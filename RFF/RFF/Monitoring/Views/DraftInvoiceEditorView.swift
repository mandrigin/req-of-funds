import SwiftUI

/// View for editing and reviewing draft invoices before sending
struct DraftInvoiceEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var scheduler = InvoiceScheduler.shared

    let draft: DraftInvoice

    @State private var editedDraft: DraftInvoice
    @State private var showingPreview = false
    @State private var showingAddLineItem = false
    @State private var editingLineItem: InvoiceLineItem?
    @State private var showingDiscardConfirmation = false
    @State private var showingFolderPicker = false
    @State private var pendingExportAction: (() -> Void)?
    @State private var nextGenerationDate: Date?

    init(draft: DraftInvoice) {
        self.draft = draft
        self._editedDraft = State(initialValue: draft)
    }

    var body: some View {
        HSplitView {
            // Editor panel
            editorPanel
                .frame(minWidth: 450, maxWidth: 550)

            // Preview panel
            previewPanel
                .frame(minWidth: 400)
        }
        .frame(width: 1000, height: 750)
        .sheet(isPresented: $showingAddLineItem) {
            LineItemEditorView(
                lineItem: editingLineItem,
                currency: editedDraft.currency
            ) { item in
                if let index = editedDraft.lineItems.firstIndex(where: { $0.id == item.id }) {
                    editedDraft.lineItems[index] = item
                } else {
                    editedDraft.lineItems.append(item)
                }
            }
        }
        .sheet(isPresented: $showingFolderPicker) {
            ExportFolderPickerView(
                monitoredPaths: ConfigManager.shared.config.monitoredPaths
            ) { selectedPath in
                performExport(to: selectedPath)
            }
        }
    }

    private var editorPanel: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("Edit Draft Invoice")
                        .font(.headline)
                    Text(editedDraft.invoiceNumber)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                statusBadge
            }
            .padding()

            Divider()

            // Form
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Dates
                    GroupBox("Dates") {
                        VStack(alignment: .leading, spacing: 12) {
                            DatePicker(
                                "Issue Date",
                                selection: $editedDraft.issueDate,
                                displayedComponents: .date
                            )
                            .onChange(of: editedDraft.issueDate) { _ in
                                recalculatePaymentTerms()
                            }
                            DatePicker(
                                "Due Date",
                                selection: $editedDraft.dueDate,
                                displayedComponents: .date
                            )
                            .onChange(of: editedDraft.dueDate) { _ in
                                recalculatePaymentTerms()
                            }

                            // Display due date adjustment explanation if present
                            if let explanation = editedDraft.dueDateAdjustmentExplanation {
                                Text(explanation)
                                    .font(.caption)
                                    .foregroundColor(.orange)
                                    .padding(.vertical, 2)
                            }

                            // Display calculated payment terms
                            Text("Payment Terms: \(editedDraft.paymentTerms.displayText)")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            // Display next auto-generation date
                            if let nextDate = nextGenerationDate {
                                let formatter = DateFormatter()
                                let _ = formatter.dateFormat = "MMM d, yyyy"
                                Text("Next invoice will be auto-generated on \(formatter.string(from: nextDate))")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                                    .padding(.top, 4)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .onAppear {
                        loadNextGenerationDate()
                    }

                    // Line Items
                    GroupBox("Line Items") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(editedDraft.lineItems) { item in
                                LineItemRow(
                                    item: item,
                                    currency: editedDraft.currency
                                ) {
                                    editingLineItem = item
                                    showingAddLineItem = true
                                } onDelete: {
                                    editedDraft.lineItems.removeAll { $0.id == item.id }
                                }
                            }

                            Divider()

                            HStack {
                                Button(action: {
                                    editingLineItem = nil
                                    showingAddLineItem = true
                                }) {
                                    Label("Add Line Item", systemImage: "plus")
                                }

                                Spacer()

                                VStack(alignment: .trailing) {
                                    Text("Subtotal: \(editedDraft.currency.format(editedDraft.subtotal))")
                                    Text("Total: \(editedDraft.currency.format(editedDraft.total))")
                                        .fontWeight(.bold)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }

                    // Notes
                    GroupBox("Notes") {
                        TextEditor(text: Binding(
                            get: { editedDraft.notes ?? "" },
                            set: { editedDraft.notes = $0.isEmpty ? nil : $0 }
                        ))
                        .frame(height: 80)
                        .border(Color.gray.opacity(0.3))
                        .padding(.vertical, 8)
                    }
                }
                .padding()
            }

            Divider()

            // Actions
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                if editedDraft.status == .pending {
                    Button("Discard Draft", role: .destructive) {
                        showingDiscardConfirmation = true
                    }
                }

                Spacer()

                if editedDraft.status == .pending {
                    Button("Save Draft") {
                        saveDraft()
                    }

                    Button("Approve") {
                        approveDraft()
                    }
                    .buttonStyle(.borderedProminent)
                }

                if editedDraft.status == .approved {
                    Button("Mark as Sent") {
                        markAsSent()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .alert("Discard Draft Invoice?", isPresented: $showingDiscardConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Discard", role: .destructive) {
                discardDraft()
            }
        } message: {
            Text("Are you sure you want to discard invoice \(editedDraft.invoiceNumber)? This action cannot be undone.")
        }
    }

    private var previewPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Preview")
                    .font(.headline)
                Spacer()
                Button(action: exportPDF) {
                    Label("Export PDF", systemImage: "arrow.down.doc")
                }
            }
            .padding()

            Divider()

            ScrollView {
                InvoicePreviewView(invoice: editedDraft)
                    .padding()
            }
            .background(Color.gray.opacity(0.1))
        }
    }

    private var statusBadge: some View {
        Text(editedDraft.status.rawValue.capitalized)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(statusColor.opacity(0.2))
            .foregroundColor(statusColor)
            .cornerRadius(4)
    }

    private var statusColor: Color {
        switch editedDraft.status {
        case .pending: return .orange
        case .approved: return .blue
        case .sent: return .green
        case .cancelled: return .red
        }
    }

    private func saveDraft() {
        scheduler.updateDraft(editedDraft)
        dismiss()
    }

    private func approveDraft() {
        scheduler.updateDraft(editedDraft)
        scheduler.approveDraft(editedDraft)
        dismiss()
    }

    private func markAsSent() {
        scheduler.markDraftAsSent(editedDraft)
        dismiss()
    }

    private func discardDraft() {
        scheduler.deleteDraft(editedDraft)
        dismiss()
    }

    private func exportPDF() {
        let config = ConfigManager.shared.config
        let monitoredPaths = config.monitoredPaths

        // If multiple monitored paths exist, show picker
        if monitoredPaths.count > 1 {
            pendingExportAction = nil  // Will be set when user picks
            showingFolderPicker = true
            return
        }

        // Use first monitored path, or fall back to Documents if none configured
        let destinationRoot: URL
        if let firstPath = monitoredPaths.first {
            destinationRoot = firstPath.path
        } else if let configuredRoot = config.destinationRoot {
            destinationRoot = configuredRoot
        } else {
            destinationRoot = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        }

        performExport(to: destinationRoot)
    }

    private func performExport(to destinationRoot: URL) {
        // 1. Generate filename from invoice number
        let sanitizedNumber = editedDraft.invoiceNumber
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let filename = "\(sanitizedNumber).pdf"

        // 2. Determine destination folder using Organizer pattern
        let organizer = Organizer.fromConfig()
        let folderName = organizer.invoiceFolderName(for: editedDraft.issueDate)

        let destinationFolder = destinationRoot.appendingPathComponent(folderName)
        let destinationPath = destinationFolder.appendingPathComponent(filename)

        // 3. Ensure destination folder exists
        do {
            try FileManager.default.createDirectory(
                at: destinationFolder,
                withIntermediateDirectories: true
            )
        } catch {
            print("Failed to create destination folder: \(error)")
            return
        }

        // 4. Render invoice to PDF using ImageRenderer
        let previewView = InvoicePreviewView(invoice: editedDraft)
            .frame(width: 612, height: 792) // US Letter size at 72 DPI

        let renderer = ImageRenderer(content: previewView)
        renderer.scale = 2.0 // Higher resolution

        // Handle potential filename collision
        var finalPath = destinationPath
        var counter = 1
        while FileManager.default.fileExists(atPath: finalPath.path) {
            let nameWithoutExt = sanitizedNumber
            finalPath = destinationFolder.appendingPathComponent("\(nameWithoutExt)-\(counter).pdf")
            counter += 1
        }

        // Render to PDF
        renderer.render { size, renderContext in
            var mediaBox = CGRect(origin: .zero, size: size)
            guard let context = CGContext(finalPath as CFURL, mediaBox: &mediaBox, nil) else {
                print("Failed to create PDF context")
                return
            }

            context.beginPDFPage(nil)
            renderContext(context)
            context.endPDFPage()
            context.closePDF()
        }

        // 5. Reveal in Finder
        NSWorkspace.shared.selectFile(finalPath.path, inFileViewerRootedAtPath: destinationFolder.path)
    }

    /// Recalculate payment terms based on the difference between due date and issue date.
    /// This preserves the user's intended due date rather than calculating it from payment terms.
    private func recalculatePaymentTerms() {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.day], from: editedDraft.issueDate, to: editedDraft.dueDate)
        let days = max(0, components.day ?? 0)
        editedDraft.paymentTerms.daysUntilDue = days
    }

    private func loadNextGenerationDate() {
        // Find the template for this draft
        guard let template = scheduler.templates.first(where: { $0.id == draft.templateId }),
              template.isActive else {
            return
        }

        // Use fallback for immediate display
        nextGenerationDate = scheduler.calculateNextGenerationDateFallback(for: template)

        // Then update with async result (includes bank holidays)
        scheduler.calculateNextGenerationDate(for: template) { result in
            DispatchQueue.main.async {
                if case .success(let date) = result {
                    nextGenerationDate = date
                }
            }
        }
    }
}

