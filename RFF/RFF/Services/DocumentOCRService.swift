import Foundation
import Vision
import AppKit

/// Represents a recognized text observation with its metadata
struct TextObservation: Identifiable, Sendable {
    let id: UUID
    let text: String
    let confidence: Float
    let boundingBox: CGRect

    init(text: String, confidence: Float, boundingBox: CGRect) {
        self.id = UUID()
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

/// Result of OCR processing for a single page/image
struct OCRPageResult: Sendable {
    let pageIndex: Int
    let observations: [TextObservation]
    let fullText: String

    var isEmpty: Bool {
        observations.isEmpty
    }
}

/// Result of OCR processing for an entire document
struct OCRDocumentResult: Sendable {
    let pages: [OCRPageResult]
    let sourceURL: URL?

    var fullText: String {
        pages.map(\.fullText).joined(separator: "\n\n---\n\n")
    }

    var totalObservations: Int {
        pages.reduce(0) { $0 + $1.observations.count }
    }
}

/// Errors that can occur during OCR processing
enum OCRError: Error, LocalizedError {
    case imageLoadFailed(URL)
    case noTextFound
    case processingFailed(String)
    case userCancelled
    case invalidImageData

    var errorDescription: String? {
        switch self {
        case .imageLoadFailed(let url):
            return "Failed to load image from: \(url.path)"
        case .noTextFound:
            return "No text was found in the document"
        case .processingFailed(let reason):
            return "OCR processing failed: \(reason)"
        case .userCancelled:
            return "File selection was cancelled"
        case .invalidImageData:
            return "Invalid image data"
        }
    }
}

/// Service for performing OCR on documents using Apple Vision framework
actor DocumentOCRService {
    /// Maximum concurrent Vision requests
    private let maxConcurrentRequests: Int

    /// Custom vocabulary for financial document recognition
    private let customWords: [String] = [
        "RFF", "disbursement", "requisition",
        "funding", "allocation", "expenditure",
        "reimbursement", "invoice", "purchase order",
        "budget", "fiscal", "appropriation",
        "encumbrance", "voucher", "ledger",
        // Swiss document terms
        "CHF", "Franken", "Quellensteuer", "QST",
        "AHV", "Alters", "Hinterlassenenversicherung",
        "KTG", "Krankentaggeld", "Krankentaggeldversicherung",
        "UVG", "Unfallversicherung", "Prämie", "Beitrag",
        "Rechnung", "Betrag", "Fälligkeit", "MwSt", "MWST"
    ]

    /// Semaphore for limiting concurrent requests
    private let semaphore: DispatchSemaphore

    init(maxConcurrentRequests: Int = 8) {
        self.maxConcurrentRequests = maxConcurrentRequests
        self.semaphore = DispatchSemaphore(value: maxConcurrentRequests)
    }

    /// Presents a file picker and processes the selected document
    @MainActor
    func selectAndProcessDocument() async throws -> OCRDocumentResult {
        let url = try await selectFile()
        return try await processDocument(at: url)
    }

    /// Presents NSOpenPanel for file selection
    @MainActor
    private func selectFile() async throws -> URL {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.pdf, .png, .jpeg, .tiff, .heic]
        panel.message = "Select a document to scan"
        panel.prompt = "Scan Document"

        let response = await panel.begin()

        guard response == .OK, let url = panel.url else {
            throw OCRError.userCancelled
        }

        return url
    }

    /// Process a document at the given URL
    func processDocument(at url: URL) async throws -> OCRDocumentResult {
        let fileExtension = url.pathExtension.lowercased()

        if fileExtension == "pdf" {
            return try await processPDF(at: url)
        } else {
            let pageResult = try await processImage(at: url, pageIndex: 0)
            return OCRDocumentResult(pages: [pageResult], sourceURL: url)
        }
    }

    /// Process a PDF document page by page
    private func processPDF(at url: URL) async throws -> OCRDocumentResult {
        guard let pdfDocument = CGPDFDocument(url as CFURL) else {
            throw OCRError.imageLoadFailed(url)
        }

        let pageCount = pdfDocument.numberOfPages
        var results: [OCRPageResult] = []

        // Process pages with controlled concurrency
        try await withThrowingTaskGroup(of: OCRPageResult.self) { group in
            for pageIndex in 1...pageCount {
                group.addTask {
                    try await self.processPDFPage(
                        document: pdfDocument,
                        pageNumber: pageIndex,
                        pageIndex: pageIndex - 1
                    )
                }
            }

            for try await result in group {
                results.append(result)
            }
        }

        // Sort by page index
        results.sort { $0.pageIndex < $1.pageIndex }

        return OCRDocumentResult(pages: results, sourceURL: url)
    }

    /// Process a single PDF page
    private func processPDFPage(
        document: CGPDFDocument,
        pageNumber: Int,
        pageIndex: Int
    ) async throws -> OCRPageResult {
        // Limit concurrent requests
        semaphore.wait()
        defer { semaphore.signal() }

        return try await withCheckedThrowingContinuation { continuation in
            autoreleasepool {
                guard let page = document.page(at: pageNumber) else {
                    continuation.resume(throwing: OCRError.processingFailed("Could not access page \(pageNumber)"))
                    return
                }

                let pageRect = page.getBoxRect(.mediaBox)
                let scale: CGFloat = 2.0 // Higher resolution for better OCR
                let width = Int(pageRect.width * scale)
                let height = Int(pageRect.height * scale)

                guard let context = CGContext(
                    data: nil,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else {
                    continuation.resume(throwing: OCRError.processingFailed("Could not create graphics context"))
                    return
                }

                context.setFillColor(CGColor.white)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.scaleBy(x: scale, y: scale)
                context.drawPDFPage(page)

                guard let cgImage = context.makeImage() else {
                    continuation.resume(throwing: OCRError.processingFailed("Could not render page to image"))
                    return
                }

                self.performOCR(on: cgImage, pageIndex: pageIndex) { result in
                    continuation.resume(with: result)
                }
            }
        }
    }

    /// Process a single image file
    private func processImage(at url: URL, pageIndex: Int) async throws -> OCRPageResult {
        semaphore.wait()
        defer { semaphore.signal() }

        return try await withCheckedThrowingContinuation { continuation in
            autoreleasepool {
                guard let nsImage = NSImage(contentsOf: url),
                      let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    continuation.resume(throwing: OCRError.imageLoadFailed(url))
                    return
                }

                self.performOCR(on: cgImage, pageIndex: pageIndex) { result in
                    continuation.resume(with: result)
                }
            }
        }
    }

    /// Process a CGImage directly
    func processImage(_ cgImage: CGImage) async throws -> OCRPageResult {
        semaphore.wait()
        defer { semaphore.signal() }

        return try await withCheckedThrowingContinuation { continuation in
            autoreleasepool {
                self.performOCR(on: cgImage, pageIndex: 0) { result in
                    continuation.resume(with: result)
                }
            }
        }
    }

    /// Process raw image data
    func processImageData(_ data: Data) async throws -> OCRPageResult {
        guard let nsImage = NSImage(data: data),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw OCRError.invalidImageData
        }

        return try await processImage(cgImage)
    }

