import Foundation

// MARK: - Extracted Data Types

/// An extracted amount with its source location
struct ExtractedAmount: Sendable, Identifiable {
    let id: UUID
    let value: Decimal
    let currency: Currency
    let rawText: String
    let confidence: Float
    let boundingBox: CGRect

    init(value: Decimal, currency: Currency = .usd, rawText: String, confidence: Float, boundingBox: CGRect) {
        self.id = UUID()
        self.value = value
        self.currency = currency
        self.rawText = rawText
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

/// An extracted date with its source location
struct ExtractedDate: Sendable, Identifiable {
    let id: UUID
    let date: Date
    let rawText: String
    let confidence: Float
    let boundingBox: CGRect

    init(date: Date, rawText: String, confidence: Float, boundingBox: CGRect) {
        self.id = UUID()
        self.date = date
        self.rawText = rawText
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

/// Result of amount and date extraction with bounding box references
struct ExtractedData: Sendable {
    /// All extracted monetary amounts with locations
    let amounts: [ExtractedAmount]

    /// All extracted dates with locations
    let dates: [ExtractedDate]

    /// Primary (most likely total) amount
    var primaryAmount: ExtractedAmount? {
        // Prefer the largest amount as the total
        amounts.max(by: { $0.value < $1.value })
    }

    /// Primary (most likely due) date
    var primaryDate: ExtractedDate? {
        // Prefer the earliest future date
        let now = Date()
        let futureDates = dates.filter { $0.date > now }
        return futureDates.min(by: { $0.date < $1.date }) ?? dates.first
    }

    /// Overall confidence score
    var overallConfidence: Float {
        let scores = amounts.map(\.confidence) + dates.map(\.confidence)
        guard !scores.isEmpty else { return 0 }
        return scores.reduce(0, +) / Float(scores.count)
    }
}

// MARK: - Extraction Service

/// Service for extracting amounts and dates from OCR observations while preserving bounding boxes
actor AmountDateExtractionService {

    // MARK: - Currency Patterns

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

        // CHF patterns (Swiss Franc)
        // Swiss format uses apostrophe as thousands separator: 1'234.56
        // Some OCR outputs use spaces: 2 605.25
        let chfPatterns = [
            #"CHF\s*[\d'\s.,]+\.\d{2}"#,           // CHF 1'234.56 or CHF 2 605.25
            #"[\d'\s.,]+\.\d{2}\s*CHF"#,           // 1'234.56 CHF or 2 605.25 CHF
            #"Fr\.\s*[\d'\s.,]+\.\d{2}"#,          // Fr. 1'234.56
            #"SFr\.\s*[\d'\s.,]+\.\d{2}"#,         // SFr. 1'234.56
            #"[\d'.,]+\.?\d*\s*(?:francs?|Franken)"# // 1'234.56 francs/Franken
        ]
        for pattern in chfPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                patterns.append(CurrencyPattern(regex: regex, currency: .chf))
            }
        }

        return patterns
    }()

    // MARK: - Public API

    /// Extract amounts and dates from OCR page result
    /// - Parameter pageResult: OCR result with text observations
    /// - Returns: Extracted data with bounding box references
    func extract(from pageResult: OCRPageResult) async -> ExtractedData {
        var amounts: [ExtractedAmount] = []
        var dates: [ExtractedDate] = []

        for observation in pageResult.observations {
            // Extract amounts from this observation
            let extractedAmounts = extractAmounts(from: observation)
            amounts.append(contentsOf: extractedAmounts)

            // Extract dates from this observation
            let extractedDates = extractDates(from: observation)
            dates.append(contentsOf: extractedDates)
        }

        // Deduplicate amounts by value (keep highest confidence)
        amounts = deduplicateAmounts(amounts)

        // Sort amounts by value descending
        amounts.sort { $0.value > $1.value }

        // Sort dates chronologically
        dates.sort { $0.date < $1.date }

        return ExtractedData(amounts: amounts, dates: dates)
    }

    /// Extract amounts and dates from entire document result
    /// - Parameter documentResult: OCR result for all pages
    /// - Returns: Extracted data with bounding box references
    func extract(from documentResult: OCRDocumentResult) async -> ExtractedData {
        var allAmounts: [ExtractedAmount] = []
        var allDates: [ExtractedDate] = []

        for page in documentResult.pages {
            let pageData = await extract(from: page)
            allAmounts.append(contentsOf: pageData.amounts)
            allDates.append(contentsOf: pageData.dates)
        }

        // Deduplicate across pages
        allAmounts = deduplicateAmounts(allAmounts)
        allAmounts.sort { $0.value > $1.value }
        allDates.sort { $0.date < $1.date }

        return ExtractedData(amounts: allAmounts, dates: allDates)
    }

    // MARK: - Amount Extraction

    /// Extract amounts from a single text observation
    private func extractAmounts(from observation: TextObservation) -> [ExtractedAmount] {
        let text = observation.text
        var amounts: [ExtractedAmount] = []
        let range = NSRange(text.startIndex..<text.endIndex, in: text)

        // Try each currency pattern
        for currencyPattern in currencyPatterns {
            let matches = currencyPattern.regex.matches(in: text, options: [], range: range)

            for match in matches {
                if let matchRange = Range(match.range, in: text) {
                    let matchString = String(text[matchRange])
                    if let value = parseAmount(from: matchString, currency: currencyPattern.currency) {
                        // Filter unreasonable amounts
                        if value > 0 && value < 1_000_000_000_000 {
                            let amount = ExtractedAmount(
                                value: value,
                                currency: currencyPattern.currency,
                                rawText: matchString,
                                confidence: observation.confidence,
                                boundingBox: observation.boundingBox
                            )
                            amounts.append(amount)
                        }
                    }
                }
            }
        }

        return amounts
    }

    /// Parse currency string into Decimal
    private func parseAmount(from string: String, currency: Currency) -> Decimal? {
        var cleaned = string
            // Remove currency symbols
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: "£", with: "")
            // Remove currency codes
            .replacingOccurrences(of: "USD", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "EUR", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "GBP", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "CHF", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "SFr.", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "Fr.", with: "", options: .caseInsensitive)
            // Remove currency words
            .replacingOccurrences(of: "dollars", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "dollar", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "euros", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "euro", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "pounds", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "pound", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "francs", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "franc", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "Franken", with: "", options: .caseInsensitive)
            // Remove whitespace
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespaces)

