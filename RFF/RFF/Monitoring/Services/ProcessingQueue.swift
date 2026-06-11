import Foundation

// MARK: - Processing Queue

/// Manages concurrent file processing with limited OCR parallelism
///
/// Implementation per spec section 4:
/// - maxConcurrent = 2 for OCR operations
/// - Serial queue for file events
/// - Operation queue for OCR processing
final class ProcessingQueue {

    // MARK: - Types

    /// Priority levels for queued items
    enum Priority: Int, Comparable {
        case low = 0
        case normal = 1
        case high = 2

        static func < (lhs: Priority, rhs: Priority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// A queued processing item
    struct QueuedItem: Equatable {
        let url: URL
        let priority: Priority
        let queuedAt: Date

        static func == (lhs: QueuedItem, rhs: QueuedItem) -> Bool {
            lhs.url == rhs.url
        }
    }

    // MARK: - Properties

    /// Maximum concurrent OCR operations (per spec)
    private let maxConcurrent: Int

    /// Serial queue for coordinating access
    private let coordinationQueue = DispatchQueue(
        label: "com.invoicefiler.processingqueue.coordination",
        qos: .utility
    )

    /// Operation queue for OCR processing
    private let ocrOperationQueue: OperationQueue

    /// Pending items waiting to be processed
    private var pendingItems: [QueuedItem] = []

    /// Currently processing URLs
    private var processingURLs: Set<URL> = []

    /// Lock for thread-safe access
    private let lock = NSLock()

    /// Callback for processing items
    private var processHandler: ((URL) async -> Void)?

    /// Whether the queue is paused
    private(set) var isPaused: Bool = false

    /// Whether the queue has been started
    private(set) var isRunning: Bool = false

    // MARK: - Public Properties

    /// Number of items currently being processed
    var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return processingURLs.count
    }

    /// Number of items waiting to be processed
    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingItems.count
    }

    /// Total items in queue (pending + active)
    var totalCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingItems.count + processingURLs.count
    }

    // MARK: - Initialization

    /// Create a processing queue with the given concurrency limit
    /// - Parameter maxConcurrent: Maximum concurrent OCR operations (default 2)
    init(maxConcurrent: Int = 2) {
        self.maxConcurrent = maxConcurrent

        self.ocrOperationQueue = OperationQueue()
        self.ocrOperationQueue.name = "com.invoicefiler.ocr"
        self.ocrOperationQueue.maxConcurrentOperationCount = maxConcurrent
        self.ocrOperationQueue.qualityOfService = .utility
    }

    // MARK: - Configuration

    /// Set the handler called when an item is ready for processing
    /// - Parameter handler: Async handler that processes a URL
    func setProcessHandler(_ handler: @escaping (URL) async -> Void) {
        self.processHandler = handler
    }

    // MARK: - Queue Control

    /// Start the processing queue
    func start() {
        lock.lock()
        isRunning = true
        isPaused = false
        lock.unlock()

        processNextIfAvailable()
    }

    /// Stop the processing queue
    func stop() {
        lock.lock()
        isRunning = false
        lock.unlock()

        ocrOperationQueue.cancelAllOperations()
    }

    /// Pause processing (pending items remain queued)
    func pause() {
        lock.lock()
        isPaused = true
        lock.unlock()

        ocrOperationQueue.isSuspended = true
    }

    /// Resume processing
    func resume() {
        lock.lock()
        isPaused = false
        lock.unlock()

        ocrOperationQueue.isSuspended = false
        processNextIfAvailable()
    }

    // MARK: - Enqueue

    /// Enqueue a URL for processing
    /// - Parameters:
    ///   - url: URL to process
    ///   - priority: Processing priority (default normal)
    func enqueue(_ url: URL, priority: Priority = .normal) {
        lock.lock()
        defer { lock.unlock() }

        // Skip if already queued or processing
        let item = QueuedItem(url: url, priority: priority, queuedAt: Date())
        if pendingItems.contains(item) || processingURLs.contains(url) {
            return
        }

        // Insert in priority order (higher priority first, then by queue time)
        let insertIndex = pendingItems.firstIndex { existing in
            if item.priority > existing.priority {
                return true
            }
            if item.priority == existing.priority && item.queuedAt < existing.queuedAt {
                return true
            }
            return false
        } ?? pendingItems.endIndex

        pendingItems.insert(item, at: insertIndex)

        // Trigger processing
        DispatchQueue.main.async { [weak self] in
            self?.processNextIfAvailable()
        }
    }

    /// Enqueue multiple URLs for processing
    /// - Parameters:
    ///   - urls: URLs to process
    ///   - priority: Processing priority (default normal)
    func enqueue(_ urls: [URL], priority: Priority = .normal) {
        for url in urls {
            enqueue(url, priority: priority)
        }
    }

    /// Remove a URL from the pending queue
    /// - Parameter url: URL to remove
    /// - Returns: true if the URL was removed
    @discardableResult
    func cancel(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let item = QueuedItem(url: url, priority: .normal, queuedAt: Date())
        if let index = pendingItems.firstIndex(of: item) {
            pendingItems.remove(at: index)
            return true
        }
        return false
    }

    /// Clear all pending items
    func clearPending() {
        lock.lock()
        pendingItems.removeAll()
        lock.unlock()
    }

    // MARK: - Private Methods

    private func processNextIfAvailable() {
        guard isRunning && !isPaused else { return }
        guard let handler = processHandler else { return }

        lock.lock()

        // Check if we can process more
        guard processingURLs.count < maxConcurrent else {
            lock.unlock()
            return
        }

        // Get next item
        guard !pendingItems.isEmpty else {
            lock.unlock()
            return
        }

        let item = pendingItems.removeFirst()
        processingURLs.insert(item.url)

        lock.unlock()

        // Process on operation queue
        let urlToProcess = item.url
        ocrOperationQueue.addOperation { [weak self] in
            Task { [weak self] in
                await handler(urlToProcess)

                guard let self else { return }
                self.coordinationQueue.sync {
                    _ = self.processingURLs.remove(urlToProcess)
                }

                // Process next item
                self.processNextIfAvailable()
            }
        }
    }
}

// MARK: - ProcessingQueue Statistics

extension ProcessingQueue {
    /// Get current queue statistics
    var statistics: (active: Int, pending: Int, total: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (processingURLs.count, pendingItems.count, processingURLs.count + pendingItems.count)
    }
}
