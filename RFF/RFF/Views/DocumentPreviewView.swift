import SwiftUI
import PDFKit
import AppKit

// MARK: - Highlight Types

/// Type of data being highlighted
enum HighlightType {
    case amount
    case date

    var color: NSColor {
        switch self {
        case .amount:
            return NSColor.systemGreen.withAlphaComponent(0.3)
        case .date:
            return NSColor.systemBlue.withAlphaComponent(0.3)
        }
    }
}

/// A highlight annotation for document preview
struct DocumentHighlight: Identifiable {
    let id: UUID
    let boundingBox: CGRect
    let label: String
    let type: HighlightType
    let pageIndex: Int

    init(boundingBox: CGRect, label: String, type: HighlightType, pageIndex: Int = 0) {
        self.id = UUID()
        self.boundingBox = boundingBox
        self.label = label
        self.type = type
        self.pageIndex = pageIndex
    }
}

// MARK: - Document Preview View

/// Interactive document viewer that displays PDFs or images with highlight overlays
struct DocumentPreviewView: View {
    /// URL of the document to display
    let documentURL: URL?

    /// Raw image data (for clipboard-pasted images)
    let imageData: Data?

    /// Highlights to display over the document
    let highlights: [DocumentHighlight]

    /// Currently selected highlight
    @Binding var selectedHighlight: DocumentHighlight?

    /// Whether the document is a PDF
    private var isPDF: Bool {
        documentURL?.pathExtension.lowercased() == "pdf"
    }

    init(
        documentURL: URL?,
        highlights: [DocumentHighlight] = [],
        selectedHighlight: Binding<DocumentHighlight?> = .constant(nil)
    ) {
        self.documentURL = documentURL
        self.imageData = nil
        self.highlights = highlights
        self._selectedHighlight = selectedHighlight
    }

    init(
        imageData: Data,
        highlights: [DocumentHighlight] = [],
        selectedHighlight: Binding<DocumentHighlight?> = .constant(nil)
    ) {
        self.documentURL = nil
        self.imageData = imageData
        self.highlights = highlights
        self._selectedHighlight = selectedHighlight
    }

    var body: some View {
        Group {
            if isPDF, let url = documentURL {
                PDFPreviewView(
                    url: url,
                    highlights: highlights,
                    selectedHighlight: $selectedHighlight
                )
            } else if let url = documentURL {
                ImagePreviewView(
                    url: url,
                    highlights: highlights,
                    selectedHighlight: $selectedHighlight
                )
            } else if let data = imageData {
                ImagePreviewView(
                    imageData: data,
                    highlights: highlights,
                    selectedHighlight: $selectedHighlight
                )
            } else {
                ContentUnavailableView(
                    "No Document",
                    systemImage: "doc.questionmark",
                    description: Text("Select a document to preview")
                )
            }
        }
    }
}

// MARK: - PDF Preview View

/// PDF viewer with highlight overlay support
private struct PDFPreviewView: View {
    let url: URL
    let highlights: [DocumentHighlight]
    @Binding var selectedHighlight: DocumentHighlight?

    @State private var pdfDocument: PDFDocument?

    var body: some View {
        PDFViewer(
            document: pdfDocument,
            highlights: highlights.compactMap { highlight -> HighlightRegion? in
                // Convert normalized Vision coordinates to PDF page coordinates
                guard let pdf = pdfDocument,
                      highlight.pageIndex < pdf.pageCount,
                      let page = pdf.page(at: highlight.pageIndex) else {
                    return nil
                }

                let pageBounds = page.bounds(for: .mediaBox)
                let pdfRect = convertNormalizedToPDF(highlight.boundingBox, pageSize: pageBounds.size)

                return HighlightRegion(
                    pageIndex: highlight.pageIndex,
                    bounds: pdfRect,
                    color: highlight.type.color,
                    label: highlight.label
                )
            }
        )
        .onAppear {
            pdfDocument = PDFDocument(url: url)
        }
    }

    /// Convert normalized bounding box (0-1, bottom-left origin) to PDF coordinates
    private func convertNormalizedToPDF(_ normalizedBox: CGRect, pageSize: CGSize) -> CGRect {
        // Vision uses normalized coords (0-1) with origin at bottom-left
        // PDF uses points with origin at bottom-left (same origin, just scale)
        return CGRect(
            x: normalizedBox.origin.x * pageSize.width,
            y: normalizedBox.origin.y * pageSize.height,
            width: normalizedBox.width * pageSize.width,
            height: normalizedBox.height * pageSize.height
        )
    }
}

// MARK: - Image Preview View

/// Image viewer with highlight overlay support using NSImage
private struct ImagePreviewView: View {
    let url: URL?
    let imageData: Data?
    let highlights: [DocumentHighlight]
    @Binding var selectedHighlight: DocumentHighlight?

