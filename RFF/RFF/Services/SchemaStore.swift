import Foundation

/// Errors that can occur in schema operations
enum SchemaStoreError: Error, LocalizedError {
    case schemaNotFound(UUID)
    case cannotModifyBuiltIn
    case saveFailed(String)
    case loadFailed(String)
    case invalidSchema(String)

    var errorDescription: String? {
        switch self {
        case .schemaNotFound(let id):
            return "Schema not found: \(id)"
        case .cannotModifyBuiltIn:
            return "Cannot modify built-in schemas"
        case .saveFailed(let reason):
            return "Failed to save schema: \(reason)"
        case .loadFailed(let reason):
            return "Failed to load schemas: \(reason)"
        case .invalidSchema(let reason):
            return "Invalid schema: \(reason)"
        }
    }
}

/// Service for managing invoice schemas - storage, retrieval, and matching
actor SchemaStore {
    /// Singleton instance
    static let shared = SchemaStore()

    /// All loaded schemas (built-in + user-created)
    private var schemas: [UUID: InvoiceSchema] = [:]

    /// Directory for storing user schemas
    private let userSchemasDirectory: URL

    /// File for user schemas JSON
    private let userSchemasFile: URL

    private init() {
        // Set up storage directory
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDirectory = appSupport.appendingPathComponent("RFF", isDirectory: true)
        self.userSchemasDirectory = appDirectory.appendingPathComponent("Schemas", isDirectory: true)
        self.userSchemasFile = userSchemasDirectory.appendingPathComponent("user_schemas.json")

        // Create directory if needed
        try? FileManager.default.createDirectory(at: userSchemasDirectory, withIntermediateDirectories: true)
    }

    /// Load all schemas (built-in + user) on startup
    func loadSchemas() async throws {
        // Load built-in schemas
        for schema in Self.builtInSchemas {
            schemas[schema.id] = schema
        }

        // Load user schemas
        try await loadUserSchemas()
    }

    /// Get all schemas
    func allSchemas() -> [InvoiceSchema] {
        Array(schemas.values).sorted { $0.name < $1.name }
    }

    /// Get built-in schemas only
    func builtInSchemas() -> [InvoiceSchema] {
        schemas.values.filter { $0.isBuiltIn }.sorted { $0.name < $1.name }
    }

    /// Get user-created schemas only
    func userSchemas() -> [InvoiceSchema] {
        schemas.values.filter { !$0.isBuiltIn }.sorted { $0.name < $1.name }
    }

    /// Get a schema by ID
    func schema(id: UUID) -> InvoiceSchema? {
        schemas[id]
    }

    /// Find schemas matching a vendor name
    func schemasMatching(vendor: String) -> [InvoiceSchema] {
        let normalizedVendor = vendor.lowercased().trimmingCharacters(in: .whitespaces)
        return schemas.values.filter { schema in
            guard let vendorId = schema.vendorIdentifier?.lowercased() else { return false }
            return normalizedVendor.contains(vendorId) || vendorId.contains(normalizedVendor)
        }.sorted { $0.usageCount > $1.usageCount }
    }

    /// Find the best matching schema for extracted text
    func findBestMatch(forText text: String) -> InvoiceSchema? {
        let lowercasedText = text.lowercased()

        // Score each schema based on vendor match and usage
        var bestMatch: InvoiceSchema?
        var bestScore = 0.0

        for schema in schemas.values {
            var score = 0.0

            // Vendor identifier match
            if let vendorId = schema.vendorIdentifier?.lowercased(),
               lowercasedText.contains(vendorId) {
                score += 10.0
            }

            // Label hints match
            for mapping in schema.fieldMappings {
                if let hint = mapping.labelHint?.lowercased(),
                   lowercasedText.contains(hint) {
                    score += 1.0 * mapping.effectiveConfidence
                }
            }

            // Boost by usage and confidence
            score += Double(schema.usageCount) * 0.1
            score += schema.averageConfidence * 2.0

            if score > bestScore {
                bestScore = score
                bestMatch = schema
            }
        }

        // Only return if we have a reasonable match
        return bestScore > 5.0 ? bestMatch : nil
    }

    // MARK: - CRUD Operations

    /// Create a new user schema
    func createSchema(
        name: String,
        vendorIdentifier: String? = nil,
        description: String? = nil,
        fieldMappings: [FieldMapping] = []
    ) async throws -> InvoiceSchema {
        let schema = InvoiceSchema(
            name: name,
            vendorIdentifier: vendorIdentifier,
            description: description,
            fieldMappings: fieldMappings,
            isBuiltIn: false
        )

        schemas[schema.id] = schema
        try await saveUserSchemas()
        return schema
    }

    /// Update an existing user schema
    func updateSchema(_ schema: InvoiceSchema) async throws {
        guard !schema.isBuiltIn else {
            throw SchemaStoreError.cannotModifyBuiltIn
        }

        guard schemas[schema.id] != nil else {
            throw SchemaStoreError.schemaNotFound(schema.id)
        }

        var updated = schema
        updated.updatedAt = Date()
        schemas[schema.id] = updated
        try await saveUserSchemas()
    }

    /// Delete a user schema
    func deleteSchema(id: UUID) async throws {
        guard let schema = schemas[id] else {
            throw SchemaStoreError.schemaNotFound(id)
        }

        guard !schema.isBuiltIn else {
            throw SchemaStoreError.cannotModifyBuiltIn
        }

        schemas.removeValue(forKey: id)
        try await saveUserSchemas()
    }

    /// Duplicate a schema (for customization)
    func duplicateSchema(id: UUID, newName: String) async throws -> InvoiceSchema {
        guard let original = schemas[id] else {
            throw SchemaStoreError.schemaNotFound(id)
        }

        let duplicate = InvoiceSchema(
            name: newName,
            vendorIdentifier: original.vendorIdentifier,
            description: "Copy of \(original.name)",
            fieldMappings: original.fieldMappings,
            isBuiltIn: false
        )

        schemas[duplicate.id] = duplicate
        try await saveUserSchemas()
        return duplicate
    }

    /// Record successful use of a schema
    func recordUsage(schemaId: UUID, confidence: Double) async {
        guard var schema = schemas[schemaId] else { return }

        schema.usageCount += 1
        // Rolling average of confidence
        schema.averageConfidence = (schema.averageConfidence * Double(schema.usageCount - 1) + confidence) / Double(schema.usageCount)
        schema.updatedAt = Date()

        schemas[schemaId] = schema

        if !schema.isBuiltIn {
            try? await saveUserSchemas()
        }
    }

    /// Update field mapping confidence based on user feedback
    func updateFieldConfidence(
        schemaId: UUID,
        fieldType: InvoiceFieldType,
        confirmed: Bool
    ) async throws {
        guard var schema = schemas[schemaId] else {
            throw SchemaStoreError.schemaNotFound(schemaId)
        }

        guard !schema.isBuiltIn else {
            throw SchemaStoreError.cannotModifyBuiltIn
        }

        if let index = schema.fieldMappings.firstIndex(where: { $0.fieldType == fieldType }) {
            var mapping = schema.fieldMappings[index]
            if confirmed {
                mapping.confirmationCount += 1
            } else {
                mapping.correctionCount += 1
            }
            schema.fieldMappings[index] = mapping
        }

        schema.updatedAt = Date()
        schemas[schemaId] = schema
        try await saveUserSchemas()
    }

    // MARK: - Persistence

    private func loadUserSchemas() async throws {
        guard FileManager.default.fileExists(atPath: userSchemasFile.path) else {
            return // No user schemas yet
        }

        do {
            let data = try Data(contentsOf: userSchemasFile)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let userSchemas = try decoder.decode([InvoiceSchema].self, from: data)

            for schema in userSchemas {
                schemas[schema.id] = schema
            }
        } catch {
            throw SchemaStoreError.loadFailed(error.localizedDescription)
        }
    }

    private func saveUserSchemas() async throws {
        let userSchemasList = schemas.values.filter { !$0.isBuiltIn }

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(Array(userSchemasList))
            try data.write(to: userSchemasFile, options: .atomic)
        } catch {
            throw SchemaStoreError.saveFailed(error.localizedDescription)
        }
    }

    /// Export a schema to JSON data
    func exportSchema(id: UUID) throws -> Data {
        guard let schema = schemas[id] else {
            throw SchemaStoreError.schemaNotFound(id)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(schema)
    }

    /// Import a schema from JSON data
    func importSchema(from data: Data) async throws -> InvoiceSchema {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var schema = try decoder.decode(InvoiceSchema.self, from: data)

        // Ensure imported schemas are not built-in and get new ID
        schema = InvoiceSchema(
            name: schema.name,
            vendorIdentifier: schema.vendorIdentifier,
            description: schema.description,
            fieldMappings: schema.fieldMappings,
            isBuiltIn: false
        )

        schemas[schema.id] = schema
        try await saveUserSchemas()
        return schema
    }
}

