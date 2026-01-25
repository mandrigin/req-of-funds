import SwiftUI
import SwiftData
import PDFKit
import AppKit
import UniformTypeIdentifiers

/// Filter for document list: Inbox (pending/underReview) vs Confirmed (approved/completed) vs Paid (archive)
enum DocumentFilter: String, CaseIterable {
    case inbox = "Inbox"
    case confirmed = "Confirmed"
    case paid = "Paid"
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

/// Recipient filter for document list
enum RecipientFilter: Hashable {
    case all
    case specific(String)
    case unassigned

    var displayName: String {
        switch self {
        case .all:
            return "All Recipients"
        case .specific(let recipient):
            return recipient
        case .unassigned:
            return "No Recipient"
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

    // Paid: archived documents with payment recorded
    private var paidDocuments: [RFFDocument] {
        allDocuments.filter { $0.status == .paid }
    }

    @State private var selectedFilter: DocumentFilter = .inbox
    @State private var selectedCurrencyFilter: CurrencyFilter = .all
    @State private var selectedRecipientFilter: RecipientFilter = .all

    /// Documents to display based on current filters
    private var documents: [RFFDocument] {
        let statusFiltered: [RFFDocument]
        switch selectedFilter {
        case .inbox:
            statusFiltered = inboxDocuments
        case .confirmed:
            statusFiltered = confirmedDocuments
        case .paid:
            statusFiltered = paidDocuments
        }

        // Apply currency filter
        let currencyFiltered: [RFFDocument]
        switch selectedCurrencyFilter {
        case .all:
            currencyFiltered = statusFiltered
        case .specific(let currency):
            currencyFiltered = statusFiltered.filter { $0.currency == currency }
        }

        // Apply recipient filter
        switch selectedRecipientFilter {
        case .all:
            return currencyFiltered
        case .specific(let recipient):
            return currencyFiltered.filter { $0.recipient == recipient }
        case .unassigned:
            return currencyFiltered.filter { $0.recipient == nil || $0.recipient?.isEmpty == true }
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
        case .paid:
            statusFiltered = paidDocuments
        }
        let currencies = Set(statusFiltered.map { $0.currency })
        return Currency.allCases.filter { currencies.contains($0) }
    }

    /// Available recipients in the current document set (for filter menu)
    private var availableRecipients: [String] {
        let statusFiltered: [RFFDocument]
        switch selectedFilter {
        case .inbox:
            statusFiltered = inboxDocuments
        case .confirmed:
            statusFiltered = confirmedDocuments
        case .paid:
            statusFiltered = paidDocuments
        }
        let recipients = Set(statusFiltered.compactMap { $0.recipient }.filter { !$0.isEmpty })
        return recipients.sorted()
    }

    /// Whether there are documents without recipients in the current filter
    private var hasUnassignedRecipients: Bool {
        let statusFiltered: [RFFDocument]
        switch selectedFilter {
        case .inbox:
            statusFiltered = inboxDocuments
        case .confirmed:
            statusFiltered = confirmedDocuments
        case .paid:
            statusFiltered = paidDocuments
        }
        return statusFiltered.contains { $0.recipient == nil || $0.recipient?.isEmpty == true }
    }
    @State private var isImportingPDF = false
    @State private var importError: String?
    @State private var showingImportError = false
    @State private var selectedDocuments: Set<RFFDocument.ID> = []
    @State private var selectedDocument: RFFDocument?
    @State private var sortOrder = [KeyPathComparator(\RFFDocument.dueDate)]
    @State private var isProcessingPaste = false
    @State private var isProcessingDrop = false
    @State private var dropProcessingCount = 0
    @State private var dropProcessingTotal = 0

    // Text entry state
    @State private var showingTextEntry = false

    // Library AI Analysis state (for context menu)
    @State private var isAnalyzingFromLibrary = false
    @State private var showingLibraryAIResults = false
    @State private var libraryAIAnalysisResult: AIAnalysisResult?
    @State private var libraryAITargetDocument: RFFDocument?
    @State private var libraryAIErrorMessage: String?
    @State private var showingLibraryAIError = false

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

    /// Documents to use for totals calculation (selected or all in current view)
    private var documentsForTotals: [RFFDocument] {
        if selectedDocuments.isEmpty {
            return documents
        } else {
            return documents.filter { selectedDocuments.contains($0.id) }
        }
    }

    /// Totals grouped by currency for the current selection/view
    private var totalsByCurrency: [(currency: Currency, total: Decimal)] {
        let grouped = Dictionary(grouping: documentsForTotals) { $0.currency }
        return Currency.allCases.compactMap { currency in
            guard let docs = grouped[currency], !docs.isEmpty else { return nil }
            let total = docs.reduce(Decimal(0)) { $0 + $1.amount }
            return (currency: currency, total: total)
        }
    }

    /// Formatted totals string for display
    private var totalsDisplayText: String {
        if totalsByCurrency.isEmpty {
            return "No documents"
        }

        let parts = totalsByCurrency.map { item in
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = item.currency.currencyCode
            formatter.maximumFractionDigits = 2
            let formatted = formatter.string(from: item.total as NSDecimalNumber) ?? "\(item.total)"
            return formatted
        }

        let prefix = selectedDocuments.isEmpty ? "Total" : "Selected"
        return "\(prefix): \(parts.joined(separator: ", "))"
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // Filter tabs at top of library
                HStack {
                    Picker("Filter", selection: $selectedFilter) {
                        ForEach(DocumentFilter.allCases, id: \.self) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 270)

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

                    // Recipient filter menu
                    Menu {
                        Button {
                            selectedRecipientFilter = .all
                        } label: {
                            if case .all = selectedRecipientFilter {
                                Label("All Recipients", systemImage: "checkmark")
                            } else {
                                Text("All Recipients")
                            }
                        }

                        if hasUnassignedRecipients {
                            Button {
                                selectedRecipientFilter = .unassigned
                            } label: {
                                if case .unassigned = selectedRecipientFilter {
                                    Label("No Recipient", systemImage: "checkmark")
                                } else {
                                    Text("No Recipient")
                                }
                            }
                        }

                        if !availableRecipients.isEmpty {
                            Divider()

                            ForEach(availableRecipients, id: \.self) { recipient in
                                Button {
                                    selectedRecipientFilter = .specific(recipient)
                                } label: {
                                    if case .specific(let selected) = selectedRecipientFilter, selected == recipient {
                                        Label(recipient, systemImage: "checkmark")
                                    } else {
                                        Text(recipient)
                                    }
                                }
                            }
                        }
                    } label: {
                        Label(recipientFilterLabel, systemImage: "person.crop.circle")
                    }

                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                // Table view with columns
                Table(documents, selection: $selectedDocuments, sortOrder: $sortOrder) {
                TableColumn("Organization", value: \.requestingOrganization) { document in
                    Text(document.requestingOrganization)
                }
                .width(min: 120, ideal: 180)

                TableColumn("Recipient") { document in
                    if let recipient = document.recipient, !recipient.isEmpty {
                        Text(recipient)
                            .foregroundStyle(.primary)
                    } else {
                        Text("—")
                            .foregroundStyle(.tertiary)
                    }
                }
                .width(min: 80, ideal: 120)

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
            .onDrop(of: [.pdf, .image], isTargeted: nil) { providers in
                handleFileDrop(providers: providers)
                return true
            }
            .overlay {
                if isProcessingDrop {
                    ZStack {
                        Color.black.opacity(0.3)
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.5)
                            if dropProcessingTotal > 1 {
                                Text("Processing \(dropProcessingCount) of \(dropProcessingTotal) files...")
                                    .font(.headline)
                            } else {
                                Text("Processing invoice...")
                                    .font(.headline)
                            }
                        }
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                } else if documents.isEmpty {
                    ContentUnavailableView {
                        Label(
                            emptyStateTitle,
                            systemImage: emptyStateIcon
                        )
                    } description: {
                        Text(emptyStateDescription)
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
                    // AI Analyze - only for single document selection, not for read-only docs
                    if ids.count == 1, let id = ids.first,
                       let doc = documents.first(where: { $0.id == id }),
                       !(doc.extractedText ?? "").isEmpty,
                       !doc.isReadOnly {
                        Button {
                            performLibraryAIAnalysis(documentId: id)
                        } label: {
                            if isAnalyzingFromLibrary {
                                Label("Analyzing...", systemImage: "sparkles")
                            } else {
                                Label("AI Analyze", systemImage: "sparkles")
                            }
                        }
                        .disabled(isAnalyzingFromLibrary)
                    }

                    Divider()

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
                    .help("Import an invoice or document from a PDF file")
                    Button(action: { showingTextEntry = true }) {
                        Label("Enter Text", systemImage: "text.badge.plus")
                    }
                    .help("Manually enter document details as text")
                    Button(action: addDocument) {
                        Label("Add Document", systemImage: "plus")
                    }
                    .help("Create a new blank document")
                }

                ToolbarItemGroup(placement: .secondaryAction) {
                    if !selectedDocuments.isEmpty {
                        Button(role: .destructive) {
                            deleteDocuments(ids: selectedDocuments)
                        } label: {
                            Label("Delete Selected", systemImage: "trash")
                        }
                        .help("Delete the selected documents")
                    }
                }
            }

                // Totals bar at bottom
                if !documents.isEmpty {
                    Divider()
                    HStack {
                        Text(totalsDisplayText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(documentsForTotals.count) of \(documents.count) documents")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.bar)
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
        .sheet(isPresented: $showingTextEntry) {
            TextEntrySheet { document in
                modelContext.insert(document)

                // Schedule deadline notification
                Task {
                    try? await NotificationService.shared.scheduleDeadlineNotification(
                        documentId: document.id,
                        title: document.title,
                        organization: document.requestingOrganization,
                        dueDate: document.dueDate
                    )
                }
            }
        }
        .sheet(isPresented: $showingLibraryAIResults) {
            if let result = libraryAIAnalysisResult,
               let document = libraryAITargetDocument {
                LibraryAIAnalysisResultSheet(
                    result: result,
                    document: document,
                    onDismiss: { showingLibraryAIResults = false }
                )
            }
        }
        .alert("AI Analysis Error", isPresented: $showingLibraryAIError) {
            Button("OK") { }
        } message: {
            Text(libraryAIErrorMessage ?? "Unknown error")
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
                await processDroppedFile(at: tempCopy)
                await MainActor.run {
                    isProcessingDrop = false
                }
            }

        case .failure(let error):
            importError = error.localizedDescription
            showingImportError = true
        }
    }

    private func handleFileDrop(providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }

        isProcessingDrop = true
        dropProcessingTotal = providers.count
        dropProcessingCount = 1

        Task {
            var errors: [String] = []

            for (index, provider) in providers.enumerated() {
                await MainActor.run {
                    dropProcessingCount = index + 1
                }

                do {
                    let tempCopy = try await loadDroppedFile(from: provider)
                    await processDroppedFile(at: tempCopy)
                } catch {
                    errors.append(error.localizedDescription)
                }
            }

            await MainActor.run {
                isProcessingDrop = false
                dropProcessingCount = 0
                dropProcessingTotal = 0

                if !errors.isEmpty {
                    importError = errors.count == 1
                        ? errors[0]
                        : "Failed to import \(errors.count) files"
                    showingImportError = true
                }
            }
        }
    }

    private func loadDroppedFile(from provider: NSItemProvider) async throws -> URL {
        // Try PDF first, then images
        let supportedTypes: [(UTType, String)] = [
            (.pdf, "pdf"),
            (.png, "png"),
            (.jpeg, "jpg"),
            (.heic, "heic"),
            (.tiff, "tiff"),
            (.bmp, "bmp"),
            (.gif, "gif")
        ]

        for (utType, ext) in supportedTypes {
            if provider.hasItemConformingToTypeIdentifier(utType.identifier) {
                return try await withCheckedThrowingContinuation { continuation in
                    provider.loadFileRepresentation(forTypeIdentifier: utType.identifier) { url, error in
                        if let error = error {
                            continuation.resume(throwing: error)
                            return
                        }

                        guard let url = url else {
                            continuation.resume(throwing: TransferError.invalidData)
                            return
                        }

                        // Copy to a persistent location since the provided URL is temporary
                        let tempCopy = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString)
                            .appendingPathExtension(ext)

                        do {
                            try FileManager.default.copyItem(at: url, to: tempCopy)
                            continuation.resume(returning: tempCopy)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        }

        throw TransferError.invalidData
    }

    private func processDroppedFile(at url: URL) async {
        do {
            // Step 1: Run OCR on the file (works for PDFs and images)
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
            }
        } catch {
            await MainActor.run {
                importError = "Failed to process file: \(error.localizedDescription)"
                showingImportError = true
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

    private var recipientFilterLabel: String {
        switch selectedRecipientFilter {
        case .all:
            return "All"
        case .specific(let recipient):
            // Truncate long recipient names for the label
            if recipient.count > 15 {
                return String(recipient.prefix(12)) + "..."
            }
            return recipient
        case .unassigned:
            return "None"
        }
    }

    private var emptyStateTitle: String {
        switch selectedFilter {
        case .inbox:
            return "No Pending Documents"
        case .confirmed:
            return "No Confirmed Documents"
        case .paid:
            return "No Paid Documents"
        }
    }

    private var emptyStateIcon: String {
        switch selectedFilter {
        case .inbox:
            return "tray"
        case .confirmed:
            return "checkmark.circle"
        case .paid:
            return "banknote"
        }
    }

    private var emptyStateDescription: String {
        switch selectedFilter {
        case .inbox:
            return "Documents pending review will appear here."
        case .confirmed:
            return "Approved and completed documents will appear here."
        case .paid:
            return "Paid documents will appear here as an archive."
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

    // MARK: - Library AI Analysis

    private func performLibraryAIAnalysis(documentId: RFFDocument.ID) {
        guard let document = documents.first(where: { $0.id == documentId }) else { return }
        guard let extractedText = document.extractedText, !extractedText.isEmpty else {
            libraryAIErrorMessage = "No extracted text available. Import a document first."
            showingLibraryAIError = true
            return
        }

        isAnalyzingFromLibrary = true
        libraryAITargetDocument = document

        Task {
            do {
                let result = try await AIAnalysisService.shared.analyzeDocument(text: extractedText)
                await MainActor.run {
                    libraryAIAnalysisResult = result
                    showingLibraryAIResults = true
                    isAnalyzingFromLibrary = false
                }
            } catch {
                await MainActor.run {
                    libraryAIErrorMessage = error.localizedDescription
                    showingLibraryAIError = true
                    isAnalyzingFromLibrary = false
                }
            }
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
        case .paid:
            return .orange.opacity(0.2)
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
        case .paid:
            return .orange
        }
    }
}

struct DocumentDetailView: View {
    @Bindable var document: RFFDocument
    @Environment(\.modelContext) private var modelContext
    @State private var selectedTab = 0
    @State private var pdfDocument: PDFDocument?
    @State private var highlights: [HighlightRegion] = []
    @State private var selectedHighlight: HighlightRegion?
    @State private var isDetectingFields = false
    @State private var showConfirmationPanel = true
    @State private var showingConfirmationAlert = false
    @State private var showingValidationError = false
    @State private var validationErrors: [String] = []

    // Mark as Paid state
    @State private var showingPaidSheet = false
    @State private var selectedPaidDate = Date()

    // Schema Editor state
    @State private var showingSchemaEditor = false

    // AI Analysis state
    @State private var isAnalyzingWithAI = false
    @State private var showingAIResults = false
    @State private var aiAnalysisResult: AIAnalysisResult?
    @State private var aiErrorMessage: String?
    @State private var showingAIError = false

    // Schema editing state
    @State private var isEditingSchema = false

    // Schema extraction state
    @State private var isExtractingWithSchema = false
    @State private var schemaExtractionResult: SchemaExtractionResultWithValues?
    @State private var showingSchemaExtractionResults = false
    @State private var schemaExtractionError: String?
    @State private var showingSchemaExtractionError = false
    @State private var showingSchemaSelector = false
    @State private var availableSchemas: [InvoiceSchema] = []
    @State private var documentSchemaName: String?

    private let textFinder = PDFTextFinder()
    private let schemaExtractionService = SchemaExtractionService.shared

    /// Check if document can be confirmed (is in inbox state)
    private var canConfirm: Bool {
        document.status == .pending || document.status == .underReview
    }

    /// Check if document can be marked as paid (is in confirmed state)
    private var canMarkAsPaid: Bool {
        document.status == .approved || document.status == .completed
    }

    /// Mark the document as paid with the selected payment date
    private func markAsPaid() {
        document.paidDate = selectedPaidDate
        document.status = .paid
        document.updatedAt = Date()

        // Post notification for UI updates
        NotificationCenter.default.post(
            name: .documentStatusChanged,
            object: nil,
            userInfo: ["documentId": document.id, "status": RFFStatus.paid]
        )
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
                    LabeledContent("Recipient", value: document.recipient ?? "—")
                    LabeledContent("Amount", value: document.amount, format: .currency(code: document.currency.currencyCode))
                    LabeledContent("Currency", value: "\(document.currency.symbol) \(document.currency.displayName)")
                    LabeledContent("Due Date", value: document.dueDate, format: .dateTime)
                    LabeledContent("Status") {
                        StatusBadge(status: document.status)
                    }
                }

                // Schema section
                Section("Extraction Schema") {
                    if let schemaName = documentSchemaName {
                        LabeledContent("Schema", value: schemaName)
                    } else {
                        Text("No schema assigned")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Button {
                            showingSchemaSelector = true
                        } label: {
                            Label(document.schemaId == nil ? "Assign Schema" : "Change Schema", systemImage: "doc.text.magnifyingglass")
                        }

                        if document.schemaId != nil && document.documentPath != nil {
                            Button {
                                performSchemaExtraction()
                            } label: {
                                if isExtractingWithSchema {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Label("Re-analyze", systemImage: "arrow.clockwise")
                                }
                            }
                            .disabled(isExtractingWithSchema)
                        }
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

                // Show payment info section for paid documents
                if let paidDate = document.paidDate {
                    Section("Payment Info") {
                        LabeledContent("Payment Date", value: paidDate, format: .dateTime.month().day().year())
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
                                    // Field detection status
                                    if isDetectingFields {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text("Detecting fields...")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    } else {
                                        Text("\(highlights.count) fields detected")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }

                                    Button {
                                        detectAllFields()
                                    } label: {
                                        Label("Re-detect", systemImage: "arrow.clockwise")
                                    }
                                    .disabled(isDetectingFields)

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
                                    .disabled(document.isReadOnly || isAnalyzingWithAI || (document.extractedText ?? "").isEmpty)
                                    .help(document.isReadOnly ? "Document is locked" : "Analyze document with AI")

                                    Button {
                                        withAnimation {
                                            isEditingSchema = true
                                        }
                                    } label: {
                                        Label("Edit Schema", systemImage: "rectangle.and.pencil.and.ellipsis")
                                    }
                                    .disabled(document.isReadOnly)
                                    .help(document.isReadOnly ? "Document is locked" : "Visually map document fields to schema")

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

                                VStack(spacing: 0) {
                                    // Fixed legend header
                                    if !highlights.isEmpty {
                                        HighlightLegendView()
                                        Divider()
                                    }

                                    PDFViewer(
                                        document: pdfDocument,
                                        highlights: highlights,
                                        selectedHighlightId: selectedHighlight?.id,
                                        onHighlightTapped: { highlight in
                                            withAnimation {
                                                selectedHighlight = highlight
                                            }
                                        }
                                    )
                                }

                                // Selected field info panel
                                if let selected = selectedHighlight {
                                    SelectedFieldPanel(
                                        highlight: selected,
                                        document: document,
                                        onDismiss: {
                                            withAnimation {
                                                selectedHighlight = nil
                                            }
                                        },
                                        onApply: { fieldType, value in
                                            applyFieldValue(fieldType: fieldType, value: value)
                                            withAnimation {
                                                selectedHighlight = nil
                                            }
                                        }
                                    )
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                                }
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
                if document.documentPath != nil {
                    Button {
                        showingSchemaEditor = true
                    } label: {
                        Label("Edit Schema", systemImage: "doc.text.magnifyingglass")
                    }
                    .help("Edit the extraction schema for this document type")
                }

                if canConfirm {
                    Button {
                        showingConfirmationAlert = true
                    } label: {
                        Label("Confirm", systemImage: "checkmark.seal.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .help("Approve this document and lock in the current values")
                }

                if canMarkAsPaid {
                    Button {
                        selectedPaidDate = Date()
                        showingPaidSheet = true
                    } label: {
                        Label("Mark as Paid", systemImage: "banknote.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .help("Record payment date and move to Paid archive")
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
        .sheet(isPresented: $showingPaidSheet) {
            MarkAsPaidSheet(
                selectedDate: $selectedPaidDate,
                onConfirm: {
                    markAsPaid()
                    showingPaidSheet = false
                },
                onCancel: {
                    showingPaidSheet = false
                }
            )
        }
        .sheet(isPresented: $showingSchemaEditor) {
            if let path = document.documentPath {
                SchemaEditorView(documentURL: URL(fileURLWithPath: path))
                    .frame(minWidth: 1000, minHeight: 700)
            }
        }
        .sheet(isPresented: $showingSchemaExtractionResults) {
            if let result = schemaExtractionResult {
                SchemaExtractionResultSheet(
                    result: result,
                    document: document,
                    onApply: { result in
                        Task {
                            await schemaExtractionService.applyToDocument(result, document: document)
                            showingSchemaExtractionResults = false
                        }
                    },
                    onDismiss: { showingSchemaExtractionResults = false }
                )
            }
        }
        .sheet(isPresented: $showingSchemaSelector) {
            SchemaSelectorSheet(
                selectedSchemaId: document.schemaId,
                availableSchemas: availableSchemas,
                onSelect: { schemaId in
                    document.schemaId = schemaId
                    document.updatedAt = Date()
                    loadSchemaName()
                    showingSchemaSelector = false
                },
                onCancel: { showingSchemaSelector = false }
            )
        }
        .alert("Schema Extraction Error", isPresented: $showingSchemaExtractionError) {
            Button("OK") { }
        } message: {
            Text(schemaExtractionError ?? "Unknown error")
        }
        .onAppear {
            loadPDF()
            loadSchemaName()
            loadAvailableSchemas()
        }
    }

    private func loadPDF() {
        guard let path = document.documentPath else { return }
        let url = URL(fileURLWithPath: path)
        pdfDocument = PDFDocument(url: url)

        // Auto-detect fields when PDF loads
        detectAllFields()
    }

    /// Apply a detected field value to the document
    private func applyFieldValue(fieldType: InvoiceFieldType, value: String) {
        switch fieldType {
        case .vendor:
            document.requestingOrganization = value
        case .total:
            if let amount = parseAmount(value) {
                document.amount = amount
            }
        case .invoiceDate:
            if let date = parseDate(value) {
                document.dueDate = date
            }
        case .dueDate:
            if let date = parseDate(value) {
                document.dueDate = date
            }
        case .invoiceNumber:
            // Could add an invoiceNumber field to the document model
            break
        default:
            break
        }
        document.updatedAt = Date()
    }

    /// Parse a currency amount string to Decimal
    private func parseAmount(_ text: String) -> Decimal? {
        let cleaned = text
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: "£", with: "")
            .replacingOccurrences(of: "CHF", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Decimal(string: cleaned)
    }

    /// Parse a date string to Date
    private func parseDate(_ text: String) -> Date? {
        DateParsingUtility.parseDate(text)
    }

    /// Detect all known field types in the PDF and create highlights
    private func detectAllFields() {
        guard let pdf = pdfDocument else { return }

        isDetectingFields = true
        highlights = []

        Task {
            var allHighlights: [HighlightRegion] = []

            // Find amounts (total, subtotal, prices)
            let amounts = textFinder.findAmounts(in: pdf)
            allHighlights.append(contentsOf: amounts.map { match in
                HighlightRegion(
                    pageIndex: match.pageIndex,
                    bounds: match.bounds,
                    label: match.text,
                    fieldType: .total
                )
            })

            // Find dates
            let dates = textFinder.findDates(in: pdf)
            allHighlights.append(contentsOf: dates.map { match in
                HighlightRegion(
                    pageIndex: match.pageIndex,
                    bounds: match.bounds,
                    label: match.text,
                    fieldType: .invoiceDate
                )
            })

            // Find invoice numbers (common patterns)
            let invoicePatterns = [
                #"(?i)inv(?:oice)?[\s#:\-]*([A-Z0-9\-]+)"#,
                #"[A-Z]{2,4}[\-]?\d{4,}"#
            ]
            for pattern in invoicePatterns {
                let matches = textFinder.findPattern(pattern, in: pdf)
                allHighlights.append(contentsOf: matches.map { match in
                    HighlightRegion(
                        pageIndex: match.pageIndex,
                        bounds: match.bounds,
                        label: match.text,
                        fieldType: .invoiceNumber
                    )
                })
            }

            // Find PO numbers
            let poPatterns = [
                #"(?i)p\.?o\.?[\s#:\-]*(\d+)"#,
                #"(?i)purchase\s*order[\s#:\-]*(\d+)"#
            ]
            for pattern in poPatterns {
                let matches = textFinder.findPattern(pattern, in: pdf)
                allHighlights.append(contentsOf: matches.map { match in
                    HighlightRegion(
                        pageIndex: match.pageIndex,
                        bounds: match.bounds,
                        label: match.text,
                        fieldType: .poNumber
                    )
                })
            }

            // Remove duplicate highlights (same bounds on same page)
            var uniqueHighlights: [HighlightRegion] = []
            var seenBounds: Set<String> = []
            for highlight in allHighlights {
                let key = "\(highlight.pageIndex)-\(Int(highlight.bounds.origin.x))-\(Int(highlight.bounds.origin.y))"
                if !seenBounds.contains(key) {
                    seenBounds.insert(key)
                    uniqueHighlights.append(highlight)
                }
            }

            await MainActor.run {
                highlights = uniqueHighlights
                isDetectingFields = false
            }
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

    /// Load the name of the document's assigned schema
    private func loadSchemaName() {
        guard let schemaId = document.schemaId else {
            documentSchemaName = nil
            return
        }

        Task {
            let store = SchemaStore.shared
            try? await store.loadSchemas()
            let schema = await store.schema(id: schemaId)
            await MainActor.run {
                documentSchemaName = schema?.name
            }
        }
    }

    /// Load available schemas for the selector
    private func loadAvailableSchemas() {
        Task {
            let store = SchemaStore.shared
            try? await store.loadSchemas()
            let schemas = await store.allSchemas()
            await MainActor.run {
                availableSchemas = schemas
            }
        }
    }

    /// Perform schema-based extraction on the document
    private func performSchemaExtraction() {
        guard document.schemaId != nil else {
            schemaExtractionError = "No schema assigned to this document"
            showingSchemaExtractionError = true
            return
        }

        guard document.documentPath != nil else {
            schemaExtractionError = "Document has no associated file"
            showingSchemaExtractionError = true
            return
        }

        isExtractingWithSchema = true

        Task {
            do {
                let result = try await schemaExtractionService.extractWithDocumentSchema(document)
                await MainActor.run {
                    schemaExtractionResult = result
                    showingSchemaExtractionResults = true
                    isExtractingWithSchema = false
                }
            } catch {
                await MainActor.run {
                    schemaExtractionError = error.localizedDescription
                    showingSchemaExtractionError = true
                    isExtractingWithSchema = false
                }
            }
        }
    }
}

// MARK: - Selected Field Panel

/// Panel showing details of a selected highlight with option to apply the value
struct SelectedFieldPanel: View {
    let highlight: HighlightRegion
    let document: RFFDocument
    let onDismiss: () -> Void
    let onApply: (InvoiceFieldType, String) -> Void

    @State private var editedValue: String
    @State private var selectedFieldType: InvoiceFieldType

    init(
        highlight: HighlightRegion,
        document: RFFDocument,
        onDismiss: @escaping () -> Void,
        onApply: @escaping (InvoiceFieldType, String) -> Void
    ) {
        self.highlight = highlight
        self.document = document
        self.onDismiss = onDismiss
        self.onApply = onApply
        self._editedValue = State(initialValue: highlight.label ?? "")
        self._selectedFieldType = State(initialValue: highlight.fieldType ?? .total)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Field type indicator
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(nsColor: FieldHighlightColor.color(for: selectedFieldType).withAlphaComponent(0.3)))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(nsColor: FieldHighlightColor.color(for: selectedFieldType)), lineWidth: 2)
                )
                .frame(width: 24, height: 24)

            // Field type picker
            Picker("Field Type", selection: $selectedFieldType) {
                ForEach(applicableFieldTypes, id: \.self) { fieldType in
                    Text(fieldType.displayName).tag(fieldType)
                }
            }
            .labelsHidden()
            .frame(width: 140)
            .disabled(document.isReadOnly)

            // Editable value
            TextField("Value", text: $editedValue)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 150)
                .disabled(document.isReadOnly)

            // Current document value for this field
            if let currentValue = currentDocumentValue {
                Text("Current: \(currentValue)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Apply button
            Button {
                onApply(selectedFieldType, editedValue)
            } label: {
                Label(document.isReadOnly ? "Locked" : "Apply", systemImage: document.isReadOnly ? "lock.fill" : "checkmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(document.isReadOnly || editedValue.isEmpty)

            // Dismiss button
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// Field types applicable for editing
    private var applicableFieldTypes: [InvoiceFieldType] {
        [.vendor, .total, .subtotal, .tax, .invoiceDate, .dueDate, .invoiceNumber, .poNumber]
    }

    /// Current value in the document for the selected field type
    private var currentDocumentValue: String? {
        switch selectedFieldType {
        case .vendor:
            return document.requestingOrganization.isEmpty ? nil : document.requestingOrganization
        case .total, .subtotal, .tax:
            if document.amount > 0 {
                let formatter = NumberFormatter()
                formatter.numberStyle = .decimal
                formatter.minimumFractionDigits = 2
                formatter.maximumFractionDigits = 2
                return formatter.string(from: document.amount as NSDecimalNumber)
            }
            return nil
        case .invoiceDate, .dueDate:
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            return formatter.string(from: document.dueDate)
        default:
            return nil
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

        // Save schema if suggested
        if let schemaName = result.suggestedSchemaName, !schemaName.isEmpty {
            saveSchema(name: schemaName, suggestions: selectedItems)
        }

        document.updatedAt = Date()
        onDismiss()
    }

    private func applyFieldSuggestion(_ suggestion: AIFieldSuggestion) {
        switch suggestion.fieldType {
        case "vendor":
            document.requestingOrganization = suggestion.value
        case "recipient":
            document.recipient = suggestion.value
        case "total", "subtotal":
            if let amount = parseAmount(suggestion.value) {
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
            if document.title == "New Document" || document.title.isEmpty {
                document.title = "Invoice \(suggestion.value)"
            }
        default:
            break
        }
    }

    private func saveSchema(name: String, suggestions: [AIFieldSuggestion]) {
        Task {
            // Check if schema with this name already exists
            let existingSchemas = await SchemaStore.shared.allSchemas()
            let exists = existingSchemas.contains { $0.name.lowercased() == name.lowercased() }

            if !exists {
                // Convert suggestions to field mappings
                let fieldMappings: [FieldMapping] = suggestions.compactMap { suggestion in
                    guard let fieldType = InvoiceFieldType(rawValue: suggestion.fieldType) else {
                        return nil
                    }
                    return FieldMapping(
                        fieldType: fieldType,
                        confidence: suggestion.confidence
                    )
                }

                // Extract vendor identifier from suggestions
                let vendorIdentifier = suggestions.first { $0.fieldType == "vendor" }?.value

                do {
                    _ = try await SchemaStore.shared.createSchema(
                        name: name,
                        vendorIdentifier: vendorIdentifier,
                        description: "Auto-generated from AI analysis",
                        fieldMappings: fieldMappings
                    )
                } catch {
                    print("Failed to save schema: \(error)")
                }
            }
        }
    }

    private func parseISODate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: string)
    }

    /// Parse a currency amount string to Decimal, handling commas and currency symbols
    private func parseAmount(_ text: String) -> Decimal? {
        let cleaned = text
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: "£", with: "")
            .replacingOccurrences(of: "CHF", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Decimal(string: cleaned)
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
        case "recipient": return "Recipient"
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

// MARK: - Mark as Paid Sheet

/// Sheet for selecting payment date when marking a document as paid
struct MarkAsPaidSheet: View {
    @Binding var selectedDate: Date
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Mark as Paid")
                    .font(.headline)
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            // Date picker
            VStack(alignment: .leading, spacing: 16) {
                Text("Select the payment date for this document.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                DatePicker(
                    "Payment Date",
                    selection: $selectedDate,
                    displayedComponents: [.date]
                )
                .datePickerStyle(.graphical)
            }
            .padding()

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Mark as Paid") {
                    onConfirm()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
            .padding()
        }
        .frame(width: 340, height: 400)
    }
}

// MARK: - Schema Extraction Result Sheet

/// Sheet showing schema extraction results with option to apply to document
struct SchemaExtractionResultSheet: View {
    let result: SchemaExtractionResultWithValues
    let document: RFFDocument
    let onApply: (SchemaExtractionResultWithValues) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("Extraction Results")
                        .font(.headline)
                    Text("Schema: \(result.schemaName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ConfidenceBadge(confidence: result.overallConfidence)
            }
            .padding()

            Divider()

            // Extracted fields list
            List {
                Section("Extracted Fields (\(result.extractedFields.count))") {
                    ForEach(result.extractedFields) { field in
                        HStack {
                            Circle()
                                .fill(Color(nsColor: colorForFieldType(field.fieldType)))
                                .frame(width: 10, height: 10)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(field.fieldType.displayName)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text(field.value)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }

                            Spacer()

                            Text("\(Int(field.confidence * 100))%")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(confidenceColor(field.confidence).opacity(0.2), in: Capsule())
                        }
                        .padding(.vertical, 4)
                    }
                }

                if !result.warnings.isEmpty {
                    Section("Warnings") {
                        ForEach(result.warnings, id: \.self) { warning in
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text(warning)
                                    .font(.caption)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)

            Divider()

            // Footer with actions
            HStack {
                Text("Apply these values to update the document?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Apply Values") {
                    onApply(result)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 450, height: 500)
    }

    private func confidenceColor(_ confidence: Double) -> Color {
        if confidence >= 0.8 {
            return .green
        } else if confidence >= 0.5 {
            return .orange
        } else {
            return .red
        }
    }
}

// MARK: - Schema Selector Sheet

/// Sheet for selecting a schema to assign to a document
struct SchemaSelectorSheet: View {
    let selectedSchemaId: UUID?
    let availableSchemas: [InvoiceSchema]
    let onSelect: (UUID) -> Void
    let onCancel: () -> Void

    @State private var searchText = ""

    private var filteredSchemas: [InvoiceSchema] {
        if searchText.isEmpty {
            return availableSchemas
        }
        let lowered = searchText.lowercased()
        return availableSchemas.filter {
            $0.name.lowercased().contains(lowered) ||
            ($0.vendorIdentifier?.lowercased().contains(lowered) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Select Schema")
                    .font(.headline)
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            // Search field
            TextField("Search schemas...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.vertical, 8)

            // Schema list
            List {
                ForEach(filteredSchemas) { schema in
                    SchemaRow(
                        schema: schema,
                        isSelected: schema.id == selectedSchemaId,
                        onSelect: { onSelect(schema.id) }
                    )
                }
            }
            .listStyle(.plain)

            if filteredSchemas.isEmpty {
                ContentUnavailableView(
                    "No Schemas",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(searchText.isEmpty ? "Create a schema from the Schema Editor" : "No schemas match your search")
                )
            }
        }
        .frame(width: 400, height: 450)
    }
}

/// Row showing a single schema in the selector
struct SchemaRow: View {
    let schema: InvoiceSchema
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(schema.name)
                            .fontWeight(isSelected ? .bold : .regular)
                        if schema.isBuiltIn {
                            Text("Built-in")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.blue.opacity(0.2), in: Capsule())
                                .foregroundStyle(.blue)
                        }
                    }

                    HStack {
                        if let vendor = schema.vendorIdentifier {
                            Text("Vendor: \(vendor)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("\(schema.fieldMappings.count) fields")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        if schema.usageCount > 0 {
                            Text("\(schema.usageCount) uses")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.blue)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
    }
}

// MARK: - Text Entry Sheet

/// Sheet for entering plain text and running AI analysis to create a document
struct TextEntrySheet: View {
    @Environment(\.dismiss) private var dismiss

    let onCreateDocument: (RFFDocument) -> Void

    // Text input
    @State private var inputText: String = ""

    // Analysis state
    @State private var isAnalyzing = false
    @State private var analysisResult: AIAnalysisResult?
    @State private var analysisError: String?
    @State private var showingError = false

    // Editable extracted fields
    @State private var organization: String = ""
    @State private var amount: Decimal = 0
    @State private var currency: Currency = .usd
    @State private var dueDate: Date = Date().addingTimeInterval(30 * 24 * 60 * 60)

    /// Check if we have enough data to create a document
    private var canCreateDocument: Bool {
        !organization.isEmpty || amount > 0
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Enter Invoice Text")
                    .font(.headline)
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            // Main content
            HSplitView {
                // Left: Text input
                VStack(alignment: .leading, spacing: 8) {
                    Text("Paste or type invoice details:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $inputText)
                        .font(.body.monospaced())
                        .frame(minHeight: 200)
                        .border(Color.secondary.opacity(0.3), width: 1)

                    HStack {
                        Button {
                            performAnalysis()
                        } label: {
                            if isAnalyzing {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Analyzing...")
                            } else {
                                Label("Analyze with AI", systemImage: "sparkles")
                            }
                        }
                        .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAnalyzing)

                        Spacer()

                        Text("\(inputText.count) characters")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding()
                .frame(minWidth: 350)

                // Right: Extracted fields form
                Form {
                    Section("Document Fields") {
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

                    // Show AI suggestions if available
                    if let result = analysisResult, !result.suggestions.isEmpty {
                        Section("AI Suggestions") {
                            ForEach(result.suggestions) { suggestion in
                                Button {
                                    applySuggestion(suggestion)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(displayName(for: suggestion.fieldType))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            Text(suggestion.value)
                                                .foregroundStyle(.primary)
                                        }
                                        Spacer()
                                        Text("\(Int(suggestion.confidence * 100))%")
                                            .font(.caption)
                                            .foregroundStyle(suggestion.confidence >= 0.7 ? .green : .orange)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if let summary = result.summary {
                            Section("Summary") {
                                Text(summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(minWidth: 300, maxWidth: 400)
            }

            Divider()

            // Footer
            HStack {
                if let error = analysisError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Spacer()

                Button("Create Document") {
                    createDocument()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canCreateDocument)
            }
            .padding()
        }
        .frame(minWidth: 750, minHeight: 500)
        .alert("Analysis Error", isPresented: $showingError) {
            Button("OK") { }
        } message: {
            Text(analysisError ?? "Unknown error")
        }
    }

    private func performAnalysis() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        isAnalyzing = true
        analysisError = nil

        Task {
            do {
                let result = try await AIAnalysisService.shared.analyzeDocument(text: text)
                await MainActor.run {
                    analysisResult = result
                    isAnalyzing = false

                    // Auto-apply high-confidence suggestions
                    for suggestion in result.suggestions where suggestion.confidence >= 0.8 {
                        applySuggestion(suggestion)
                    }
                }
            } catch {
                await MainActor.run {
                    analysisError = error.localizedDescription
                    isAnalyzing = false
                    showingError = true
                }
            }
        }
    }

    private func applySuggestion(_ suggestion: AIFieldSuggestion) {
        switch suggestion.fieldType {
        case "vendor":
            organization = suggestion.value
        case "total":
            if let value = Decimal(string: suggestion.value) {
                amount = value
            }
        case "due_date":
            if let date = parseISODate(suggestion.value) {
                dueDate = date
            }
        case "currency":
            if let curr = Currency(rawValue: suggestion.value.uppercased()) {
                currency = curr
            }
        default:
            break
        }
    }

    private func parseISODate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: string)
    }

    private func displayName(for fieldType: String) -> String {
        switch fieldType {
        case "invoice_number": return "Invoice Number"
        case "invoice_date": return "Invoice Date"
        case "due_date": return "Due Date"
        case "vendor": return "Vendor"
        case "recipient": return "Recipient"
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

    private func createDocument() {
        let title = generateTitle()
        let document = RFFDocument(
            title: title,
            requestingOrganization: organization.isEmpty ? "Unknown" : organization,
            amount: amount,
            currency: currency,
            dueDate: dueDate,
            extractedText: inputText.isEmpty ? nil : inputText
        )

        onCreateDocument(document)
        dismiss()
    }

    private func generateTitle() -> String {
        if !organization.isEmpty && amount > 0 {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = currency.currencyCode
            let amountStr = formatter.string(from: amount as NSDecimalNumber) ?? "\(amount)"
            return "\(organization) - \(amountStr)"
        } else if !organization.isEmpty {
            return "RFF - \(organization)"
        } else {
            return "RFF - Text Entry"
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: RFFDocument.self, inMemory: true)
}
