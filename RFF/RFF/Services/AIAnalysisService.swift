import Foundation

/// Suggested field from AI analysis
struct AIFieldSuggestion: Identifiable, Codable, Sendable {
    let id: UUID
    let fieldType: String
    let value: String
    let confidence: Double
    let reasoning: String?

    init(id: UUID = UUID(), fieldType: String, value: String, confidence: Double, reasoning: String? = nil) {
        self.id = id
        self.fieldType = fieldType
        self.value = value
        self.confidence = confidence
        self.reasoning = reasoning
    }

    /// Convert to InvoiceFieldType if valid
    var invoiceFieldType: InvoiceFieldType? {
        InvoiceFieldType(rawValue: fieldType)
    }
}

/// Result of AI document analysis
struct AIAnalysisResult: Sendable {
    /// Suggested field values
    let suggestions: [AIFieldSuggestion]

    /// Suggested schema name based on vendor
    let suggestedSchemaName: String?

    /// Document summary
    let summary: String?

    /// Any warnings or notes
    let notes: [String]
}

/// Errors during AI analysis
enum AIAnalysisError: Error, LocalizedError {
    case apiKeyNotConfigured
    case networkError(String)
    case invalidResponse
    case rateLimited
    case insufficientQuota

    var errorDescription: String? {
        switch self {
        case .apiKeyNotConfigured:
            return "OpenAI API key not configured. Add it in Settings > AI."
        case .networkError(let message):
            return "Network error: \(message)"
        case .invalidResponse:
            return "Invalid response from AI service"
        case .rateLimited:
            return "Rate limited. Please try again later."
        case .insufficientQuota:
            return "OpenAI API quota exceeded. Check your billing settings."
        }
    }
}