// MARK: - Built-in Schemas

extension SchemaStore {
    /// Predefined schemas for common invoice formats
    static let builtInSchemas: [InvoiceSchema] = [
        // Generic Invoice Schema
        InvoiceSchema(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Generic Invoice",
            vendorIdentifier: nil,
            description: "General-purpose invoice schema for common formats",
            fieldMappings: [
                FieldMapping(
                    fieldType: .invoiceNumber,
                    pattern: #"(?:Invoice|Inv|#)\s*:?\s*([A-Z0-9-]+)"#,
                    labelHint: "Invoice",
                    confidence: 0.6
                ),
                FieldMapping(
                    fieldType: .invoiceDate,
                    pattern: #"(?:Date|Invoice Date)\s*:?\s*(\d{1,2}[/-]\d{1,2}[/-]\d{2,4})"#,
                    labelHint: "Date",
                    confidence: 0.7
                ),
                FieldMapping(
                    fieldType: .dueDate,
                    pattern: #"(?:Due|Due Date|Payment Due)\s*:?\s*(\d{1,2}[/-]\d{1,2}[/-]\d{2,4})"#,
                    labelHint: "Due",
                    confidence: 0.7
                ),
                FieldMapping(
                    fieldType: .vendor,
                    region: NormalizedRegion(x: 0.0, y: 0.7, width: 0.5, height: 0.3),
                    confidence: 0.5
                ),
                FieldMapping(
                    fieldType: .total,
                    pattern: #"(?:Total|Amount Due|Grand Total)\s*:?\s*[$€£]?\s*([\d,]+\.?\d*)"#,
                    labelHint: "Total",
                    confidence: 0.8
                ),
                FieldMapping(
                    fieldType: .subtotal,
                    pattern: #"(?:Subtotal|Sub-total)\s*:?\s*[$€£]?\s*([\d,]+\.?\d*)"#,
                    labelHint: "Subtotal",
                    confidence: 0.7
                ),
                FieldMapping(
                    fieldType: .tax,
                    pattern: #"(?:Tax|VAT|GST)\s*:?\s*[$€£]?\s*([\d,]+\.?\d*)"#,
                    labelHint: "Tax",
                    confidence: 0.7
                )
            ],
            version: 1,
            isBuiltIn: true,
            usageCount: 0,
            averageConfidence: 0.0
        ),

        // Amazon Business Invoice
        InvoiceSchema(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "Amazon Business",
            vendorIdentifier: "amazon",
            description: "Schema for Amazon Business invoices",
            fieldMappings: [
                FieldMapping(
                    fieldType: .invoiceNumber,
                    pattern: #"Order\s*#?\s*:?\s*(\d{3}-\d{7}-\d{7})"#,
                    labelHint: "Order #",
                    confidence: 0.9
                ),
                FieldMapping(
                    fieldType: .invoiceDate,
                    labelHint: "Order Placed",
                    confidence: 0.8
                ),
                FieldMapping(
                    fieldType: .vendor,
                    labelHint: "Sold by",
                    confidence: 0.9
                ),
                FieldMapping(
                    fieldType: .total,
                    pattern: #"Grand Total\s*:?\s*\$?([\d,]+\.\d{2})"#,
                    labelHint: "Grand Total",
                    confidence: 0.9
                ),
                FieldMapping(
                    fieldType: .tax,
                    pattern: #"Tax\s*:?\s*\$?([\d,]+\.\d{2})"#,
                    labelHint: "Tax",
                    confidence: 0.8
                )
            ],
            version: 1,
            isBuiltIn: true,
            usageCount: 0,
            averageConfidence: 0.0
        ),

        // Office Supplies (Staples, Office Depot pattern)
        InvoiceSchema(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            name: "Office Supplies",
            vendorIdentifier: nil,
            description: "Schema for common office supply vendor invoices",
            fieldMappings: [
                FieldMapping(
                    fieldType: .invoiceNumber,
                    pattern: #"(?:Invoice|Order)\s*(?:#|Number|No\.?)\s*:?\s*([A-Z0-9-]+)"#,
                    labelHint: "Invoice",
                    confidence: 0.7
                ),
                FieldMapping(
                    fieldType: .invoiceDate,
                    labelHint: "Invoice Date",
                    confidence: 0.7
                ),
                FieldMapping(
                    fieldType: .poNumber,
                    pattern: #"(?:PO|P\.O\.|Purchase Order)\s*(?:#|Number|No\.?)?\s*:?\s*([A-Z0-9-]+)"#,
                    labelHint: "PO",
                    confidence: 0.8
                ),
                FieldMapping(
                    fieldType: .total,
                    pattern: #"(?:Total|Invoice Total)\s*:?\s*\$?([\d,]+\.\d{2})"#,
                    labelHint: "Total",
                    confidence: 0.8
                ),
                FieldMapping(
                    fieldType: .subtotal,
                    pattern: #"Subtotal\s*:?\s*\$?([\d,]+\.\d{2})"#,
                    labelHint: "Subtotal",
                    confidence: 0.7
                )
            ],
            version: 1,
            isBuiltIn: true,
            usageCount: 0,
            averageConfidence: 0.0
        ),

        // Utility Bill
        InvoiceSchema(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            name: "Utility Bill",
            vendorIdentifier: nil,
            description: "Schema for utility bills (electric, gas, water)",
            fieldMappings: [
                FieldMapping(
                    fieldType: .invoiceNumber,
                    pattern: #"(?:Account|Acct)\s*(?:#|Number|No\.?)?\s*:?\s*([A-Z0-9-]+)"#,
                    labelHint: "Account",
                    confidence: 0.7
                ),
                FieldMapping(
                    fieldType: .invoiceDate,
                    labelHint: "Bill Date",
                    confidence: 0.7
                ),
                FieldMapping(
                    fieldType: .dueDate,
                    labelHint: "Due Date",
                    confidence: 0.8
                ),
                FieldMapping(
                    fieldType: .total,
                    pattern: #"(?:Amount Due|Total Due|Current Charges)\s*:?\s*\$?([\d,]+\.\d{2})"#,
                    labelHint: "Amount Due",
                    confidence: 0.9
                ),
                FieldMapping(
                    fieldType: .vendor,
                    region: NormalizedRegion(x: 0.0, y: 0.8, width: 0.4, height: 0.2),
                    confidence: 0.6
                )
            ],
            version: 1,
            isBuiltIn: true,
            usageCount: 0,
            averageConfidence: 0.0
        ),

        // Professional Services Invoice
        InvoiceSchema(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
            name: "Professional Services",
            vendorIdentifier: nil,
            description: "Schema for consulting, legal, or professional service invoices",
            fieldMappings: [
                FieldMapping(
                    fieldType: .invoiceNumber,
                    pattern: #"(?:Invoice|Inv)\s*(?:#|Number|No\.?)?\s*:?\s*([A-Z0-9-]+)"#,
                    labelHint: "Invoice",
                    confidence: 0.7
                ),
                FieldMapping(
                    fieldType: .invoiceDate,
                    labelHint: "Date",
                    confidence: 0.7
                ),
                FieldMapping(
                    fieldType: .dueDate,
                    pattern: #"(?:Due|Payment Due|Net \d+)\s*:?\s*(\d{1,2}[/-]\d{1,2}[/-]\d{2,4})"#,
                    labelHint: "Payment Terms",
                    confidence: 0.7
                ),
                FieldMapping(
                    fieldType: .vendor,
                    region: NormalizedRegion(x: 0.0, y: 0.75, width: 0.5, height: 0.25),
                    confidence: 0.6
                ),
                FieldMapping(
                    fieldType: .customerName,
                    labelHint: "Bill To",
                    confidence: 0.7
                ),
                FieldMapping(
                    fieldType: .total,
                    pattern: #"(?:Total|Amount Due|Balance Due)\s*:?\s*\$?([\d,]+\.\d{2})"#,
                    labelHint: "Total",
                    confidence: 0.8
                ),
                FieldMapping(
                    fieldType: .lineItemDescription,
                    labelHint: "Description",
                    confidence: 0.6
                ),
                FieldMapping(
                    fieldType: .lineItemTotal,
                    labelHint: "Amount",
                    confidence: 0.6
                )
            ],
            version: 1,
            isBuiltIn: true,
            usageCount: 0,
            averageConfidence: 0.0
        )
    ]
}
