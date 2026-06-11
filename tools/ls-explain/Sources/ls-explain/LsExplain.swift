import AppKit
import Foundation
import ImageIO
import PDFKit
import Vision

/// Everything we can learn about a file without AI - fed to Ollama as evidence
struct FileEvidence {
    let name: String
    let sizeBytes: Int64
    let created: Date?
    let modified: Date?
    /// Download URLs from com.apple.metadata:kMDItemWhereFroms
    let whereFroms: [String]
    /// Downloading app from com.apple.quarantine (e.g. "Safari", "Slack")
    let quarantineAgent: String?
    let quarantineDate: Date?
    /// Extracted text snippet for documents/images, nil for binaries
    let contentSnippet: String?
}

@main
struct LsExplain {
    static let textExtensions: Set<String> = ["txt", "md", "csv", "json", "log", "xml", "yml", "yaml"]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tiff", "tif", "heic", "webp", "gif", "bmp"]

    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        var modelOverride: String?
        if let flagIndex = arguments.firstIndex(of: "--model"), flagIndex + 1 < arguments.count {
            modelOverride = arguments[flagIndex + 1]
            arguments.removeSubrange(flagIndex...flagIndex + 1)
        }
        if arguments.contains("-h") || arguments.contains("--help") || arguments.count > 1 {
            print("usage: ls-explain [--model <ollama-model>] [folder]")
            print("Explains every file in the folder (what it is, where it came from) using local Ollama.")
            exit(arguments.count > 1 ? 1 : 0)
        }

