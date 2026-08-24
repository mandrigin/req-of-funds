import Foundation
import Combine

// MARK: - Processing Outcome

/// Detailed outcome of processing a file
enum ProcessingOutcome {
    case success(destination: URL)
    case skippedNotInvoice(confidence: Float)
    case skippedNoCompanyMatch
    case skippedAlreadyFiled
    case skippedExtractionFailed(Error)
    case skippedProtected
    case skippedNoContent
    case skippedDeleted
    case queuedForReview(confidence: Float)
    case failedMoveError(Error)
    case failedLocked

    var logOutcome: LogOutcome {
        switch self {
        case .success:
            return .success
        case .skippedNotInvoice:
            return .skippedNotInvoice
        case .queuedForReview:
            return .queuedForReview
        case .skippedNoCompanyMatch:
            return .skippedNoCompanyMatch
        case .skippedAlreadyFiled:
            return .skippedAlreadyFiled
        case .skippedExtractionFailed:
            return .skippedExtractionFailed
        case .skippedProtected:
            return .skippedProtected
        case .skippedNoContent:
            return .skippedNoContent
        case .skippedDeleted:
            return .skippedDeleted
        case .failedMoveError:
            return .failedMoveError
        case .failedLocked:
            return .failedLocked
        }
    }

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

// MARK: - Processing Result

/// Complete result of processing a file
struct ProcessingResultData {
    let file: URL
    let extraction: ExtractionResult?
    let invoiceClassification: InvoiceClassification?
    let companyMatch: CompanyMatchResult?
    let extractedDate: DateExtractionResult?
    let destinationFolder: URL?
    let outcome: ProcessingOutcome
    let processingTimeMs: Int
}

/// Everything the RFF import hook needs about a successfully filed invoice
struct FiledInvoice {
    let originalURL: URL
    let destinationURL: URL
    let extractedText: String
    let companyName: String?
    let organizations: [String]
    let invoiceDate: Date
    let isSalary: Bool
}

// MARK: - Invoice Processor Delegate

/// Delegate protocol for processing events
protocol InvoiceProcessorDelegate: AnyObject {
    func processorDidStartProcessing(_ processor: InvoiceProcessor, file: URL)
    func processorDidFinishProcessing(_ processor: InvoiceProcessor, result: ProcessingResultData)
    func processorDidEncounterError(_ processor: InvoiceProcessor, file: URL, error: Error)
}

// MARK: - Invoice Processor

/// Main processing loop for invoice filing
///
/// Implementation per spec section 5.3:
/// - Coordinates file events → debounce → extract → classify → match → organize → move
/// - Handles all edge cases from section 7
/// - Logs all operations
final class InvoiceProcessor {

    // MARK: - Properties

    private let contentExtractor: ContentExtractor
    private let invoiceClassifier: InvoiceClassifier
    private let companyMatcher: CompanyMatcher
    private let dateExtractor: DateExtractor
    private let organizer: Organizer
    private let mover: Mover
    private let logger: FilingLogger
    private let processingQueue: ProcessingQueue

    private let config: AppConfig

    /// AI classification cascade (Apple Intelligence -> Ollama -> review queue)
    private lazy var aiClassifier = AIInvoiceClassifier(
        keywordClassifier: invoiceClassifier,
        config: config
    )

    /// Called after a file is successfully moved into an invoice folder, so the
    /// coordinator can import it into the RFF library
    var onInvoiceFiled: ((FiledInvoice) -> Void)?

    weak var delegate: InvoiceProcessorDelegate?

    /// Cancellables for Combine subscriptions
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    /// Create a processor with all required components
    init(
        contentExtractor: ContentExtractor,
        invoiceClassifier: InvoiceClassifier,
        companyMatcher: CompanyMatcher,
        dateExtractor: DateExtractor,
        organizer: Organizer,
        mover: Mover,
        logger: FilingLogger,
        processingQueue: ProcessingQueue,
        config: AppConfig
    ) {
        self.contentExtractor = contentExtractor
        self.invoiceClassifier = invoiceClassifier
        self.companyMatcher = companyMatcher
        self.dateExtractor = dateExtractor
        self.organizer = organizer
        self.mover = mover
        self.logger = logger
        self.processingQueue = processingQueue
        self.config = config

        setupProcessingQueue()
    }

    /// Create a processor from the current app configuration
    static func fromConfig(logger: FilingLogger, processingQueue: ProcessingQueue) -> InvoiceProcessor {
        let config = ConfigManager.shared.config
        return InvoiceProcessor(
            contentExtractor: ContentExtractor.fromConfig(),
            invoiceClassifier: InvoiceClassifier.fromConfig(),
            companyMatcher: CompanyMatcher.fromConfig(),
            dateExtractor: DateExtractor(),
            organizer: Organizer.fromConfig(),
            mover: Mover(),
            logger: logger,
            processingQueue: processingQueue,
            config: config
        )
    }