    /// Perform OCR using Vision framework with modern async API when available
    private func performOCR(
        on image: CGImage,
        pageIndex: Int,
        completion: @escaping (Result<OCRPageResult, Error>) -> Void
    ) {
        // Use modern async RecognizeTextRequest API on macOS 15+
        if #available(macOS 15.0, *) {
            Task {
                do {
                    let result = try await performOCRModern(on: image, pageIndex: pageIndex)
                    completion(.success(result))
                } catch {
                    completion(.failure(error))
                }
            }
            return
        }

        // Fall back to completion handler API for older macOS
        performOCRLegacy(on: image, pageIndex: pageIndex, completion: completion)
    }

    /// Modern async Vision API (macOS 15+)
    @available(macOS 15.0, *)
    private func performOCRModern(on image: CGImage, pageIndex: Int) async throws -> OCRPageResult {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.customWords = customWords

        let observations = try await request.perform(on: image)

        var textObservations: [TextObservation] = []
        var textLines: [String] = []

        for observation in observations {
            guard let topCandidate = observation.topCandidates(1).first else {
                continue
            }

            let textObs = TextObservation(
                text: topCandidate.string,
                confidence: topCandidate.confidence,
                boundingBox: observation.boundingBox.cgRect
            )
            textObservations.append(textObs)
            textLines.append(topCandidate.string)
        }

        let fullText = textLines.joined(separator: "\n")
        return OCRPageResult(
            pageIndex: pageIndex,
            observations: textObservations,
            fullText: fullText
        )
    }

    /// Legacy completion-handler API (macOS 13-14)
    private func performOCRLegacy(
        on image: CGImage,
        pageIndex: Int,
        completion: @escaping (Result<OCRPageResult, Error>) -> Void
    ) {
        let request = VNRecognizeTextRequest { request, error in
            if let error = error {
                completion(.failure(OCRError.processingFailed(error.localizedDescription)))
                return
            }

            guard let observations = request.results as? [VNRecognizedTextObservation] else {
                completion(.success(OCRPageResult(pageIndex: pageIndex, observations: [], fullText: "")))
                return
            }

            var textObservations: [TextObservation] = []
            var textLines: [String] = []

            for observation in observations {
                guard let topCandidate = observation.topCandidates(1).first else {
                    continue
                }

                let textObs = TextObservation(
                    text: topCandidate.string,
                    confidence: topCandidate.confidence,
                    boundingBox: observation.boundingBox
                )
                textObservations.append(textObs)
                textLines.append(topCandidate.string)
            }

            let fullText = textLines.joined(separator: "\n")
            let result = OCRPageResult(
                pageIndex: pageIndex,
                observations: textObservations,
                fullText: fullText
            )

            completion(.success(result))
        }

        // Configure for accurate recognition
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.customWords = customWords

        // Use revision 3 for latest improvements (macOS 13+)
        if #available(macOS 13.0, *) {
            request.revision = VNRecognizeTextRequestRevision3
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        do {
            try handler.perform([request])
        } catch {
            completion(.failure(OCRError.processingFailed(error.localizedDescription)))
        }
    }

    /// Batch process multiple image URLs
    func processImages(at urls: [URL]) async throws -> [OCRDocumentResult] {
        try await withThrowingTaskGroup(of: OCRDocumentResult.self) { group in
            for url in urls {
                group.addTask {
                    try await self.processDocument(at: url)
                }
            }

            var results: [OCRDocumentResult] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }
    }
}
