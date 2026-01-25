import Foundation
import SwiftUI

/// Tracks AI analysis progress across the app for global visibility
@MainActor
@Observable
final class AIAnalysisProgressManager {
    /// Shared singleton instance
    static let shared = AIAnalysisProgressManager()

    /// Documents currently being analyzed (by document ID)
    private(set) var analyzingDocuments: Set<UUID>

    /// Results for completed analyses (keyed by document ID)
    private(set) var completedResults: [UUID: AIAnalysisResult]

    /// Errors for failed analyses (keyed by document ID)
    private(set) var errors: [UUID: String]

    /// Total number of documents in current batch
    private(set) var batchTotal: Int

    /// Number of completed documents in current batch
    private(set) var batchCompleted: Int

    /// Whether any analysis is currently running
    var isAnalyzing: Bool {
        !analyzingDocuments.isEmpty
    }

    /// Progress as a fraction (0.0 to 1.0)
    var batchProgress: Double {
        guard batchTotal > 0 else { return 0 }
        return Double(batchCompleted) / Double(batchTotal)
    }

    /// Check if a specific document is being analyzed
    func isAnalyzing(documentId: UUID) -> Bool {
        analyzingDocuments.contains(documentId)
    }

    /// Get result for a document if available
    func result(for documentId: UUID) -> AIAnalysisResult? {
        completedResults[documentId]
    }

    /// Get error for a document if available
    func error(for documentId: UUID) -> String? {
        errors[documentId]
    }

    /// Clear result for a document (after it's been displayed/applied)
    func clearResult(for documentId: UUID) {
        completedResults.removeValue(forKey: documentId)
    }

    /// Clear error for a document
    func clearError(for documentId: UUID) {
        errors.removeValue(forKey: documentId)
    }

    /// Start analysis for a single document
    func startAnalysis(documentId: UUID, text: String) async {
        // Add to tracking
        analyzingDocuments.insert(documentId)
        errors.removeValue(forKey: documentId)
        completedResults.removeValue(forKey: documentId)

        do {
            let result = try await AIAnalysisService.shared.analyzeDocument(text: text)
            completedResults[documentId] = result
        } catch {
            errors[documentId] = error.localizedDescription
        }

        // Remove from tracking
        analyzingDocuments.remove(documentId)
    }

    /// Start batch analysis for multiple documents
    /// - Parameter documents: Array of (id, extractedText) tuples
    func startBatchAnalysis(documents: [(id: UUID, text: String)]) async {
        guard !documents.isEmpty else { return }

        // Reset batch tracking
        batchTotal = documents.count
        batchCompleted = 0

        // Clear previous results for these documents
        for (id, _) in documents {
            errors.removeValue(forKey: id)
            completedResults.removeValue(forKey: id)
        }

        // Process documents concurrently with a limit
        await withTaskGroup(of: Void.self) { group in
            // Limit concurrency to avoid overwhelming the API
            let maxConcurrency = 3
            var pending = documents[...]

            // Start initial batch
            for _ in 0..<min(maxConcurrency, documents.count) {
                if let doc = pending.popFirst() {
                    group.addTask { [weak self] in
                        await self?.analyzeDocument(id: doc.id, text: doc.text)
                    }
                }
            }

            // As each completes, start another
            for await _ in group {
                batchCompleted += 1

                if let doc = pending.popFirst() {
                    group.addTask { [weak self] in
                        await self?.analyzeDocument(id: doc.id, text: doc.text)
                    }
                }
            }
        }

        // Reset batch tracking when done
        batchTotal = 0
        batchCompleted = 0
    }

    /// Analyze a single document (internal helper)
    private func analyzeDocument(id: UUID, text: String) async {
        analyzingDocuments.insert(id)

        do {
            let result = try await AIAnalysisService.shared.analyzeDocument(text: text)
            completedResults[id] = result
        } catch {
            errors[id] = error.localizedDescription
        }

        analyzingDocuments.remove(id)
    }

    private init() {
        self.analyzingDocuments = []
        self.completedResults = [:]
        self.errors = [:]
        self.batchTotal = 0
        self.batchCompleted = 0
    }
}
