import Foundation

/// Field types that can be extracted from invoices
enum InvoiceFieldType: String, Codable, CaseIterable, Identifiable {
    case invoiceNumber = "invoice_number"
    case invoiceDate = "invoice_date"
    case dueDate = "due_date"
    case vendor = "vendor"
    case vendorAddress = "vendor_address"
    case recipient = "recipient"
    case customerName = "customer_name"
    case customerAddress = "customer_address"
    case subtotal = "subtotal"
    case tax = "tax"
    case total = "total"
    case currency = "currency"
    case paymentTerms = "payment_terms"
    case poNumber = "po_number"
    case lineItemDescription = "line_item_description"
    case lineItemQuantity = "line_item_quantity"
    case lineItemUnitPrice = "line_item_unit_price"
    case lineItemTotal = "line_item_total"

    var id: String { rawValue }

    /// Human-readable display name
    var displayName: String {
        switch self {
        case .invoiceNumber: return "Invoice Number"
        case .invoiceDate: return "Invoice Date"
        case .dueDate: return "Due Date"
        case .vendor: return "Vendor Name"
        case .vendorAddress: return "Vendor Address"
        case .recipient: return "Recipient"
        case .customerName: return "Customer Name"
        case .customerAddress: return "Recipient Address"
        case .subtotal: return "Subtotal"
        case .tax: return "Tax"
        case .total: return "Total"
        case .currency: return "Currency"
        case .paymentTerms: return "Payment Terms"
        case .poNumber: return "PO Number"
        case .lineItemDescription: return "Line Item Description"
        case .lineItemQuantity: return "Line Item Quantity"
        case .lineItemUnitPrice: return "Line Item Unit Price"
        case .lineItemTotal: return "Line Item Total"
        }
    }

    /// Whether this field type is part of a line item (repeating)
    var isLineItemField: Bool {
        switch self {
        case .lineItemDescription, .lineItemQuantity, .lineItemUnitPrice, .lineItemTotal:
            return true
        default:
            return false
        }
    }

    /// Whether this field is required for a valid extraction
    var isRequired: Bool {
        switch self {
        case .vendor, .total, .invoiceDate:
            return true
        default:
            return false
        }
    }
}

/// Normalized bounding box region (0.0-1.0 coordinates relative to page)
struct NormalizedRegion: Codable, Equatable, Sendable, Hashable {
    /// Left edge (0.0 = left, 1.0 = right)
    let x: Double
    /// Bottom edge (0.0 = bottom, 1.0 = top) - Vision coordinate system
    let y: Double
    /// Width as fraction of page width
    let width: Double
    /// Height as fraction of page height
    let height: Double

    /// Check if a point is within this region with tolerance
    func contains(point: CGPoint, tolerance: Double = 0.05) -> Bool {
        let expandedX = x - tolerance
        let expandedY = y - tolerance
        let expandedWidth = width + tolerance * 2
        let expandedHeight = height + tolerance * 2

        return point.x >= expandedX &&
               point.x <= expandedX + expandedWidth &&
               point.y >= expandedY &&
               point.y <= expandedY + expandedHeight
    }

    /// Convert to CGRect
    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    /// Create from CGRect
    init(cgRect: CGRect) {
        self.x = cgRect.origin.x
        self.y = cgRect.origin.y
        self.width = cgRect.width
        self.height = cgRect.height
    }

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Maps a field to its extraction rules
struct FieldMapping: Codable, Identifiable, Sendable, Hashable {
    /// Unique identifier
    let id: UUID

    /// The type of field being mapped
    let fieldType: InvoiceFieldType

    /// Expected region on the page (normalized coordinates)
    let region: NormalizedRegion?

    /// Optional regex pattern for validation/extraction
    let pattern: String?

    /// Label text that typically precedes this field (e.g., "Invoice #:", "Total:")
    let labelHint: String?

    /// Confidence weight (0.0-1.0) based on learning
    var confidence: Double

    /// Number of times this mapping has been confirmed by user
    var confirmationCount: Int

