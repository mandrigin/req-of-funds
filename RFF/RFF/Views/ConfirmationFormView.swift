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
    @State private var originalRecipient: String = ""
    @State private var originalAmount: Decimal = 0
    @State private var originalCurrency: Currency = .usd
    @State private var originalDueDate: Date = Date()

    // Track which fields have been manually edited
    @State private var organizationSource: FieldSource = .extracted
    @State private var recipientSource: FieldSource = .extracted
    @State private var amountSource: FieldSource = .extracted
    @State private var currencySource: FieldSource = .extracted
    @State private var dueDateSource: FieldSource = .extracted

    // Local editing state
    @State private var editingOrganization: String = ""
    @State private var editingRecipient: String = ""
    @State private var editingAmount: Decimal = 0
    @State private var editingCurrency: Currency = .usd
    @State private var editingDueDate: Date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            header

            Divider()

            // Form fields
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    organizationField
                    recipientField
                    amountField
                    currencyField
                    dueDateField
                }
                .padding()
            }
        }
        .frame(minWidth: 280, maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear {
            initializeFields()
        }
        .onChange(of: document.id) { _, _ in
            initializeFields()
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

    // MARK: - Recipient Field

    private var recipientField: some View {
        ConfirmationField(label: "Recipient", source: recipientSource) {
            TextField("Recipient (who invoice is addressed to)", text: $editingRecipient)
                .textFieldStyle(.roundedBorder)
                .onChange(of: editingRecipient) { _, newValue in
                    if newValue != originalRecipient {
                        recipientSource = .manual
                    }
                    document.recipient = newValue.isEmpty ? nil : newValue
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

    // MARK: - Helpers

    private func initializeFields() {
        // Store original values for edit detection
        originalOrganization = document.requestingOrganization
        originalRecipient = document.recipient ?? ""
        originalAmount = document.amount
        originalCurrency = document.currency
        originalDueDate = document.dueDate

        // Initialize editing state
        editingOrganization = document.requestingOrganization
        editingRecipient = document.recipient ?? ""
        editingAmount = document.amount
        editingCurrency = document.currency
        editingDueDate = document.dueDate

        // Assume values are extracted initially
        // (In a full implementation, this could come from document metadata)
        organizationSource = .extracted
        recipientSource = .extracted
        amountSource = .extracted
        currencySource = .extracted
        dueDateSource = .extracted
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
