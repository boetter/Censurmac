import Foundation
import PDFKit
import AppKit
import CoreText

/// Renders each PDF page to a bitmap and draws black redaction boxes over
/// sensitive text, then reassembles into a new PDF document.
/// The resulting PDF contains only rasterised images — no extractable text.
class PDFRedactionEngine {

    private let scale: CGFloat = 2.0   // Retina-quality render

    func createRedactedPDF(from original: PDFDocument, entities: [RedactionEntity]) -> PDFDocument? {
        guard !entities.isEmpty else { return nil }

        // Pre-compute: for each unique entity text, find all selections in the document
        // then group by page index → [(pageBounds, replacement)]
        var redactionsByPage: [Int: [(rect: CGRect, replacement: String)]] = [:]

        let uniqueEntities = Dictionary(
            entities.map { ($0.originalText.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for (_, entity) in uniqueEntities {
            let selections = original.findString(entity.originalText, withOptions: [.caseInsensitive])
            for selection in selections {
                for page in selection.pages {
                    guard let idx = original.index(for: page) else { continue }
                    let rect = selection.bounds(for: page)
                    redactionsByPage[idx, default: []].append((rect: rect, replacement: entity.replacement))
                }
            }
        }

        let newDocument = PDFDocument()

        for i in 0..<original.pageCount {
            guard let page = original.page(at: i) else { continue }
            let mediaBox = page.bounds(for: .mediaBox)

            guard let rendered = renderPage(page, mediaBox: mediaBox, redactions: redactionsByPage[i] ?? []) else { continue }

            let nsImage = NSImage(cgImage: rendered, size: mediaBox.size)
            if let newPage = PDFPage(image: nsImage) {
                newDocument.insert(newPage, at: newDocument.pageCount)
            }
        }

        return newDocument.pageCount > 0 ? newDocument : nil
    }

    // MARK: - Private

    private func renderPage(_ page: PDFPage, mediaBox: CGRect, redactions: [(rect: CGRect, replacement: String)]) -> CGImage? {
        let w = Int(mediaBox.width * scale)
        let h = Int(mediaBox.height * scale)

        guard let ctx = makeBitmapContext(width: w, height: h) else { return nil }

        // White background
        ctx.setFillColor(CGColor.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // Render PDF page — PDFPage draws in CGContext with (0,0) at bottom-left
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()

        // Draw redaction boxes (same coordinate system: bottom-left origin)
        for (rect, replacement) in redactions {
            let boxRect = CGRect(
                x: (rect.minX - 1) * scale,
                y: (rect.minY - 1) * scale,
                width: (rect.width + 2) * scale,
                height: (rect.height + 2) * scale
            )

            // Black fill
            ctx.setFillColor(CGColor.black)
            ctx.fill(boxRect)

            // White replacement label using CoreText
            drawLabel(replacement, in: boxRect, context: ctx)
        }

        return ctx.makeImage()
    }

    private func drawLabel(_ text: String, in rect: CGRect, context: CGContext) {
        let fontSize = max(rect.height * 0.55, 6)
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor.white
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrStr)

        context.saveGState()
        // CoreText also uses bottom-left origin, so we can set textPosition directly
        context.textPosition = CGPoint(x: rect.minX + 2, y: rect.minY + rect.height * 0.2)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func makeBitmapContext(width: Int, height: Int) -> CGContext? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }
}
