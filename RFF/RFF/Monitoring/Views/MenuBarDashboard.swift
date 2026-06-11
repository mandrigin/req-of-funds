import SwiftUI
import AppKit

// MARK: - Signal Palette (app-wide)

/// One signal system, one meaning per color, everywhere in the app:
/// green = ok/done · amber = needs you · red = overdue/error · teal = outbound · gray = inert.
/// These are tuned for light chrome; the KOII variants below are the same signals
/// tuned for the dark display surfaces.
enum Signal {
    static let green = Color(red: 0.13, green: 0.62, blue: 0.30)
    static let amber = Color(red: 0.85, green: 0.50, blue: 0.02)
    static let red = Color(red: 0.83, green: 0.21, blue: 0.18)
    static let teal = Color(red: 0.05, green: 0.52, blue: 0.62)
    static let gray = Color.secondary
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
    static let teal = Color(red: 0.35, green: 0.78, blue: 0.98)

    static func mono(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Notification.Name {
    /// Legacy name kept for any external scripts; the app uses rffOpenSection
    static let rffOpenReporting = Notification.Name("rff.openReporting")
}

// MARK: - Badge State

/// Urgency of the "send your invoice" signal
enum SendUrgency {
    case none       // nothing to send
    case normal     // drafts exist, due is far
    case soon       // due within 7 days
    case overdue    // past due

    var koColor: Color {
        switch self {
        case .none, .normal: return KOII.teal
        case .soon: return KOII.amber
        case .overdue: return KOII.red
        }
    }

    var nsColor: NSColor {
        switch self {
        case .none, .normal: return NSColor(red: 0.35, green: 0.78, blue: 0.98, alpha: 1)
        case .soon: return NSColor(red: 1.00, green: 0.62, blue: 0.10, alpha: 1)
        case .overdue: return NSColor(red: 1.00, green: 0.27, blue: 0.23, alpha: 1)
        }
    }
}

/// Everything the badge and panel need, computed in one place so they always agree
struct BadgeState {
    let status: MonitoringStatus
    let queueCount: Int
    let sendCount: Int
    let sendUrgency: SendUrgency
    let earliestSendDue: Date?
    let daysToReport: Int

    @MainActor
    static func current(
        coordinator: MonitoringCoordinator,
        reviewQueue: ReviewQueueStore,
        scheduler: InvoiceScheduler
    ) -> BadgeState {
        let unsent = scheduler.draftInvoices.filter {
            $0.status == .pending || $0.status == .approved
        }
        let earliest = unsent.map(\.dueDate).min()

        let urgency: SendUrgency
        if unsent.isEmpty {
            urgency = .none
        } else if let earliest, earliest < Date() {
            urgency = .overdue
        } else if let earliest, earliest.timeIntervalSinceNow < 7 * 24 * 3600 {
            urgency = .soon
        } else {
            urgency = .normal
        }

        return BadgeState(
            status: coordinator.status,
            queueCount: reviewQueue.pendingCount,
            sendCount: unsent.count,
            sendUrgency: urgency,
            earliestSendDue: earliest,
            daysToReport: AccountantReportService.daysUntilReport()
        )
    }
}

// MARK: - Menu Bar Icon (quiet by default, characters mean "you have a job")

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

    static func render(state: BadgeState) -> NSImage {
        // Actionable segments only - an idle day is just the dot
        var segments: [(String, NSColor)] = []
        if state.queueCount > 0 {
            segments.append(("?\(state.queueCount)", amber))
        }
        if state.sendCount > 0 {
            segments.append(("S\(state.sendCount)", state.sendUrgency.nsColor))
        }
        if state.daysToReport <= 3 {
            segments.append(("R\(state.daysToReport)", state.daysToReport <= 1 ? red : amber))
        }

        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .heavy)
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

        let dotDiameter: CGFloat = 7
        let spacing: CGFloat = segments.isEmpty ? 0 : 4
        let height: CGFloat = 16
        let textSize = text.size()
        let width = dotDiameter + spacing + ceil(textSize.width) + 2
        let dot = dotColor(for: state.status)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            dot.setFill()
            NSBezierPath(ovalIn: NSRect(
                x: 1, y: (height - dotDiameter) / 2, width: dotDiameter, height: dotDiameter
            )).fill()
            if !segments.isEmpty {
                text.draw(at: NSPoint(
                    x: dotDiameter + spacing,
                    y: (height - textSize.height) / 2
                ))
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
            state: .current(coordinator: coordinator, reviewQueue: reviewQueue, scheduler: scheduler)
        ))
    }
}