        // Handle Swiss number format (1'234.56) - apostrophe as thousands separator
        if currency == .chf {
            cleaned = cleaned.replacingOccurrences(of: "'", with: "")
            cleaned = cleaned.replacingOccurrences(of: ",", with: "")
        }
        // Handle European number format (1.234,56) for EUR
        else if currency == .eur && cleaned.contains(",") {
            // Check if it's European format: has comma as decimal separator
            // European: 1.234,56 -> 1234.56
            // American: 1,234.56 -> 1234.56
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

    /// Deduplicate amounts keeping highest confidence for each value+currency combination
    private func deduplicateAmounts(_ amounts: [ExtractedAmount]) -> [ExtractedAmount] {
        // Key by both value and currency to avoid deduplicating different currencies
        struct AmountKey: Hashable {
            let value: Decimal
            let currency: Currency
        }

        var seen: [AmountKey: ExtractedAmount] = [:]

        for amount in amounts {
            let key = AmountKey(value: amount.value, currency: amount.currency)
            if let existing = seen[key] {
                if amount.confidence > existing.confidence {
                    seen[key] = amount
                }
            } else {
                seen[key] = amount
            }
        }

        return Array(seen.values)
    }

    // MARK: - Date Extraction

    /// Extract dates from a single text observation
    private func extractDates(from observation: TextObservation) -> [ExtractedDate] {
        let text = observation.text
        var dates: [ExtractedDate] = []

        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = detector.matches(in: text, options: [], range: range)

        let now = Date()
        let calendar = Calendar.current

        for match in matches {
            if let date = match.date,
               let matchRange = Range(match.range, in: text) {
                // Filter dates within reasonable range (-5 to +10 years)
                let yearDiff = calendar.dateComponents([.year], from: now, to: date).year ?? 0
                if yearDiff >= -5 && yearDiff <= 10 {
                    let rawText = String(text[matchRange])
                    let extractedDate = ExtractedDate(
                        date: date,
                        rawText: rawText,
                        confidence: observation.confidence,
                        boundingBox: observation.boundingBox
                    )
                    dates.append(extractedDate)
                }
            }
        }

        return dates
    }
}
