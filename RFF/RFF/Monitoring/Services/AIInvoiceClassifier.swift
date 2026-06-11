import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Verdict

/// Which stage of the cascade produced the final verdict
enum ClassificationStage: String, Codable {
    case appleIntelligence = "apple-intelligence"
    case ollama = "ollama"
    case keywords = "keywords"
}

/// Result of the AI classification cascade
struct AIClassificationVerdict {
    /// 0.0-1.0 confidence that the document is an invoice
    let confidence: Float

    /// Organization names found in the document (helps company matching)
    let organizations: [String]

    /// Stage that produced the decision
    let stage: ClassificationStage

    /// Confidence from the earlier Apple Intelligence pass, when Ollama decided
    let primaryConfidence: Float?

    /// True when no stage could decide confidently - send to manual review
    let needsReview: Bool

    var isInvoice: Bool { confidence >= AIInvoiceClassifier.confidentYes }
}

#if canImport(FoundationModels)
/// Structured output schema for the on-device model (guided generation)
@available(macOS 26, *)
@Generable
private struct InvoiceJudgement {
    @Guide(description: "Confidence from 0.0 to 1.0 that this document is an invoice, i.e. a bill requesting payment (also Rechnung, facture, factura). Receipts, contracts, letters, marketing and statements are not invoices.")
    let invoiceConfidence: Double

    @Guide(description: "All distinct company/organization names mentioned in the document, exactly as written. No addresses, no people, no duplicates. Empty if none.")
    let organizations: [String]
}
#endif

// MARK: - Classifier

/// Three-stage invoice classification cascade:
/// 1. Apple Intelligence (on-device, free, fast) decides clear cases
/// 2. Local Ollama gets a second opinion on the uncertain band
/// 3. Still uncertain -> manual review queue (caller's responsibility)
/// Keyword heuristics (ported from InvoiceFiler) are the fallback when no AI is available.
final class AIInvoiceClassifier {

    /// Above this the cascade accepts "invoice" without further opinions
    static let confidentYes: Float = 0.8
    /// Below this the cascade accepts "not an invoice"
    static let confidentNo: Float = 0.25

    private let keywordClassifier: InvoiceClassifier
    private let config: AppConfig

    init(keywordClassifier: InvoiceClassifier, config: AppConfig) {
        self.keywordClassifier = keywordClassifier
        self.config = config
    }

    static func fromConfig() -> AIInvoiceClassifier {
        AIInvoiceClassifier(
            keywordClassifier: InvoiceClassifier.fromConfig(),
            config: ConfigManager.shared.config
        )
    }

    // MARK: - Cascade

    func classify(text: String) async -> AIClassificationVerdict {
        // Stage 1: Apple Intelligence
        if config.usesAIClassification, let primary = await classifyWithAppleIntelligence(text: text) {
            if primary.confidence >= Self.confidentYes || primary.confidence <= Self.confidentNo {
                return primary
            }
            // Suspicious band -> Stage 2: Ollama second opinion
            if config.usesOllamaFallback, let second = await classifyWithOllama(text: text) {
                if second.confidence >= Self.confidentYes || second.confidence <= Self.confidentNo {
                    return AIClassificationVerdict(
                        confidence: second.confidence,
                        organizations: second.organizations.isEmpty ? primary.organizations : second.organizations,
                        stage: .ollama,
                        primaryConfidence: primary.confidence,
                        needsReview: false
                    )
                }
                // Both uncertain -> review, averaging the two opinions
                return AIClassificationVerdict(
                    confidence: (primary.confidence + second.confidence) / 2,
                    organizations: second.organizations.isEmpty ? primary.organizations : second.organizations,
                    stage: .ollama,
                    primaryConfidence: primary.confidence,
                    needsReview: true
                )
            }
            // No Ollama available -> review
            return AIClassificationVerdict(
                confidence: primary.confidence,
                organizations: primary.organizations,
                stage: .appleIntelligence,
                primaryConfidence: nil,
                needsReview: true
            )
        }

        // Stage 0 fallback: keyword heuristics (no AI available)
        let keyword = keywordClassifier.classify(text)
        let threshold = config.invoiceConfidenceThreshold
        // Within 0.2 below the threshold counts as suspicious -> review
        let needsReview = !keyword.isInvoice && keyword.confidence >= max(0, threshold - 0.2)
        return AIClassificationVerdict(
            confidence: keyword.confidence,
            organizations: [],
            stage: .keywords,
            primaryConfidence: nil,
            needsReview: needsReview
        )
    }

    // MARK: - Stage 1: Apple Intelligence

    private func classifyWithAppleIntelligence(text: String) async -> AIClassificationVerdict? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            guard case .available = SystemLanguageModel.default.availability else {
                return nil
            }
            do {
                let session = LanguageModelSession(instructions: """
                    You classify documents. Given OCR or extracted text, decide whether it is an \
                    invoice - a bill requesting payment (invoice, Rechnung, facture, factura). \
                    Receipts, contracts, letters, and statements are not invoices. \
                    Also list every company or organization name that appears in the text, \
                    exactly as written.
                    """)
                let prompt = "Document text:\n\"\"\"\n\(text.prefix(3000))\n\"\"\""
                let response = try await session.respond(to: prompt, generating: InvoiceJudgement.self)
                return AIClassificationVerdict(
                    confidence: Float(min(max(response.content.invoiceConfidence, 0), 1)),
                    organizations: dedupe(response.content.organizations),
                    stage: .appleIntelligence,
                    primaryConfidence: nil,
                    needsReview: false
                )
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }

    // MARK: - Stage 2: Ollama

    private func classifyWithOllama(text: String) async -> AIClassificationVerdict? {
        let service = AIAnalysisService.shared
        let models = await service.fetchOllamaModels()
        guard !models.isEmpty else { return nil }

        let preferred = await service.getOllamaModel()
        let model = (!preferred.isEmpty && models.contains { $0.name == preferred })
            ? preferred
            : AIAnalysisService.bestOllamaModel(among: models)!.name

        var request = URLRequest(url: AIAnalysisService.ollamaBaseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300

        let prompt = """
        Decide whether this document is an invoice - a bill requesting payment (invoice, Rechnung, \
        facture, factura). Receipts, contracts, letters, and statements are not invoices. \
        Respond with JSON exactly like {"invoiceConfidence": 0.0, "organizations": ["..."]} where \
        invoiceConfidence is 0.0-1.0 and organizations lists every company name in the text.

        Document text:
        \"\"\"
        \(text.prefix(3000))
        \"\"\"
        """

        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "stream": false,
            "format": "json",
            "options": ["temperature": 0.1, "num_ctx": 8192]
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = httpBody

        let session = URLSession(configuration: {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 300
            config.timeoutIntervalForResource = 300
            return config
        }())

        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String,
              let contentData = content.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any] else {
            return nil
        }

        let confidence = (parsed["invoiceConfidence"] as? Double)
            ?? (parsed["invoiceConfidence"] as? NSNumber)?.doubleValue
            ?? 0
        let organizations = (parsed["organizations"] as? [String]) ?? []

        return AIClassificationVerdict(
            confidence: Float(min(max(confidence, 0), 1)),
            organizations: dedupe(organizations),
            stage: .ollama,
            primaryConfidence: nil,
            needsReview: false
        )
    }

    // MARK: - Helpers

    private func dedupe(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}