    /// Number of times this mapping has been corrected by user
    var correctionCount: Int

    init(
        id: UUID = UUID(),
        fieldType: InvoiceFieldType,
        region: NormalizedRegion? = nil,
        pattern: String? = nil,
        labelHint: String? = nil,
        confidence: Double = 0.5,
        confirmationCount: Int = 0,
        correctionCount: Int = 0
    ) {
        self.id = id
        self.fieldType = fieldType
        self.region = region
        self.pattern = pattern
        self.labelHint = labelHint
        self.confidence = confidence
        self.confirmationCount = confirmationCount
        self.correctionCount = correctionCount
    }

    /// Effective confidence considering confirmations and corrections
    var effectiveConfidence: Double {
        let totalFeedback = confirmationCount + correctionCount
        guard totalFeedback > 0 else { return confidence }

        let feedbackRatio = Double(confirmationCount) / Double(totalFeedback)
        // Blend base confidence with feedback-based confidence
        return (confidence + feedbackRatio) / 2.0
    }
}

/// A reusable schema for extracting data from a specific invoice format
struct InvoiceSchema: Codable, Identifiable, Sendable, Hashable, Equatable {
    /// Unique identifier
    let id: UUID

    /// Human-readable name for this schema
    var name: String

    /// Vendor/company this schema is for (used for matching)
    var vendorIdentifier: String?

    /// Optional description
    var description: String?

    /// Field mappings for this schema
    var fieldMappings: [FieldMapping]

    /// Schema version for migrations
    let version: Int

    /// Whether this is a built-in schema (not user-editable)
    let isBuiltIn: Bool

    /// Creation timestamp
    let createdAt: Date

    /// Last modification timestamp
    var updatedAt: Date

    /// Number of documents successfully processed with this schema
    var usageCount: Int

    /// Average extraction confidence across recent uses
    var averageConfidence: Double

    init(
        id: UUID = UUID(),
        name: String,
        vendorIdentifier: String? = nil,
        description: String? = nil,
        fieldMappings: [FieldMapping] = [],
        version: Int = 1,
        isBuiltIn: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        usageCount: Int = 0,
        averageConfidence: Double = 0.0
    ) {
        self.id = id
        self.name = name
        self.vendorIdentifier = vendorIdentifier
        self.description = description
        self.fieldMappings = fieldMappings
        self.version = version
        self.isBuiltIn = isBuiltIn
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.usageCount = usageCount
        self.averageConfidence = averageConfidence
    }

    /// Get mapping for a specific field type
    func mapping(for fieldType: InvoiceFieldType) -> FieldMapping? {
        fieldMappings.first { $0.fieldType == fieldType }
    }

    /// Get all line item field mappings
    var lineItemMappings: [FieldMapping] {
        fieldMappings.filter { $0.fieldType.isLineItemField }
    }

    /// Get all header field mappings (non-line-item)
    var headerMappings: [FieldMapping] {
        fieldMappings.filter { !$0.fieldType.isLineItemField }
    }

    /// Check if schema has all required fields mapped
    var hasRequiredFields: Bool {
        let requiredTypes = InvoiceFieldType.allCases.filter { $0.isRequired }
        let mappedTypes = Set(fieldMappings.map { $0.fieldType })
        return requiredTypes.allSatisfy { mappedTypes.contains($0) }
    }
}

/// Result of applying a schema to extract data from a document
struct SchemaExtractionResult: Sendable {
    /// The schema used for extraction
    let schemaId: UUID

    /// Extracted field values with their confidence
    let extractedFields: [ExtractedField]

    /// Overall confidence of the extraction
    let overallConfidence: Double

    /// Warnings or issues encountered during extraction
    let warnings: [String]
}

/// A single extracted field value
struct ExtractedField: Sendable {
    /// The field type
    let fieldType: InvoiceFieldType

    /// The extracted text value
    let value: String

    /// Confidence score (0.0-1.0)
    let confidence: Double

    /// Bounding box where this value was found
    let boundingBox: NormalizedRegion

    /// Page index where this value was found
    let pageIndex: Int
}
