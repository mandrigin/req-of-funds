import Foundation
import SwiftData

/// Status of an RFF document in the workflow
enum RFFStatus: String, Codable, CaseIterable {
    case pending = "pending"
    case underReview = "under_review"
    case approved = "approved"
    case rejected = "rejected"
    case completed = "completed"
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

    /// Deadline for the request
    var dueDate: Date

    /// Current status in the workflow
    var status: RFFStatus

    /// Text extracted from the document via OCR
    var extractedText: String?

    /// Path to the source document file
    var documentPath: String?

    /// Line items associated with this document
    @Relationship(deleteRule: .cascade, inverse: \LineItem.document)
    var lineItems: [LineItem]

    /// Creation timestamp
    var createdAt: Date

    /// Last modification timestamp
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        requestingOrganization: String,
        amount: Decimal,
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
        self.dueDate = dueDate
        self.status = status
        self.extractedText = extractedText
        self.documentPath = documentPath
        self.lineItems = lineItems
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}
