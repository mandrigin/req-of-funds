import Foundation
import Combine

// MARK: - Review Item

/// A document the AI cascade could not confidently classify - awaiting the user's call
struct ReviewQueueItem: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let filePath: String
    let fileName: String
    /// Confidence from the deciding stage
    let confidence: Float
    /// Apple Intelligence confidence when Ollama was the deciding stage
    let primaryConfidence: Float?
    let stage: ClassificationStage
    let organizations: [String]
    /// First part of the extracted text, for display
    let textSnippet: String
    /// Date the organizer would use for the destination folder
    let suggestedDate: Date
    let queuedAt: Date

    var fileURL: URL { URL(fileURLWithPath: filePath) }
}

/// User decisions on files, kept so the watcher never re-processes or re-queues them
enum ReviewDecision: String, Codable {
    case pending      // waiting in the queue
    case notInvoice   // user said: not an invoice, leave it alone
}

// MARK: - Store

/// JSON-backed manual confirmation queue at ~/Library/Application Support/RFF/review-queue.json
@MainActor
final class ReviewQueueStore: ObservableObject {
    static let shared = ReviewQueueStore()

    @Published private(set) var items: [ReviewQueueItem] = []
    /// File path -> decision; consulted by the processor to skip decided files
    @Published private(set) var decisions: [String: ReviewDecision] = [:]

    private var storeURL: URL {
        ConfigManager.shared.appSupportDirectory.appendingPathComponent("review-queue.json")
    }

    private struct Snapshot: Codable {
        var items: [ReviewQueueItem]
        var decisions: [String: ReviewDecision]
    }

    private init() {
        load()
    }

    // MARK: - Queries (callable from any thread via await)

    /// Whether the processor should skip this file (already queued or user said "not invoice")
    func shouldSkip(_ url: URL) -> Bool {
        decisions[url.path] != nil
    }

    var pendingCount: Int { items.count }

    // MARK: - Mutations

    func enqueue(_ item: ReviewQueueItem) {
        guard decisions[item.filePath] == nil else { return }
        items.append(item)
        decisions[item.filePath] = .pending
        save()
    }

    /// User confirmed it's an invoice; remove from queue. Caller files the document.
    func approve(_ item: ReviewQueueItem) {
        items.removeAll { $0.id == item.id }
        // The file is about to move out of the watched folder - forget the path
        decisions.removeValue(forKey: item.filePath)
        save()
    }

    /// User said it's not an invoice; remember so it's never asked about again.
    func reject(_ item: ReviewQueueItem) {
        items.removeAll { $0.id == item.id }
        decisions[item.filePath] = .notInvoice
        save()
    }

    /// Drop queue entries whose file disappeared from disk
    func prune() {
        let fileManager = FileManager.default
        let gone = items.filter { !fileManager.fileExists(atPath: $0.filePath) }
        guard !gone.isEmpty else { return }
        for item in gone {
            items.removeAll { $0.id == item.id }
            decisions.removeValue(forKey: item.filePath)
        }
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return
        }
        items = snapshot.items
        decisions = snapshot.decisions
    }

    private func save() {
        let snapshot = Snapshot(items: items, decisions: decisions)
        guard let data = try? {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(snapshot)
        }() else { return }
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: storeURL, options: .atomic)
    }
}
