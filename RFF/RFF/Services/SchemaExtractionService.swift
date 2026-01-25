import Foundation
import PDFKit

/// Result of schema-based extraction with field values and confidence
struct SchemaExtractionResultWithValues: Sendable {
    /// The schema used for extraction
    let schemaId: UUID

    /// Schema name for display
    let schemaName: String

    /// Extracted field values with their confidence
    let extractedFields: [ExtractedFieldValue]

    /// Overall confidence of the extraction (average of field confidences)
    let overallConfidence: Double

    /// Warnings or issues encountered during extraction
    let warnings: [String]
}

/// A single extracted field value with confidence and source info
struct ExtractedFieldValue: Identifiable, Sendable {
    let id: UUID

    /// The field type
    let fieldType: InvoiceFieldType

    /// The extracted text value
    let value: String

    /// Confidence score (0.0-1.0)
    let confidence: Double

    /// Page index where this value was found
    let pageIndex: Int

    init(
        id: UUID = UUID(),
        fieldType: InvoiceFieldType,
        value: String,
        confidence: Double,
        pageIndex: Int = 0
    ) {
        self.id = id
        self.fieldType = fieldType
        self.value = value
        self.confidence = confidence
        self.pageIndex = pageIndex
    }
}

/// Errors during schema extraction
enum SchemaExtractionError: Error, LocalizedError {
    case noSchemaAssigned
    case schemaNotFound(UUID)
    case noDocumentPath
    case ocrFailed(Error)
    case noFieldsExtracted

    var errorDescription: String? {
        switch self {
        case .noSchemaAssigned:
            return "No schema assigned to this document"
        case .schemaNotFound(let id):
            return "Schema not found: \(id)"
        case .noDocumentPath:
            return "Document has no associated file"
        case .ocrFailed(let error):
            return "OCR processing failed: \(error.localizedDescription)"
        case .noFieldsExtracted:
            return "No fields could be extracted using the schema"
        }
    }
}

