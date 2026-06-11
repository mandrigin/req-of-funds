import SwiftUI
import AppKit

extension Notification.Name {
    /// Posted by the menu bar [REPORT] button; ContentView switches to the Reporting tab
    static let rffOpenReporting = Notification.Name("rff.openReporting")
}

// MARK: - Badge Callout Plumbing

/// The badge's information segments, in display order
enum BadgeSegmentID: Hashable, CaseIterable {
    case status, filed, queue, drafts, report
}

/// Anchor identity for connector lines: a badge segment or its callout text
enum BadgeMark: Hashable {
    case segment(BadgeSegmentID)
    case callout(BadgeSegmentID)
}

struct BadgeAnchorsKey: PreferenceKey {
    static let defaultValue: [BadgeMark: Anchor<CGPoint>] = [:]
    static func reduce(
        value: inout [BadgeMark: Anchor<CGPoint>],
        nextValue: () -> [BadgeMark: Anchor<CGPoint>]
    ) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - KO-II Palette

/// Teenage-engineering-ish palette: near-black panel, mono type, signal colors
enum KOII {
    static let bg = Color(red: 0.10, green: 0.10, blue: 0.11)
    static let cell = Color(red: 0.16, green: 0.16, blue: 0.17)
    static let line = Color(red: 0.26, green: 0.26, blue: 0.28)
    static let text = Color(red: 0.92, green: 0.91, blue: 0.88)
    static let dim = Color(red: 0.55, green: 0.55, blue: 0.55)
    static let amber = Color(red: 1.00, green: 0.62, blue: 0.10)
    static let green = Color(red: 0.30, green: 0.85, blue: 0.39)
    static let red = Color(red: 1.00, green: 0.27, blue: 0.23)