// MARK: - Invoice Preview

struct InvoicePreviewView: View {
    let invoice: DraftInvoice

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Header
            HStack(alignment: .top) {
                // Sender
                VStack(alignment: .leading, spacing: 4) {
                    if let company = invoice.sender.company {
                        Text(company)
                            .font(.title2)
                            .fontWeight(.bold)
                    }
                    Text(invoice.sender.name)
                    if let addr = invoice.sender.addressLine1 {
                        Text(addr)
                    }
                    if let addr = invoice.sender.addressLine2 {
                        Text(addr)
                    }
                    Text(cityStatePostal(invoice.sender))
                    if let email = invoice.sender.email {
                        Text(email)
                    }
                    if let taxId = invoice.sender.taxId {
                        Text("Tax ID: \(taxId)")
                    }
                }
                .font(.caption)

                Spacer()

                // Invoice info
                VStack(alignment: .trailing, spacing: 4) {
                    Text("INVOICE")
                        .font(.title)
                        .fontWeight(.bold)
                    Text(invoice.invoiceNumber)
                        .font(.headline)

                    Spacer().frame(height: 16)

                    HStack {
                        Text("Issue Date:")
                        Text(dateFormatter.string(from: invoice.issueDate))
                    }
                    HStack {
                        Text("Due Date:")
                        Text(dateFormatter.string(from: invoice.dueDate))
                            .fontWeight(.semibold)
                    }
                }
            }

