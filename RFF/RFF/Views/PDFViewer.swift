import SwiftUI
import PDFKit

/// Color scheme for different field types in PDF highlights
enum FieldHighlightColor {
    static func color(for fieldType: InvoiceFieldType?) -> NSColor {
        guard let fieldType = fieldType else {
            return .yellow.withAlphaComponent(0.3)
        }
        switch fieldType {
        case .total, .subtotal, .tax, .lineItemTotal, .lineItemUnitPrice:
            return NSColor.systemGreen.withAlphaComponent(0.3)
        case .invoiceDate, .dueDate:
            return NSColor.systemBlue.withAlphaComponent(0.3)
        case .vendor, .vendorAddress:
            return NSColor.systemOrange.withAlphaComponent(0.3)
        case .invoiceNumber, .poNumber:
            return NSColor.systemPurple.withAlphaComponent(0.3)
        case .customerName, .customerAddress:
            return NSColor.systemTeal.withAlphaComponent(0.3)
        case .lineItemDescription, .lineItemQuantity:
            return NSColor.systemGray.withAlphaComponent(0.3)
        case .currency, .paymentTerms:
            return NSColor.systemIndigo.withAlphaComponent(0.3)
        }
    }

    static var legendItems: [(fieldType: InvoiceFieldType, color: NSColor, label: String)] {
        [
            (.total, NSColor.systemGreen, "Amount"),
            (.invoiceDate, NSColor.systemBlue, "Date"),
            (.vendor, NSColor.systemOrange, "Vendor"),
            (.invoiceNumber, NSColor.systemPurple, "Invoice #"),
            (.customerName, NSColor.systemTeal, "Customer"),
            (.lineItemDescription, NSColor.systemGray, "Line Item"),
            (.currency, NSColor.systemIndigo, "Terms"),
        ]
    }
}

/// A region to highlight in the PDF
struct HighlightRegion: Identifiable, Equatable {
    let id: UUID
    /// The page index (0-based)
    let pageIndex: Int
    /// The bounds of the region to highlight (in PDF page coordinates)
    let bounds: CGRect
    /// The highlight color
    let color: NSColor
    /// Optional label for the highlight
    let label: String?
    /// The detected field type (if any)
    let fieldType: InvoiceFieldType?

    init(
        id: UUID = UUID(),
        pageIndex: Int,
        bounds: CGRect,
        color: NSColor? = nil,
        label: String? = nil,
        fieldType: InvoiceFieldType? = nil
    ) {
        self.id = id
        self.pageIndex = pageIndex
        self.bounds = bounds
        self.color = color ?? FieldHighlightColor.color(for: fieldType)
        self.label = label
        self.fieldType = fieldType
    }

    static func == (lhs: HighlightRegion, rhs: HighlightRegion) -> Bool {
        lhs.id == rhs.id
    }
}

/// SwiftUI wrapper for PDFKit's PDFView
struct PDFViewer: NSViewRepresentable {
    let document: PDFDocument?
    let highlights: [HighlightRegion]
    let selectedHighlightId: UUID?
    var onHighlightTapped: ((HighlightRegion) -> Void)?

    init(
        document: PDFDocument?,
        highlights: [HighlightRegion] = [],
        selectedHighlightId: UUID? = nil,
        onHighlightTapped: ((HighlightRegion) -> Void)? = nil
    ) {
        self.document = document
        self.highlights = highlights
        self.selectedHighlightId = selectedHighlightId
        self.onHighlightTapped = onHighlightTapped
    }

    init(url: URL, highlights: [HighlightRegion] = []) {
        self.document = PDFDocument(url: url)
        self.highlights = highlights
        self.selectedHighlightId = nil
        self.onHighlightTapped = nil
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
        context.coordinator.selectedHighlightId = selectedHighlightId
        context.coordinator.onHighlightTapped = onHighlightTapped

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
        Coordinator(highlights: highlights, selectedHighlightId: selectedHighlightId, onHighlightTapped: onHighlightTapped)
    }

    class Coordinator: NSObject, PDFPageOverlayViewProvider {
        var highlights: [HighlightRegion]
        var selectedHighlightId: UUID?
        var onHighlightTapped: ((HighlightRegion) -> Void)?

        init(highlights: [HighlightRegion], selectedHighlightId: UUID?, onHighlightTapped: ((HighlightRegion) -> Void)?) {
            self.highlights = highlights
            self.selectedHighlightId = selectedHighlightId
            self.onHighlightTapped = onHighlightTapped
        }

        func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
            guard let pageIndex = view.document?.index(for: page) else {
                return nil
            }

            let pageHighlights = highlights.filter { $0.pageIndex == pageIndex }
            guard !pageHighlights.isEmpty else {
                return nil
            }

            let overlayView = HighlightOverlayView(
                highlights: pageHighlights,
                page: page,
                selectedHighlightId: selectedHighlightId,
                onHighlightTapped: onHighlightTapped
            )
            return overlayView
        }
    }
}

/// Overlay view that draws highlights on a PDF page
private class HighlightOverlayView: NSView {
    let highlights: [HighlightRegion]
    let page: PDFPage
    let selectedHighlightId: UUID?
    var onHighlightTapped: ((HighlightRegion) -> Void)?

    init(
        highlights: [HighlightRegion],
        page: PDFPage,
        selectedHighlightId: UUID? = nil,
        onHighlightTapped: ((HighlightRegion) -> Void)? = nil
    ) {
        self.highlights = highlights
        self.page = page
        self.selectedHighlightId = selectedHighlightId
        self.onHighlightTapped = onHighlightTapped
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
            let isSelected = highlight.id == selectedHighlightId

            // Draw fill
            context.setFillColor(highlight.color.cgColor)
            context.fill(viewBounds)

            // Draw border for selected highlight
            if isSelected {
                context.setStrokeColor(highlight.color.withAlphaComponent(1.0).cgColor)
                context.setLineWidth(2.0)
                context.stroke(viewBounds)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let locationInView = convert(event.locationInWindow, from: nil)

        // Check if click is within any highlight
        for highlight in highlights {
            let viewBounds = convert(highlight.bounds, from: page)
            if viewBounds.contains(locationInView) {
                onHighlightTapped?(highlight)
                return
            }
        }

        // If not in a highlight, call super to allow normal PDF interaction
        super.mouseDown(with: event)
    }

    /// Convert bounds from PDF page coordinates to view coordinates
    private func convert(_ rect: CGRect, from page: PDFPage) -> CGRect {
        let pageBounds = page.bounds(for: .mediaBox)

        // Guard against division by zero
        guard pageBounds.width > 0, pageBounds.height > 0,
              bounds.width > 0, bounds.height > 0 else {
            return .zero
        }

        let scaleX = bounds.width / pageBounds.width
        let scaleY = bounds.height / pageBounds.height

        return CGRect(
            x: rect.origin.x * scaleX,
            y: rect.origin.y * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )
    }
}

/// Compact horizontal legend bar showing what each highlight color represents
struct HighlightLegendView: View {
    var body: some View {
        HStack(spacing: 12) {
            ForEach(FieldHighlightColor.legendItems, id: \.fieldType) { item in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(nsColor: item.color.withAlphaComponent(0.4)))
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(Color(nsColor: item.color), lineWidth: 1)
                        )
                        .frame(width: 12, height: 12)

                    Text(item.label)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

#Preview {
    PDFViewer(document: nil)
        .frame(width: 600, height: 800)
}

#Preview("Legend") {
    HighlightLegendView()
        .padding()
}
