import Foundation
import Combine

/// Result of a debounced file ready for processing
struct DebouncedFile: Equatable {
    /// The canonical URL of the file
    let url: URL

    /// The original event type that triggered processing
    let eventType: FileWatcherEvent
}

/// Outcome of stability check
enum StabilityResult {
    /// File is stable and ready for processing
    case stable

    /// File is still changing, retry later
    case unstable

    /// File no longer exists
    case missing

    /// Max retries exceeded
    case maxRetriesExceeded
}

/// Protocol for debouncer to enable testing
protocol DebouncerProtocol {
    var readyFiles: AnyPublisher<DebouncedFile, Never> { get }
    func process(event: FileWatcherEvent)
    func cancel(url: URL)
    func cancelAll()
    var pendingCount: Int { get }
}

/// Debounces file events to prevent processing during downloads or rapid modifications
final class Debouncer: DebouncerProtocol {
    // MARK: - Types

    /// Internal state for a pending file
    private struct PendingFile {
        let url: URL
        let canonicalPath: String
        let originalEvent: FileWatcherEvent
        var timer: DispatchWorkItem?
        var stabilityCheckCount: Int = 0
        var lastKnownSize: UInt64?
    }

    // MARK: - Properties

    /// Publisher for files ready to process
    private let readySubject = PassthroughSubject<DebouncedFile, Never>()

    /// Public publisher for ready files
    var readyFiles: AnyPublisher<DebouncedFile, Never> {
        readySubject.eraseToAnyPublisher()
    }

    /// Debounce interval in seconds
    private let debounceInterval: TimeInterval

    /// Stability check interval in seconds
    private let stabilityCheckInterval: TimeInterval = 0.5

    /// Maximum stability checks before skipping
    private let maxStabilityChecks: Int = 5

    /// Queue for timer operations
    private let timerQueue = DispatchQueue(label: "com.invoicefiler.debouncer", qos: .utility)

    /// Pending files by canonical path
    private var pendingFiles: [String: PendingFile] = [:]

    /// Lock for thread-safe access to pendingFiles
    private let lock = NSLock()

    /// Set of paths currently being processed (deduplication)
    private var processingPaths: Set<String> = []

    /// FilingLogger for skipped files
    private var logger: FilingLogger?

    // MARK: - Public Properties

