import Foundation

// MARK: - Invoice Classification Result

/// Result of invoice classification
struct InvoiceClassification {
    /// Whether the document is classified as an invoice
    let isInvoice: Bool

    /// Confidence score (0.0-1.0)
    let confidence: Float

    /// Keywords that matched during classification
    let keywordMatches: [KeywordMatch]

    /// Structure patterns detected in the document
    let detectedPatterns: [String]
}

// MARK: - Keyword Category

/// Categories for invoice keyword classification
private enum KeywordCategory: String {
    case primary = "primary"
    case secondary = "secondary"
    case financial = "financial"
    case payment = "payment"
    case reference = "reference"
    case negative = "negative"

    var weight: Float {
        switch self {
        case .primary: return 3.0
        case .secondary: return 2.0
        case .financial: return 1.5
        case .payment: return 1.0
        case .reference: return 1.5
        case .negative: return -2.0
        }
    }
}

// MARK: - Structure Pattern

/// Structure patterns detected in documents
private enum StructurePattern: String, CaseIterable {
    case invoiceNumber = "invoiceNumber"
    case currencyAmount = "currencyAmount"
    case datePattern = "datePattern"
    case taxIdPattern = "taxIdPattern"
    case lineItems = "lineItems"

    var scoreBoost: Float {
        switch self {
        case .invoiceNumber: return 0.15
        case .currencyAmount: return 0.10
        case .datePattern: return 0.05
        case .taxIdPattern: return 0.10
        case .lineItems: return 0.15
        }
    }
}

// MARK: - Invoice Classifier

/// Classifies documents as invoices based on keyword and structure analysis
///
/// Implementation per spec section 3.3:
/// - Two-stage classification: keyword scoring + structure scoring
/// - Keyword taxonomy with weighted categories
/// - Structure pattern detection with score boosts
/// - Normalized confidence score (0.0-1.0)
final class InvoiceClassifier {

    // MARK: - Keyword Taxonomy

    /// Keyword taxonomy per spec section 3.3
    private static let keywordTaxonomy: [(category: KeywordCategory, keywords: [String])] = [
        // Primary identifiers (weight: 3.0)
        (.primary, [
            "invoice",
            "tax invoice",
            "rechnung",      // German
            "facture",       // French
            "factura"        // Spanish/Italian
        ]),

        // Secondary identifiers (weight: 2.0)
        (.secondary, [
            "bill",
            "receipt",
            "statement",
            "credit note",
            "debit note"
        ]),

        // Financial terms (weight: 1.5)
        (.financial, [
            "subtotal",
            "sub-total",
            "total",
            "tax",
            "vat",
            "gst",
            "amount due",
            "balance due"
        ]),

        // Payment terms (weight: 1.0)
        (.payment, [
            "due date",
            "payment terms",
            "net 30",
            "net 60",
            "pay by",
            "payment due"
        ]),

        // Reference fields (weight: 1.5)
        (.reference, [
            "invoice #",
            "invoice no",
            "invoice number",
            "inv #",
            "inv no",
            "bill to",
            "ship to",
            "sold to",
            "billed to"
        ]),

        // Negative signals (weight: -2.0)
        (.negative, [
            "quote",
            "estimate",
            "proposal",
            "draft",
            "proforma",
            "pro forma",
            "quotation"
        ])
    ]

    /// Maximum possible positive score from keywords
    private static let maxPositiveKeywordScore: Float = {
        keywordTaxonomy
            .filter { $0.category != .negative }
            .reduce(0) { $0 + $1.category.weight }
    }()

    // MARK: - Regex Patterns

    /// Invoice number pattern: (invoice|inv)[\s#:]*([A-Z0-9-]{3,20})
    private static let invoiceNumberPattern = try! NSRegularExpression(
        pattern: #"(?:invoice|inv)[\s#:\-]*([A-Z0-9\-]{3,20})"#,
        options: [.caseInsensitive]
    )

    /// InvoiceCurrency amount pattern: [$€£¥]\s*[\d,]+\.?\d{0,2} or [\d,]+\.?\d{2}\s*(USD|EUR|GBP)
    private static let currencyAmountPattern = try! NSRegularExpression(
        pattern: #"(?:[$€£¥]\s*[\d,]+\.?\d{0,2})|(?:[\d,]+\.\d{2}\s*(?:USD|EUR|GBP|CAD|AUD|CHF))"#,
        options: [.caseInsensitive]
    )

    /// Date pattern: \d{1,2}[\/\-\.]\d{1,2}[\/\-\.]\d{2,4}
    private static let datePattern = try! NSRegularExpression(
        pattern: #"\d{1,2}[\/\-\.]\d{1,2}[\/\-\.]\d{2,4}"#,
        options: []
    )

    /// Tax ID patterns (EIN, VAT)
    private static let taxIdPattern = try! NSRegularExpression(
        pattern: #"(?:\d{2}[-]?\d{7})|(?:VAT[\s:]*[A-Z]{2}\d+)|(?:EIN[\s:]*\d{2}[-]?\d{7})"#,
        options: [.caseInsensitive]
    )

