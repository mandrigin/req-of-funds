import Foundation
import SwiftUI
import UniformTypeIdentifiers
import PDFKit

// MARK: - Transferable for Line Items

extension RFFDocumentData.LineItemData: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .lineItem)
    }
}

extension UTType {
    static var lineItem: UTType {
        UTType(exportedAs: "com.rff.lineitem", conformingTo: .json)
    }
}

// MARK: - Transferable for RFF Document Data

extension RFFDocumentData: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        // Primary: Codable JSON representation
        CodableRepresentation(contentType: .rffDocument)

        // Export as PDF for sharing
        DataRepresentation(exportedContentType: .pdf) { document in
            try document.exportAsPDF()
        }

        // Accept dropped PDFs to extract content
        FileRepresentation(importedContentType: .pdf) { receivedFile in
            try await Self.importFromPDF(receivedFile.file)
        }

        // Accept dropped images for OCR
        FileRepresentation(importedContentType: .image) { receivedFile in
            try await Self.importFromImage(receivedFile.file)
        }
    }

    /// Export document data as PDF
    private func exportAsPDF() throws -> Data {
        let pdfData = NSMutableData()
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter

        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let pdfContext = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw TransferError.invalidData
        }

        pdfContext.beginPDFPage(nil)

        // Draw content
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.black
        ]

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 18),
            .foregroundColor: NSColor.black
        ]

        var yPosition: CGFloat = pageRect.height - 50

        // Title
        let titleString = NSAttributedString(string: title, attributes: titleAttributes)
        titleString.draw(at: CGPoint(x: 50, y: yPosition))
        yPosition -= 30

        // Organization
        let orgString = NSAttributedString(string: "Organization: \(requestingOrganization)", attributes: attributes)
        orgString.draw(at: CGPoint(x: 50, y: yPosition))
        yPosition -= 20

        // Amount
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.currencyCode
        let amountStr = formatter.string(from: amount as NSDecimalNumber) ?? "\(amount)"
        let amountString = NSAttributedString(string: "Amount: \(amountStr)", attributes: attributes)
        amountString.draw(at: CGPoint(x: 50, y: yPosition))
        yPosition -= 20

        // Due Date
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        let dueDateStr = dateFormatter.string(from: dueDate)
        let dueDateString = NSAttributedString(string: "Due Date: \(dueDateStr)", attributes: attributes)
        dueDateString.draw(at: CGPoint(x: 50, y: yPosition))
        yPosition -= 30

        // Line items
        if !lineItems.isEmpty {
            let lineItemsHeader = NSAttributedString(string: "Line Items:", attributes: titleAttributes)
            lineItemsHeader.draw(at: CGPoint(x: 50, y: yPosition))
            yPosition -= 25

            for item in lineItems {
                let itemTotal = formatter.string(from: item.total as NSDecimalNumber) ?? "\(item.total)"
                let itemString = NSAttributedString(
                    string: "• \(item.itemDescription): \(item.quantity) × \(formatter.string(from: item.unitPrice as NSDecimalNumber) ?? "") = \(itemTotal)",
                    attributes: attributes
                )
                itemString.draw(at: CGPoint(x: 60, y: yPosition))
                yPosition -= 18
            }
        }

        pdfContext.endPDFPage()
        pdfContext.closePDF()

        return pdfData as Data
    }

    /// Import from a dropped PDF file
    private static func importFromPDF(_ url: URL) async throws -> RFFDocumentData {
        // Start security-scoped access
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { url.stopAccessingSecurityScopedResource() }
        }

        // Process OCR
        let ocrService = DocumentOCRService()
        let result = try await ocrService.processDocument(at: url)

        // Extract entities from OCR text
        let extractor = EntityExtractionService()
        let entities = try await extractor.extractEntities(from: result.fullText)

        // Build document from extracted data
        var document = RFFDocumentData()
        document.title = url.deletingPathExtension().lastPathComponent
        document.extractedText = result.fullText
        document.requestingOrganization = entities.organizationName ?? ""
        document.amount = entities.amount ?? Decimal.zero
        document.currency = entities.currency ?? .usd
        document.dueDate = entities.dueDate ?? Date().addingTimeInterval(7 * 24 * 60 * 60)

        // Create bookmark for the source PDF
        if let bookmarkData = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            document.attachedFiles.append(
                RFFDocumentData.AttachedFileData(
                    id: UUID(),
                    filename: url.lastPathComponent,
                    bookmarkData: bookmarkData,
                    addedAt: Date()
                )
            )
        }

        return document
    }

    /// Import from a dropped image file
    private static func importFromImage(_ url: URL) async throws -> RFFDocumentData {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { url.stopAccessingSecurityScopedResource() }
        }

        // Process OCR on image
        let ocrService = DocumentOCRService()
        let result = try await ocrService.processDocument(at: url)

        // Extract entities
        let extractor = EntityExtractionService()
        let entities = try await extractor.extractEntities(from: result.fullText)

        var document = RFFDocumentData()
        document.title = url.deletingPathExtension().lastPathComponent
        document.extractedText = result.fullText
        document.requestingOrganization = entities.organizationName ?? ""
        document.amount = entities.amount ?? Decimal.zero
        document.currency = entities.currency ?? .usd
        document.dueDate = entities.dueDate ?? Date().addingTimeInterval(7 * 24 * 60 * 60)

        return document
    }
}

enum TransferError: Error, LocalizedError {
    case accessDenied
    case invalidData
    case ocrFailed

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Access to the dropped file was denied"
        case .invalidData:
            return "The dropped file contains invalid data"
        case .ocrFailed:
            return "Failed to extract text from the document"
        }
    }
}
