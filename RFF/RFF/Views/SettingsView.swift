import SwiftUI
import AppKit

/// Settings view for the RFF application
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            NotificationSettingsView()
                .tabItem {
                    Label("Notifications", systemImage: "bell")
                }

            MonitoringSettingsView()
                .tabItem {
                    Label("Pipeline", systemImage: "eye")
                }

            AISettingsView()
                .tabItem {
                    Label("AI", systemImage: "sparkles")
                }

            SchemaSettingsView()
                .tabItem {
                    Label("Schemas", systemImage: "rectangle.3.group")
                }

            AdvancedSettingsView()
                .tabItem {
                    Label("Advanced", systemImage: "gearshape.2")
                }
        }
        .frame(width: 560, height: 520)
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @AppStorage("defaultDueDateDays") private var defaultDueDateDays = 7
    @AppStorage("defaultCurrency") private var defaultCurrency = "USD"
    @AppStorage("favoriteCurrencies") private var favoriteCurrenciesData = Data()
    @AppStorage("autoSaveEnabled") private var autoSaveEnabled = true
    @AppStorage("autoSaveInterval") private var autoSaveInterval = 30

    @State private var favoriteCurrencies: Set<String> = []

    var body: some View {
        Form {
            Section("About RFF") {
                LabeledContent("Version") {
                    Text(appVersion)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("Defaults") {
                Picker("Default Due Date", selection: $defaultDueDateDays) {
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("30 days").tag(30)
                    Text("60 days").tag(60)
                    Text("90 days").tag(90)
                }

                Picker("Default Currency", selection: $defaultCurrency) {
                    ForEach(Currency.allCases) { currency in
                        Text("\(currency.rawValue) (\(currency.symbol))")
                            .tag(currency.rawValue)
                    }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Select currencies you frequently work with. AI analysis will prioritize these when extracting invoice data.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: [
                        GridItem(.adaptive(minimum: 100), spacing: 8)
                    ], spacing: 8) {
                        ForEach(Currency.allCases) { currency in
                            FavoriteCurrencyToggle(
                                currency: currency,
                                isSelected: favoriteCurrencies.contains(currency.rawValue),
                                onToggle: { toggleFavorite(currency) }
                            )
                        }
                    }
                    .padding(.top, 4)
                }
            } header: {
                Text("Favorite Currencies")
            }

            Section("Auto-Save") {
                Toggle("Enable Auto-Save", isOn: $autoSaveEnabled)

                if autoSaveEnabled {
                    Picker("Save Interval", selection: $autoSaveInterval) {
                        Text("15 seconds").tag(15)
                        Text("30 seconds").tag(30)
                        Text("1 minute").tag(60)
                        Text("5 minutes").tag(300)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            loadFavorites()
        }
    }

    private func loadFavorites() {
        if let decoded = try? JSONDecoder().decode(Set<String>.self, from: favoriteCurrenciesData) {
            favoriteCurrencies = decoded
        } else {
            // Default favorites if none set
            favoriteCurrencies = Set(["USD", "EUR", "GBP"])
        }
    }

    private func toggleFavorite(_ currency: Currency) {
        if favoriteCurrencies.contains(currency.rawValue) {
            favoriteCurrencies.remove(currency.rawValue)
        } else {
            favoriteCurrencies.insert(currency.rawValue)
        }
        saveFavorites()
    }

    private func saveFavorites() {
        if let encoded = try? JSONEncoder().encode(favoriteCurrencies) {
            favoriteCurrenciesData = encoded
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        if let build, !build.isEmpty {
            return "\(version) (\(build))"
        }
        return version
    }
}

/// Toggle button for favorite currency selection
private struct FavoriteCurrencyToggle: View {
    let currency: Currency
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 4) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                Text(currency.rawValue)
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.blue : Color.secondary.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(currency.displayName)
    }
}

// MARK: - Notification Settings

struct NotificationSettingsView: View {
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("reminderDaysBefore") private var reminderDaysBefore = 3
    @AppStorage("dailyDigestEnabled") private var dailyDigestEnabled = false
    @AppStorage("dailyDigestTime") private var dailyDigestTime = 9 // Hour of day (0-23)

    var body: some View {
        Form {
            Section("Due Date Reminders") {
                Toggle("Enable Notifications", isOn: $notificationsEnabled)

                if notificationsEnabled {
                    Picker("Remind Me", selection: $reminderDaysBefore) {
                        Text("1 day before").tag(1)
                        Text("3 days before").tag(3)
                        Text("5 days before").tag(5)
                        Text("1 week before").tag(7)
                        Text("2 weeks before").tag(14)
                    }
                }
            }

            Section("Daily Digest") {
                Toggle("Daily Summary", isOn: $dailyDigestEnabled)

                if dailyDigestEnabled {
                    Picker("Digest Time", selection: $dailyDigestTime) {
                        Text("6:00 AM").tag(6)
                        Text("7:00 AM").tag(7)
                        Text("8:00 AM").tag(8)
                        Text("9:00 AM").tag(9)
                        Text("10:00 AM").tag(10)
                        Text("12:00 PM").tag(12)
                        Text("5:00 PM").tag(17)
                    }
                }
            }

            Section {
                Button("Request Notification Permission") {
                    Task {
                        try? await NotificationService.shared.requestAuthorization()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - OCR Settings

struct OCRSettingsView: View {
    @AppStorage("ocrAccuracy") private var ocrAccuracy = "accurate"
    @AppStorage("languageCorrection") private var languageCorrection = true
    @AppStorage("maxConcurrentOCR") private var maxConcurrentOCR = 4

    var body: some View {
        Form {
            Section("Recognition") {
                Picker("Accuracy Level", selection: $ocrAccuracy) {
                    Text("Fast").tag("fast")
                    Text("Accurate").tag("accurate")
                }

                Toggle("Use Language Correction", isOn: $languageCorrection)
            }

            Section("Performance") {
                Picker("Concurrent Pages", selection: $maxConcurrentOCR) {
                    Text("2 pages").tag(2)
                    Text("4 pages").tag(4)
                    Text("8 pages").tag(8)
                    Text("16 pages").tag(16)
                }

                Text("Higher values process faster but use more memory.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Custom Vocabulary") {
                Text("RFF-specific terms are automatically recognized: RFF, disbursement, requisition, funding, allocation, expenditure, reimbursement, invoice, purchase order, budget, fiscal, appropriation, encumbrance, voucher, ledger")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - AI Settings

struct AISettingsView: View {
    @State private var selectedProvider: AIProvider = .anthropic
    @State private var anthropicKey = ""
    @State private var isClaudeCodeAvailable = false
    @State private var isFoundationModelsAvailable = false
    @State private var isOllamaAvailable = false
    @State private var ollamaModels: [OllamaModel] = []
    @State private var selectedOllamaModel = ""  // Empty = auto-pick best
    @State private var isAnthropicKeyConfigured = false
    @State private var showingAnthropicKey = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    private var bestOllamaModelName: String? {
        AIAnalysisService.bestOllamaModel(among: ollamaModels)?.name
    }

    var body: some View {
        Form {
            Section("AI Provider") {
                Picker("Provider", selection: $selectedProvider) {
                    ForEach(AIProvider.selectableCases, id: \.self) { provider in
                        HStack {
                            Text(provider.displayName)
                            if provider == .foundation && !isFoundationModelsAvailable {
                                Text("(macOS 26+)")
                                    .foregroundStyle(.secondary)
                            }
                            if provider == .ollama && !isOllamaAvailable {
                                Text("(Not running)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(provider)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedProvider) { _, newValue in
                    // Don't allow selecting Apple Intelligence if not available
                    if newValue == .foundation && !isFoundationModelsAvailable {
                        Task {
                            selectedProvider = await AIAnalysisService.shared.detectAvailableProvider() ?? .anthropic
                        }
                        return
                    }
                    Task {
                        await AIAnalysisService.shared.setSelectedProvider(newValue)
                    }
                }

                if selectedProvider == .foundation {
                    if isFoundationModelsAvailable {
                        Label("Using Apple Intelligence - no API key needed, fully private!", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Label("Requires macOS 26 or later", systemImage: "xmark.circle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } else if selectedProvider == .ollama {
                    if isOllamaAvailable {
                        Label("Using local Ollama - no API key needed, fully private!", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Label("Ollama is not running", systemImage: "xmark.circle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } else if selectedProvider == .anthropic {
                    if hasEnvKey(for: .anthropic) {
                        Label("Using ANTHROPIC_API_KEY environment variable", systemImage: "terminal")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    } else if isAnthropicKeyConfigured {
                        Label("Using Anthropic API key", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else if isClaudeCodeAvailable {
                        Label("Using local Claude Code CLI - no API key needed!", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Label("Requires an API key or Claude Code", systemImage: "xmark.circle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            // Apple Intelligence section (macOS 26+)
            if isFoundationModelsAvailable {
                Section("Apple Intelligence") {
                    Label("Apple Intelligence available", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Runs entirely on your Mac. No API key required, fully private - your data never leaves your device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Apple Intelligence") {
                    Label("Requires macOS 26+", systemImage: "desktopcomputer")
                        .foregroundStyle(.secondary)
                    Text("Apple Intelligence analysis will be available when you upgrade to macOS 26 or later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Ollama section
            Section("Ollama") {
                if isOllamaAvailable {
                    Label("Ollama running - \(ollamaModels.count) model\(ollamaModels.count == 1 ? "" : "s") installed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)

                    Picker("Model", selection: $selectedOllamaModel) {
                        Text("Auto (best installed)").tag("")
                        ForEach(ollamaModels) { model in
                            Text(model.name).tag(model.name)
                        }
                    }
                    .onChange(of: selectedOllamaModel) { _, newValue in
                        Task {
                            await AIAnalysisService.shared.setOllamaModel(newValue)
                        }
                    }

                    if selectedOllamaModel.isEmpty, let best = bestOllamaModelName {
                        Text("Auto currently picks \(best) - the largest installed model. Bigger models extract more accurately but respond slower.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("Runs entirely on your Mac via the local Ollama server. No API key required, fully private.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Not running", systemImage: "xmark.circle")
                        .foregroundStyle(.secondary)
                    Text("Start the Ollama app (or run 'ollama serve') and pull a model, e.g. 'ollama pull qwen3:32b'.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link("Get Ollama", destination: URL(string: "https://ollama.com")!)
                }
            }

            // Claude section
            Section("Claude") {
                if isClaudeCodeAvailable {
                    Label("Claude Code CLI detected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Uses your existing Claude Code authentication when no API key is set. No API key required.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Add an Anthropic API key, or install Claude Code to use Claude without one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link("Get an Anthropic API key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    Link("Install Claude Code", destination: URL(string: "https://claude.ai/download")!)
                }

                APIKeyInputView(
                    apiKey: $anthropicKey,
                    isConfigured: $isAnthropicKeyConfigured,
                    showingKey: $showingAnthropicKey,
                    provider: .anthropic,
                    isSaving: $isSaving,
                    errorMessage: $errorMessage,
                    successMessage: $successMessage,
                    hasEnvKey: hasEnvKey(for: .anthropic)
                )
            }

            Section("Privacy") {
                Text("API keys are stored in UserDefaults. Document text is only sent when you explicitly tap 'AI Analyze'. Apple Intelligence and Ollama keep everything on your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            await loadSettings()
        }
    }

    private func hasEnvKey(for provider: AIProvider) -> Bool {
        guard let envVar = provider.apiKeyEnvVar else {
            return false  // Local providers don't use env vars
        }
        if let envKey = ProcessInfo.processInfo.environment[envVar],
           !envKey.isEmpty {
            return true
        }
        return false
    }

    private func loadSettings() async {
        isClaudeCodeAvailable = await AIAnalysisService.shared.isClaudeCodeAvailable()
        isFoundationModelsAvailable = await AIAnalysisService.shared.isFoundationModelsAvailable()
        selectedProvider = await AIAnalysisService.shared.getSelectedProvider()
        isAnthropicKeyConfigured = await AIAnalysisService.shared.isAPIKeyConfigured(for: .anthropic)
        selectedOllamaModel = await AIAnalysisService.shared.getOllamaModel()
        ollamaModels = await AIAnalysisService.shared.fetchOllamaModels()
        isOllamaAvailable = !ollamaModels.isEmpty
        // A previously chosen model may have been removed - fall back to auto
        if !selectedOllamaModel.isEmpty && !ollamaModels.contains(where: { $0.name == selectedOllamaModel }) {
            selectedOllamaModel = ""
        }
    }
}

/// Reusable API key input component
private struct APIKeyInputView: View {
    @Binding var apiKey: String
    @Binding var isConfigured: Bool
    @Binding var showingKey: Bool
    let provider: AIProvider
    @Binding var isSaving: Bool
    @Binding var errorMessage: String?
    @Binding var successMessage: String?
    let hasEnvKey: Bool

    var body: some View {
        if hasEnvKey {
            Label("Using environment variable", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            HStack {
                if showingKey {
                    TextField("API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                } else {
                    SecureField("API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                }

                Button {
                    showingKey.toggle()
                } label: {
                    Image(systemName: showingKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
            }

            HStack {
                if isConfigured {
                    Label("Configured", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Not set", systemImage: "xmark.circle")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Save") {
                        saveAPIKey()
                    }
                    .disabled(apiKey.isEmpty)

                    if isConfigured {
                        Button("Remove", role: .destructive) {
                            removeAPIKey()
                        }
                    }
                }
            }
        }
    }

    private func saveAPIKey() {
        isSaving = true
        errorMessage = nil
        successMessage = nil

        Task {
            await AIAnalysisService.shared.saveAPIKey(apiKey, for: provider)
            isConfigured = true
            apiKey = ""
            successMessage = "\(provider.displayName) API key saved"
            isSaving = false
        }
    }

    private func removeAPIKey() {
        Task {
            await AIAnalysisService.shared.deleteAPIKey(for: provider)
            isConfigured = false
            successMessage = "\(provider.displayName) API key removed"
        }
    }
}

// MARK: - Schema Settings

struct SchemaSettingsView: View {
    @State private var showingSchemaEditor = false

    var body: some View {
        Form {
            Section("Invoice Schemas") {
                Text("Schemas define how to extract data from different invoice formats. Create custom schemas for vendors with consistent layouts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    showingSchemaEditor = true
                } label: {
                    Label("Open Schema Editor", systemImage: "rectangle.3.group")
                }
                .buttonStyle(.borderedProminent)
            }

            Section("About Schemas") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Map document regions to fields", systemImage: "square.dashed")
                    Label("Train on multiple examples for accuracy", systemImage: "brain")
                    Label("Auto-match vendors by identifier", systemImage: "person.badge.shield.checkmark")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $showingSchemaEditor) {
            SchemaEditorView()
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}

// MARK: - Advanced Settings

struct AdvancedSettingsView: View {
    @AppStorage("debugMode") private var debugMode = false
    @AppStorage("clearCacheOnQuit") private var clearCacheOnQuit = false

    var body: some View {
        Form {
            Section("Developer") {
                Toggle("Debug Mode", isOn: $debugMode)

                if debugMode {
                    Text("Debug logs will be written to Console.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Document Storage") {
                LabeledContent("Location") {
                    Text(DocumentStorageService.documentsDirectory.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Button("Open in Finder") {
                    try? DocumentStorageService.ensureDirectory()
                    NSWorkspace.shared.open(DocumentStorageService.documentsDirectory)
                }

                Text("Invoice files are copied here on import so they remain accessible even if the originals are moved or deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Cache") {
                Toggle("Clear Cache on Quit", isOn: $clearCacheOnQuit)

                Button("Clear OCR Cache Now") {
                    clearOCRCache()
                }

                Button("Reset All Settings", role: .destructive) {
                    resetAllSettings()
                }
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                LabeledContent("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func clearOCRCache() {
        // Clear any cached OCR data
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        if let cacheDir = cacheDir {
            let ocrCacheDir = cacheDir.appendingPathComponent("OCRCache")
            try? FileManager.default.removeItem(at: ocrCacheDir)
        }
    }

    private func resetAllSettings() {
        let domain = Bundle.main.bundleIdentifier!
        UserDefaults.standard.removePersistentDomain(forName: domain)
    }
}

#Preview {
    SettingsView()
}
