import SwiftUI
import AppKit
import QuickLookUI

/// Full manual confirmation queue: documents the AI cascade could not decide on
struct ReviewQueueView: View {
    @ObservedObject var reviewQueue = ReviewQueueStore.shared
    @ObservedObject var coordinator = MonitoringCoordinator.shared
    @State private var selectedItem: ReviewQueueItem?

    var body: some View {
        NavigationSplitView {
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
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
            .overlay {
                if reviewQueue.items.isEmpty {
                    ContentUnavailableView(
                        "Queue is empty",
                        systemImage: "checkmark.seal",
                        description: Text("Documents the AI can't confidently classify will appear here.")
                    )
                }
            }
        } detail: {
            if let item = selectedItem {
                ReviewItemDetail(item: item) { approved in
                    if approved {
                        coordinator.approveReviewItem(item)
                    } else {
                        coordinator.rejectReviewItem(item)
                    }
                    selectedItem = nil
                }
            } else {
                Text("Select a document").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Confirmation Queue")
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

    var body: some View {
        VStack(spacing: 0) {
            // Document preview
            QuickLookPreview(url: item.fileURL)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    ReviewConfidenceBadge(confidence: item.confidence, stage: item.stage)
                    if let primary = item.primaryConfidence {
                        Text("Apple Intelligence said \(Int(primary * 100))%")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(ConfigManager.shared.config.usesArchiveFiling
                         ? "Will be archived and added to the library"
                         : "Would file to \(AccountantReportService.folderName(for: item.suggestedDate))")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if !item.organizations.isEmpty {
                    Text("Organizations: \(item.organizations.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Text(item.textSnippet)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(4)

                HStack {
                    Button {
                        decide(false)
                    } label: {
                        Label("Not an Invoice", systemImage: "xmark.circle")
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
                        Label("Confirm Invoice & File", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
        }
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