        let dir = URL(
            fileURLWithPath: ((arguments.first ?? ".") as NSString).expandingTildeInPath,
            isDirectory: true
        )

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            fail("not a folder: \(dir.path)")
        }

        guard let model = await resolveModel(override: modelOverride) else {
            fail("Ollama is not running at 127.0.0.1:11434 or has no models installed")
        }
        FileHandle.standardError.write(Data("ls-explain: using \(model)\n".utf8))

        let files = ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? [])
            .filter { !((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard !files.isEmpty else {
            fail("no files in \(dir.path)")
        }

        for file in files {
            let evidence = await gatherEvidence(for: file)
            print(file.lastPathComponent)
            do {
                let verdict = try await explain(evidence: evidence, model: model)
                print("  what: \(verdict.what)")
                print("  from: \(verdict.from)")
            } catch {
                print("  error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Evidence Gathering

    static func gatherEvidence(for url: URL) async -> FileEvidence {
        let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]

        var snippet: String?
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            snippet = try? await extractDocumentText(from: url)
        } else if textExtensions.contains(ext) {
            snippet = try? String(contentsOf: url, encoding: .utf8)
        } else if imageExtensions.contains(ext) {
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                snippet = try? await recognizeText(in: image)
            }
        }

        let quarantine = quarantineInfo(for: url)

        return FileEvidence(
            name: url.lastPathComponent,
            sizeBytes: (attributes[.size] as? Int64) ?? 0,
            created: attributes[.creationDate] as? Date,
            modified: attributes[.modificationDate] as? Date,
            whereFroms: whereFroms(for: url),
            quarantineAgent: quarantine.agent,
            quarantineDate: quarantine.date,
            contentSnippet: snippet?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Download URLs recorded by macOS when the file arrived (browser, mail, AirDrop...)
    static func whereFroms(for url: URL) -> [String] {
        guard let data = xattr(url, name: "com.apple.metadata:kMDItemWhereFroms"),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let urls = plist as? [String] else {
            return []
        }
        return urls
    }

    /// Quarantine attribute: "flags;hex-timestamp;AgentName;UUID"
    static func quarantineInfo(for url: URL) -> (agent: String?, date: Date?) {
        guard let data = xattr(url, name: "com.apple.quarantine"),
              let string = String(data: data, encoding: .utf8) else {
            return (nil, nil)
        }
        let parts = string.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        let agent = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
        var date: Date?
        if parts.count > 1, let seconds = UInt64(parts[1], radix: 16), seconds > 0 {
            date = Date(timeIntervalSince1970: TimeInterval(seconds))
        }
        return (agent, date)
    }

    static func xattr(_ url: URL, name: String) -> Data? {
        let length = getxattr(url.path, name, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let result = data.withUnsafeMutableBytes { buffer in
            getxattr(url.path, name, buffer.baseAddress, length, 0, 0)
        }
        return result > 0 ? data : nil
    }

    // MARK: - Ollama

    static let ollamaBase = URL(string: "http://127.0.0.1:11434")!

    /// Pick the model: explicit override, else the largest installed one
    static func resolveModel(override: String?) async -> String? {
        var request = URLRequest(url: ollamaBase.appendingPathComponent("api/tags"))
        request.timeoutInterval = 3
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]], !models.isEmpty else {
            return nil
        }

        let names = models.compactMap { $0["name"] as? String }
        if let override {
            return names.first { $0 == override || $0.hasPrefix(override + ":") } ?? override
        }

        func parameterBillions(_ model: [String: Any]) -> Double {
            let size = ((model["details"] as? [String: Any])?["parameter_size"] as? String ?? "")
                .uppercased()
            let value = Double(size.filter { $0.isNumber || $0 == "." }) ?? 0
            return size.hasSuffix("M") ? value / 1000 : value
        }

        return models
            .filter { !(($0["name"] as? String) ?? "").localizedCaseInsensitiveContains("embed") }
            .max { parameterBillions($0) < parameterBillions($1) }?["name"] as? String
    }

    struct Explanation {
        let what: String
        let from: String
    }

    static func explain(evidence: FileEvidence, model: String) async throws -> Explanation {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"

        var facts: [String] = []
        facts.append("filename: \(evidence.name)")
        facts.append("size: \(ByteCountFormatter.string(fromByteCount: evidence.sizeBytes, countStyle: .file))")
        if let created = evidence.created {
            facts.append("created: \(dateFormatter.string(from: created))")
        }
        if let modified = evidence.modified {
            facts.append("modified: \(dateFormatter.string(from: modified))")
        }
        if !evidence.whereFroms.isEmpty {
            facts.append("downloaded from: \(evidence.whereFroms.prefix(2).joined(separator: " , "))")
        }
        if let agent = evidence.quarantineAgent {
            facts.append("received via app: \(agent)")
        }
        if let quarantineDate = evidence.quarantineDate {
            facts.append("received at: \(dateFormatter.string(from: quarantineDate))")
        }
        if let snippet = evidence.contentSnippet, !snippet.isEmpty {
            facts.append("content excerpt:\n\"\"\"\n\(snippet.prefix(1500))\n\"\"\"")
        }

        // Origin is decided by metadata, not by the model - small models happily
        // hallucinate download stories for files that have no provenance at all
        let hasOrigin = !evidence.whereFroms.isEmpty || evidence.quarantineAgent != nil

        let prompt: String
        if hasOrigin {
            prompt = """
            You are a file librarian. Based ONLY on the evidence below, explain this file.
            Respond with JSON exactly like {"what": "...", "from": "..."}.
            - "what": one short sentence - what the file is and what it contains.
            - "from": one short sentence - where it came from, strictly from the \
            "downloaded from" / "received via app" / "received at" facts. Never invent sources.
            Be concrete and terse. No hedging filler.

            Evidence:
            \(facts.joined(separator: "\n"))
            """
        } else {
            prompt = """
            You are a file librarian. Based ONLY on the evidence below, explain this file.
            Respond with JSON exactly like {"what": "..."}.
            - "what": one short sentence - what the file is and what it contains.
            Be concrete and terse. No hedging filler.

            Evidence:
            \(facts.joined(separator: "\n"))
            """
        }

        var request = URLRequest(url: ollamaBase.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600

        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "stream": false,
            "format": "json",
            "options": ["temperature": 0.2, "num_ctx": 8192]
        ] as [String: Any])

        let session = URLSession(configuration: {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 600
            config.timeoutIntervalForResource = 600
            return config
        }())

        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String,
              let contentData = content.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any] else {
            throw NSError(domain: "ls-explain", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "unexpected Ollama response"
            ])
        }

        let fallbackOrigin: String
        if let created = evidence.created {
            fallbackOrigin = "no download record · likely created locally on \(dateFormatter.string(from: created))"
        } else {
            fallbackOrigin = "no download record · likely created locally"
        }

        return Explanation(
            what: (parsed["what"] as? String) ?? "?",
            from: hasOrigin ? ((parsed["from"] as? String) ?? "?") : fallbackOrigin
        )
    }

    // MARK: - Text Extraction (same approach as ls-isinvoice)

    static func extractDocumentText(from url: URL) async throws -> String {
        guard let document = PDFDocument(url: url) else { return "" }
        let embedded = (0..<min(document.pageCount, 3))
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")
        if embedded.trimmingCharacters(in: .whitespacesAndNewlines).count >= 40 {
            return embedded
        }
        var ocr = ""
        for index in 0..<min(document.pageCount, 2) {
            if let page = document.page(at: index), let image = render(page) {
                ocr += try await recognizeText(in: image) + "\n"
            }
        }
        return ocr.isEmpty ? embedded : ocr
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
        let image = page.thumbnail(
            of: CGSize(width: bounds.width * 2, height: bounds.height * 2),
            for: .mediaBox
        )
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    // MARK: - Helpers

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("ls-explain: \(message)\n".utf8))
        exit(1)
    }
}
