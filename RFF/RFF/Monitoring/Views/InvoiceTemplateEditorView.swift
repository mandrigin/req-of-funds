import SwiftUI

/// View for creating and editing invoice templates
struct InvoiceTemplateEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var scheduler = InvoiceScheduler.shared
    @ObservedObject private var configManager = ConfigManager.shared

    let template: InvoiceTemplate?
    let onSave: ((InvoiceTemplate) -> Void)?

    // Form state
    @State private var name: String = ""
    @State private var selectedClient: String = ""
    @State private var invoiceNumberPrefix: String = ""
    @State private var currency: InvoiceCurrency = .usd
    @State private var lineItems: [InvoiceLineItem] = []
    @State private var notes: String = ""
    @State private var terms: String = ""
    @State private var billingDay: Int = 1
    @State private var isActive: Bool = true

    // Sender details
    @State private var senderName: String = ""
    @State private var senderCompany: String = ""
    @State private var senderAddress1: String = ""
    @State private var senderAddress2: String = ""
    @State private var senderCity: String = ""
    @State private var senderState: String = ""
    @State private var senderPostal: String = ""
    @State private var senderCountry: String = "US"
    @State private var senderEmail: String = ""
    @State private var senderPhone: String = ""
    @State private var senderTaxId: String = ""

    // Recipient details
    @State private var recipientName: String = ""
    @State private var recipientCompany: String = ""
    @State private var recipientAddress1: String = ""
    @State private var recipientAddress2: String = ""
    @State private var recipientCity: String = ""
    @State private var recipientState: String = ""
    @State private var recipientPostal: String = ""
    @State private var recipientCountry: String = "US"
    @State private var recipientEmail: String = ""

    // Payment terms
    @State private var paymentDays: Int = 30

    // Bank details (where the money goes)
    @State private var bankAccountHolder: String = ""
    @State private var bankName: String = ""
    @State private var bankIBAN: String = ""
    @State private var bankBIC: String = ""
    @State private var bankAddress: String = ""

    // Line item editing
    @State private var showingAddLineItem = false
    @State private var editingLineItem: InvoiceLineItem?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(template == nil ? "New Invoice Template" : "Edit Template")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { saveTemplate() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding()

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Basic Info
                    GroupBox("Template Info") {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("Template Name", text: $name)
                                .textFieldStyle(.roundedBorder)

                            if configManager.companies.isEmpty {
                                HStack {
                                    Text("No clients configured")
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text("Add in Preferences → Companies")
                                        .font(.caption)
                                        .foregroundColor(.blue)
                                }
                            } else {
                                Picker("Client", selection: $selectedClient) {
                                    Text("Select Client...").tag("")
                                    ForEach(configManager.companies, id: \.name) { company in
                                        Text(company.name).tag(company.name)
                                    }
                                }
                            }

                            HStack {
                                TextField("Invoice Number Prefix", text: $invoiceNumberPrefix)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 150)
                                Text("e.g., ACME → ACME-202601-001")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }

                            HStack {
                                Picker("InvoiceCurrency", selection: $currency) {
                                    ForEach(InvoiceCurrency.allCases) { curr in
                                        Text("\(curr.rawValue) - \(curr.name)").tag(curr)
                                    }
                                }
                                .frame(width: 250)

                                Spacer()

                                Toggle("Active", isOn: $isActive)
                            }

                            Stepper("Billing Day of Month: \(billingDay)", value: $billingDay, in: 1...28)

                            Stepper("Payment Terms: Net \(paymentDays)", value: $paymentDays, in: 1...120)
                        }
                        .padding(.vertical, 8)
                    }

                    // Bank details printed on the invoice
                    GroupBox("Payment Details (Bank Transfer)") {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("Account Holder (e.g., 0xFF Consulting GmbH)", text: $bankAccountHolder)
                                .textFieldStyle(.roundedBorder)
                            TextField("Bank Name", text: $bankName)
                                .textFieldStyle(.roundedBorder)
                            HStack {
                                TextField("IBAN", text: $bankIBAN)
                                    .textFieldStyle(.roundedBorder)
                                TextField("BIC / SWIFT", text: $bankBIC)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 160)
                            }
                            TextField("Bank Address (optional, for international transfers)", text: $bankAddress)
                                .textFieldStyle(.roundedBorder)
                            Text("Printed on every generated invoice. The payment reference defaults to the invoice number.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 8)
                    }

                    // Line Items
                    GroupBox("Line Items") {
                        VStack(alignment: .leading, spacing: 8) {
                            if lineItems.isEmpty {
                                Text("No line items added yet")
                                    .foregroundColor(.secondary)
                                    .padding()
                            } else {
                                ForEach(lineItems) { item in
                                    LineItemRow(item: item, currency: currency) {
                                        editingLineItem = item
                                        showingAddLineItem = true
                                    } onDelete: {
                                        lineItems.removeAll { $0.id == item.id }
                                    }
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

                                Text("Subtotal: \(currency.format(subtotal))")
                                    .fontWeight(.semibold)
                            }
                        }
                        .padding(.vertical, 8)
                    }

                    // Sender Details
                    GroupBox("Sender (Your) Details") {
                        ContactDetailsForm(
                            name: $senderName,
                            company: $senderCompany,
                            address1: $senderAddress1,
                            address2: $senderAddress2,
                            city: $senderCity,
                            state: $senderState,
                            postal: $senderPostal,
                            country: $senderCountry,
                            email: $senderEmail,
                            phone: $senderPhone,
                            taxId: $senderTaxId,
                            showTaxId: true,
                            showPhone: true
                        )
                    }

                    // Recipient Details
                    GroupBox("Recipient (Client) Details") {
                        ContactDetailsForm(
                            name: $recipientName,
                            company: $recipientCompany,
                            address1: $recipientAddress1,
                            address2: $recipientAddress2,
                            city: $recipientCity,
                            state: $recipientState,
                            postal: $recipientPostal,
                            country: $recipientCountry,
                            email: $recipientEmail,
                            phone: .constant(""),
                            taxId: .constant(""),
                            showTaxId: false,
                            showPhone: false
                        )
                    }

                    // Notes & Terms
                    GroupBox("Additional Details") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Notes (appears on invoice)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextEditor(text: $notes)
                                .frame(height: 60)
                                .border(Color.gray.opacity(0.3))

                            Text("Payment Terms & Conditions")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextEditor(text: $terms)
                                .frame(height: 60)
                                .border(Color.gray.opacity(0.3))
                        }
                        .padding(.vertical, 8)
                    }
                }
                .padding()
            }
        }
        .frame(width: 700, height: 800)
        .onAppear {
            loadTemplate()
        }
        .sheet(isPresented: $showingAddLineItem) {
            LineItemEditorView(
                lineItem: editingLineItem,
                currency: currency
            ) { item in
                if let index = lineItems.firstIndex(where: { $0.id == item.id }) {
                    lineItems[index] = item
                } else {
                    lineItems.append(item)
                }
            }
        }
    }

    private var subtotal: Decimal {
        lineItems.reduce(0) { $0 + $1.total }
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        (configManager.companies.isEmpty || !selectedClient.isEmpty) &&
        !senderName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func loadTemplate() {
        guard let template = template else { return }

        name = template.name
        selectedClient = template.clientCompanyName
        invoiceNumberPrefix = template.invoiceNumberPrefix ?? ""
        currency = template.currency
        lineItems = template.lineItems
        notes = template.notes ?? ""
        terms = template.terms ?? ""
        billingDay = template.billingDayOfMonth
        isActive = template.isActive
        paymentDays = template.paymentTerms.daysUntilDue

        // Bank details
        bankAccountHolder = template.bankDetails?.accountHolder ?? ""
        bankName = template.bankDetails?.bankName ?? ""
        bankIBAN = template.bankDetails?.iban ?? ""
        bankBIC = template.bankDetails?.bic ?? ""
        bankAddress = template.bankDetails?.bankAddress ?? ""

        // Sender
        senderName = template.sender.name
        senderCompany = template.sender.company ?? ""
        senderAddress1 = template.sender.addressLine1 ?? ""
        senderAddress2 = template.sender.addressLine2 ?? ""
        senderCity = template.sender.city ?? ""
        senderState = template.sender.state ?? ""
        senderPostal = template.sender.postalCode ?? ""
        senderCountry = template.sender.countryCode
        senderEmail = template.sender.email ?? ""
        senderPhone = template.sender.phone ?? ""
        senderTaxId = template.sender.taxId ?? ""

        // Recipient
        recipientName = template.recipient.name
        recipientCompany = template.recipient.company ?? ""
        recipientAddress1 = template.recipient.addressLine1 ?? ""
        recipientAddress2 = template.recipient.addressLine2 ?? ""
        recipientCity = template.recipient.city ?? ""
        recipientState = template.recipient.state ?? ""
        recipientPostal = template.recipient.postalCode ?? ""
        recipientCountry = template.recipient.countryCode
        recipientEmail = template.recipient.email ?? ""
    }

    private func saveTemplate() {
        let sender = ContactDetails(
            name: senderName,
            company: senderCompany.isEmpty ? nil : senderCompany,
            addressLine1: senderAddress1.isEmpty ? nil : senderAddress1,
            addressLine2: senderAddress2.isEmpty ? nil : senderAddress2,
            city: senderCity.isEmpty ? nil : senderCity,
            state: senderState.isEmpty ? nil : senderState,
            postalCode: senderPostal.isEmpty ? nil : senderPostal,
            countryCode: senderCountry,
            email: senderEmail.isEmpty ? nil : senderEmail,
            phone: senderPhone.isEmpty ? nil : senderPhone,
            taxId: senderTaxId.isEmpty ? nil : senderTaxId
        )

        let recipient = ContactDetails(
            name: recipientName,
            company: recipientCompany.isEmpty ? nil : recipientCompany,
            addressLine1: recipientAddress1.isEmpty ? nil : recipientAddress1,
            addressLine2: recipientAddress2.isEmpty ? nil : recipientAddress2,
            city: recipientCity.isEmpty ? nil : recipientCity,
            state: recipientState.isEmpty ? nil : recipientState,
            postalCode: recipientPostal.isEmpty ? nil : recipientPostal,
            countryCode: recipientCountry,
            email: recipientEmail.isEmpty ? nil : recipientEmail
        )

        let paymentTerms = PaymentTerms(daysUntilDue: paymentDays)

        let trimmedIBAN = bankIBAN.trimmingCharacters(in: .whitespaces)
        let bankDetails: BankDetails? = trimmedIBAN.isEmpty ? nil : BankDetails(
            accountHolder: bankAccountHolder.trimmingCharacters(in: .whitespaces),
            bankName: bankName.trimmingCharacters(in: .whitespaces),
            iban: trimmedIBAN,
            bic: bankBIC.trimmingCharacters(in: .whitespaces),
            bankAddress: bankAddress.isEmpty ? nil : bankAddress
        )

        let trimmedPrefix = invoiceNumberPrefix.trimmingCharacters(in: .whitespaces)
        var newTemplate = InvoiceTemplate(
            id: template?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            clientCompanyName: selectedClient,
            invoiceNumberPrefix: trimmedPrefix.isEmpty ? nil : trimmedPrefix,
            lineItems: lineItems,
            currency: currency,
            notes: notes.isEmpty ? nil : notes,
            terms: terms.isEmpty ? nil : terms,
            sender: sender,
            recipient: recipient,
            paymentTerms: paymentTerms,
            bankDetails: bankDetails,
            billingDayOfMonth: billingDay,
            isActive: isActive
        )

        if template != nil {
            newTemplate.createdAt = template!.createdAt
        }

        if let onSave = onSave {
            onSave(newTemplate)
        } else if template != nil {
            scheduler.updateTemplate(newTemplate)
        } else {
            scheduler.addTemplate(newTemplate)
        }

        dismiss()
    }
}

