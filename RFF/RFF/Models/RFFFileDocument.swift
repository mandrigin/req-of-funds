import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Custom UTType for RFF documents
extension UTType {
    static var rffDocument: UTType {
        UTType(exportedAs: "com.rff.document", conformingTo: .json)
    }
}

/// Codable data structure for persisting RFF document to file
struct RFFDocumentData: Codable {
    var id: UUID
    var title: String
    var requestingOrganization: String
    var amount: Decimal
    var currency: Currency
    var dueDate: Date
    var status: String
    var extractedText: String?
    var notes: String?
    var lineItems: [LineItemData]
    var attachedFiles: [AttachedFileData]
    var createdAt: Date
    var updatedAt: Date

    struct LineItemData: Codable, Identifiable {
        var id: UUID
        var itemDescription: String
        var quantity: Int
        var unitPrice: Decimal
        var category: String?
        var notes: String?

        var total: Decimal {
            unitPrice * Decimal(quantity)
        }
    }

    struct AttachedFileData: Codable, Identifiable {
        var id: UUID
        var filename: String
        var bookmarkData: Data?
        var addedAt: Date
    }

    var totalAmount: Decimal {
        lineItems.reduce(Decimal.zero) { $0 + $1.total }
    }

    /// Returns true if the document is in a read-only state (approved, completed, or paid)
    var isReadOnly: Bool {
        switch status {
        case "approved", "completed", "paid":
            return true
        default:
            return false
        }
    }

    init() {
        self.id = UUID()
        self.title = "New RFF Document"
        self.requestingOrganization = ""
        self.amount = Decimal.zero
        self.currency = .usd
        self.dueDate = Date().addingTimeInterval(7 * 24 * 60 * 60)
        self.status = "pending"
        self.extractedText = nil
        self.notes = nil
        self.lineItems = []
        self.attachedFiles = []
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

/// FileDocument implementation for RFF documents
struct RFFFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.rffDocument, .json] }
    static var writableContentTypes: [UTType] { [.rffDocument] }

    var data: RFFDocumentData

    init() {
        self.data = RFFDocumentData()
    }

    init(data: RFFDocumentData) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let fileData = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.data = try decoder.decode(RFFDocumentData.self, from: fileData)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        var updatedData = data
        updatedData.updatedAt = Date()

        let jsonData = try encoder.encode(updatedData)
        return FileWrapper(regularFileWithContents: jsonData)
    }
}

// MARK: - Security-Scoped Bookmarks

extension RFFFileDocument {
    /// Create a security-scoped bookmark for a file URL
    static func createBookmark(for url: URL) throws -> Data {
        // Start accessing the security-scoped resource
        guard url.startAccessingSecurityScopedResource() else {
            throw BookmarkError.accessDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }

        return try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Resolve a security-scoped bookmark to a URL
    static func resolveBookmark(_ bookmarkData: Data) throws -> URL {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        if isStale {
            // Bookmark needs to be recreated
            throw BookmarkError.staleBookmark
        }

        return url
    }

    /// Add an attached file with security-scoped bookmark
    mutating func attachFile(at url: URL) throws {
        let bookmarkData = try Self.createBookmark(for: url)

        let attachment = RFFDocumentData.AttachedFileData(
            id: UUID(),
            filename: url.lastPathComponent,
            bookmarkData: bookmarkData,
            addedAt: Date()
        )

        data.attachedFiles.append(attachment)
        data.updatedAt = Date()
    }

    /// Access an attached file's URL with security scope
    func accessAttachedFile(_ attachment: RFFDocumentData.AttachedFileData) throws -> URL {
        guard let bookmarkData = attachment.bookmarkData else {
            throw BookmarkError.missingBookmarkData
        }

        let url = try Self.resolveBookmark(bookmarkData)

        guard url.startAccessingSecurityScopedResource() else {
            throw BookmarkError.accessDenied
        }

        return url
    }
}

enum BookmarkError: Error, LocalizedError {
    case accessDenied
    case staleBookmark
    case missingBookmarkData

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Access to the file was denied"
        case .staleBookmark:
            return "The file bookmark is stale and needs to be recreated"
        case .missingBookmarkData:
            return "No bookmark data available for this file"
        }
    }
}
