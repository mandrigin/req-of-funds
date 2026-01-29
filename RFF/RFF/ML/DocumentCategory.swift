import Foundation

/// Categories for document classification
/// Used by the ML text classifier to categorize incoming documents
enum DocumentCategory: String, CaseIterable, Codable {
    case invoice = "invoice"
    case purchaseOrder = "purchase_order"
    case grantRequest = "grant_request"
    case reimbursement = "reimbursement"

    /// Human-readable display name
    var displayName: String {
        switch self {
        case .invoice:
            return "Invoice"
        case .purchaseOrder:
            return "Purchase Order"
        case .grantRequest:
            return "Grant Request"
        case .reimbursement:
            return "Reimbursement"
        }
    }

    /// Description of what this document type typically contains
    var description: String {
        switch self {
        case .invoice:
            return "A bill requesting payment for goods or services rendered"
        case .purchaseOrder:
            return "A formal request to purchase goods or services"
        case .grantRequest:
            return "An application for funding from a grant program"
        case .reimbursement:
            return "A request for repayment of expenses incurred"
        }
    }
}