// MARK: - Line Item Row

struct LineItemRow: View {
    let item: InvoiceLineItem
    let currency: InvoiceCurrency
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.description)
                    .fontWeight(.medium)
                HStack(spacing: 8) {
                    Text("\(item.quantity as NSDecimalNumber) \(item.unit ?? "units")")
                    Text("@")
                    Text(currency.format(item.unitPrice))
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            Text(currency.format(item.total))
                .fontWeight(.medium)

            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)

            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundColor(.red)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Line Item Editor

struct LineItemEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let lineItem: InvoiceLineItem?
    let currency: InvoiceCurrency
    let onSave: (InvoiceLineItem) -> Void

    @State private var description: String = ""
    @State private var quantity: String = "1"
    @State private var unitPrice: String = ""
    @State private var unit: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Text(lineItem == nil ? "Add Line Item" : "Edit Line Item")
                .font(.headline)

            Form {
                TextField("Description", text: $description)
                TextField("Quantity", text: $quantity)
                TextField("Unit (optional, e.g., hours)", text: $unit)
                TextField("Unit Price (\(currency.symbol))", text: $unitPrice)
            }
            .formStyle(.grouped)

            if let total = calculatedTotal {
                Text("Total: \(currency.format(total))")
                    .font(.headline)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding()
        .frame(width: 400, height: 300)
        .onAppear {
            if let item = lineItem {
                description = item.description
                quantity = "\(item.quantity)"
                unitPrice = "\(item.unitPrice)"
                unit = item.unit ?? ""
            }
        }
    }

    private var calculatedTotal: Decimal? {
        guard let qty = Decimal(string: quantity),
              let price = Decimal(string: unitPrice) else { return nil }
        return qty * price
    }

    private var isValid: Bool {
        !description.trimmingCharacters(in: .whitespaces).isEmpty &&
        Decimal(string: quantity) != nil &&
        Decimal(string: unitPrice) != nil
    }

    private func save() {
        guard let qty = Decimal(string: quantity),
              let price = Decimal(string: unitPrice) else { return }

        let item = InvoiceLineItem(
            id: lineItem?.id ?? UUID(),
            description: description.trimmingCharacters(in: .whitespaces),
            quantity: qty,
            unitPrice: price,
            unit: unit.isEmpty ? nil : unit
        )

        onSave(item)
        dismiss()
    }
}