    static func mono(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Menu Bar Icon (dense, colored)

/// Renders the menu bar "icon": a tiny colored status strip with live numbers.
/// Drawn as a non-template NSImage so colors survive in the menu bar.
enum MenuBarBadgeRenderer {
    static let amber = NSColor(red: 1.00, green: 0.62, blue: 0.10, alpha: 1)
    static let green = NSColor(red: 0.30, green: 0.85, blue: 0.39, alpha: 1)
    static let red = NSColor(red: 1.00, green: 0.27, blue: 0.23, alpha: 1)

    static func dotColor(for status: MonitoringStatus) -> NSColor {
        switch status {
        case .idle: return green
        case .processing: return amber
        case .error: return red
        case .stopped: return .systemGray
        }
    }

    static func render(
        status: MonitoringStatus,
        filedToday: Int,
        queueCount: Int,
        draftCount: Int,
        daysToReport: Int
    ) -> NSImage {
        let fg = NSColor.labelColor

        // Two stacked micro-rows next to the dot: half the horizontal footprint
        var topRow: [(String, NSColor)] = [("\(filedToday)", fg)]
        if queueCount > 0 {
            topRow.append(("?\(queueCount)", amber))
        }
        var bottomRow: [(String, NSColor)] = []
        if draftCount > 0 {
            bottomRow.append(("D\(draftCount)", .systemTeal))
        }
        if daysToReport <= 3 {
            bottomRow.append(("R\(daysToReport)", daysToReport <= 1 ? red : amber))
        }

        // Single row: bigger type; two rows: stacked micro type
        let singleRow = bottomRow.isEmpty
        let font = NSFont.monospacedSystemFont(ofSize: singleRow ? 11 : 8, weight: .heavy)

        func line(_ segments: [(String, NSColor)]) -> NSAttributedString {
            let text = NSMutableAttributedString()
            for (index, segment) in segments.enumerated() {
                if index > 0 {
                    text.append(NSAttributedString(string: " ", attributes: [.font: font]))
                }
                text.append(NSAttributedString(
                    string: segment.0,
                    attributes: [.font: font, .foregroundColor: segment.1]
                ))
            }
            return text
        }

        let top = line(topRow)
        let bottom = line(bottomRow)

        let dotDiameter: CGFloat = 6
        let spacing: CGFloat = 3
        let height: CGFloat = 16
        let textWidth = max(top.size().width, bottom.size().width)
        let width = dotDiameter + spacing + ceil(textWidth) + 2
        let dot = dotColor(for: status)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            dot.setFill()
            NSBezierPath(ovalIn: NSRect(
                x: 0, y: (height - dotDiameter) / 2, width: dotDiameter, height: dotDiameter
            )).fill()

            let x = dotDiameter + spacing
            if singleRow {
                top.draw(at: NSPoint(x: x, y: (height - top.size().height) / 2))
            } else {
                top.draw(at: NSPoint(x: x, y: height - top.size().height + 1))
                bottom.draw(at: NSPoint(x: x, y: -1))
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// SwiftUI wrapper used as the MenuBarExtra label
struct MenuBarBadgeLabel: View {
    @ObservedObject var coordinator = MonitoringCoordinator.shared
    @ObservedObject var reviewQueue = ReviewQueueStore.shared
    @ObservedObject var scheduler = InvoiceScheduler.shared

    var body: some View {
        Image(nsImage: MenuBarBadgeRenderer.render(
            status: coordinator.status,
            filedToday: coordinator.stats.filedToday,
            queueCount: reviewQueue.pendingCount,
            draftCount: scheduler.draftInvoices.filter { $0.status == .pending }.count,
            daysToReport: AccountantReportService.daysUntilReport()
        ))
    }
}

// MARK: - Dashboard Panel

/// The dense at-a-glance dashboard shown when clicking the menu bar item
struct MenuBarDashboardView: View {
    @ObservedObject var coordinator = MonitoringCoordinator.shared
    @ObservedObject var reviewQueue = ReviewQueueStore.shared
    @ObservedObject var scheduler = InvoiceScheduler.shared
    @ObservedObject var configManager = ConfigManager.shared

    @Environment(\.openWindow) private var openWindow

    @State private var ollamaUp = false
    @State private var appleIntelligenceUp = false

    private var pendingDrafts: [DraftInvoice] {
        scheduler.draftInvoices.filter { $0.status == .pending }
    }

    var body: some View {
        VStack(spacing: 1) {
            badgeLegend
            header
            counterGrid
            reportRow
            aiRow
            if !reviewQueue.items.isEmpty {
                queueSection
            }
            if !pendingDrafts.isEmpty {
                draftsSection
            }
            lastFiledRow
            footer
        }
        .background(KOII.line)
        .frame(width: 460)
        .background(KOII.bg)
        .task {
            coordinator.refreshStats()
            appleIntelligenceUp = AIAnalysisService.shared.isFoundationModelsAvailable()
            ollamaUp = await AIAnalysisService.shared.isOllamaAvailable()
        }
    }

    // MARK: Badge Callouts (the menu bar icon itself, magnified, with trace lines
    // to live explanations - TE-style self-explanation on the device)

    private var daysToReport: Int { AccountantReportService.daysUntilReport() }

    private var reportColor: Color {
        daysToReport <= 1 ? KOII.red : (daysToReport <= 3 ? KOII.amber : KOII.dim)
    }

    /// Segments currently visible in the menu bar badge, in badge order
    private var visibleSegments: [BadgeSegmentID] {
        var segments: [BadgeSegmentID] = [.status, .filed]
        if reviewQueue.pendingCount > 0 { segments.append(.queue) }
        if !pendingDrafts.isEmpty { segments.append(.drafts) }
        if daysToReport <= 3 { segments.append(.report) }
        return segments
    }

    private func segmentColor(_ segment: BadgeSegmentID) -> Color {
        switch segment {
        case .status: return statusColor
        case .filed: return KOII.text
        case .queue: return KOII.amber
        case .drafts: return Color.teal
        case .report: return reportColor
        }
    }

    private func segmentGlyph(_ segment: BadgeSegmentID) -> String {
        switch segment {
        case .status: return "●"
        case .filed: return "\(coordinator.stats.filedToday)"
        case .queue: return "?\(reviewQueue.pendingCount)"
        case .drafts: return "D\(pendingDrafts.count)"
        case .report: return "R\(daysToReport)"
        }
    }

    private func segmentExplanation(_ segment: BadgeSegmentID) -> String {
        switch segment {
        case .status:
            switch coordinator.status {
            case .idle:
                return "WATCHING \(configManager.config.monitoredPaths.count) FOLDER\(configManager.config.monitoredPaths.count == 1 ? "" : "S")"
            case .processing(let file):
                return "PROCESSING \(file.prefix(16))"
            case .error(let message):
                return "ERROR \(message.prefix(18))"
            case .stopped:
                return "STOPPED · START BELOW"
            }
        case .filed:
            if coordinator.stats.filedToday == 0 {
                return "NOTHING FILED YET TODAY"
            }
            if let last = coordinator.stats.lastFiledName {
                return "\(coordinator.stats.filedToday) FILED TODAY · \(last.prefix(12))"
            }
            return "\(coordinator.stats.filedToday) FILED TODAY"
        case .queue:
            return "\(reviewQueue.pendingCount) AWAIT YOUR CONFIRM → REVIEW"
        case .drafts:
            return "\(pendingDrafts.count) DRAFT\(pendingDrafts.count == 1 ? "" : "S") TO APPROVE → OUTBOUND"
        case .report:
            return "RPT IN \(daysToReport)D · IN:\(coordinator.stats.reportInbound) OUT:\(coordinator.stats.reportOutbound)"
        }
    }

    private var badgeTopRow: [BadgeSegmentID] {
        visibleSegments.filter { $0 == .filed || $0 == .queue }
    }

    private var badgeBottomRow: [BadgeSegmentID] {
        visibleSegments.filter { $0 == .drafts || $0 == .report }
    }

    /// Callouts ordered to match the replica's vertical geometry, so trace lines
    /// run parallel and never cross: top row first, then the dot, then bottom row
    private var calloutOrder: [BadgeSegmentID] {
        badgeBottomRow.isEmpty
            ? [.status] + badgeTopRow
            : badgeTopRow + [.status] + badgeBottomRow
    }

    /// Exact replica of the menu bar badge layout (dot + stacked micro rows), magnified
    private var badgeReplica: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 22, height: 22)
                .anchorPreference(key: BadgeAnchorsKey.self, value: .trailing) {
                    [BadgeMark.segment(.status): $0]
                }
            VStack(alignment: .leading, spacing: badgeBottomRow.isEmpty ? 0 : 6) {
                HStack(spacing: 12) {
                    ForEach(badgeTopRow, id: \.self) { segment in
                        Text(segmentGlyph(segment))
                            .font(KOII.mono(badgeBottomRow.isEmpty ? 34 : 27, weight: .heavy))
                            .foregroundStyle(segmentColor(segment))
                            // Last glyph in a row exits from its centerline (clean
                            // horizontal trace); earlier ones exit over the top edge
                            .anchorPreference(
                                key: BadgeAnchorsKey.self,
                                value: segment == badgeTopRow.last ? .trailing : .topTrailing
                            ) {
                                [BadgeMark.segment(segment): $0]
                            }
                    }
                }
                if !badgeBottomRow.isEmpty {
                    HStack(spacing: 12) {
                        ForEach(badgeBottomRow, id: \.self) { segment in
                            Text(segmentGlyph(segment))
                                .font(KOII.mono(27, weight: .heavy))
                                .foregroundStyle(segmentColor(segment))
                                .anchorPreference(
                                    key: BadgeAnchorsKey.self,
                                    value: segment == badgeBottomRow.last ? .trailing : .bottomTrailing
                                ) {
                                    [BadgeMark.segment(segment): $0]
                                }
                        }
                    }
                }
            }
        }
    }

    /// Callout capsule: Liquid Glass on macOS 26, flat cell before that
    @ViewBuilder
    private func calloutLabel(_ segment: BadgeSegmentID) -> some View {
        let label = Text(segmentExplanation(segment))
            .font(KOII.mono(10, weight: .semibold))
            .foregroundStyle(segmentColor(segment))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)

        Group {
            if #available(macOS 26.0, *) {
                label.glassEffect()
            } else {
                label.background(KOII.cell, in: Capsule())
            }
        }
        .overlay(Capsule().stroke(segmentColor(segment).opacity(0.45), lineWidth: 1))
    }

