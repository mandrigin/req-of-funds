import Foundation

// MARK: - Extracted Data Types

/// An extracted amount with its source location
struct ExtractedAmount: Sendable, Identifiable {
    let id: UUID
    let value: Decimal
    let rawText: String
    let confidence: Float
    let boundingBox: CGRect

    init(value: Decimal, rawText: String, confidence: Float, boundingBox: CGRect) {
        self.id = UUID()
        self.value = value
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

    /// Pattern for USD amounts: $1,234.56
    private let dollarSignPattern = try! NSRegularExpression(
        pattern: #"\$[\d,]+\.?\d*"#,
        options: []
    )

    /// Pattern for amounts with USD suffix: 1,234.56 USD
    private let usdSuffixPattern = try! NSRegularExpression(
        pattern: #"[\d,]+\.?\d*\s*USD"#,
        options: .caseInsensitive
    )

    /// Pattern for USD prefix: USD 1,234.56
    private let usdPrefixPattern = try! NSRegularExpression(
        pattern: #"USD\s*[\d,]+\.?\d*"#,
        options: .caseInsensitive
    )

    /// Pattern for "dollars": 1,234.56 dollars
    private let dollarsPattern = try! NSRegularExpression(
        pattern: #"[\d,]+\.?\d*\s*dollars?"#,
        options: .caseInsensitive
    )

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

        // Try each pattern
        let patterns = [dollarSignPattern, usdSuffixPattern, usdPrefixPattern, dollarsPattern]

        for pattern in patterns {
            let matches = pattern.matches(in: text, options: [], range: range)

            for match in matches {
                if let matchRange = Range(match.range, in: text) {
                    let matchString = String(text[matchRange])
                    if let value = parseAmount(from: matchString) {
                        // Filter unreasonable amounts
                        if value > 0 && value < 1_000_000_000_000 {
                            let amount = ExtractedAmount(
                                value: value,
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
    private func parseAmount(from string: String) -> Decimal? {
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

    /// Deduplicate amounts keeping highest confidence for each value
    private func deduplicateAmounts(_ amounts: [ExtractedAmount]) -> [ExtractedAmount] {
        var seen: [Decimal: ExtractedAmount] = [:]

        for amount in amounts {
            if let existing = seen[amount.value] {
                if amount.confidence > existing.confidence {
                    seen[amount.value] = amount
                }
            } else {
                seen[amount.value] = amount
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
