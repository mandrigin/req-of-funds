import Foundation
import Combine

/// Events emitted by the FileWatcher
enum FileWatcherEvent: Equatable {
    /// A file was created in a monitored directory
    case created(URL)

    /// A file was renamed into a monitored directory
    case renamedInto(URL)

    /// A file was modified in a monitored directory
    case modified(URL)

    /// The file URL associated with this event
    var url: URL {
        switch self {
        case .created(let url), .renamedInto(let url), .modified(let url):
            return url
        }
    }
}

/// Protocol for file watching to enable testing
protocol FileWatcherProtocol {
    var events: AnyPublisher<FileWatcherEvent, Never> { get }
    func start() throws
    func stop()
    var isRunning: Bool { get }
}

/// Watches directories for file changes using FSEvents API
final class FileWatcher: FileWatcherProtocol {
    // MARK: - Types

    /// Error types for FileWatcher
    enum WatcherError: LocalizedError {
        case failedToCreateStream(String)
        case invalidPath(URL)
        case alreadyRunning
        case notRunning

        var errorDescription: String? {
            switch self {
            case .failedToCreateStream(let path):
                return "Failed to create FSEvents stream for path: \(path)"
            case .invalidPath(let url):
                return "Invalid path: \(url.path)"
            case .alreadyRunning:
                return "FileWatcher is already running"
            case .notRunning:
                return "FileWatcher is not running"
            }
        }
    }

    // MARK: - Private Types

    /// Information about a single watched path
    private struct WatchedPath {
        let url: URL
        let recursive: Bool
    }

    // MARK: - Properties

    /// Publisher for file events
    private let eventSubject = PassthroughSubject<FileWatcherEvent, Never>()

    /// Public publisher for events
    var events: AnyPublisher<FileWatcherEvent, Never> {
        eventSubject.eraseToAnyPublisher()
    }

    /// Paths being watched
    private var watchedPaths: [WatchedPath] = []

    /// The FSEvents stream
    private var eventStream: FSEventStreamRef?

    /// Queue for FSEvents callbacks
    private let eventQueue = DispatchQueue(label: "com.invoicefiler.filewatcher", qos: .utility)

    /// Supported file extensions (lowercase)
    private var supportedExtensions: Set<String> = []

    /// Exclusion patterns
    private var exclusionPatterns: [String] = []

    /// Whether the watcher is currently running
    private(set) var isRunning: Bool = false

    /// Latency in seconds before FSEvents delivers events (allows coalescing)
    private let latency: CFTimeInterval = 0.5

    /// Set of paths currently being tracked (for filtering non-recursive)
    private var trackedDirectories: Set<String> = []

    /// Non-recursive watched directories (for filtering)
    private var nonRecursiveDirectories: Set<String> = []

    // MARK: - Initialization

    init() {}

    deinit {
        stop()
    }

    // MARK: - Configuration

    /// Configure the watcher with monitored paths
    func configure(paths: [MonitoredPath], supportedExtensions: Set<String>, exclusionPatterns: [String]) {
        self.watchedPaths = paths.map { WatchedPath(url: $0.path, recursive: $0.recursive) }
        self.supportedExtensions = Set(supportedExtensions.map { $0.lowercased() })
        self.exclusionPatterns = exclusionPatterns

        // Track non-recursive directories for filtering
        self.nonRecursiveDirectories = Set(paths.filter { !$0.recursive }.map { $0.path.path })
        self.trackedDirectories = Set(paths.map { $0.path.path })
    }

    // MARK: - Control

    /// Start watching configured directories
    func start() throws {
        guard !isRunning else {
            throw WatcherError.alreadyRunning
        }

        guard !watchedPaths.isEmpty else {
            return // Nothing to watch
        }

        // Validate paths exist
        let fileManager = FileManager.default
        for watchedPath in watchedPaths {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: watchedPath.url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw WatcherError.invalidPath(watchedPath.url)
            }
        }

