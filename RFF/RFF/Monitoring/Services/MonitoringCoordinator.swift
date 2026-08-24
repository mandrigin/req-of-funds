import Foundation
import Combine
import SwiftData

// MARK: - Pipeline Status

enum MonitoringStatus: Equatable {
    case stopped
    case idle
    case processing(file: String)
    case error(String)

    var isRunning: Bool {
        if case .stopped = self { return false }
        return true
    }
}

/// Rolling counters for the dashboard / menu bar
struct MonitoringStats: Equatable {
    var filedToday = 0
    var filed24h = 0
    var skipped24h = 0
    var queuedTotal = 0
    var lastFiledName: String?
    var lastFiledAt: Date?

    // Report-month numbers (last month, due on the 12th), from the app DB
    var reportInbound = 0   // bills paid last month
    var reportOutbound = 0  // my invoices due last month
    var paidThisMonth = 0
}

// MARK: - Coordinator

/// Owns the whole monitoring pipeline (watch -> debounce -> classify -> file -> import)
/// and publishes state for the menu bar dashboard.
@MainActor
final class MonitoringCoordinator: ObservableObject {
    static let shared = MonitoringCoordinator()

    @Published private(set) var status: MonitoringStatus = .stopped
    @Published private(set) var stats = MonitoringStats()
    @Published private(set) var recentResults: [ProcessingResultData] = []

    private var fileWatcher: FileWatcher?
    private var debouncer: Debouncer?
    private var processingQueue: ProcessingQueue?
    private var processor: InvoiceProcessor?
    private var logger: FilingLogger?

    private var modelContainer: ModelContainer?
    private var cancellables = Set<AnyCancellable>()

    /// Destination paths already imported into the RFF library (dedupe across restarts)
    private var importedPaths: Set<String> = []
    private var importedPathsURL: URL {
        ConfigManager.shared.appSupportDirectory.appendingPathComponent("imported-files.json")
    }

    private init() {
        loadImportedPaths()
    }

    // MARK: - Lifecycle