// MARK: - Contact Details Form

struct ContactDetailsForm: View {
    @Binding var name: String
    @Binding var company: String
    @Binding var address1: String
    @Binding var address2: String
    @Binding var city: String
    @Binding var state: String
    @Binding var postal: String
    @Binding var country: String
    @Binding var email: String
    @Binding var phone: String
    @Binding var taxId: String

    var showTaxId: Bool
    var showPhone: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                TextField("Company", text: $company)
                    .textFieldStyle(.roundedBorder)
            }

            TextField("Address Line 1", text: $address1)
                .textFieldStyle(.roundedBorder)
            TextField("Address Line 2", text: $address2)
                .textFieldStyle(.roundedBorder)

            HStack {
                TextField("City", text: $city)
                    .textFieldStyle(.roundedBorder)
                TextField("State/Province", text: $state)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                TextField("Postal", text: $postal)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
            }

            HStack {
                Picker("Country", selection: $country) {
                    Text("United States").tag("US")
                    Text("United Kingdom").tag("GB")
                    Text("Germany").tag("DE")
                    Text("France").tag("FR")
                    Text("Canada").tag("CA")
                    Text("Australia").tag("AU")
                    Text("Netherlands").tag("NL")
                    Text("Norway").tag("NO")
                    Text("Switzerland").tag("CH")
                    Text("Japan").tag("JP")
                    Text("Singapore").tag("SG")
                }
                .frame(width: 200)

                Spacer()
            }

            HStack {
                TextField("Email", text: $email)
                    .textFieldStyle(.roundedBorder)

                if showPhone {
                    TextField("Phone", text: $phone)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                }
            }

            if showTaxId {
                TextField("Tax ID (VAT/EIN)", text: $taxId)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }
        }
        .padding(.vertical, 8)
    }
}
