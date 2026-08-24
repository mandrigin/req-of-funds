import SwiftUI
import AppKit
import QuickLookUI

/// Full manual confirmation queue: documents the AI cascade could not decide on
struct ReviewQueueView: View {
    @ObservedObject var reviewQueue = ReviewQueueStore.shared
    @ObservedObject var coordinator = MonitoringCoordinator.shared
    @State private var selectedItem: ReviewQueueItem?

    var body: some View {
        HSplitView {
            List(reviewQueue.items, selection: $selectedItem) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.fileName).font(.headline).lineLimit(1)
                    HStack(spacing: 8) {
                        ReviewConfidenceBadge(confidence: item.confidence, stage: item.stage)
                        if !item.organizations.isEmpty {
                            Text(item.organizations.prefix(2).joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .padding(.vertical, 2)
                .tag(item)
            }
            .frame(minWidth: 240, idealWidth: 300, maxWidth: 400)
            .overlay {
                if reviewQueue.items.isEmpty {
                    ContentUnavailableView(
                        "Review is empty",
                        systemImage: "checkmark.seal",
                        description: Text("Documents the AI can't confidently classify will appear here.")
                    )
                }
            }

            Group {
                if let item = selectedItem {
                    ReviewItemDetail(item: item) { approved in
                        if approved {
                            coordinator.approveReviewItem(item)
                        } else {
                            coordinator.rejectReviewItem(item)
                        }
                        selectedItem = nil
                    }
                    .id(item.id)
                } else {
                    ContentUnavailableView(
                        "Select a Document",
                        systemImage: "doc.viewfinder",
                        description: Text("Choose a queued document to inspect its evidence before filing.")
                    )
                }
            }
            .frame(minWidth: 680, maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
        }
        .navigationTitle("Review")
        .onAppear { reviewQueue.prune() }
    }
}

private struct ReviewConfidenceBadge: View {
    let confidence: Float
    let stage: ClassificationStage

    var body: some View {
        Text("\(Int(confidence * 100))% · \(label)")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.orange.opacity(0.2))
            .clipShape(Capsule())
    }

    private var label: String {
        switch stage {
        case .appleIntelligence: return "Apple Intelligence"
        case .ollama: return "Ollama"
        case .keywords: return "keywords"
        }
    }
}

private struct ReviewItemDetail: View {
    let item: ReviewQueueItem
    let decide: (Bool) -> Void

    @State private var looksLikeInvoice = false
    @State private var checkedFields: Set<ReviewCheck> = []
    @State private var showingRejectReasons = false

    private var allRequiredChecksDone: Bool {
        checkedFields.isSuperset(of: Set(ReviewCheck.allCases))
    }

