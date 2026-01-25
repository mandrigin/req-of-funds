import Foundation

/// A user correction to an extracted field
struct FieldCorrection: Codable, Identifiable, Sendable {
    /// Unique identifier
    let id: UUID

    /// The schema that was used (if any)
    let schemaId: UUID?

    /// The field type that was corrected
    let fieldType: InvoiceFieldType

    /// The original extracted value
    let originalValue: String

    /// The corrected value entered by the user
    let correctedValue: String

    /// Bounding box where the original value was found
    let boundingBox: NormalizedRegion?

    /// Confidence of the original extraction
    let originalConfidence: Double

    /// Whether this was a complete replacement (vs. minor edit)
    let wasCompleteReplacement: Bool

    /// Timestamp of the correction
    let timestamp: Date

    /// Document identifier for grouping
    let documentId: UUID?

    init(
        id: UUID = UUID(),
        schemaId: UUID? = nil,
        fieldType: InvoiceFieldType,
        originalValue: String,
        correctedValue: String,
        boundingBox: NormalizedRegion? = nil,
        originalConfidence: Double = 0.5,
        wasCompleteReplacement: Bool = false,
        timestamp: Date = Date(),
        documentId: UUID? = nil
    ) {
        self.id = id
        self.schemaId = schemaId
        self.fieldType = fieldType
        self.originalValue = originalValue
        self.correctedValue = correctedValue
        self.boundingBox = boundingBox
        self.originalConfidence = originalConfidence
        self.wasCompleteReplacement = wasCompleteReplacement
        self.timestamp = timestamp
        self.documentId = documentId
    }

    /// Levenshtein distance between original and corrected
    var editDistance: Int {
        levenshteinDistance(originalValue, correctedValue)
    }

    /// Whether this was a minor correction (typo fix, etc.)
    var isMinorCorrection: Bool {
        let distance = editDistance
        let maxLength = max(originalValue.count, correctedValue.count)
        guard maxLength > 0 else { return true }
        return Double(distance) / Double(maxLength) < 0.3
    }
}

/// Summary statistics for a field type
struct FieldCorrectionStats: Sendable {
    let fieldType: InvoiceFieldType
    let totalExtractions: Int
    let correctionsCount: Int
    let minorCorrectionsCount: Int
    let averageOriginalConfidence: Double

    /// Accuracy rate (1 - corrections/total)
    var accuracyRate: Double {
        guard totalExtractions > 0 else { return 0 }
        return 1.0 - (Double(correctionsCount) / Double(totalExtractions))
    }

    /// Suggested confidence adjustment based on history
    var suggestedConfidenceAdjustment: Double {
        // If lots of corrections, reduce confidence
        // If few corrections, boost confidence
        let baseAdjustment = accuracyRate - 0.5 // -0.5 to +0.5 range
        return baseAdjustment * 0.2 // Scale to -0.1 to +0.1
    }
}

