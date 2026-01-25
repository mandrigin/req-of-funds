import SwiftUI
import SwiftData
import PDFKit

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var documents: [RFFDocument]
    @State private var isImportingPDF = false
    @State private var importError: String?
    @State private var showingImportError = false

    private let pdfService = PDFService()

    var body: some View {
        NavigationSplitView {
            List {
                ForEach(documents) { document in
                    NavigationLink {
                        DocumentDetailView(document: document)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(document.title)
                                .font(.headline)
                            Text(document.requestingOrganization)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete(perform: deleteDocuments)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 250)
            .toolbar {
                ToolbarItem {
                    Button(action: { isImportingPDF = true }) {
                        Label("Import PDF", systemImage: "doc.badge.plus")
                    }
                }
                ToolbarItem {
                    Button(action: addDocument) {
                        Label("Add Document", systemImage: "plus")
                    }
                }
            }
        } detail: {
            Text("Select a document")
        }
        .fileImporter(
            isPresented: $isImportingPDF,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            handlePDFImport(result)
        }
        .alert("Import Error", isPresented: $showingImportError) {
            Button("OK") { }
        } message: {
            Text(importError ?? "Unknown error")
        }
    }

    private func handlePDFImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            // Start accessing security-scoped resource
            guard url.startAccessingSecurityScopedResource() else {
                importError = "Unable to access the selected file."
                showingImportError = true
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let extractionResult = try pdfService.extractContent(from: url)

                withAnimation {
                    let newDocument = RFFDocument(
                        title: extractionResult.title ?? url.deletingPathExtension().lastPathComponent,
                        requestingOrganization: extractionResult.author ?? "Unknown",
                        amount: Decimal(0),
                        dueDate: Date().addingTimeInterval(30 * 24 * 60 * 60),
                        extractedText: extractionResult.text,
                        documentPath: url.path
                    )
                    modelContext.insert(newDocument)
                }
            } catch {
                importError = error.localizedDescription
                showingImportError = true
            }

        case .failure(let error):
            importError = error.localizedDescription
            showingImportError = true
        }
    }

    private func addDocument() {
        withAnimation {
            let newDocument = RFFDocument(
                title: "New Document",
                requestingOrganization: "Organization",
                amount: Decimal(0),
                dueDate: Date().addingTimeInterval(7 * 24 * 60 * 60)
            )
            modelContext.insert(newDocument)

            // Schedule deadline notification
            Task {
                try? await NotificationService.shared.scheduleDeadlineNotification(
                    documentId: newDocument.id,
                    title: newDocument.title,
                    organization: newDocument.requestingOrganization,
                    dueDate: newDocument.dueDate
                )
            }
        }
    }

    private func deleteDocuments(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                let document = documents[index]
                // Cancel any scheduled notifications
                Task {
                    await NotificationService.shared.cancelNotification(for: document.id)
                }
                modelContext.delete(document)
            }
        }
    }
}

struct DocumentDetailView: View {
    let document: RFFDocument
    @State private var selectedTab = 0
    @State private var pdfDocument: PDFDocument?
    @State private var highlights: [HighlightRegion] = []

    private let textFinder = PDFTextFinder()

    var body: some View {
        TabView(selection: $selectedTab) {
            // Info Tab
            Form {
                Section("Document Info") {
                    LabeledContent("Title", value: document.title)
                    LabeledContent("Organization", value: document.requestingOrganization)
                    LabeledContent("Amount", value: document.amount, format: .currency(code: "USD"))
                    LabeledContent("Due Date", value: document.dueDate, format: .dateTime)
                    LabeledContent("Status", value: document.status.rawValue.capitalized)
                }

                if let extractedText = document.extractedText, !extractedText.isEmpty {
                    Section("Extracted Text") {
                        ScrollView {
                            Text(extractedText)
                                .font(.body)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 300)
                    }
                }

                Section("Line Items") {
                    if document.lineItems.isEmpty {
                        Text("No line items")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(document.lineItems) { item in
                            HStack {
                                Text(item.itemDescription)
                                Spacer()
                                Text(item.total, format: .currency(code: "USD"))
                            }
                        }
                    }
                }
            }
            .padding()
            .tabItem {
                Label("Info", systemImage: "info.circle")
            }
            .tag(0)

            // PDF Viewer Tab
            if document.documentPath != nil {
                VStack {
                    HStack {
                        Button("Highlight Amounts") {
                            highlightAmounts()
                        }
                        Button("Highlight Dates") {
                            highlightDates()
                        }
                        Button("Clear Highlights") {
                            highlights = []
                        }
                    }
                    .padding(.horizontal)

                    PDFViewer(document: pdfDocument, highlights: highlights)
                }
                .tabItem {
                    Label("PDF", systemImage: "doc.richtext")
                }
                .tag(1)
            }
        }
        .navigationTitle(document.title)
        .onAppear {
            loadPDF()
        }
    }

    private func loadPDF() {
        guard let path = document.documentPath else { return }
        let url = URL(fileURLWithPath: path)
        pdfDocument = PDFDocument(url: url)
    }

    private func highlightAmounts() {
        guard let pdf = pdfDocument else { return }
        let matches = textFinder.findAmounts(in: pdf)
        highlights = matches.map { match in
            HighlightRegion(
                pageIndex: match.pageIndex,
                bounds: match.bounds,
                color: NSColor.green.withAlphaComponent(0.3),
                label: match.text
            )
        }
    }

    private func highlightDates() {
        guard let pdf = pdfDocument else { return }
        let matches = textFinder.findDates(in: pdf)
        highlights = matches.map { match in
            HighlightRegion(
                pageIndex: match.pageIndex,
                bounds: match.bounds,
                color: NSColor.blue.withAlphaComponent(0.3),
                label: match.text
            )
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: RFFDocument.self, inMemory: true)
}
