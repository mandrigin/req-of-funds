import SwiftUI
import SwiftData
import PDFKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RFFDocument.dueDate) private var documents: [RFFDocument]
    @State private var isImportingPDF = false
    @State private var importError: String?
    @State private var showingImportError = false
    @State private var selectedDocuments: Set<RFFDocument.ID> = []
    @State private var selectedDocument: RFFDocument?
    @State private var sortOrder = [KeyPathComparator(\RFFDocument.dueDate)]
    @State private var isProcessingDrop = false

    private let pdfService = PDFService()
    private let ocrService = DocumentOCRService()
    private let entityService = EntityExtractionService()

    var body: some View {
        NavigationSplitView {
            // Table view with columns
            Table(documents, selection: $selectedDocuments, sortOrder: $sortOrder) {
                TableColumn("Title", value: \.title) { document in
                    Text(document.title)
                        .fontWeight(.medium)
                }
                .width(min: 150, ideal: 200)

                TableColumn("Organization", value: \.requestingOrganization) { document in
                    Text(document.requestingOrganization)
                }
                .width(min: 120, ideal: 180)

                TableColumn("Amount") { document in
                    Text(document.amount, format: .currency(code: "USD"))
                        .monospacedDigit()
                }
                .width(100)

                TableColumn("Due Date", value: \.dueDate) { document in
                    HStack {
                        Text(document.dueDate, format: .dateTime.month().day().year())
                        if document.dueDate < Date() && document.status != .completed {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }
                .width(120)

                TableColumn("Status") { document in
                    StatusBadge(status: document.status)
                }
                .width(100)
            }
            .onChange(of: sortOrder) { _, newOrder in
                // Sorting is handled by the Table
            }
            .onDrop(of: [.pdf], isTargeted: nil) { providers in
                handlePDFDrop(providers: providers)
                return true
            }
            .overlay {
                if isProcessingDrop {
                    ZStack {
                        Color.black.opacity(0.3)
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.5)
                            Text("Processing invoice...")
                                .font(.headline)
                        }
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .onChange(of: selectedDocuments) { _, newSelection in
                if let first = newSelection.first {
                    selectedDocument = documents.first { $0.id == first }
                } else {
                    selectedDocument = nil
                }
            }
            .contextMenu(forSelectionType: RFFDocument.ID.self) { ids in
                if !ids.isEmpty {
                    Button(role: .destructive) {
                        deleteDocuments(ids: ids)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            } primaryAction: { ids in
                // Double-click to open
                if let id = ids.first, let doc = documents.first(where: { $0.id == id }) {
                    selectedDocument = doc
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(action: { isImportingPDF = true }) {
                        Label("Import PDF", systemImage: "doc.badge.plus")
                    }
                    Button(action: addDocument) {
                        Label("Add Document", systemImage: "plus")
                    }
                }

                ToolbarItemGroup(placement: .secondaryAction) {
                    if !selectedDocuments.isEmpty {
                        Button(role: .destructive) {
                            deleteDocuments(ids: selectedDocuments)
                        } label: {
                            Label("Delete Selected", systemImage: "trash")
                        }
                    }
                }
            }
        } detail: {
            if let document = selectedDocument {
                DocumentDetailView(document: document)
            } else {
                ContentUnavailableView(
                    "No Document Selected",
                    systemImage: "doc.text",
                    description: Text("Select a document from the library to view details")
                )
            }
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

            isProcessingDrop = true

            // Copy to persistent location while we have access
            let tempCopy = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("pdf")

            do {
                try FileManager.default.copyItem(at: url, to: tempCopy)
            } catch {
                url.stopAccessingSecurityScopedResource()
                importError = "Failed to access file: \(error.localizedDescription)"
                showingImportError = true
                isProcessingDrop = false
                return
            }

            url.stopAccessingSecurityScopedResource()

            Task {
                await processDroppedPDF(at: tempCopy)
            }

        case .failure(let error):
            importError = error.localizedDescription
            showingImportError = true
        }
    }

    private func handlePDFDrop(providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }

        isProcessingDrop = true

        provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { url, error in
            defer { DispatchQueue.main.async { isProcessingDrop = false } }

            guard let url = url else {
                if let error = error {
                    DispatchQueue.main.async {
                        importError = error.localizedDescription
                        showingImportError = true
                    }
                }
                return
            }

            // Copy to a persistent location since the provided URL is temporary
            let tempCopy = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("pdf")

            do {
                try FileManager.default.copyItem(at: url, to: tempCopy)
            } catch {
                DispatchQueue.main.async {
                    importError = "Failed to access dropped file: \(error.localizedDescription)"
                    showingImportError = true
                }
                return
            }

            Task {
                await processDroppedPDF(at: tempCopy)
            }
        }
    }

    private func processDroppedPDF(at url: URL) async {
        do {
            // Step 1: Run OCR on the PDF
            let ocrResult = try await ocrService.processDocument(at: url)

            // Step 2: Extract entities (org, amount, due date)
            let entities = try await entityService.extractEntities(from: ocrResult)

            // Step 3: Create RFFDocument with extracted data
            await MainActor.run {
                withAnimation {
                    let newDocument = RFFDocument(
                        title: generateTitle(from: entities, url: url),
                        requestingOrganization: entities.organizationName ?? "Unknown Organization",
                        amount: entities.amount ?? Decimal(0),
                        dueDate: entities.dueDate ?? Date().addingTimeInterval(30 * 24 * 60 * 60),
                        extractedText: ocrResult.fullText,
                        documentPath: url.path
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
                isProcessingDrop = false
            }
        } catch {
            await MainActor.run {
                importError = "Failed to process invoice: \(error.localizedDescription)"
                showingImportError = true
                isProcessingDrop = false
            }
        }
    }

    private func generateTitle(from entities: ExtractedEntities, url: URL) -> String {
        let baseName = url.deletingPathExtension().lastPathComponent

        if let org = entities.organizationName, let amount = entities.amount {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = "USD"
            let amountStr = formatter.string(from: amount as NSDecimalNumber) ?? "\(amount)"
            return "\(org) - \(amountStr)"
        } else if let org = entities.organizationName {
            return "RFF - \(org)"
        } else {
            return baseName
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
                Task {
                    await NotificationService.shared.cancelNotification(for: document.id)
                }
                modelContext.delete(document)
            }
        }
    }

    private func deleteDocuments(ids: Set<RFFDocument.ID>) {
        withAnimation {
            for id in ids {
                if let document = documents.first(where: { $0.id == id }) {
                    Task {
                        await NotificationService.shared.cancelNotification(for: document.id)
                    }
                    modelContext.delete(document)
                }
            }
            selectedDocuments.removeAll()
            selectedDocument = nil
        }
    }
}

// MARK: - Status Badge

struct StatusBadge: View {
    let status: RFFStatus

    var body: some View {
        Text(status.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(backgroundColor, in: Capsule())
            .foregroundStyle(foregroundColor)
    }

    private var backgroundColor: Color {
        switch status {
        case .pending:
            return .gray.opacity(0.2)
        case .underReview:
            return .blue.opacity(0.2)
        case .approved:
            return .green.opacity(0.2)
        case .rejected:
            return .red.opacity(0.2)
        case .completed:
            return .purple.opacity(0.2)
        }
    }

    private var foregroundColor: Color {
        switch status {
        case .pending:
            return .gray
        case .underReview:
            return .blue
        case .approved:
            return .green
        case .rejected:
            return .red
        case .completed:
            return .purple
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
