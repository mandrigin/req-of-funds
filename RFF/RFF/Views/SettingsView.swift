import SwiftUI

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

            OCRSettingsView()
                .tabItem {
                    Label("OCR", systemImage: "doc.text.viewfinder")
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
        .frame(width: 500, height: 450)
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @AppStorage("defaultDueDateDays") private var defaultDueDateDays = 7
    @AppStorage("defaultCurrency") private var defaultCurrency = "USD"
    @AppStorage("autoSaveEnabled") private var autoSaveEnabled = true
    @AppStorage("autoSaveInterval") private var autoSaveInterval = 30

    var body: some View {
        Form {
            Section("Defaults") {
                Picker("Default Due Date", selection: $defaultDueDateDays) {
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("30 days").tag(30)
                    Text("60 days").tag(60)
                    Text("90 days").tag(90)
                }

                Picker("Currency", selection: $defaultCurrency) {
                    Text("USD ($)").tag("USD")
                    Text("EUR (€)").tag("EUR")
                    Text("GBP (£)").tag("GBP")
                    Text("JPY (¥)").tag("JPY")
                    Text("CAD (C$)").tag("CAD")
                }
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
    @State private var openAIKey = ""
    @State private var anthropicKey = ""
    @State private var isOpenAIKeyConfigured = false
    @State private var isAnthropicKeyConfigured = false
    @State private var showingOpenAIKey = false
    @State private var showingAnthropicKey = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    var body: some View {
        Form {
            Section("AI Provider") {
                Picker("Provider", selection: $selectedProvider) {
                    ForEach(AIProvider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: selectedProvider) { _, newValue in
                    Task {
                        await AIAnalysisService.shared.setSelectedProvider(newValue)
                    }
                }

                if hasEnvKey(for: selectedProvider) {
                    Label("Using \(selectedProvider.apiKeyEnvVar) environment variable", systemImage: "terminal")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }

            Section("Anthropic API Key") {
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

            Section("OpenAI API Key") {
                APIKeyInputView(
                    apiKey: $openAIKey,
                    isConfigured: $isOpenAIKeyConfigured,
                    showingKey: $showingOpenAIKey,
                    provider: .openai,
                    isSaving: $isSaving,
                    errorMessage: $errorMessage,
                    successMessage: $successMessage,
                    hasEnvKey: hasEnvKey(for: .openai)
                )
            }

            Section("Privacy") {
                Text("API keys are stored in UserDefaults. Document text is only sent when you explicitly tap 'AI Analyze'.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Links") {
                Link("Get an Anthropic API key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                Link("Get an OpenAI API key", destination: URL(string: "https://platform.openai.com/api-keys")!)

                Text("Anthropic uses Claude Sonnet, OpenAI uses GPT-4o-mini.")
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
        if let envKey = ProcessInfo.processInfo.environment[provider.apiKeyEnvVar],
           !envKey.isEmpty {
            return true
        }
        return false
    }

    private func loadSettings() async {
        selectedProvider = await AIAnalysisService.shared.getSelectedProvider()
        isOpenAIKeyConfigured = await AIAnalysisService.shared.isAPIKeyConfigured(for: .openai)
        isAnthropicKeyConfigured = await AIAnalysisService.shared.isAPIKeyConfigured(for: .anthropic)
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

            Section("Storage") {
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