/// Service for extracting document fields using a specific schema
actor SchemaExtractionService {
    /// Shared instance
    static let shared = SchemaExtractionService()

    private let ocrService = DocumentOCRService()
    private let fieldClassifier = FieldClassifier.shared

    /// Extract fields from a document using its assigned schema
    /// - Parameters:
    ///   - document: The RFFDocument to extract from
    /// - Returns: Extraction result with field values and confidence scores
    func extractWithDocumentSchema(_ document: RFFDocument) async throws -> SchemaExtractionResultWithValues {
        guard let schemaId = document.schemaId else {
            throw SchemaExtractionError.noSchemaAssigned
        }

        guard let path = document.documentPath else {
            throw SchemaExtractionError.noDocumentPath
        }

        return try await extractWithSchema(
            schemaId: schemaId,
            documentURL: URL(fileURLWithPath: path)
        )
    }

    /// Extract fields from a document URL using a specific schema
    /// - Parameters:
    ///   - schemaId: The schema ID to use for extraction
    ///   - documentURL: The document file URL
    /// - Returns: Extraction result with field values and confidence scores
    func extractWithSchema(
        schemaId: UUID,
        documentURL: URL
    ) async throws -> SchemaExtractionResultWithValues {
        // Get the schema
        let store = SchemaStore.shared
        try? await store.loadSchemas()

        guard let schema = await store.schema(id: schemaId) else {
            throw SchemaExtractionError.schemaNotFound(schemaId)
        }

        return try await extractWithSchema(schema, documentURL: documentURL)
    }

    /// Extract fields from a document URL using a specific schema
    /// - Parameters:
    ///   - schema: The schema to use for extraction
    ///   - documentURL: The document file URL
    /// - Returns: Extraction result with field values and confidence scores
    func extractWithSchema(
        _ schema: InvoiceSchema,
        documentURL: URL
    ) async throws -> SchemaExtractionResultWithValues {
        // Run OCR on the document
        let ocrResult: OCRDocumentResult
        do {
            ocrResult = try await ocrService.processDocument(at: documentURL)
        } catch {
            throw SchemaExtractionError.ocrFailed(error)
        }

        // Convert OCR observations to text observations
        var allObservations: [TextObservation] = []
        for (pageIndex, page) in ocrResult.pages.enumerated() {
            for observation in page.observations {
                var obs = observation
                // Keep track of page for multi-page documents
                allObservations.append(obs)
            }
        }

        // Classify observations using the schema
        let classificationResults = await fieldClassifier.classifyWithSchema(allObservations, schema: schema)

        // Convert classification results to extracted field values
        var extractedFields: [ExtractedFieldValue] = []
        var warnings: [String] = []
        var seenFieldTypes: Set<InvoiceFieldType> = []

        // Group results by field type and take the highest confidence match
        var fieldGroups: [InvoiceFieldType: [FieldClassificationResult]] = [:]
        for result in classificationResults {
            fieldGroups[result.fieldType, default: []].append(result)
        }

        for (fieldType, results) in fieldGroups {
            // Take the highest confidence result for each field type
            if let best = results.max(by: { $0.confidence < $1.confidence }) {
                // Find the page index for this observation
                let pageIndex = allObservations.firstIndex { obs in
                    let box = NormalizedRegion(cgRect: obs.boundingBox)
                    return abs(box.x - best.boundingBox.x) < 0.001 &&
                           abs(box.y - best.boundingBox.y) < 0.001
                }.flatMap { idx -> Int? in
                    // Calculate which page this observation is on
                    var count = 0
                    for (pageIdx, page) in ocrResult.pages.enumerated() {
                        count += page.observations.count
                        if idx < count {
                            return pageIdx
                        }
                    }
                    return 0
                } ?? 0

                extractedFields.append(ExtractedFieldValue(
                    fieldType: fieldType,
                    value: best.text,
                    confidence: best.confidence,
                    pageIndex: pageIndex
                ))
                seenFieldTypes.insert(fieldType)
            }
        }

        // Check for missing required fields
        for fieldType in InvoiceFieldType.allCases where fieldType.isRequired {
            if !seenFieldTypes.contains(fieldType) {
                warnings.append("Required field '\(fieldType.displayName)' not found")
            }
        }

        if extractedFields.isEmpty {
            throw SchemaExtractionError.noFieldsExtracted
        }

        // Calculate overall confidence
        let totalConfidence = extractedFields.reduce(0.0) { $0 + $1.confidence }
        let overallConfidence = totalConfidence / Double(extractedFields.count)

        // Record usage
        let schemaStore = SchemaStore.shared
        await schemaStore.recordUsage(schemaId: schema.id, confidence: overallConfidence)

        return SchemaExtractionResultWithValues(
            schemaId: schema.id,
            schemaName: schema.name,
            extractedFields: extractedFields.sorted { $0.fieldType.displayName < $1.fieldType.displayName },
            overallConfidence: overallConfidence,
            warnings: warnings
        )
    }

    /// Apply extraction results to a document
    /// - Parameters:
    ///   - result: The extraction result
    ///   - document: The document to update
    func applyToDocument(_ result: SchemaExtractionResultWithValues, document: RFFDocument) {
        for field in result.extractedFields {
            switch field.fieldType {
            case .vendor:
                document.requestingOrganization = field.value
            case .total:
                if let amount = parseAmount(field.value) {
                    document.amount = amount
                }
            case .invoiceDate, .dueDate:
                if let date = parseDate(field.value) {
                    document.dueDate = date
                }
            case .currency:
                if let currency = parseCurrency(field.value) {
                    document.currency = currency
                }
            default:
                // Other fields not directly mapped to document model
                break
            }
        }
        document.schemaId = result.schemaId
        document.updatedAt = Date()
    }

    // MARK: - Parsing Helpers

    private func parseAmount(_ text: String) -> Decimal? {
        let cleaned = text
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: "£", with: "")
            .replacingOccurrences(of: "CHF", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Decimal(string: cleaned)
    }

    private func parseDate(_ text: String) -> Date? {
        DateParsingUtility.parseDate(text)
    }

    private func parseCurrency(_ text: String) -> Currency? {
        let lowered = text.lowercased()
        if lowered.contains("usd") || lowered.contains("$") || lowered.contains("dollar") {
            return .usd
        } else if lowered.contains("eur") || lowered.contains("€") || lowered.contains("euro") {
            return .eur
        } else if lowered.contains("gbp") || lowered.contains("£") || lowered.contains("pound") {
            return .gbp
        } else if lowered.contains("chf") || lowered.contains("franc") {
            return .chf
        }
        return nil
    }
}
