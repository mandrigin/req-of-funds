import Foundation

// MARK: - InvoiceCurrency

/// Supported currencies for invoices
enum InvoiceCurrency: String, Codable, CaseIterable, Identifiable {
    case usd = "USD"
    case eur = "EUR"
    case gbp = "GBP"
    case chf = "CHF"
    case jpy = "JPY"
    case cad = "CAD"
    case aud = "AUD"
    case nzd = "NZD"
    case sek = "SEK"
    case nok = "NOK"
    case dkk = "DKK"
    case pln = "PLN"
    case czk = "CZK"
    case huf = "HUF"
    case inr = "INR"
    case sgd = "SGD"
    case hkd = "HKD"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .usd, .cad, .aud, .nzd, .sgd, .hkd: return "$"
        case .eur: return "\u{20AC}"
        case .gbp: return "\u{00A3}"
        case .chf: return "CHF"
        case .jpy: return "\u{00A5}"
        case .sek, .nok, .dkk: return "kr"
        case .pln: return "z\u{0142}"
        case .czk: return "K\u{010D}"
        case .huf: return "Ft"
        case .inr: return "\u{20B9}"
        }
    }

    var name: String {
        switch self {
        case .usd: return "US Dollar"
        case .eur: return "Euro"
        case .gbp: return "British Pound"
        case .chf: return "Swiss Franc"
        case .jpy: return "Japanese Yen"
        case .cad: return "Canadian Dollar"
        case .aud: return "Australian Dollar"
        case .nzd: return "New Zealand Dollar"
        case .sek: return "Swedish Krona"
        case .nok: return "Norwegian Krone"
        case .dkk: return "Danish Krone"
        case .pln: return "Polish Zloty"
        case .czk: return "Czech Koruna"
        case .huf: return "Hungarian Forint"
        case .inr: return "Indian Rupee"
        case .sgd: return "Singapore Dollar"
        case .hkd: return "Hong Kong Dollar"
        }
    }

    /// Format an amount in this currency
    func format(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = rawValue
        return formatter.string(from: amount as NSDecimalNumber) ?? "\(symbol)\(amount)"
    }
}

// MARK: - Line Item

/// A single line item on an invoice
struct InvoiceLineItem: Codable, Equatable, Identifiable, Hashable {
    var id: UUID
    var description: String
    var quantity: Decimal
    var unitPrice: Decimal
    var unit: String?  // e.g., "hours", "units", "days"

    var total: Decimal {
        quantity * unitPrice
    }

    init(
        id: UUID = UUID(),
        description: String,
        quantity: Decimal = 1,
        unitPrice: Decimal,
        unit: String? = nil
    ) {
        self.id = id
        self.description = description
        self.quantity = quantity
        self.unitPrice = unitPrice
        self.unit = unit
    }
}

// MARK: - Contact Details

/// Contact information for sender or recipient
struct ContactDetails: Codable, Equatable, Hashable {
    var name: String
    var company: String?
    var addressLine1: String?
    var addressLine2: String?
    var city: String?
    var state: String?
    var postalCode: String?
    var countryCode: String  // ISO 3166-1 alpha-2
    var email: String?
    var phone: String?
    var taxId: String?  // VAT, EIN, etc.

    init(
        name: String,
        company: String? = nil,
        addressLine1: String? = nil,
        addressLine2: String? = nil,
        city: String? = nil,
        state: String? = nil,
        postalCode: String? = nil,
        countryCode: String = "US",
        email: String? = nil,
        phone: String? = nil,
        taxId: String? = nil
    ) {
        self.name = name
        self.company = company
        self.addressLine1 = addressLine1
        self.addressLine2 = addressLine2
        self.city = city
        self.state = state
        self.postalCode = postalCode
        self.countryCode = countryCode
        self.email = email
        self.phone = phone
        self.taxId = taxId
    }

