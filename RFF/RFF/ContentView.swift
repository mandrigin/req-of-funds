import SwiftUI
import SwiftData
import PDFKit
import AppKit
import UniformTypeIdentifiers

/// Filter for document list: Inbox (pending/underReview) vs Confirmed (approved/completed) vs Paid (archive)
/// Top-level app sections shown in the sidebar source list.
/// Inbox/Confirmed/Paid are document states; the rest are places.
enum DocumentFilter: String, CaseIterable {
    case inbox = "Inbox"
    case confirmed = "Confirmed"
    case paid = "Paid"
    case review = "Review"
    case templates = "Templates"
    case drafts = "Drafts"
    case reporting = "Reporting"

    var isDocumentList: Bool {
        switch self {
        case .inbox, .confirmed, .paid: return true
        default: return false
        }
    }

    var systemImage: String {
        switch self {
        case .inbox: return "tray"
        case .confirmed: return "checkmark.circle"
        case .paid: return "banknote"
        case .review: return "questionmark.circle"
        case .templates: return "doc.text"
        case .drafts: return "paperplane"
        case .reporting: return "chart.bar.doc.horizontal"
        }
    }
}

extension Notification.Name {
    /// Posted by the menu bar panel / Go menu to switch the main window's section
    static let rffOpenSection = Notification.Name("rff.openSection")
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

    var displayName: String {
        switch self {
        case .all:
            return "All Recipients"
        case .specific(let recipient):
            return recipient
        }
    }
}

/// Result of migrating legacy document paths into managed storage
struct MigrationResult {
    let migrated: Int
    let missing: Int

    var summary: String {
        var parts: [String] = []
        if migrated > 0 {
            parts.append("\(migrated) document\(migrated == 1 ? "" : "s") copied into app storage.")
        }
        if missing > 0 {
            parts.append("\(missing) document\(missing == 1 ? "'s" : "s'") original file\(missing == 1 ? " was" : "s were") not found — the original path is shown in the preview.")
        }
        return parts.joined(separator: "\n")
    }
}

/// Shows the document file path with a Reveal / Copy / Replace button
struct DocumentPathBar: View {
    let path: String
    let documentId: UUID
    var onFileReplaced: ((String) -> Void)?

    @State private var isPickingReplacement = false

