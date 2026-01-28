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

/// Supported currencies for RFF documents
/// Covers major world currencies - ISO 4217 codes
enum Currency: String, Codable, CaseIterable, Identifiable {
    // Major currencies
    case usd = "USD"
    case eur = "EUR"
    case gbp = "GBP"
    case jpy = "JPY"
    case chf = "CHF"
    case cad = "CAD"
    case aud = "AUD"
    case nzd = "NZD"

    // European currencies (non-Euro)
    case sek = "SEK"
    case nok = "NOK"
    case dkk = "DKK"
    case pln = "PLN"
    case czk = "CZK"
    case huf = "HUF"
    case ron = "RON"
    case bgn = "BGN"
    case hrk = "HRK"
    case isk = "ISK"

    // Asian currencies
    case cny = "CNY"
    case hkd = "HKD"
    case sgd = "SGD"
    case krw = "KRW"
    case twd = "TWD"
    case thb = "THB"
    case myr = "MYR"
    case idr = "IDR"
    case php = "PHP"
    case vnd = "VND"
    case inr = "INR"

    // Middle Eastern & African currencies
    case aed = "AED"
    case sar = "SAR"
    case ils = "ILS"
    case zar = "ZAR"
    case egp = "EGP"
    case ngn = "NGN"
    case kes = "KES"

    // Americas
    case mxn = "MXN"
    case brl = "BRL"
    case ars = "ARS"
    case clp = "CLP"
    case cop = "COP"
    case pen = "PEN"

    // Other major currencies
    case rub = "RUB"
    case try_ = "TRY"  // Turkish Lira (try is reserved keyword)

    var id: String { rawValue }

    /// Currency symbol
    var symbol: String {
        switch self {
        case .usd, .cad, .aud, .nzd, .sgd, .hkd, .mxn, .ars, .clp, .cop: return "$"
        case .eur: return "€"
        case .gbp: return "£"
        case .jpy, .cny: return "¥"
        case .chf: return "CHF"
        case .sek, .nok, .dkk, .isk: return "kr"
        case .pln: return "zł"
        case .czk: return "Kč"
        case .huf: return "Ft"
        case .ron: return "lei"
        case .bgn: return "лв"
        case .hrk: return "kn"
        case .krw: return "₩"
        case .twd: return "NT$"
        case .thb: return "฿"
        case .myr: return "RM"
        case .idr: return "Rp"
        case .php: return "₱"
        case .vnd: return "₫"
        case .inr: return "₹"
        case .aed: return "د.إ"
        case .sar: return "﷼"
        case .ils: return "₪"
        case .zar: return "R"
        case .egp: return "E£"
        case .ngn: return "₦"
        case .kes: return "KSh"
        case .brl: return "R$"
        case .pen: return "S/"
        case .rub: return "₽"
        case .try_: return "₺"
        }
    }

    /// Full currency name
    var displayName: String {
        switch self {
        case .usd: return "US Dollar"
        case .eur: return "Euro"
        case .gbp: return "British Pound"
        case .jpy: return "Japanese Yen"
        case .chf: return "Swiss Franc"
        case .cad: return "Canadian Dollar"
        case .aud: return "Australian Dollar"
        case .nzd: return "New Zealand Dollar"
        case .sek: return "Swedish Krona"
        case .nok: return "Norwegian Krone"
        case .dkk: return "Danish Krone"
        case .pln: return "Polish Zloty"
        case .czk: return "Czech Koruna"
        case .huf: return "Hungarian Forint"
        case .ron: return "Romanian Leu"
        case .bgn: return "Bulgarian Lev"
        case .hrk: return "Croatian Kuna"
        case .isk: return "Icelandic Króna"
        case .cny: return "Chinese Yuan"
        case .hkd: return "Hong Kong Dollar"
        case .sgd: return "Singapore Dollar"
        case .krw: return "South Korean Won"
        case .twd: return "Taiwan Dollar"
        case .thb: return "Thai Baht"
        case .myr: return "Malaysian Ringgit"
        case .idr: return "Indonesian Rupiah"
        case .php: return "Philippine Peso"
        case .vnd: return "Vietnamese Dong"
        case .inr: return "Indian Rupee"
        case .aed: return "UAE Dirham"
        case .sar: return "Saudi Riyal"
        case .ils: return "Israeli Shekel"
        case .zar: return "South African Rand"
        case .egp: return "Egyptian Pound"
        case .ngn: return "Nigerian Naira"
        case .kes: return "Kenyan Shilling"
        case .mxn: return "Mexican Peso"
        case .brl: return "Brazilian Real"
        case .ars: return "Argentine Peso"
        case .clp: return "Chilean Peso"
        case .cop: return "Colombian Peso"
        case .pen: return "Peruvian Sol"
        case .rub: return "Russian Ruble"
        case .try_: return "Turkish Lira"
        }
    }

    /// Currency code for formatting
    var currencyCode: String { rawValue }

    /// Common currencies for quick selection (most used globally)
    static var common: [Currency] {
        [.usd, .eur, .gbp, .jpy, .chf, .cad, .aud, .sek, .nok, .dkk, .cny, .inr]
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