// MARK: - Badge Callout Plumbing

/// The badge's information segments, in display order
enum BadgeSegmentID: Hashable, CaseIterable {
    case status, queue, send, report
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

// MARK: - Dashboard Panel

/// The dense at-a-glance dashboard shown when clicking the menu bar item.
/// The annotated badge replica IS the header - every number lives exactly once.
struct MenuBarDashboardView: View {
    @ObservedObject var coordinator = MonitoringCoordinator.shared
    @ObservedObject var reviewQueue = ReviewQueueStore.shared
    @ObservedObject var scheduler = InvoiceScheduler.shared
    @ObservedObject var configManager = ConfigManager.shared

    @Environment(\.openWindow) private var openWindow

    @State private var ollamaUp = false
    @State private var appleIntelligenceUp = false

    private var state: BadgeState {
        .current(coordinator: coordinator, reviewQueue: reviewQueue, scheduler: scheduler)
    }

    private var pendingDrafts: [DraftInvoice] {
        scheduler.draftInvoices.filter { $0.status == .pending || $0.status == .approved }
    }

    var body: some View {
        VStack(spacing: 1) {
            badgeBoard
            aiRow
            if !reviewQueue.items.isEmpty {
                queueSection
            }
            if !pendingDrafts.isEmpty {
                sendSection
            }
            footer
        }
        .background(KOII.line)
        .frame(width: 530)
        .background(KOII.bg)
        .task {
            coordinator.refreshStats()
            appleIntelligenceUp = AIAnalysisService.shared.isFoundationModelsAvailable()
            ollamaUp = await AIAnalysisService.shared.isOllamaAvailable()
        }
    }

    // MARK: Segments

    private var statusColor: Color {
        switch coordinator.status {
        case .idle: return KOII.green
        case .processing: return KOII.amber
        case .error: return KOII.red
        case .stopped: return KOII.dim
        }
    }

    private var reportColor: Color {
        state.daysToReport <= 1 ? KOII.red : (state.daysToReport <= 3 ? KOII.amber : KOII.dim)
    }

    /// Segments currently visible in the menu bar badge, in badge order
    private var visibleSegments: [BadgeSegmentID] {
        var segments: [BadgeSegmentID] = [.status]
        if state.queueCount > 0 { segments.append(.queue) }
        if state.sendCount > 0 { segments.append(.send) }
        if state.daysToReport <= 3 { segments.append(.report) }
        return segments
    }

    private func segmentColor(_ segment: BadgeSegmentID) -> Color {
        switch segment {
        case .status: return statusColor
        case .queue: return KOII.amber
        case .send: return state.sendUrgency.koColor
        case .report: return reportColor
        }
    }

    private func segmentGlyph(_ segment: BadgeSegmentID) -> String {
        switch segment {
        case .status: return "●"
        case .queue: return "?\(state.queueCount)"
        case .send: return "S\(state.sendCount)"
        case .report: return "R\(state.daysToReport)"
        }
    }

    private func segmentExplanation(_ segment: BadgeSegmentID) -> String {
        switch segment {
        case .status:
            switch coordinator.status {
            case .idle:
                let count = configManager.config.monitoredPaths.count
                return "WATCHING \(count) FOLDER\(count == 1 ? "" : "S")"
            case .processing(let file):
                return "PROCESSING \(file.prefix(16))"
            case .error(let message):
                return "ERROR \(message.prefix(18))"
            case .stopped:
                return "STOPPED · START BELOW"
            }
        case .queue:
            return state.queueCount > 0
                ? "\(state.queueCount) AWAIT YOUR CONFIRM → REVIEW"
                : "REVIEW CLEAR"
        case .send:
            if state.sendCount == 0 { return "NOTHING TO SEND" }
            if let due = state.earliestSendDue {
                let formatter = DateFormatter()
                formatter.dateFormat = "dd.MM"
                let prefix = state.sendUrgency == .overdue ? "OVERDUE" : "DUE \(formatter.string(from: due))"
                return "\(state.sendCount) INVOICE\(state.sendCount == 1 ? "" : "S") TO SEND · \(prefix)"
            }
            return "\(state.sendCount) INVOICE\(state.sendCount == 1 ? "" : "S") TO SEND"
        case .report:
            return "RPT IN \(state.daysToReport)D · IN:\(coordinator.stats.reportInbound) OUT:\(coordinator.stats.reportOutbound)"
        }
    }

    // MARK: Badge Board (centered replica, callouts on four sides, traces never cross)