    private var fileExists: Bool {
        FileManager.default.fileExists(atPath: path)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: fileExists ? "doc.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(fileExists ? .secondary : .orange)
                .font(.caption)
            Text(path)
                .font(.caption)
                .foregroundColor(fileExists ? .secondary : .orange)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(path)
            Spacer()
            if fileExists {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                .font(.caption)
                .buttonStyle(.borderless)
            } else {
                Text("File missing")
                    .font(.caption)
                    .foregroundColor(.orange)
                Button("Replace File...") {
                    isPickingReplacement = true
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(fileExists ? Color.clear : Color.orange.opacity(0.08))
        .fileImporter(
            isPresented: $isPickingReplacement,
            allowedContentTypes: [.pdf, .png, .jpeg, .tiff],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            if let newPath = try? DocumentStorageService.copyFile(from: url, documentId: documentId) {
                onFileReplaced?(newPath)
            }
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

    @State private var selectedFilter: DocumentFilter = .confirmed
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
        default:
            statusFiltered = []  // Non-document sections render their own views
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
        default:
            statusFiltered = []  // Non-document sections render their own views
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
        default:
            statusFiltered = []  // Non-document sections render their own views
        }
        let recipients = Set(statusFiltered.compactMap { $0.recipient })
        return recipients.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    @State private var isImportingPDF = false
    @State private var importError: String?
    @State private var showingImportError = false
    @State private var selectedDocuments: Set<RFFDocument.ID> = []
    @State private var selectedDocument: RFFDocument?
    @State private var sortOrder = [KeyPathComparator(\RFFDocument.dueDate)]
    @State private var isProcessingPaste = false
    @State private var isProcessingDrop = false
    @State private var pendingDropCount = 0
    @State private var newlyDroppedDocumentIDs: [RFFDocument.ID] = []

    // Migration state
    @State private var migrationResult: MigrationResult?
    @State private var showingMigrationResult = false

    // Column visibility configuration
    @StateObject private var columnConfiguration = LibraryColumnConfiguration.shared
    @ObservedObject private var reviewQueue = ReviewQueueStore.shared
    @ObservedObject private var invoiceScheduler = InvoiceScheduler.shared

    // Text entry state
    @State private var showingTextEntry = false

    // Bulk actions on the table selection
    @State private var showingBulkPaidSheet = false
    @State private var bulkPaidDate = Date()
    @State private var bulkPaidIDs: Set<RFFDocument.ID> = []

    /// Selected documents still in the inbox state (eligible for bulk confirm)
    private var confirmableSelection: [RFFDocument] {
        allDocuments.filter {
            selectedDocuments.contains($0.id) && ($0.status == .pending || $0.status == .underReview)
        }
    }

    /// Selected documents in the confirmed state (eligible for bulk mark-as-paid)
    private var payableSelection: [RFFDocument] {
        allDocuments.filter {
            selectedDocuments.contains($0.id) && ($0.status == .approved || $0.status == .completed)
        }
    }

    // Paste preview state
    @State private var showingPastePreview = false
    @State private var pastedImageData: Data?
    @State private var pastedImageExtension: String = "png"
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

    /// TE-style model plate: dark mono label at the foot of the sidebar
    private var versionPlate: some View {
        HStack(spacing: 5) {
            Circle().fill(Signal.green).frame(width: 5, height: 5)
            Text("RFF")
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(KOII.text)
            Text("[\(Bundle.main.rffVersion.uppercased())]")
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(KOII.amber)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(KOII.bg, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .help("RFF \(Bundle.main.rffVersion)")
    }

    /// Sidebar source list: every part of the app, one click away
    private var sourceList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedFilter) {
                Section("Money Out") {
                    Label("Inbox", systemImage: DocumentFilter.inbox.systemImage)
                        .badge(inboxDocuments.count)
                        .tag(DocumentFilter.inbox)
                    Label("Confirmed", systemImage: DocumentFilter.confirmed.systemImage)
                        .tag(DocumentFilter.confirmed)
                    Label("Paid", systemImage: DocumentFilter.paid.systemImage)
                        .tag(DocumentFilter.paid)
                }
                Section("Money In") {
                    Label("Templates", systemImage: DocumentFilter.templates.systemImage)
                        .tag(DocumentFilter.templates)
                    Label("Drafts", systemImage: DocumentFilter.drafts.systemImage)
                        .badge(unsentDraftCount)
                        .tag(DocumentFilter.drafts)
                }
                Section {
                    Label("Review", systemImage: DocumentFilter.review.systemImage)
                        .badge(reviewQueue.pendingCount)
                        .tag(DocumentFilter.review)
                    Label("Reporting", systemImage: DocumentFilter.reporting.systemImage)
                        .tag(DocumentFilter.reporting)
                }
            }
            .listStyle(.sidebar)

            versionPlate
        }
    }

    /// Outbound drafts that still need sending (pending or approved, not sent)
    private var unsentDraftCount: Int {
        invoiceScheduler.draftInvoices
            .filter { $0.status == .pending || $0.status == .approved }
            .count
    }

    private var mainSplit: some View {
        NavigationSplitView {
            sourceList
                .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            // Flexible frames everywhere: switching sections must never resize the window
            Group {
                switch selectedFilter {
                case .review:
                    ReviewQueueView()
                case .templates:
                    TemplatesListView()
                case .drafts:
                    DraftsListView()
                case .reporting:
                    ReportingView()
                case .inbox, .confirmed, .paid:
                    documentSplit
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var documentSplit: some View {
        HSplitView {
            documentListPane
                .frame(minWidth: 470, maxWidth: .infinity)
            // Detail gets the lion's share: preview + confirm form need the room
            Group {
                if let document = selectedDocument {
                    DocumentDetailView(document: document)
                        .id(document.id)
                } else {
                    ContentUnavailableView(
                        "No Document Selected",
                        systemImage: "doc.text",
                        description: Text("Select a document to view details")
                    )
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
        }
    }

    private var documentListPane: some View {
            VStack(spacing: 0) {
                // Filters live directly above the list they control
                HStack(spacing: 6) {
                    Spacer(minLength: 4)

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
                    .controlSize(.small)
                    .fixedSize()

                    // Recipient filter menu (always visible for consistent UI)
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
                    .controlSize(.small)
                    .fixedSize()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                Divider()

                // Content area: table (or the Reporting overlay), tabs stay visible above
                VStack(spacing: 0) {
                // Table view with columns
                Table(documents, selection: $selectedDocuments, sortOrder: $sortOrder) {
                TableColumn("Due Date", value: \.dueDate) { document in
                    HStack {
                        Text(document.dueDate, format: .dateTime.month().day().year())
                            .monospacedDigit()
                        // Overdue warning only matters while money is still owed
                        if document.dueDate < Date()
                            && document.status != .completed
                            && document.status != .paid {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }
                .width(min: 96, ideal: 110, max: 130)

                TableColumn("Amount") { document in
                    HStack(spacing: 6) {
                        Spacer(minLength: 0)
                        Text(document.amount, format: .number.precision(.fractionLength(2)).grouping(.automatic))
                            .font(.system(.body, design: .monospaced))
                        Text(document.currency.rawValue)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .tracking(0.5)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(currencyColor(for: document.currency).opacity(0.16), in: Capsule())
                            .foregroundStyle(currencyColor(for: document.currency))
                    }
                }
                .width(min: 110, ideal: 130, max: 160)

                // From is the elastic column: it absorbs whatever width remains
                TableColumn("From", value: \.requestingOrganization) { document in
                    HStack(spacing: 6) {
                        Text(document.requestingOrganization)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if document.documentCategory == DocumentCategory.salary.rawValue {
                            SalaryTag()
                        }
                    }
                }
                .width(min: 110)

                TableColumn("Status") { document in
                    HStack(spacing: 6) {
                        StatusBadge(status: document.status, paidDaysLate: document.paidDaysLate)
                        // Show AI analysis progress indicator
                        if AIAnalysisProgressManager.shared.isAnalyzing(documentId: document.id) {
                            ProgressView()
                                .controlSize(.small)
                                .help("AI analysis in progress...")
                        }
                    }
                }
                .width(min: 105, ideal: 120, max: 150)

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
                            emptyStateTitle,
                            systemImage: emptyStateIcon
                        )
                    } description: {
                        Text(emptyStateDescription)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                // Batch AI analysis progress bar
                if AIAnalysisProgressManager.shared.batchTotal > 0 {
                    AIBatchProgressBar()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
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
                // Reset recipient filter if selected recipient no longer available
                if case .specific(let recipient) = selectedRecipientFilter {
                    if !availableRecipients.contains(recipient) {
                        selectedRecipientFilter = .all
                    }
                }
            }
            .contextMenu(forSelectionType: RFFDocument.ID.self) { ids in
                if !ids.isEmpty {
                    // AI Analyze buttons - works with single or multiple documents
                    let selectedDocs = documents.filter { ids.contains($0.id) }
                    let docsWithText = selectedDocs.filter { !($0.extractedText ?? "").isEmpty }
                    let anyAnalyzing = selectedDocs.contains { AIAnalysisProgressManager.shared.isAnalyzing(documentId: $0.id) }
                    let countSuffix = ids.count > 1 ? " (\(docsWithText.count))" : ""

                    // Cloud AI option (uses configured provider: Claude Code, Anthropic, or OpenAI)
                    Button {
                        performBatchAIAnalysis(documentIds: ids)
                    } label: {
                        Label("Analyze with Claude\(countSuffix)", systemImage: "cloud")
                    }
                    .disabled(docsWithText.isEmpty || anyAnalyzing)

                    // On-Device AI option (Apple Foundation Models, macOS 26+)
                    if #available(macOS 26, *) {
                        Button {
                            performBatchAIAnalysis(documentIds: ids, provider: .foundation)
                        } label: {
                            Label("Analyze with Apple Intelligence\(countSuffix)", systemImage: "desktopcomputer")
                        }
                        .disabled(docsWithText.isEmpty || anyAnalyzing)
                    }

                    // Local Ollama server option
                    Button {
                        performBatchAIAnalysis(documentIds: ids, provider: .ollama)
                    } label: {
                        Label("Analyze with Ollama\(countSuffix)", systemImage: "cpu")
                    }
                    .disabled(docsWithText.isEmpty || anyAnalyzing)

                    Divider()

                    let confirmable = selectedDocs.filter { $0.status == .pending || $0.status == .underReview }
                    let payable = selectedDocs.filter { $0.status == .approved || $0.status == .completed }

                    if !confirmable.isEmpty {
                        Button {
                            confirmDocuments(ids: Set(confirmable.map(\.id)))
                        } label: {
                            Label(
                                confirmable.count > 1 ? "Confirm (\(confirmable.count))" : "Confirm",
                                systemImage: "checkmark.seal.fill"
                            )
                        }
                    }

                    if !payable.isEmpty {
                        Button {
                            bulkPaidIDs = Set(payable.map(\.id))
                            bulkPaidDate = Date()
                            showingBulkPaidSheet = true
                        } label: {
                            Label(
                                payable.count > 1 ? "Mark as Paid (\(payable.count))…" : "Mark as Paid…",
                                systemImage: "banknote.fill"
                            )
                        }
                    }

                    if !confirmable.isEmpty || !payable.isEmpty {
                        Divider()
                    }

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
            .tableColumnVisibility(configuration: columnConfiguration)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if !confirmableSelection.isEmpty {
                        Button {
                            confirmDocuments(ids: Set(confirmableSelection.map(\.id)))
                        } label: {
                            Label("Confirm (\(confirmableSelection.count))", systemImage: "checkmark.seal.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    }

                    if !payableSelection.isEmpty {
                        Button {
                            bulkPaidIDs = Set(payableSelection.map(\.id))
                            bulkPaidDate = Date()
                            showingBulkPaidSheet = true
                        } label: {
                            Label("Mark as Paid (\(payableSelection.count))", systemImage: "banknote.fill")
                        }
                    }

                    if !selectedDocuments.isEmpty {
                        Button(role: .destructive) {
                            deleteDocuments(ids: selectedDocuments)
                        } label: {
                            Label("Delete Selected", systemImage: "trash")
                        }
                    }

                    Menu {
                        Button(action: { isImportingPDF = true }) {
                            Label("Import PDF…", systemImage: "doc.badge.plus")
                        }
                        Button(action: { showingTextEntry = true }) {
                            Label("Enter Text…", systemImage: "text.badge.plus")
                        }
                        Button(action: addDocument) {
                            Label("New Empty Document", systemImage: "doc")
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }

                // Totals bar: a dark "display surface" - the gauge readout of the table
                if !documents.isEmpty {
                    HStack {
                        Text(totalsDisplayText)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(KOII.amber)
                        Spacer()
                        Text("\(documentsForTotals.count)/\(documents.count) DOCS")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(KOII.dim)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(KOII.bg)
                }
                }
            }
    }

    var body: some View {
        mainSplit
        .onReceive(NotificationCenter.default.publisher(for: .rffOpenSection)) { note in
            if let raw = note.object as? String,
               let section = DocumentFilter(rawValue: raw) {
                selectedFilter = section
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
            if let window = NSApp.windows.first(where: { $0.title.hasPrefix("RFF") }) {
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
                        let docId = UUID()

                        // Save the pasted image into app storage so the document keeps a preview
                        let storedPath = try? DocumentStorageService.saveData(
                            imageData,
                            documentId: docId,
                            fileExtension: pastedImageExtension
                        )

                        let newDocument = RFFDocument(
                            id: docId,
                            title: generateTitle(from: confirmedEntities),
                            requestingOrganization: confirmedEntities.organizationName ?? "Unknown",
                            amount: confirmedEntities.amount ?? Decimal(0),
                            currency: confirmedEntities.currency ?? .usd,
                            dueDate: confirmedEntities.dueDate ?? Date().addingTimeInterval(30 * 24 * 60 * 60),
                            extractedText: ocrResult.fullText,
                            documentPath: storedPath
                        )
                        if SalarySlipDetector.isSalarySlip(
                            filename: nil,
                            text: ocrResult.fullText,
                            config: ConfigManager.shared.config
                        ) {
                            newDocument.documentCategory = DocumentCategory.salary.rawValue
                        }
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
        .sheet(isPresented: $showingBulkPaidSheet) {
            MarkAsPaidSheet(
                selectedDate: $bulkPaidDate,
                onConfirm: {
                    markDocumentsAsPaid(ids: bulkPaidIDs, paidDate: bulkPaidDate)
                    bulkPaidIDs.removeAll()
                    showingBulkPaidSheet = false
                },
                onCancel: {
                    bulkPaidIDs.removeAll()
                    showingBulkPaidSheet = false
                }
            )
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
        .task {
            migrateExternalDocuments()
        }
        .alert("Document Storage Migration", isPresented: $showingMigrationResult) {
            Button("OK") { }
        } message: {
            if let result = migrationResult {
                Text(result.summary)
            }
        }
    }

    /// On first launch, copy any externally-referenced files into managed storage
    /// so we don't lose them if the originals are moved later.
    private func migrateExternalDocuments() {
        let docsToMigrate = allDocuments.filter { doc in
            guard let path = doc.documentPath else { return false }
            return !DocumentStorageService.isManagedPath(path)
        }

        guard !docsToMigrate.isEmpty else { return }

        var migrated = 0
        var missing = 0

        for doc in docsToMigrate {
            guard let path = doc.documentPath else { continue }

            if FileManager.default.fileExists(atPath: path) {
                let sourceURL = URL(fileURLWithPath: path)
                if let newPath = try? DocumentStorageService.copyFile(from: sourceURL, documentId: doc.id) {
                    doc.documentPath = newPath
                    doc.updatedAt = Date()
                    migrated += 1
                }
            } else if doc.status != .paid {
                // Don't nag about missing files for paid/archived invoices
                missing += 1
            }
        }

        if migrated > 0 || missing > 0 {
            migrationResult = MigrationResult(migrated: migrated, missing: missing)
            showingMigrationResult = true
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

            // Copy into managed storage while we still have security-scoped access
            let documentId = UUID()
            let storedURL: URL
            do {
                let storedPath = try DocumentStorageService.copyFile(from: url, documentId: documentId)
                storedURL = URL(fileURLWithPath: storedPath)
            } catch {
                url.stopAccessingSecurityScopedResource()
                importError = "Failed to copy file: \(error.localizedDescription)"
                showingImportError = true
                isProcessingDrop = false
                return
            }

            url.stopAccessingSecurityScopedResource()

            Task {
                await processDroppedPDF(at: storedURL, documentId: documentId)
            }

        case .failure(let error):
            importError = error.localizedDescription
            showingImportError = true
        }
    }

    private func handlePDFDrop(providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }

        isProcessingDrop = true
        pendingDropCount = providers.count
        newlyDroppedDocumentIDs = []

        for provider in providers {
            provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { url, error in
                guard let url = url else {
                    if let error = error {
                        DispatchQueue.main.async {
                            importError = error.localizedDescription
                            showingImportError = true
                            pendingDropCount -= 1
                            if pendingDropCount == 0 {
                                isProcessingDrop = false
                            }
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
                        pendingDropCount -= 1
                        if pendingDropCount == 0 {
                            isProcessingDrop = false
                        }
                    }
                    return
                }

                Task {
                    await processDroppedPDF(at: tempCopy)
                    await MainActor.run {
                        pendingDropCount -= 1
                        if pendingDropCount == 0 {
                            isProcessingDrop = false
                            // Select the first newly dropped document to show its preview
                            if let firstNewID = newlyDroppedDocumentIDs.first {
                                selectedDocuments = [firstNewID]
                            }
                        }
                    }
                }
            }
        }
    }

    private func processDroppedPDF(at url: URL, documentId: UUID? = nil) async {
        do {
            // Step 1: Run OCR on the PDF
            let ocrResult = try await ocrService.processDocument(at: url)

            // A salary PDF can bundle several payslips (one per page): when two or
            // more pages each read as a payslip, import every page as its own entry
            let config = ConfigManager.shared.config
            if SalarySlipDetector.isSalarySlip(
                filename: url.lastPathComponent,
                text: ocrResult.fullText,
                config: config
            ) {
                let slipPages = SalarySlipDetector.salaryPages(in: ocrResult, config: config)
                if slipPages.count >= 2 {
                    var pageSlips: [(page: OCRPageResult, entities: ExtractedEntities?)] = []
                    for page in slipPages {
                        pageSlips.append((page, try? await entityService.extractEntities(from: page.fullText)))
                    }

                    await MainActor.run {
                        withAnimation {
                            let baseName = url.deletingPathExtension().lastPathComponent
                            for slip in pageSlips {
                                let docId = UUID()
                                // Each entry keeps its own copy so deleting one never
                                // orphans the file another entry points to
                                let storedPath = (try? DocumentStorageService.copyFile(from: url, documentId: docId))
                                    ?? url.path
                                let newDocument = RFFDocument(
                                    id: docId,
                                    title: "\(baseName) – page \(slip.page.pageIndex + 1)",
                                    requestingOrganization: slip.entities?.organizationName ?? "Unknown Organization",
                                    amount: slip.entities?.amount ?? Decimal(0),
                                    currency: slip.entities?.currency ?? .usd,
                                    dueDate: slip.entities?.dueDate ?? Date(),
                                    extractedText: slip.page.fullText,
                                    documentPath: storedPath
                                )
                                newDocument.documentCategory = DocumentCategory.salary.rawValue
                                modelContext.insert(newDocument)
                                newlyDroppedDocumentIDs.append(newDocument.id)
                            }
                        }
                    }
                    return
                }
            }

            // Step 2: Extract entities (org, amount, due date)
            let entities = try await entityService.extractEntities(from: ocrResult)

            // Step 3: Create RFFDocument with extracted data
            await MainActor.run {
                withAnimation {
                    let docId = documentId ?? UUID()

                    // Copy file into app storage (skip if already there, e.g. from file import)
                    let storedPath: String
                    if DocumentStorageService.isManagedPath(url.path) {
                        storedPath = url.path
                    } else {
                        do {
                            storedPath = try DocumentStorageService.copyFile(from: url, documentId: docId)
                        } catch {
                            storedPath = url.path // fallback to original if copy fails
                        }
                    }

                    let newDocument = RFFDocument(
                        id: docId,
                        title: generateTitle(from: entities, url: url),
                        requestingOrganization: entities.organizationName ?? "Unknown Organization",
                        amount: entities.amount ?? Decimal(0),
                        currency: entities.currency ?? .usd,
                        dueDate: entities.dueDate ?? Date().addingTimeInterval(30 * 24 * 60 * 60),
                        extractedText: ocrResult.fullText,
                        documentPath: storedPath
                    )
                    if SalarySlipDetector.isSalarySlip(
                        filename: url.lastPathComponent,
                        text: ocrResult.fullText,
                        config: ConfigManager.shared.config
                    ) {
                        newDocument.documentCategory = DocumentCategory.salary.rawValue
                    }
                    modelContext.insert(newDocument)
                    newlyDroppedDocumentIDs.append(newDocument.id)

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
                importError = "Failed to process invoice: \(error.localizedDescription)"
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
        }
    }

    /// Segment label with a live badge on Inbox when documents wait there
    private func filterLabel(for filter: DocumentFilter) -> String {
        if filter == .inbox && !inboxDocuments.isEmpty {
            return "● Inbox \(inboxDocuments.count)"
        }
        return filter.rawValue
    }

    private var emptyStateTitle: String {
        switch selectedFilter {
        case .inbox:
            return "No Pending Documents"
        case .confirmed:
            return "No Confirmed Documents"
        case .paid:
            return "No Paid Documents"
        default:
            return ""
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
        default:
            return "doc"
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
        default:
            return ""
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
        case .jpy, .cny:
            return .orange
        case .sek, .nok, .dkk:
            return .cyan
        case .aud, .nzd:
            return .teal
        case .cad:
            return .mint
        default:
            return .gray
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

    /// Confirm every given document still in the inbox state
    private func confirmDocuments(ids: Set<RFFDocument.ID>) {
        let now = Date()
        withAnimation {
            for document in allDocuments where ids.contains(document.id)
                && (document.status == .pending || document.status == .underReview) {
                document.confirmedOrganization = document.requestingOrganization
                document.confirmedAmount = document.amount
                document.confirmedDueDate = document.dueDate
                document.confirmedAt = now
                document.status = .approved
                document.updatedAt = now

                NotificationCenter.default.post(
                    name: .documentStatusChanged,
                    object: nil,
                    userInfo: ["documentId": document.id, "status": RFFStatus.approved]
                )
            }
            selectedDocuments.removeAll()
            selectedDocument = nil
        }
    }

    /// Mark every given confirmed document as paid on the chosen date
    private func markDocumentsAsPaid(ids: Set<RFFDocument.ID>, paidDate: Date) {
        withAnimation {
            for document in allDocuments where ids.contains(document.id)
                && (document.status == .approved || document.status == .completed) {
                document.paidDate = paidDate
                document.status = .paid
                document.updatedAt = Date()

                NotificationCenter.default.post(
                    name: .documentStatusChanged,
                    object: nil,
                    userInfo: ["documentId": document.id, "status": RFFStatus.paid]
                )
            }
            selectedDocuments.removeAll()
            selectedDocument = nil
        }
    }

    // MARK: - Batch AI Analysis

    private func performBatchAIAnalysis(documentIds: Set<RFFDocument.ID>, provider: AIProvider? = nil) {
        // Get documents with extracted text
        let docsToAnalyze = documents.filter { doc in
            documentIds.contains(doc.id) && !(doc.extractedText ?? "").isEmpty
        }

        guard !docsToAnalyze.isEmpty else { return }

        // Build array of (id, text) tuples
        let docData = docsToAnalyze.compactMap { doc -> (id: UUID, text: String)? in
            guard let text = doc.extractedText, !text.isEmpty else { return nil }
            return (id: doc.id, text: text)
        }

        Task {
            await AIAnalysisProgressManager.shared.startBatchAnalysis(documents: docData, provider: provider)
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
                let fileExtension = imageType.preferredFilenameExtension ?? "png"
                provider.loadDataRepresentation(forTypeIdentifier: imageType.identifier) { data, error in
                    Task { @MainActor in
                        if let data = data {
                            pastedImageExtension = fileExtension
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

// MARK: - AI Batch Progress Bar

/// Progress bar shown during batch AI analysis
struct AIBatchProgressBar: View {
    private var progressManager: AIAnalysisProgressManager { AIAnalysisProgressManager.shared }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 4) {
                Text("Analyzing \(progressManager.batchCompleted + 1) of \(progressManager.batchTotal) documents...")
                    .font(.caption)
                    .fontWeight(.medium)

                ProgressView(value: progressManager.batchProgress)
                    .progressViewStyle(.linear)
            }

            Text("\(Int(progressManager.batchProgress * 100))%")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

// MARK: - Status Badge

/// LED-style status: a signal dot plus a mono word.
/// One palette app-wide: green ok · amber needs-you/late · red overdue · gray inert.
struct StatusBadge: View {
    let status: RFFStatus
    /// Days the payment was late (0 = on time)
    var paidDaysLate: Int? = nil

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(ledColor)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.5)
            if status == .paid, let daysLate = paidDaysLate, daysLate > 0 {
                Text("· \(daysLate)D LATE")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Signal.amber)
            }
        }
        .help(paidHelp)
    }

    private var label: String {
        status.rawValue.replacingOccurrences(of: "_", with: " ").uppercased()
    }

    private var paidHelp: String {
        guard status == .paid else { return "" }
        guard let daysLate = paidDaysLate, daysLate > 0 else { return "Paid on time" }
        return "Paid \(daysLate) day\(daysLate == 1 ? "" : "s") after the due date"
    }

    private var ledColor: Color {
        switch status {
        case .pending:
            return Signal.gray
        case .underReview:
            return Signal.amber
        case .approved, .completed:
            return Signal.green
        case .rejected:
            return Signal.red
        case .paid:
            return (paidDaysLate ?? 0) > 0 ? Signal.amber : Signal.green
        }
    }
}

struct DocumentDetailView: View {
    @Bindable var document: RFFDocument
    @Environment(\.modelContext) private var modelContext
    @State private var pdfDocument: PDFDocument?
    @State private var documentImage: NSImage?  // For non-PDF images (screenshots, etc.)
    @State private var highlights: [HighlightRegion] = []
    @State private var selectedHighlight: HighlightRegion?
    @State private var isDetectingFields = false
    @State private var showConfirmationPanel = true
    @State private var isPreviewExpanded = false  // Preview collapsed by default
    @State private var showingConfirmationAlert = false
    @State private var showingValidationError = false
    @State private var validationErrors: [String] = []

    // Mark as Paid state
    @State private var showingPaidSheet = false
    @State private var selectedPaidDate = Date()

    // Un-confirm state
    @State private var showingUnconfirmAlert = false

    // Schema Editor state
    @State private var showingSchemaEditor = false

    // AI Analysis state (using global AIAnalysisProgressManager for progress tracking)
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

    /// Original path shown when the file is missing (moved/deleted)
    @State private var missingFilePath: String?

    private let textFinder = PDFTextFinder()
    private let schemaExtractionService = SchemaExtractionService.shared

    /// Whether the document is a PDF (vs an image like PNG, JPEG, etc.)
    private var isPDF: Bool {
        guard let path = document.documentPath else { return false }
        return URL(fileURLWithPath: path).pathExtension.lowercased() == "pdf"
    }

    /// Check if document can be confirmed (is in inbox state)
    private var canConfirm: Bool {
        document.status == .pending || document.status == .underReview
    }

    /// Check if document can be marked as paid (is in confirmed state)
    private var canMarkAsPaid: Bool {
        document.status == .approved || document.status == .completed
    }

    /// Check if document can be un-confirmed (is in confirmed state but not paid)
    private var canUnconfirm: Bool {
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

    /// Un-confirm the document: clear confirmed values and move back to inbox
    private func unconfirmDocument() {
        // Clear confirmed values
        document.confirmedOrganization = nil
        document.confirmedAmount = nil
        document.confirmedDueDate = nil
        document.confirmedAt = nil

        // Transition status back to pending
        document.status = .pending
        document.updatedAt = Date()

        // Post notification for UI updates
        NotificationCenter.default.post(
            name: .documentStatusChanged,
            object: nil,
            userInfo: ["documentId": document.id, "status": RFFStatus.pending]
        )
    }

    var body: some View {
        Group {
            if document.documentPath != nil {
                if isEditingSchema {
                    // Inline schema editor mode
                    InlineSchemaEditorView(
                        document: document,
                        isEditing: $isEditingSchema
                    )
                } else {
                    // Normal review mode - vertical layout with preview on top, form below
                    VStack(spacing: 0) {
                        // Top: Collapsible PDF Viewer with highlight controls
                        VStack(spacing: 0) {
                            HStack {
                                // Expand/collapse toggle
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        isPreviewExpanded.toggle()
                                    }
                                } label: {
                                    Label(
                                        isPreviewExpanded ? "Collapse Preview" : "Expand Preview",
                                        systemImage: isPreviewExpanded ? "chevron.up" : "chevron.down"
                                    )
                                }

                                Divider()
                                    .frame(height: 20)

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

                                Divider()
                                    .frame(height: 20)

                                // AI Analysis menu with Cloud and On-Device options
                                Menu {
                                    Button {
                                        performAIAnalysis()
                                    } label: {
                                        Label("Analyze with Claude", systemImage: "cloud")
                                    }

                                    if #available(macOS 26, *) {
                                        Button {
                                            performAIAnalysis(using: .foundation)
                                        } label: {
                                            Label("Analyze with Apple Intelligence", systemImage: "desktopcomputer")
                                        }
                                    }

                                    Button {
                                        performAIAnalysis(using: .ollama)
                                    } label: {
                                        Label("Analyze with Ollama", systemImage: "cpu")
                                    }
                                } label: {
                                    if AIAnalysisProgressManager.shared.isAnalyzing(documentId: document.id) {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Label("AI Analyze", systemImage: "sparkles")
                                    }
                                }
                                .disabled(AIAnalysisProgressManager.shared.isAnalyzing(documentId: document.id) || (document.extractedText ?? "").isEmpty)

                                if document.documentCategory == DocumentCategory.salary.rawValue {
                                    Divider()
                                        .frame(height: 20)
                                    SalaryTag()
                                }

                                Spacer()
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)

                            Divider()

                            // File path bar — always visible
                            if let path = document.documentPath {
                                DocumentPathBar(path: path, documentId: document.id) { newPath in
                                    document.documentPath = newPath
                                    document.updatedAt = Date()
                                    missingFilePath = nil
                                    loadDocument()
                                }
                                Divider()
                            }

                            // Preview content (collapsible)
                            if isPreviewExpanded {
                                VStack(spacing: 0) {
                                    // Fixed legend header (only for PDFs with detected fields)
                                    if isPDF && !highlights.isEmpty {
                                        HighlightLegendView()
                                        Divider()
                                    }

                                    if isPDF {
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
                                    } else if let image = documentImage {
                                        // Image preview for non-PDF documents (screenshots, etc.)
                                        ZoomableImageView(image: image)
                                    } else if let missing = missingFilePath {
                                        ContentUnavailableView {
                                            Label("File Not Found", systemImage: "questionmark.folder")
                                        } description: {
                                            Text("The original file has been moved or deleted.\n\(missing)")
                                        } actions: {
                                            Button("Copy Path") {
                                                NSPasteboard.general.clearContents()
                                                NSPasteboard.general.setString(missing, forType: .string)
                                            }
                                        }
                                    } else {
                                        ContentUnavailableView(
                                            "Unable to Load Document",
                                            systemImage: "doc.questionmark",
                                            description: Text("The document could not be loaded")
                                        )
                                    }
                                }
                                .frame(minHeight: 300, maxHeight: 400)

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
                            } else {
                                // Collapsed preview - show thumbnail
                                HStack {
                                    if let pdf = pdfDocument, let page = pdf.page(at: 0) {
                                        // PDF thumbnail
                                        let thumb = page.thumbnail(of: CGSize(width: 120, height: 160), for: .mediaBox)
                                        Image(nsImage: thumb)
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(height: 80)
                                            .cornerRadius(4)
                                            .shadow(radius: 2)
                                    } else if let image = documentImage {
                                        // Image thumbnail (screenshots, etc.)
                                        Image(nsImage: image)
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(height: 80)
                                            .cornerRadius(4)
                                            .shadow(radius: 2)
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Document Preview")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text("Click 'Expand Preview' to view full document")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                }
                                .padding()
                                .background(Color(nsColor: .controlBackgroundColor))
                            }
                        }

                        Divider()

                        // Bottom: Confirmation form panel with line items
                        ScrollView {
                            VStack(spacing: 0) {
                                ConfirmationFormView(document: document)

                                // Line Items section
                                if !document.lineItems.isEmpty {
                                    Divider()
                                    LineItemsSection(document: document)
                                }
                            }
                        }
                    }
                }
            } else {
                // No PDF - show confirmation form only with line items
                ScrollView {
                    VStack(spacing: 0) {
                        ConfirmationFormView(document: document)

                        // Line Items section
                        if !document.lineItems.isEmpty {
                            Divider()
                            LineItemsSection(document: document)
                        }
                    }
                }
            }
        }
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

                if canUnconfirm {
                    Button {
                        showingUnconfirmAlert = true
                    } label: {
                        Label("Un-confirm", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
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
        .alert("Un-confirm Document", isPresented: $showingUnconfirmAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Un-confirm", role: .destructive) {
                unconfirmDocument()
            }
        } message: {
            Text("Move this document back to the Inbox for editing? The confirmed values will be cleared.")
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
            loadDocument()
            loadSchemaName()
            loadAvailableSchemas()
            checkForAIResults()
            // Auto-expand preview for confirmed invoices (ready to pay)
            if document.status == .approved {
                isPreviewExpanded = true
            }
        }
        .onChange(of: AIAnalysisProgressManager.shared.isAnalyzing(documentId: document.id)) { _, isAnalyzing in
            // Check for results when analysis completes
            if !isAnalyzing {
                checkForAIResults()
            }
        }
    }

    private func loadDocument() {
        guard var path = document.documentPath else { return }

        // Migrate: if file is not in managed storage, try to copy it in
        if !DocumentStorageService.isManagedPath(path) {
            let sourceURL = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                if let newPath = try? DocumentStorageService.copyFile(from: sourceURL, documentId: document.id) {
                    document.documentPath = newPath
                    document.updatedAt = Date()
                    path = newPath
                }
            } else {
                // Original file is gone — show its path so the user knows where it was
                missingFilePath = path
                return
            }
        }

        // Check managed file still exists (shouldn't happen, but be safe)
        guard FileManager.default.fileExists(atPath: path) else {
            missingFilePath = path
            return
        }

        let url = URL(fileURLWithPath: path)

        if isPDF {
            pdfDocument = PDFDocument(url: url)
            documentImage = nil
            // Auto-detect fields when PDF loads
            detectAllFields()
        } else {
            // Load as image (PNG, JPEG, TIFF, etc.)
            documentImage = NSImage(contentsOf: url)
            pdfDocument = nil
            highlights = []  // Image field detection not yet supported
        }
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
        let formatters: [DateFormatter] = {
            let formats = ["MM/dd/yyyy", "M/d/yyyy", "yyyy-MM-dd", "MMMM d, yyyy", "MMM d, yyyy"]
            return formats.map { format in
                let formatter = DateFormatter()
                formatter.dateFormat = format
                return formatter
            }
        }()

        for formatter in formatters {
            if let date = formatter.date(from: text) {
                return date
            }
        }
        return nil
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
        performAIAnalysis(using: nil)
    }

    private func performAIAnalysis(using provider: AIProvider?) {
        guard let extractedText = document.extractedText, !extractedText.isEmpty else {
            aiErrorMessage = "No extracted text available. Import a document first."
            showingAIError = true
            return
        }

        Task {
            await AIAnalysisProgressManager.shared.startAnalysis(
                documentId: document.id,
                text: extractedText,
                provider: provider
            )
        }
    }

    /// Check for completed AI analysis results from the global progress manager
    private func checkForAIResults() {
        let progressManager = AIAnalysisProgressManager.shared

        // Check for results
        if let result = progressManager.result(for: document.id) {
            aiAnalysisResult = result
            showingAIResults = true
            progressManager.clearResult(for: document.id)
        }

        // Check for errors
        if let error = progressManager.error(for: document.id) {
            aiErrorMessage = error
            showingAIError = true
            progressManager.clearError(for: document.id)
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

// MARK: - Line Items Section

/// Displays line items for the document in a collapsible section
struct LineItemsSection: View {
    let document: RFFDocument
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Line Items (\(document.lineItems.count))")
                        .font(.headline)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding()

            if isExpanded {
                Divider()
                    .padding(.horizontal)

                VStack(spacing: 0) {
                    ForEach(document.lineItems) { item in
                        HStack {
                            Text(item.itemDescription)
                                .lineLimit(2)
                            Spacer()
                            Text(item.total, format: .currency(code: document.currency.currencyCode))
                                .fontWeight(.medium)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)

                        if item.id != document.lineItems.last?.id {
                            Divider()
                                .padding(.horizontal)
                        }
                    }
                }
                .padding(.bottom)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
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

            // Editable value
            TextField("Value", text: $editedValue)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 150)

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
                Label("Apply", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(editedValue.isEmpty)

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
// MARK: - Salary Tag

/// Small capsule marking a document as a salary slip
struct SalaryTag: View {
    var body: some View {
        Text("SALARY")
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(0.5)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.purple.opacity(0.16), in: Capsule())
            .foregroundStyle(.purple)
            .help("Salary slip")
    }
}

// MARK: - Zoomable Image Preview

/// Image preview with pinch-to-zoom and explicit zoom controls.
/// Zoom 1.0 = fit to the visible area; larger values scroll.
struct ZoomableImageView: View {
    let image: NSImage

    @State private var zoom: CGFloat = 1.0
    @State private var pinchBaseZoom: CGFloat?

    private static let minZoom: CGFloat = 0.25
    private static let maxZoom: CGFloat = 8.0

    var body: some View {
        GeometryReader { proxy in
            let fitScale = min(
                proxy.size.width / max(image.size.width, 1),
                proxy.size.height / max(image.size.height, 1),
                1
            )
            let scale = fitScale * zoom

            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(
                        width: image.size.width * scale,
                        height: image.size.height * scale
                    )
                    // Center the image while it is smaller than the viewport
                    .frame(
                        minWidth: proxy.size.width,
                        minHeight: proxy.size.height
                    )
            }
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        if pinchBaseZoom == nil { pinchBaseZoom = zoom }
                        zoom = clampZoom((pinchBaseZoom ?? 1) * value)
                    }
                    .onEnded { _ in pinchBaseZoom = nil }
            )
            .overlay(alignment: .bottomTrailing) {
                zoomControls(fitScale: fitScale)
            }
        }
    }

    private func zoomControls(fitScale: CGFloat) -> some View {
        HStack(spacing: 6) {
            Button {
                zoom = clampZoom(zoom / 1.25)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom out")

            Text("\(Int(zoom * 100))%")
                .font(.caption.monospacedDigit())
                .frame(minWidth: 40)

            Button {
                zoom = clampZoom(zoom * 1.25)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom in")

            Divider()
                .frame(height: 14)

            Button("Fit") {
                zoom = 1.0
            }
            .help("Fit to window")

            Button("100%") {
                zoom = clampZoom(1 / max(fitScale, 0.001))
            }
            .help("Actual size")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .padding(12)
    }

    private func clampZoom(_ value: CGFloat) -> CGFloat {
        min(Self.maxZoom, max(Self.minZoom, value))
    }
}

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
    /// Maps suggestion ID to the selected option ID (for fields with multiple options)
    @State private var selectedOptions: [UUID: UUID] = [:]

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
                            isSelected: selectedSuggestions.contains(suggestion.id),
                            selectedOptionId: selectedOptionBinding(for: suggestion)
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
            // Pre-select high confidence suggestions and their primary options
            for suggestion in result.suggestions where suggestion.confidence >= 0.7 {
                selectedSuggestions.insert(suggestion.id)
                if let primaryOption = suggestion.options.first {
                    selectedOptions[suggestion.id] = primaryOption.id
                }
            }
        }
    }

    /// Creates a binding for the selected option ID for a given suggestion
    private func selectedOptionBinding(for suggestion: AIFieldSuggestion) -> Binding<UUID?> {
        Binding(
            get: { selectedOptions[suggestion.id] ?? suggestion.options.first?.id },
            set: { newValue in
                if let newValue = newValue {
                    selectedOptions[suggestion.id] = newValue
                }
            }
        )
    }

    /// Gets the selected option for a suggestion, defaulting to the primary (first) option
    private func getSelectedOption(for suggestion: AIFieldSuggestion) -> AIFieldOption? {
        if let selectedId = selectedOptions[suggestion.id] {
            return suggestion.options.first { $0.id == selectedId }
        }
        return suggestion.options.first
    }

    private func applySelectedSuggestions() {
        let selectedItems = result.suggestions.filter { selectedSuggestions.contains($0.id) }

        for suggestion in selectedItems {
            if let option = getSelectedOption(for: suggestion) {
                applyFieldSuggestion(suggestion, option: option)
            }
        }

        // Save schema if suggested
        if let schemaName = result.suggestedSchemaName, !schemaName.isEmpty {
            saveSchema(name: schemaName, suggestions: selectedItems)
        }

        document.updatedAt = Date()
        onDismiss()
    }

    private func applyFieldSuggestion(_ suggestion: AIFieldSuggestion, option: AIFieldOption) {
        let value = option.value
        switch suggestion.fieldType {
        case "vendor":
            document.requestingOrganization = value
        case "recipient", "customer_name":
            document.recipient = value
        case "total":
            if let amount = Decimal(string: value) {
                document.amount = amount
            }
        case "due_date":
            if let date = parseISODate(value) {
                document.dueDate = date
            }
        case "currency":
            if let currency = Currency(rawValue: value.uppercased()) {
                document.currency = currency
            }
        case "invoice_number":
            if document.title == "New Document" || document.title.isEmpty {
                document.title = "Invoice \(value)"
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
}

struct LibraryAISuggestionRow: View {
    let suggestion: AIFieldSuggestion
    let isSelected: Bool
    @Binding var selectedOptionId: UUID?

    /// The currently selected option (defaults to first/primary option)
    private var selectedOption: AIFieldOption? {
        if let id = selectedOptionId {
            return suggestion.options.first { $0.id == id }
        }
        return suggestion.options.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Field header with name
            HStack {
                Text(displayName(for: suggestion.fieldType))
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                if suggestion.hasAlternatives {
                    Text("\(suggestion.options.count) options")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Options - show as selectable list if multiple
            if suggestion.hasAlternatives {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(suggestion.options) { option in
                        LibraryAIOptionRow(
                            option: option,
                            isSelected: option.id == selectedOptionId || (selectedOptionId == nil && option.id == suggestion.options.first?.id),
                            isFieldSelected: isSelected
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedOptionId = option.id
                        }
                    }
                }
            } else if let option = suggestion.options.first {
                // Single option - show inline
                HStack {
                    Text(option.value)
                        .font(.body)
                        .foregroundStyle(isSelected ? .primary : .secondary)

                    Spacer()

                    LibraryConfidenceBadge(confidence: option.confidence)
                }

                if let reasoning = option.reasoning {
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
        case "recipient", "customer_name": return "Recipient"
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

/// Row for a single AI field option (used when field has multiple options)
struct LibraryAIOptionRow: View {
    let option: AIFieldOption
    let isSelected: Bool
    let isFieldSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            // Selection indicator
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? .blue : .secondary)
                .font(.caption)

            // Value
            Text(option.value)
                .font(.callout)
                .foregroundStyle(isSelected && isFieldSelected ? .primary : .secondary)

            Spacer()

            // Confidence badge
            LibraryConfidenceBadge(confidence: option.confidence)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
        .cornerRadius(4)
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
        case "recipient", "customer_name": return "Recipient"
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