    // MARK: - Setup

    private func setupProcessingQueue() {
        processingQueue.setProcessHandler { [weak self] url in
            await self?.processFile(at: url)
        }
    }

    // MARK: - Public API

    /// Start the processor
    func start() {
        processingQueue.start()
    }

    /// Stop the processor
    func stop() {
        processingQueue.stop()
    }

    /// Queue a file for processing
    func queueFile(_ url: URL) {
        processingQueue.enqueue(url)
    }

    /// File a document the user approved in the review queue (bypasses classification)
    func processApprovedFile(at url: URL) async {
        await processFile(at: url, forceInvoice: true)
    }

    /// Queue multiple files for processing
    func queueFiles(_ urls: [URL]) {
        processingQueue.enqueue(urls)
    }

    /// Subscribe to debounced file events
    func subscribe(to debouncer: Debouncer) {
        debouncer.readyFiles
            .sink { [weak self] debouncedFile in
                self?.queueFile(debouncedFile.url)
            }
            .store(in: &cancellables)
    }

    // MARK: - Processing Logic

    /// Process a single file through the full pipeline
    private func processFile(at url: URL, forceInvoice: Bool = false) async {
        let startTime = Date()

        // Respect prior user decisions from the review queue (pending or "not an invoice")
        if !forceInvoice, await ReviewQueueStore.shared.shouldSkip(url) {
            return
        }

        delegate?.processorDidStartProcessing(self, file: url)

        // Track intermediate results for logging
        var extraction: ExtractionResult?
        var classification: InvoiceClassification?
        var companyMatch: CompanyMatchResult?
        var dateResult: DateExtractionResult?

        // 1. Check if file still exists (may have been deleted during debounce)
        guard FileManager.default.fileExists(atPath: url.path) else {
            let result = ProcessingResultData(
                file: url,
                extraction: nil,
                invoiceClassification: nil,
                companyMatch: nil,
                extractedDate: nil,
                destinationFolder: nil,
                outcome: .skippedDeleted,
                processingTimeMs: elapsedMs(since: startTime)
            )
            logResult(result)
            delegate?.processorDidFinishProcessing(self, result: result)
            return
        }

        // 2. Idempotency check - skip if already in invoice folder
        if organizer.isInInvoiceFolder(url) {
            let result = ProcessingResultData(
                file: url,
                extraction: nil,
                invoiceClassification: nil,
                companyMatch: nil,
                extractedDate: nil,
                destinationFolder: nil,
                outcome: .skippedAlreadyFiled,
                processingTimeMs: elapsedMs(since: startTime)
            )
            logResult(result)
            delegate?.processorDidFinishProcessing(self, result: result)
            return
        }

        // 3. Extract content
        do {
            extraction = try await contentExtractor.extract(from: url)
        } catch ContentExtractorError.pdfExtractionFailed(let pdfError) {
            // Check for password-protected PDF
            if case .documentUnreadable = pdfError {
                let result = ProcessingResultData(
                    file: url,
                    extraction: nil,
                    invoiceClassification: nil,
                    companyMatch: nil,
                    extractedDate: nil,
                    destinationFolder: nil,
                    outcome: .skippedProtected,
                    processingTimeMs: elapsedMs(since: startTime)
                )
                logResult(result)
                delegate?.processorDidFinishProcessing(self, result: result)
                return
            }

            let result = ProcessingResultData(
                file: url,
                extraction: nil,
                invoiceClassification: nil,
                companyMatch: nil,
                extractedDate: nil,
                destinationFolder: nil,
                outcome: .skippedExtractionFailed(pdfError),
                processingTimeMs: elapsedMs(since: startTime)
            )
            logResult(result)
            delegate?.processorDidFinishProcessing(self, result: result)
            return
        } catch {
            let result = ProcessingResultData(
                file: url,
                extraction: nil,
                invoiceClassification: nil,
                companyMatch: nil,
                extractedDate: nil,
                destinationFolder: nil,
                outcome: .skippedExtractionFailed(error),
                processingTimeMs: elapsedMs(since: startTime)
            )
            logResult(result)
            delegate?.processorDidFinishProcessing(self, result: result)
            return
        }

        guard let extractionResult = extraction else {
            let result = ProcessingResultData(
                file: url,
                extraction: nil,
                invoiceClassification: nil,
                companyMatch: nil,
                extractedDate: nil,
                destinationFolder: nil,
                outcome: .skippedNoContent,
                processingTimeMs: elapsedMs(since: startTime)
            )
            logResult(result)
            delegate?.processorDidFinishProcessing(self, result: result)
            return
        }

        // Check for meaningful content
        if !extractionResult.hasMeaningfulContent {
            let result = ProcessingResultData(
                file: url,
                extraction: extraction,
                invoiceClassification: nil,
                companyMatch: nil,
                extractedDate: nil,
                destinationFolder: nil,
                outcome: .skippedNoContent,
                processingTimeMs: elapsedMs(since: startTime)
            )
            logResult(result)
            delegate?.processorDidFinishProcessing(self, result: result)
            return
        }

        // 4. Salary slips are matched by keyword (filename or text) and bypass
        // invoice classification entirely - they are filed under Salary instead
        let isSalary = SalarySlipDetector.isSalarySlip(
            filename: url.lastPathComponent,
            text: extractionResult.text,
            config: config
        )

        // 5. Classify as invoice - AI cascade (Apple Intelligence -> Ollama -> review queue)
        // Keyword classification still runs for log details
        classification = invoiceClassifier.classify(extractionResult.text)

        var verdict: AIClassificationVerdict?
        if !forceInvoice && !isSalary {
            let aiVerdict = await aiClassifier.classify(text: extractionResult.text)
            verdict = aiVerdict

            if aiVerdict.needsReview {
                // Suspicious: park it in the manual confirmation queue, leave the file in place
                let suggestedDate = dateExtractor.extract(
                    from: extractionResult.text,
                    fileURL: url,
                    dateSource: config.dateSource
                ).date
                let item = ReviewQueueItem(
                    id: UUID(),
                    filePath: url.path,
                    fileName: url.lastPathComponent,
                    confidence: aiVerdict.confidence,
                    primaryConfidence: aiVerdict.primaryConfidence,
                    stage: aiVerdict.stage,
                    organizations: aiVerdict.organizations,
                    textSnippet: String(extractionResult.text.prefix(400)),
                    suggestedDate: suggestedDate,
                    queuedAt: Date()
                )
                await MainActor.run { ReviewQueueStore.shared.enqueue(item) }

                let result = ProcessingResultData(
                    file: url,
                    extraction: extraction,
                    invoiceClassification: classification,
                    companyMatch: nil,
                    extractedDate: nil,
                    destinationFolder: nil,
                    outcome: .queuedForReview(confidence: aiVerdict.confidence),
                    processingTimeMs: elapsedMs(since: startTime)
                )
                logResult(result)
                delegate?.processorDidFinishProcessing(self, result: result)
                return
            }

            guard aiVerdict.isInvoice else {
                let result = ProcessingResultData(
                    file: url,
                    extraction: extraction,
                    invoiceClassification: classification,
                    companyMatch: nil,
                    extractedDate: nil,
                    destinationFolder: nil,
                    outcome: .skippedNotInvoice(confidence: aiVerdict.confidence),
                    processingTimeMs: elapsedMs(since: startTime)
                )
                logResult(result)
                delegate?.processorDidFinishProcessing(self, result: result)
                return
            }
        }

        // 5. Match company
        companyMatch = companyMatcher.match(
            text: extractionResult.text,
            filename: config.enableFilenameHint ? url.lastPathComponent : nil
        )

        // AI-extracted organization names act as a second matching signal
        if companyMatch == nil, let organizations = verdict?.organizations, !organizations.isEmpty {
            companyMatch = companyMatcher.match(
                text: organizations.joined(separator: "\n"),
                filename: nil
            )
        }

        // User-approved files and salary slips get filed even without a company match
        guard companyMatch != nil || forceInvoice || isSalary else {
            let result = ProcessingResultData(
                file: url,
                extraction: extraction,
                invoiceClassification: classification,
                companyMatch: nil,
                extractedDate: nil,
                destinationFolder: nil,
                outcome: .skippedNoCompanyMatch,
                processingTimeMs: elapsedMs(since: startTime)
            )
            logResult(result)
            delegate?.processorDidFinishProcessing(self, result: result)
            return
        }

        // 6. Extract date
        dateResult = dateExtractor.extract(
            from: extractionResult.text,
            fileURL: url,
            dateSource: config.dateSource
        )

        let invoiceDate = dateResult?.date ?? Date()

        // 7. Resolve destination
        let organization: OrganizationResult
        do {
            organization = try organizer.organize(
                sourceFile: url,
                extractedDate: invoiceDate,
                subfolder: isSalary ? Organizer.salarySubfolder : nil
            )
        } catch OrganizerError.alreadyInInvoiceFolder {
            let result = ProcessingResultData(
                file: url,
                extraction: extraction,
                invoiceClassification: classification,
                companyMatch: companyMatch,
                extractedDate: dateResult,
                destinationFolder: nil,
                outcome: .skippedAlreadyFiled,
                processingTimeMs: elapsedMs(since: startTime)
            )
            logResult(result)
            delegate?.processorDidFinishProcessing(self, result: result)
            return
        } catch {
            let result = ProcessingResultData(
                file: url,
                extraction: extraction,
                invoiceClassification: classification,
                companyMatch: companyMatch,
                extractedDate: dateResult,
                destinationFolder: nil,
                outcome: .failedMoveError(error),
                processingTimeMs: elapsedMs(since: startTime)
            )
            logResult(result)
            delegate?.processorDidFinishProcessing(self, result: result)
            return
        }

        // 8. Execute move
        do {
            let moveResult = try await mover.moveWithRetry(
                from: url,
                to: organization.destinationPath
            )

            // Use actual destination path (may differ due to collision handling)
            let actualDestination = moveResult.destinationPath

            if moveResult.hadCollision {
                logger.logCollision(
                    sourcePath: url,
                    intendedPath: organization.destinationPath,
                    actualPath: actualDestination,
                    suffix: moveResult.collisionSuffix
                )
            }

            let result = ProcessingResultData(
                file: url,
                extraction: extraction,
                invoiceClassification: classification,
                companyMatch: companyMatch,
                extractedDate: dateResult,
                destinationFolder: organization.destinationFolder,
                outcome: .success(destination: actualDestination),
                processingTimeMs: elapsedMs(since: startTime)
            )
            logResult(result)
            delegate?.processorDidFinishProcessing(self, result: result)

            // Hand off to the RFF library import hook
            if config.importsToRFF {
                onInvoiceFiled?(FiledInvoice(
                    originalURL: url,
                    destinationURL: actualDestination,
                    extractedText: extractionResult.text,
                    companyName: companyMatch?.company.name,
                    organizations: verdict?.organizations ?? [],
                    invoiceDate: invoiceDate,
                    isSalary: isSalary
                ))
            }

        } catch let error as MoverError where error.errorCode == "file_locked" {
            let result = ProcessingResultData(
                file: url,
                extraction: extraction,
                invoiceClassification: classification,
                companyMatch: companyMatch,
                extractedDate: dateResult,
                destinationFolder: organization.destinationFolder,
                outcome: .failedLocked,
                processingTimeMs: elapsedMs(since: startTime)
            )
            logResult(result)
            delegate?.processorDidFinishProcessing(self, result: result)

        } catch {
            let result = ProcessingResultData(
                file: url,
                extraction: extraction,
                invoiceClassification: classification,
                companyMatch: companyMatch,
                extractedDate: dateResult,
                destinationFolder: organization.destinationFolder,
                outcome: .failedMoveError(error),
                processingTimeMs: elapsedMs(since: startTime)
            )
            logResult(result)
            delegate?.processorDidFinishProcessing(self, result: result)
        }
    }