    /// Called once at app launch with the SwiftData container for library imports
    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        refreshStats()
    }

    func start() {
        stop()

        let config = ConfigManager.shared.config
        guard !config.monitoredPaths.isEmpty else {
            status = .stopped
            return
        }

        try? ConfigManager.shared.ensureLogDirectoryExists()
        let logger = FilingLogger(logPath: config.logLocation)
        let queue = ProcessingQueue(maxConcurrent: 2)
        let processor = InvoiceProcessor.fromConfig(logger: logger, processingQueue: queue)
        processor.delegate = self
        processor.onInvoiceFiled = { [weak self] filed in
            Task { @MainActor in
                await self?.importIntoLibrary(filed)
            }
        }

        let debouncer = Debouncer(debounceInterval: config.debounceInterval)
        debouncer.configure(logger: logger)
        processor.subscribe(to: debouncer)

        let watcher = FileWatcher()
        watcher.configure(
            paths: config.monitoredPaths,
            supportedExtensions: config.supportedExtensions,
            exclusionPatterns: config.exclusionPatterns
        )
        watcher.events
            .sink { [weak debouncer] event in
                debouncer?.process(event: event)
            }
            .store(in: &cancellables)

        self.logger = logger
        self.processingQueue = queue
        self.processor = processor
        self.debouncer = debouncer
        self.fileWatcher = watcher

        do {
            try watcher.start()
        } catch {
            status = .error("Watcher failed: \(error.localizedDescription)")
            return
        }
        queue.start()
        processor.start()
        status = .idle

        ReviewQueueStore.shared.prune()
        refreshStats()
        scanExistingFiles()
    }

    func stop() {
        fileWatcher?.stop()
        processingQueue?.stop()
        processor?.stop()
        cancellables.removeAll()
        fileWatcher = nil
        debouncer = nil
        processingQueue = nil
        processor = nil
        status = .stopped
    }

    func restart() {
        start()
    }

    /// Pick up files that were already in the monitored folders at startup
    private func scanExistingFiles() {
        let config = ConfigManager.shared.config
        let fileManager = FileManager.default
        var urls: [URL] = []

        for monitored in config.monitoredPaths {
            let contents = (try? fileManager.contentsOfDirectory(
                at: monitored.path,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            for url in contents {
                var isDirectory: ObjCBool = false
                fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                guard !isDirectory.boolValue else { continue }
                guard ConfigManager.shared.isExtensionSupported(url.pathExtension) else { continue }
                guard !ConfigManager.shared.matchesExclusionPattern(url.lastPathComponent) else { continue }
                urls.append(url)
            }
        }

        if !urls.isEmpty {
            processor?.queueFiles(urls)
        }
    }

    // MARK: - Review Queue Actions

    /// User confirmed a queued document is an invoice: file it (and import to library)
    func approveReviewItem(_ item: ReviewQueueItem) {
        ReviewQueueStore.shared.approve(item)
        refreshStats()
        guard let processor else { return }
        Task {
            await processor.processApprovedFile(at: item.fileURL)
        }
    }

    /// User said a queued document is not an invoice: never ask again
    func rejectReviewItem(_ item: ReviewQueueItem) {
        ReviewQueueStore.shared.reject(item)
        refreshStats()
    }

    // MARK: - RFF Library Import

    /// Import a freshly filed invoice into the RFF document library (deduplicated)
    private func importIntoLibrary(_ filed: FiledInvoice) async {
        guard let modelContainer else { return }
        guard !importedPaths.contains(filed.destinationURL.path) else { return }

        do {
            // Mirror ContentView.processDroppedPDF: OCR -> entities -> RFFDocument
            let ocrResult = try await DocumentOCRService().processDocument(at: filed.destinationURL)
            let entities = try await EntityExtractionService().extractEntities(from: ocrResult)

            let docId = UUID()
            let storedPath = (try? DocumentStorageService.copyFile(from: filed.destinationURL, documentId: docId))
                ?? filed.destinationURL.path

            let organization = filed.companyName
                ?? entities.organizationName
                ?? filed.organizations.first
                ?? "Unknown Organization"

            let baseName = filed.originalURL.deletingPathExtension().lastPathComponent

            // Salary slips document money already paid: the pay date stands in for
            // the due date, and no payment-deadline reminder is scheduled
            let dueDate: Date
            if filed.isSalary {
                dueDate = entities.dueDate ?? filed.invoiceDate
            } else {
                dueDate = entities.dueDate ?? filed.invoiceDate.addingTimeInterval(30 * 24 * 60 * 60)
            }

            let document = RFFDocument(
                id: docId,
                title: baseName,
                requestingOrganization: organization,
                amount: entities.amount ?? Decimal(0),
                currency: entities.currency ?? .usd,
                dueDate: dueDate,
                extractedText: ocrResult.fullText,
                documentPath: storedPath
            )
            if filed.isSalary {
                document.documentCategory = DocumentCategory.salary.rawValue
                document.classificationConfidence = 1.0
            }

            let context = modelContainer.mainContext
            context.insert(document)
            try? context.save()

            importedPaths.insert(filed.destinationURL.path)
            saveImportedPaths()

            if !filed.isSalary {
                try? await NotificationService.shared.scheduleDeadlineNotification(
                    documentId: document.id,
                    title: document.title,
                    organization: document.requestingOrganization,
                    dueDate: document.dueDate
                )
            }
        } catch {
            // Filing succeeded; import is best-effort. Leave a trace in the status.
            status = .error("Library import failed: \(error.localizedDescription)")
        }
    }

    private func loadImportedPaths() {
        if let data = try? Data(contentsOf: importedPathsURL),
           let paths = try? JSONDecoder().decode([String].self, from: data) {
            importedPaths = Set(paths)
        }
    }

    private func saveImportedPaths() {
        if let data = try? JSONEncoder().encode(Array(importedPaths).sorted()) {
            try? data.write(to: importedPathsURL, options: .atomic)
        }
    }

    // MARK: - Stats

    func refreshStats() {
        var newStats = MonitoringStats()
        newStats.queuedTotal = ReviewQueueStore.shared.pendingCount

        // Report-month numbers come from the app DB (reporting source of truth)
        if let modelContainer {
            let lastMonth = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
            let lastMonthReport = ReportingService.report(for: lastMonth, context: modelContainer.mainContext)
            newStats.reportInbound = lastMonthReport.inbound.count
            newStats.reportOutbound = lastMonthReport.outbound.count

            let thisMonthReport = ReportingService.report(for: Date(), context: modelContainer.mainContext)
            newStats.paidThisMonth = thisMonthReport.inbound.count

            // Keep the every-12th reminder text in sync with live numbers
            AccountantReportService.scheduleReminder(
                inbound: lastMonthReport.inbound.count,
                outbound: lastMonthReport.outbound.count
            )
        }

        // Read the JSONL move log for 24h / today counters
        let config = ConfigManager.shared.config
        if let content = try? String(contentsOf: config.logLocation, encoding: .utf8) {
            let dayAgo = Date().addingTimeInterval(-24 * 3600)
            let startOfToday = Calendar.current.startOfDay(for: Date())
            let isoParser = ISO8601DateFormatter()
            let isoParserFractional = ISO8601DateFormatter()
            isoParserFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            for line in content.split(separator: "\n").suffix(2000) {
                guard let data = line.data(using: .utf8),
                      let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let timestampString = entry["timestamp"] as? String,
                      let timestamp = isoParserFractional.date(from: timestampString)
                        ?? isoParser.date(from: timestampString),
                      timestamp > dayAgo else {
                    continue
                }
                let outcome = entry["outcome"] as? String ?? ""
                if outcome == "success" {
                    newStats.filed24h += 1
                    if timestamp >= startOfToday { newStats.filedToday += 1 }
                    if let dest = entry["destination_path"] as? String ?? entry["destinationPath"] as? String {
                        newStats.lastFiledName = URL(fileURLWithPath: dest).lastPathComponent
                        newStats.lastFiledAt = timestamp
                    }
                } else if outcome.hasPrefix("skipped") {
                    newStats.skipped24h += 1
                }
            }
        }

        stats = newStats
    }
}

// MARK: - InvoiceProcessorDelegate

extension MonitoringCoordinator: InvoiceProcessorDelegate {
    nonisolated func processorDidStartProcessing(_ processor: InvoiceProcessor, file: URL) {
        Task { @MainActor in
            self.status = .processing(file: file.lastPathComponent)
        }
    }

    nonisolated func processorDidFinishProcessing(_ processor: InvoiceProcessor, result: ProcessingResultData) {
        Task { @MainActor in
            self.recentResults.insert(result, at: 0)
            if self.recentResults.count > 50 {
                self.recentResults.removeLast(self.recentResults.count - 50)
            }
            self.status = .idle
            self.refreshStats()
        }
    }

    nonisolated func processorDidEncounterError(_ processor: InvoiceProcessor, file: URL, error: Error) {
        Task { @MainActor in
            self.status = .error(error.localizedDescription)
        }
    }
}
