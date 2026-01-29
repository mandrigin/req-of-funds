import Foundation
import PDFKit

/// Result of PDF text extraction
struct PDFExtractionResult {
    /// Extracted text from all pages
    let text: String
    /// Document title from metadata (if available)
    let title: String?
    /// Document author from metadata (if available)
    let author: String?
    /// Number of pages in the document
    let pageCount: Int
}

/// Service for handling PDF document operations
final class PDFService {

    /// Errors that can occur during PDF processing
    enum PDFServiceError: Error, LocalizedError {
        case fileNotFound(URL)
        case invalidPDF(URL)
        case extractionFailed(String)

        var errorDescription: String? {
            switch self {
            case .fileNotFound(let url):
                return "PDF file not found at: \(url.path)"
            case .invalidPDF(let url):
                return "Invalid or corrupted PDF file: \(url.path)"
            case .extractionFailed(let reason):
                return "Text extraction failed: \(reason)"
            }
        }
    }

    /// Load a PDF document from a file URL
    /// - Parameter url: The file URL of the PDF document
    /// - Returns: A PDFDocument instance
    /// - Throws: PDFServiceError if the file cannot be loaded
    func loadDocument(from url: URL) throws -> PDFDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PDFServiceError.fileNotFound(url)
        }

        guard let document = PDFDocument(url: url) else {
            throw PDFServiceError.invalidPDF(url)
        }

        return document
    }

    /// Extract text and metadata from a PDF document
    /// - Parameter document: The PDFDocument to extract from
    /// - Returns: PDFExtractionResult containing text and metadata
    func extractContent(from document: PDFDocument) -> PDFExtractionResult {
        let text = extractText(from: document)
        let metadata = extractMetadata(from: document)

        return PDFExtractionResult(
            text: text,
            title: metadata.title,
            author: metadata.author,
            pageCount: document.pageCount
        )
    }

    /// Extract text and metadata from a PDF file URL
    /// - Parameter url: The file URL of the PDF document
    /// - Returns: PDFExtractionResult containing text and metadata
    /// - Throws: PDFServiceError if the file cannot be processed
    func extractContent(from url: URL) throws -> PDFExtractionResult {
        let document = try loadDocument(from: url)
        return extractContent(from: document)
    }

    /// Extract text from all pages of a PDF document
    /// Uses autoreleasepool per page for memory efficiency with large documents
    /// - Parameter document: The PDFDocument to extract text from
    /// - Returns: Combined text from all pages
    private func extractText(from document: PDFDocument) -> String {
        var pageTexts: [String] = []
        pageTexts.reserveCapacity(document.pageCount)

        for pageIndex in 0..<document.pageCount {
            // Use autoreleasepool per page to manage memory with large documents
            autoreleasepool {
                if let page = document.page(at: pageIndex),
                   let pageText = page.string {
                    pageTexts.append(pageText)
                }
            }
        }

        return pageTexts.joined(separator: "\n\n")
    }

    /// Extract metadata from a PDF document
    /// - Parameter document: The PDFDocument to extract metadata from
    /// - Returns: Tuple containing optional title and author
    private func extractMetadata(from document: PDFDocument) -> (title: String?, author: String?) {
        guard let attributes = document.documentAttributes else {
            return (nil, nil)
        }

        let title = attributes[PDFDocumentAttribute.titleAttribute] as? String
        let author = attributes[PDFDocumentAttribute.authorAttribute] as? String

        return (title, author)
    }
}
