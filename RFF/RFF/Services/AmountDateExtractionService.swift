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

        // SEK patterns (Swedish Krona)
        // Swedish format: 1 234,56 kr or 1234,56 SEK
        let sekPatterns = [
            #"[\d\s]+[,.]?\d*\s*kr"#,              // 1 234,56 kr
            #"[\d\s,]+[,.]?\d*\s*SEK"#,            // 1 234,56 SEK
            #"SEK\s*[\d\s,]+[,.]?\d*"#,            // SEK 1 234,56
            #"[\d\s,]+[,.]?\d*\s*kronor"#          // 1 234 kronor
        ]
        for pattern in sekPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                patterns.append(CurrencyPattern(regex: regex, currency: .sek))
            }
        }

        // NOK patterns (Norwegian Krone)
        let nokPatterns = [
            #"[\d\s]+[,.]?\d*\s*NOK"#,             // 1 234,56 NOK
            #"NOK\s*[\d\s,]+[,.]?\d*"#,            // NOK 1 234,56
            #"[\d\s,]+[,.]?\d*\s*kroner"#          // 1 234 kroner (Norwegian)
        ]
        for pattern in nokPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                patterns.append(CurrencyPattern(regex: regex, currency: .nok))
            }
        }

        // DKK patterns (Danish Krone)
        let dkkPatterns = [
            #"[\d\s.,]+[,.]?\d*\s*DKK"#,           // 1.234,56 DKK
            #"DKK\s*[\d\s.,]+[,.]?\d*"#,           // DKK 1.234,56
        ]
        for pattern in dkkPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                patterns.append(CurrencyPattern(regex: regex, currency: .dkk))
            }
        }

        // JPY patterns (Japanese Yen)
        let jpyPatterns = [
            #"¥[\d,]+\.?\d*"#,                     // ¥1,234
            #"[\d,]+\.?\d*\s*円"#,                 // 1,234円
            #"[\d,]+\.?\d*\s*JPY"#,                // 1,234 JPY
            #"JPY\s*[\d,]+\.?\d*"#,                // JPY 1,234
            #"[\d,]+\.?\d*\s*yen"#                 // 1,234 yen
        ]
        for pattern in jpyPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                patterns.append(CurrencyPattern(regex: regex, currency: .jpy))
            }
        }

        // CAD patterns (Canadian Dollar)
        let cadPatterns = [
            #"C\$[\d,]+\.?\d*"#,                   // C$1,234.56
            #"CAD\s*[\d,]+\.?\d*"#,                // CAD 1,234.56
            #"[\d,]+\.?\d*\s*CAD"#                 // 1,234.56 CAD
        ]
        for pattern in cadPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                patterns.append(CurrencyPattern(regex: regex, currency: .cad))
            }
        }

        // AUD patterns (Australian Dollar)
        let audPatterns = [
            #"A\$[\d,]+\.?\d*"#,                   // A$1,234.56
            #"AUD\s*[\d,]+\.?\d*"#,                // AUD 1,234.56
            #"[\d,]+\.?\d*\s*AUD"#                 // 1,234.56 AUD
        ]
        for pattern in audPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                patterns.append(CurrencyPattern(regex: regex, currency: .aud))
            }
        }

        // CNY patterns (Chinese Yuan)
        let cnyPatterns = [
            #"[\d,]+\.?\d*\s*元"#,                 // 1,234.56元
            #"[\d,]+\.?\d*\s*CNY"#,                // 1,234.56 CNY
            #"CNY\s*[\d,]+\.?\d*"#,                // CNY 1,234.56
            #"[\d,]+\.?\d*\s*RMB"#,                // 1,234.56 RMB
            #"RMB\s*[\d,]+\.?\d*"#                 // RMB 1,234.56
        ]
        for pattern in cnyPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                patterns.append(CurrencyPattern(regex: regex, currency: .cny))
            }
        }

        // INR patterns (Indian Rupee)
        let inrPatterns = [
            #"₹[\d,]+\.?\d*"#,                     // ₹1,23,456.78
            #"Rs\.?\s*[\d,]+\.?\d*"#,              // Rs. 1,23,456.78
            #"[\d,]+\.?\d*\s*INR"#,                // 1,23,456.78 INR
            #"INR\s*[\d,]+\.?\d*"#                 // INR 1,23,456.78
        ]
        for pattern in inrPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                patterns.append(CurrencyPattern(regex: regex, currency: .inr))
            }
        }

        // PLN patterns (Polish Zloty)
        let plnPatterns = [
            #"[\d\s]+[,.]?\d*\s*zł"#,              // 1 234,56 zł
            #"[\d\s,]+[,.]?\d*\s*PLN"#,            // 1 234,56 PLN
            #"PLN\s*[\d\s,]+[,.]?\d*"#             // PLN 1 234,56
        ]
        for pattern in plnPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                patterns.append(CurrencyPattern(regex: regex, currency: .pln))
            }
        }

        // BRL patterns (Brazilian Real)
        let brlPatterns = [
            #"R\$\s*[\d.,]+[,.]?\d*"#,             // R$ 1.234,56
            #"[\d.,]+[,.]?\d*\s*BRL"#,             // 1.234,56 BRL
            #"BRL\s*[\d.,]+[,.]?\d*"#              // BRL 1.234,56
        ]
        for pattern in brlPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                patterns.append(CurrencyPattern(regex: regex, currency: .brl))
            }
        }

        // MXN patterns (Mexican Peso)
        let mxnPatterns = [
            #"[\d,]+\.?\d*\s*MXN"#,                // 1,234.56 MXN
            #"MXN\s*[\d,]+\.?\d*"#,                // MXN 1,234.56
            #"MX\$[\d,]+\.?\d*"#                   // MX$1,234.56
        ]
        for pattern in mxnPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                patterns.append(CurrencyPattern(regex: regex, currency: .mxn))
            }
        }

        return patterns
    }()

    /// Get favorite currencies from user settings
    private static func getFavoriteCurrencies() -> [Currency] {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: "favoriteCurrencies"),
              let codes = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return codes.compactMap { Currency(rawValue: $0) }
    }

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
            .replacingOccurrences(of: "¥", with: "")
            .replacingOccurrences(of: "₹", with: "")
            .replacingOccurrences(of: "₩", with: "")
            .replacingOccurrences(of: "₽", with: "")
            .replacingOccurrences(of: "₺", with: "")
            .replacingOccurrences(of: "₱", with: "")
            .replacingOccurrences(of: "₫", with: "")
            .replacingOccurrences(of: "₦", with: "")
            .replacingOccurrences(of: "₪", with: "")
            // Remove currency codes (alphabetically)
            .replacingOccurrences(of: "AUD", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "BRL", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "CAD", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "CHF", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "CNY", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "DKK", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "EUR", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "GBP", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "INR", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "JPY", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "MXN", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "NOK", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "PLN", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "RMB", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "SEK", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "USD", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "SFr.", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "Fr.", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "Rs.", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "Rs", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "R$", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "C$", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "A$", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "MX$", with: "", options: .caseInsensitive)
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
            .replacingOccurrences(of: "kronor", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "kroner", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "kr", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "yen", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "円", with: "")
            .replacingOccurrences(of: "元", with: "")
            .replacingOccurrences(of: "zł", with: "", options: .caseInsensitive)
            // Remove whitespace
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespaces)

        // Handle Swiss number format (1'234.56) - apostrophe as thousands separator
        if currency == .chf {
            cleaned = cleaned.replacingOccurrences(of: "'", with: "")
            cleaned = cleaned.replacingOccurrences(of: ",", with: "")
        }
        // Handle Nordic/European number format (1 234,56 or 1.234,56)
        // SEK, NOK, DKK, PLN, EUR, BRL use comma as decimal separator
        else if [.sek, .nok, .dkk, .pln, .eur, .brl].contains(currency) && cleaned.contains(",") {
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
                    // Only comma - assume it's decimal separator for these currencies
                    cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
                }
            }
        } else {
            // USD/GBP/CAD/AUD/JPY/CNY/INR use comma as thousand separator
            cleaned = cleaned.replacingOccurrences(of: ",", with: "")
        }

        // Handle common OCR errors
        cleaned = cleaned.replacingOccurrences(of: "O", with: "0")
        cleaned = cleaned.replacingOccurrences(of: "l", with: "1")

        return Decimal(string: cleaned)
    }

    /// Deduplicate amounts keeping highest confidence for each value+currency combination
    /// Prefers favorite currencies when the same amount is detected in multiple currencies
    private func deduplicateAmounts(_ amounts: [ExtractedAmount]) -> [ExtractedAmount] {
        let favorites = Self.getFavoriteCurrencies()

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

        // If the same numeric value appears with different currencies,
        // prefer favorite currencies over non-favorites
        var byValue: [Decimal: [ExtractedAmount]] = [:]
        for amount in seen.values {
            byValue[amount.value, default: []].append(amount)
        }

        var result: [ExtractedAmount] = []
        for (_, amountsWithSameValue) in byValue {
            if amountsWithSameValue.count == 1 {
                result.append(amountsWithSameValue[0])
            } else {
                // Multiple currencies for same value - prefer favorites
                let favoriteAmounts = amountsWithSameValue.filter { favorites.contains($0.currency) }
                if !favoriteAmounts.isEmpty {
                    // Use the favorite with highest confidence
                    if let best = favoriteAmounts.max(by: { $0.confidence < $1.confidence }) {
                        result.append(best)
                    }
                } else {
                    // No favorites match - keep highest confidence
                    if let best = amountsWithSameValue.max(by: { $0.confidence < $1.confidence }) {
                        result.append(best)
                    }
                }
            }
        }

        return result
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
            if let matchRange = Range(match.range, in: text) {
                let rawText = String(text[matchRange])

                // For dot-separated dates, use smart parsing to handle European format
                // NSDataDetector may incorrectly parse DD.MM.YYYY as MM.DD.YYYY
                let parsedDate: Date?
                if rawText.contains(".") {
                    parsedDate = DateParsingUtility.parseDotSeparatedDate(rawText)
                } else {
                    parsedDate = match.date
                }

                guard let date = parsedDate else { continue }

                // Filter dates within reasonable range (-5 to +10 years)
                let yearDiff = calendar.dateComponents([.year], from: now, to: date).year ?? 0
                if yearDiff >= -5 && yearDiff <= 10 {
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
