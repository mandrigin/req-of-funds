import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// AI provider options
enum AIProvider: String, CaseIterable, Codable {
    case claudeCode = "claude_code"
    case openai = "openai"
    case anthropic = "anthropic"
    case foundation = "foundation"  // Apple Foundation Models (macOS 26+)

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code (Local)"
        case .openai: return "OpenAI"
        case .anthropic: return "Claude (Anthropic)"
        case .foundation: return "On-Device (Apple)"
        }
    }

    var apiKeyEnvVar: String? {
        switch self {
        case .claudeCode: return nil  // No API key needed
        case .foundation: return nil  // No API key needed - on-device
        case .openai: return "OPENAI_API_KEY"
        case .anthropic: return "ANTHROPIC_API_KEY"
        }
    }

    var requiresAPIKey: Bool {
        self != .claudeCode && self != .foundation
    }

    /// Whether this provider runs entirely on-device (no network)
    var isOnDevice: Bool {
        self == .foundation
    }
}

/// A single option for an extracted field value
struct AIFieldOption: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    let value: String
    let confidence: Double
    let reasoning: String?

    init(id: UUID = UUID(), value: String, confidence: Double, reasoning: String? = nil) {
        self.id = id
        self.value = value
        self.confidence = confidence
        self.reasoning = reasoning
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: AIFieldOption, rhs: AIFieldOption) -> Bool {
        lhs.id == rhs.id
    }
}

/// Suggested field from AI analysis with up to 3 options
struct AIFieldSuggestion: Identifiable, Codable, Sendable {
    let id: UUID
    let fieldType: String
    /// Up to 3 options for this field, sorted by confidence (highest first)
    let options: [AIFieldOption]

    init(id: UUID = UUID(), fieldType: String, options: [AIFieldOption]) {
        self.id = id
        self.fieldType = fieldType
        // Sort options by confidence descending and limit to 3
        self.options = Array(options.sorted { $0.confidence > $1.confidence }.prefix(3))
    }

    /// Convenience initializer for single-value suggestions (backwards compatibility)
    init(id: UUID = UUID(), fieldType: String, value: String, confidence: Double, reasoning: String? = nil) {
        self.id = id
        self.fieldType = fieldType
        self.options = [AIFieldOption(value: value, confidence: confidence, reasoning: reasoning)]
    }

    /// Primary (highest confidence) value - for backwards compatibility
    var value: String { options.first?.value ?? "" }

    /// Primary (highest confidence) confidence score - for backwards compatibility
    var confidence: Double { options.first?.confidence ?? 0 }

    /// Primary (highest confidence) reasoning - for backwards compatibility
    var reasoning: String? { options.first?.reasoning }

    /// Whether this suggestion has multiple options to choose from
    var hasAlternatives: Bool { options.count > 1 }

    /// Convert to InvoiceFieldType if valid
    /// Handles aliases for backwards compatibility
    var invoiceFieldType: InvoiceFieldType? {
        // Try direct match first
        if let fieldType = InvoiceFieldType(rawValue: fieldType) {
            return fieldType
        }
        // Handle aliases
        switch fieldType.lowercased() {
        case "recipient_name", "buyer", "buyer_name", "bill_to", "customer_name", "customer":
            return .recipient
        case "seller", "seller_name", "from":
            return .vendor
        default:
            return nil
        }
    }
}

/// Result of AI document analysis
struct AIAnalysisResult: Sendable {
    /// Suggested field values
    let suggestions: [AIFieldSuggestion]

    /// Suggested schema name based on vendor
    let suggestedSchemaName: String?

    /// Document summary
    let summary: String?

    /// Any warnings or notes
    let notes: [String]
}

/// Errors during AI analysis
enum AIAnalysisError: Error, LocalizedError {
    case apiKeyNotConfigured
    case claudeCodeNotAvailable
    case claudeCodeError(String)
    case foundationModelsNotAvailable
    case foundationModelsError(String)
    case networkError(String)
    case invalidResponse
    case rateLimited
    case insufficientQuota

    var errorDescription: String? {
        switch self {
        case .apiKeyNotConfigured:
            return "API key not configured. Add it in Settings > AI."
        case .claudeCodeNotAvailable:
            return "Claude Code CLI not found. Install Claude Code or configure an API key."
        case .claudeCodeError(let message):
            return "Claude Code error: \(message)"
        case .foundationModelsNotAvailable:
            return "On-device AI requires macOS 26 or later."
        case .foundationModelsError(let message):
            return "On-device AI error: \(message)"
        case .networkError(let message):
            return "Network error: \(message)"
        case .invalidResponse:
            return "Invalid response from AI service"
        case .rateLimited:
            return "Rate limited. Please try again later."
        case .insufficientQuota:
            return "API quota exceeded. Check your billing settings."
        }
    }
}

