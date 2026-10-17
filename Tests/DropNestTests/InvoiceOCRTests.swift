import XCTest
import AppKit
import PDFKit
@testable import DropNest

final class InvoiceOCRTests: XCTestCase {
    @MainActor
    func testScannedPDFInvoiceCanBeReadWithoutATextLayer() async throws {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DropNest-ScannedInvoice-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 700,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1200, height: 700).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black]
        ("INVOICE" as NSString).draw(at: NSPoint(x: 60, y: 520), withAttributes: attributes)
        ("HOTEL ACCOMMODATION" as NSString).draw(at: NSPoint(x: 60, y: 400), withAttributes: attributes)
        ("SYNTHETIC TEST ONLY" as NSString).draw(at: NSPoint(x: 60, y: 280), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        var bounds = CGRect(x: 0, y: 0, width: 1200, height: 700)
        let consumer = CGDataConsumer(url: url as CFURL)!
        let pdf = CGContext(consumer: consumer, mediaBox: &bounds, nil)!
        pdf.beginPDFPage(nil); pdf.draw(bitmap.cgImage!, in: bounds); pdf.endPDFPage(); pdf.closePDF()
        XCTAssertTrue(FileTextExtractor.extract(url).text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let extracted = await Task.detached { FileTextExtractor.extractInvoice(url) }.value
        XCTAssertTrue(extracted.text.uppercased().contains("INVOICE"), extracted.text)
        XCTAssertTrue(extracted.text.uppercased().contains("ACCOMMODATION"), extracted.text)
    }
}
