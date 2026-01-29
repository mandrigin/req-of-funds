import Foundation
import NaturalLanguage

/// Result of field classification for a text observation
struct FieldClassificationResult: Sendable {
    /// The predicted field type
    let fieldType: InvoiceFieldType
    /// Confidence score (0.0 to 1.0)
    let confidence: Double
    /// All field type probabilities
    let probabilities: [InvoiceFieldType: Double]
    /// The original text that was classified
    let text: String
    /// The bounding box of the text
    let boundingBox: NormalizedRegion
}

/// Error types for field classification
enum FieldClassificationError: Error, LocalizedError {
    case modelNotFound
    case modelLoadFailed(Error)
    case predictionFailed
    case emptyText

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "Field classifier model not found"
        case .modelLoadFailed(let error):
            return "Failed to load field classifier: \(error.localizedDescription)"
        case .predictionFailed:
            return "Field classification prediction failed"
        case .emptyText:
            return "Cannot classify empty text"
        }
    }
}

/// Service for classifying OCR text regions into invoice field types
/// Uses rule-based heuristics combined with pattern matching
actor FieldClassifier {
    /// Shared instance
    static let shared = FieldClassifier()

    /// Pattern matchers for each field type
    private let fieldPatterns: [InvoiceFieldType: [NSRegularExpression]]

    /// Label keywords that suggest a field type
    private let fieldLabelKeywords: [InvoiceFieldType: [String]]

    init() {
        // Initialize regex patterns for field detection
        var patterns: [InvoiceFieldType: [NSRegularExpression]] = [:]
        var keywords: [InvoiceFieldType: [String]] = [:]

        // Invoice Number patterns
        patterns[.invoiceNumber] = Self.compilePatterns([
            #"^[A-Z]{2,4}[\-]?\d{4,}"#,                    // INV-12345
            #"^\d{3,}-\d{3,}-\d{3,}$"#,                    // 123-456-789
            #"^[A-Z0-9]{6,}$"#                              // ABC123456
        ])
        keywords[.invoiceNumber] = ["invoice", "inv", "number", "no.", "#"]

        // Date patterns - use centralized patterns from DateParsingUtility
        let datePatterns = DateParsingUtility.datePatterns
        patterns[.invoiceDate] = Self.compilePatterns(datePatterns)
        keywords[.invoiceDate] = ["date", "invoice date", "issued"]

        patterns[.dueDate] = Self.compilePatterns(datePatterns)
        keywords[.dueDate] = ["due", "due date", "payment due", "due by", "pay by"]

        // Currency/Amount patterns
        let amountPatterns = [
            #"^\$[\d,]+\.?\d*$"#,                          // $1,234.56
            #"^€[\d,.\s]+$"#,                              // €1.234,56
            #"^£[\d,]+\.?\d*$"#,                           // £1,234.56
            #"^[\d,]+\.\d{2}$"#                            // 1,234.56
        ]
        patterns[.total] = Self.compilePatterns(amountPatterns)
        keywords[.total] = ["total", "amount due", "grand total", "balance due", "total due"]

        patterns[.subtotal] = Self.compilePatterns(amountPatterns)
        keywords[.subtotal] = ["subtotal", "sub-total", "sub total"]

        patterns[.tax] = Self.compilePatterns(amountPatterns)
        keywords[.tax] = ["tax", "vat", "gst", "hst", "sales tax"]

        // Vendor/Organization - typically at top of invoice
        keywords[.vendor] = ["from", "seller", "vendor", "company", "billed from"]

        // Customer
        keywords[.customerName] = ["bill to", "invoice to", "customer", "sold to", "ship to"]

        // PO Number
        patterns[.poNumber] = Self.compilePatterns([
            #"^PO[\-\s]?\d{4,}$"#,                         // PO-12345
            #"^\d{4,}$"#                                    // 12345 (when near PO label)
        ])
        keywords[.poNumber] = ["po", "p.o.", "purchase order"]

        // Payment terms
        keywords[.paymentTerms] = ["terms", "payment terms", "net", "due upon receipt"]

        // Line item fields
        keywords[.lineItemDescription] = ["description", "item", "service", "product"]
        keywords[.lineItemQuantity] = ["qty", "quantity", "units"]
        keywords[.lineItemUnitPrice] = ["unit price", "rate", "price", "unit cost"]
        keywords[.lineItemTotal] = ["amount", "line total", "ext", "extended"]

        self.fieldPatterns = patterns
        self.fieldLabelKeywords = keywords
    }

    /// Compile regex patterns, filtering out invalid ones
    private static func compilePatterns(_ patterns: [String]) -> [NSRegularExpression] {
        patterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }

    // MARK: - Classification

    /// Classify a single text observation
    func classify(
        text: String,
        boundingBox: CGRect,
        nearbyText: [String] = []
    ) async -> FieldClassificationResult? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalizedBox = NormalizedRegion(cgRect: boundingBox)
        var scores: [InvoiceFieldType: Double] = [:]

        // Initialize all scores to 0
        for fieldType in InvoiceFieldType.allCases {
            scores[fieldType] = 0.0
        }

        // Score based on pattern matching
        for (fieldType, patterns) in fieldPatterns {
            for pattern in patterns {
                let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
                if pattern.firstMatch(in: trimmed, options: [], range: range) != nil {
                    scores[fieldType, default: 0] += 0.4
                    break
                }
            }
        }

        // Score based on label proximity (nearby text contains label keywords)
        let nearbyLower = nearbyText.map { $0.lowercased() }.joined(separator: " ")
        for (fieldType, keywords) in fieldLabelKeywords {
            for keyword in keywords {
                if nearbyLower.contains(keyword) {
                    scores[fieldType, default: 0] += 0.3
                    break
                }
            }
        }

        // Score based on position heuristics
        applyPositionScores(to: &scores, boundingBox: normalizedBox)

        // Score based on text characteristics
        applyTextCharacteristicScores(to: &scores, text: trimmed)

        // Find best match
        guard let (bestType, bestScore) = scores.max(by: { $0.value < $1.value }),
              bestScore > 0.1 else {
            return nil
        }

        // Normalize probabilities
        let totalScore = scores.values.reduce(0, +)
        var probabilities: [InvoiceFieldType: Double] = [:]
        for (type, score) in scores {
            probabilities[type] = totalScore > 0 ? score / totalScore : 0
        }

        return FieldClassificationResult(
            fieldType: bestType,
            confidence: min(1.0, bestScore),
            probabilities: probabilities,
            text: trimmed,
            boundingBox: normalizedBox
        )
    }

    /// Classify multiple text observations from OCR result
    func classifyObservations(
        _ observations: [TextObservation]
    ) async -> [FieldClassificationResult] {
        var results: [FieldClassificationResult] = []

        for (index, observation) in observations.enumerated() {
            // Gather nearby text for context
            let nearbyText = gatherNearbyText(
                for: index,
                in: observations,
                maxDistance: 0.1
            )

            if let result = await classify(
                text: observation.text,
                boundingBox: observation.boundingBox,
                nearbyText: nearbyText
            ) {
                results.append(result)
            }
        }

        return results
    }

    // MARK: - Position-based Scoring

    /// Apply scores based on typical field positions on invoice
    private func applyPositionScores(
        to scores: inout [InvoiceFieldType: Double],
        boundingBox: NormalizedRegion
    ) {
        let y = boundingBox.y  // Vision coordinates: 0 = bottom, 1 = top

        // Vendor typically at top
        if y > 0.75 {
            scores[.vendor, default: 0] += 0.2
        }

        // Total typically at bottom
        if y < 0.3 {
            scores[.total, default: 0] += 0.15
            scores[.subtotal, default: 0] += 0.1
            scores[.tax, default: 0] += 0.1
        }

        // Line items typically in middle
        if y > 0.3 && y < 0.7 {
            scores[.lineItemDescription, default: 0] += 0.1
            scores[.lineItemQuantity, default: 0] += 0.1
            scores[.lineItemUnitPrice, default: 0] += 0.1
            scores[.lineItemTotal, default: 0] += 0.1
        }

        // Invoice number/date often at top right
        if y > 0.7 && boundingBox.x > 0.5 {
            scores[.invoiceNumber, default: 0] += 0.15
            scores[.invoiceDate, default: 0] += 0.15
        }
    }

    // MARK: - Text Characteristic Scoring

    /// Apply scores based on text content characteristics
    private func applyTextCharacteristicScores(
        to scores: inout [InvoiceFieldType: Double],
        text: String
    ) {
        // Currency symbols suggest amount fields
        if text.contains("$") || text.contains("€") || text.contains("£") {
            scores[.total, default: 0] += 0.2
            scores[.subtotal, default: 0] += 0.15
            scores[.tax, default: 0] += 0.15
            scores[.lineItemTotal, default: 0] += 0.1
            scores[.lineItemUnitPrice, default: 0] += 0.1
        }

        // Pure numeric with 2 decimals - likely amount
        if text.range(of: #"^\d[\d,]*\.\d{2}$"#, options: .regularExpression) != nil {
            scores[.total, default: 0] += 0.15
            scores[.lineItemTotal, default: 0] += 0.1
        }

        // Short numeric - likely quantity
        if text.range(of: #"^\d{1,3}$"#, options: .regularExpression) != nil {
            scores[.lineItemQuantity, default: 0] += 0.2
        }

        // Date-like text
        if text.range(of: #"\d{1,2}[/-]\d{1,2}[/-]\d{2,4}"#, options: .regularExpression) != nil {
            scores[.invoiceDate, default: 0] += 0.2
            scores[.dueDate, default: 0] += 0.2
        }

        // Long text - likely description
        if text.count > 30 {
            scores[.lineItemDescription, default: 0] += 0.2
            scores[.vendor, default: 0] += 0.1
        }
    }

    // MARK: - Helpers

    /// Gather text from nearby observations for context
    private func gatherNearbyText(
        for index: Int,
        in observations: [TextObservation],
        maxDistance: Double
    ) -> [String] {
        guard index < observations.count else { return [] }
        let target = observations[index]
        let targetCenter = CGPoint(
            x: target.boundingBox.midX,
            y: target.boundingBox.midY
        )

        var nearby: [String] = []

        for (i, obs) in observations.enumerated() {
            if i == index { continue }

            let obsCenter = CGPoint(
                x: obs.boundingBox.midX,
                y: obs.boundingBox.midY
            )

            let distance = sqrt(
                pow(obsCenter.x - targetCenter.x, 2) +
                pow(obsCenter.y - targetCenter.y, 2)
            )

            if distance <= maxDistance {
                nearby.append(obs.text)
            }
        }

        return nearby
    }
}

