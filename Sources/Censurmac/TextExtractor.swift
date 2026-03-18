import Foundation
import AppKit

/// Extracts plain text from .txt, .md, .csv, .rtf, .docx, .xlsx files.
class TextExtractor {

    enum ExtractionError: LocalizedError {
        case unsupportedFormat(String)
        case readFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let ext): return "Filformatet .\(ext) understøttes ikke."
            case .readFailed(let msg):        return "Kunne ikke læse filen: \(msg)"
            }
        }
    }

    func extract(from url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "txt", "md", "csv", "tsv", "json", "xml", "html", "htm":
            return try plainText(from: url)

        case "rtf", "rtfd":
            return try attributedText(from: url)

        case "doc", "docx":
            return try attributedText(from: url)

        case "xls", "xlsx":
            return try excelText(from: url)

        default:
            // Try as UTF-8 plain text, fall back to error
            if let text = try? plainText(from: url) { return text }
            throw ExtractionError.unsupportedFormat(ext)
        }
    }

    // MARK: - Helpers

    private func plainText(from url: URL) throws -> String {
        // Try UTF-8 first, then common Latin encodings
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        if let text = try? String(contentsOf: url, encoding: .isoLatin1) { return text }
        if let text = try? String(contentsOf: url, encoding: .windowsCP1252) { return text }
        throw ExtractionError.readFailed("Kunne ikke afkode tekstfil.")
    }

    private func attributedText(from url: URL) throws -> String {
        do {
            var docAttrs: NSDictionary? = nil
            let attrStr = try NSAttributedString(
                url: url,
                options: [:],
                documentAttributes: &docAttrs
            )
            return attrStr.string
        } catch {
            throw ExtractionError.readFailed(error.localizedDescription)
        }
    }

    private func excelText(from url: URL) throws -> String {
        // Try NSAttributedString (works for some .xls files)
        if let text = try? attributedText(from: url), !text.isEmpty {
            return text
        }

        // XLSX is a ZIP archive — unzip and parse xl/sharedStrings.xml
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-q", url.path, "-d", tempDir.path]
        try? process.run()
        process.waitUntilExit()

        // Read shared strings (text cell values)
        let sharedStrings = tempDir.appendingPathComponent("xl/sharedStrings.xml")
        var texts: [String] = []

        if FileManager.default.fileExists(atPath: sharedStrings.path),
           let data = FileManager.default.contents(atPath: sharedStrings.path) {
            texts = SharedStringsParser.parse(data)
        }

        // Also read inline strings from worksheets if shared strings empty
        if texts.isEmpty {
            texts = extractWorksheetStrings(in: tempDir)
        }

        guard !texts.isEmpty else {
            throw ExtractionError.readFailed("Ingen tekst fundet i Excel-filen.")
        }
        return texts.joined(separator: "\n")
    }

    private func extractWorksheetStrings(in dir: URL) -> [String] {
        let sheetsDir = dir.appendingPathComponent("xl/worksheets")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sheetsDir, includingPropertiesForKeys: nil
        ) else { return [] }

        var result: [String] = []
        for file in files where file.pathExtension == "xml" {
            if let data = FileManager.default.contents(atPath: file.path) {
                result += SharedStringsParser.parse(data)
            }
        }
        return result
    }
}

// MARK: - Simple XML text extractor

private class SharedStringsParser: NSObject, XMLParserDelegate {
    private var strings: [String] = []
    private var buffer = ""
    private var inTextElement = false

    static func parse(_ data: Data) -> [String] {
        let parser = SharedStringsParser()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        xmlParser.parse()
        return parser.strings
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if elementName == "t" || elementName == "v" {
            inTextElement = true
            buffer = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inTextElement { buffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        if (elementName == "t" || elementName == "v"), !buffer.trimmingCharacters(in: .whitespaces).isEmpty {
            strings.append(buffer)
            inTextElement = false
        }
    }
}