            Divider()

            // Bill To
            VStack(alignment: .leading, spacing: 4) {
                Text("BILL TO")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let company = invoice.recipient.company {
                    Text(company)
                        .fontWeight(.semibold)
                }
                Text(invoice.recipient.name)
                if let addr = invoice.recipient.addressLine1 {
                    Text(addr)
                }
                if let addr = invoice.recipient.addressLine2 {
                    Text(addr)
                }
                Text(cityStatePostal(invoice.recipient))
            }
            .font(.caption)

            // Line Items Table
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Description")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Qty")
                        .frame(width: 60, alignment: .trailing)
                    Text("Rate")
                        .frame(width: 80, alignment: .trailing)
                    Text("Amount")
                        .frame(width: 80, alignment: .trailing)
                }
                .font(.caption)
                .fontWeight(.semibold)
                .padding(.vertical, 8)
                .background(Color.gray.opacity(0.2))

                // Items
                ForEach(invoice.lineItems) { item in
                    HStack {
                        Text(item.description)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(item.quantity as NSDecimalNumber)")
                            .frame(width: 60, alignment: .trailing)
                        Text(invoice.currency.format(item.unitPrice))
                            .frame(width: 80, alignment: .trailing)
                        Text(invoice.currency.format(item.total))
                            .frame(width: 80, alignment: .trailing)
                    }
                    .font(.caption)
                    .padding(.vertical, 6)

                    Divider()
                }

                // Totals
                HStack {
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        HStack {
                            Text("Subtotal:")
                            Text(invoice.currency.format(invoice.subtotal))
                                .frame(width: 80, alignment: .trailing)
                        }
                        HStack {
                            Text("Total:")
                                .fontWeight(.bold)
                            Text(invoice.currency.format(invoice.total))
                                .fontWeight(.bold)
                                .frame(width: 80, alignment: .trailing)
                        }
                    }
                    .font(.caption)
                    .padding(.top, 8)
                }
            }

            // Notes
            if let notes = invoice.notes, !notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notes")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text(notes)
                        .font(.caption)
                }
            }

            // Terms
            if let terms = invoice.terms, !terms.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Terms & Conditions")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text(terms)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Payment info
            VStack(alignment: .leading, spacing: 4) {
                Text("Payment Terms: \(invoice.paymentTerms.displayText)")
                    .font(.caption)
                    .fontWeight(.semibold)
                if let instructions = invoice.paymentTerms.paymentInstructions {
                    Text(instructions)
                        .font(.caption)
                }
            }

            // Bank transfer details - where to send the money
            if let bank = invoice.bankDetails, bank.isComplete {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PAYMENT DETAILS")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 2) {
                        GridRow {
                            Text("Account Holder").foregroundColor(.secondary)
                            Text(bank.accountHolder)
                        }
                        if !bank.bankName.isEmpty {
                            GridRow {
                                Text("Bank").foregroundColor(.secondary)
                                Text(bank.bankName)
                            }
                        }
                        GridRow {
                            Text("IBAN").foregroundColor(.secondary)
                            Text(bank.iban).fontWeight(.semibold)
                        }
                        if !bank.bic.isEmpty {
                            GridRow {
                                Text("BIC / SWIFT").foregroundColor(.secondary)
                                Text(bank.bic)
                            }
                        }
                        if let address = bank.bankAddress, !address.isEmpty {
                            GridRow {
                                Text("Bank Address").foregroundColor(.secondary)
                                Text(address)
                            }
                        }
                        GridRow {
                            Text("Reference").foregroundColor(.secondary)
                            Text(bank.paymentReference ?? invoice.invoiceNumber)
                                .fontWeight(.semibold)
                        }
                    }
                    .font(.caption)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.08))
                .cornerRadius(4)
            }

            Spacer()
        }
        .padding(24)
        .background(Color.white)
        .cornerRadius(4)
        .shadow(radius: 2)
    }

    private func cityStatePostal(_ contact: ContactDetails) -> String {
        var parts: [String] = []
        if let city = contact.city { parts.append(city) }
        if let state = contact.state { parts.append(state) }
        if let postal = contact.postalCode { parts.append(postal) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Drafts List View

struct DraftsListView: View {
    @ObservedObject private var scheduler = InvoiceScheduler.shared
    @State private var selectedDraft: DraftInvoice?
    @State private var showingEditor = false
    @State private var filterStatus: DraftInvoiceStatus?
    @State private var draftToDelete: DraftInvoice?
    @State private var showingDeleteConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            // Filter bar
            HStack {
                Text("Draft Invoices")
                    .font(.headline)

                Spacer()

                Picker("Filter", selection: $filterStatus) {
                    Text("All").tag(nil as DraftInvoiceStatus?)
                    Text("Pending").tag(DraftInvoiceStatus.pending as DraftInvoiceStatus?)
                    Text("Approved").tag(DraftInvoiceStatus.approved as DraftInvoiceStatus?)
                    Text("Sent").tag(DraftInvoiceStatus.sent as DraftInvoiceStatus?)
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
            }
            .padding()

            Divider()

            // List
            if filteredDrafts.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No draft invoices")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredDrafts, selection: $selectedDraft) { draft in
                    DraftInvoiceRow(draft: draft)
                        .tag(draft)
                        .contextMenu {
                            Button("Edit") {
                                selectedDraft = draft
                                showingEditor = true
                            }
                            Divider()
                            if draft.status == .pending {
                                Button("Cancel Draft") {
                                    scheduler.cancelDraft(draft)
                                }
                            }
                            Button("Delete", role: .destructive) {
                                draftToDelete = draft
                                showingDeleteConfirmation = true
                            }
                        }
                }
            }
        }
        .onChange(of: selectedDraft) { draft in
            if draft != nil {
                showingEditor = true
            }
        }
        .sheet(isPresented: $showingEditor) {
            if let draft = selectedDraft {
                DraftInvoiceEditorView(draft: draft)
            }
        }
        .alert("Delete Draft Invoice?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                draftToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let draft = draftToDelete {
                    scheduler.deleteDraft(draft)
                }
                draftToDelete = nil
            }
        } message: {
            if let draft = draftToDelete {
                Text("Are you sure you want to permanently delete invoice \(draft.invoiceNumber)? This action cannot be undone.")
            }
        }
    }

    private var filteredDrafts: [DraftInvoice] {
        if let status = filterStatus {
            return scheduler.draftInvoices.filter { $0.status == status }
        }
        return scheduler.draftInvoices
    }
}