/// Service for AI-assisted document analysis using OpenAI or Anthropic API
/// Privacy-first: Only sends data when user explicitly requests
actor AIAnalysisService {
    /// UserDefaults keys for API configuration
    private static let openAIKeyDefaultsKey = "ai_openai_api_key"
    private static let anthropicKeyDefaultsKey = "ai_anthropic_api_key"
    private static let selectedProviderDefaultsKey = "ai_selected_provider"

    /// Shared instance
    static let shared = AIAnalysisService()

    private let session: URLSession
    private let defaults = UserDefaults.standard

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    // MARK: - Claude Code CLI Detection

    /// Common paths where Claude Code CLI might be installed
    /// Note: Sandboxed apps can't use 'which' command, so we check paths directly
    private static let claudeCodePaths: [String] = {
        var paths = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",  // Homebrew on Apple Silicon
            "/usr/bin/claude"
        ]
        // Add user-local paths (expand ~ to actual home directory)
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            paths.insert("\(home)/.local/bin/claude", at: 0)  // npm global install location
        }
        return paths
    }()

    /// Check if Claude Code CLI is available by checking common installation paths
    /// Note: Can't use 'which' command in sandboxed macOS apps
    nonisolated func isClaudeCodeAvailable() -> Bool {
        return getClaudeCodePath() != nil
    }

    /// Get the path to the Claude CLI by checking common installation paths
    /// Note: Can't use 'which' command in sandboxed macOS apps
    nonisolated func getClaudeCodePath() -> String? {
        let fileManager = FileManager.default
        for path in Self.claudeCodePaths {
            if fileManager.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    // MARK: - Foundation Models Detection (macOS 26+)

    /// Check if Apple Foundation Models is available (requires macOS 26+)
    nonisolated func isFoundationModelsAvailable() -> Bool {
        if #available(macOS 26, *) {
            return true
        }
        return false
    }

    // MARK: - Provider Management

    /// Get the currently selected provider
    func getSelectedProvider() -> AIProvider {
        if let rawValue = defaults.string(forKey: Self.selectedProviderDefaultsKey),
           let provider = AIProvider(rawValue: rawValue) {
            // Validate that Claude Code is still available if selected
            if provider == .claudeCode && !isClaudeCodeAvailable() {
                return detectAvailableProvider() ?? .anthropic
            }
            return provider
        }
        // Auto-detect based on available providers
        return detectAvailableProvider() ?? .anthropic
    }

    /// Set the selected provider
    func setSelectedProvider(_ provider: AIProvider) {
        defaults.set(provider.rawValue, forKey: Self.selectedProviderDefaultsKey)
    }

    /// Auto-detect available provider based on CLI availability and API keys
    func detectAvailableProvider() -> AIProvider? {
        // Priority: Claude Code CLI first (no API key needed!)
        if isClaudeCodeAvailable() {
            return .claudeCode
        }
        // Then Anthropic API
        if isAPIKeyConfigured(for: .anthropic) {
            return .anthropic
        }
        // Then OpenAI API
        if isAPIKeyConfigured(for: .openai) {
            return .openai
        }
        return nil
    }

    // MARK: - API Key Management

    /// Check if API key is configured for a specific provider
    func isAPIKeyConfigured(for provider: AIProvider) -> Bool {
        // Claude Code doesn't need an API key
        if provider == .claudeCode {
            return isClaudeCodeAvailable()
        }
        // Foundation Models doesn't need an API key - just macOS 26+
        if provider == .foundation {
            return isFoundationModelsAvailable()
        }
        // Check environment variable first
        if let envVar = provider.apiKeyEnvVar,
           let envKey = ProcessInfo.processInfo.environment[envVar],
           !envKey.isEmpty {
            return true
        }
        // Check UserDefaults
        let defaultsKey = provider == .openai ? Self.openAIKeyDefaultsKey : Self.anthropicKeyDefaultsKey
        if let storedKey = defaults.string(forKey: defaultsKey), !storedKey.isEmpty {
            return true
        }
        return false
    }

    /// Check if any AI provider is available (CLI, on-device, or API key)
    func isAnyAPIKeyConfigured() -> Bool {
        isClaudeCodeAvailable() || isFoundationModelsAvailable() || isAPIKeyConfigured(for: .openai) || isAPIKeyConfigured(for: .anthropic)
    }

    /// Get the API key for a provider (throws if not configured)
    func getAPIKey(for provider: AIProvider) throws -> String {
        // Claude Code doesn't need an API key
        if provider == .claudeCode {
            if isClaudeCodeAvailable() {
                return ""  // No key needed
            }
            throw AIAnalysisError.claudeCodeNotAvailable
        }
        // Foundation Models doesn't need an API key
        if provider == .foundation {
            if isFoundationModelsAvailable() {
                return ""  // No key needed - on-device
            }
            throw AIAnalysisError.foundationModelsNotAvailable
        }
        // Check environment variable first
        if let envVar = provider.apiKeyEnvVar,
           let envKey = ProcessInfo.processInfo.environment[envVar],
           !envKey.isEmpty {
            return envKey
        }
        // Check UserDefaults
        let defaultsKey = provider == .openai ? Self.openAIKeyDefaultsKey : Self.anthropicKeyDefaultsKey
        if let storedKey = defaults.string(forKey: defaultsKey), !storedKey.isEmpty {
            return storedKey
        }
        throw AIAnalysisError.apiKeyNotConfigured
    }

    /// Save the API key for a provider
    func saveAPIKey(_ key: String, for provider: AIProvider) {
        let defaultsKey = provider == .openai ? Self.openAIKeyDefaultsKey : Self.anthropicKeyDefaultsKey
        defaults.set(key, forKey: defaultsKey)
    }

    /// Delete the API key for a provider
    func deleteAPIKey(for provider: AIProvider) {
        let defaultsKey = provider == .openai ? Self.openAIKeyDefaultsKey : Self.anthropicKeyDefaultsKey
        defaults.removeObject(forKey: defaultsKey)
    }

    // MARK: - Legacy API (for compatibility)

    /// Check if API key is configured (uses selected provider)
    func isAPIKeyConfigured() -> Bool {
        isAPIKeyConfigured(for: getSelectedProvider())
    }

    /// Get the API key (uses selected provider)
    func getAPIKey() throws -> String {
        try getAPIKey(for: getSelectedProvider())
    }

    /// Save the API key (uses selected provider)
    func saveAPIKey(_ key: String) {
        saveAPIKey(key, for: getSelectedProvider())
    }

    /// Delete the API key (uses selected provider)
    func deleteAPIKey() {
        deleteAPIKey(for: getSelectedProvider())
    }

    // MARK: - Document Analysis

    /// Analyze document text using the selected AI provider
    /// This is only called when user explicitly taps "AI Analyze"
    func analyzeDocument(text: String) async throws -> AIAnalysisResult {
        let provider = getSelectedProvider()
        let apiKey = try getAPIKey(for: provider)

        let prompt = buildAnalysisPrompt(for: text)
        let response = try await callAI(prompt: prompt, apiKey: apiKey, provider: provider)

        return try parseAnalysisResponse(response)
    }

    /// Analyze document text using a specific provider
    /// Used for explicit "AI Analyze (Local)" vs "AI Analyze" actions
    func analyzeDocument(text: String, using provider: AIProvider) async throws -> AIAnalysisResult {
        let apiKey = try getAPIKey(for: provider)

        let prompt = buildAnalysisPrompt(for: text)
        let response = try await callAI(prompt: prompt, apiKey: apiKey, provider: provider)

        return try parseAnalysisResponse(response)
    }

    /// Suggest a schema for the document
    func suggestSchema(text: String, existingSchemas: [InvoiceSchema]) async throws -> InvoiceSchema? {
        let provider = getSelectedProvider()
        let apiKey = try getAPIKey(for: provider)

        let schemaNames = existingSchemas.map { $0.name }.joined(separator: ", ")
        let prompt = """
        Analyze this invoice text and determine if it matches any of these existing schemas: \(schemaNames)

        If it matches an existing schema, respond with just the schema name.
        If it's a new vendor/format, respond with "NEW: [suggested schema name]"

        Invoice text:
        \(text.prefix(3000))
        """

        let response = try await callAI(prompt: prompt, apiKey: apiKey, provider: provider)

        if response.hasPrefix("NEW:") {
            // Create new schema suggestion
            return nil
        } else {
            // Find matching schema
            let schemaName = response.trimmingCharacters(in: .whitespacesAndNewlines)
            return existingSchemas.first { $0.name.lowercased() == schemaName.lowercased() }
        }
    }

    // MARK: - Private Implementation

    private func buildAnalysisPrompt(for text: String) -> String {
        """
        You are an invoice data extraction assistant. Extract structured data from the invoice text below.

        ## STEP 1: Identify the key information
        Look for these fields in the invoice:
        - Invoice number: Look for "Invoice #", "Invoice No.", "Inv:", "Bill #", "Rechnung Nr.", "Re.Nr." or similar labels
        - Invoice date: Look for "Invoice Date", "Date:", "Issued:", "Datum:", "Rechnungsdatum:" or the date near the invoice number
        - Due date: Look for "Due Date", "Payment Due", "Due:", "Pay By:", "Fällig:", "Zahlbar bis:"
        - Vendor: The company SENDING the invoice (usually at top, with logo)
        - Recipient: The company/person RECEIVING the invoice (look for "Bill To:", "Ship To:", "Customer:", "An:", "Empfänger:", "Rechnungsempfänger:")
        - Amounts: Look for "Subtotal", "Tax", "VAT", "Total", "Amount Due", "Balance Due", "Grand Total", "Netto", "MwSt", "Brutto", "Gesamt", "Summe", "Endbetrag"
        - Currency: USD ($), EUR (€), GBP (£), CHF, or stated currency
        - PO number: Look for "PO #", "Purchase Order", "P.O.:", "Bestellnummer:", "Auftragsnummer:"

        ## STEP 2: Format the values
        - Dates: Convert to YYYY-MM-DD format
          * "January 15, 2024" → "2024-01-15"
          * "15/01/2024" (European) → "2024-01-15"
          * "01/15/2024" (US) → "2024-01-15"
          * "15.01.2024" (German) → "2024-01-15"
        - Numbers: Extract numeric value only, no currency symbols
          * "$1,234.56" → "1234.56"
          * "€1.234,56" (European) → "1234.56"
          * "CHF 1'234.56" (Swiss) → "1234.56"
        - Vendor/Recipient: Use the company name only, not the full address

        ## STEP 3: Output JSON format with OPTIONS
        For each field, return up to 3 options when there is ambiguity:
        - If you're highly confident (>0.9), you may return just one option
        - If there are multiple plausible values, return 2-3 options with different confidence levels
        - Order options by confidence (highest first)

        {
            "suggestions": [
                {
                    "fieldType": "field_name",
                    "options": [
                        {"value": "primary value", "confidence": 0.95, "reasoning": "why this is most likely"},
                        {"value": "alternative", "confidence": 0.7, "reasoning": "why this might be correct"}
                    ]
                }
            ],
            "schemaName": "Vendor Name Invoice",
            "summary": "one-line summary",
            "notes": ["warnings if any"]
        }

        Valid fieldType values: invoice_number, invoice_date, due_date, vendor, recipient, subtotal, tax, total, currency, po_number

        ## EXAMPLE 1 (US format):
        Input text:
        '''
        ACME CORPORATION
        123 Business St, New York, NY 10001

        INVOICE
        Invoice #: INV-2024-0042
        Date: March 15, 2024
        Due: April 14, 2024

        Bill To:
        Widget Co.
        456 Client Ave

        Services rendered............$500.00
        Consulting hours.............$300.00
        Subtotal: $800.00
        Tax (8%): $64.00
        Total Due: $864.00
        '''

        Output:
        {
            "suggestions": [
                {"fieldType": "vendor", "options": [{"value": "ACME CORPORATION", "confidence": 0.95, "reasoning": "Company name at top of invoice"}]},
                {"fieldType": "invoice_number", "options": [{"value": "INV-2024-0042", "confidence": 0.95, "reasoning": "Labeled as Invoice #"}]},
                {"fieldType": "invoice_date", "options": [{"value": "2024-03-15", "confidence": 0.9, "reasoning": "Date field converted to ISO format"}]},
                {"fieldType": "due_date", "options": [{"value": "2024-04-14", "confidence": 0.9, "reasoning": "Due date converted to ISO format"}]},
                {"fieldType": "recipient", "options": [{"value": "Widget Co.", "confidence": 0.9, "reasoning": "Listed under Bill To"}]},
                {"fieldType": "subtotal", "options": [{"value": "800.00", "confidence": 0.9, "reasoning": "Labeled as Subtotal"}]},
                {"fieldType": "tax", "options": [{"value": "64.00", "confidence": 0.9, "reasoning": "Labeled as Tax (8%)"}]},
                {"fieldType": "total", "options": [{"value": "864.00", "confidence": 0.95, "reasoning": "Labeled as Total Due"}]},
                {"fieldType": "currency", "options": [{"value": "USD", "confidence": 0.9, "reasoning": "Dollar sign used"}]}
            ],
            "schemaName": "ACME Corporation Invoice",
            "summary": "Invoice for services and consulting from ACME Corporation",
            "notes": []
        }

        ## EXAMPLE 2 (German/DACH format with ambiguity):
        Input text:
        '''
        Müller GmbH
        Hauptstraße 1, 10115 Berlin
        IBAN: DE89 3704 0044 0532 0130 00
        USt-IdNr.: DE123456789

        RECHNUNG
        Rechnung Nr.: RE-2024-00789
        Rechnungsdatum: 15.03.2024
        Fällig: 30.03.2024

        Rechnungsempfänger:
        Schmidt AG
        z.Hd. Herr Weber
        Bahnhofstraße 42
        80331 München

        Beratungsleistungen März 2024
        Nettobetrag: €1.500,00
        MwSt. 19%: €285,00
        Bruttobetrag: €1.785,00

        Zahlbar per Überweisung
        '''

        Output:
        {
            "suggestions": [
                {"fieldType": "vendor", "options": [{"value": "Müller GmbH", "confidence": 0.95, "reasoning": "Company at top with IBAN and VAT ID"}]},
                {"fieldType": "invoice_number", "options": [{"value": "RE-2024-00789", "confidence": 0.95, "reasoning": "Rechnung Nr. is German for Invoice No."}]},
                {"fieldType": "invoice_date", "options": [{"value": "2024-03-15", "confidence": 0.9, "reasoning": "Rechnungsdatum (invoice date) in DD.MM.YYYY format"}]},
                {"fieldType": "due_date", "options": [{"value": "2024-03-30", "confidence": 0.9, "reasoning": "Fällig means Due"}]},
                {"fieldType": "recipient", "options": [
                    {"value": "Schmidt AG", "confidence": 0.9, "reasoning": "Main company under Rechnungsempfänger (invoice recipient)"},
                    {"value": "Herr Weber", "confidence": 0.4, "reasoning": "Attention person (z.Hd.) but not the company"}
                ]},
                {"fieldType": "subtotal", "options": [{"value": "1500.00", "confidence": 0.9, "reasoning": "Nettobetrag (net amount) before VAT"}]},
                {"fieldType": "tax", "options": [{"value": "285.00", "confidence": 0.95, "reasoning": "MwSt. is German VAT (Mehrwertsteuer)"}]},
                {"fieldType": "total", "options": [{"value": "1785.00", "confidence": 0.95, "reasoning": "Bruttobetrag (gross amount) is total including VAT"}]},
                {"fieldType": "currency", "options": [{"value": "EUR", "confidence": 0.95, "reasoning": "Euro symbol (€) used throughout"}]}
            ],
            "schemaName": "Müller GmbH Rechnung",
            "summary": "German consulting invoice from Müller GmbH to Schmidt AG",
            "notes": ["European number format converted (comma as decimal separator)", "IBAN indicates German bank transfer payment"]
        }

        ## EXAMPLE 3 (Swiss format):
        Input text:
        '''
        Helvetia Consulting AG
        Bahnhofstrasse 10, 8001 Zürich
        CHE-123.456.789 MWST

        Rechnung Nr. 2024-456
        Datum: 20.03.2024
        Zahlbar bis: 20.04.2024

        An: Alpine Solutions GmbH

        IT-Beratung: CHF 2'500.00
        MWST 8.1%: CHF 202.50
        Total: CHF 2'702.50
        '''

        Output:
        {
            "suggestions": [
                {"fieldType": "vendor", "options": [{"value": "Helvetia Consulting AG", "confidence": 0.95, "reasoning": "Company name with Swiss VAT number (CHE)"}]},
                {"fieldType": "invoice_number", "options": [{"value": "2024-456", "confidence": 0.9, "reasoning": "Rechnung Nr."}]},
                {"fieldType": "invoice_date", "options": [{"value": "2024-03-20", "confidence": 0.9, "reasoning": "Datum in DD.MM.YYYY format"}]},
                {"fieldType": "due_date", "options": [{"value": "2024-04-20", "confidence": 0.9, "reasoning": "Zahlbar bis (payable until)"}]},
                {"fieldType": "recipient", "options": [{"value": "Alpine Solutions GmbH", "confidence": 0.9, "reasoning": "Listed after An: (To:)"}]},
                {"fieldType": "subtotal", "options": [{"value": "2500.00", "confidence": 0.85, "reasoning": "Amount before Swiss VAT (MWST)"}]},
                {"fieldType": "tax", "options": [{"value": "202.50", "confidence": 0.95, "reasoning": "MWST is Swiss VAT at 8.1%"}]},
                {"fieldType": "total", "options": [{"value": "2702.50", "confidence": 0.95, "reasoning": "Total amount"}]},
                {"fieldType": "currency", "options": [{"value": "CHF", "confidence": 0.95, "reasoning": "Swiss Francs explicitly stated"}]}
            ],
            "schemaName": "Helvetia Consulting Rechnung",
            "summary": "Swiss IT consulting invoice from Helvetia Consulting AG",
            "notes": ["Swiss number format with apostrophe as thousands separator"]
        }

        ## NOW ANALYZE THIS INVOICE:
        \(text.prefix(4000))

        Respond with only the JSON object. No markdown code blocks.
        """
    }

    private func callAI(prompt: String, apiKey: String, provider: AIProvider) async throws -> String {
        switch provider {
        case .claudeCode:
            return try await callClaudeCode(prompt: prompt)
        case .foundation:
            return try await callFoundationModels(prompt: prompt)
        case .openai:
            return try await callOpenAI(prompt: prompt, apiKey: apiKey)
        case .anthropic:
            return try await callAnthropic(prompt: prompt, apiKey: apiKey)
        }
    }

    private func callClaudeCode(prompt: String) async throws -> String {
        guard let claudePath = getClaudeCodePath() else {
            throw AIAnalysisError.claudeCodeNotAvailable
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: claudePath)
            // Use --print mode for non-interactive single-shot prompts
            // --output-format text ensures we get plain text response
            process.arguments = ["--print", "--output-format", "text", prompt]

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try process.run()

                // Run in background to avoid blocking
                DispatchQueue.global(qos: .userInitiated).async {
                    process.waitUntilExit()

                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

                    if process.terminationStatus == 0 {
                        if let output = String(data: outputData, encoding: .utf8) {
                            continuation.resume(returning: output.trimmingCharacters(in: .whitespacesAndNewlines))
                        } else {
                            continuation.resume(throwing: AIAnalysisError.invalidResponse)
                        }
                    } else {
                        let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                        continuation.resume(throwing: AIAnalysisError.claudeCodeError(errorMessage.trimmingCharacters(in: .whitespacesAndNewlines)))
                    }
                }
            } catch {
                continuation.resume(throwing: AIAnalysisError.claudeCodeError(error.localizedDescription))
            }
        }
    }

    private func callFoundationModels(prompt: String) async throws -> String {
        // Requires macOS 26+ - check availability first
        guard isFoundationModelsAvailable() else {
            throw AIAnalysisError.foundationModelsNotAvailable
        }

        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return try await callFoundationModelsImpl(prompt: prompt)
        }
        #endif

        throw AIAnalysisError.foundationModelsNotAvailable
    }

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    private func callFoundationModelsImpl(prompt: String) async throws -> String {
        // Import handled via conditional compilation
        // FoundationModels provides SystemLanguageModel and LanguageModelSession
        let model = SystemLanguageModel.default

        // Check model availability
        switch model.availability {
        case .available:
            break
        case .unavailable(let reason):
            let reasonDescription: String
            switch reason {
            case .appleIntelligenceNotEnabled:
                reasonDescription = "Apple Intelligence is not enabled. Enable it in System Settings > Apple Intelligence & Siri."
            case .deviceNotEligible:
                reasonDescription = "This device does not support Apple Intelligence."
            case .modelNotReady:
                reasonDescription = "The language model is still downloading. Please try again later."
            @unknown default:
                reasonDescription = "The language model is not available."
            }
            throw AIAnalysisError.foundationModelsError(reasonDescription)
        }

        // Create session and generate response
        let session = LanguageModelSession()
        do {
            let response = try await session.respond(to: prompt)
            return response.content
        } catch {
            throw AIAnalysisError.foundationModelsError(error.localizedDescription)
        }
    }
    #endif

    private func callOpenAI(prompt: String, apiKey: String) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.3,
            "max_tokens": 2000
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIAnalysisError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 429:
            throw AIAnalysisError.rateLimited
        case 401:
            throw AIAnalysisError.apiKeyNotConfigured
        case 402:
            throw AIAnalysisError.insufficientQuota
        default:
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AIAnalysisError.networkError("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIAnalysisError.invalidResponse
        }

        return content
    }

    private func callAnthropic(prompt: String, apiKey: String) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": "claude-sonnet-4-20250514",
            "max_tokens": 2000,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIAnalysisError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 429:
            throw AIAnalysisError.rateLimited
        case 401:
            throw AIAnalysisError.apiKeyNotConfigured
        case 402:
            throw AIAnalysisError.insufficientQuota
        default:
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AIAnalysisError.networkError("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }

        // Parse Anthropic response format
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstBlock = content.first,
              let text = firstBlock["text"] as? String else {
            throw AIAnalysisError.invalidResponse
        }

        return text
    }

    /// Extract JSON from AI response, handling markdown code blocks and surrounding text
    private func extractJSON(from response: String) -> String {
        // Try to find JSON within markdown code blocks first
        // Match ```json ... ``` or ``` ... ``` anywhere in the response
        if let jsonBlockRange = response.range(of: "```json\\s*\\n?([\\s\\S]*?)```", options: .regularExpression) {
            let match = String(response[jsonBlockRange])
            // Remove the opening ```json and closing ```
            var jsonContent = match
            if let startRange = jsonContent.range(of: "```json") {
                jsonContent.removeSubrange(startRange)
            }
            if let endRange = jsonContent.range(of: "```", options: .backwards) {
                jsonContent.removeSubrange(endRange)
            }
            return jsonContent.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Try plain ``` blocks
        if let codeBlockRange = response.range(of: "```\\s*\\n?([\\s\\S]*?)```", options: .regularExpression) {
            let match = String(response[codeBlockRange])
            var jsonContent = match
            // Remove leading ```
            if let startRange = jsonContent.range(of: "```") {
                jsonContent.removeSubrange(startRange)
            }
            // Remove trailing ```
            if let endRange = jsonContent.range(of: "```", options: .backwards) {
                jsonContent.removeSubrange(endRange)
            }
            return jsonContent.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // No code blocks found - try to extract JSON object directly
        // Find the first { and last } to extract the JSON
        guard let firstBrace = response.firstIndex(of: "{"),
              let lastBrace = response.lastIndex(of: "}") else {
            return response.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return String(response[firstBrace...lastBrace])
    }

    private func parseAnalysisResponse(_ response: String) throws -> AIAnalysisResult {
        // Extract JSON from response - handle various AI response formats
        let cleanResponse = extractJSON(from: response)

        guard let data = cleanResponse.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIAnalysisError.invalidResponse
        }

        var suggestions: [AIFieldSuggestion] = []

        if let suggestionsArray = json["suggestions"] as? [[String: Any]] {
            for item in suggestionsArray {
                guard let fieldType = item["fieldType"] as? String else {
                    continue
                }

                // Try new format with options array first
                if let optionsArray = item["options"] as? [[String: Any]] {
                    var options: [AIFieldOption] = []
                    for optionItem in optionsArray {
                        guard let value = optionItem["value"] as? String else {
                            continue
                        }
                        let confidence = optionItem["confidence"] as? Double ?? 0.5
                        let reasoning = optionItem["reasoning"] as? String

                        // Post-process value based on field type
                        let normalizedValue = normalizeFieldValue(value, forFieldType: fieldType)

                        options.append(AIFieldOption(
                            value: normalizedValue,
                            confidence: confidence,
                            reasoning: reasoning
                        ))
                    }
                    if !options.isEmpty {
                        suggestions.append(AIFieldSuggestion(
                            fieldType: fieldType,
                            options: options
                        ))
                    }
                }
                // Fall back to legacy single-value format for backwards compatibility
                else if let value = item["value"] as? String {
                    let confidence = item["confidence"] as? Double ?? 0.5
                    let reasoning = item["reasoning"] as? String

                    // Post-process value based on field type
                    let normalizedValue = normalizeFieldValue(value, forFieldType: fieldType)

                    suggestions.append(AIFieldSuggestion(
                        fieldType: fieldType,
                        value: normalizedValue,
                        confidence: confidence,
                        reasoning: reasoning
                    ))
                }
            }
        }

        let schemaName = json["schemaName"] as? String
        let summary = json["summary"] as? String
        let notes = json["notes"] as? [String] ?? []

        return AIAnalysisResult(
            suggestions: suggestions,
            suggestedSchemaName: schemaName,
            summary: summary,
            notes: notes
        )
    }

    /// Normalize a field value based on its type
    /// Handles common variations in AI output (currency symbols, date formats, number formats)
    private func normalizeFieldValue(_ value: String, forFieldType fieldType: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        switch fieldType {
        case "subtotal", "tax", "total":
            return normalizeNumericValue(trimmed)
        case "invoice_date", "due_date":
            return normalizeDateValue(trimmed)
        case "currency":
            return normalizeCurrency(trimmed)
        default:
            return trimmed
        }
    }

    /// Normalize numeric values: remove currency symbols, handle European decimals
    private func normalizeNumericValue(_ value: String) -> String {
        var cleaned = value

        // Remove common currency symbols and prefixes
        let currencyPatterns = ["$", "€", "£", "¥", "USD", "EUR", "GBP", "CHF"]
        for pattern in currencyPatterns {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: "")
        }

        // Remove thousands separators and whitespace
        cleaned = cleaned.replacingOccurrences(of: " ", with: "")

        // Handle European format: 1.234,56 → 1234.56
        // Check if comma appears after period (European format)
        if let commaIndex = cleaned.lastIndex(of: ","),
           let periodIndex = cleaned.lastIndex(of: "."),
           commaIndex > periodIndex {
            // European format: periods are thousands, comma is decimal
            cleaned = cleaned.replacingOccurrences(of: ".", with: "")
            cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
        } else if cleaned.contains(",") && !cleaned.contains(".") {
            // Comma-only format: might be decimal separator (e.g., "1234,56")
            // Check if comma is followed by exactly 2 digits at end
            if let commaIndex = cleaned.lastIndex(of: ",") {
                let afterComma = cleaned[cleaned.index(after: commaIndex)...]
                if afterComma.count <= 2 && afterComma.allSatisfy({ $0.isNumber }) {
                    cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
                } else {
                    // Comma is thousands separator
                    cleaned = cleaned.replacingOccurrences(of: ",", with: "")
                }
            }
        } else {
            // US format or already clean: just remove commas (thousands separator)
            cleaned = cleaned.replacingOccurrences(of: ",", with: "")
        }

        // Remove any remaining non-numeric characters except decimal point
        cleaned = String(cleaned.filter { $0.isNumber || $0 == "." || $0 == "-" })

        return cleaned
    }

    /// Normalize date values to ISO 8601 (YYYY-MM-DD)
    private func normalizeDateValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        // If already in ISO format, return as-is
        if trimmed.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil {
            return trimmed
        }

        // Try various date formats
        let dateFormats = [
            "MMMM d, yyyy",      // January 15, 2024
            "MMMM dd, yyyy",     // January 15, 2024
            "MMM d, yyyy",       // Jan 15, 2024
            "MMM dd, yyyy",      // Jan 15, 2024
            "d MMMM yyyy",       // 15 January 2024
            "dd MMMM yyyy",      // 15 January 2024
            "d MMM yyyy",        // 15 Jan 2024
            "dd MMM yyyy",       // 15 Jan 2024
            "dd/MM/yyyy",        // 15/01/2024 (European)
            "d/M/yyyy",          // 5/1/2024 (European)
            "MM/dd/yyyy",        // 01/15/2024 (US)
            "M/d/yyyy",          // 1/15/2024 (US)
            "dd.MM.yyyy",        // 15.01.2024 (German)
            "d.M.yyyy",          // 5.1.2024 (German)
            "yyyy/MM/dd",        // 2024/01/15
            "dd-MM-yyyy",        // 15-01-2024
            "MM-dd-yyyy",        // 01-15-2024
        ]

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        let isoFormatter = DateFormatter()
        isoFormatter.dateFormat = "yyyy-MM-dd"
        isoFormatter.locale = Locale(identifier: "en_US_POSIX")

        for format in dateFormats {
            dateFormatter.dateFormat = format
            if let date = dateFormatter.date(from: trimmed) {
                return isoFormatter.string(from: date)
            }
        }

        // If no format matched, return original (AI might have already formatted it)
        return trimmed
    }

    /// Normalize currency codes
    private func normalizeCurrency(_ value: String) -> String {
        let upper = value.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Map symbols and common variations to standard codes
        let currencyMap: [String: String] = [
            "$": "USD",
            "US$": "USD",
            "US DOLLAR": "USD",
            "US DOLLARS": "USD",
            "DOLLAR": "USD",
            "DOLLARS": "USD",
            "€": "EUR",
            "EURO": "EUR",
            "EUROS": "EUR",
            "£": "GBP",
            "POUND": "GBP",
            "POUNDS": "GBP",
            "BRITISH POUND": "GBP",
            "¥": "JPY",
            "YEN": "JPY",
            "CHF": "CHF",
            "SWISS FRANC": "CHF",
            "FRANC": "CHF",
        ]

        return currencyMap[upper] ?? upper
    }
}

// MARK: - Preview Helpers

extension AIAnalysisResult {
    static var preview: AIAnalysisResult {
        AIAnalysisResult(
            suggestions: [
                AIFieldSuggestion(fieldType: "vendor", options: [
                    AIFieldOption(value: "Acme Corp", confidence: 0.95, reasoning: "Found at top of invoice"),
                    AIFieldOption(value: "ACME Corporation", confidence: 0.7, reasoning: "Full legal name in footer")
                ]),
                AIFieldSuggestion(fieldType: "invoice_number", value: "INV-2024-001", confidence: 0.9, reasoning: "Standard invoice number format"),
                AIFieldSuggestion(fieldType: "total", options: [
                    AIFieldOption(value: "1234.56", confidence: 0.85, reasoning: "Labeled 'Total Due'"),
                    AIFieldOption(value: "1134.56", confidence: 0.6, reasoning: "Subtotal before tax"),
                    AIFieldOption(value: "1334.56", confidence: 0.4, reasoning: "Grand total with shipping")
                ])
            ],
            suggestedSchemaName: "Acme Corp Invoice",
            summary: "Invoice from Acme Corp for office supplies",
            notes: ["Tax amount may be included in total"]
        )
    }
}
