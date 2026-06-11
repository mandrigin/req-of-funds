import Foundation
import PDFKit
import CoreGraphics

// MARK: - PDF Extraction Result

/// Result of PDF text extraction
enum MonitorPDFExtractionResult {
    /// Successfully extracted text with native PDFKit
    case success(text: String, pageCount: Int)

    /// PDF needs OCR - contains partial text and rendered pages
    case needsOCR(partialText: String, pages: [CGImage], pageCount: Int)

    /// Extraction failed
    case failure(PDFExtractionError)
}

/// Errors that can occur during PDF extraction
enum PDFExtractionError: LocalizedError {
    /// Document could not be opened (corrupted or invalid format)
    case documentUnreadable

    /// Document is password-protected
    case passwordProtected

    /// Document has no pages
    case emptyDocument

    /// Page rendering failed
    case renderingFailed(page: Int)

    /// General error with underlying cause
    case other(Error)

    var errorDescription: String? {
        switch self {
        case .documentUnreadable:
            return "PDF document could not be opened"
        case .passwordProtected:
            return "PDF document is password-protected"
        case .emptyDocument:
            return "PDF document has no pages"
        case .renderingFailed(let page):
            return "Failed to render PDF page \(page)"
        case .other(let error):
            return "PDF extraction error: \(error.localizedDescription)"
        }
    }
}

// MARK: - PDF Extractor

/// Extracts text from PDF documents using PDFKit
final class PDFExtractor {

    // MARK: - Constants

    /// Minimum word count to consider PDF as having extractable text
    private static let minimumWordCount = 50

    /// Default DPI for rendering PDF pages to images for OCR
    private static let defaultRenderDPI: CGFloat = 150.0

    // MARK: - Initialization

    init() {}

    // MARK: - Public API

    /// Extract text from a PDF file
    /// - Parameters:
    ///   - url: URL to the PDF file
    ///   - maxPages: Maximum number of pages to process (from config.maxOCRPages)
    /// - Returns: Extraction result indicating success, need for OCR, or failure
    func extract(url: URL, maxPages: Int) -> MonitorPDFExtractionResult {
        // Attempt to open the document
        guard let document = PDFDocument(url: url) else {
            // Check if file exists to provide better error
            if !FileManager.default.fileExists(atPath: url.path) {
                return .failure(.documentUnreadable)
            }
            // Document exists but couldn't be opened - likely corrupted or password-protected
            // PDFKit doesn't expose password-protection check without trying to unlock
            return .failure(.documentUnreadable)
        }

        // Check for password protection
        if document.isLocked {
            return .failure(.passwordProtected)
        }

        // Check for empty document
        guard document.pageCount > 0 else {
            return .failure(.emptyDocument)
        }

        // Determine how many pages to process
        let pageCount = min(document.pageCount, maxPages)

        // Extract native text from pages
        var fullText = ""
        var pagesWithNoText: [Int] = []

        for i in 0..<pageCount {
            guard let page = document.page(at: i) else {
                continue
            }

            if let pageText = page.string, !pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fullText += pageText + "\n\n"
            } else {
                pagesWithNoText.append(i)
            }
        }

        // Count words to determine if we have meaningful text
        let wordCount = countWords(in: fullText)

        // If we have enough text, return success
        if wordCount >= Self.minimumWordCount {
            return .success(text: fullText, pageCount: pageCount)
        }

        // Not enough text - this is likely a scanned PDF, needs OCR
        // Render pages to images for OCR processing
        var renderedPages: [CGImage] = []

        for i in 0..<pageCount {
            guard let page = document.page(at: i) else {
                continue
            }

            if let image = renderPage(page, dpi: Self.defaultRenderDPI) {
                renderedPages.append(image)
            }
        }

        // If we couldn't render any pages, that's a failure
        if renderedPages.isEmpty {
            return .failure(.renderingFailed(page: 0))
        }

        return .needsOCR(partialText: fullText, pages: renderedPages, pageCount: pageCount)
    }

    /// Check if a PDF at the given URL can be opened
    /// - Parameter url: URL to the PDF file
    /// - Returns: true if the PDF can be opened, false otherwise
    func canOpen(url: URL) -> Bool {
        guard let document = PDFDocument(url: url) else {
            return false
        }
        return !document.isLocked
    }

    /// Get page count for a PDF without extracting text
    /// - Parameter url: URL to the PDF file
    /// - Returns: Page count, or nil if document can't be opened
    func pageCount(url: URL) -> Int? {
        guard let document = PDFDocument(url: url), !document.isLocked else {
            return nil
        }
        return document.pageCount
    }

    // MARK: - Page Rendering

    /// Render a PDF page to a CGImage for OCR
    /// - Parameters:
    ///   - page: The PDF page to render
    ///   - dpi: Resolution for rendering (default 150 DPI)
    /// - Returns: Rendered CGImage, or nil if rendering failed
    func renderPage(_ page: PDFPage, dpi: CGFloat = defaultRenderDPI) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale = dpi / 72.0
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)

        // Ensure dimensions are valid
        guard width > 0, height > 0 else {
            return nil
        }

        // Create bitmap context
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        // Fill with white background (PDFs may have transparent backgrounds)
        context.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Scale context to match DPI
        context.scaleBy(x: scale, y: scale)

        // Draw the PDF page
        page.draw(with: .mediaBox, to: context)

        return context.makeImage()
    }

    // MARK: - Private Helpers

    /// Count words in text (simple whitespace-based word count)
    private func countWords(in text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return 0
        }

        // Split by whitespace and newlines, filter empty strings
        let words = trimmed.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        return words.count
    }
}

// MARK: - ExtractionResult Conversion

extension PDFExtractor {
    /// Convert MonitorPDFExtractionResult to ExtractionDetails for logging
    /// - Parameters:
    ///   - result: The PDF extraction result
    ///   - extractionTimeMs: Time taken for extraction in milliseconds
    /// - Returns: ExtractionDetails struct for logging
    static func makeExtractionDetails(
        from result: MonitorPDFExtractionResult,
        extractionTimeMs: Int
    ) -> ExtractionDetails? {
        switch result {
        case .success(let text, let pageCount):
            return ExtractionDetails(
                method: .pdfKit,
                confidence: 1.0,  // Native PDF text is high confidence
                pageCount: pageCount,
                extractionTimeMs: extractionTimeMs,
                textLength: text.count
            )

        case .needsOCR(let partialText, _, let pageCount):
            // This will be updated after OCR completes
            return ExtractionDetails(
                method: .pdfKit,
                confidence: 0.0,  // Low confidence - needs OCR
                pageCount: pageCount,
                extractionTimeMs: extractionTimeMs,
                textLength: partialText.count
            )

        case .failure:
            return nil
        }
    }
}
