import Foundation
import SwiftData

/// Status of an RFF document in the workflow
enum RFFStatus: String, Codable, CaseIterable {
    case pending = "pending"
    case underReview = "under_review"
    case approved = "approved"
    case rejected = "rejected"
    case completed = "completed"
    case paid = "paid"
}

/// Supported currencies for RFF documents (ISO 4217)
enum Currency: String, Codable, CaseIterable, Identifiable {
    // Major world currencies
    case usd = "USD"
    case eur = "EUR"
    case gbp = "GBP"
    case jpy = "JPY"
    case cny = "CNY"
    case chf = "CHF"

    // Other common currencies (alphabetical by code)
    case aud = "AUD"
    case brl = "BRL"
    case cad = "CAD"
    case czk = "CZK"
    case dkk = "DKK"
    case hkd = "HKD"
    case huf = "HUF"
    case idr = "IDR"
    case ils = "ILS"
    case inr = "INR"
    case krw = "KRW"
    case mxn = "MXN"
    case myr = "MYR"
    case nok = "NOK"
    case nzd = "NZD"
    case php = "PHP"
    case pln = "PLN"
    case ron = "RON"
    case rub = "RUB"
    case sek = "SEK"
    case sgd = "SGD"
    case thb = "THB"
    case `try` = "TRY"
    case twd = "TWD"
    case zar = "ZAR"

    var id: String { rawValue }

    /// Currency symbol
    var symbol: String {
        switch self {
        case .usd: return "$"
        case .eur: return "€"
        case .gbp: return "£"
        case .jpy: return "¥"
        case .cny: return "¥"
        case .chf: return "CHF"
        case .aud: return "A$"
        case .brl: return "R$"
        case .cad: return "C$"
        case .czk: return "Kč"
        case .dkk: return "kr"
        case .hkd: return "HK$"
        case .huf: return "Ft"
        case .idr: return "Rp"
        case .ils: return "₪"
        case .inr: return "₹"
        case .krw: return "₩"
        case .mxn: return "MX$"
        case .myr: return "RM"
        case .nok: return "kr"
        case .nzd: return "NZ$"
        case .php: return "₱"
        case .pln: return "zł"
        case .ron: return "lei"
        case .rub: return "₽"
        case .sek: return "kr"
        case .sgd: return "S$"
        case .thb: return "฿"
        case .try: return "₺"
        case .twd: return "NT$"
        case .zar: return "R"
        }
    }

    /// Full currency name
    var displayName: String {
        switch self {
        case .usd: return "US Dollar"
        case .eur: return "Euro"
        case .gbp: return "British Pound"
        case .jpy: return "Japanese Yen"
        case .cny: return "Chinese Yuan"
        case .chf: return "Swiss Franc"
        case .aud: return "Australian Dollar"
        case .brl: return "Brazilian Real"
        case .cad: return "Canadian Dollar"
        case .czk: return "Czech Koruna"
        case .dkk: return "Danish Krone"
        case .hkd: return "Hong Kong Dollar"
        case .huf: return "Hungarian Forint"
        case .idr: return "Indonesian Rupiah"
        case .ils: return "Israeli Shekel"
        case .inr: return "Indian Rupee"
        case .krw: return "South Korean Won"
        case .mxn: return "Mexican Peso"
        case .myr: return "Malaysian Ringgit"
        case .nok: return "Norwegian Krone"
        case .nzd: return "New Zealand Dollar"
        case .php: return "Philippine Peso"
        case .pln: return "Polish Złoty"
        case .ron: return "Romanian Leu"
        case .rub: return "Russian Ruble"
        case .sek: return "Swedish Krona"
        case .sgd: return "Singapore Dollar"
        case .thb: return "Thai Baht"
        case .try: return "Turkish Lira"
        case .twd: return "Taiwan Dollar"
        case .zar: return "South African Rand"
        }
    }

    /// Currency code for formatting
    var currencyCode: String { rawValue }

    /// Common currencies shown at top of pickers
    static var common: [Currency] {
        [.usd, .eur, .gbp, .jpy, .chf, .cad, .aud]
    }
}

/// Main document model for RFF (Request for Funding) documents
@Model
final class RFFDocument {
    /// Unique identifier
    @Attribute(.unique) var id: UUID

    /// Document title
    var title: String

    /// Organization requesting the funding
    var requestingOrganization: String

    /// Recipient (who the invoice is addressed to)
    var recipient: String?

    /// Requested funding amount
    var amount: Decimal

    /// Currency for the amount
    var currency: Currency

    /// Deadline for the request
    var dueDate: Date

    /// Current status in the workflow
    var status: RFFStatus

    /// Text extracted from the document via OCR
    var extractedText: String?

    /// ML-classified document category
    var documentCategory: String?

    /// Confidence score of the ML classification (0.0 to 1.0)
    var classificationConfidence: Double?

    /// Path to the source document file
    var documentPath: String?

    /// Line items associated with this document
    @Relationship(deleteRule: .cascade, inverse: \LineItem.document)
    var lineItems: [LineItem]

    /// Creation timestamp
    var createdAt: Date

    /// Last modification timestamp
    var updatedAt: Date

    // MARK: - Confirmed Values (set when document is approved)

    /// Confirmed organization name (locked after approval)
    var confirmedOrganization: String?

    /// Confirmed amount (locked after approval)
    var confirmedAmount: Decimal?

    /// Confirmed due date (locked after approval)
    var confirmedDueDate: Date?

    /// Timestamp when document was confirmed/approved
    var confirmedAt: Date?

    /// Date when the document was marked as paid
    var paidDate: Date?

    /// ID of the schema used for field extraction (nil = no schema assigned)
    var schemaId: UUID?

    /// Returns true if the document is in a read-only state (approved, completed, or paid)
    var isReadOnly: Bool {
        switch status {
        case .approved, .completed, .paid:
            return true
        case .pending, .underReview, .rejected:
            return false
        }
    }

    init(
        id: UUID = UUID(),
        title: String,
        requestingOrganization: String,
        recipient: String? = nil,
        amount: Decimal,
        currency: Currency = .usd,
        dueDate: Date,
        status: RFFStatus = .pending,
        extractedText: String? = nil,
        documentPath: String? = nil,
        lineItems: [LineItem] = []
    ) {
        self.id = id
        self.title = title
        self.requestingOrganization = requestingOrganization
        self.recipient = recipient
        self.amount = amount
        self.currency = currency
        self.dueDate = dueDate
        self.status = status
        self.extractedText = extractedText
        self.documentPath = documentPath
        self.lineItems = lineItems
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}
