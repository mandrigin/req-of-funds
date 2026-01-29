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
            CommandGroup(after: .newItem) {
                Button("Open Library") {
                    openLibraryWindow()
                }
                .keyboardShortcut("L", modifiers: [.command, .shift])
            }
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