    @State private var image: NSImage?
    @State private var imageSize: CGSize = .zero

    init(
        url: URL,
        highlights: [DocumentHighlight],
        selectedHighlight: Binding<DocumentHighlight?>
    ) {
        self.url = url
        self.imageData = nil
        self.highlights = highlights
        self._selectedHighlight = selectedHighlight
    }

    init(
        imageData: Data,
        highlights: [DocumentHighlight],
        selectedHighlight: Binding<DocumentHighlight?>
    ) {
        self.url = nil
        self.imageData = imageData
        self.highlights = highlights
        self._selectedHighlight = selectedHighlight
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    if let image = image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(
                                maxWidth: geometry.size.width,
                                maxHeight: geometry.size.height
                            )
                            .background(
                                GeometryReader { imageGeometry in
                                    Color.clear
                                        .onAppear {
                                            imageSize = imageGeometry.size
                                        }
                                        .onChange(of: imageGeometry.size) { _, newSize in
                                            imageSize = newSize
                                        }
                                }
                            )

                        // Overlay highlights
                        ForEach(highlights) { highlight in
                            HighlightOverlay(
                                highlight: highlight,
                                imageSize: imageSize,
                                isSelected: selectedHighlight?.id == highlight.id
                            )
                            .onTapGesture {
                                selectedHighlight = highlight
                            }
                        }
                    } else {
                        ProgressView("Loading image...")
                    }
                }
            }
        }
        .onAppear {
            loadImage()
        }
    }

    private func loadImage() {
        if let url = url {
            image = NSImage(contentsOf: url)
        } else if let data = imageData {
            image = NSImage(data: data)
        }
    }
}

// MARK: - Highlight Overlay

/// A single highlight overlay for an image
private struct HighlightOverlay: View {
    let highlight: DocumentHighlight
    let imageSize: CGSize
    let isSelected: Bool

    var body: some View {
        let rect = convertBoundingBox(highlight.boundingBox, to: imageSize)

        ZStack(alignment: .topLeading) {
            // Highlight rectangle
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(nsColor: highlight.type.color))
                .frame(width: rect.width, height: rect.height)

            // Selection border
            if isSelected {
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(Color(nsColor: highlight.type.color.withAlphaComponent(1.0)), lineWidth: 2)
                    .frame(width: rect.width, height: rect.height)
            }

            // Label tooltip on hover
            if isSelected {
                Text(highlight.label)
                    .font(.caption)
                    .padding(4)
                    .background(.ultraThinMaterial)
                    .cornerRadius(4)
                    .offset(y: -24)
            }
        }
        .position(x: rect.midX, y: rect.midY)
    }

    /// Convert normalized bounding box (0-1) to view coordinates
    /// Vision framework returns bounding boxes with origin at bottom-left, normalized to 0-1
    private func convertBoundingBox(_ box: CGRect, to size: CGSize) -> CGRect {
        // Vision bounding boxes are normalized (0-1) with origin at bottom-left
        // SwiftUI coordinates have origin at top-left
        let x = box.origin.x * size.width
        let y = (1 - box.origin.y - box.height) * size.height
        let width = box.width * size.width
        let height = box.height * size.height

        return CGRect(x: x, y: y, width: width, height: height)
    }
}

// MARK: - ExtractedData Conversion

extension DocumentPreviewView {
    /// Create highlights from ExtractedData
    static func highlights(from extractedData: ExtractedData, pageIndex: Int = 0) -> [DocumentHighlight] {
        var highlights: [DocumentHighlight] = []

        // Add amount highlights
        for amount in extractedData.amounts {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = "USD"
            let label = formatter.string(from: amount.value as NSDecimalNumber) ?? amount.rawText

            highlights.append(DocumentHighlight(
                boundingBox: amount.boundingBox,
                label: label,
                type: .amount,
                pageIndex: pageIndex
            ))
        }

        // Add date highlights
        for date in extractedData.dates {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            let label = formatter.string(from: date.date)

            highlights.append(DocumentHighlight(
                boundingBox: date.boundingBox,
                label: label,
                type: .date,
                pageIndex: pageIndex
            ))
        }

        return highlights
    }
}

// MARK: - Preview

#Preview("PDF Preview") {
    DocumentPreviewView(documentURL: nil)
        .frame(width: 600, height: 800)
}

#Preview("With Highlights") {
    let highlights = [
        DocumentHighlight(
            boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.05),
            label: "$1,234.56",
            type: .amount
        ),
        DocumentHighlight(
            boundingBox: CGRect(x: 0.5, y: 0.3, width: 0.15, height: 0.04),
            label: "Jan 15, 2026",
            type: .date
        )
    ]

    return DocumentPreviewView(
        documentURL: nil,
        highlights: highlights
    )
    .frame(width: 600, height: 800)
}