// MARK: - Schema-based Classification

extension FieldClassifier {
    /// Classify observations using a specific schema's mappings
    func classifyWithSchema(
        _ observations: [TextObservation],
        schema: InvoiceSchema
    ) async -> [FieldClassificationResult] {
        var results: [FieldClassificationResult] = []

        for observation in observations {
            let normalizedBox = NormalizedRegion(cgRect: observation.boundingBox)

            // Check each field mapping in the schema
            for mapping in schema.fieldMappings {
                var score = 0.0

                // Region-based matching
                if let region = mapping.region,
                   region.contains(point: CGPoint(x: normalizedBox.x, y: normalizedBox.y), tolerance: 0.1) {
                    score += 0.3 * mapping.effectiveConfidence
                }

                // Pattern-based matching
                if let pattern = mapping.pattern,
                   let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                    let range = NSRange(observation.text.startIndex..<observation.text.endIndex, in: observation.text)
                    if regex.firstMatch(in: observation.text, options: [], range: range) != nil {
                        score += 0.4 * mapping.effectiveConfidence
                    }
                }

                // Label hint matching (check nearby text)
                if let hint = mapping.labelHint?.lowercased(),
                   observation.text.lowercased().contains(hint) {
                    score += 0.2 * mapping.effectiveConfidence
                }

                if score > 0.2 {
                    results.append(FieldClassificationResult(
                        fieldType: mapping.fieldType,
                        confidence: min(1.0, score),
                        probabilities: [mapping.fieldType: score],
                        text: observation.text,
                        boundingBox: normalizedBox
                    ))
                }
            }
        }

        // Remove duplicates, keeping highest confidence for each text
        var bestResults: [String: FieldClassificationResult] = [:]
        for result in results {
            if let existing = bestResults[result.text] {
                if result.confidence > existing.confidence {
                    bestResults[result.text] = result
                }
            } else {
                bestResults[result.text] = result
            }
        }

        return Array(bestResults.values)
    }
}