    private enum CalloutSide {
        case left, top, right, bottom
    }

    /// Each visible segment gets its own side, matched to its position in the
    /// replica: dot exits left, last glyph exits right, middle ones up/down.
    private var sideAssignment: [BadgeSegmentID: CalloutSide] {
        let segments = visibleSegments
        var map: [BadgeSegmentID: CalloutSide] = [:]
        guard let first = segments.first else { return map }
        map[first] = .left
        if segments.count >= 2 { map[segments[segments.count - 1]] = .right }
        if segments.count >= 3 { map[segments[1]] = .top }
        if segments.count == 4 { map[segments[2]] = .bottom }
        return map
    }

    private func segmentAnchor(for side: CalloutSide) -> Anchor<CGPoint>.Source {
        switch side {
        case .left: return .leading
        case .top: return .top
        case .right: return .trailing
        case .bottom: return .bottom
        }
    }

    private func calloutAnchor(for side: CalloutSide) -> Anchor<CGPoint>.Source {
        switch side {
        case .left: return .trailing   // callout sits left of replica, trace enters its right edge
        case .top: return .bottom
        case .right: return .leading
        case .bottom: return .top
        }
    }

    private func segment(on side: CalloutSide) -> BadgeSegmentID? {
        sideAssignment.first { $0.value == side }?.key
    }

    /// Exact replica of the menu bar badge (dot + actionable glyphs), magnified
    private var badgeReplica: some View {
        HStack(spacing: 12) {
            ForEach(visibleSegments, id: \.self) { segment in
                let side = sideAssignment[segment] ?? .left
                Group {
                    if segment == .status {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 18, height: 18)
                    } else {
                        Text(segmentGlyph(segment))
                            .font(KOII.mono(30, weight: .heavy))
                            .foregroundStyle(segmentColor(segment))
                    }
                }
                .anchorPreference(key: BadgeAnchorsKey.self, value: segmentAnchor(for: side)) {
                    [BadgeMark.segment(segment): $0]
                }
            }
        }
    }

    /// Callout capsule: Liquid Glass on macOS 26, flat cell before that
    @ViewBuilder
    private func calloutCapsule(_ text: String, color: Color, dimmed: Bool = false) -> some View {
        let label = Text(text)
            .font(KOII.mono(10, weight: .semibold))
            .foregroundStyle(dimmed ? KOII.dim : color)
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
        .overlay(Capsule().stroke((dimmed ? KOII.dim : color).opacity(dimmed ? 0.2 : 0.45), lineWidth: 1))
        .opacity(dimmed ? 0.75 : 1)
    }

    /// Facts that aren't badge segments right now - shown once, dimmed, below the callouts
    private var quietFacts: [(String, Color)] {
        var facts: [(String, Color)] = []

        // Filed today (diary fact - never in the badge anymore)
        if coordinator.stats.filedToday > 0 {
            var text = "\(coordinator.stats.filedToday) FILED TODAY"
            if let last = coordinator.stats.lastFiledName {
                text += " · \(last.prefix(14))"
            }
            facts.append((text, KOII.text))
        } else {
            facts.append(("NOTHING FILED TODAY", KOII.dim))
        }

        facts.append(("\(coordinator.stats.paidThisMonth) PAID THIS MONTH", KOII.text))

        // Hidden segments keep teaching the badge vocabulary
        for segment in BadgeSegmentID.allCases where segment != .status && !visibleSegments.contains(segment) {
            facts.append((segmentExplanation(segment), KOII.dim))
        }

        return facts
    }

    @ViewBuilder
    private func sideCallout(_ side: CalloutSide) -> some View {
        if let segment = segment(on: side) {
            calloutCapsule(segmentExplanation(segment), color: segmentColor(segment))
                .anchorPreference(key: BadgeAnchorsKey.self, value: calloutAnchor(for: side)) {
                    [BadgeMark.callout(segment): $0]
                }
        }
    }

