import Foundation

// MARK: - Log Entry Models

/// Outcome types for log entries
enum LogOutcome: String, Codable {
    case success
    case skippedNotInvoice = "skipped:not-invoice"
    case skippedNoCompanyMatch = "skipped:no-company-match"
    case skippedAlreadyFiled = "skipped:already-filed"
    case skippedLocked = "skipped:locked"
    case skippedUnstable = "skipped:unstable"
    case skippedExtractionFailed = "skipped:extraction-failed"
    case skippedProtected = "skipped:protected"
    case skippedNoContent = "skipped:no-content"
    case skippedDeleted = "skipped:deleted"
    case queuedForReview = "queued:review"
    case failedMoveError = "failed:move-error"
    case failedLocked = "failed:locked"
}

/// Extraction method used to get text from document
enum ExtractionMethod: String, Codable {
    case pdfKit
    case visionOCR
    case hybrid
}

/// Details about text extraction
struct ExtractionDetails: Codable {
    let method: ExtractionMethod
    let confidence: Float
    let pageCount: Int
    let extractionTimeMs: Int
    let textLength: Int
}

/// A keyword match during invoice classification
struct KeywordMatch: Codable {
    let keyword: String
    let category: String
    let weight: Float
}

/// Invoice classification details
struct InvoiceClassificationDetails: Codable {
    let isInvoice: Bool
    let confidence: Float
    let keywordMatches: [KeywordMatch]
    let structurePatterns: [String]
}

/// Signal type for company matching
enum MatchSignalType: String, Codable {
    case exactName
    case alias
    case fuzzy
    case taxId
    case domain
}

/// A signal contributing to company match
struct MatchSignal: Codable {
    let type: MatchSignalType
    let confidence: Float
    let matched: String?
}

/// Company match details
struct CompanyMatchDetails: Codable {
    let company: String
    let confidence: Float
    let signals: [MatchSignal]
}

/// Date extraction source
enum DateExtractionSource: String, Codable {
    case invoiceContent
    case fileCreationDate
    case fileModificationDate
    case currentDate
}

/// Date extraction details
struct DateExtractionDetails: Codable {
    let extractedDate: String
    let source: DateExtractionSource
    let pattern: String?
}

/// Main log entry structure matching spec section 3.8
struct LogEntry: Codable {
    let timestamp: String
    let eventId: String
    let action: String
    let outcome: LogOutcome
    let sourcePath: String
    let destinationPath: String?
    let filename: String
    let fileSize: Int64

    let extraction: ExtractionDetails?
    let invoiceClassification: InvoiceClassificationDetails?
    let companyMatch: CompanyMatchDetails?
    let dateExtraction: DateExtractionDetails?

    let processingTimeMs: Int
    let errorCode: String?
    let errorMessage: String?
}

// MARK: - FilingLogger

/// JSONL logger with rotation support
class FilingLogger {

    // MARK: - Constants

    private static let maxFileSize: Int64 = 10 * 1024 * 1024 // 10 MB
    private static let maxRotatedFiles = 12

    // MARK: - Properties

    private let logPath: URL
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let dateFormatter: ISO8601DateFormatter
    private var fileHandle: FileHandle?
    private let queue = DispatchQueue(label: "com.invoicefiler.logger", qos: .utility)

    // MARK: - Initialization

    init(logPath: URL? = nil) {
        // Default: ~/Library/Logs/InvoiceFiler/moves.jsonl
        if let path = logPath {
            self.logPath = path
        } else {
            let logsDir = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Logs")
                .appendingPathComponent("RFF")
            self.logPath = logsDir.appendingPathComponent("moves.jsonl")
        }

        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]