    var body: some View {
        HSplitView {
            // The preview flexes; the verification panel keeps a readable fixed band
            QuickLookPreview(url: item.fileURL)
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)

            verificationPanel
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 420, maxHeight: .infinity)
        }
    }

    private var verificationPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    evidenceSection
                    destinationSection
                    decisionSection
                }
                .padding()
            }

            Divider()

            footer
                .padding()
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .confirmationDialog(
            "Mark as not an invoice",
            isPresented: $showingRejectReasons,
            titleVisibility: .visible
        ) {
            Button("Receipt") { decide(false) }
            Button("Bank Document") { decide(false) }
            Button("Contract") { decide(false) }
            Button("Duplicate") { decide(false) }
            Button("Irrelevant File") { decide(false) }
            Button("Not an Invoice") { decide(false) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The reason is not stored yet, but choosing one slows the rejection down and makes the decision explicit.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.fileName)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                ReviewConfidenceBadge(confidence: item.confidence, stage: item.stage)
                if let primary = item.primaryConfidence {
                    Text("Apple Intelligence \(Int(primary * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Review slowly. Confirm the evidence before filing this document.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var evidenceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Evidence")

            EvidenceRow(label: "Sender candidates", value: organizationText, systemImage: "building.2")
            EvidenceRow(label: "Amount candidate", value: amountCandidate ?? "Not found in snippet", systemImage: "banknote")
            EvidenceRow(label: "Date candidate", value: item.suggestedDate.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
            EvidenceRow(label: "Classifier", value: "\(classificationStageText) at \(Int(item.confidence * 100))%", systemImage: "waveform.path.ecg")

            VStack(alignment: .leading, spacing: 6) {
                Label("Extracted snippet", systemImage: "text.quote")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(item.textSnippet)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(8)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Filing")

            EvidenceRow(
                label: "Result",
                value: ConfigManager.shared.config.usesArchiveFiling
                    ? "Archive and add to Library"
                    : "Folder \(AccountantReportService.folderName(for: item.suggestedDate))",
                systemImage: "archivebox"
            )
            EvidenceRow(label: "Original path", value: item.filePath, systemImage: "folder")
        }
    }

    private var decisionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Verification")

            Button {
                looksLikeInvoice.toggle()
                if !looksLikeInvoice {
                    checkedFields.removeAll()
                }
            } label: {
                Label(
                    looksLikeInvoice ? "Looks Like An Invoice" : "Mark As Invoice Candidate",
                    systemImage: looksLikeInvoice ? "checkmark.seal.fill" : "doc.badge.ellipsis"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(ReviewCheck.allCases) { check in
                    Toggle(isOn: Binding(
                        get: { checkedFields.contains(check) },
                        set: { isOn in
                            if isOn {
                                checkedFields.insert(check)
                            } else {
                                checkedFields.remove(check)
                            }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(check.title)
                            Text(check.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!looksLikeInvoice)
                }
            }
            .padding(.top, 4)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if looksLikeInvoice {
                Text(allRequiredChecksDone
                     ? "Ready to file."
                     : "Confirm every evidence check before filing.")
                    .font(.caption)
                    .foregroundStyle(allRequiredChecksDone ? .green : .secondary)
            }

            HStack {
                Button(role: .destructive) {
                    showingRejectReasons = true
                } label: {
                    Label("Not an Invoice...", systemImage: "xmark.circle")
                }

                Spacer()

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
                } label: {
                    Label("Reveal", systemImage: "magnifyingglass")
                }

                Button {
                    decide(true)
                } label: {
                    Label("File And Add To Library", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!looksLikeInvoice || !allRequiredChecksDone)
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
    }

    private var organizationText: String {
        item.organizations.isEmpty ? "Not found" : item.organizations.joined(separator: ", ")
    }

    private var classificationStageText: String {
        switch item.stage {
        case .appleIntelligence: return "Apple Intelligence"
        case .ollama: return "Ollama"
        case .keywords: return "Keywords"
        }
    }

    private var amountCandidate: String? {
        let pattern = #"(?:[$€£]|CHF|USD|EUR|GBP|SEK|NOK|DKK)\s?\d{1,3}(?:[,\s]\d{3})*(?:[.,]\d{2})?|\d{1,3}(?:[,\s]\d{3})*(?:[.,]\d{2})?\s?(?:CHF|USD|EUR|GBP|SEK|NOK|DKK)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(item.textSnippet.startIndex..<item.textSnippet.endIndex, in: item.textSnippet)
        guard let match = regex.firstMatch(in: item.textSnippet, range: range),
              let swiftRange = Range(match.range, in: item.textSnippet) else {
            return nil
        }
        return String(item.textSnippet[swiftRange])
    }
}

private enum ReviewCheck: String, CaseIterable, Identifiable {
    case documentType
    case organization
    case amountAndDate
    case destination

    var id: String { rawValue }

    var title: String {
        switch self {
        case .documentType: return "Document is an invoice or bill"
        case .organization: return "Sender or recipient makes sense"
        case .amountAndDate: return "Amount and date evidence looks plausible"
        case .destination: return "Filing destination is acceptable"
        }
    }

    var detail: String {
        switch self {
        case .documentType: return "The preview contains a payable invoice, not a receipt or contract."
        case .organization: return "The detected organization matches the visible document."
        case .amountAndDate: return "The extracted amount/date candidates match what you see."
        case .destination: return "The archive or monthly folder is the right target."
        }
    }
}

private struct EvidenceRow: View {
    let label: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Minimal QuickLook wrapper for previewing the queued file
struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.previewItem = url as QLPreviewItem
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        nsView.previewItem = url as QLPreviewItem
    }
}
