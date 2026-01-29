import Foundation
import SwiftData

/// A line item within an RFF document
@Model
final class LineItem {
    /// Unique identifier
    @Attribute(.unique) var id: UUID

    /// Description of the line item
    var itemDescription: String

    /// Quantity requested
    var quantity: Int

    /// Unit price
    var unitPrice: Decimal

    /// Category for classification
    var category: String?

    /// Notes or additional details
    var notes: String?

    /// Parent document
    var document: RFFDocument?

    /// Computed total for this line item
    var total: Decimal {
        unitPrice * Decimal(quantity)
    }

    init(
        id: UUID = UUID(),
        itemDescription: String,
        quantity: Int = 1,
        unitPrice: Decimal,
        category: String? = nil,
        notes: String? = nil,
        document: RFFDocument? = nil
    ) {
        self.id = id
        self.itemDescription = itemDescription
        self.quantity = quantity
        self.unitPrice = unitPrice
        self.category = category
        self.notes = notes
        self.document = document
    }
}
