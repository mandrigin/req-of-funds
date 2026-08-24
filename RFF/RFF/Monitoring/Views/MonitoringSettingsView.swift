import SwiftUI
import AppKit

/// Settings tab for the folder-monitoring pipeline (inherited from InvoiceFiler)
struct MonitoringSettingsView: View {
    @ObservedObject private var configManager = ConfigManager.shared
    @ObservedObject private var coordinator = MonitoringCoordinator.shared

    @State private var newCompanyName = ""
    @State private var newCompanyAliases = ""
    @State private var salaryKeywordsText = ""

    // OCR knobs (shared with manual imports)
    @AppStorage("ocrAccuracy") private var ocrAccuracy = "accurate"
    @AppStorage("languageCorrection") private var languageCorrection = true
    @AppStorage("maxConcurrentOCR") private var maxConcurrentOCR = 4

    var body: some View {
        Form {
            Section("Watched Folders") {
                ForEach(configManager.config.monitoredPaths, id: \.path) { monitored in
                    HStack {
                        Text(monitored.path.path).font(.caption)
                        if monitored.recursive {
                            Text("(recursive)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            try? configManager.removeMonitoredPath(at: monitored.path)
                            coordinator.restart()
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                Button {
                    addFolder()
                } label: {
                    Label("Add Folder…", systemImage: "folder.badge.plus")
                }
            }

            Section("Filing") {
                Toggle("Flat archive (app database drives reporting)", isOn: Binding(
                    get: { configManager.config.usesArchiveFiling },
                    set: { enabled in
                        try? configManager.updateConfig { $0.useArchiveFiling = enabled }
                        coordinator.restart()
                    }
                ))

                if configManager.config.usesArchiveFiling {
                    HStack {
                        Text(configManager.config.resolvedArchiveRoot.path).font(.caption)
                        Spacer()
                        Button("Change…") { chooseArchiveRoot() }
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [configManager.config.resolvedArchiveRoot]
                            )
                        }
                    }
                    Text("Processed invoices move here with a nanosecond timestamp appended to the original name. Monthly reports come from the Reporting tab, not folders.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack {
                        if let root = configManager.config.destinationRoot {
                            Text(root.path).font(.caption)
                            Spacer()
                            Button("Clear") {
                                try? configManager.updateConfig { $0.destinationRoot = nil }
                                coordinator.restart()
                            }
                        } else {
                            Text("Same folder as the file (invoices-MM-YYYY subfolder)")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Choose…") { chooseDestinationRoot() }
                        }
                    }
                    Text("Legacy mode: invoices filed into invoices-MM-YYYY folders.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("AI Classification") {
                Toggle("Use Apple Intelligence (primary)", isOn: binding(\.aiClassificationEnabled, default: true))
                Toggle("Ollama second opinion for uncertain documents", isOn: binding(\.ollamaFallbackEnabled, default: true))
                Toggle("Import filed invoices into RFF library", isOn: binding(\.autoImportToRFF, default: true))
                Text("Clear cases are decided by Apple Intelligence on-device. Uncertain ones (\(Int(AIInvoiceClassifier.confidentNo * 100))-\(Int(AIInvoiceClassifier.confidentYes * 100))% confidence) are double-checked with Ollama, and anything still unclear lands in the Confirmation Queue.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Salary Slips") {
                Toggle("Detect salary slips", isOn: Binding(
                    get: { configManager.config.usesSalaryDetection },
                    set: { enabled in
                        try? configManager.updateConfig { $0.salaryDetectionEnabled = enabled }
                        coordinator.restart()
                    }
                ))

                if configManager.config.usesSalaryDetection {
                    TextField("Keywords (comma-separated)", text: $salaryKeywordsText)
                        .onSubmit { saveSalaryKeywords() }
                    Text("Matched case-insensitively against the filename and document text. Matching files skip invoice classification, move to the archive's Salary folder, and go through the normal Inbox flow tagged as salary. A PDF whose pages each read as a payslip becomes one entry per page. Press Return to apply.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("My Companies (invoice recipients)") {
                ForEach(configManager.config.companies, id: \.name) { company in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(company.name)
                            if !company.aliases.isEmpty {
                                Text(company.aliases.joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button(role: .destructive) {
                            try? configManager.removeCompany(named: company.name)
                            coordinator.restart()
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                HStack {
                    TextField("Company name", text: $newCompanyName)
                    TextField("Aliases (comma-separated)", text: $newCompanyAliases)
                    Button("Add") {
                        let aliases = newCompanyAliases
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        try? configManager.addCompany(CompanyConfig(name: newCompanyName, aliases: aliases))
                        newCompanyName = ""
                        newCompanyAliases = ""
                        coordinator.restart()
                    }
                    .disabled(newCompanyName.isEmpty)
                }

                Text("Only documents billed to one of these companies are auto-filed. This keeps random PDFs in Downloads untouched.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Invoice Generation") {
                Toggle("Generate recurring invoice drafts on schedule", isOn: Binding(
                    get: { configManager.config.invoiceSchedulingEnabled },
                    set: { enabled in
                        try? configManager.updateConfig { $0.invoiceSchedulingEnabled = enabled }
                        if enabled {
                            InvoiceScheduler.shared.startScheduler()
                        } else {
                            InvoiceScheduler.shared.stopScheduler()
                        }
                    }
                ))
                Text("Templates and drafts are managed in the Invoices window (menu bar → INVOICES).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("OCR") {
                Picker("Accuracy Level", selection: $ocrAccuracy) {
                    Text("Fast").tag("fast")
                    Text("Accurate").tag("accurate")
                }
                Toggle("Use Language Correction", isOn: $languageCorrection)
                Picker("Concurrent Pages", selection: $maxConcurrentOCR) {
                    Text("2 pages").tag(2)
                    Text("4 pages").tag(4)
                    Text("8 pages").tag(8)
                    Text("16 pages").tag(16)
                }
            }

            Section("Pipeline") {
                LabeledContent("Status") {
                    Text(statusDescription).font(.caption)
                }
                HStack {
                    Button(coordinator.status.isRunning ? "Stop Monitoring" : "Start Monitoring") {
                        coordinator.status.isRunning ? coordinator.stop() : coordinator.start()
                    }
                    Button("Open Log Folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([configManager.config.logLocation])
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            salaryKeywordsText = configManager.config.resolvedSalaryKeywords.joined(separator: ", ")
        }
    }

    private func saveSalaryKeywords() {
        let keywords = salaryKeywordsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        try? configManager.updateConfig { $0.salaryKeywords = keywords.isEmpty ? nil : keywords }
        salaryKeywordsText = configManager.config.resolvedSalaryKeywords.joined(separator: ", ")
        coordinator.restart()
    }

    private var statusDescription: String {
        switch coordinator.status {
        case .stopped: return "Stopped"
        case .idle: return "Watching \(configManager.config.monitoredPaths.count) folder(s)"
        case .processing(let file): return "Processing \(file)"
        case .error(let message): return "Error: \(message)"
        }
    }

    private func binding(_ keyPath: WritableKeyPath<AppConfig, Bool?>, default defaultValue: Bool) -> Binding<Bool> {
        Binding(
            get: { configManager.config[keyPath: keyPath] ?? defaultValue },
            set: { newValue in
                try? configManager.updateConfig { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch Folder"
        if panel.runModal() == .OK, let url = panel.url {
            try? configManager.addMonitoredPath(MonitoredPath(path: url, recursive: false))
            coordinator.restart()
        }
    }

    private func chooseArchiveRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as Archive"
        if panel.runModal() == .OK, let url = panel.url {
            try? configManager.updateConfig { $0.archiveRoot = url }
            coordinator.restart()
        }
    }

    private func chooseDestinationRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as Destination"
        if panel.runModal() == .OK, let url = panel.url {
            try? configManager.updateConfig { $0.destinationRoot = url }
            coordinator.restart()
        }
    }
}
