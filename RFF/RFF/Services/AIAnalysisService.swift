import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// AI provider options
enum AIProvider: String, CaseIterable, Codable {
    case claudeCode = "claude_code"
    case openai = "openai"
    case anthropic = "anthropic"
    case foundation = "foundation"  // Apple Foundation Models (macOS 26+)
    case ollama = "ollama"          // Local Ollama server

    /// Providers offered in the Settings picker. Legacy cases (claudeCode, openai)
    /// stay in the enum so stored selections still decode, but are folded into
    /// the three user-facing options.
    static var selectableCases: [AIProvider] {
        [.foundation, .ollama, .anthropic]
    }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code (Local)"
        case .openai: return "OpenAI"
        case .anthropic: return "Claude"
        case .foundation: return "Apple Intelligence"
        case .ollama: return "Ollama"
        }
    }

    var apiKeyEnvVar: String? {
        switch self {
        case .claudeCode: return nil  // No API key needed
        case .foundation: return nil  // No API key needed - on-device
        case .ollama: return nil      // Local server - no API key needed
        case .openai: return "OPENAI_API_KEY"
        case .anthropic: return "ANTHROPIC_API_KEY"
        }
    }

    var requiresAPIKey: Bool {
        self == .openai || self == .anthropic
    }

    /// Whether this provider runs entirely on-device (no external network)
    var isOnDevice: Bool {
        self == .foundation || self == .ollama
    }
}

/// A model installed in the local Ollama server
struct OllamaModel: Identifiable, Sendable, Hashable {
    let name: String
    /// Approximate parameter count in billions, parsed from Ollama's "32.8B" style strings
    let parameterBillions: Double

    var id: String { name }
}

/// A single option value for an AI field suggestion with its own confidence
struct AIFieldOption: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    let value: String
    let confidence: Double
    let reasoning: String?

    init(id: UUID = UUID(), value: String, confidence: Double, reasoning: String? = nil) {
        self.id = id
        self.value = value
        self.confidence = confidence
        self.reasoning = reasoning
    }
}

/// Suggested field from AI analysis
struct AIFieldSuggestion: Identifiable, Codable, Sendable {
    let id: UUID
    let fieldType: String
    let value: String
    let confidence: Double
    let reasoning: String?
    /// Multiple value options with confidence weights (empty for single-option suggestions)
    let options: [AIFieldOption]

    init(id: UUID = UUID(), fieldType: String, value: String, confidence: Double, reasoning: String? = nil, options: [AIFieldOption] = []) {
        self.id = id
        self.fieldType = fieldType
        self.value = value
        self.confidence = confidence
        self.reasoning = reasoning
        // If no options provided, create a default option from the primary value
        if options.isEmpty {
            self.options = [AIFieldOption(value: value, confidence: confidence, reasoning: reasoning)]
        } else {
            self.options = options
        }
    }

    /// Whether this suggestion has multiple alternative values to choose from
    var hasAlternatives: Bool {
        options.count > 1
    }

    /// Convert to InvoiceFieldType if valid
    /// Handles aliases for backwards compatibility and local AI variations
    var invoiceFieldType: InvoiceFieldType? {
        // Try direct match first
        if let fieldType = InvoiceFieldType(rawValue: fieldType) {
            return fieldType
        }
        // Handle aliases - local AI models may use varied field names
        switch fieldType.lowercased() {
        case "recipient_name", "buyer", "buyer_name", "bill_to", "customer_name", "customer":
            return .recipient
        case "seller", "seller_name", "from":
            return .vendor
        case "invoice_no", "inv_number", "bill_number":
            return .invoiceNumber
        case "date", "issued_date":
            return .invoiceDate
        case "payment_due", "pay_by":
            return .dueDate
        case "amount", "amount_due", "balance_due", "grand_total":
            return .total
        case "sub_total":
            return .subtotal
        case "vat", "sales_tax":
            return .tax
        case "purchase_order", "purchase_order_number":
            return .poNumber
        default:
            return nil
        }
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
    case foundationModelsNotAvailable
    case foundationModelsError(String)
    case ollamaNotAvailable
    case ollamaError(String)
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
        case .ollamaNotAvailable:
            return "Ollama is not running or has no models installed. Start Ollama and pull a model first."
        case .ollamaError(let message):
            return "Ollama error: \(message)"
        case .foundationModelsNotAvailable:
            return "On-device AI requires macOS 26 or later."
        case .foundationModelsError(let message):
            return "On-device AI error: \(message)"
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
    private static let ollamaModelDefaultsKey = "ai_ollama_model"

    /// Local Ollama server (default install)
    static let ollamaBaseURL = URL(string: "http://127.0.0.1:11434")!

    /// Shared instance
    static let shared = AIAnalysisService()

    private let session: URLSession
    /// Separate session for Ollama: local models can take minutes to generate
    private let ollamaSession: URLSession
    private let defaults = UserDefaults.standard

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)