/// Service for AI-assisted document analysis using OpenAI API
/// Privacy-first: Only sends data when user explicitly requests
actor AIAnalysisService {
    /// Keychain key for OpenAI API key
    static let apiKeyKeychainKey = "openai_api_key"

    /// Shared instance
    static let shared = AIAnalysisService()

    private let keychainManager = KeychainManager()
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    // MARK: - API Key Management

    /// Check if API key is configured
    func isAPIKeyConfigured() -> Bool {
        keychainManager.tokenExists(forKey: Self.apiKeyKeychainKey)
    }

    /// Get the API key (throws if not configured)
    func getAPIKey() throws -> String {
        guard isAPIKeyConfigured() else {
            throw AIAnalysisError.apiKeyNotConfigured
        }
        return try keychainManager.retrieveToken(forKey: Self.apiKeyKeychainKey)
    }

    /// Save the API key
    func saveAPIKey(_ key: String) throws {
        try keychainManager.saveToken(key, forKey: Self.apiKeyKeychainKey)
    }

    /// Delete the API key
    func deleteAPIKey() throws {
        try keychainManager.deleteToken(forKey: Self.apiKeyKeychainKey)
    }

    // MARK: - Document Analysis

    /// Analyze document text using OpenAI
    /// This is only called when user explicitly taps "AI Analyze"
    func analyzeDocument(text: String) async throws -> AIAnalysisResult {
        let apiKey = try getAPIKey()

        let prompt = buildAnalysisPrompt(for: text)
        let response = try await callOpenAI(prompt: prompt, apiKey: apiKey)

        return try parseAnalysisResponse(response)
    }

    /// Suggest a schema for the document
    func suggestSchema(text: String, existingSchemas: [InvoiceSchema]) async throws -> InvoiceSchema? {
        let apiKey = try getAPIKey()

        let schemaNames = existingSchemas.map { $0.name }.joined(separator: ", ")
        let prompt = """
        Analyze this invoice text and determine if it matches any of these existing schemas: \(schemaNames)

        If it matches an existing schema, respond with just the schema name.
        If it's a new vendor/format, respond with "NEW: [suggested schema name]"

        Invoice text:
        \(text.prefix(3000))
        """

        let response = try await callOpenAI(prompt: prompt, apiKey: apiKey)

        if response.hasPrefix("NEW:") {
            // Create new schema suggestion
            return nil
        } else {
            // Find matching schema
            let schemaName = response.trimmingCharacters(in: .whitespacesAndNewlines)
            return existingSchemas.first { $0.name.lowercased() == schemaName.lowercased() }
        }
    }

    // MARK: - Private Implementation

    private func buildAnalysisPrompt(for text: String) -> String {
        """
        You are an invoice data extraction assistant. Analyze the following invoice text and extract structured data.

        Return a JSON object with the following structure:
        {
            "suggestions": [
                {
                    "fieldType": "invoice_number|invoice_date|due_date|vendor|customer_name|subtotal|tax|total|currency|po_number",
                    "value": "extracted value",
                    "confidence": 0.0-1.0,
                    "reasoning": "brief explanation"
                }
            ],
            "schemaName": "suggested name for this invoice format (e.g., 'Amazon Business', 'Staples Invoice')",
            "summary": "one-line summary of the invoice",
            "notes": ["any warnings or observations about data quality"]
        }

        Focus on extracting:
        - Invoice number (invoice_number)
        - Invoice date (invoice_date) - format as ISO 8601 (YYYY-MM-DD)
        - Due date (due_date) - format as ISO 8601 (YYYY-MM-DD)
        - Vendor/seller name (vendor)
        - Customer/buyer name (customer_name)
        - Subtotal before tax (subtotal) - numeric value only
        - Tax amount (tax) - numeric value only
        - Total amount (total) - numeric value only
        - Currency (currency) - USD, EUR, GBP, etc.
        - PO number if present (po_number)

        Invoice text:
        \(text.prefix(4000))

        Respond with only the JSON object, no markdown code blocks.
        """
    }

    private func callOpenAI(prompt: String, apiKey: String) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.3,
            "max_tokens": 2000
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIAnalysisError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 429:
            throw AIAnalysisError.rateLimited
        case 401:
            throw AIAnalysisError.apiKeyNotConfigured
        case 402:
            throw AIAnalysisError.insufficientQuota
        default:
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AIAnalysisError.networkError("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIAnalysisError.invalidResponse
        }

        return content
    }

    private func parseAnalysisResponse(_ response: String) throws -> AIAnalysisResult {
        // Clean up response - remove markdown code blocks if present
        var cleanResponse = response
        if cleanResponse.hasPrefix("```json") {
            cleanResponse = String(cleanResponse.dropFirst(7))
        }
        if cleanResponse.hasPrefix("```") {
            cleanResponse = String(cleanResponse.dropFirst(3))
        }
        if cleanResponse.hasSuffix("```") {
            cleanResponse = String(cleanResponse.dropLast(3))
        }
        cleanResponse = cleanResponse.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleanResponse.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIAnalysisError.invalidResponse
        }

        var suggestions: [AIFieldSuggestion] = []

        if let suggestionsArray = json["suggestions"] as? [[String: Any]] {
            for item in suggestionsArray {
                guard let fieldType = item["fieldType"] as? String,
                      let value = item["value"] as? String else {
                    continue
                }

                let confidence = item["confidence"] as? Double ?? 0.5
                let reasoning = item["reasoning"] as? String

                suggestions.append(AIFieldSuggestion(
                    fieldType: fieldType,
                    value: value,
                    confidence: confidence,
                    reasoning: reasoning
                ))
            }
        }

        let schemaName = json["schemaName"] as? String
        let summary = json["summary"] as? String
        let notes = json["notes"] as? [String] ?? []

        return AIAnalysisResult(
            suggestions: suggestions,
            suggestedSchemaName: schemaName,
            summary: summary,
            notes: notes
        )
    }
}

// MARK: - Preview Helpers

extension AIAnalysisResult {
    static var preview: AIAnalysisResult {
        AIAnalysisResult(
            suggestions: [
                AIFieldSuggestion(fieldType: "vendor", value: "Acme Corp", confidence: 0.95, reasoning: "Found at top of invoice"),
                AIFieldSuggestion(fieldType: "invoice_number", value: "INV-2024-001", confidence: 0.9, reasoning: "Standard invoice number format"),
                AIFieldSuggestion(fieldType: "total", value: "1234.56", confidence: 0.85, reasoning: "Largest amount on invoice")
            ],
            suggestedSchemaName: "Acme Corp Invoice",
            summary: "Invoice from Acme Corp for office supplies",
            notes: ["Tax amount may be included in total"]
        )
    }
}
