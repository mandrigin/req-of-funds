import SwiftUI
import UniformTypeIdentifiers

/// Main editor view for RFF documents using Table view
struct DocumentEditorView: View {
    @Binding var document: RFFFileDocument
    @State private var selectedLineItems: Set<RFFDocumentData.LineItemData.ID> = []
    @State private var isImporting = false
    @State private var isProcessingDrop = false
    @State private var showingAddLineItem = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationSplitView {
            // Sidebar with document info
            DocumentInfoSidebar(document: $document.data)
                .frame(minWidth: 250)
        } detail: {
            // Main content with table view
            VStack(spacing: 0) {
                // Line items table
                LineItemsTableView(
                    lineItems: $document.data.lineItems,
                    selection: $selectedLineItems,
                    currency: document.data.currency
                )

                Divider()

                // Bottom bar with totals and actions
                BottomBar(document: $document.data, selectedCount: selectedLineItems.count) {
                    deleteSelectedItems()
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingAddLineItem = true
                } label: {
                    Label("Add Line Item", systemImage: "plus")
                }

                Button {
                    isImporting = true
                } label: {
                    Label("Import PDF", systemImage: "doc.badge.plus")
                }
            }
        }
        .sheet(isPresented: $showingAddLineItem) {
            AddLineItemSheet(lineItems: $document.data.lineItems, currency: document.data.currency)
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.pdf, .png, .jpeg, .tiff],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .dropDestination(for: RFFDocumentData.self) { items, _ in
            guard let first = items.first else { return false }
            document.data = first
            return true
        }
        .overlay {
            if isProcessingDrop {
                ProcessingOverlay()
            }
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            if let error = errorMessage {
                Text(error)
            }
        }
    }

    private func deleteSelectedItems() {
        document.data.lineItems.removeAll { selectedLineItems.contains($0.id) }
        selectedLineItems.removeAll()
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            isProcessingDrop = true

            Task {
                do {
                    let hasAccess = url.startAccessingSecurityScopedResource()
                    defer {
                        if hasAccess { url.stopAccessingSecurityScopedResource() }
                    }

                    let ocrService = DocumentOCRService()
                    let ocrResult = try await ocrService.processDocument(at: url)

                    let extractor = EntityExtractionService()
                    let entities = try await extractor.extractEntities(from: ocrResult.fullText)

                    await MainActor.run {
                        document.data.extractedText = ocrResult.fullText
                        if document.data.requestingOrganization.isEmpty {
                            document.data.requestingOrganization = entities.organizationName ?? ""
                        }
                        if document.data.amount == Decimal.zero {
                            document.data.amount = entities.amount ?? Decimal.zero
                            // Also set currency when updating amount
                            if let currency = entities.currency {
                                document.data.currency = currency
                            }
                        }
                        if let dueDate = entities.dueDate {
                            document.data.dueDate = dueDate
                        }

                        // Add bookmark
                        if let bookmarkData = try? url.bookmarkData(
                            options: .withSecurityScope,
                            includingResourceValuesForKeys: nil,
                            relativeTo: nil
                        ) {
                            document.data.attachedFiles.append(
                                RFFDocumentData.AttachedFileData(
                                    id: UUID(),
                                    filename: url.lastPathComponent,
                                    bookmarkData: bookmarkData,
                                    addedAt: Date()
                                )
                            )
                        }

                        isProcessingDrop = false
                    }
                } catch {
                    await MainActor.run {
                        errorMessage = error.localizedDescription
                        isProcessingDrop = false
                    }
                }
            }

        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Document Info Sidebar

struct DocumentInfoSidebar: View {
    @Binding var document: RFFDocumentData

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        Form {
            Section("Document") {
                TextField("Title", text: $document.title)
                TextField("Organization", text: $document.requestingOrganization)
            }

            Section("Financial") {
                Picker("Currency", selection: $document.currency) {
                    ForEach(Currency.allCases) { currency in
                        Text("\(currency.symbol) \(currency.displayName)").tag(currency)
                    }
                }

                HStack {
                    Text("Amount")
                    Spacer()
                    TextField("Amount", value: $document.amount, format: .currency(code: document.currency.currencyCode))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 120)
                }

                HStack {
                    Text("Total (Line Items)")
                    Spacer()
                    Text(document.totalAmount, format: .currency(code: document.currency.currencyCode))
                        .foregroundStyle(.secondary)
                }
            }

            Section("Timeline") {
                DatePicker("Due Date", selection: $document.dueDate, displayedComponents: [.date])

                LabeledContent("Status") {
                    Picker("", selection: $document.status) {
                        Text("Pending").tag("pending")
                        Text("Under Review").tag("under_review")
                        Text("Approved").tag("approved")
                        Text("Rejected").tag("rejected")
                        Text("Completed").tag("completed")
                    }
                    .labelsHidden()
                }
            }

            Section("Metadata") {
                LabeledContent("Created", value: dateFormatter.string(from: document.createdAt))
                LabeledContent("Updated", value: dateFormatter.string(from: document.updatedAt))
            }

            if !document.attachedFiles.isEmpty {
                Section("Attached Files") {
                    ForEach(document.attachedFiles) { file in
                        HStack {
                            Image(systemName: "doc.fill")
                            Text(file.filename)
                            Spacer()
                            Text(dateFormatter.string(from: file.addedAt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let extractedText = document.extractedText, !extractedText.isEmpty {
                Section("Extracted Text") {
                    Text(extractedText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(10)
                }
            }

            Section("Notes") {
                TextEditor(text: Binding(
                    get: { document.notes ?? "" },
                    set: { document.notes = $0.isEmpty ? nil : $0 }
                ))
                .frame(minHeight: 100)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Line Items Table View

struct LineItemsTableView: View {
    @Binding var lineItems: [RFFDocumentData.LineItemData]
    @Binding var selection: Set<RFFDocumentData.LineItemData.ID>
    let currency: Currency

    var body: some View {
        Table(lineItems, selection: $selection) {
            TableColumn("Description") { item in
                Text(item.itemDescription)
            }
            .width(min: 200, ideal: 300)

            TableColumn("Category") { item in
                Text(item.category ?? "—")
                    .foregroundStyle(item.category == nil ? .secondary : .primary)
            }
            .width(min: 100, ideal: 150)

            TableColumn("Qty") { item in
                Text("\(item.quantity)")
                    .monospacedDigit()
            }
            .width(50)

            TableColumn("Unit Price") { item in
                Text(item.unitPrice, format: .currency(code: currency.currencyCode))
                    .monospacedDigit()
            }
            .width(100)

            TableColumn("Total") { item in
                Text(item.total, format: .currency(code: currency.currencyCode))
                    .monospacedDigit()
                    .fontWeight(.medium)
            }
            .width(100)
        }
        .contextMenu(forSelectionType: RFFDocumentData.LineItemData.ID.self) { ids in
            if !ids.isEmpty {
                Button("Delete", role: .destructive) {
                    lineItems.removeAll { ids.contains($0.id) }
                    selection.subtract(ids)
                }
            }
        }
    }
}

// MARK: - Bottom Bar

struct BottomBar: View {
    @Binding var document: RFFDocumentData
    let selectedCount: Int
    let onDelete: () -> Void

    var body: some View {
        HStack {
            if selectedCount > 0 {
                Text("\(selectedCount) selected")
                    .foregroundStyle(.secondary)

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.borderless)
            }

            Spacer()

            VStack(alignment: .trailing) {
                Text("Line Items Total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(document.totalAmount, format: .currency(code: document.currency.currencyCode))
                    .font(.title2)
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
        }
        .padding()
    }
}

// MARK: - Add Line Item Sheet

struct AddLineItemSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var lineItems: [RFFDocumentData.LineItemData]
    let currency: Currency

    @State private var description = ""
    @State private var quantity = 1
    @State private var unitPrice = Decimal.zero
    @State private var category = ""

    var body: some View {
        VStack(spacing: 20) {
            Text("Add Line Item")
                .font(.headline)

            Form {
                TextField("Description", text: $description)
                TextField("Category", text: $category)

                HStack {
                    Text("Quantity")
                    Spacer()
                    TextField("Qty", value: $quantity, format: .number)
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: $quantity, in: 1...9999)
                        .labelsHidden()
                }

                HStack {
                    Text("Unit Price")
                    Spacer()
                    TextField("Price", value: $unitPrice, format: .currency(code: currency.currencyCode))
                        .frame(width: 120)
                        .multilineTextAlignment(.trailing)
                }
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Add") {
                    let item = RFFDocumentData.LineItemData(
                        id: UUID(),
                        itemDescription: description,
                        quantity: quantity,
                        unitPrice: unitPrice,
                        category: category.isEmpty ? nil : category,
                        notes: nil
                    )
                    lineItems.append(item)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(description.isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
    }
}

// MARK: - Processing Overlay

struct ProcessingOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)
                Text("Processing document...")
                    .font(.headline)
            }
            .padding(32)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

#Preview {
    DocumentEditorView(document: .constant(RFFFileDocument()))
}