        self.dateFormatter = ISO8601DateFormatter()
        self.dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        ensureLogDirectoryExists()
    }

    deinit {
        closeFileHandle()
    }

    // MARK: - Public API

    /// Log a processing event
    func log(
        action: String = "move",
        outcome: LogOutcome,
        sourcePath: URL,
        destinationPath: URL? = nil,
        fileSize: Int64 = 0,
        extraction: ExtractionDetails? = nil,
        invoiceClassification: InvoiceClassificationDetails? = nil,
        companyMatch: CompanyMatchDetails? = nil,
        dateExtraction: DateExtractionDetails? = nil,
        processingTimeMs: Int = 0,
        errorCode: String? = nil,
        errorMessage: String? = nil
    ) {
        let entry = LogEntry(
            timestamp: dateFormatter.string(from: Date()),
            eventId: UUID().uuidString,
            action: action,
            outcome: outcome,
            sourcePath: sourcePath.path,
            destinationPath: destinationPath?.path,
            filename: sourcePath.lastPathComponent,
            fileSize: fileSize,
            extraction: extraction,
            invoiceClassification: invoiceClassification,
            companyMatch: companyMatch,
            dateExtraction: dateExtraction,
            processingTimeMs: processingTimeMs,
            errorCode: errorCode,
            errorMessage: errorMessage
        )

        appendEntry(entry)
    }

    /// Log a path collision event
    func logCollision(
        sourcePath: URL,
        intendedPath: URL,
        actualPath: URL,
        suffix: Int?
    ) {
        let entry = LogEntry(
            timestamp: dateFormatter.string(from: Date()),
            eventId: UUID().uuidString,
            action: "collision",
            outcome: .success,
            sourcePath: sourcePath.path,
            destinationPath: actualPath.path,
            filename: sourcePath.lastPathComponent,
            fileSize: 0,
            extraction: nil,
            invoiceClassification: nil,
            companyMatch: nil,
            dateExtraction: nil,
            processingTimeMs: 0,
            errorCode: nil,
            errorMessage: "Collision resolved: \(intendedPath.lastPathComponent) → \(actualPath.lastPathComponent) (suffix: \(suffix ?? 0))"
        )

        appendEntry(entry)
    }

    /// Get the current log file path
    var currentLogPath: URL {
        return logPath
    }

    // MARK: - Private Methods

    private func ensureLogDirectoryExists() {
        let directory = logPath.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func appendEntry(_ entry: LogEntry) {
        queue.async { [weak self] in
            guard let self = self else { return }

            // Check rotation before writing
            self.rotateIfNeeded()

            // Encode entry to JSON
            guard let jsonData = try? self.encoder.encode(entry),
                  var jsonString = String(data: jsonData, encoding: .utf8) else {
                return
            }

            // Append newline for JSONL format
            jsonString += "\n"

            // Write to file
            self.writeToFile(jsonString)
        }
    }

    private func writeToFile(_ content: String) {
        guard let data = content.data(using: .utf8) else { return }

        // Create file if it doesn't exist
        if !fileManager.fileExists(atPath: logPath.path) {
            fileManager.createFile(atPath: logPath.path, contents: nil)
        }

        // Open file handle if needed
        if fileHandle == nil {
            fileHandle = try? FileHandle(forWritingTo: logPath)
            fileHandle?.seekToEndOfFile()
        }

        // Write and flush
        if let handle = fileHandle {
            handle.write(data)
            // fflush equivalent - synchronize to disk
            try? handle.synchronize()
        }
    }

    private func rotateIfNeeded() {
        guard let attributes = try? fileManager.attributesOfItem(atPath: logPath.path),
              let fileSize = attributes[.size] as? Int64 else {
            return
        }

        if fileSize > Self.maxFileSize {
            rotate()
        }
    }

    private func rotate() {
        // Close current handle
        closeFileHandle()

        // Generate rotated filename with timestamp
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")

        let directory = logPath.deletingLastPathComponent()
        let rotatedName = "moves-\(timestamp).jsonl"
        let rotatedPath = directory.appendingPathComponent(rotatedName)

        // Rename current file
        try? fileManager.moveItem(at: logPath, to: rotatedPath)

        // Clean up old rotated files
        cleanupOldRotatedFiles()
    }

    private func cleanupOldRotatedFiles() {
        let directory = logPath.deletingLastPathComponent()

        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey]) else {
            return
        }

        // Find rotated log files (moves-*.jsonl but not moves.jsonl)
        let rotatedFiles = files.filter { url in
            let name = url.lastPathComponent
            return name.hasPrefix("moves-") && name.hasSuffix(".jsonl")
        }

        // Sort by creation date (oldest first)
        let sortedFiles = rotatedFiles.sorted { url1, url2 in
            let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
            let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
            return date1 < date2
        }

        // Delete oldest files if we have more than max
        let filesToDelete = max(0, sortedFiles.count - Self.maxRotatedFiles)
        for i in 0..<filesToDelete {
            try? fileManager.removeItem(at: sortedFiles[i])
        }
    }

    private func closeFileHandle() {
        try? fileHandle?.close()
        fileHandle = nil
    }
}
