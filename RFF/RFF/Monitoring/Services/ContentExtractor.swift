import Foundation
import CoreGraphics

// MARK: - Extraction Result

/// Result of content extraction from a file
struct ExtractionResult {
    /// Extracted text from the document
    let text: String

    /// Method used for extraction
    let method: ExtractionMethod

    /// Confidence score (0.0-1.0). PDFKit native text is 1.0, OCR varies
    let confidence: Float

    /// Number of pages processed
    let pageCount: Int

    /// Time taken for extraction in milliseconds
    let extractionTimeMs: Int
}

// MARK: - Content Extractor Error

/// Errors that can occur during content extraction
enum ContentExtractorError: LocalizedError {
    /// File type is not supported for extraction
    case unsupportedFileType(String)

    /// PDF extraction failed
    case pdfExtractionFailed(PDFExtractionError)

    /// OCR extraction failed
    case ocrFailed(MonitorOCRError)

    /// File not found
    case fileNotFound(URL)

    /// No text could be extracted
    case noTextExtracted

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType(let ext):
            return "Unsupported file type: \(ext)"
        case .pdfExtractionFailed(let error):
            return "PDF extraction failed: \(error.localizedDescription)"
        case .ocrFailed(let error):
            return "OCR failed: \(error.localizedDescription)"
        case .fileNotFound(let url):
            return "File not found: \(url.path)"
        case .noTextExtracted:
            return "No text could be extracted from the document"
        }
    }
}

// MARK: - Content Extractor

/// Orchestrates text extraction from PDFs and images
///
/// Extraction strategy per spec section 3.2:
/// - PDFs: Try PDFKit native text first, fall back to Vision OCR if < 50 words
/// - Images (PNG/JPG/JPEG/HEIC/TIFF/WEBP): Direct Vision OCR
/// - Hybrid documents: Combine PDFKit text with OCR from scanned pages
final class ContentExtractor {

    // MARK: - Properties

    private let pdfExtractor: PDFExtractor
    private let ocrExtractor: OCRExtractor
    private let maxOCRPages: Int
    private let supportedImageExtensions: Set<String>
    private let supportedPDFExtension = "pdf"

    // MARK: - Initialization

    /// Create a content extractor with the given configuration
    /// - Parameters:
    ///   - ocrLanguages: Languages for Vision OCR (e.g., ["en-US"])
    ///   - maxOCRPages: Maximum pages to process for OCR
    init(ocrLanguages: [String] = ["en-US"], maxOCRPages: Int = 3) {
        self.pdfExtractor = PDFExtractor()
        self.ocrExtractor = OCRExtractor(languages: ocrLanguages)
        self.maxOCRPages = maxOCRPages
        self.supportedImageExtensions = ["png", "jpg", "jpeg", "heic", "tiff", "webp"]
    }

    /// Create a content extractor from the current app configuration
    static func fromConfig() -> ContentExtractor {
        let config = ConfigManager.shared.config
        return ContentExtractor(
            ocrLanguages: config.ocrLanguages,
            maxOCRPages: config.maxOCRPages
        )
    }

    // MARK: - Public API

    /// Extract text content from a file
    /// - Parameter url: URL to the file (PDF or image)
    /// - Returns: Extraction result with text and metadata
    func extract(from url: URL) async throws -> ExtractionResult {
        let startTime = Date()

        // Verify file exists
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ContentExtractorError.fileNotFound(url)
        }

        let fileExtension = url.pathExtension.lowercased()

