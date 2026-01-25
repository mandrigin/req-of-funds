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

            AdvancedSettingsView()
                .tabItem {
                    Label("Advanced", systemImage: "gearshape.2")
                }
        }
        .frame(width: 500, height: 400)
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