/// Service for tracking and learning from user corrections
/// All data stays on device - no cloud sync
actor CorrectionHistoryService {
    /// Singleton instance
    static let shared = CorrectionHistoryService()

    /// Directory for storing correction history
    private let historyDirectory: URL

    /// File for corrections
    private let correctionsFile: URL

    /// In-memory cache of corrections
    private var corrections: [FieldCorrection] = []

    /// Track extraction counts per field type
    private var extractionCounts: [InvoiceFieldType: Int] = [:]

    /// Maximum corrections to keep (rolling window)
    private let maxCorrections = 10000

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDirectory = appSupport.appendingPathComponent("RFF", isDirectory: true)
        self.historyDirectory = appDirectory.appendingPathComponent("CorrectionHistory", isDirectory: true)
        self.correctionsFile = historyDirectory.appendingPathComponent("corrections.json")

        // Create directory if needed
        try? FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Loading/Saving

    /// Load correction history from disk
    func loadHistory() async throws {
        guard FileManager.default.fileExists(atPath: correctionsFile.path) else {
            return
        }

        let data = try Data(contentsOf: correctionsFile)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        corrections = try decoder.decode([FieldCorrection].self, from: data)

        // Rebuild extraction counts from corrections
        for correction in corrections {
            extractionCounts[correction.fieldType, default: 0] += 1
        }
    }

    /// Save corrections to disk
    private func saveHistory() async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        let data = try encoder.encode(corrections)
        try data.write(to: correctionsFile, options: .atomic)
    }

    // MARK: - Recording

    /// Record that an extraction was performed (for tracking accuracy)
    func recordExtraction(fieldType: InvoiceFieldType) {
        extractionCounts[fieldType, default: 0] += 1
    }

    /// Record a user correction
    func recordCorrection(_ correction: FieldCorrection) async throws {
        corrections.append(correction)

        // Trim old corrections if needed
        if corrections.count > maxCorrections {
            corrections = Array(corrections.suffix(maxCorrections))
        }

        try await saveHistory()

        // Update schema confidence if applicable
        if let schemaId = correction.schemaId {
            try? await SchemaStore.shared.updateFieldConfidence(
                schemaId: schemaId,
                fieldType: correction.fieldType,
                confirmed: false
            )
        }
    }

    /// Record that a user confirmed an extraction was correct
    func recordConfirmation(
        schemaId: UUID?,
        fieldType: InvoiceFieldType
    ) async {
        // Update schema confidence
        if let schemaId = schemaId {
            try? await SchemaStore.shared.updateFieldConfidence(
                schemaId: schemaId,
                fieldType: fieldType,
                confirmed: true
            )
        }
    }

    // MARK: - Statistics

    /// Get correction statistics for a field type
    func statistics(for fieldType: InvoiceFieldType) -> FieldCorrectionStats {
        let fieldCorrections = corrections.filter { $0.fieldType == fieldType }
        let minorCorrections = fieldCorrections.filter { $0.isMinorCorrection }

        let avgConfidence = fieldCorrections.isEmpty ? 0.5 :
            fieldCorrections.map { $0.originalConfidence }.reduce(0, +) / Double(fieldCorrections.count)

        return FieldCorrectionStats(
            fieldType: fieldType,
            totalExtractions: extractionCounts[fieldType] ?? fieldCorrections.count,
            correctionsCount: fieldCorrections.count,
            minorCorrectionsCount: minorCorrections.count,
            averageOriginalConfidence: avgConfidence
        )
    }

    /// Get statistics for all field types
    func allStatistics() -> [FieldCorrectionStats] {
        InvoiceFieldType.allCases.map { statistics(for: $0) }
    }

    /// Get recent corrections for a specific schema
    func recentCorrections(forSchema schemaId: UUID, limit: Int = 50) -> [FieldCorrection] {
        corrections
            .filter { $0.schemaId == schemaId }
            .suffix(limit)
            .reversed()
            .map { $0 }
    }

    /// Get common correction patterns (original -> corrected mappings)
    func commonPatterns(for fieldType: InvoiceFieldType, limit: Int = 10) -> [(original: String, corrected: String, count: Int)] {
        let fieldCorrections = corrections.filter { $0.fieldType == fieldType }

        // Group by original -> corrected
        var patterns: [String: [String: Int]] = [:]
        for correction in fieldCorrections {
            let key = correction.originalValue.lowercased()
            patterns[key, default: [:]][correction.correctedValue, default: 0] += 1
        }

        // Flatten and sort
        var flatPatterns: [(original: String, corrected: String, count: Int)] = []
        for (original, correctedCounts) in patterns {
            for (corrected, count) in correctedCounts {
                flatPatterns.append((original, corrected, count))
            }
        }

        return flatPatterns
            .sorted { $0.count > $1.count }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Learning Integration

    /// Get suggested confidence adjustment for a field type based on history
    func suggestedConfidenceAdjustment(for fieldType: InvoiceFieldType) -> Double {
        statistics(for: fieldType).suggestedConfidenceAdjustment
    }

    /// Export training data for Create ML retraining
    func exportTrainingData() async throws -> URL {
        let trainingFile = historyDirectory.appendingPathComponent("training_data.json")

        // Group corrections by field type for training
        var trainingData: [[String: Any]] = []

        for correction in corrections {
            trainingData.append([
                "text": correction.correctedValue,
                "label": correction.fieldType.rawValue
            ])
        }

        let data = try JSONSerialization.data(withJSONObject: trainingData, options: .prettyPrinted)
        try data.write(to: trainingFile)

        return trainingFile
    }

    /// Clear all correction history
    func clearHistory() async throws {
        corrections.removeAll()
        extractionCounts.removeAll()
        try? FileManager.default.removeItem(at: correctionsFile)
    }
}

// MARK: - Levenshtein Distance

private func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
    let s1 = Array(s1)
    let s2 = Array(s2)
    let m = s1.count
    let n = s2.count

    if m == 0 { return n }
    if n == 0 { return m }

    var matrix = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)

    for i in 0...m { matrix[i][0] = i }
    for j in 0...n { matrix[0][j] = j }

    for i in 1...m {
        for j in 1...n {
            if s1[i - 1] == s2[j - 1] {
                matrix[i][j] = matrix[i - 1][j - 1]
            } else {
                matrix[i][j] = min(
                    matrix[i - 1][j] + 1,      // deletion
                    matrix[i][j - 1] + 1,      // insertion
                    matrix[i - 1][j - 1] + 1   // substitution
                )
            }
        }
    }

    return matrix[m][n]
}
