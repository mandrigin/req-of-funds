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
            #"[\d\s]+[,.]?\d*\s*SEK"#,             // 1 234,56 SEK
            #"SEK\s*[\d\s,]+[,.]?\d*"#,            // SEK 1 234,56
            #"[\d\s,]+[,.]?\d*\s*kronor"#          // 1 234,56 kronor
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
            #"[\d\s,]+[,.]?\d*\s*kroner"#          // 1 234,56 kroner
        ]
        for pattern in nokPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                patterns.append(CurrencyPattern(regex: regex, currency: .nok))
            }
        }

        // DKK patterns (Danish Krone)
        let dkkPatterns = [
            #"[\d\s]+[,.]?\d*\s*DKK"#,             // 1 234,56 DKK
            #"DKK\s*[\d\s,]+[,.]?\d*"#             // DKK 1 234,56
        ]
        for pattern in dkkPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                patterns.append(CurrencyPattern(regex: regex, currency: .dkk))
            }
        }

        // JPY patterns (Japanese Yen)
        let jpyPatterns = [
            #"¥[\d,]+\.?\d*"#,                     // ¥1,234
            #"[\d,]+\.?\d*\s*JPY"#,                // 1,234 JPY
            #"JPY\s*[\d,]+\.?\d*"#,                // JPY 1,234
            #"[\d,]+\.?\d*\s*yen"#                 // 1,234 yen
        ]
        for pattern in jpyPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                patterns.append(CurrencyPattern(regex: regex, currency: .jpy))
            }
        }

        // CNY patterns (Chinese Yuan)
        let cnyPatterns = [
            #"[\d,]+\.?\d*\s*CNY"#,                // 1,234.56 CNY
            #"CNY\s*[\d,]+\.?\d*"#,                // CNY 1,234.56
            #"[\d,]+\.?\d*\s*RMB"#,                // 1,234.56 RMB
            #"RMB\s*[\d,]+\.?\d*"#,                // RMB 1,234.56
            #"[\d,]+\.?\d*\s*元"#                  // 1,234.56 元
        ]
        for pattern in cnyPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                patterns.append(CurrencyPattern(regex: regex, currency: .cny))
            }
        }

        // CAD patterns (Canadian Dollar)
        let cadPatterns = [
            #"C\$[\d,]+\.?\d*"#,                   // C$1,234.56
            #"[\d,]+\.?\d*\s*CAD"#,                // 1,234.56 CAD
            #"CAD\s*[\d,]+\.?\d*"#                 // CAD 1,234.56
        ]
        for pattern in cadPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                patterns.append(CurrencyPattern(regex: regex, currency: .cad))
            }
        }

        // AUD patterns (Australian Dollar)
        let audPatterns = [
            #"A\$[\d,]+\.?\d*"#,                   // A$1,234.56
            #"[\d,]+\.?\d*\s*AUD"#,                // 1,234.56 AUD
            #"AUD\s*[\d,]+\.?\d*"#                 // AUD 1,234.56
        ]
        for pattern in audPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                patterns.append(CurrencyPattern(regex: regex, currency: .aud))
            }
        }

        // NZD patterns (New Zealand Dollar)
        let nzdPatterns = [
            #"NZ\$[\d,]+\.?\d*"#,                  // NZ$1,234.56
            #"[\d,]+\.?\d*\s*NZD"#,                // 1,234.56 NZD
            #"NZD\s*[\d,]+\.?\d*"#                 // NZD 1,234.56
        ]
        for pattern in nzdPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                patterns.append(CurrencyPattern(regex: regex, currency: .nzd))
            }
        }

        // HKD patterns (Hong Kong Dollar)
        let hkdPatterns = [
            #"HK\$[\d,]+\.?\d*"#,                  // HK$1,234.56
            #"[\d,]+\.?\d*\s*HKD"#,                // 1,234.56 HKD
            #"HKD\s*[\d,]+\.?\d*"#                 // HKD 1,234.56
        ]
        for pattern in hkdPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                patterns.append(CurrencyPattern(regex: regex, currency: .hkd))
            }
        }

        // SGD patterns (Singapore Dollar)
        let sgdPatterns = [
            #"S\$[\d,]+\.?\d*"#,                   // S$1,234.56
            #"[\d,]+\.?\d*\s*SGD"#,                // 1,234.56 SGD
            #"SGD\s*[\d,]+\.?\d*"#                 // SGD 1,234.56
        ]
        for pattern in sgdPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                patterns.append(CurrencyPattern(regex: regex, currency: .sgd))
            }
        }

        // PLN patterns (Polish Złoty)
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

        // CZK patterns (Czech Koruna)
        let czkPatterns = [
            #"[\d\s]+[,.]?\d*\s*Kč"#,              // 1 234,56 Kč
            #"[\d\s,]+[,.]?\d*\s*CZK"#,            // 1 234,56 CZK
            #"CZK\s*[\d\s,]+[,.]?\d*"#             // CZK 1 234,56
        ]
        for pattern in czkPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                patterns.append(CurrencyPattern(regex: regex, currency: .czk))
            }
        }

        // HUF patterns (Hungarian Forint)
        let hufPatterns = [
            #"[\d\s]+[,.]?\d*\s*Ft"#,              // 1 234 Ft
            #"[\d\s,]+[,.]?\d*\s*HUF"#,            // 1 234 HUF
            #"HUF\s*[\d\s,]+[,.]?\d*"#             // HUF 1 234
        ]
        for pattern in hufPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                patterns.append(CurrencyPattern(regex: regex, currency: .huf))
            }
        }

        // INR patterns (Indian Rupee)
        let inrPatterns = [
            #"₹[\d,]+\.?\d*"#,                     // ₹1,234.56
            #"[\d,]+\.?\d*\s*INR"#,                // 1,234.56 INR
            #"INR\s*[\d,]+\.?\d*"#,                // INR 1,234.56
            #"Rs\.?\s*[\d,]+\.?\d*"#               // Rs. 1,234.56
        ]
        for pattern in inrPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                patterns.append(CurrencyPattern(regex: regex, currency: .inr))
            }
        }

        // KRW patterns (South Korean Won)
        let krwPatterns = [
            #"₩[\d,]+\.?\d*"#,                     // ₩1,234
            #"[\d,]+\.?\d*\s*KRW"#,                // 1,234 KRW
            #"KRW\s*[\d,]+\.?\d*"#                 // KRW 1,234
        ]
        for pattern in krwPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                patterns.append(CurrencyPattern(regex: regex, currency: .krw))
            }
        }

        // MXN patterns (Mexican Peso)
        let mxnPatterns = [
            #"MX\$[\d,]+\.?\d*"#,                  // MX$1,234.56
            #"[\d,]+\.?\d*\s*MXN"#,                // 1,234.56 MXN
            #"MXN\s*[\d,]+\.?\d*"#                 // MXN 1,234.56
        ]
        for pattern in mxnPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                patterns.append(CurrencyPattern(regex: regex, currency: .mxn))
            }
        }

        // BRL patterns (Brazilian Real)
        let brlPatterns = [
            #"R\$[\d,]+\.?\d*"#,                   // R$1.234,56
            #"[\d,]+\.?\d*\s*BRL"#,                // 1.234,56 BRL
            #"BRL\s*[\d,]+\.?\d*"#                 // BRL 1.234,56
        ]
        for pattern in brlPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                patterns.append(CurrencyPattern(regex: regex, currency: .brl))
            }
        }

        // ZAR patterns (South African Rand)
        let zarPatterns = [
            #"[\d,]+\.?\d*\s*ZAR"#,                // 1,234.56 ZAR
            #"ZAR\s*[\d,]+\.?\d*"#                 // ZAR 1,234.56
        ]
        for pattern in zarPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                patterns.append(CurrencyPattern(regex: regex, currency: .zar))
            }
        }

        // RUB patterns (Russian Ruble)
        let rubPatterns = [
            #"₽[\d\s]+[,.]?\d*"#,                  // ₽1 234,56
            #"[\d\s,]+[,.]?\d*\s*RUB"#,            // 1 234,56 RUB
            #"RUB\s*[\d\s,]+[,.]?\d*"#,            // RUB 1 234,56
            #"[\d\s,]+[,.]?\d*\s*руб"#             // 1 234,56 руб
        ]
        for pattern in rubPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                patterns.append(CurrencyPattern(regex: regex, currency: .rub))
            }
        }

        // ILS patterns (Israeli Shekel)
        let ilsPatterns = [
            #"₪[\d,]+\.?\d*"#,                     // ₪1,234.56
            #"[\d,]+\.?\d*\s*ILS"#,                // 1,234.56 ILS
            #"ILS\s*[\d,]+\.?\d*"#,                // ILS 1,234.56
            #"[\d,]+\.?\d*\s*NIS"#                 // 1,234.56 NIS
        ]
        for pattern in ilsPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                patterns.append(CurrencyPattern(regex: regex, currency: .ils))
            }
        }

        // TRY patterns (Turkish Lira)
        let tryPatterns = [
            #"₺[\d,]+\.?\d*"#,                     // ₺1,234.56
            #"[\d,]+\.?\d*\s*TRY"#,                // 1,234.56 TRY
            #"TRY\s*[\d,]+\.?\d*"#,                // TRY 1,234.56
            #"[\d,]+\.?\d*\s*TL"#                  // 1,234.56 TL
        ]
        for pattern in tryPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                patterns.append(CurrencyPattern(regex: regex, currency: .try))
            }
        }

        // THB patterns (Thai Baht)
        let thbPatterns = [
            #"฿[\d,]+\.?\d*"#,                     // ฿1,234.56
            #"[\d,]+\.?\d*\s*THB"#,                // 1,234.56 THB
            #"THB\s*[\d,]+\.?\d*"#                 // THB 1,234.56
        ]
        for pattern in thbPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                patterns.append(CurrencyPattern(regex: regex, currency: .thb))
            }
        }

        // RON patterns (Romanian Leu)
        let ronPatterns = [
            #"[\d\s]+[,.]?\d*\s*lei"#,             // 1 234,56 lei
            #"[\d\s,]+[,.]?\d*\s*RON"#,            // 1 234,56 RON
            #"RON\s*[\d\s,]+[,.]?\d*"#             // RON 1 234,56
        ]
        for pattern in ronPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                patterns.append(CurrencyPattern(regex: regex, currency: .ron))
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
            .replacingOccurrences(of: "¥", with: "")
            .replacingOccurrences(of: "₹", with: "")
            .replacingOccurrences(of: "₩", with: "")
            .replacingOccurrences(of: "₽", with: "")
            .replacingOccurrences(of: "₪", with: "")
            .replacingOccurrences(of: "₺", with: "")
            .replacingOccurrences(of: "฿", with: "")
            .replacingOccurrences(of: "₱", with: "")
            // Remove currency codes (ISO 4217)
            .replacingOccurrences(of: "USD", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "EUR", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "GBP", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "CHF", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "SFr.", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "Fr.", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "SEK", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "NOK", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "DKK", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "JPY", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "CNY", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "RMB", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "CAD", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "AUD", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "NZD", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "HKD", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "SGD", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "PLN", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "CZK", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "HUF", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "RON", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "INR", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "KRW", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "THB", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "MXN", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "BRL", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "ZAR", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "RUB", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "ILS", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "NIS", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "TRY", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "TL", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "IDR", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "MYR", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "PHP", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "TWD", with: "", options: .caseInsensitive)
            // Remove currency symbols (text-based)
            .replacingOccurrences(of: "kr", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "zł", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "Kč", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "Ft", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "lei", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "Rs.", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "Rs", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "RM", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "Rp", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "руб", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "元", with: "", options: .caseInsensitive)
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
            .replacingOccurrences(of: "yen", with: "", options: .caseInsensitive)
            // Remove whitespace
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespaces)

        // Handle Swiss number format (1'234.56) - apostrophe as thousands separator
        if currency == .chf {
            cleaned = cleaned.replacingOccurrences(of: "'", with: "")
            cleaned = cleaned.replacingOccurrences(of: ",", with: "")
        }
        // Handle European number format (1.234,56) for currencies that use comma as decimal
        else if usesCommaDecimal(currency) && cleaned.contains(",") {
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
                    // Only comma - assume it's decimal separator
                    cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
                }
            }
        } else {
            // USD/GBP and others use comma as thousand separator
            cleaned = cleaned.replacingOccurrences(of: ",", with: "")
        }

        // Handle common OCR errors
        cleaned = cleaned.replacingOccurrences(of: "O", with: "0")
        cleaned = cleaned.replacingOccurrences(of: "l", with: "1")

        return Decimal(string: cleaned)
    }

    /// Check if currency uses comma as decimal separator (European format)
    private func usesCommaDecimal(_ currency: Currency) -> Bool {
        switch currency {
        // European currencies typically use comma as decimal separator
        case .eur, .sek, .nok, .dkk, .pln, .czk, .huf, .ron, .rub, .brl:
            return true
        // These use dot as decimal separator
        case .usd, .gbp, .chf, .jpy, .cny, .cad, .aud, .nzd, .hkd, .sgd, .inr, .krw, .thb, .mxn, .zar, .ils, .try, .idr, .myr, .php, .twd:
            return false
        }
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
