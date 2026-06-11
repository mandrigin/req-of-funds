import Foundation
import Vision
import CoreGraphics
import PDFKit

// MARK: - OCR Result

/// Result of OCR extraction from an image
struct OCRResult {
    /// Extracted text from the image
    let text: String

    /// Average confidence score (0.0-1.0) across all recognized text observations
    let confidence: Float

    /// Number of text observations found
    let observationCount: Int

    /// Time taken for OCR in milliseconds
    let processingTimeMs: Int
}

// MARK: - OCR Error

/// Errors that can occur during OCR extraction
enum MonitorOCRError: LocalizedError {
    case imageCreationFailed
    case recognitionFailed(Error)
    case noTextFound
    case timeout
    case pdfRenderingFailed
    case pdfPageNotFound(Int)

    var errorDescription: String? {
        switch self {
        case .imageCreationFailed:
            return "Failed to create image for OCR processing"
        case .recognitionFailed(let error):
            return "Text recognition failed: \(error.localizedDescription)"
        case .noTextFound:
            return "No text was found in the image"
        case .timeout:
            return "OCR operation timed out"
        case .pdfRenderingFailed:
            return "Failed to render PDF page to image"
        case .pdfPageNotFound(let index):
            return "PDF page at index \(index) not found"
        }
    }
}

// MARK: - OCR Extractor

/// Vision framework OCR extractor for images and PDF pages
final class OCRExtractor {

    // MARK: - Constants

    /// Default DPI for rendering PDF pages (spec: 150 DPI)
    static let defaultDPI: CGFloat = 150.0

    /// Default timeout for OCR operations (spec: 30 seconds)
    static let defaultTimeoutSeconds: TimeInterval = 30.0

    // MARK: - Properties

    /// Languages to use for OCR (e.g., ["en-US", "de-DE"])
    private let languages: [String]

    /// Timeout for OCR operations
    private let timeout: TimeInterval

    // MARK: - Initialization

    /// Create an OCR extractor with specified languages
    /// - Parameters:
    ///   - languages: Recognition languages (e.g., ["en-US"])
    ///   - timeout: Timeout in seconds (default: 30)
    init(languages: [String] = ["en-US"], timeout: TimeInterval = defaultTimeoutSeconds) {
        self.languages = languages
        self.timeout = timeout
    }

    // MARK: - Public API

    /// Perform OCR on a CGImage
    /// - Parameter image: The image to extract text from
    /// - Returns: OCR result with text and confidence
    func recognize(image: CGImage) async throws -> OCRResult {
        let startTime = Date()

        return try await withThrowingTaskGroup(of: OCRResult.self) { group in
            // Add the OCR task
            group.addTask {
                try await self.performRecognition(image: image, startTime: startTime)
            }

            // Add timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.timeout * 1_000_000_000))
                throw MonitorOCRError.timeout
            }

            // Return first completed result (either OCR or timeout)
            guard let result = try await group.next() else {
                throw MonitorOCRError.noTextFound
            }

            // Cancel remaining tasks
            group.cancelAll()

            return result
        }
    }

    /// Perform OCR on a PDF page
    /// - Parameters:
    ///   - page: The PDF page to extract text from
    ///   - dpi: Resolution for rendering (default: 150 DPI)
    /// - Returns: OCR result with text and confidence
    func recognize(pdfPage page: PDFPage, dpi: CGFloat = defaultDPI) async throws -> OCRResult {
        guard let image = renderPDFPageToImage(page: page, dpi: dpi) else {
            throw MonitorOCRError.pdfRenderingFailed
        }
        return try await recognize(image: image)
    }

    /// Perform OCR on multiple PDF pages
    /// - Parameters:
    ///   - document: The PDF document
    ///   - pageIndices: Indices of pages to OCR (0-based)
    ///   - dpi: Resolution for rendering (default: 150 DPI)
    /// - Returns: Combined OCR result from all pages
    func recognize(pdfDocument document: PDFDocument, pageIndices: [Int], dpi: CGFloat = defaultDPI) async throws -> OCRResult {
        let startTime = Date()
        var allText = ""
        var totalConfidence: Float = 0.0
        var totalObservations = 0

        for index in pageIndices {
            guard let page = document.page(at: index) else {
                throw MonitorOCRError.pdfPageNotFound(index)
            }

            let pageResult = try await recognize(pdfPage: page, dpi: dpi)
            allText += pageResult.text
            if index < pageIndices.count - 1 {
                allText += "\n\n"
            }
            totalConfidence += pageResult.confidence * Float(pageResult.observationCount)
            totalObservations += pageResult.observationCount
        }

        let avgConfidence = totalObservations > 0 ? totalConfidence / Float(totalObservations) : 0.0
        let processingTime = Int(Date().timeIntervalSince(startTime) * 1000)

        return OCRResult(
            text: allText,
            confidence: avgConfidence,
            observationCount: totalObservations,
            processingTimeMs: processingTime
        )
    }

    /// Perform OCR on an image file URL
    /// - Parameter url: URL to the image file
    /// - Returns: OCR result with text and confidence
    func recognize(imageURL url: URL) async throws -> OCRResult {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw MonitorOCRError.imageCreationFailed
        }
        return try await recognize(image: image)
    }

    // MARK: - Private Methods

    private func performRecognition(image: CGImage, startTime: Date) async throws -> OCRResult {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: MonitorOCRError.recognitionFailed(error))
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation],
                      !observations.isEmpty else {
                    continuation.resume(throwing: MonitorOCRError.noTextFound)
                    return
                }

                // Extract text from top candidates
                let textLines = observations.compactMap { observation -> String? in
                    observation.topCandidates(1).first?.string
                }

                let text = textLines.joined(separator: "\n")

                // Calculate average confidence
                let confidences = observations.compactMap { observation -> Float? in
                    observation.topCandidates(1).first?.confidence
                }
                let avgConfidence = confidences.isEmpty ? 0.0 : confidences.reduce(0, +) / Float(confidences.count)

                let processingTime = Int(Date().timeIntervalSince(startTime) * 1000)

                let result = OCRResult(
                    text: text,
                    confidence: avgConfidence,
                    observationCount: observations.count,
                    processingTimeMs: processingTime
                )

                continuation.resume(returning: result)
            }

            // Configure request per spec
            request.recognitionLevel = .accurate
            request.recognitionLanguages = languages
            request.usesLanguageCorrection = true

            // Perform the request
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: MonitorOCRError.recognitionFailed(error))
            }
        }
    }

    // MARK: - PDF Rendering

    /// Render a PDF page to a CGImage at specified DPI
    /// - Parameters:
    ///   - page: The PDF page to render
    ///   - dpi: Resolution in dots per inch (default: 150)
    /// - Returns: Rendered CGImage or nil if rendering fails
    func renderPDFPageToImage(page: PDFPage, dpi: CGFloat = defaultDPI) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale = dpi / 72.0  // PDF points are 72 per inch
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)

        // Create RGB color space
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }

        // Create bitmap context
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        // Fill with white background
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Scale context to DPI
        context.scaleBy(x: scale, y: scale)

        // Draw PDF page
        // PDFPage.draw() expects the context to be set up for its coordinate system
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)

        page.draw(with: .mediaBox, to: context)

        return context.makeImage()
    }
}

// MARK: - Convenience Extensions

extension OCRExtractor {
    /// Create an OCR extractor using the current app configuration
    static func fromConfig() -> OCRExtractor {
        let config = ConfigManager.shared.config
        return OCRExtractor(
            languages: config.ocrLanguages,
            timeout: OCRExtractor.defaultTimeoutSeconds
        )
    }
}
