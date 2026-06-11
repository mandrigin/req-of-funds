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
        WindowGroup("RFF", id: "library") {
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

        // Settings scene
        Settings {
            SettingsView()
        }
    }

    private func openLibraryWindow() {
        if let window = NSApp.windows.first(where: { $0.title == "RFF" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // Open new library window
            NSApp.sendAction(Selector(("newWindowForTab:")), to: nil, from: nil)
        }
    }
}

/// "Go" menu in the main menu bar: every section of the one window, one keystroke away
struct RFFGoCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    private func go(_ section: DocumentFilter) {
        openWindow(id: "library")
        NotificationCenter.default.post(name: .rffOpenSection, object: section.rawValue)
    }

    var body: some Commands {
        CommandMenu("Go") {
            Button("Inbox") { go(.inbox) }
                .keyboardShortcut("1", modifiers: .command)
            Button("Confirmed") { go(.confirmed) }
                .keyboardShortcut("2", modifiers: .command)
            Button("Paid") { go(.paid) }
                .keyboardShortcut("3", modifiers: .command)
            Button("Review") { go(.review) }
                .keyboardShortcut("4", modifiers: .command)
            Button("Drafts") { go(.drafts) }
                .keyboardShortcut("5", modifiers: .command)
            Button("Reporting") { go(.reporting) }
                .keyboardShortcut("6", modifiers: .command)

            Divider()

            Button("Archive Folder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [ConfigManager.shared.config.resolvedArchiveRoot]
                )
            }
            .keyboardShortcut("7", modifiers: .command)
        }
    }
}
