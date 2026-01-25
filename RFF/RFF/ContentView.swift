import SwiftUI
import SwiftData
import PDFKit
import AppKit
import UniformTypeIdentifiers

/// Filter for document list: Inbox (pending/underReview) vs Confirmed (approved/completed)
enum DocumentFilter: String, CaseIterable {
    case inbox = "Inbox"
    case confirmed = "Confirmed"
}

/// Currency filter for document list
enum CurrencyFilter: Hashable {
    case all
    case specific(Currency)

    var displayName: String {
        switch self {
        case .all:
            return "All Currencies"
        case .specific(let currency):
            return currency.displayName
        }
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext

    // All documents (for filtering)
    @Query(sort: \RFFDocument.dueDate) private var allDocuments: [RFFDocument]

    // Inbox: pending and underReview documents
    private var inboxDocuments: [RFFDocument] {
        allDocuments.filter { $0.status == .pending || $0.status == .underReview }
    }

    // Confirmed: approved and completed documents
    private var confirmedDocuments: [RFFDocument] {
        allDocuments.filter { $0.status == .approved || $0.status == .completed }
    }

    @State private var selectedFilter: DocumentFilter = .inbox
    @State private var selectedCurrencyFilter: CurrencyFilter = .all

    /// Documents to display based on current filters
    private var documents: [RFFDocument] {
        let statusFiltered: [RFFDocument]
        switch selectedFilter {
        case .inbox:
            statusFiltered = inboxDocuments
        case .confirmed:
            statusFiltered = confirmedDocuments
        }

        // Apply currency filter
        switch selectedCurrencyFilter {
        case .all:
            return statusFiltered
        case .specific(let currency):
            return statusFiltered.filter { $0.currency == currency }
        }
    }

    /// Available currencies in the current document set (for filter menu)
    private var availableCurrencies: [Currency] {
        let statusFiltered: [RFFDocument]
        switch selectedFilter {
        case .inbox:
            statusFiltered = inboxDocuments
        case .confirmed:
            statusFiltered = confirmedDocuments
        }
        let currencies = Set(statusFiltered.map { $0.currency })
        return Currency.allCases.filter { currencies.contains($0) }
    }
    @State private var isImportingPDF = false
    @State private var importError: String?
    @State private var showingImportError = false
    @State private var selectedDocuments: Set<RFFDocument.ID> = []
    @State private var selectedDocument: RFFDocument?
    @State private var sortOrder = [KeyPathComparator(\RFFDocument.dueDate)]
    @State private var isProcessingPaste = false
    @State private var isProcessingDrop = false

    // Paste preview state
    @State private var showingPastePreview = false
    @State private var pastedImageData: Data?
    @State private var pastedOCRResult: OCRPageResult?
    @State private var pastedExtractedData: ExtractedData?
    @State private var pastedEntities: ExtractedEntities?

    private let pdfService = PDFService()
    private let amountDateService = AmountDateExtractionService()
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
                    Text(document.amount, format: .currency(code: document.currency.currencyCode))
                        .monospacedDigit()
                }
                .width(100)

