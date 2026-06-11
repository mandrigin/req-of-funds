import SwiftUI

/// Renders a draft invoice to a PDF file (US Letter) using the same
/// InvoicePreviewView the editor shows.
@MainActor
enum InvoicePDFRenderer {
    static func render(_ invoice: DraftInvoice, to fileURL: URL) {
        let previewView = InvoicePreviewView(invoice: invoice)
            .frame(width: 612, height: 792)  // US Letter at 72 DPI

        let renderer = ImageRenderer(content: previewView)
        renderer.scale = 2.0

        renderer.render { size, renderContext in
            var mediaBox = CGRect(origin: .zero, size: size)
            guard let context = CGContext(fileURL as CFURL, mediaBox: &mediaBox, nil) else {
                return
            }
            context.beginPDFPage(nil)
            renderContext(context)
            context.endPDFPage()
            context.closePDF()
        }
    }
}