    private var badgeLegend: some View {
        HStack(alignment: .center, spacing: 64) {
            badgeReplica
            VStack(alignment: .leading, spacing: 8) {
                ForEach(calloutOrder, id: \.self) { segment in
                    calloutLabel(segment)
                        .anchorPreference(key: BadgeAnchorsKey.self, value: .leading) {
                            [BadgeMark.callout(segment): $0]
                        }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .background(KOII.bg)
        .overlayPreferenceValue(BadgeAnchorsKey.self) { anchors in
            // PCB-trace connector lines from each badge segment to its callout
            GeometryReader { proxy in
                ForEach(Array(calloutOrder.enumerated()), id: \.element) { index, segment in
                    if let segmentAnchor = anchors[.segment(segment)],
                       let calloutAnchor = anchors[.callout(segment)] {
                        let from = proxy[segmentAnchor]
                        let to = proxy[calloutAnchor]
                        let nodeCenter = CGPoint(x: from.x + 9, y: from.y)
                        let lane = to.x - 12 - CGFloat(calloutOrder.count - index) * 9

                        // Trace: node edge -> lane -> callout capsule, touching it
                        Path { path in
                            path.move(to: CGPoint(x: nodeCenter.x + 4.5, y: nodeCenter.y))
                            path.addLine(to: CGPoint(x: lane, y: nodeCenter.y))
                            path.addLine(to: CGPoint(x: lane, y: to.y))
                            path.addLine(to: CGPoint(x: to.x, y: to.y))
                        }
                        .stroke(segmentColor(segment).opacity(0.6), lineWidth: 1.5)

                        // Inverted node: black core, colored ring - marks the trace origin
                        Circle()
                            .fill(KOII.bg)
                            .stroke(segmentColor(segment), lineWidth: 1.5)
                            .frame(width: 9, height: 9)
                            .position(nodeCenter)
                    }
                }
            }
        }
    }

    // MARK: Header

    private var statusColor: Color {
        switch coordinator.status {
        case .idle: return KOII.green
        case .processing: return KOII.amber
        case .error: return KOII.red
        case .stopped: return KOII.dim
        }
    }

    private var statusText: String {
        switch coordinator.status {
        case .idle: return "WATCHING \(configManager.config.monitoredPaths.count) DIR"
        case .processing(let file): return "PROC \(file.prefix(18))"
        case .error(let message): return "ERR \(message.prefix(20))"
        case .stopped: return "STOPPED"
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text("RFF·MONITOR").font(KOII.mono(11, weight: .heavy)).foregroundStyle(KOII.text)
            Spacer()
            Text(statusText).font(KOII.mono(9)).foregroundStyle(statusColor)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(KOII.cell)
    }

    // MARK: Counters

    private func counterCell(_ label: String, _ value: String, color: Color = KOII.text) -> some View {
        VStack(spacing: 1) {
            Text(value).font(KOII.mono(20, weight: .heavy)).foregroundStyle(color)
            Text(label).font(KOII.mono(8)).foregroundStyle(KOII.dim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(KOII.cell)
    }

    private var counterGrid: some View {
        HStack(spacing: 1) {
            counterCell("TODAY", "\(coordinator.stats.filedToday)")
            counterCell("24H", "\(coordinator.stats.filed24h)")
            counterCell("QUEUE", "\(reviewQueue.pendingCount)",
                        color: reviewQueue.pendingCount > 0 ? KOII.amber : KOII.text)
            counterCell("DRAFTS", "\(pendingDrafts.count)",
                        color: pendingDrafts.isEmpty ? KOII.text : Color.teal)
            counterCell("PAID·M", "\(coordinator.stats.paidThisMonth)")
        }
    }

    // MARK: Report

    private var reportRow: some View {
        let days = AccountantReportService.daysUntilReport()
        let urgency: Color = days <= 1 ? KOII.red : (days <= 3 ? KOII.amber : KOII.dim)
        return HStack(spacing: 8) {
            Text("RPT 12TH").font(KOII.mono(9, weight: .heavy)).foregroundStyle(urgency)
            Text("T-\(days)D").font(KOII.mono(12, weight: .heavy)).foregroundStyle(urgency)
            Text("IN:\(coordinator.stats.reportInbound) OUT:\(coordinator.stats.reportOutbound)")
                .font(KOII.mono(9)).foregroundStyle(KOII.text)
            Spacer()
            Button {
                openWindow(id: "library")
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .rffOpenReporting, object: nil)
            } label: {
                Text("[REPORT]").font(KOII.mono(9, weight: .heavy)).foregroundStyle(KOII.amber)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(KOII.cell)
    }

    // MARK: AI status

    private func led(_ label: String, _ on: Bool) -> some View {
        HStack(spacing: 3) {
            Circle().fill(on ? KOII.green : KOII.dim).frame(width: 6, height: 6)
            Text(label).font(KOII.mono(8)).foregroundStyle(on ? KOII.text : KOII.dim)
        }
    }

    private var aiRow: some View {
        HStack(spacing: 12) {
            led("APL·INT", appleIntelligenceUp)
            led("OLLAMA", ollamaUp)
            led("IMPORT", configManager.config.importsToRFF)
            led("SCHED", configManager.config.invoiceSchedulingEnabled)
            Spacer()
            Text(Date(), format: .dateTime.day(.twoDigits).month(.twoDigits))
                .font(KOII.mono(8)).foregroundStyle(KOII.dim)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(KOII.cell)
    }

    // MARK: Review queue

    private var queueSection: some View {
        VStack(spacing: 1) {
            HStack {
                Text("CONFIRM?").font(KOII.mono(8, weight: .heavy)).foregroundStyle(KOII.amber)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(KOII.cell)

            ForEach(reviewQueue.items.prefix(3)) { item in
                HStack(spacing: 6) {
                    Text(item.fileName.prefix(24))
                        .font(KOII.mono(9)).foregroundStyle(KOII.text)
                        .lineLimit(1)
                    Text("\(Int(item.confidence * 100))%")
                        .font(KOII.mono(9, weight: .heavy)).foregroundStyle(KOII.amber)
                    Spacer()
                    Button {
                        coordinator.approveReviewItem(item)
                    } label: {
                        Text("[INV✓]").font(KOII.mono(9, weight: .heavy)).foregroundStyle(KOII.green)
                    }.buttonStyle(.plain)
                    Button {
                        coordinator.rejectReviewItem(item)
                    } label: {
                        Text("[NO✗]").font(KOII.mono(9, weight: .heavy)).foregroundStyle(KOII.red)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(KOII.cell)
            }

            if reviewQueue.items.count > 3 {
                HStack {
                    Text("+\(reviewQueue.items.count - 3) MORE").font(KOII.mono(8)).foregroundStyle(KOII.dim)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 2)
                .background(KOII.cell)
            }
        }
    }

    // MARK: Drafts

    private var draftsSection: some View {
        VStack(spacing: 1) {
            ForEach(pendingDrafts.prefix(2)) { draft in
                HStack(spacing: 6) {
                    Text("INV").font(KOII.mono(8, weight: .heavy)).foregroundStyle(Color.teal)
                    Text(draft.invoiceNumber).font(KOII.mono(9)).foregroundStyle(KOII.text)
                    Text(draft.recipient.company ?? draft.recipient.name)
                        .font(KOII.mono(9)).foregroundStyle(KOII.dim).lineLimit(1)
                    Spacer()
                    Text(draft.dueDate, format: .dateTime.day(.twoDigits).month(.twoDigits))
                        .font(KOII.mono(9)).foregroundStyle(KOII.amber)
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(KOII.cell)
            }
        }
    }

    // MARK: Last filed + footer

    private var lastFiledRow: some View {
        HStack(spacing: 6) {
            Text("LAST").font(KOII.mono(8, weight: .heavy)).foregroundStyle(KOII.dim)
            if let name = coordinator.stats.lastFiledName, let at = coordinator.stats.lastFiledAt {
                Text(name.prefix(28)).font(KOII.mono(9)).foregroundStyle(KOII.text).lineLimit(1)
                Spacer()
                Text(at, format: .dateTime.hour().minute()).font(KOII.mono(9)).foregroundStyle(KOII.dim)
            } else {
                Text("—").font(KOII.mono(9)).foregroundStyle(KOII.dim)
                Spacer()
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(KOII.cell)
    }

    private func footerButton(_ title: String, color: Color = KOII.text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(KOII.mono(9, weight: .heavy))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(KOII.cell)
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        VStack(spacing: 1) {
            // Navigation: inbound library / AI-uncertain review / my invoices / monthly report
            HStack(spacing: 1) {
                footerButton("LIBRARY") {
                    openWindow(id: "library")
                    NSApp.activate(ignoringOtherApps: true)
                }
                footerButton(
                    reviewQueue.pendingCount > 0 ? "REVIEW·\(reviewQueue.pendingCount)" : "REVIEW",
                    color: reviewQueue.pendingCount > 0 ? KOII.amber : KOII.text
                ) {
                    openWindow(id: "review-queue")
                    NSApp.activate(ignoringOtherApps: true)
                }
                footerButton("OUTBOUND") {
                    openWindow(id: "invoicing")
                    NSApp.activate(ignoringOtherApps: true)
                }
                footerButton("REPORT", color: KOII.amber) {
                    openWindow(id: "library")
                    NSApp.activate(ignoringOtherApps: true)
                    NotificationCenter.default.post(name: .rffOpenReporting, object: nil)
                }
            }
            // Controls
            HStack(spacing: 1) {
                footerButton(
                    coordinator.status.isRunning ? "■ STOP WATCH" : "▶ START WATCH",
                    color: coordinator.status.isRunning ? KOII.dim : KOII.green
                ) {
                    coordinator.status.isRunning ? coordinator.stop() : coordinator.start()
                }
                footerButton("⏻ QUIT", color: KOII.dim) {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
