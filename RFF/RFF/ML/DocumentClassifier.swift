import Foundation
import NaturalLanguage

/// Result of a document classification
struct ClassificationResult: Sendable {
    /// The predicted category
    let category: DocumentCategory
    /// Confidence score (0.0 to 1.0)
    let confidence: Double
    /// All category probabilities
    let probabilities: [DocumentCategory: Double]
}

/// Error types for document classification
enum ClassificationError: Error, LocalizedError {
    case modelNotFound
    case modelLoadFailed(Error)
    case predictionFailed
    case emptyText
    case invalidModel

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "Document classifier model not found in bundle"
        case .modelLoadFailed(let error):
            return "Failed to load classifier model: \(error.localizedDescription)"
        case .predictionFailed:
            return "Classification prediction failed"
        case .emptyText:
            return "Cannot classify empty text"
        case .invalidModel:
            return "Model is not a valid text classifier"
        }
    }
}

/// Service for classifying documents using a trained Core ML model
/// Thread-safe and designed for concurrent batch processing
actor DocumentClassifier {
    /// The name of the Core ML model file (without extension)
    private static let modelName = "DocumentClassifier"

    /// The NLModel wrapper for the trained classifier
    private var model: NLModel?

    /// Whether the model has been successfully loaded
    private(set) var isLoaded: Bool = false

    /// Shared instance for convenience
    static let shared = DocumentClassifier()

    init() {}

    // MARK: - Model Loading

    /// Load the classifier model from the app bundle
    /// Call this at app startup or before first classification
    func loadModel() async throws {
        guard !isLoaded else { return }

        guard let modelURL = Bundle.main.url(
            forResource: Self.modelName,
            withExtension: "mlmodelc"
        ) else {
            throw ClassificationError.modelNotFound
        }

        do {
            model = try NLModel(contentsOf: modelURL)
            isLoaded = true
        } catch {
            throw ClassificationError.modelLoadFailed(error)
        }
    }

    /// Load a model from a specific URL (useful for testing or dynamic models)
    func loadModel(from url: URL) async throws {
        do {
            model = try NLModel(contentsOf: url)
            isLoaded = true
        } catch {
            throw ClassificationError.modelLoadFailed(error)
        }
    }

    // MARK: - Single Document Classification

    /// Classify a single document's text
    /// - Parameter text: The document text to classify
    /// - Returns: Classification result with category and confidence
    func classify(_ text: String) async throws -> ClassificationResult {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClassificationError.emptyText
        }

        guard let model = model else {
            throw ClassificationError.modelNotFound
        }

        // Get the top prediction
        guard let prediction = model.predictedLabel(for: text) else {
            throw ClassificationError.predictionFailed
        }

        // Get hypothesis probabilities for all categories
        let hypotheses = model.predictedLabelHypotheses(for: text, maximumCount: DocumentCategory.allCases.count)

        var probabilities: [DocumentCategory: Double] = [:]
        for category in DocumentCategory.allCases {
            probabilities[category] = hypotheses[category.rawValue] ?? 0.0
        }

        guard let category = DocumentCategory(rawValue: prediction) else {
            throw ClassificationError.predictionFailed
        }

        let confidence = probabilities[category] ?? 0.0

        return ClassificationResult(
            category: category,
            confidence: confidence,
            probabilities: probabilities
        )
    }

    // MARK: - Batch Classification

    /// Classify multiple documents concurrently
    /// Uses structured concurrency for thread-safe parallel processing
    /// - Parameter texts: Array of document texts to classify
    /// - Returns: Array of results in the same order as input
    func classifyBatch(_ texts: [String]) async throws -> [Result<ClassificationResult, Error>] {
        guard isLoaded else {
            throw ClassificationError.modelNotFound
        }

        return await withTaskGroup(of: (Int, Result<ClassificationResult, Error>).self) { group in
            for (index, text) in texts.enumerated() {
                group.addTask {
                    do {
                        let result = try await self.classify(text)
                        return (index, .success(result))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }

            var results = Array(repeating: Result<ClassificationResult, Error>.failure(ClassificationError.predictionFailed), count: texts.count)
            for await (index, result) in group {
                results[index] = result
            }
            return results
        }
    }

    /// Classify multiple documents, returning only successful results
    /// - Parameter texts: Array of document texts to classify
    /// - Returns: Array of successful classification results (may be shorter than input)
    func classifyBatchSuccessful(_ texts: [String]) async throws -> [ClassificationResult] {
        let results = try await classifyBatch(texts)
        return results.compactMap { try? $0.get() }
    }

    // MARK: - Utilities

    /// Get the most likely category without full result details
    /// Useful for quick filtering operations
    func quickClassify(_ text: String) async -> DocumentCategory? {
        guard let model = model,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let prediction = model.predictedLabel(for: text) else {
            return nil
        }
        return DocumentCategory(rawValue: prediction)
    }

    /// Check if text is likely a specific category with minimum confidence
    func isCategory(_ category: DocumentCategory, text: String, minConfidence: Double = 0.7) async -> Bool {
        guard let result = try? await classify(text) else {
            return false
        }
        return result.category == category && result.confidence >= minConfidence
    }

    /// Unload the model to free memory
    func unloadModel() {
        model = nil
        isLoaded = false
    }
}