    /// Formatted multi-line address
    var formattedAddress: String {
        var lines: [String] = []

        if let company = company, !company.isEmpty {
            lines.append(company)
        }
        lines.append(name)
        if let addr1 = addressLine1, !addr1.isEmpty {
            lines.append(addr1)
        }
        if let addr2 = addressLine2, !addr2.isEmpty {
            lines.append(addr2)
        }

        var cityLine = ""
        if let city = city { cityLine += city }
        if let state = state { cityLine += cityLine.isEmpty ? state : ", \(state)" }
        if let postal = postalCode { cityLine += " \(postal)" }
        if !cityLine.isEmpty { lines.append(cityLine) }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Payment Terms

/// Payment terms for an invoice
struct PaymentTerms: Codable, Equatable, Hashable {
    /// Number of days until payment is due
    var daysUntilDue: Int

    /// Optional early payment discount percentage
    var earlyPaymentDiscount: Decimal?

    /// Days for early payment discount
    var earlyPaymentDays: Int?

    /// Late payment fee percentage
    var lateFeePercentage: Decimal?

    /// Additional payment instructions
    var paymentInstructions: String?

    init(
        daysUntilDue: Int = 30,
        earlyPaymentDiscount: Decimal? = nil,
        earlyPaymentDays: Int? = nil,
        lateFeePercentage: Decimal? = nil,
        paymentInstructions: String? = nil
    ) {
        self.daysUntilDue = daysUntilDue
        self.earlyPaymentDiscount = earlyPaymentDiscount
        self.earlyPaymentDays = earlyPaymentDays
        self.lateFeePercentage = lateFeePercentage
        self.paymentInstructions = paymentInstructions
    }

    var displayText: String {
        "Net \(daysUntilDue)"
    }
}

// MARK: - Bank Details

/// Where the money should be transferred - printed on every generated invoice
struct BankDetails: Codable, Equatable, Hashable {
    /// Account holder name (usually the sender company)
    var accountHolder: String

    /// Bank name (e.g., "UBS Switzerland AG")
    var bankName: String

    /// IBAN, formatted as the bank expects it
    var iban: String

    /// BIC / SWIFT code
    var bic: String

    /// Optional bank address (some recipients require it for international transfers)
    var bankAddress: String?

    /// Payment reference; nil means "use the invoice number"
    var paymentReference: String?

    init(
        accountHolder: String = "",
        bankName: String = "",
        iban: String = "",
        bic: String = "",
        bankAddress: String? = nil,
        paymentReference: String? = nil
    ) {
        self.accountHolder = accountHolder
        self.bankName = bankName
        self.iban = iban
        self.bic = bic
        self.bankAddress = bankAddress
        self.paymentReference = paymentReference
    }

    var isComplete: Bool {
        !iban.trimmingCharacters(in: .whitespaces).isEmpty
            && !accountHolder.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

// MARK: - Invoice Template

/// A reusable invoice template saved per client
struct InvoiceTemplate: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var name: String
    var clientCompanyName: String  // Links to CompanyConfig by name

    // Invoice numbering
    var invoiceNumberPrefix: String?  // Custom prefix for invoice numbers (e.g., "ACME", "BRAND")

    // Content
    var lineItems: [InvoiceLineItem]
    var currency: InvoiceCurrency
    var notes: String?
    var terms: String?

    // Sender details
    var sender: ContactDetails

    // Recipient details (can be overridden per invoice)
    var recipient: ContactDetails

    // Payment
    var paymentTerms: PaymentTerms

    // Bank transfer details printed on generated invoices
    // Optional so templates saved before this field existed still decode
    var bankDetails: BankDetails?

    // Scheduling
    var billingDayOfMonth: Int  // 1-28 (day to generate invoice)
    var isActive: Bool

    // Metadata
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        clientCompanyName: String,
        invoiceNumberPrefix: String? = nil,
        lineItems: [InvoiceLineItem] = [],
        currency: InvoiceCurrency = .usd,
        notes: String? = nil,
        terms: String? = nil,
        sender: ContactDetails,
        recipient: ContactDetails,
        paymentTerms: PaymentTerms = PaymentTerms(),
        bankDetails: BankDetails? = nil,
        billingDayOfMonth: Int = 1,
        isActive: Bool = true
    ) {
        self.id = id
        self.name = name
        self.clientCompanyName = clientCompanyName
        self.invoiceNumberPrefix = invoiceNumberPrefix
        self.lineItems = lineItems
        self.currency = currency
        self.notes = notes
        self.terms = terms
        self.sender = sender
        self.recipient = recipient
        self.paymentTerms = paymentTerms
        self.bankDetails = bankDetails
        self.billingDayOfMonth = min(28, max(1, billingDayOfMonth))
        self.isActive = isActive
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    /// Calculate subtotal of all line items
    var subtotal: Decimal {
        lineItems.reduce(0) { $0 + $1.total }
    }
}

// MARK: - Draft Invoice Status

enum DraftInvoiceStatus: String, Codable {
    case pending    // Generated, awaiting review
    case approved   // User approved, ready to send/export
    case sent       // Marked as sent
    case cancelled  // User cancelled this draft
}

// MARK: - Draft Invoice

/// A generated invoice draft based on a template
struct DraftInvoice: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var templateId: UUID
    var invoiceNumber: String

    // Dates
    var issueDate: Date
    var dueDate: Date
    var dueDateAdjustmentExplanation: String?  // Explains why due date was adjusted (weekends/holidays)

    // Content (copied from template, can be edited)
    var lineItems: [InvoiceLineItem]
    var currency: InvoiceCurrency
    var notes: String?
    var terms: String?

    // Parties
    var sender: ContactDetails
    var recipient: ContactDetails

    // Payment
    var paymentTerms: PaymentTerms

    // Bank transfer details (copied from template, editable per draft)
    var bankDetails: BankDetails?

    // Status
    var status: DraftInvoiceStatus

    // Metadata
    var createdAt: Date
    var updatedAt: Date
    var sentAt: Date?

    /// Calculate subtotal
    var subtotal: Decimal {
        lineItems.reduce(0) { $0 + $1.total }
    }

    /// Calculate total (subtotal + tax if applicable)
    var total: Decimal {
        // For now, just return subtotal
        // Tax calculation can be added later
        subtotal
    }

    init(
        id: UUID = UUID(),
        templateId: UUID,
        invoiceNumber: String,
        issueDate: Date = Date(),
        dueDate: Date,
        dueDateAdjustmentExplanation: String? = nil,
        lineItems: [InvoiceLineItem],
        currency: InvoiceCurrency,
        notes: String? = nil,
        terms: String? = nil,
        sender: ContactDetails,
        recipient: ContactDetails,
        paymentTerms: PaymentTerms,
        bankDetails: BankDetails? = nil,
        status: DraftInvoiceStatus = .pending
    ) {
        self.id = id
        self.templateId = templateId
        self.invoiceNumber = invoiceNumber
        self.issueDate = issueDate
        self.dueDate = dueDate
        self.dueDateAdjustmentExplanation = dueDateAdjustmentExplanation
        self.lineItems = lineItems
        self.currency = currency
        self.notes = notes
        self.terms = terms
        self.sender = sender
        self.recipient = recipient
        self.paymentTerms = paymentTerms
        self.bankDetails = bankDetails
        self.status = status
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    /// Create a draft from a template
    static func fromTemplate(
        _ template: InvoiceTemplate,
        invoiceNumber: String,
        issueDate: Date = Date(),
        dueDate: Date,
        dueDateAdjustmentExplanation: String? = nil
    ) -> DraftInvoice {
        DraftInvoice(
            templateId: template.id,
            invoiceNumber: invoiceNumber,
            issueDate: issueDate,
            dueDate: dueDate,
            dueDateAdjustmentExplanation: dueDateAdjustmentExplanation,
            lineItems: template.lineItems,
            currency: template.currency,
            notes: template.notes,
            terms: template.terms,
            sender: template.sender,
            recipient: template.recipient,
            paymentTerms: template.paymentTerms,
            bankDetails: template.bankDetails
        )
    }
}

// MARK: - Invoice Number Generator

struct InvoiceNumberGenerator {
    /// Generate an invoice number based on date and sequence
    /// Format: INV-YYYYMM-XXX (e.g., INV-202601-001)
    static func generate(date: Date, sequence: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMM"
        let dateStr = formatter.string(from: date)
        let seqStr = String(format: "%03d", sequence)
        return "INV-\(dateStr)-\(seqStr)"
    }

    /// Generate with client prefix
    /// Format: ABC-YYYYMM-XXX (e.g., ACME-202601-001)
    static func generate(clientPrefix: String, date: Date, sequence: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMM"
        let dateStr = formatter.string(from: date)
        let seqStr = String(format: "%03d", sequence)
        let prefix = clientPrefix.uppercased().prefix(4)
        return "\(prefix)-\(dateStr)-\(seqStr)"
    }
}
