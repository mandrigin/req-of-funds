import SwiftUI
import SwiftData

@main
struct RFFApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            RFFDocument.self,
            LineItem.self
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )

        do {
            return try ModelContainer(
                for: schema,
                configurations: [modelConfiguration]
            )
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    init() {
        // Boot the invoice monitoring pipeline (inherited from InvoiceFiler)
        MonitoringCoordinator.shared.configure(modelContainer: sharedModelContainer)
        MonitoringCoordinator.shared.start()

        if ConfigManager.shared.config.invoiceSchedulingEnabled {
            InvoiceScheduler.shared.startScheduler()
        }
        // The every-12th accountant reminder is scheduled by the coordinator
        // with live report counts (see MonitoringCoordinator.refreshStats)
    }

    var body: some Scene {
        // Library window for browsing all documents in SwiftData (primary window)
        WindowGroup("RFF Library", id: "library") {
            ContentView()
                .onAppear {
                    appDelegate.modelContainer = sharedModelContainer
                }
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 1100, height: 700)
        .windowResizability(.contentMinSize)
        .commands {
            RFFGoCommands()
        }

        // Document-based scene for RFF files
        DocumentGroup(newDocument: RFFFileDocument()) { file in
            DocumentEditorView(document: file.$document)
                .frame(minWidth: 800, minHeight: 600)
                .onAppear {
                    appDelegate.modelContainer = sharedModelContainer
                }
        }
        .modelContainer(sharedModelContainer)

        // Always-visible dense dashboard in the menu bar
        MenuBarExtra {
            MenuBarDashboardView()
        } label: {
            MenuBarBadgeLabel()
        }
        .menuBarExtraStyle(.window)

        // Manual review: documents the AI cascade couldn't confidently classify
        WindowGroup("Needs Review", id: "review-queue") {
            ReviewQueueView()
                .frame(minWidth: 700, minHeight: 450)
        }
        .defaultSize(width: 850, height: 550)

        // Outbound invoices: templates, drafts, scheduling (inherited from InvoiceFiler)
        WindowGroup("Outbound Invoices", id: "invoicing") {
            InvoicingView()
        }

        // Settings scene
        Settings {
            SettingsView()
        }
    }

    private func openLibraryWindow() {
        if let window = NSApp.windows.first(where: { $0.title == "RFF Library" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // Open new library window
            NSApp.sendAction(Selector(("newWindowForTab:")), to: nil, from: nil)
        }
    }
}

/// "Go" menu in the main menu bar: every part of the app, one keystroke away
struct RFFGoCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Go") {
            Button("Library") {
                openWindow(id: "library")
            }
            .keyboardShortcut("1", modifiers: .command)

            Button("Needs Review") {
                openWindow(id: "review-queue")
            }
            .keyboardShortcut("2", modifiers: .command)

            Button("Outbound Invoices") {
                openWindow(id: "invoicing")
            }
            .keyboardShortcut("3", modifiers: .command)

            Button("Reporting") {
                openWindow(id: "library")
                NotificationCenter.default.post(name: .rffOpenReporting, object: nil)
            }
            .keyboardShortcut("4", modifiers: .command)

            Divider()

            Button("Current Archive Folder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [ConfigManager.shared.config.resolvedArchiveRoot]
                )
            }
            .keyboardShortcut("5", modifiers: .command)
        }
    }
}
