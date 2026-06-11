import AppKit
import Foundation
import FoundationModels
import ImageIO
import PDFKit
import Vision

/// Structured verdict produced by the on-device model via guided generation
@Generable
struct InvoiceVerdict {
    @Guide(description: "Confidence from 0.0 to 1.0 that this document is an invoice, i.e. a bill requesting payment (also Rechnung, facture, factura).")
    let invoiceConfidence: Double

    @Guide(description: "All distinct company/organization names mentioned in the document, exactly as written. No addresses, no people, no duplicates. Empty if none.")
    let organizations: [String]
}

@main
struct LsIsInvoice {
    static let supportedExtensions: Set<String> = [
        "pdf", "txt", "png", "jpg", "jpeg", "tiff", "tif", "heic", "webp", "gif", "bmp"
    ]

    static func main() async {
        let args = CommandLine.arguments.dropFirst()
        if args.contains("-h") || args.contains("--help") || args.count > 1 {
            print("usage: ls-isinvoice [folder]")
            print("Classifies each PDF/image/txt in the folder with on-device Apple Intelligence.")
            exit(args.count > 1 ? 1 : 0)
        }

        let dir = URL(
            fileURLWithPath: ((args.first ?? ".") as NSString).expandingTildeInPath,
            isDirectory: true
        )

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            fail("not a folder: \(dir.path)")
        }

        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            fail("Apple Intelligence model unavailable: \(reason)")
        }

        let files = ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? [])
            .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard !files.isEmpty else {
            fail("no PDF/image/txt files in \(dir.path)")
        }

        let nameWidth = files.map { $0.lastPathComponent.count }.max() ?? 0

        for file in files {
            let name = file.lastPathComponent.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            let text = (try? await extractText(from: file)) ?? ""
            guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 10 else {
                print("\(name)  no readable text")
                continue
            }
            do {
                let verdict = try await classify(text: text)
                var seen = Set<String>()
                let organizations = verdict.organizations
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
                let orgsPart = organizations.isEmpty ? "-" : organizations.joined(separator: ", ")
                print("\(name)  invoice: \(percent(verdict.invoiceConfidence))  orgs: \(orgsPart)")
            } catch {
                print("\(name)  error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Classification

    static func classify(text: String) async throws -> InvoiceVerdict {
        // Fresh session per file so documents don't bleed into each other's context
        let session = LanguageModelSession(instructions: """
            You classify documents. Given OCR or extracted text, decide whether it is an \
            invoice - a bill requesting payment (invoice, Rechnung, facture, factura). \
            Receipts, contracts, letters, and statements are not invoices. \
            Also list every company or organization name that appears in the text, \
            exactly as written.
            """)
        let prompt = "Document text:\n\"\"\"\n\(text.prefix(3000))\n\"\"\""
        let response = try await session.respond(to: prompt, generating: InvoiceVerdict.self)
        return response.content
    }

    // MARK: - Text Extraction

    static func extractText(from url: URL) async throws -> String {
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let doc = PDFDocument(url: url) else { return "" }
            let embedded = (0..<min(doc.pageCount, 3))
                .compactMap { doc.page(at: $0)?.string }
                .joined(separator: "\n")
            if embedded.trimmingCharacters(in: .whitespacesAndNewlines).count >= 40 {
                return embedded
            }
            // Scanned PDF: OCR the first pages instead
            var ocr = ""
            for index in 0..<min(doc.pageCount, 2) {
                if let page = doc.page(at: index), let image = render(page) {
                    ocr += try await recognizeText(in: image) + "\n"
                }
            }
            return ocr.isEmpty ? embedded : ocr
        case "txt":
            return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        default:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                return ""
            }
            return try await recognizeText(in: image)
        }
    }

    static func recognizeText(in image: CGImage) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let observations = try await request.perform(on: image)
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2.0
        let image = page.thumbnail(
            of: CGSize(width: bounds.width * scale, height: bounds.height * scale),
            for: .mediaBox
        )
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    // MARK: - Helpers

    static func percent(_ value: Double) -> String {
        String(format: "%3.0f%%", min(max(value, 0), 1) * 100)
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("ls-isinvoice: \(message)\n".utf8))
        exit(1)
    }
}