    /// Number of files currently pending
    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingFiles.count
    }

    // MARK: - Initialization

    /// Initialize with debounce interval
    /// - Parameter debounceInterval: Seconds to wait after last event before processing
    init(debounceInterval: TimeInterval = 3.0) {
        self.debounceInterval = debounceInterval
    }

    /// Configure with a logger for skipped file notifications
    func configure(logger: FilingLogger) {
        self.logger = logger
    }

    // MARK: - Public Methods

    /// Process a file watcher event
    /// - Parameter event: The file event to debounce
    func process(event: FileWatcherEvent) {
        let url = event.url

        // Resolve to canonical path for deduplication
        guard let canonicalPath = resolveCanonicalPath(url) else {
            return // File doesn't exist or can't be resolved
        }

        lock.lock()

        // Check if already being processed
        if processingPaths.contains(canonicalPath) {
            lock.unlock()
            return
        }

        // Cancel existing timer if present
        if let existing = pendingFiles[canonicalPath] {
            existing.timer?.cancel()
        }

        // Create new pending file entry
        var pending = PendingFile(
            url: url,
            canonicalPath: canonicalPath,
            originalEvent: event
        )

        // Schedule new timer
        let workItem = createTimerWorkItem(for: canonicalPath)
        pending.timer = workItem
        pendingFiles[canonicalPath] = pending

        lock.unlock()

        // Schedule the work item
        timerQueue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    /// Cancel pending processing for a specific URL
    /// - Parameter url: The URL to cancel
    func cancel(url: URL) {
        guard let canonicalPath = resolveCanonicalPath(url) else { return }

        lock.lock()
        defer { lock.unlock() }

        if let pending = pendingFiles.removeValue(forKey: canonicalPath) {
            pending.timer?.cancel()
        }
    }

    /// Cancel all pending processing
    func cancelAll() {
        lock.lock()
        defer { lock.unlock() }

        for (_, pending) in pendingFiles {
            pending.timer?.cancel()
        }
        pendingFiles.removeAll()
    }

    // MARK: - Private Methods

    /// Create a timer work item for a pending file
    private func createTimerWorkItem(for canonicalPath: String) -> DispatchWorkItem {
        return DispatchWorkItem { [weak self] in
            self?.handleTimerFired(canonicalPath: canonicalPath)
        }
    }

    /// Handle timer firing for a pending file
    private func handleTimerFired(canonicalPath: String) {
        lock.lock()
        guard var pending = pendingFiles[canonicalPath] else {
            lock.unlock()
            return
        }
        lock.unlock()

        // Perform stability check
        let stabilityResult = checkStability(for: pending.url, previousSize: pending.lastKnownSize)

        switch stabilityResult {
        case .stable:
            // File is stable, emit ready event
            emitReady(pending: pending)

        case .unstable:
            // File is still changing, schedule another check
            pending.stabilityCheckCount += 1

            if pending.stabilityCheckCount >= maxStabilityChecks {
                // Max retries exceeded
                logSkipped(url: pending.url, reason: .skippedUnstable)
                removePending(canonicalPath: canonicalPath)
            } else {
                // Update last known size and schedule another check
                pending.lastKnownSize = getFileSize(pending.url)

                lock.lock()
                let workItem = createTimerWorkItem(for: canonicalPath)
                pending.timer = workItem
                pendingFiles[canonicalPath] = pending
                lock.unlock()

                timerQueue.asyncAfter(deadline: .now() + stabilityCheckInterval, execute: workItem)
            }

        case .missing:
            // File was deleted, just remove from pending
            removePending(canonicalPath: canonicalPath)

        case .maxRetriesExceeded:
            // Should not happen here, but handle defensively
            logSkipped(url: pending.url, reason: .skippedUnstable)
            removePending(canonicalPath: canonicalPath)
        }
    }

    /// Check if file is stable (size unchanged over interval)
    private func checkStability(for url: URL, previousSize: UInt64?) -> StabilityResult {
        guard let currentSize = getFileSize(url) else {
            return .missing
        }

        // If we don't have a previous size, get one and wait
        guard let prevSize = previousSize else {
            // First check - need to wait and check again
            Thread.sleep(forTimeInterval: stabilityCheckInterval)

            guard let newSize = getFileSize(url) else {
                return .missing
            }

            if currentSize == newSize && newSize > 0 {
                return .stable
            } else {
                return .unstable
            }
        }

        // We have previous size, compare
        if currentSize == prevSize && currentSize > 0 {
            return .stable
        } else {
            return .unstable
        }
    }

    /// Get file size or nil if file doesn't exist
    private func getFileSize(_ url: URL) -> UInt64? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return attributes[.size] as? UInt64
        } catch {
            return nil
        }
    }

    /// Emit ready event for a stable file
    private func emitReady(pending: PendingFile) {
        lock.lock()
        pendingFiles.removeValue(forKey: pending.canonicalPath)
        processingPaths.insert(pending.canonicalPath)
        lock.unlock()

        let debouncedFile = DebouncedFile(
            url: pending.url,
            eventType: pending.originalEvent
        )

        readySubject.send(debouncedFile)

        // Remove from processing after a short delay to prevent immediate re-processing
        timerQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.lock.lock()
            self?.processingPaths.remove(pending.canonicalPath)
            self?.lock.unlock()
        }
    }

    /// Remove a pending file
    private func removePending(canonicalPath: String) {
        lock.lock()
        if let pending = pendingFiles.removeValue(forKey: canonicalPath) {
            pending.timer?.cancel()
        }
        lock.unlock()
    }

    /// Log a skipped file
    private func logSkipped(url: URL, reason: LogOutcome) {
        logger?.log(
            action: "process",
            outcome: reason,
            sourcePath: url,
            processingTimeMs: Int(debounceInterval * 1000)
        )
    }

    /// Resolve URL to canonical path (resolving symlinks)
    private func resolveCanonicalPath(_ url: URL) -> String? {
        let resolvedURL = url.resolvingSymlinksInPath()
        let standardizedPath = resolvedURL.standardized.path

        // Verify file exists
        guard FileManager.default.fileExists(atPath: standardizedPath) else {
            return nil
        }

        return standardizedPath
    }

    // MARK: - Combine Integration

    /// Create a publisher that subscribes to FileWatcher events and emits debounced files
    func subscribe(to fileWatcher: FileWatcherProtocol) -> AnyCancellable {
        return fileWatcher.events
            .sink { [weak self] event in
                self?.process(event: event)
            }
    }
}

// MARK: - Convenience Extensions

extension Debouncer {
    /// Mark a file as processed (call after successful processing)
    func markProcessed(url: URL) {
        guard let canonicalPath = resolveCanonicalPath(url) else { return }

        lock.lock()
        processingPaths.remove(canonicalPath)
        lock.unlock()
    }
}
