import Foundation
import NaturalLanguage

/// Extracted entities from document text
struct ExtractedEntities: Sendable {
    /// Organization name (requestor)
    let organizationName: String?

    /// Due date found in document
    let dueDate: Date?

    /// Monetary amount
    let amount: Decimal?

    /// All organization names found
    let allOrganizations: [String]

    /// All dates found
    let allDates: [Date]

    /// All currency amounts found
    let allAmounts: [Decimal]

    /// Confidence scores for primary extractions
    let confidence: ExtractionConfidence
}

/// Confidence scores for extracted entities
struct ExtractionConfidence: Sendable {
    let organizationConfidence: Float
    let dateConfidence: Float
    let amountConfidence: Float

    var overall: Float {
        let scores = [organizationConfidence, dateConfidence, amountConfidence]
        let nonZero = scores.filter { $0 > 0 }
        guard !nonZero.isEmpty else { return 0 }
        return nonZero.reduce(0, +) / Float(nonZero.count)
    }
}

/// Errors during entity extraction
enum ExtractionError: Error, LocalizedError {
    case emptyText
    case noEntitiesFound

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "No text provided for extraction"
        case .noEntitiesFound:
            return "No entities could be extracted from the text"
        }
    }
}

/// Service for extracting structured entities from OCR text
actor EntityExtractionService {

    // MARK: - Currency Regex Patterns

    /// Pattern for currency amounts: $1,234.56 or 1,234.56 USD/dollars
    private let currencyPatterns: [NSRegularExpression] = {
        let patterns = [
            // $1,234.56 or $1234.56 or $1,234
            #"\$[\d,]+\.?\d*"#,
            // 1,234.56 USD or 1234 USD
            #"[\d,]+\.?\d*\s*USD"#,
            // 1,234.56 dollars or 1234 dollars
            #"[\d,]+\.?\d*\s*dollars?"#,
            // USD 1,234.56
            #"USD\s*[\d,]+\.?\d*"#
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }()

    // MARK: - Public API

    /// Extract entities from text
    /// - Parameter text: The OCR text to process
    /// - Returns: Extracted entities with confidence scores
    func extractEntities(from text: String) async throws -> ExtractedEntities {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw ExtractionError.emptyText
        }

        // Run extractions concurrently
        async let organizations = extractOrganizations(from: trimmedText)
        async let dates = extractDates(from: trimmedText)
        async let amounts = extractCurrencyAmounts(from: trimmedText)

        let (orgs, extractedDates, extractedAmounts) = await (organizations, dates, amounts)

        // Calculate confidence based on extraction results
        let orgConfidence: Float = orgs.isEmpty ? 0 : min(1.0, Float(orgs.count) * 0.3 + 0.4)
        let dateConfidence: Float = extractedDates.isEmpty ? 0 : min(1.0, Float(extractedDates.count) * 0.3 + 0.5)
        let amountConfidence: Float = extractedAmounts.isEmpty ? 0 : min(1.0, Float(extractedAmounts.count) * 0.3 + 0.5)

        let confidence = ExtractionConfidence(
            organizationConfidence: orgConfidence,
            dateConfidence: dateConfidence,
            amountConfidence: amountConfidence
        )

        return ExtractedEntities(
            organizationName: orgs.first,
            dueDate: selectMostLikelyDueDate(from: extractedDates),
            amount: selectPrimaryAmount(from: extractedAmounts),
            allOrganizations: orgs,
            allDates: extractedDates,
            allAmounts: extractedAmounts,
            confidence: confidence
        )
    }

    /// Extract entities from OCR result
    /// - Parameter ocrResult: Result from DocumentOCRService
    /// - Returns: Extracted entities
    func extractEntities(from ocrResult: OCRDocumentResult) async throws -> ExtractedEntities {
        try await extractEntities(from: ocrResult.fullText)
    }

    // MARK: - Organization Extraction

    /// Extract organization names using NLTagger
    private func extractOrganizations(from text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text

        // Configure for organization detection with name joining
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]

        var organizations: [String] = []
        var seenNormalized: Set<String> = []

        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: options
        ) { tag, tokenRange in
            if tag == .organizationName {
                let orgName = String(text[tokenRange])
                let normalized = orgName.lowercased().trimmingCharacters(in: .whitespaces)

                // Deduplicate and filter very short names
                if normalized.count >= 2 && !seenNormalized.contains(normalized) {
                    seenNormalized.insert(normalized)
                    organizations.append(orgName)
                }
            }
            return true
        }

        return organizations
    }

    // MARK: - Date Extraction

    /// Extract dates using NSDataDetector
    private func extractDates(from text: String) -> [Date] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = detector.matches(in: text, options: [], range: range)

        var dates: [Date] = []
        let now = Date()
        let calendar = Calendar.current

        for match in matches {
            if let date = match.date {
                // Filter out dates that are too far in the past (>5 years)
                // or unreasonably far in the future (>10 years)
                let yearDifference = calendar.dateComponents([.year], from: now, to: date).year ?? 0
                if yearDifference >= -5 && yearDifference <= 10 {
                    dates.append(date)
                }
            }
        }

        // Sort by date
        return dates.sorted()
    }

    /// Select the most likely due date from extracted dates
    /// Prefers future dates, especially those within the next year
    private func selectMostLikelyDueDate(from dates: [Date]) -> Date? {
        guard !dates.isEmpty else { return nil }

        let now = Date()
        let futureDates = dates.filter { $0 > now }

        // Prefer the earliest future date (most likely a deadline)
        if let earliestFuture = futureDates.first {
            return earliestFuture
        }

        // Fall back to the most recent past date
        return dates.last
    }

    // MARK: - Currency Extraction

    /// Extract currency amounts using regex patterns
    private func extractCurrencyAmounts(from text: String) -> [Decimal] {
        var amounts: [Decimal] = []
        var seenValues: Set<Decimal> = []

        for pattern in currencyPatterns {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let matches = pattern.matches(in: text, options: [], range: range)

            for match in matches {
                if let matchRange = Range(match.range, in: text) {
                    let matchString = String(text[matchRange])
                    if let amount = parseAmount(from: matchString) {
                        // Deduplicate and filter unreasonable amounts
                        if amount > 0 && amount < 1_000_000_000_000 && !seenValues.contains(amount) {
                            seenValues.insert(amount)
                            amounts.append(amount)
                        }
                    }
                }
            }
        }

        // Sort by amount descending (larger amounts likely more significant)
        return amounts.sorted(by: >)
    }

    /// Parse a currency string into a Decimal
    private func parseAmount(from string: String) -> Decimal? {
        // Remove currency symbols and text
        var cleaned = string
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "USD", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "dollars", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "dollar", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)

        // Handle common OCR errors
        cleaned = cleaned.replacingOccurrences(of: "O", with: "0")
        cleaned = cleaned.replacingOccurrences(of: "l", with: "1")

        return Decimal(string: cleaned)
    }

    /// Select the primary amount from extracted amounts
    /// Typically the largest amount represents the total funding request
    private func selectPrimaryAmount(from amounts: [Decimal]) -> Decimal? {
        // Return the largest amount (already sorted descending)
        return amounts.first
    }
}

// MARK: - Extraction Pipeline

extension EntityExtractionService {

    /// Convenience method to process OCR text and return a pre-populated RFF document draft
    /// - Parameters:
    ///   - text: OCR extracted text
    ///   - title: Optional title override
    /// - Returns: Tuple of extracted entities and suggested document values
    func extractDocumentData(
        from text: String,
        title: String? = nil
    ) async throws -> (entities: ExtractedEntities, suggestedTitle: String) {
        let entities = try await extractEntities(from: text)

        // Generate a suggested title from the organization and amount
        let suggestedTitle: String
        if let org = entities.organizationName, let amount = entities.amount {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = "USD"
            let amountStr = formatter.string(from: amount as NSDecimalNumber) ?? "\(amount)"
            suggestedTitle = title ?? "RFF - \(org) - \(amountStr)"
        } else if let org = entities.organizationName {
            suggestedTitle = title ?? "RFF - \(org)"
        } else {
            suggestedTitle = title ?? "RFF - Untitled"
        }

        return (entities, suggestedTitle)
    }
}