    // MARK: - Logging

    private func logResult(_ result: ProcessingResultData) {
        let destinationPath: URL?
        if case .success(let dest) = result.outcome {
            destinationPath = dest
        } else {
            destinationPath = nil
        }

        let fileSize = getFileSize(result.file)

        var errorCode: String?
        var errorMessage: String?

        switch result.outcome {
        case .skippedExtractionFailed(let error):
            errorCode = "extraction_failed"
            errorMessage = error.localizedDescription
        case .failedMoveError(let error):
            errorCode = "move_error"
            errorMessage = error.localizedDescription
        case .failedLocked:
            errorCode = "file_locked"
            errorMessage = "File was locked after max retries"
        default:
            break
        }

        logger.log(
            action: "move",
            outcome: result.outcome.logOutcome,
            sourcePath: result.file,
            destinationPath: destinationPath,
            fileSize: fileSize,
            extraction: result.extraction?.asExtractionDetails,
            invoiceClassification: result.invoiceClassification?.asClassificationDetails,
            companyMatch: result.companyMatch?.asCompanyMatchDetails,
            dateExtraction: result.extractedDate?.asExtractionDetails(),
            processingTimeMs: result.processingTimeMs,
            errorCode: errorCode,
            errorMessage: errorMessage
        )
    }

    // MARK: - Helpers

    private func elapsedMs(since startTime: Date) -> Int {
        return Int(Date().timeIntervalSince(startTime) * 1000)
    }

    private func getFileSize(_ url: URL) -> Int64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return attributes[.size] as? Int64 ?? 0
        } catch {
            return 0
        }
    }
}
