import SwiftUI
import PDFKit

/// A region to highlight in the PDF
struct HighlightRegion: Identifiable {
    let id = UUID()
    /// The page index (0-based)
    let pageIndex: Int
    /// The bounds of the region to highlight (in PDF page coordinates)
    let bounds: CGRect
    /// The highlight color
    let color: NSColor
    /// Optional label for the highlight
    let label: String?

    init(pageIndex: Int, bounds: CGRect, color: NSColor = .yellow.withAlphaComponent(0.3), label: String? = nil) {
        self.pageIndex = pageIndex
        self.bounds = bounds
        self.color = color
        self.label = label
    }
}

/// SwiftUI wrapper for PDFKit's PDFView
struct PDFViewer: NSViewRepresentable {
    let document: PDFDocument?
    let highlights: [HighlightRegion]

    init(document: PDFDocument?, highlights: [HighlightRegion] = []) {
        self.document = document
        self.highlights = highlights
    }

    init(url: URL, highlights: [HighlightRegion] = []) {
        self.document = PDFDocument(url: url)
        self.highlights = highlights
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.document = document

        if !highlights.isEmpty {
            pdfView.pageOverlayViewProvider = context.coordinator
        }

        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        if pdfView.document !== document {
            pdfView.document = document
        }

        context.coordinator.highlights = highlights

        // Clear and reset provider to force PDFKit to recreate overlay views
        // PDFKit caches overlays and won't call the delegate again otherwise
        pdfView.pageOverlayViewProvider = nil
        if !highlights.isEmpty {
            pdfView.pageOverlayViewProvider = context.coordinator
        }

        // Force layout refresh to ensure overlays are redrawn
        pdfView.layoutDocumentView()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(highlights: highlights)
    }

    class Coordinator: NSObject, PDFPageOverlayViewProvider {
        var highlights: [HighlightRegion]

        init(highlights: [HighlightRegion]) {
            self.highlights = highlights
        }

        func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
            guard let pageIndex = view.document?.index(for: page) else {
                return nil
            }

            let pageHighlights = highlights.filter { $0.pageIndex == pageIndex }
            guard !pageHighlights.isEmpty else {
                return nil
            }

            return HighlightOverlayView(highlights: pageHighlights, page: page)
        }
    }
}

/// Overlay view that draws highlights on a PDF page
private class HighlightOverlayView: NSView {
    let highlights: [HighlightRegion]
    let page: PDFPage

    init(highlights: [HighlightRegion], page: PDFPage) {
        self.highlights = highlights
        self.page = page
        super.init(frame: .zero)
        self.wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        for highlight in highlights {
            // Convert PDF coordinates to view coordinates
            let viewBounds = convert(highlight.bounds, from: page)

            context.setFillColor(highlight.color.cgColor)
            context.fill(viewBounds)
        }
    }

    /// Convert bounds from PDF page coordinates to view coordinates
    /// PDF/Vision uses bottom-left origin, NSView overlay uses top-left origin (flipped)
    private func convert(_ rect: CGRect, from page: PDFPage) -> CGRect {
        let pageBounds = page.bounds(for: .mediaBox)

        // Guard against division by zero
        guard pageBounds.width > 0, pageBounds.height > 0,
              bounds.width > 0, bounds.height > 0 else {
            return .zero
        }

        let scaleX = bounds.width / pageBounds.width
        let scaleY = bounds.height / pageBounds.height

        // Flip Y coordinate: PDF origin is bottom-left, view origin is top-left
        // rect.origin.y is distance from bottom, we need distance from top
        let flippedY = pageBounds.height - rect.origin.y - rect.height

        return CGRect(
            x: rect.origin.x * scaleX,
            y: flippedY * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )
    }
}

#Preview {
    PDFViewer(document: nil)
        .frame(width: 600, height: 800)
}
