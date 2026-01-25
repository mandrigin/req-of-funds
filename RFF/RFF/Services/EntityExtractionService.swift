import Foundation
import NaturalLanguage

/// Extracted amount with currency
struct ExtractedCurrencyAmount: Sendable {
    let value: Decimal
    let currency: Currency
}

/// Extracted entities from document text
struct ExtractedEntities: Sendable {
    /// Organization name (requestor)
    let organizationName: String?

    /// Due date found in document
    let dueDate: Date?

    /// Monetary amount
    let amount: Decimal?

    /// Currency for the amount
    let currency: Currency?

    /// All organization names found
    let allOrganizations: [String]

    /// All dates found
    let allDates: [Date]

    /// All currency amounts found with their currencies
    let allAmounts: [ExtractedCurrencyAmount]

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

    /// Currency pattern with associated currency type
    private struct CurrencyPattern {
        let regex: NSRegularExpression
        let currency: Currency
    }

    /// All currency patterns grouped by currency
    private let currencyPatterns: [CurrencyPattern] = {
        var patterns: [CurrencyPattern] = []

        // USD patterns
        let usdPatterns = [
            #"\$[\d,]+\.?\d*"#,                    // $1,234.56
            #"[\d,]+\.?\d*\s*USD"#,                // 1,234.56 USD
            #"USD\s*[\d,]+\.?\d*"#,                // USD 1,234.56
            #"[\d,]+\.?\d*\s*dollars?"#            // 1,234.56 dollars
        ]
        for pattern in usdPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                patterns.append(CurrencyPattern(regex: regex, currency: .usd))
            }
        }

        // EUR patterns
        let eurPatterns = [
            #"€[\d,\s]+[.,]?\d*"#,                 // €1.234,56 or €1,234.56
            #"[\d,\s]+[.,]?\d*\s*€"#,              // 1.234,56 € or 1,234.56 €
            #"[\d,]+\.?\d*\s*EUR"#,                // 1,234.56 EUR
            #"EUR\s*[\d,]+\.?\d*"#,                // EUR 1,234.56
            #"[\d,]+\.?\d*\s*euros?"#              // 1,234.56 euros
        ]
        for pattern in eurPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                patterns.append(CurrencyPattern(regex: regex, currency: .eur))
            }
        }

        // GBP patterns
        let gbpPatterns = [
            #"£[\d,]+\.?\d*"#,                     // £1,234.56
            #"[\d,]+\.?\d*\s*£"#,                  // 1,234.56 £
            #"[\d,]+\.?\d*\s*GBP"#,                // 1,234.56 GBP
            #"GBP\s*[\d,]+\.?\d*"#,                // GBP 1,234.56
            #"[\d,]+\.?\d*\s*pounds?"#             // 1,234.56 pounds
        ]
        for pattern in gbpPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                patterns.append(CurrencyPattern(regex: regex, currency: .gbp))
            }
        }

        return patterns
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

        let primaryAmount = selectPrimaryAmount(from: extractedAmounts)

        return ExtractedEntities(
            organizationName: orgs.first,
            dueDate: selectMostLikelyDueDate(from: extractedDates),
            amount: primaryAmount?.value,
            currency: primaryAmount?.currency,
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
    private func extractCurrencyAmounts(from text: String) -> [ExtractedCurrencyAmount] {
        var amounts: [ExtractedCurrencyAmount] = []

        // Key for deduplication: value + currency
        struct AmountKey: Hashable {
            let value: Decimal
            let currency: Currency
        }
        var seenAmounts: Set<AmountKey> = []

        for currencyPattern in currencyPatterns {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let matches = currencyPattern.regex.matches(in: text, options: [], range: range)

            for match in matches {
                if let matchRange = Range(match.range, in: text) {
                    let matchString = String(text[matchRange])
                    if let value = parseAmount(from: matchString, currency: currencyPattern.currency) {
                        let key = AmountKey(value: value, currency: currencyPattern.currency)
                        // Deduplicate and filter unreasonable amounts
                        if value > 0 && value < 1_000_000_000_000 && !seenAmounts.contains(key) {
                            seenAmounts.insert(key)
                            amounts.append(ExtractedCurrencyAmount(value: value, currency: currencyPattern.currency))
                        }
                    }
                }
            }
        }

        // Sort by amount descending (larger amounts likely more significant)
        return amounts.sorted { $0.value > $1.value }
    }

    /// Parse a currency string into a Decimal
    private func parseAmount(from string: String, currency: Currency) -> Decimal? {
        // Remove currency symbols and text
        var cleaned = string
            // Remove currency symbols
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: "£", with: "")
            // Remove currency codes
            .replacingOccurrences(of: "USD", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "EUR", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "GBP", with: "", options: .caseInsensitive)
            // Remove currency words
            .replacingOccurrences(of: "dollars", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "dollar", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "euros", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "euro", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "pounds", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "pound", with: "", options: .caseInsensitive)
            // Remove whitespace
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespaces)

        // Handle European number format (1.234,56) for EUR
        if currency == .eur && cleaned.contains(",") {
            let lastComma = cleaned.lastIndex(of: ",")
            let lastDot = cleaned.lastIndex(of: ".")

            if let commaIdx = lastComma {
                if let dotIdx = lastDot {
                    // Both present - comma after dot means European format
                    if commaIdx > dotIdx {
                        // European: 1.234,56 -> remove dots, replace comma with dot
                        cleaned = cleaned.replacingOccurrences(of: ".", with: "")
                        cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
                    } else {
                        // American: 1,234.56 -> just remove commas
                        cleaned = cleaned.replacingOccurrences(of: ",", with: "")
                    }
                } else {
                    // Only comma - assume it's decimal separator for EUR
                    cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
                }
            }
        } else {
            // USD/GBP use comma as thousand separator
            cleaned = cleaned.replacingOccurrences(of: ",", with: "")
        }

        // Handle common OCR errors
        cleaned = cleaned.replacingOccurrences(of: "O", with: "0")
        cleaned = cleaned.replacingOccurrences(of: "l", with: "1")

        return Decimal(string: cleaned)
    }

    /// Select the primary amount from extracted amounts
    /// Typically the largest amount represents the total funding request
    private func selectPrimaryAmount(from amounts: [ExtractedCurrencyAmount]) -> ExtractedCurrencyAmount? {
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
            formatter.currencyCode = entities.currency?.currencyCode ?? "USD"
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