        let ollamaConfig = URLSessionConfiguration.default
        ollamaConfig.timeoutIntervalForRequest = 600
        ollamaConfig.timeoutIntervalForResource = 600
        self.ollamaSession = URLSession(configuration: ollamaConfig)
    }

    // MARK: - Claude Code CLI Detection

    /// Common paths where Claude Code CLI might be installed
    /// Note: Sandboxed apps can't use 'which' command, so we check paths directly
    private static let claudeCodePaths: [String] = {
        var paths = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",  // Homebrew on Apple Silicon
            "/usr/bin/claude"
        ]
        // Add user-local paths (expand ~ to actual home directory)
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            paths.insert("\(home)/.local/bin/claude", at: 0)  // npm global install location
        }
        return paths
    }()

    /// Check if Claude Code CLI is available by checking common installation paths
    /// Note: Can't use 'which' command in sandboxed macOS apps
    nonisolated func isClaudeCodeAvailable() -> Bool {
        return getClaudeCodePath() != nil
    }

    /// Get the path to the Claude CLI by checking common installation paths
    /// Note: Can't use 'which' command in sandboxed macOS apps
    nonisolated func getClaudeCodePath() -> String? {
        let fileManager = FileManager.default
        for path in Self.claudeCodePaths {
            if fileManager.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    // MARK: - Foundation Models Detection (macOS 26+)

    /// Check if Apple Foundation Models is available (requires macOS 26+)
    nonisolated func isFoundationModelsAvailable() -> Bool {
        if #available(macOS 26, *) {
            return true
        }
        return false
    }

    // MARK: - Ollama Detection

    /// Fetch the models installed in the local Ollama server (empty if Ollama isn't running)
    func fetchOllamaModels() async -> [OllamaModel] {
        var request = URLRequest(url: Self.ollamaBaseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 3

        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            return []
        }

        return models.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            // Embedding models can't generate text
            if name.localizedCaseInsensitiveContains("embed") { return nil }
            let details = item["details"] as? [String: Any]
            let parameterSize = details?["parameter_size"] as? String ?? ""
            return OllamaModel(name: name, parameterBillions: Self.parseParameterBillions(parameterSize))
        }
    }

    /// Check if the local Ollama server is running with at least one usable model
    func isOllamaAvailable() async -> Bool {
        !(await fetchOllamaModels()).isEmpty
    }

    /// Parse Ollama parameter size strings like "32.8B" or "700M" into billions
    private static func parseParameterBillions(_ string: String) -> Double {
        let trimmed = string.trimmingCharacters(in: .whitespaces).uppercased()
        guard let value = Double(trimmed.filter { $0.isNumber || $0 == "." }) else {
            return 0
        }
        return trimmed.hasSuffix("M") ? value / 1000 : value
    }

    /// Pick the best installed model: the one with the most parameters
    static func bestOllamaModel(among models: [OllamaModel]) -> OllamaModel? {
        models.max { $0.parameterBillions < $1.parameterBillions }
    }

    /// Get the user's preferred Ollama model (empty string means auto-pick the best)
    func getOllamaModel() -> String {
        defaults.string(forKey: Self.ollamaModelDefaultsKey) ?? ""
    }

    /// Set the preferred Ollama model (empty string means auto-pick the best)
    func setOllamaModel(_ model: String) {
        defaults.set(model, forKey: Self.ollamaModelDefaultsKey)
    }

    /// Resolve which Ollama model to use: user preference if still installed, otherwise the best installed one
    private func resolveOllamaModel() async throws -> String {
        let models = await fetchOllamaModels()
        guard !models.isEmpty else {
            throw AIAnalysisError.ollamaNotAvailable
        }
        let preferred = getOllamaModel()
        if !preferred.isEmpty, models.contains(where: { $0.name == preferred }) {
            return preferred
        }
        return Self.bestOllamaModel(among: models)!.name
    }

    // MARK: - Provider Management

    /// Get the currently selected provider
    func getSelectedProvider() -> AIProvider {
        if let rawValue = defaults.string(forKey: Self.selectedProviderDefaultsKey),
           let provider = AIProvider(rawValue: rawValue) {
            // Legacy selections fold into Claude, which prefers the CLI and
            // falls back to the Anthropic API key
            if provider == .claudeCode || provider == .openai {
                return .anthropic
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
        // Claude works without a key via the Claude Code CLI, or with an API key
        if isClaudeCodeAvailable() || isAPIKeyConfigured(for: .anthropic) {
            return .anthropic
        }
        if isFoundationModelsAvailable() {
            return .foundation
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
        // Foundation Models doesn't need an API key - just macOS 26+
        if provider == .foundation {
            return isFoundationModelsAvailable()
        }
        // Ollama is a local server - no key; availability is checked at call time
        if provider == .ollama {
            return true
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

    /// Check if any AI provider is available (CLI, on-device, or API key)
    func isAnyAPIKeyConfigured() -> Bool {
        isClaudeCodeAvailable() || isFoundationModelsAvailable() || isAPIKeyConfigured(for: .openai) || isAPIKeyConfigured(for: .anthropic)
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
        // Foundation Models doesn't need an API key
        if provider == .foundation {
            if isFoundationModelsAvailable() {
                return ""  // No key needed - on-device
            }
            throw AIAnalysisError.foundationModelsNotAvailable
        }
        // Ollama is a local server - no key needed
        if provider == .ollama {
            return ""
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
        // Claude can fall back to the local Claude Code CLI when no key is set
        if provider == .anthropic && isClaudeCodeAvailable() {
            return ""  // Empty key signals callAI to use the CLI
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

        let favoriteCurrencies = loadFavoriteCurrencies()
        let prompt = buildAnalysisPrompt(for: text, favoriteCurrencies: favoriteCurrencies)
        let response = try await callAI(prompt: prompt, apiKey: apiKey, provider: provider)

        return try parseAnalysisResponse(response)
    }

    /// Analyze document text using a specific provider
    /// Used for explicit "AI Analyze (Local)" vs "AI Analyze" actions
    func analyzeDocument(text: String, using provider: AIProvider) async throws -> AIAnalysisResult {
        let apiKey = try getAPIKey(for: provider)

        let favoriteCurrencies = loadFavoriteCurrencies()
        let prompt = buildAnalysisPrompt(for: text, favoriteCurrencies: favoriteCurrencies)
        let response = try await callAI(prompt: prompt, apiKey: apiKey, provider: provider)

        return try parseAnalysisResponse(response)
    }

    /// Load user's favorite currencies from settings
    private func loadFavoriteCurrencies() -> [String] {
        guard let data = defaults.data(forKey: "favoriteCurrencies"),
              let favorites = try? JSONDecoder().decode(Set<String>.self, from: data) else {
            return ["USD", "EUR", "GBP"]  // Default favorites
        }
        return Array(favorites).sorted()
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

    private func buildAnalysisPrompt(for text: String, favoriteCurrencies: [String] = ["USD", "EUR", "GBP"]) -> String {
        let currencyList = favoriteCurrencies.isEmpty ? "USD, EUR, GBP" : favoriteCurrencies.joined(separator: ", ")
        let currencyHint = favoriteCurrencies.isEmpty ? "" : """

        IMPORTANT: The user frequently works with these currencies: \(currencyList)
        When identifying the currency, prioritize these if the invoice appears to use one of them.
        For example, if you see "kr" or "SEK", and SEK is in the user's favorites, use SEK.
        """
        return """
        You are an invoice data extraction assistant. Extract structured data from the invoice text below.

        ## STEP 1: Identify the key information
        Look for these fields in the invoice:
        - Invoice number: Look for "Invoice #", "Invoice No.", "Inv:", "Bill #", or similar labels
        - Invoice date: Look for "Invoice Date", "Date:", "Issued:", or the date near the invoice number
        - Due date: Look for "Due Date", "Payment Due", "Due:", "Pay By:"
        - Vendor: The company SENDING the invoice (usually at top, with logo)
        - Recipient: The company/person RECEIVING the invoice (look for "Bill To:", "Ship To:", "Customer:")
        - Amounts: Look for "Subtotal", "Tax", "VAT", "Total", "Amount Due", "Balance Due", "Grand Total"
        - Currency: Look for currency symbols or codes. Common ones include USD ($), EUR (€), GBP (£), SEK (kr), NOK (kr), DKK (kr), CHF, JPY (¥), CNY (¥), and many others.\(currencyHint)
        - PO number: Look for "PO #", "Purchase Order", "P.O.:"

        ## STEP 2: Format the values
        - Dates: Convert to YYYY-MM-DD format
          * "January 15, 2024" → "2024-01-15"
          * "15/01/2024" (European) → "2024-01-15"
          * "01/15/2024" (US) → "2024-01-15"
        - Numbers: Extract numeric value only, no currency symbols
          * "$1,234.56" → "1234.56"
          * "€1.234,56" (European) → "1234.56"
        - Vendor/Recipient: Use the company name only, not the full address

        ## STEP 3: Output JSON format
        {
            "suggestions": [
                {"fieldType": "field_name", "value": "extracted value", "confidence": 0.0-1.0, "reasoning": "why"}
            ],
            "schemaName": "Vendor Name Invoice",
            "summary": "one-line summary",
            "notes": ["warnings if any"]
        }

        Valid fieldType values: invoice_number, invoice_date, due_date, vendor, recipient, subtotal, tax, total, currency, po_number

        ## EXAMPLE 1:
        Input text:
        '''
        ACME CORPORATION
        123 Business St, New York, NY 10001

        INVOICE
        Invoice #: INV-2024-0042
        Date: March 15, 2024
        Due: April 14, 2024

        Bill To:
        Widget Co.
        456 Client Ave

        Services rendered............$500.00
        Consulting hours.............$300.00
        Subtotal: $800.00
        Tax (8%): $64.00
        Total Due: $864.00
        '''

        Output:
        {
            "suggestions": [
                {"fieldType": "vendor", "value": "ACME CORPORATION", "confidence": 0.95, "reasoning": "Company name at top of invoice"},
                {"fieldType": "invoice_number", "value": "INV-2024-0042", "confidence": 0.95, "reasoning": "Labeled as Invoice #"},
                {"fieldType": "invoice_date", "value": "2024-03-15", "confidence": 0.9, "reasoning": "Date field converted to ISO format"},
                {"fieldType": "due_date", "value": "2024-04-14", "confidence": 0.9, "reasoning": "Due date converted to ISO format"},
                {"fieldType": "recipient", "value": "Widget Co.", "confidence": 0.9, "reasoning": "Listed under Bill To"},
                {"fieldType": "subtotal", "value": "800.00", "confidence": 0.9, "reasoning": "Labeled as Subtotal"},
                {"fieldType": "tax", "value": "64.00", "confidence": 0.9, "reasoning": "Labeled as Tax (8%)"},
                {"fieldType": "total", "value": "864.00", "confidence": 0.95, "reasoning": "Labeled as Total Due"},
                {"fieldType": "currency", "value": "USD", "confidence": 0.9, "reasoning": "Dollar sign used"}
            ],
            "schemaName": "ACME Corporation Invoice",
            "summary": "Invoice for services and consulting from ACME Corporation",
            "notes": []
        }

        ## EXAMPLE 2 (European format):
        Input text:
        '''
        Müller GmbH
        Hauptstraße 1, 10115 Berlin

        Rechnung Nr. 2024-123
        Datum: 15.03.2024
        Fällig: 30.03.2024

        An: Schmidt AG

        Beratung: €1.500,00
        MwSt 19%: €285,00
        Gesamt: €1.785,00
        '''

        Output:
        {
            "suggestions": [
                {"fieldType": "vendor", "value": "Müller GmbH", "confidence": 0.95, "reasoning": "Company at top"},
                {"fieldType": "invoice_number", "value": "2024-123", "confidence": 0.9, "reasoning": "Rechnung Nr. means Invoice No."},
                {"fieldType": "invoice_date", "value": "2024-03-15", "confidence": 0.9, "reasoning": "European date format DD.MM.YYYY"},
                {"fieldType": "due_date", "value": "2024-03-30", "confidence": 0.9, "reasoning": "Fällig means Due"},
                {"fieldType": "recipient", "value": "Schmidt AG", "confidence": 0.85, "reasoning": "An: means To:"},
                {"fieldType": "subtotal", "value": "1500.00", "confidence": 0.85, "reasoning": "Amount before tax"},
                {"fieldType": "tax", "value": "285.00", "confidence": 0.9, "reasoning": "MwSt is German VAT"},
                {"fieldType": "total", "value": "1785.00", "confidence": 0.95, "reasoning": "Gesamt means Total"},
                {"fieldType": "currency", "value": "EUR", "confidence": 0.95, "reasoning": "Euro symbol used"}
            ],
            "schemaName": "Müller GmbH Invoice",
            "summary": "German consulting invoice from Müller GmbH",
            "notes": ["European number format converted (comma as decimal separator)"]
        }

        ## NOW ANALYZE THIS INVOICE:
        \(text.prefix(4000))

        Respond with only the JSON object. No markdown code blocks.
        """
    }

    private func callAI(prompt: String, apiKey: String, provider: AIProvider) async throws -> String {
        switch provider {
        case .claudeCode:
            return try await callClaudeCode(prompt: prompt)
        case .foundation:
            return try await callFoundationModels(prompt: prompt)
        case .ollama:
            return try await callOllama(prompt: prompt)
        case .openai:
            return try await callOpenAI(prompt: prompt, apiKey: apiKey)
        case .anthropic:
            // Empty key means no API key configured but Claude Code CLI is available
            if apiKey.isEmpty {
                return try await callClaudeCode(prompt: prompt)
            }
            return try await callAnthropic(prompt: prompt, apiKey: apiKey)
        }
    }

    private func callOllama(prompt: String) async throws -> String {
        let model = try await resolveOllamaModel()

        var request = URLRequest(url: Self.ollamaBaseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "stream": false,
            // Constrain output to valid JSON - also suppresses reasoning preambles
            "format": "json",
            "options": [
                "temperature": 0.2,
                // The extraction prompt plus invoice text exceeds Ollama's default context
                "num_ctx": 8192
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await ollamaSession.data(for: request)
        } catch {
            throw AIAnalysisError.ollamaNotAvailable
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIAnalysisError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AIAnalysisError.ollamaError("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIAnalysisError.invalidResponse
        }

        return content
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

    private func callFoundationModels(prompt: String) async throws -> String {
        // Requires macOS 26+ - check availability first
        guard isFoundationModelsAvailable() else {
            throw AIAnalysisError.foundationModelsNotAvailable
        }

        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return try await callFoundationModelsImpl(prompt: prompt)
        }
        #endif

        throw AIAnalysisError.foundationModelsNotAvailable
    }

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    private func callFoundationModelsImpl(prompt: String) async throws -> String {
        // Import handled via conditional compilation
        // FoundationModels provides SystemLanguageModel and LanguageModelSession
        let model = SystemLanguageModel.default

        // Check model availability
        switch model.availability {
        case .available:
            break
        case .unavailable(let reason):
            let reasonDescription: String
            switch reason {
            case .appleIntelligenceNotEnabled:
                reasonDescription = "Apple Intelligence is not enabled. Enable it in System Settings > Apple Intelligence & Siri."
            case .deviceNotEligible:
                reasonDescription = "This device does not support Apple Intelligence."
            case .modelNotReady:
                reasonDescription = "The language model is still downloading. Please try again later."
            @unknown default:
                reasonDescription = "The language model is not available."
            }
            throw AIAnalysisError.foundationModelsError(reasonDescription)
        }

        // Create session and generate response
        let session = LanguageModelSession()
        do {
            let response = try await session.respond(to: prompt)
            return response.content
        } catch {
            throw AIAnalysisError.foundationModelsError(error.localizedDescription)
        }
    }
    #endif

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

    /// Extract JSON from AI response, handling markdown code blocks and surrounding text
    private func extractJSON(from response: String) -> String {
        // Try to find JSON within markdown code blocks first
        // Match ```json ... ``` or ``` ... ``` anywhere in the response
        if let jsonBlockRange = response.range(of: "```json\\s*\\n?([\\s\\S]*?)```", options: .regularExpression) {
            let match = String(response[jsonBlockRange])
            // Remove the opening ```json and closing ```
            var jsonContent = match
            if let startRange = jsonContent.range(of: "```json") {
                jsonContent.removeSubrange(startRange)
            }
            if let endRange = jsonContent.range(of: "```", options: .backwards) {
                jsonContent.removeSubrange(endRange)
            }
            return jsonContent.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Try plain ``` blocks
        if let codeBlockRange = response.range(of: "```\\s*\\n?([\\s\\S]*?)```", options: .regularExpression) {
            let match = String(response[codeBlockRange])
            var jsonContent = match
            // Remove leading ```
            if let startRange = jsonContent.range(of: "```") {
                jsonContent.removeSubrange(startRange)
            }
            // Remove trailing ```
            if let endRange = jsonContent.range(of: "```", options: .backwards) {
                jsonContent.removeSubrange(endRange)
            }
            return jsonContent.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // No code blocks found - try to extract JSON object directly
        // Find the first { and last } to extract the JSON
        guard let firstBrace = response.firstIndex(of: "{"),
              let lastBrace = response.lastIndex(of: "}") else {
            return response.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return String(response[firstBrace...lastBrace])
    }

    private func parseAnalysisResponse(_ response: String) throws -> AIAnalysisResult {
        // Extract JSON from response - handle various AI response formats
        let cleanResponse = extractJSON(from: response)

        guard let data = cleanResponse.data(using: .utf8),
              var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIAnalysisError.invalidResponse
        }

        // Local models sometimes wrap the result in an extra object
        // (e.g. {"invoiceData": {"suggestions": [...]}}) - unwrap one level
        if json["suggestions"] == nil,
           let nested = json.values.compactMap({ $0 as? [String: Any] }).first(where: { $0["suggestions"] != nil }) {
            json = nested
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

                // Post-process value based on field type
                let normalizedValue = normalizeFieldValue(value, forFieldType: fieldType)

                suggestions.append(AIFieldSuggestion(
                    fieldType: fieldType,
                    value: normalizedValue,
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

    /// Normalize a field value based on its type
    /// Handles common variations in AI output (currency symbols, date formats, number formats)
    private func normalizeFieldValue(_ value: String, forFieldType fieldType: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        switch fieldType {
        case "subtotal", "tax", "total":
            return normalizeNumericValue(trimmed)
        case "invoice_date", "due_date":
            return normalizeDateValue(trimmed)
        case "currency":
            return normalizeCurrency(trimmed)
        default:
            return trimmed
        }
    }

    /// Normalize numeric values: remove currency symbols, handle European decimals
    private func normalizeNumericValue(_ value: String) -> String {
        var cleaned = value

        // Remove common currency symbols and prefixes (comprehensive list)
        let currencyPatterns = [
            // Symbols
            "$", "€", "£", "¥", "₹", "₩", "₽", "₺", "₪", "₱", "฿",
            // Codes
            "USD", "EUR", "GBP", "CHF", "JPY", "CNY",
            "SEK", "NOK", "DKK", "AUD", "CAD", "NZD",
            "BRL", "HKD", "HUF", "IDR", "ILS", "INR",
            "KRW", "MXN", "MYR", "PHP", "PLN", "RON",
            "RUB", "SGD", "THB", "TRY", "TWD", "ZAR", "CZK",
            // Common prefixes/suffixes
            "kr", "Kr", "KR", "Kč", "zł", "Zł", "Ft", "lei", "Lei",
            "R$", "A$", "C$", "S$", "HK$", "NZ$", "NT$", "MX$",
            "RM", "Rp", "Rs"
        ]
        for pattern in currencyPatterns {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: "", options: .caseInsensitive)
        }

        // Remove thousands separators and whitespace
        cleaned = cleaned.replacingOccurrences(of: " ", with: "")

        // Handle European format: 1.234,56 → 1234.56
        // Check if comma appears after period (European format)
        if let commaIndex = cleaned.lastIndex(of: ","),
           let periodIndex = cleaned.lastIndex(of: "."),
           commaIndex > periodIndex {
            // European format: periods are thousands, comma is decimal
            cleaned = cleaned.replacingOccurrences(of: ".", with: "")
            cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
        } else if cleaned.contains(",") && !cleaned.contains(".") {
            // Comma-only format: might be decimal separator (e.g., "1234,56")
            // Check if comma is followed by exactly 2 digits at end
            if let commaIndex = cleaned.lastIndex(of: ",") {
                let afterComma = cleaned[cleaned.index(after: commaIndex)...]
                if afterComma.count <= 2 && afterComma.allSatisfy({ $0.isNumber }) {
                    cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
                } else {
                    // Comma is thousands separator
                    cleaned = cleaned.replacingOccurrences(of: ",", with: "")
                }
            }
        } else {
            // US format or already clean: just remove commas (thousands separator)
            cleaned = cleaned.replacingOccurrences(of: ",", with: "")
        }

        // Remove any remaining non-numeric characters except decimal point
        cleaned = String(cleaned.filter { $0.isNumber || $0 == "." || $0 == "-" })

        return cleaned
    }

    /// Normalize date values to ISO 8601 (YYYY-MM-DD)
    private func normalizeDateValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        // If already in ISO format, return as-is
        if trimmed.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil {
            return trimmed
        }

        // Try various date formats
        let dateFormats = [
            "MMMM d, yyyy",      // January 15, 2024
            "MMMM dd, yyyy",     // January 15, 2024
            "MMM d, yyyy",       // Jan 15, 2024
            "MMM dd, yyyy",      // Jan 15, 2024
            "d MMMM yyyy",       // 15 January 2024
            "dd MMMM yyyy",      // 15 January 2024
            "d MMM yyyy",        // 15 Jan 2024
            "dd MMM yyyy",       // 15 Jan 2024
            "dd/MM/yyyy",        // 15/01/2024 (European)
            "d/M/yyyy",          // 5/1/2024 (European)
            "MM/dd/yyyy",        // 01/15/2024 (US)
            "M/d/yyyy",          // 1/15/2024 (US)
            "dd.MM.yyyy",        // 15.01.2024 (German)
            "d.M.yyyy",          // 5.1.2024 (German)
            "yyyy/MM/dd",        // 2024/01/15
            "dd-MM-yyyy",        // 15-01-2024
            "MM-dd-yyyy",        // 01-15-2024
        ]

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        let isoFormatter = DateFormatter()
        isoFormatter.dateFormat = "yyyy-MM-dd"
        isoFormatter.locale = Locale(identifier: "en_US_POSIX")

        for format in dateFormats {
            dateFormatter.dateFormat = format
            if let date = dateFormatter.date(from: trimmed) {
                return isoFormatter.string(from: date)
            }
        }

        // If no format matched, return original (AI might have already formatted it)
        return trimmed
    }

    /// Normalize currency codes
    private func normalizeCurrency(_ value: String) -> String {
        let upper = value.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Map symbols and common variations to standard ISO 4217 codes
        let currencyMap: [String: String] = [
            // USD
            "$": "USD",
            "US$": "USD",
            "US DOLLAR": "USD",
            "US DOLLARS": "USD",
            "DOLLAR": "USD",
            "DOLLARS": "USD",
            // EUR
            "€": "EUR",
            "EURO": "EUR",
            "EUROS": "EUR",
            // GBP
            "£": "GBP",
            "POUND": "GBP",
            "POUNDS": "GBP",
            "BRITISH POUND": "GBP",
            "STERLING": "GBP",
            // JPY
            "¥": "JPY",
            "YEN": "JPY",
            "JAPANESE YEN": "JPY",
            // CNY
            "YUAN": "CNY",
            "RMB": "CNY",
            "RENMINBI": "CNY",
            "CHINESE YUAN": "CNY",
            // CHF
            "SWISS FRANC": "CHF",
            "FRANC": "CHF",
            "FR.": "CHF",
            "SFR": "CHF",
            // Scandinavian
            "KR": "SEK",  // Default kr to SEK, but AI should specify
            "KRONA": "SEK",
            "KRONOR": "SEK",
            "SWEDISH KRONA": "SEK",
            "SWEDISH KRONOR": "SEK",
            "KRONE": "NOK",
            "KRONER": "NOK",
            "NORWEGIAN KRONE": "NOK",
            "DANISH KRONE": "DKK",
            // AUD
            "A$": "AUD",
            "AU$": "AUD",
            "AUSTRALIAN DOLLAR": "AUD",
            // CAD
            "C$": "CAD",
            "CA$": "CAD",
            "CANADIAN DOLLAR": "CAD",
            // Other common
            "R$": "BRL",
            "REAL": "BRL",
            "REAIS": "BRL",
            "HK$": "HKD",
            "HONG KONG DOLLAR": "HKD",
            "₹": "INR",
            "RS": "INR",
            "RUPEE": "INR",
            "RUPEES": "INR",
            "₩": "KRW",
            "WON": "KRW",
            "MX$": "MXN",
            "PESO": "MXN",
            "NZ$": "NZD",
            "NEW ZEALAND DOLLAR": "NZD",
            "ZŁ": "PLN",
            "ZLOTY": "PLN",
            "₽": "RUB",
            "RUBLE": "RUB",
            "RUBLES": "RUB",
            "S$": "SGD",
            "SINGAPORE DOLLAR": "SGD",
            "฿": "THB",
            "BAHT": "THB",
            "₺": "TRY",
            "LIRA": "TRY",
            "TURKISH LIRA": "TRY",
            "NT$": "TWD",
            "R": "ZAR",
            "RAND": "ZAR",
            "₪": "ILS",
            "SHEKEL": "ILS",
            "₱": "PHP",
            "RM": "MYR",
            "RINGGIT": "MYR",
            "RP": "IDR",
            "RUPIAH": "IDR",
            "KČ": "CZK",
            "KORUNA": "CZK",
            "FT": "HUF",
            "FORINT": "HUF",
            "LEI": "RON",
            "LEU": "RON",
        ]

        return currencyMap[upper] ?? upper
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
