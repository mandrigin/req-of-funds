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
enum Currency: String, Codable, CaseIterable, Identifiable {
    case usd = "USD"
    case eur = "EUR"
    case gbp = "GBP"

    var id: String { rawValue }

    /// Currency symbol
    var symbol: String {
        switch self {
        case .usd: return "$"
        case .eur: return "€"
        case .gbp: return "£"
        }
    }

    /// Full currency name
    var displayName: String {
        switch self {
        case .usd: return "US Dollar"
        case .eur: return "Euro"
        case .gbp: return "British Pound"
        }
    }

    /// Currency code for formatting
    var currencyCode: String { rawValue }
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

    init(
        id: UUID = UUID(),
        title: String,
        requestingOrganization: String,
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