    private var badgeBoard: some View {
        VStack(spacing: 34) {
            sideCallout(.top)
            HStack(spacing: 40) {
                sideCallout(.left)
                badgeReplica
                sideCallout(.right)
            }
            sideCallout(.bottom)

            // Remaining facts, once each, quiet - the rest of the instrument readout
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
                ForEach(Array(quietFacts.enumerated()), id: \.offset) { _, fact in
                    calloutCapsule(fact.0, color: fact.1, dimmed: true)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .background(KOII.bg)
        .overlayPreferenceValue(BadgeAnchorsKey.self) { anchors in
            // Straight elbow traces, one per side - geometrically unable to cross
            GeometryReader { proxy in
                ForEach(visibleSegments, id: \.self) { segment in
                    if let side = sideAssignment[segment],
                       let segmentAnchor = anchors[.segment(segment)],
                       let calloutAnchor = anchors[.callout(segment)] {
                        let from = proxy[segmentAnchor]
                        let to = proxy[calloutAnchor]
                        let isHorizontal = (side == .left || side == .right)
                        let nodeOffset: CGFloat = 8
                        let node = isHorizontal
                            ? CGPoint(x: from.x + (side == .left ? -nodeOffset : nodeOffset), y: from.y)
                            : CGPoint(x: from.x, y: from.y + (side == .top ? -nodeOffset : nodeOffset))

                        Path { path in
                            path.move(to: node)
                            if isHorizontal {
                                if abs(node.y - to.y) < 6 {
                                    // Already aligned: clean straight run
                                } else {
                                    let midX = (node.x + to.x) / 2
                                    path.addLine(to: CGPoint(x: midX, y: node.y))
                                    path.addLine(to: CGPoint(x: midX, y: to.y))
                                }
                            } else {
                                if abs(node.x - to.x) < 6 {
                                    // Already aligned: clean straight drop
                                } else {
                                    let midY = (node.y + to.y) / 2
                                    path.addLine(to: CGPoint(x: node.x, y: midY))
                                    path.addLine(to: CGPoint(x: to.x, y: midY))
                                }
                            }
                            path.addLine(to: to)
                        }
                        .stroke(segmentColor(segment).opacity(0.6), lineWidth: 1.5)

                        // Inverted node: black core, colored ring - marks the trace origin
                        Circle()
                            .fill(KOII.bg)
                            .stroke(segmentColor(segment), lineWidth: 1.5)
                            .frame(width: 9, height: 9)
                            .position(node)
                    }
                }
            }
        }
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

    // MARK: Review section (actions, not numbers)

    private var queueSection: some View {
        VStack(spacing: 1) {
            HStack {
                Text("REVIEW").font(KOII.mono(8, weight: .heavy)).foregroundStyle(KOII.amber)
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
                    Text("+\(reviewQueue.items.count - 3) MORE → REVIEW")
                        .font(KOII.mono(8)).foregroundStyle(KOII.dim)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 2)
                .background(KOII.cell)
            }
        }
    }

    // MARK: Send section (outbound drafts that still need to go out)

    private var sendSection: some View {
        VStack(spacing: 1) {
            HStack {
                Text("TO SEND").font(KOII.mono(8, weight: .heavy)).foregroundStyle(state.sendUrgency.koColor)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(KOII.cell)

            ForEach(pendingDrafts.prefix(2)) { draft in
                let overdue = draft.dueDate < Date()
                let soon = !overdue && draft.dueDate.timeIntervalSinceNow < 7 * 24 * 3600
                HStack(spacing: 6) {
                    Text(draft.invoiceNumber).font(KOII.mono(9)).foregroundStyle(KOII.text)
                    Text(draft.recipient.company ?? draft.recipient.name)
                        .font(KOII.mono(9)).foregroundStyle(KOII.dim).lineLimit(1)
                    Spacer()
                    Text(draft.dueDate, format: .dateTime.day(.twoDigits).month(.twoDigits))
                        .font(KOII.mono(9, weight: .heavy))
                        .foregroundStyle(overdue ? KOII.red : (soon ? KOII.amber : KOII.teal))
                    Button {
                        openSection(.drafts)
                    } label: {
                        Text("[SEND→]").font(KOII.mono(9, weight: .heavy)).foregroundStyle(KOII.teal)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(KOII.cell)
            }
        }
    }

    // MARK: Footer navigation

    private func openSection(_ section: DocumentFilter) {
        openWindow(id: "library")
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .rffOpenSection, object: section.rawValue)
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
            HStack(spacing: 1) {
                footerButton("LIBRARY") { openSection(.confirmed) }
                footerButton(
                    state.queueCount > 0 ? "REVIEW·\(state.queueCount)" : "REVIEW",
                    color: state.queueCount > 0 ? KOII.amber : KOII.text
                ) { openSection(.review) }
                footerButton(
                    state.sendCount > 0 ? "SEND·\(state.sendCount)" : "OUTBOUND",
                    color: state.sendCount > 0 ? state.sendUrgency.koColor : KOII.text
                ) { openSection(.drafts) }
                footerButton("REPORT", color: KOII.amber) { openSection(.reporting) }
            }
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
