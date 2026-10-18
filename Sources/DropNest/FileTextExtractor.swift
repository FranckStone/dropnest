import Foundation
import PDFKit
import Vision
import ImageIO
import AppKit
import DropNestCore

struct ExtractedText: Sendable {
    var text = ""
    var truncated = false
}

enum FileTextExtractor {
    /// Invoice import also reads scanned PDFs; normal indexing keeps its existing bounded text path.
    static func extractInvoice(_ url: URL, limit: Int = 6000) -> ExtractedText {
        let text = extract(url, limit: limit)
        guard url.pathExtension.lowercased() == "pdf", text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let document = PDFDocument(url: url) else { return text }
        var lines: [String] = []
        for index in 0..<min(document.pageCount, 3) {
            guard let page = document.page(at: index) else { continue }
            let image = page.thumbnail(of: NSSize(width: 1600, height: 1600), for: .mediaBox)
            guard let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.recognitionLanguages = ["zh-Hans", "en-US"]
            if (try? VNImageRequestHandler(cgImage: bitmap).perform([request])) != nil {
                lines.append(contentsOf: (request.results ?? []).compactMap { $0.topCandidates(1).first?.string })
            }
            if lines.joined(separator: "\n").count >= limit { break }
        }
        let result = lines.joined(separator: "\n")
        return ExtractedText(text: String(result.prefix(limit)), truncated: document.pageCount > 3 || result.count > limit)
    }
    static let textExtensions: Set<String> = ["txt", "md", "csv", "tsv", "log", "json", "yaml", "yml", "xml", "html", "htm", "swift", "py", "js", "ts", "tsx", "jsx", "go", "rs", "java", "c", "cpp", "h", "css", "sh", "sql"]
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "webp", "bmp"]

    static func extract(_ url: URL, limit: Int = 60_000) -> ExtractedText {
        let ext = url.pathExtension.lowercased()
        var raw = ""
        var truncated = false
        if textExtensions.contains(ext) {
            guard let file = try? FileHandle(forReadingFrom: url) else { return ExtractedText() }
            defer { try? file.close() }
            let cap = limit * 4
            let data = (try? file.read(upToCount: cap + 1)) ?? Data()
            truncated = data.count > cap
            let bounded = data.prefix(cap)
            if bounded.starts(with: [0xff, 0xfe]) || bounded.starts(with: [0xfe, 0xff]) {
                raw = String(data: bounded, encoding: .utf16) ?? ""
            } else { raw = String(decoding: bounded, as: UTF8.self) }
            if ext == "html" || ext == "htm" { raw = readableHTML(raw) }
        } else if ext == "pdf", let document = PDFDocument(url: url) {
            let pages = min(document.pageCount, 100)
            for page in 0..<pages {
                raw += (document.page(at: page)?.string ?? "") + "\n"
                if raw.count >= limit { truncated = true; break }
            }
            if document.pageCount > pages { truncated = true }
        } else if ["rtf", "doc", "docx", "odt"].contains(ext) {
            let output = command("/usr/bin/textutil", ["-convert", "txt", "-stdout", url.path], cap: limit * 4)
            raw = String(decoding: output.data, as: UTF8.self); truncated = output.truncated
        } else if ["xlsx", "pptx"].contains(ext) {
            if let office = OfficeText.extract(url, pptx: ext == "pptx", limit: limit) {
                raw = office.text; truncated = office.truncated
            }
        } else if imageExtensions.contains(ext),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1600,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.recognitionLanguages = ["zh-Hans", "en-US"]
            if (try? VNImageRequestHandler(cgImage: thumbnail).perform([request])) != nil {
                raw = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            }
        }
        if raw.count > limit { truncated = true }
        return ExtractedText(text: String(raw.prefix(limit)), truncated: truncated)
    }

    private static func readableHTML(_ html: String) -> String {
        var text = html
        for pattern in [#"(?is)<script\b[^>]*>.*?</script\s*>"#, #"(?is)<style\b[^>]*>.*?</style\s*>"#, #"(?s)<!--.*?-->"#, #"(?s)<[^>]+>"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        for (entity, value) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        if let regex = try? NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let digits = Range(match.range(at: 1), in: text), let range = Range(match.range, in: text) else { continue }
                let raw = String(text[digits]); let hex = raw.hasPrefix("x")
                if let value = UInt32(hex ? String(raw.dropFirst()) : raw, radix: hex ? 16 : 10), let scalar = UnicodeScalar(value) {
                    text.replaceSubrange(range, with: String(scalar))
                }
            }
        }
        return text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func command(_ executable: String, _ arguments: [String], cap: Int) -> (data: Data, truncated: Bool) {
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (Data(), false) }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 12, execute: timeout)
        defer { timeout.cancel(); try? pipe.fileHandleForReading.close() }
        var data = Data()
        while data.count <= cap {
            guard let chunk = try? pipe.fileHandleForReading.read(upToCount: min(16_384, cap + 1 - data.count)), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        let truncated = data.count > cap
        if truncated && process.isRunning { process.terminate() }
        process.waitUntilExit()
        guard process.terminationStatus == 0 || truncated else { return (Data(), false) }
        return (Data(data.prefix(cap)), truncated)
    }
}
