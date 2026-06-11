import SwiftUI
import SwiftData
import AppKit

/// Monthly accountant report, generated from the app database.
/// Outbound = my invoices by DUE DATE in the month; inbound = bills by PAID DATE.
struct ReportingView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var scheduler = InvoiceScheduler.shared

    /// First day of the reported month; defaults to last month (what's due on the 12th)
    @State private var month: Date = {
        let lastMonth = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
        let components = Calendar.current.dateComponents([.year, .month], from: lastMonth)
        return Calendar.current.date(from: components) ?? lastMonth
    }()

    /// Currency codes excluded by the filter chips (inverted so new currencies default to on)
    @State private var excludedCurrencies: Set<String> = []

    @State private var exportResult: String?

    private var report: MonthlyReport {
        ReportingService.report(for: month, context: modelContext)
    }

    private var presentCurrencyCodes: [String] {
        var codes = Set(report.inbound.map { $0.currency.rawValue })
        codes.formUnion(report.outbound.map { $0.currency.rawValue })
        return codes.sorted()
    }

    private var selectedCurrencyCodes: Set<String> {
        Set(presentCurrencyCodes).subtracting(excludedCurrencies)
    }

    private var filteredInbound: [RFFDocument] {
        report.inbound.filter { selectedCurrencyCodes.contains($0.currency.rawValue) }
    }

    private var filteredOutbound: [DraftInvoice] {
        report.outbound.filter { selectedCurrencyCodes.contains($0.currency.rawValue) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !presentCurrencyCodes.isEmpty {
                        currencyChips
                    }
                    outboundSection
                    inboundSection
                }
                .padding()
            }
            Divider()
            footer
        }
    }

    // MARK: - Header

    private var reportDeadline: Date {
        let next = Calendar.current.date(byAdding: .month, value: 1, to: month) ?? month
        var components = Calendar.current.dateComponents([.year, .month], from: next)
        components.day = 12
        return Calendar.current.date(from: components) ?? next
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                month = Calendar.current.date(byAdding: .month, value: -1, to: month) ?? month
            } label: {
                Image(systemName: "chevron.left")
            }

            Text(month, format: .dateTime.month(.wide).year())
                .font(.title3.weight(.semibold))
                .frame(width: 160)

            Button {
                month = Calendar.current.date(byAdding: .month, value: 1, to: month) ?? month
            } label: {
                Image(systemName: "chevron.right")
            }

            Text("report due \(reportDeadline, format: .dateTime.day().month())")
                .font(.caption)
                .foregroundStyle(reportDeadline < Date() ? .secondary : Color.orange)

            Spacer()

            Button {
                exportFiles()
            } label: {
                Label("Export Files…", systemImage: "square.and.arrow.up")
            }
            .disabled(filteredInbound.isEmpty && filteredOutbound.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    // MARK: - Currency Filter

    private var currencyChips: some View {
        HStack(spacing: 6) {
            Text("Currencies:")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(presentCurrencyCodes, id: \.self) { code in
                let isOn = !excludedCurrencies.contains(code)
                Button {
                    if isOn {
                        excludedCurrencies.insert(code)
                    } else {
                        excludedCurrencies.remove(code)
                    }
                } label: {
                    Text(code)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(isOn ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.1), in: Capsule())
                        .foregroundStyle(isOn ? Color.accentColor : .secondary)
                        .overlay(Capsule().stroke(isOn ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            if !excludedCurrencies.isEmpty {
                Button("All") { excludedCurrencies.removeAll() }
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
            Spacer()
        }
    }

    // MARK: - Outbound (my invoices, by due date)

    private var outboundSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                if filteredOutbound.isEmpty {
                    Text("No outgoing invoices due this month.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(filteredOutbound) { draft in
                        HStack(spacing: 10) {
                            statusDot(for: draft.status)
                            Text(draft.invoiceNumber)
                                .font(.callout.monospaced())
                            Text(draft.recipient.company ?? draft.recipient.name)
                                .lineLimit(1)
                            Spacer()
                            Text(draft.dueDate, format: .dateTime.day(.twoDigits).month(.twoDigits))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Text(draft.currency.format(draft.total))
                                .monospacedDigit()
                                .frame(width: 110, alignment: .trailing)
                        }
                        .font(.callout)
                        .padding(.vertical, 2)
                    }
                    totalsRow(report.outboundTotals
                        .filter { selectedCurrencyCodes.contains($0.currencyCode) }
                        .map { "\($0.currencyCode) \($0.total)" })
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Outbound — sent by me, due in \(month, format: .dateTime.month(.wide))", systemImage: "arrow.up.right")
                .font(.headline)
        }
    }

    // MARK: - Inbound (bills, by paid date)

    private var inboundSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                if filteredInbound.isEmpty {
                    Text("No bills paid this month.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(filteredInbound) { document in
                        HStack(spacing: 10) {
                            Circle().fill(.green).frame(width: 7, height: 7)
                            Text(document.requestingOrganization)
                                .lineLimit(1)
                            if document.documentPath == nil {
                                Image(systemName: "doc.questionmark")
                                    .foregroundStyle(.orange)
                                    .help("No file attached - won't be included in the export")
                            }
                            Spacer()
                            if let paidDate = document.paidDate {
                                Text("paid \(paidDate, format: .dateTime.day(.twoDigits).month(.twoDigits))")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Text("\(document.currency.symbol)\(document.amount)")
                                .monospacedDigit()
                                .frame(width: 110, alignment: .trailing)
                        }
                        .font(.callout)
                        .padding(.vertical, 2)
                    }
                    totalsRow(report.inboundTotals
                        .filter { selectedCurrencyCodes.contains($0.currency.rawValue) }
                        .map { "\($0.currency.rawValue) \($0.total)" })
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Inbound — bills paid in \(month, format: .dateTime.month(.wide))", systemImage: "arrow.down.left")
                .font(.headline)
        }
    }

    private func totalsRow(_ totals: [String]) -> some View {
        HStack {
            Spacer()
            Text(totals.joined(separator: "  ·  "))
                .font(.callout.weight(.bold))
                .monospacedDigit()
        }
        .padding(.top, 6)
    }

    private func statusDot(for status: DraftInvoiceStatus) -> some View {
        let color: Color
        switch status {
        case .sent: color = .green
        case .approved: color = .blue
        case .pending: color = .orange
        case .cancelled: color = .gray
        }
        return Circle().fill(color).frame(width: 7, height: 7)
            .help(String(describing: status))
    }

    // MARK: - Footer / Export

    private var footer: some View {
        HStack {
            Text("\(filteredOutbound.count) outbound · \(filteredInbound.count) inbound")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let exportResult {
                Text(exportResult)
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func exportFiles() {
        // No questions asked: stage everything in a temp folder and open it,
        // ready to drag into Mail / upload to the accountants
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        let stamp = DateFormatter()
        stamp.dateFormat = "HHmmss"
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("report-\(formatter.string(from: month))-\(stamp.string(from: Date()))")

        do {
            let count = try ReportingService.exportFiles(
                report: report,
                currencyCodes: selectedCurrencyCodes,
                to: folder
            )
            exportResult = "Exported \(count) file\(count == 1 ? "" : "s")"
            NSWorkspace.shared.open(folder)
        } catch {
            exportResult = "Export failed: \(error.localizedDescription)"
        }
    }
}
