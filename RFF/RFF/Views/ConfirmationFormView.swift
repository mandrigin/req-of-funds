import SwiftUI
import SwiftData

/// Tracks whether a field value was auto-extracted or manually edited
enum FieldSource: Equatable {
    case extracted    // Value came from OCR/AI extraction
    case manual       // Value was manually entered/edited by user
}

/// A single editable field with extraction source indicator
struct ConfirmationField<Content: View>: View {
    let label: String
    let source: FieldSource
    let content: () -> Content

    init(label: String, source: FieldSource, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.source = source
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                SourceBadge(source: source)
            }

            content()
        }
    }
}

/// Visual indicator showing if a field was auto-extracted or manually edited
struct SourceBadge: View {
    let source: FieldSource

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: source == .extracted ? "wand.and.stars" : "pencil")
                .font(.system(size: 9))

            Text(source == .extracted ? "Auto" : "Edited")
                .font(.system(size: 9, weight: .medium))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            source == .extracted
                ? Color.blue.opacity(0.15)
                : Color.orange.opacity(0.15),
            in: Capsule()
        )
        .foregroundStyle(source == .extracted ? .blue : .orange)
    }
}

/// DocuSign-style editable confirmation form for extracted document fields
struct ConfirmationFormView: View {
    @Bindable var document: RFFDocument
    @Environment(\.modelContext) private var modelContext

    // Track original values to detect manual edits
    @State private var originalOrganization: String = ""
    @State private var originalAmount: Decimal = 0
    @State private var originalCurrency: Currency = .usd
    @State private var originalDueDate: Date = Date()

    // Track which fields have been manually edited
    @State private var organizationSource: FieldSource = .extracted
    @State private var amountSource: FieldSource = .extracted
    @State private var currencySource: FieldSource = .extracted
    @State private var dueDateSource: FieldSource = .extracted

    // Local editing state
    @State private var editingOrganization: String = ""
    @State private var editingAmount: Decimal = 0
    @State private var editingCurrency: Currency = .usd
    @State private var editingDueDate: Date = Date()

    @State private var showingConfirmation = false
    @State private var isConfirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            header

            Divider()