                TableColumn("Currency") { document in
                    Text(document.currency.rawValue)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(currencyColor(for: document.currency).opacity(0.2), in: Capsule())
                }
                .width(60)

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
                } else if documents.isEmpty {
                    ContentUnavailableView {
                        Label(
                            selectedFilter == .inbox ? "No Pending Documents" : "No Confirmed Documents",
                            systemImage: selectedFilter == .inbox ? "tray" : "checkmark.circle"
                        )
                    } description: {
                        Text(selectedFilter == .inbox
                            ? "Documents pending review will appear here."
                            : "Approved and completed documents will appear here.")
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
            .onChange(of: selectedFilter) { _, _ in
                // Clear selection when switching filters
                selectedDocuments.removeAll()
                selectedDocument = nil
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
                ToolbarItemGroup(placement: .navigation) {
                    Picker("Filter", selection: $selectedFilter) {
                        ForEach(DocumentFilter.allCases, id: \.self) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)

                    // Currency filter menu
                    Menu {
                        Button {
                            selectedCurrencyFilter = .all
                        } label: {
                            if case .all = selectedCurrencyFilter {
                                Label("All Currencies", systemImage: "checkmark")
                            } else {
                                Text("All Currencies")
                            }
                        }

                        Divider()

                        ForEach(Currency.allCases) { currency in
                            Button {
                                selectedCurrencyFilter = .specific(currency)
                            } label: {
                                if case .specific(let selected) = selectedCurrencyFilter, selected == currency {
                                    Label("\(currency.symbol) \(currency.displayName)", systemImage: "checkmark")
                                } else {
                                    Text("\(currency.symbol) \(currency.displayName)")
                                }
                            }
                        }
                    } label: {
                        Label(currencyFilterLabel, systemImage: "dollarsign.circle")
                    }
                }

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
        .onPasteCommand(of: [.png, .jpeg, .tiff]) { providers in
            handleImagePaste(providers: providers)
        }
        .overlay {
            if isProcessingPaste {
                ZStack {
                    Color.black.opacity(0.3)
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Processing pasted image...")
                            .font(.headline)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openLibrary)) { _ in
            // Bring the library window to front when notification is received
            if let window = NSApp.windows.first(where: { $0.title == "RFF Library" }) {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .sheet(isPresented: $showingPastePreview) {
            if let imageData = pastedImageData,
               let ocrResult = pastedOCRResult,
               let extractedData = pastedExtractedData,
               let entities = pastedEntities {
                PastePreviewSheet(
                    imageData: imageData,
                    ocrResult: ocrResult,
                    extractedData: extractedData,
                    entities: entities
                ) { confirmedEntities in
                    // Create document with confirmed data
                    withAnimation {
                        let newDocument = RFFDocument(
                            title: generateTitle(from: confirmedEntities),
                            requestingOrganization: confirmedEntities.organizationName ?? "Unknown",
                            amount: confirmedEntities.amount ?? Decimal(0),
                            currency: confirmedEntities.currency ?? .usd,
                            dueDate: confirmedEntities.dueDate ?? Date().addingTimeInterval(30 * 24 * 60 * 60),
                            extractedText: ocrResult.fullText
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

                    // Clear paste state
                    pastedImageData = nil
                    pastedOCRResult = nil
                    pastedExtractedData = nil
                    pastedEntities = nil
                }
            }
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
                        currency: entities.currency ?? .usd,
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
            formatter.currencyCode = entities.currency?.currencyCode ?? "USD"
            let amountStr = formatter.string(from: amount as NSDecimalNumber) ?? "\(amount)"
            return "\(org) - \(amountStr)"
        } else if let org = entities.organizationName {
            return "RFF - \(org)"
        } else {
            return baseName
        }
    }

    private var currencyFilterLabel: String {
        switch selectedCurrencyFilter {
        case .all:
            return "All"
        case .specific(let currency):
            return currency.symbol
        }
    }

    private func currencyColor(for currency: Currency) -> Color {
        switch currency {
        case .usd:
            return .green
        case .eur:
            return .blue
        case .gbp:
            return .purple
        case .chf:
            return .red
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

    // MARK: - Clipboard Paste Support

    private func handleImagePaste(providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }

        isProcessingPaste = true

        // Try to load image data from the provider
        let imageTypes: [UTType] = [.png, .jpeg, .tiff]

        for imageType in imageTypes {
            if provider.hasItemConformingToTypeIdentifier(imageType.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: imageType.identifier) { data, error in
                    Task { @MainActor in
                        if let data = data {
                            await processClipboardImage(data: data)
                        } else {
                            isProcessingPaste = false
                            importError = error?.localizedDescription ?? "Failed to load image from clipboard"
                            showingImportError = true
                        }
                    }
                }
                return
            }
        }

        isProcessingPaste = false
        importError = "No supported image found in clipboard"
        showingImportError = true
    }

    @MainActor
    private func processClipboardImage(data: Data) async {
        do {
            // Run OCR on the pasted image
            let ocrResult = try await ocrService.processImageData(data)

            guard !ocrResult.isEmpty else {
                isProcessingPaste = false
                importError = "No text found in the pasted image"
                showingImportError = true
                return
            }

            // Extract entities from OCR text
            let entities = try await entityService.extractEntities(from: ocrResult.fullText)

            // Extract amounts and dates with bounding boxes for highlighting
            let extractedData = await amountDateService.extract(from: ocrResult)

            // Store data for preview sheet
            pastedImageData = data
            pastedOCRResult = ocrResult
            pastedExtractedData = extractedData
            pastedEntities = entities

            isProcessingPaste = false

            // Show preview sheet
            showingPastePreview = true

        } catch {
            isProcessingPaste = false
            importError = error.localizedDescription
            showingImportError = true
        }
    }

    private func generateTitle(from entities: ExtractedEntities) -> String {
        if let org = entities.organizationName, let amount = entities.amount {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = entities.currency?.currencyCode ?? "USD"
            let amountStr = formatter.string(from: amount as NSDecimalNumber) ?? "\(amount)"
            return "RFF - \(org) - \(amountStr)"
        } else if let org = entities.organizationName {
            return "RFF - \(org)"
        } else {
            return "RFF - Pasted Invoice"
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
    @Bindable var document: RFFDocument
    @Environment(\.modelContext) private var modelContext
    @State private var selectedTab = 0
    @State private var pdfDocument: PDFDocument?
    @State private var highlights: [HighlightRegion] = []
    @State private var showConfirmationPanel = true
    @State private var showingConfirmationAlert = false
    @State private var showingValidationError = false
    @State private var validationErrors: [String] = []

    // AI Analysis state
    @State private var isAnalyzingWithAI = false
    @State private var showingAIResults = false
    @State private var aiAnalysisResult: AIAnalysisResult?
    @State private var aiErrorMessage: String?
    @State private var showingAIError = false

    // Schema editing state
    @State private var isEditingSchema = false

    private let textFinder = PDFTextFinder()

    /// Check if document can be confirmed (is in inbox state)
    private var canConfirm: Bool {
        document.status == .pending || document.status == .underReview
    }

    /// Validate document fields before confirmation
    private func validateForConfirmation() -> [String] {
        var errors: [String] = []

        if document.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Title is required")
        }

        if document.requestingOrganization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Organization is required")
        }

        if document.amount <= 0 {
            errors.append("Amount must be greater than zero")
        }

        return errors
    }

    /// Confirm the document: validate, store confirmed values, transition status
    private func confirmDocument() {
        let errors = validateForConfirmation()

        if !errors.isEmpty {
            validationErrors = errors
            showingValidationError = true
            return
        }

        // Store confirmed values
        document.confirmedOrganization = document.requestingOrganization
        document.confirmedAmount = document.amount
        document.confirmedDueDate = document.dueDate
        document.confirmedAt = Date()

        // Transition status to approved
        document.status = .approved
        document.updatedAt = Date()

        // Post notification for UI updates
        NotificationCenter.default.post(
            name: .documentStatusChanged,
            object: nil,
            userInfo: ["documentId": document.id, "status": RFFStatus.approved]
        )
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            // Info Tab
            Form {
                Section("Document Info") {
                    LabeledContent("Title", value: document.title)
                    LabeledContent("Organization", value: document.requestingOrganization)
                    LabeledContent("Amount", value: document.amount, format: .currency(code: document.currency.currencyCode))
                    LabeledContent("Currency", value: "\(document.currency.symbol) \(document.currency.displayName)")
                    LabeledContent("Due Date", value: document.dueDate, format: .dateTime)
                    LabeledContent("Status") {
                        StatusBadge(status: document.status)
                    }
                }

                // Show confirmed values section for approved documents
                if let confirmedAt = document.confirmedAt {
                    Section("Confirmed Values") {
                        if let confirmedOrg = document.confirmedOrganization {
                            LabeledContent("Organization", value: confirmedOrg)
                        }
                        if let confirmedAmount = document.confirmedAmount {
                            LabeledContent("Amount", value: confirmedAmount, format: .currency(code: "USD"))
                        }
                        if let confirmedDate = document.confirmedDueDate {
                            LabeledContent("Due Date", value: confirmedDate, format: .dateTime)
                        }
                        LabeledContent("Confirmed At", value: confirmedAt, format: .dateTime)
                    }
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
                                Text(item.total, format: .currency(code: document.currency.currencyCode))
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

            // Review & Confirm Tab - DocuSign-style split view
            if document.documentPath != nil {
                Group {
                    if isEditingSchema {
                        // Inline schema editor mode
                        InlineSchemaEditorView(
                            document: document,
                            isEditing: $isEditingSchema
                        )
                    } else {
                        // Normal review mode
                        HSplitView {
                            // Left: PDF Viewer with highlight controls
                            VStack(spacing: 0) {
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

                                    Divider()
                                        .frame(height: 20)

                                    Button {
                                        performAIAnalysis()
                                    } label: {
                                        if isAnalyzingWithAI {
                                            ProgressView()
                                                .controlSize(.small)
                                        } else {
                                            Label("AI Analyze", systemImage: "sparkles")
                                        }
                                    }
                                    .disabled(isAnalyzingWithAI || (document.extractedText ?? "").isEmpty)

                                    Button {
                                        withAnimation {
                                            isEditingSchema = true
                                        }
                                    } label: {
                                        Label("Edit Schema", systemImage: "rectangle.and.pencil.and.ellipsis")
                                    }
                                    .help("Visually map document fields to schema")

                                    Spacer()
                                    Button {
                                        withAnimation {
                                            showConfirmationPanel.toggle()
                                        }
                                    } label: {
                                        Label(
                                            showConfirmationPanel ? "Hide Form" : "Show Form",
                                            systemImage: showConfirmationPanel ? "sidebar.trailing" : "sidebar.leading"
                                        )
                                    }
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 8)

                                Divider()

                                PDFViewer(document: pdfDocument, highlights: highlights)
                            }
                            .frame(minWidth: 400)

                            // Right: Confirmation form panel
                            if showConfirmationPanel {
                                ConfirmationFormView(document: document)
                            }
                        }
                    }
                }
                .tabItem {
                    Label("Review & Confirm", systemImage: "checkmark.rectangle")
                }
                .tag(1)
            } else {
                // No PDF - show confirmation form only
                ConfirmationFormView(document: document)
                    .tabItem {
                        Label("Confirm", systemImage: "checkmark.rectangle")
                    }
                    .tag(1)
            }
        }
        .navigationTitle(document.title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if canConfirm {
                    Button {
                        showingConfirmationAlert = true
                    } label: {
                        Label("Confirm", systemImage: "checkmark.seal.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
            }
        }
        .alert("Confirm Document", isPresented: $showingConfirmationAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Confirm", role: .none) {
                confirmDocument()
            }
        } message: {
            Text("Approve this document? This will lock the current values as the confirmed values and move it to the Confirmed tab.")
        }
        .alert("Validation Error", isPresented: $showingValidationError) {
            Button("OK") { }
        } message: {
            Text(validationErrors.joined(separator: "\n"))
        }
        .alert("AI Analysis Error", isPresented: $showingAIError) {
            Button("OK") { }
        } message: {
            Text(aiErrorMessage ?? "Unknown error")
        }
        .sheet(isPresented: $showingAIResults) {
            if let result = aiAnalysisResult {
                LibraryAIAnalysisResultSheet(
                    result: result,
                    document: document,
                    onDismiss: { showingAIResults = false }
                )
            }
        }
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

    private func performAIAnalysis() {
        guard let extractedText = document.extractedText, !extractedText.isEmpty else {
            aiErrorMessage = "No extracted text available. Import a document first."
            showingAIError = true
            return
        }

        isAnalyzingWithAI = true

        Task {
            do {
                let result = try await AIAnalysisService.shared.analyzeDocument(text: extractedText)
                await MainActor.run {
                    aiAnalysisResult = result
                    showingAIResults = true
                    isAnalyzingWithAI = false
                }
            } catch {
                await MainActor.run {
                    aiErrorMessage = error.localizedDescription
                    showingAIError = true
                    isAnalyzingWithAI = false
                }
            }
        }
    }
}

// MARK: - Paste Preview Sheet

/// Preview sheet for pasted screenshots showing image with OCR highlights and editable fields
struct PastePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    let imageData: Data
    let ocrResult: OCRPageResult
    let extractedData: ExtractedData
    let entities: ExtractedEntities
    let onConfirm: (ExtractedEntities) -> Void

    // Editable fields
    @State private var organization: String
    @State private var amount: Decimal
    @State private var currency: Currency
    @State private var dueDate: Date

    init(
        imageData: Data,
        ocrResult: OCRPageResult,
        extractedData: ExtractedData,
        entities: ExtractedEntities,
        onConfirm: @escaping (ExtractedEntities) -> Void
    ) {
        self.imageData = imageData
        self.ocrResult = ocrResult
        self.extractedData = extractedData
        self.entities = entities
        self.onConfirm = onConfirm

        // Initialize editable fields from extracted entities
        _organization = State(initialValue: entities.organizationName ?? "")
        _amount = State(initialValue: entities.amount ?? Decimal(0))
        _currency = State(initialValue: entities.currency ?? .usd)
        _dueDate = State(initialValue: entities.dueDate ?? Date().addingTimeInterval(30 * 24 * 60 * 60))
    }


    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Screenshot Preview")
                    .font(.headline)
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            // Main content: split view
            HSplitView {
                // Left: Image preview with highlights
                VStack(spacing: 0) {
                    HStack {
                        Text("Detected Data")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()

                        // Legend
                        HStack(spacing: 12) {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color.green.opacity(0.5))
                                    .frame(width: 10, height: 10)
                                Text("Amounts")
                                    .font(.caption)
                            }
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color.blue.opacity(0.5))
                                    .frame(width: 10, height: 10)
                                Text("Dates")
                                    .font(.caption)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                    DocumentPreviewView(
                        imageData: imageData,
                        highlights: DocumentPreviewView.highlights(from: extractedData)
                    )
                }
                .frame(minWidth: 400)

                // Right: Editable form
                Form {
                    Section("Extracted Information") {
                        TextField("Organization", text: $organization)

                        HStack {
                            Text("Amount")
                            Spacer()
                            TextField("Amount", value: $amount, format: .currency(code: currency.currencyCode))
                                .multilineTextAlignment(.trailing)
                                .frame(width: 150)
                        }

                        Picker("Currency", selection: $currency) {
                            ForEach(Currency.allCases) { curr in
                                Text("\(curr.symbol) \(curr.displayName)").tag(curr)
                            }
                        }

                        DatePicker("Due Date", selection: $dueDate, displayedComponents: [.date])
                    }

                    // Show detected amounts for reference
                    if !extractedData.amounts.isEmpty {
                        Section("Detected Amounts") {
                            ForEach(extractedData.amounts) { extractedAmount in
                                Button {
                                    amount = extractedAmount.value
                                    currency = extractedAmount.currency
                                } label: {
                                    HStack {
                                        Text(extractedAmount.rawText)
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        Text(extractedAmount.value, format: .currency(code: extractedAmount.currency.currencyCode))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Show detected dates for reference
                    if !extractedData.dates.isEmpty {
                        Section("Detected Dates") {
                            ForEach(extractedData.dates) { extractedDate in
                                Button {
                                    dueDate = extractedDate.date
                                } label: {
                                    HStack {
                                        Text(extractedDate.rawText)
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        Text(extractedDate.date, format: .dateTime.month().day().year())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Show OCR text preview
                    Section("Extracted Text") {
                        ScrollView {
                            Text(ocrResult.fullText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 150)
                    }
                }
                .formStyle(.grouped)
                .frame(minWidth: 300, maxWidth: 400)
            }

            Divider()

            // Footer with actions
            HStack {
                Spacer()
                Button("Create Document") {
                    // Build confirmed entities with all required fields
                    let confirmed = ExtractedEntities(
                        organizationName: organization.isEmpty ? nil : organization,
                        dueDate: dueDate,
                        amount: amount,
                        currency: currency,
                        allOrganizations: entities.allOrganizations,
                        allDates: entities.allDates,
                        allAmounts: entities.allAmounts,
                        confidence: entities.confidence
                    )
                    onConfirm(confirmed)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(organization.isEmpty && amount == 0)
            }
            .padding()
        }
        .frame(minWidth: 800, minHeight: 600)
    }
}

// MARK: - Library AI Analysis Result Sheet

/// AI Analysis result sheet for Library documents (SwiftData-backed RFFDocument)
struct LibraryAIAnalysisResultSheet: View {
    let result: AIAnalysisResult
    @Bindable var document: RFFDocument
    let onDismiss: () -> Void

    @State private var selectedSuggestions: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("AI Analysis Results")
                        .font(.headline)
                    if let summary = result.summary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button("Done") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            // Suggestions list
            List(selection: $selectedSuggestions) {
                Section("Extracted Fields (\(result.suggestions.count))") {
                    ForEach(result.suggestions) { suggestion in
                        LibraryAISuggestionRow(
                            suggestion: suggestion,
                            isSelected: selectedSuggestions.contains(suggestion.id)
                        )
                        .tag(suggestion.id)
                    }
                }

                if !result.notes.isEmpty {
                    Section("Notes") {
                        ForEach(result.notes, id: \.self) { note in
                            Label(note, systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let schemaName = result.suggestedSchemaName {
                    Section("Suggested Schema") {
                        Label(schemaName, systemImage: "doc.text")
                    }
                }
            }
            .listStyle(.inset)

            Divider()

            // Action bar
            HStack {
                Text("\(selectedSuggestions.count) selected")
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Apply Selected") {
                    applySelectedSuggestions()
                }
                .disabled(selectedSuggestions.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 500, height: 500)
        .onAppear {
            // Pre-select high confidence suggestions
            selectedSuggestions = Set(
                result.suggestions
                    .filter { $0.confidence >= 0.7 }
                    .map { $0.id }
            )
        }
    }

    private func applySelectedSuggestions() {
        let selectedItems = result.suggestions.filter { selectedSuggestions.contains($0.id) }

        for suggestion in selectedItems {
            applyFieldSuggestion(suggestion)
        }

        onDismiss()
    }

    private func applyFieldSuggestion(_ suggestion: AIFieldSuggestion) {
        switch suggestion.fieldType {
        case "vendor":
            if document.requestingOrganization.isEmpty || document.requestingOrganization == "Unknown" {
                document.requestingOrganization = suggestion.value
            }
        case "total":
            if document.amount == .zero, let amount = Decimal(string: suggestion.value) {
                document.amount = amount
            }
        case "due_date":
            if let date = parseISODate(suggestion.value) {
                document.dueDate = date
            }
        case "currency":
            if let currency = Currency(rawValue: suggestion.value.uppercased()) {
                document.currency = currency
            }
        case "invoice_number":
            // Could update title or store separately
            if document.title == "New Document" || document.title.isEmpty {
                document.title = "Invoice \(suggestion.value)"
            }
        default:
            break
        }

        document.updatedAt = Date()
    }

    private func parseISODate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: string)
    }
}

struct LibraryAISuggestionRow: View {
    let suggestion: AIFieldSuggestion
    let isSelected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(displayName(for: suggestion.fieldType))
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Spacer()

                    LibraryConfidenceBadge(confidence: suggestion.confidence)
                }

                Text(suggestion.value)
                    .font(.body)
                    .foregroundStyle(isSelected ? .primary : .secondary)

                if let reasoning = suggestion.reasoning {
                    Text(reasoning)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func displayName(for fieldType: String) -> String {
        switch fieldType {
        case "invoice_number": return "Invoice Number"
        case "invoice_date": return "Invoice Date"
        case "due_date": return "Due Date"
        case "vendor": return "Vendor"
        case "customer_name": return "Customer"
        case "subtotal": return "Subtotal"
        case "tax": return "Tax"
        case "total": return "Total"
        case "currency": return "Currency"
        case "po_number": return "PO Number"
        case "payment_terms": return "Payment Terms"
        default: return fieldType.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

struct LibraryConfidenceBadge: View {
    let confidence: Double

    var body: some View {
        Text("\(Int(confidence * 100))%")
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(backgroundColor)
            .foregroundColor(foregroundColor)
            .cornerRadius(4)
    }

    private var backgroundColor: Color {
        if confidence >= 0.8 {
            return .green.opacity(0.2)
        } else if confidence >= 0.5 {
            return .yellow.opacity(0.2)
        } else {
            return .red.opacity(0.2)
        }
    }

    private var foregroundColor: Color {
        if confidence >= 0.8 {
            return .green
        } else if confidence >= 0.5 {
            return .orange
        } else {
            return .red
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: RFFDocument.self, inMemory: true)
}