        // Create FSEvents stream
        let pathsToWatch = watchedPaths.map { $0.url.path as CFString } as CFArray

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        // Flags: file-level events, watch root
        let flags: FSEventStreamCreateFlags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagWatchRoot
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fsEventsCallback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            let pathList = watchedPaths.map { $0.url.path }.joined(separator: ", ")
            throw WatcherError.failedToCreateStream(pathList)
        }

        eventStream = stream

        FSEventStreamSetDispatchQueue(stream, eventQueue)
        FSEventStreamStart(stream)

        isRunning = true
    }

    /// Stop watching directories
    func stop() {
        guard let stream = eventStream else { return }

        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)

        eventStream = nil
        isRunning = false
    }

    // MARK: - Event Processing

    /// Process a file system event
    fileprivate func processEvent(path: String, flags: FSEventStreamEventFlags) {
        let url = URL(fileURLWithPath: path)

        // Skip directories
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                return
            }
        }

        // Check if this event should be filtered
        guard shouldProcessFile(at: url) else { return }

        // Determine event type based on flags
        let event = classifyEvent(url: url, flags: flags)

        if let event = event {
            eventSubject.send(event)
        }
    }

    /// Classify FSEvents flags into our event types
    private func classifyEvent(url: URL, flags: FSEventStreamEventFlags) -> FileWatcherEvent? {
        // File was created
        if flags & UInt32(kFSEventStreamEventFlagItemCreated) != 0 {
            return .created(url)
        }

        // File was renamed (into this location)
        if flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 {
            // Renamed events fire twice - once for source, once for destination
            // We only care about the destination if it exists
            if FileManager.default.fileExists(atPath: url.path) {
                return .renamedInto(url)
            }
            return nil
        }

        // File was modified
        if flags & UInt32(kFSEventStreamEventFlagItemModified) != 0 {
            // Don't emit modified if file was just created
            if flags & UInt32(kFSEventStreamEventFlagItemCreated) != 0 {
                return nil
            }
            return .modified(url)
        }

        // File content changed (size, data, etc.)
        if flags & UInt32(kFSEventStreamEventFlagItemInodeMetaMod) != 0 {
            return .modified(url)
        }

        return nil
    }

    /// Check if a file should be processed based on filters
    private func shouldProcessFile(at url: URL) -> Bool {
        let filename = url.lastPathComponent
        let ext = url.pathExtension.lowercased()

        // Check extension filter
        if !supportedExtensions.isEmpty && !supportedExtensions.contains(ext) {
            return false
        }

        // Check exclusion patterns
        if matchesAnyExclusionPattern(filename) {
            return false
        }

        // Check recursive filter
        let parentPath = url.deletingLastPathComponent().path
        if !shouldIncludeFromPath(parentPath) {
            return false
        }

        return true
    }

    /// Check if a file matches any exclusion pattern
    private func matchesAnyExclusionPattern(_ filename: String) -> Bool {
        for pattern in exclusionPatterns {
            if matchesGlob(filename: filename, pattern: pattern) {
                return true
            }
        }
        return false
    }

    /// Simple glob pattern matching
    private func matchesGlob(filename: String, pattern: String) -> Bool {
        if pattern == "*" {
            return true
        }

        // Handle prefix patterns like ".*" (hidden files)
        if pattern.hasPrefix(".") && pattern.dropFirst() == "*" {
            return filename.hasPrefix(".")
        }

        // Handle suffix patterns like "*.tmp"
        if pattern.hasPrefix("*") {
            let suffix = String(pattern.dropFirst())
            return filename.hasSuffix(suffix)
        }

        // Handle prefix patterns like "temp*"
        if pattern.hasSuffix("*") {
            let prefix = String(pattern.dropLast())
            return filename.hasPrefix(prefix)
        }

        // Exact match
        return filename == pattern
    }

    /// Check if a path should be included based on recursive settings
    private func shouldIncludeFromPath(_ parentPath: String) -> Bool {
        // Check if this is a direct child of a watched directory
        if trackedDirectories.contains(parentPath) {
            return true
        }

        // Check if any watched directory is an ancestor
        for watchedPath in watchedPaths {
            let watchedPathStr = watchedPath.url.path

            if parentPath.hasPrefix(watchedPathStr) {
                // This file is under this watched path
                if watchedPath.recursive {
                    return true
                } else {
                    // Non-recursive: only include direct children
                    return parentPath == watchedPathStr
                }
            }
        }

        return false
    }
}

// MARK: - FSEvents Callback

/// C-compatible callback for FSEvents
private func fsEventsCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let clientInfo = clientCallBackInfo else { return }

    let watcher = Unmanaged<FileWatcher>.fromOpaque(clientInfo).takeUnretainedValue()
    let paths = unsafeBitCast(eventPaths, to: NSArray.self)

    for i in 0..<numEvents {
        guard let path = paths[i] as? String else { continue }
        let flags = eventFlags[i]

        // Only process file events (not directory events)
        if flags & UInt32(kFSEventStreamEventFlagItemIsFile) != 0 {
            watcher.processEvent(path: path, flags: flags)
        }
    }
}