            // Form fields
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    organizationField
                    amountField
                    currencyField
                    dueDateField
                }
                .padding()
            }

            Divider()

            // Footer with confirm button
            footer
        }
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear {
            initializeFields()
        }
        .alert("Confirm Document", isPresented: $showingConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Confirm") {
                confirmDocument()
            }
        } message: {
            Text("Mark this document as confirmed? The extracted values will be saved and the document will be moved to review.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.blue)
                Text("Confirm Details")
                    .font(.headline)
            }

            Text("Review and edit the extracted information below.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - Organization Field

    private var organizationField: some View {
        ConfirmationField(label: "Organization", source: organizationSource) {
            TextField("Organization name", text: $editingOrganization)
                .textFieldStyle(.roundedBorder)
                .onChange(of: editingOrganization) { _, newValue in
                    if newValue != originalOrganization {
                        organizationSource = .manual
                    }
                    document.requestingOrganization = newValue
                }
        }
    }

    // MARK: - Amount Field

    private var amountField: some View {
        ConfirmationField(label: "Amount", source: amountSource) {
            HStack {
                Text(editingCurrency.symbol)
                    .foregroundStyle(.secondary)
                TextField("0.00", value: $editingAmount, format: .number.precision(.fractionLength(2)))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: editingAmount) { _, newValue in
                        if newValue != originalAmount {
                            amountSource = .manual
                        }
                        document.amount = newValue
                    }
            }
        }
    }

    // MARK: - Currency Field

    private var currencyField: some View {
        ConfirmationField(label: "Currency", source: currencySource) {
            Picker("", selection: $editingCurrency) {
                ForEach(Currency.allCases, id: \.self) { currency in
                    Text("\(currency.symbol) \(currency.displayName)")
                        .tag(currency)
                }
            }
            .labelsHidden()
            .onChange(of: editingCurrency) { _, newValue in
                if newValue != originalCurrency {
                    currencySource = .manual
                }
                document.currency = newValue
            }
        }
    }

    // MARK: - Due Date Field

    private var dueDateField: some View {
        ConfirmationField(label: "Due Date", source: dueDateSource) {
            DatePicker("", selection: $editingDueDate, displayedComponents: [.date])
                .datePickerStyle(.field)
                .labelsHidden()
                .onChange(of: editingDueDate) { _, newValue in
                    // Check if date changed by more than 1 day (to account for time component)
                    let calendar = Calendar.current
                    if !calendar.isDate(newValue, inSameDayAs: originalDueDate) {
                        dueDateSource = .manual
                    }
                    document.dueDate = newValue
                }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 12) {
            // Summary of changes
            if hasEdits {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                    Text(editSummary)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }

            // Confirm button
            Button {
                showingConfirmation = true
            } label: {
                HStack {
                    if isConfirming {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    Text("Confirm & Submit")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isConfirming || !isValid)
        }
        .padding()
    }

    // MARK: - Helpers

    private var hasEdits: Bool {
        organizationSource == .manual || amountSource == .manual || currencySource == .manual || dueDateSource == .manual
    }

    private var editSummary: String {
        var edited: [String] = []
        if organizationSource == .manual { edited.append("organization") }
        if amountSource == .manual { edited.append("amount") }
        if currencySource == .manual { edited.append("currency") }
        if dueDateSource == .manual { edited.append("due date") }

        if edited.isEmpty {
            return "All values auto-extracted"
        } else {
            return "Edited: \(edited.joined(separator: ", "))"
        }
    }

    private var isValid: Bool {
        !editingOrganization.trimmingCharacters(in: .whitespaces).isEmpty &&
        editingAmount >= 0
    }

    private func initializeFields() {
        // Store original values for edit detection
        originalOrganization = document.requestingOrganization
        originalAmount = document.amount
        originalCurrency = document.currency
        originalDueDate = document.dueDate

        // Initialize editing state
        editingOrganization = document.requestingOrganization
        editingAmount = document.amount
        editingCurrency = document.currency
        editingDueDate = document.dueDate

        // Assume values are extracted initially
        // (In a full implementation, this could come from document metadata)
        organizationSource = .extracted
        amountSource = .extracted
        currencySource = .extracted
        dueDateSource = .extracted
    }

    private func confirmDocument() {
        isConfirming = true

        // Record corrections for learning
        Task {
            await recordCorrections()
        }

        // Update document status to underReview
        document.status = .underReview
        document.updatedAt = Date()

        // Save changes
        do {
            try modelContext.save()
        } catch {
            print("Failed to save document: \(error)")
        }

        isConfirming = false
    }

    private func recordCorrections() async {
        let correctionService = CorrectionHistoryService.shared

        // Record organization correction if edited
        if organizationSource == .manual && editingOrganization != originalOrganization {
            let correction = FieldCorrection(
                schemaId: nil,
                fieldType: .vendor,
                originalValue: originalOrganization,
                correctedValue: editingOrganization,
                originalConfidence: 0.5,
                wasCompleteReplacement: originalOrganization.isEmpty,
                documentId: document.id
            )
            try? await correctionService.recordCorrection(correction)
        } else {
            await correctionService.recordConfirmation(schemaId: nil, fieldType: .vendor)
        }

        // Record amount correction if edited
        if amountSource == .manual && editingAmount != originalAmount {
            let correction = FieldCorrection(
                schemaId: nil,
                fieldType: .total,
                originalValue: "\(originalAmount)",
                correctedValue: "\(editingAmount)",
                originalConfidence: 0.5,
                wasCompleteReplacement: originalAmount == 0,
                documentId: document.id
            )
            try? await correctionService.recordCorrection(correction)
        } else {
            await correctionService.recordConfirmation(schemaId: nil, fieldType: .total)
        }

        // Record due date correction if edited
        let calendar = Calendar.current
        if dueDateSource == .manual && !calendar.isDate(editingDueDate, inSameDayAs: originalDueDate) {
            let formatter = ISO8601DateFormatter()
            let correction = FieldCorrection(
                schemaId: nil,
                fieldType: .dueDate,
                originalValue: formatter.string(from: originalDueDate),
                correctedValue: formatter.string(from: editingDueDate),
                originalConfidence: 0.5,
                wasCompleteReplacement: false,
                documentId: document.id
            )
            try? await correctionService.recordCorrection(correction)
        } else {
            await correctionService.recordConfirmation(schemaId: nil, fieldType: .dueDate)
        }

        // Track extractions for accuracy statistics
        correctionService.recordExtraction(fieldType: .vendor)
        correctionService.recordExtraction(fieldType: .total)
        correctionService.recordExtraction(fieldType: .dueDate)
    }
}

#Preview {
    @Previewable @State var sampleDoc = {
        let doc = RFFDocument(
            title: "Sample Invoice",
            requestingOrganization: "Acme Corporation",
            amount: Decimal(1234.56),
            dueDate: Date().addingTimeInterval(30 * 24 * 60 * 60)
        )
        return doc
    }()

    ConfirmationFormView(document: sampleDoc)
        .modelContainer(for: RFFDocument.self, inMemory: true)
        .frame(width: 320, height: 500)
}
