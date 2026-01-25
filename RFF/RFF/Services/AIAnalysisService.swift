import Foundation

/// AI provider options
enum AIProvider: String, CaseIterable, Codable {
    case claudeCode = "claude_code"
    case openai = "openai"
    case anthropic = "anthropic"

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code (Local)"
        case .openai: return "OpenAI"
        case .anthropic: return "Claude (Anthropic)"
        }
    }

    var apiKeyEnvVar: String? {
        switch self {
        case .claudeCode: return nil  // No API key needed
        case .openai: return "OPENAI_API_KEY"
        case .anthropic: return "ANTHROPIC_API_KEY"
        }
    }

    var requiresAPIKey: Bool {
        self != .claudeCode
    }
}

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
    case claudeCodeNotAvailable
    case claudeCodeError(String)
    case networkError(String)
    case invalidResponse
    case rateLimited
    case insufficientQuota

    var errorDescription: String? {
        switch self {
        case .apiKeyNotConfigured:
            return "API key not configured. Add it in Settings > AI."
        case .claudeCodeNotAvailable:
            return "Claude Code CLI not found. Install Claude Code or configure an API key."
        case .claudeCodeError(let message):
            return "Claude Code error: \(message)"
        case .networkError(let message):
            return "Network error: \(message)"
        case .invalidResponse:
            return "Invalid response from AI service"
        case .rateLimited:
            return "Rate limited. Please try again later."
        case .insufficientQuota:
            return "API quota exceeded. Check your billing settings."
        }
    }
}