    /// Line items pattern: quantity × price pattern (e.g., "2 x $50.00" or "Qty: 5 @ 10.00")
    private static let lineItemsPattern = try! NSRegularExpression(
        pattern: #"(?:\d+\s*[x×@]\s*[$€£¥]?\s*[\d,]+\.?\d{0,2})|(?:qty[:\s]*\d+)"#,
        options: [.caseInsensitive]
    )

    // MARK: - Properties

    /// Confidence threshold for classification
    private let threshold: Float

    // MARK: - Initialization

    /// Create a classifier with the given threshold
    /// - Parameter threshold: Minimum confidence to classify as invoice (default: 0.7)
    init(threshold: Float = 0.7) {
        self.threshold = threshold
    }

    /// Create a classifier from the current app configuration
    static func fromConfig() -> InvoiceClassifier {
        let config = ConfigManager.shared.config
        return InvoiceClassifier(threshold: config.invoiceConfidenceThreshold)
    }

    // MARK: - Public API

    /// Classify a document as an invoice or not
    /// - Parameter text: The extracted text content to classify
    /// - Returns: Classification result with confidence and match details
    func classify(_ text: String) -> InvoiceClassification {
        let normalizedText = text.lowercased()

        // Stage 1: Keyword scoring
        let (keywordScore, keywordMatches) = calculateKeywordScore(normalizedText)

        // Stage 2: Structure scoring
        let (structureBoost, detectedPatterns) = calculateStructureBoost(text)

        // Combine scores, capped at 1.0
        let finalScore = min(1.0, keywordScore + structureBoost)

        // Classify based on threshold
        let isInvoice = finalScore >= threshold

        return InvoiceClassification(
            isInvoice: isInvoice,
            confidence: finalScore,
            keywordMatches: keywordMatches,
            detectedPatterns: detectedPatterns
        )
    }

    // MARK: - Keyword Scoring

    /// Calculate keyword-based score
    /// - Parameter normalizedText: Lowercased text to analyze
    /// - Returns: Tuple of (normalized score, matched keywords)
    private func calculateKeywordScore(_ normalizedText: String) -> (Float, [KeywordMatch]) {
        var totalScore: Float = 0.0
        var matches: [KeywordMatch] = []

        for (category, keywords) in Self.keywordTaxonomy {
            // Only count once per category
            for keyword in keywords {
                if normalizedText.contains(keyword) {
                    totalScore += category.weight
                    matches.append(KeywordMatch(
                        keyword: keyword,
                        category: category.rawValue,
                        weight: category.weight
                    ))
                    break // Only count once per category
                }
            }
        }

        // Normalize to 0.0-1.0 (negative scores become 0)
        let normalizedScore = max(0, totalScore) / Self.maxPositiveKeywordScore

        return (normalizedScore, matches)
    }

    // MARK: - Structure Scoring

    /// Calculate structure pattern boost
    /// - Parameter text: Original text (not lowercased, for pattern matching)
    /// - Returns: Tuple of (score boost, detected pattern names)
    private func calculateStructureBoost(_ text: String) -> (Float, [String]) {
        var boost: Float = 0.0
        var detectedPatterns: [String] = []
        let range = NSRange(text.startIndex..., in: text)

        // Check invoice number pattern
        if Self.invoiceNumberPattern.firstMatch(in: text, options: [], range: range) != nil {
            boost += StructurePattern.invoiceNumber.scoreBoost
            detectedPatterns.append(StructurePattern.invoiceNumber.rawValue)
        }

        // Check currency amount pattern
        if Self.currencyAmountPattern.firstMatch(in: text, options: [], range: range) != nil {
            boost += StructurePattern.currencyAmount.scoreBoost
            detectedPatterns.append(StructurePattern.currencyAmount.rawValue)
        }

        // Check date pattern
        if Self.datePattern.firstMatch(in: text, options: [], range: range) != nil {
            boost += StructurePattern.datePattern.scoreBoost
            detectedPatterns.append(StructurePattern.datePattern.rawValue)
        }

        // Check tax ID pattern
        if Self.taxIdPattern.firstMatch(in: text, options: [], range: range) != nil {
            boost += StructurePattern.taxIdPattern.scoreBoost
            detectedPatterns.append(StructurePattern.taxIdPattern.rawValue)
        }

        // Check for line items (multiple matches suggest itemized invoice)
        let lineItemMatches = Self.lineItemsPattern.matches(in: text, options: [], range: range)
        if lineItemMatches.count >= 2 {
            boost += StructurePattern.lineItems.scoreBoost
            detectedPatterns.append(StructurePattern.lineItems.rawValue)
        }

        return (boost, detectedPatterns)
    }
}

// MARK: - InvoiceClassification Extensions

extension InvoiceClassification {
    /// Convert to InvoiceClassificationDetails for logging
    var asClassificationDetails: InvoiceClassificationDetails {
        InvoiceClassificationDetails(
            isInvoice: isInvoice,
            confidence: confidence,
            keywordMatches: keywordMatches,
            structurePatterns: detectedPatterns
        )
    }
}
