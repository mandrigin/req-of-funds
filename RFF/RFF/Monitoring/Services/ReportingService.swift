import Foundation
import SwiftData

// MARK: - Monthly Report

/// One month's accountant report, generated from the app database:
/// - inbound: bills (RFF documents) PAID during the month
/// - outbound: invoices I sent whose DUE DATE falls in the month (money expected in)
struct MonthlyReport {
    let month: Date  // first day of the month

    let inbound: [RFFDocument]
    let outbound: [DraftInvoice]

    /// Sum per currency for the inbound side
    var inboundTotals: [(currency: Currency, total: Decimal)] {
        var sums: [Currency: Decimal] = [:]
        for document in inbound {
            sums[document.currency, default: 0] += document.amount
        }
        return sums.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { (currency: $0.key, total: $0.value) }
    }

    /// Sum per currency code for the outbound side
    var outboundTotals: [(currencyCode: String, total: Decimal)] {
        var sums: [String: Decimal] = [:]
        for draft in outbound {
            sums[draft.currency.rawValue, default: 0] += draft.total
        }
        return sums.sorted { $0.key < $1.key }
            .map { (currencyCode: $0.key, total: $0.value) }
    }
}

// MARK: - Reporting Service

@MainActor
enum ReportingService {

    /// First day of the month containing `date`
    static func monthStart(for date: Date) -> Date {
        let components = Calendar.current.dateComponents([.year, .month], from: date)
        return Calendar.current.date(from: components) ?? date
    }

    static func isDate(_ date: Date, inMonth month: Date) -> Bool {
        Calendar.current.isDate(date, equalTo: month, toGranularity: .month)
    }

    /// Build the report for the month containing `month`
    static func report(for month: Date, context: ModelContext) -> MonthlyReport {
        let monthStart = monthStart(for: month)

        // Inbound: paid during the month (library is small - filter in memory)
        let allDocuments = (try? context.fetch(FetchDescriptor<RFFDocument>())) ?? []
        let inbound = allDocuments
            .filter { document in
                guard document.documentCategory != DocumentCategory.salary.rawValue else { return false }
                guard document.status == .paid, let paidDate = document.paidDate else { return false }
                return isDate(paidDate, inMonth: monthStart)
            }
            .sorted { ($0.paidDate ?? .distantPast) < ($1.paidDate ?? .distantPast) }

        // Outbound: my invoices due in the month (anything not cancelled counts)
        let outbound = InvoiceScheduler.shared.draftInvoices
            .filter { $0.status != .cancelled && isDate($0.dueDate, inMonth: monthStart) }
            .sorted { $0.dueDate < $1.dueDate }

        return MonthlyReport(month: monthStart, inbound: inbound, outbound: outbound)
    }

    // MARK: - File Export

    /// Copy/render the report's files (filtered by currency codes) into `folder`,
    /// named so accountants can read them at a glance. Returns exported count.
    static func exportFiles(
        report: MonthlyReport,
        currencyCodes: Set<String>,
        to folder: URL
    ) throws -> Int {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        var exported = 0

        for document in report.inbound where currencyCodes.contains(document.currency.rawValue) {
            guard let path = document.documentPath, fileManager.fileExists(atPath: path) else { continue }
            let source = URL(fileURLWithPath: path)
            let paidDate = document.paidDate ?? document.dueDate
            let name = sanitize(
                "IN \(dateFormatter.string(from: paidDate)) \(document.requestingOrganization) \(document.amount) \(document.currency.rawValue)"
            ) + "." + source.pathExtension
            let target = uniqueURL(folder.appendingPathComponent(name))
            try fileManager.copyItem(at: source, to: target)
            exported += 1
        }

        for draft in report.outbound where currencyCodes.contains(draft.currency.rawValue) {
            let client = draft.recipient.company ?? draft.recipient.name
            let name = sanitize(
                "OUT \(dateFormatter.string(from: draft.dueDate)) \(draft.invoiceNumber) \(client) \(draft.total) \(draft.currency.rawValue)"
            ) + ".pdf"
            let target = uniqueURL(folder.appendingPathComponent(name))
            InvoicePDFRenderer.render(draft, to: target)
            exported += 1
        }

        return exported
    }

    private static func sanitize(_ name: String) -> String {
        name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\u{0}", with: "")
    }

    private static func uniqueURL(_ url: URL) -> URL {
        var candidate = url
        var counter = 1
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent()
                .appendingPathComponent("\(stem)-\(counter)")
                .appendingPathExtension(ext)
            counter += 1
        }
        return candidate
    }
}