        // Route to appropriate extractor
        if fileExtension == supportedPDFExtension {
            return try await extractFromPDF(url: url, startTime: startTime)
        } else if supportedImageExtensions.contains(fileExtension) {
            return try await extractFromImage(url: url, startTime: startTime)
        } else {
            throw ContentExtractorError.unsupportedFileType(fileExtension)
        }
    }

    /// Check if a file type is supported for extraction
    /// - Parameter url: URL to check
    /// - Returns: true if the file type can be processed
    func supportsFileType(at url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == supportedPDFExtension || supportedImageExtensions.contains(ext)
    }

    // MARK: - PDF Extraction

    private func extractFromPDF(url: URL, startTime: Date) async throws -> ExtractionResult {
        // Try native PDF text extraction first
        let pdfResult = pdfExtractor.extract(url: url, maxPages: maxOCRPages)

        switch pdfResult {
        case .success(let text, let pageCount):
            // Native PDFKit text extraction succeeded with sufficient content
            let extractionTime = Int(Date().timeIntervalSince(startTime) * 1000)
            return ExtractionResult(
                text: text,
                method: .pdfKit,
                confidence: 1.0, // Native text is high confidence
                pageCount: pageCount,
                extractionTimeMs: extractionTime
            )

        case .needsOCR(let partialText, let pages, let pageCount):
            // PDF needs OCR - either scanned or insufficient text
            return try await extractWithOCR(
                partialText: partialText,
                renderedPages: pages,
                pageCount: pageCount,
                startTime: startTime
            )

        case .failure(let error):
            throw ContentExtractorError.pdfExtractionFailed(error)
        }
    }

    /// Extract text using OCR, combining with any partial native text
    private func extractWithOCR(
        partialText: String,
        renderedPages: [CGImage],
        pageCount: Int,
        startTime: Date
    ) async throws -> ExtractionResult {
        // Perform OCR on rendered pages
        var ocrTexts: [String] = []
        var totalConfidence: Float = 0.0
        var observationCount = 0

        for image in renderedPages {
            do {
                let ocrResult = try await ocrExtractor.recognize(image: image)
                ocrTexts.append(ocrResult.text)
                totalConfidence += ocrResult.confidence * Float(ocrResult.observationCount)
                observationCount += ocrResult.observationCount
            } catch MonitorOCRError.noTextFound {
                // Page had no recognizable text, continue with others
                continue
            } catch {
                // Log but continue - partial extraction is better than none
                continue
            }
        }

        let ocrText = ocrTexts.joined(separator: "\n\n")

        // Combine partial native text with OCR text
        let combinedText: String
        let method: ExtractionMethod

        if !partialText.isEmpty && !ocrText.isEmpty {
            // Hybrid: both native text and OCR text
            combinedText = partialText + "\n\n" + ocrText
            method = .hybrid
        } else if !ocrText.isEmpty {
            // Pure OCR result
            combinedText = ocrText
            method = .visionOCR
        } else if !partialText.isEmpty {
            // Only partial native text available
            combinedText = partialText
            method = .pdfKit
        } else {
            throw ContentExtractorError.noTextExtracted
        }

        // Calculate average confidence
        let avgConfidence: Float
        if method == .hybrid {
            // Weight native text confidence (1.0) with OCR confidence
            let ocrConfidence = observationCount > 0 ? totalConfidence / Float(observationCount) : 0.0
            avgConfidence = (1.0 + ocrConfidence) / 2.0
        } else if observationCount > 0 {
            avgConfidence = totalConfidence / Float(observationCount)
        } else {
            avgConfidence = 1.0 // Native text only
        }

        let extractionTime = Int(Date().timeIntervalSince(startTime) * 1000)

        return ExtractionResult(
            text: combinedText,
            method: method,
            confidence: avgConfidence,
            pageCount: pageCount,
            extractionTimeMs: extractionTime
        )
    }

    // MARK: - Image Extraction

    private func extractFromImage(url: URL, startTime: Date) async throws -> ExtractionResult {
        do {
            let ocrResult = try await ocrExtractor.recognize(imageURL: url)

            let extractionTime = Int(Date().timeIntervalSince(startTime) * 1000)

            return ExtractionResult(
                text: ocrResult.text,
                method: .visionOCR,
                confidence: ocrResult.confidence,
                pageCount: 1,
                extractionTimeMs: extractionTime
            )
        } catch let error as MonitorOCRError {
            throw ContentExtractorError.ocrFailed(error)
        }
    }
}

// MARK: - ExtractionResult Extensions

extension ExtractionResult {
    /// Convert to ExtractionDetails for logging
    var asExtractionDetails: ExtractionDetails {
        ExtractionDetails(
            method: method,
            confidence: confidence,
            pageCount: pageCount,
            extractionTimeMs: extractionTimeMs,
            textLength: text.count
        )
    }

    /// Check if the extraction produced meaningful content
    var hasMeaningfulContent: Bool {
        let wordCount = text.split(separator: " ").count
        return wordCount >= 10
    }
}