struct DraftInvoiceRow: View {
    let draft: DraftInvoice

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        return f
    }()

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(draft.invoiceNumber)
                        .fontWeight(.medium)
                    statusBadge
                }
                Text(draft.recipient.company ?? draft.recipient.name)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(draft.currency.format(draft.total))
                    .fontWeight(.medium)
                HStack(spacing: 4) {
                    Text("Due: \(dateFormatter.string(from: draft.dueDate))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if draft.dueDateAdjustmentExplanation != nil {
                        Image(systemName: "info.circle")
                            .font(.caption)
                            .foregroundColor(.orange)
                            .help(draft.dueDateAdjustmentExplanation ?? "")
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var statusBadge: some View {
        Text(draft.status.rawValue.capitalized)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusColor.opacity(0.2))
            .foregroundColor(statusColor)
            .cornerRadius(4)
    }

    private var statusColor: Color {
        switch draft.status {
        case .pending: return .orange
        case .approved: return .blue
        case .sent: return .green
        case .cancelled: return .red
        }
    }
}

// MARK: - Export Folder Picker

struct ExportFolderPickerView: View {
    @Environment(\.dismiss) private var dismiss

    let monitoredPaths: [MonitoredPath]
    let onSelect: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Choose Export Folder")
                    .font(.headline)
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            // Folder list
            List(monitoredPaths, id: \.path) { monitoredPath in
                Button(action: {
                    dismiss()
                    onSelect(monitoredPath.path)
                }) {
                    HStack {
                        Image(systemName: "folder")
                            .foregroundColor(.blue)
                        VStack(alignment: .leading) {
                            Text(monitoredPath.path.lastPathComponent)
                                .fontWeight(.medium)
                            Text(monitoredPath.path.path)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 400, height: 300)
    }
}