/// Service for AI-assisted document analysis using OpenAI or Anthropic API
/// Privacy-first: Only sends data when user explicitly requests
actor AIAnalysisService {
    /// UserDefaults keys for API configuration
    private static let openAIKeyDefaultsKey = "ai_openai_api_key"
    private static let anthropicKeyDefaultsKey = "ai_anthropic_api_key"
    private static let selectedProviderDefaultsKey = "ai_selected_provider"

    /// Shared instance
    static let shared = AIAnalysisService()

    private let session: URLSession
    private let defaults = UserDefaults.standard

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    // MARK: - Claude Code CLI Detection

    /// Check if Claude Code CLI is available in PATH
    nonisolated func isClaudeCodeAvailable() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["claude"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Get the path to the Claude CLI
    nonisolated func getClaudeCodePath() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["claude"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty {
                    return path
                }
            }
        } catch {
            // Fall through to return nil
        }
        return nil
    }

    // MARK: - Provider Management

    /// Get the currently selected provider
    func getSelectedProvider() -> AIProvider {
        if let rawValue = defaults.string(forKey: Self.selectedProviderDefaultsKey),
           let provider = AIProvider(rawValue: rawValue) {
            // Validate that Claude Code is still available if selected
            if provider == .claudeCode && !isClaudeCodeAvailable() {
                return detectAvailableProvider() ?? .anthropic
            }
            return provider
        }
        // Auto-detect based on available providers
        return detectAvailableProvider() ?? .anthropic
    }

    /// Set the selected provider
    func setSelectedProvider(_ provider: AIProvider) {
        defaults.set(provider.rawValue, forKey: Self.selectedProviderDefaultsKey)
    }

    /// Auto-detect available provider based on CLI availability and API keys
    func detectAvailableProvider() -> AIProvider? {
        // Priority: Claude Code CLI first (no API key needed!)
        if isClaudeCodeAvailable() {
            return .claudeCode
        }
        // Then Anthropic API
        if isAPIKeyConfigured(for: .anthropic) {
            return .anthropic
        }
        // Then OpenAI API
        if isAPIKeyConfigured(for: .openai) {
            return .openai
        }
        return nil
    }

    // MARK: - API Key Management

    /// Check if API key is configured for a specific provider
    func isAPIKeyConfigured(for provider: AIProvider) -> Bool {
        // Claude Code doesn't need an API key
        if provider == .claudeCode {
            return isClaudeCodeAvailable()
        }
        // Check environment variable first
        if let envVar = provider.apiKeyEnvVar,
           let envKey = ProcessInfo.processInfo.environment[envVar],
           !envKey.isEmpty {
            return true
        }
        // Check UserDefaults
        let defaultsKey = provider == .openai ? Self.openAIKeyDefaultsKey : Self.anthropicKeyDefaultsKey
        if let storedKey = defaults.string(forKey: defaultsKey), !storedKey.isEmpty {
            return true
        }
        return false
    }

    /// Check if any AI provider is available (CLI or API key)
    func isAnyAPIKeyConfigured() -> Bool {
        isClaudeCodeAvailable() || isAPIKeyConfigured(for: .openai) || isAPIKeyConfigured(for: .anthropic)
    }

    /// Get the API key for a provider (throws if not configured)
    func getAPIKey(for provider: AIProvider) throws -> String {
        // Claude Code doesn't need an API key
        if provider == .claudeCode {
            if isClaudeCodeAvailable() {
                return ""  // No key needed
            }
            throw AIAnalysisError.claudeCodeNotAvailable
        }
        // Check environment variable first
        if let envVar = provider.apiKeyEnvVar,
           let envKey = ProcessInfo.processInfo.environment[envVar],
           !envKey.isEmpty {
            return envKey
        }
        // Check UserDefaults
        let defaultsKey = provider == .openai ? Self.openAIKeyDefaultsKey : Self.anthropicKeyDefaultsKey
        if let storedKey = defaults.string(forKey: defaultsKey), !storedKey.isEmpty {
            return storedKey
        }
        throw AIAnalysisError.apiKeyNotConfigured
    }

    /// Save the API key for a provider
    func saveAPIKey(_ key: String, for provider: AIProvider) {
        let defaultsKey = provider == .openai ? Self.openAIKeyDefaultsKey : Self.anthropicKeyDefaultsKey
        defaults.set(key, forKey: defaultsKey)
    }

    /// Delete the API key for a provider
    func deleteAPIKey(for provider: AIProvider) {
        let defaultsKey = provider == .openai ? Self.openAIKeyDefaultsKey : Self.anthropicKeyDefaultsKey
        defaults.removeObject(forKey: defaultsKey)
    }

    // MARK: - Legacy API (for compatibility)

    /// Check if API key is configured (uses selected provider)
    func isAPIKeyConfigured() -> Bool {
        isAPIKeyConfigured(for: getSelectedProvider())
    }

    /// Get the API key (uses selected provider)
    func getAPIKey() throws -> String {
        try getAPIKey(for: getSelectedProvider())
    }

    /// Save the API key (uses selected provider)
    func saveAPIKey(_ key: String) {
        saveAPIKey(key, for: getSelectedProvider())
    }

    /// Delete the API key (uses selected provider)
    func deleteAPIKey() {
        deleteAPIKey(for: getSelectedProvider())
    }

    // MARK: - Document Analysis

    /// Analyze document text using the selected AI provider
    /// This is only called when user explicitly taps "AI Analyze"
    func analyzeDocument(text: String) async throws -> AIAnalysisResult {
        let provider = getSelectedProvider()
        let apiKey = try getAPIKey(for: provider)

        let prompt = buildAnalysisPrompt(for: text)
        let response = try await callAI(prompt: prompt, apiKey: apiKey, provider: provider)

        return try parseAnalysisResponse(response)
    }

    /// Suggest a schema for the document
    func suggestSchema(text: String, existingSchemas: [InvoiceSchema]) async throws -> InvoiceSchema? {
        let provider = getSelectedProvider()
        let apiKey = try getAPIKey(for: provider)

        let schemaNames = existingSchemas.map { $0.name }.joined(separator: ", ")
        let prompt = """
        Analyze this invoice text and determine if it matches any of these existing schemas: \(schemaNames)

        If it matches an existing schema, respond with just the schema name.
        If it's a new vendor/format, respond with "NEW: [suggested schema name]"

        Invoice text:
        \(text.prefix(3000))
        """

        let response = try await callAI(prompt: prompt, apiKey: apiKey, provider: provider)

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

    private func callAI(prompt: String, apiKey: String, provider: AIProvider) async throws -> String {
        switch provider {
        case .claudeCode:
            return try await callClaudeCode(prompt: prompt)
        case .openai:
            return try await callOpenAI(prompt: prompt, apiKey: apiKey)
        case .anthropic:
            return try await callAnthropic(prompt: prompt, apiKey: apiKey)
        }
    }

    private func callClaudeCode(prompt: String) async throws -> String {
        guard let claudePath = getClaudeCodePath() else {
            throw AIAnalysisError.claudeCodeNotAvailable
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: claudePath)
            // Use --print mode for non-interactive single-shot prompts
            // --output-format text ensures we get plain text response
            process.arguments = ["--print", "--output-format", "text", prompt]

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try process.run()

                // Run in background to avoid blocking
                DispatchQueue.global(qos: .userInitiated).async {
                    process.waitUntilExit()

                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

                    if process.terminationStatus == 0 {
                        if let output = String(data: outputData, encoding: .utf8) {
                            continuation.resume(returning: output.trimmingCharacters(in: .whitespacesAndNewlines))
                        } else {
                            continuation.resume(throwing: AIAnalysisError.invalidResponse)
                        }
                    } else {
                        let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                        continuation.resume(throwing: AIAnalysisError.claudeCodeError(errorMessage.trimmingCharacters(in: .whitespacesAndNewlines)))
                    }
                }
            } catch {
                continuation.resume(throwing: AIAnalysisError.claudeCodeError(error.localizedDescription))
            }
        }
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

    private func callAnthropic(prompt: String, apiKey: String) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": "claude-sonnet-4-20250514",
            "max_tokens": 2000,
            "messages": [
                ["role": "user", "content": prompt]
            ]
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

        // Parse Anthropic response format
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstBlock = content.first,
              let text = firstBlock["text"] as? String else {
            throw AIAnalysisError.invalidResponse
        }

        return text
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
