import Foundation
import Combine
import UserNotifications

/// Manages invoice templates and scheduled draft generation
final class InvoiceScheduler: ObservableObject {

    // MARK: - Singleton

    static let shared = InvoiceScheduler()

    // MARK: - Published Properties

    @Published private(set) var templates: [InvoiceTemplate] = []
    @Published private(set) var draftInvoices: [DraftInvoice] = []
    @Published private(set) var pendingDrafts: [DraftInvoice] = []

    // MARK: - Properties

    private let workingDayCalculator = WorkingDayCalculator.shared
    private var schedulerTimer: Timer?
    private let fileManager = FileManager.default

    /// Directory for storing invoice data (templates, drafts, sequences)
    var dataDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("RFF").appendingPathComponent("Invoices")
    }

    private var templatesFileURL: URL {
        dataDirectory.appendingPathComponent("templates.json")
    }

    private var draftsFileURL: URL {
        dataDirectory.appendingPathComponent("drafts.json")
    }

    private var sequenceFileURL: URL {
        dataDirectory.appendingPathComponent("sequence.json")
    }

    // MARK: - Initialization

    private init() {
        ensureDataDirectoryExists()
        loadTemplates()
        loadDrafts()
        updatePendingDrafts()
    }

    // MARK: - Template Management

    /// Add a new invoice template
    func addTemplate(_ template: InvoiceTemplate) {
        var newTemplate = template
        newTemplate.createdAt = Date()
        newTemplate.updatedAt = Date()
        templates.append(newTemplate)
        saveTemplates()
    }

    /// Update an existing template
    func updateTemplate(_ template: InvoiceTemplate) {
        if let index = templates.firstIndex(where: { $0.id == template.id }) {
            var updated = template
            updated.updatedAt = Date()
            templates[index] = updated
            saveTemplates()
        }
    }

    /// Delete a template
    func deleteTemplate(_ template: InvoiceTemplate) {
        templates.removeAll { $0.id == template.id }
        saveTemplates()
    }

    /// Get templates for a specific client
    func templates(forClient clientName: String) -> [InvoiceTemplate] {
        templates.filter { $0.clientCompanyName.lowercased() == clientName.lowercased() }
    }

    /// Get active templates
    var activeTemplates: [InvoiceTemplate] {
        templates.filter { $0.isActive }
    }

    // MARK: - Draft Invoice Management

    /// Generate a draft invoice from a template (async version with bank holiday support)
    /// Due date is calculated as:
    /// 1. Find the billing day (when money should be on account)
    /// 2. Adjust billing day to previous working day if it falls on weekend/holiday
    /// 3. Subtract 1 working day = DUE DATE (so payment clears before billing day)
    /// Issue date is set to the generation date (today)
    func generateDraft(
        from template: InvoiceTemplate,
        forDate date: Date = Date(),
        completion: @escaping (Result<DraftInvoice, Error>) -> Void
    ) {
        let sequence = getNextSequence(for: date)
        // Use template's custom prefix if set, otherwise derive from client company name
        let prefix = template.invoiceNumberPrefix ?? String(template.clientCompanyName.prefix(4))
        let invoiceNumber = InvoiceNumberGenerator.generate(
            clientPrefix: prefix,
            date: date,
            sequence: sequence
        )

        let calendar = Calendar.current

        // Calculate the billing day for the target month
        // The billing day is when money should BE on the account
        // If the billing day hasn't passed yet this month, use this month
        // If the billing day has already passed, use next month
        var components = calendar.dateComponents([.year, .month], from: date)
        components.day = template.billingDayOfMonth
        guard var targetBillingDay = calendar.date(from: components) else {
            completion(.failure(InvoiceSchedulerError.invalidDate))
            return
        }

        // If the billing day has already passed this month, use next month
        if targetBillingDay < date {
            components.month! += 1
            guard let nextMonthBillingDay = calendar.date(from: components) else {
                completion(.failure(InvoiceSchedulerError.invalidDate))
                return
            }
            targetBillingDay = nextMonthBillingDay
        }

        let senderCountry = template.sender.countryCode
        let recipientCountry = template.recipient.countryCode

        // Adjust billing day to previous working day if it falls on weekend/holiday
        // This gives us the effective billing day (when money should be on account)
        workingDayCalculator.previousWorkingDayOnOrBeforeWithAdjustments(
            date: targetBillingDay,
            senderCountry: senderCountry,
            recipientCountry: recipientCountry
        ) { [weak self] billingAdjustmentResult in
            guard let self = self else {
                completion(.failure(InvoiceSchedulerError.schedulerDeallocated))
                return
            }

            switch billingAdjustmentResult {
            case .success(let billingAdjustment):
                // Now subtract 1 working day from the adjusted billing day to get the due date
                // Due date = 1 working day BEFORE billing day (so payment clears in time)
                self.workingDayCalculator.dateSubtractingWorkingDaysWithAdjustments(
                    1,
                    from: billingAdjustment.adjustedDate,
                    senderCountry: senderCountry,
                    recipientCountry: recipientCountry
                ) { [weak self] dueDateResult in
                    guard let self = self else {
                        completion(.failure(InvoiceSchedulerError.schedulerDeallocated))
                        return
                    }

                    switch dueDateResult {
                    case .success(let dueDateAdjustment):
                        DispatchQueue.main.async {
                            // Combine adjustments from both steps for the explanation
                            let combinedAdjustments = billingAdjustment.adjustments + dueDateAdjustment.adjustments
                            let combinedResult = DateAdjustmentResult(
                                originalDate: targetBillingDay,
                                adjustedDate: dueDateAdjustment.adjustedDate,
                                adjustments: combinedAdjustments
                            )

                            // Build the explanation string
                            let explanation = self.buildDueDateExplanation(
                                originalBillingDay: targetBillingDay,
                                billingAdjustment: combinedResult
                            )

                            // Due date = 1 working day before adjusted billing day
                            // Issue date = today (when invoice is generated)
                            let draft = self.createAndSaveDraft(
                                from: template,
                                invoiceNumber: invoiceNumber,
                                issueDate: date,
                                dueDate: dueDateAdjustment.adjustedDate,
                                dueDateAdjustmentExplanation: explanation
                            )
                            completion(.success(draft))
                        }
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Build a human-readable explanation of due date adjustments
    private func buildDueDateExplanation(
        originalBillingDay: Date,
        billingAdjustment: DateAdjustmentResult
    ) -> String? {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM d"

        var steps: [String] = []

        // Original billing day
        let originalStr = dateFormatter.string(from: originalBillingDay)

        // Billing day adjustments (weekend/holiday) and working day subtraction
        for adjustment in billingAdjustment.adjustments {
            let fromStr = dateFormatter.string(from: adjustment.fromDate)
            switch adjustment.reason {
            case .weekend(let dayName):
                steps.append("\(fromStr) (\(dayName)) → skip")
            case .bankHoliday(let name, let country):
                steps.append("\(fromStr) (\(name), \(country)) → skip")
            case .workingDaySubtraction(let days):
                steps.append("minus \(days) working day\(days == 1 ? "" : "s")")
            }
        }

        // Always show explanation since we now always subtract 1 working day
        let finalStr = dateFormatter.string(from: billingAdjustment.adjustedDate)
        if steps.isEmpty {
            return "Due \(finalStr) (1 working day before billing day \(originalStr))"
        }
        return "Due \(finalStr) (from billing day \(originalStr): \(steps.joined(separator: ", ")))"
    }

    /// Create and save a draft invoice (helper for async generateDraft)
    private func createAndSaveDraft(
        from template: InvoiceTemplate,
        invoiceNumber: String,
        issueDate: Date,
        dueDate: Date,
        dueDateAdjustmentExplanation: String? = nil
    ) -> DraftInvoice {
        let calendar = Calendar.current

        // Calculate payment terms from the due date (due date - issue date)
        let daysBetween = calendar.dateComponents([.day], from: issueDate, to: dueDate).day ?? template.paymentTerms.daysUntilDue
        var adjustedPaymentTerms = template.paymentTerms
        adjustedPaymentTerms.daysUntilDue = max(0, daysBetween)

        var draft = DraftInvoice.fromTemplate(
            template,
            invoiceNumber: invoiceNumber,
            issueDate: issueDate,
            dueDate: dueDate,
            dueDateAdjustmentExplanation: dueDateAdjustmentExplanation
        )
        draft.paymentTerms = adjustedPaymentTerms

        draftInvoices.append(draft)
        saveDrafts()
        updatePendingDrafts()

        // Send notification
        if #available(macOS 10.14, *) {
            MonitorNotificationManager.shared.showDraftInvoiceReady(
                invoiceNumber: invoiceNumber,
                clientName: template.clientCompanyName
            )
        }

        return draft
    }

    /// Update a draft invoice
    func updateDraft(_ draft: DraftInvoice) {
        if let index = draftInvoices.firstIndex(where: { $0.id == draft.id }) {
            var updated = draft
            updated.updatedAt = Date()
            draftInvoices[index] = updated
            saveDrafts()
            updatePendingDrafts()
        }
    }

    /// Approve a draft invoice
    func approveDraft(_ draft: DraftInvoice) {
        if let index = draftInvoices.firstIndex(where: { $0.id == draft.id }) {
            var approved = draft
            approved.status = .approved
            approved.updatedAt = Date()
            draftInvoices[index] = approved
            saveDrafts()
            updatePendingDrafts()
        }
    }

    /// Mark a draft as sent
    func markDraftAsSent(_ draft: DraftInvoice) {
        if let index = draftInvoices.firstIndex(where: { $0.id == draft.id }) {
            var sent = draft
            sent.status = .sent
            sent.sentAt = Date()
            sent.updatedAt = Date()
            draftInvoices[index] = sent
            saveDrafts()
            updatePendingDrafts()
        }
    }

    /// Cancel a draft invoice
    func cancelDraft(_ draft: DraftInvoice) {
        if let index = draftInvoices.firstIndex(where: { $0.id == draft.id }) {
            var cancelled = draft
            cancelled.status = .cancelled
            cancelled.updatedAt = Date()
            draftInvoices[index] = cancelled
            saveDrafts()
            updatePendingDrafts()
        }
    }

    /// Delete a draft invoice
    func deleteDraft(_ draft: DraftInvoice) {
        draftInvoices.removeAll { $0.id == draft.id }
        saveDrafts()
        updatePendingDrafts()
    }

    /// Get drafts by status
    func drafts(withStatus status: DraftInvoiceStatus) -> [DraftInvoice] {
        draftInvoices.filter { $0.status == status }
    }

    // MARK: - Scheduling

    /// Start the scheduler to check for invoices that need to be generated
    func startScheduler() {
        stopScheduler()

        // Check every hour
        schedulerTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.checkAndGenerateDrafts()
        }

        // Also check immediately
        checkAndGenerateDrafts()
    }

    /// Stop the scheduler
    func stopScheduler() {
        schedulerTimer?.invalidate()
        schedulerTimer = nil
    }

    /// Check if any invoices need to be generated today
    /// Invoice generation date = billing_day - payment_terms (adjusted for weekends/holidays)
    /// This ensures customers have enough time to pay before the billing day
    func checkAndGenerateDrafts() {
        let today = Date()
        let calendar = Calendar.current

        for template in activeTemplates {
            // Calculate the next billing day
            // First try current month, then next month if billing day has passed
            var components = calendar.dateComponents([.year, .month], from: today)
            components.day = template.billingDayOfMonth
            guard var rawBillingDate = calendar.date(from: components) else { continue }

            // Calculate when we would generate for this billing day
            // Generation date = billing_day - payment_terms
            let paymentDays = template.paymentTerms.daysUntilDue
            guard let rawGenerationDate = calendar.date(byAdding: .day, value: -paymentDays, to: rawBillingDate) else { continue }

            // If the generation date has already passed, use next month's billing day
            if rawGenerationDate < today {
                components.month! += 1
                guard let nextMonthBilling = calendar.date(from: components) else { continue }
                rawBillingDate = nextMonthBilling
            }

            // Recalculate generation date for the correct billing day
            guard let targetGenerationDate = calendar.date(byAdding: .day, value: -paymentDays, to: rawBillingDate) else { continue }

            // Check if we already generated a draft for this billing cycle
            let existingDraft = draftInvoices.first { draft in
                draft.templateId == template.id &&
                calendar.isDate(draft.dueDate, equalTo: rawBillingDate, toGranularity: .month)
            }

            // Skip if we already have a draft for this billing cycle
            guard existingDraft == nil else { continue }

            // Adjust generation date for weekends and bank holidays
            workingDayCalculator.previousWorkingDayOnOrBefore(
                date: targetGenerationDate,
                senderCountry: template.sender.countryCode,
                recipientCountry: template.recipient.countryCode
            ) { [weak self] result in
                guard let self = self else { return }

                switch result {
                case .success(let adjustedGenerationDate):
                    // Check if today matches the adjusted generation date
                    if calendar.isDate(today, inSameDayAs: adjustedGenerationDate) {
                        self.generateDraft(from: template, forDate: today) { result in
                            if case .failure(let error) = result {
                                print("Failed to generate draft for template \(template.name): \(error)")
                            }
                        }
                    }
                case .failure(let error):
                    // Log the error but don't fail silently - fall back to simple weekend check
                    print("Failed to fetch bank holidays for template \(template.name): \(error)")
                    // Fall back to simple weekend-only adjustment
                    let fallbackDate = self.fallbackPreviousWorkingDay(onOrBefore: targetGenerationDate)
                    if calendar.isDate(today, inSameDayAs: fallbackDate) {
                        self.generateDraft(from: template, forDate: today) { result in
                            if case .failure(let error) = result {
                                print("Failed to generate draft for template \(template.name): \(error)")
                            }
                        }
                    }
                }
            }
        }
    }

    /// Fallback for when bank holiday API is unavailable - only considers weekends
    private func fallbackPreviousWorkingDay(onOrBefore date: Date) -> Date {
        let calendar = Calendar.current
        var result = date

        // Skip weekends (Saturday = 7, Sunday = 1)
        var weekday = calendar.component(.weekday, from: result)
        while weekday == 1 || weekday == 7 {
            result = calendar.date(byAdding: .day, value: -1, to: result) ?? result
            weekday = calendar.component(.weekday, from: result)
        }

        return result
    }

    /// Calculate the next auto-generation date for a template
    /// Returns the date when the next invoice will be automatically generated
    /// Generation date = billing_day - payment_terms (adjusted for weekends/holidays)
    func calculateNextGenerationDate(
        for template: InvoiceTemplate,
        from date: Date = Date(),
        completion: @escaping (Result<Date, Error>) -> Void
    ) {
        let calendar = Calendar.current

        // Calculate the next billing day
        var components = calendar.dateComponents([.year, .month], from: date)
        components.day = template.billingDayOfMonth
        guard var rawBillingDate = calendar.date(from: components) else {
            completion(.failure(InvoiceSchedulerError.invalidDate))
            return
        }

        // Calculate when we would generate for this billing day
        let paymentDays = template.paymentTerms.daysUntilDue
        guard let rawGenerationDate = calendar.date(byAdding: .day, value: -paymentDays, to: rawBillingDate) else {
            completion(.failure(InvoiceSchedulerError.invalidDate))
            return
        }

        // If the generation date has already passed, use next month's billing day
        if rawGenerationDate < date {
            components.month! += 1
            guard let nextMonthBilling = calendar.date(from: components) else {
                completion(.failure(InvoiceSchedulerError.invalidDate))
                return
            }
            rawBillingDate = nextMonthBilling
        }

        // Recalculate generation date for the correct billing day
        guard let targetGenerationDate = calendar.date(byAdding: .day, value: -paymentDays, to: rawBillingDate) else {
            completion(.failure(InvoiceSchedulerError.invalidDate))
            return
        }

        // Adjust for weekends and bank holidays
        workingDayCalculator.previousWorkingDayOnOrBefore(
            date: targetGenerationDate,
            senderCountry: template.sender.countryCode,
            recipientCountry: template.recipient.countryCode
        ) { result in
            switch result {
            case .success(let adjustedDate):
                completion(.success(adjustedDate))
            case .failure:
                // Fall back to weekend-only adjustment
                let fallbackDate = self.fallbackPreviousWorkingDay(onOrBefore: targetGenerationDate)
                completion(.success(fallbackDate))
            }
        }
    }

    /// Synchronous version using fallback (weekend-only) calculation
    /// Use this when you need an immediate result and can't wait for async bank holiday lookup
    func calculateNextGenerationDateFallback(for template: InvoiceTemplate, from date: Date = Date()) -> Date? {
        let calendar = Calendar.current

        var components = calendar.dateComponents([.year, .month], from: date)
        components.day = template.billingDayOfMonth
        guard var rawBillingDate = calendar.date(from: components) else { return nil }

        let paymentDays = template.paymentTerms.daysUntilDue
        guard let rawGenerationDate = calendar.date(byAdding: .day, value: -paymentDays, to: rawBillingDate) else { return nil }

        if rawGenerationDate < date {
            components.month! += 1
            guard let nextMonthBilling = calendar.date(from: components) else { return nil }
            rawBillingDate = nextMonthBilling
        }

        guard let targetGenerationDate = calendar.date(byAdding: .day, value: -paymentDays, to: rawBillingDate) else { return nil }

        return fallbackPreviousWorkingDay(onOrBefore: targetGenerationDate)
    }

    /// Calculate when an invoice should be generated based on due date and working days
    func calculateGenerationDate(
        dueDate: Date,
        paymentTerms: Int,
        senderCountry: String,
        recipientCountry: String,
        completion: @escaping (Result<Date, Error>) -> Void
    ) {
        workingDayCalculator.dateSubtractingWorkingDays(
            paymentTerms,
            from: dueDate,
            senderCountry: senderCountry,
            recipientCountry: recipientCountry,
            completion: completion
        )
    }

    // MARK: - Private Methods

    private func ensureDataDirectoryExists() {
        try? fileManager.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
    }

    private func loadTemplates() {
        guard fileManager.fileExists(atPath: templatesFileURL.path) else { return }

        do {
            let data = try Data(contentsOf: templatesFileURL)
            templates = try JSONDecoder().decode([InvoiceTemplate].self, from: data)
        } catch {
            print("Failed to load templates: \(error)")
        }
    }

    private func saveTemplates() {
        do {
            let data = try JSONEncoder().encode(templates)
            try data.write(to: templatesFileURL, options: .atomic)
        } catch {
            print("Failed to save templates: \(error)")
        }
    }

    private func loadDrafts() {
        guard fileManager.fileExists(atPath: draftsFileURL.path) else { return }

        do {
            let data = try Data(contentsOf: draftsFileURL)
            draftInvoices = try JSONDecoder().decode([DraftInvoice].self, from: data)
        } catch {
            print("Failed to load drafts: \(error)")
        }
    }

    private func saveDrafts() {
        do {
            let data = try JSONEncoder().encode(draftInvoices)
            try data.write(to: draftsFileURL, options: .atomic)
        } catch {
            print("Failed to save drafts: \(error)")
        }
    }

    private func updatePendingDrafts() {
        pendingDrafts = draftInvoices.filter { $0.status == .pending }
    }

    private func getNextSequence(for date: Date) -> Int {
        var sequences: [String: Int] = [:]

        // Load existing sequences
        if fileManager.fileExists(atPath: sequenceFileURL.path),
           let data = try? Data(contentsOf: sequenceFileURL),
           let loaded = try? JSONDecoder().decode([String: Int].self, from: data) {
            sequences = loaded
        }

        // Get key for this month
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMM"
        let key = formatter.string(from: date)

        // Increment sequence
        let sequence = (sequences[key] ?? 0) + 1
        sequences[key] = sequence

        // Save
        if let data = try? JSONEncoder().encode(sequences) {
            try? data.write(to: sequenceFileURL, options: .atomic)
        }

        return sequence
    }
}

// MARK: - Errors

enum InvoiceSchedulerError: LocalizedError {
    case invalidDate
    case schedulerDeallocated

    var errorDescription: String? {
        switch self {
        case .invalidDate:
            return "Failed to calculate billing date"
        case .schedulerDeallocated:
            return "Invoice scheduler was deallocated during calculation"
        }
    }
}

// MARK: - MonitorNotificationManager Extension

@available(macOS 10.14, *)
extension MonitorNotificationManager {

    /// Show notification when a draft invoice is ready for review
    func showDraftInvoiceReady(invoiceNumber: String, clientName: String) {
        let content = UNMutableNotificationContent()
        content.title = "Draft Invoice Ready"
        content.body = "\(invoiceNumber) for \(clientName) is ready for review"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    /// Show notification when invoice generation is due
    func showInvoiceGenerationReminder(clientName: String, dueDate: Date) {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium

        let content = UNMutableNotificationContent()
        content.title = "Invoice Due Soon"
        content.body = "Invoice for \(clientName) is due \(formatter.string(from: dueDate))"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }
}
