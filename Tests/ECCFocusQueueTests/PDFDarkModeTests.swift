import AppKit
import CoreImage
import PDFKit
import Testing

@testable import ECCFocusQueue

@Suite("PDF dark mode")
@MainActor
struct PDFDarkModeTests {
  @Test("A rendered PDF page turns dark while text lightens and colors keep their hue")
  func renderedPageColors() throws {
    let document = try #require(Self.sampleDocument())
    let page = try #require(document.page(at: 0))
    let bitmap = try #require(NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 200, bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
    page.draw(with: .mediaBox, to: context.cgContext)
    let source = try #require(CIImage(bitmapImageRep: bitmap))
    let dark = PDFDarkMode.filters().reduce(source) { image, filter in
      filter.setValue(image, forKey: kCIInputImageKey)
      return filter.outputImage ?? image
    }
    let paper = Self.pixel(dark, x: 10, y: 10), ink = Self.pixel(dark, x: 50, y: 150)
    let red = Self.pixel(dark, x: 150, y: 50), gray = Self.pixel(dark, x: 100, y: 100)
    #expect([paper.r, paper.g, paper.b].allSatisfy { abs($0 - PDFDarkMode.paper) < 0.03 }, "White paper turns dark gray: \(paper)")
    #expect([ink.r, ink.g, ink.b].allSatisfy { abs($0 - PDFDarkMode.ink) < 0.03 }, "Black ink turns near white: \(ink)")
    #expect(red.r > red.g + 0.4 && red.r > red.b + 0.4, "Red stays red: \(red)")
    #expect(abs(gray.r - 0.5) < 0.06 && abs(gray.r - gray.b) < 0.02, "Midtones stay midtones: \(gray)")
  }

  @Test("The viewer applies and removes the dark filters and its page background")
  func viewToggle() {
    let view = PDFView()
    PDFDarkMode.apply(true, to: view)
    #expect(view.contentFilters.map(\.name) == ["CILinearToSRGBToneCurve", "CIColorMatrix", "CISRGBToneCurveToLinear"])
    #expect(view.backgroundColor == PDFDarkMode.invertedBackground)
    PDFDarkMode.apply(false, to: view)
    #expect(view.contentFilters.isEmpty)
    #expect(view.backgroundColor == .underPageBackgroundColor)
  }

  /// A 200pt white page: black square top left, red square bottom right, gray square in the middle.
  static func sampleDocument() -> PDFDocument? {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 200, height: 200)
    guard let consumer = CGDataConsumer(data: data), let pdf = CGContext(consumer: consumer, mediaBox: &box, nil)
    else { return nil }
    pdf.beginPDFPage(nil)
    pdf.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); pdf.fill(box)
    pdf.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1)); pdf.fill(CGRect(x: 20, y: 120, width: 60, height: 60))
    pdf.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)); pdf.fill(CGRect(x: 120, y: 20, width: 60, height: 60))
    pdf.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)); pdf.fill(CGRect(x: 90, y: 90, width: 20, height: 20))
    pdf.endPDFPage(); pdf.closePDF()
    return PDFDocument(data: data as Data)
  }

  static func pixel(_ image: CIImage, x: Int, y: Int) -> (r: Double, g: Double, b: Double) {
    var rgba = [UInt8](repeating: 0, count: 4)
    CIContext().render(image, toBitmap: &rgba, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    return (Double(rgba[0]) / 255, Double(rgba[1]) / 255, Double(rgba[2]) / 255)
  }
}
