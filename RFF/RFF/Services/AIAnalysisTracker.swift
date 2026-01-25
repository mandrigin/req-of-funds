import Foundation
import SwiftUI

/// Tracks AI analysis state globally so progress can be shown in all views
@MainActor
@Observable
final class AIAnalysisTracker {
    /// Shared instance
    static let shared = AIAnalysisTracker()

    /// Set of document IDs currently being analyzed
    private(set) var analyzingDocumentIDs: Set<UUID> = []

    /// Results for completed analyses (keyed by document ID)
    private(set) var completedResults: [UUID: AIAnalysisResult] = [:]

    /// Errors for failed analyses (keyed by document ID)
    private(set) var failedAnalyses: [UUID: Error] = [:]

    private init() {}

    /// Check if a specific document is being analyzed
    func isAnalyzing(_ documentID: UUID) -> Bool {
        analyzingDocumentIDs.contains(documentID)
    }

    /// Check if any analysis is in progress
    var isAnyAnalysisInProgress: Bool {
        !analyzingDocumentIDs.isEmpty
    }

    /// Number of documents currently being analyzed
    var analyzingCount: Int {
        analyzingDocumentIDs.count
    }

    /// Mark a document as starting analysis
    func startAnalysis(for documentID: UUID) {
        analyzingDocumentIDs.insert(documentID)
        // Clear any previous error for this document
        failedAnalyses.removeValue(forKey: documentID)
    }

    /// Mark a document as finished analysis with result
    func completeAnalysis(for documentID: UUID, result: AIAnalysisResult) {
        analyzingDocumentIDs.remove(documentID)
        completedResults[documentID] = result
    }

    /// Mark a document as failed analysis with error
    func failAnalysis(for documentID: UUID, error: Error) {
        analyzingDocumentIDs.remove(documentID)
        failedAnalyses[documentID] = error
    }

    /// Clear result for a document (e.g., after user has seen/applied it)
    func clearResult(for documentID: UUID) {
        completedResults.removeValue(forKey: documentID)
    }

    /// Clear error for a document
    func clearError(for documentID: UUID) {
        failedAnalyses.removeValue(forKey: documentID)
    }

    /// Analyze multiple documents in batch
    func analyzeBatch(documents: [RFFDocument]) async {
        for document in documents {
            guard let text = document.extractedText, !text.isEmpty else {
                failAnalysis(for: document.id, error: AIAnalysisError.invalidResponse)
                continue
            }

            startAnalysis(for: document.id)
        }

        // Run analyses concurrently with TaskGroup
        await withTaskGroup(of: (UUID, Result<AIAnalysisResult, Error>).self) { group in
            for document in documents {
                guard let text = document.extractedText, !text.isEmpty else { continue }

                group.addTask {
                    do {
                        let result = try await AIAnalysisService.shared.analyzeDocument(text: text)
                        return (document.id, .success(result))
                    } catch {
                        return (document.id, .failure(error))
                    }
                }
            }

            for await (documentID, result) in group {
                switch result {
                case .success(let analysisResult):
                    completeAnalysis(for: documentID, result: analysisResult)
                case .failure(let error):
                    failAnalysis(for: documentID, error: error)
                }
            }
        }
    }

    /// Analyze a single document
    func analyzeDocument(_ document: RFFDocument) async {
        guard let text = document.extractedText, !text.isEmpty else {
            failAnalysis(for: document.id, error: AIAnalysisError.invalidResponse)
            return
        }

        startAnalysis(for: document.id)

        do {
            let result = try await AIAnalysisService.shared.analyzeDocument(text: text)
            completeAnalysis(for: document.id, result: result)
        } catch {
            failAnalysis(for: document.id, error: error)
        }
    }
}
