import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

// Writes a 3-page US Letter PDF whose pages read PAGE ONE / PAGE TWO / PAGE THREE, and a
// PNG of the first page drawn the same way (no PDF rasterizer needed on the runner).
// Usage: pdf-page-fixture <output.pdf> <output.png>

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("pdf fixture generation failed: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3 else { fail("usage: pdf-page-fixture <output.pdf> <output.png>") }
var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 72, nil)

func drawPage(_ label: String, in ctx: CGContext) {
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(mediaBox)
    let attributes: [CFString: Any] = [
        kCTFontAttributeName: font,
        kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1),
    ]
    guard let text = CFAttributedStringCreate(nil, label as CFString, attributes as CFDictionary) else {
        fail("cannot build attributed string")
    }
    let line = CTLineCreateWithAttributedString(text)
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    ctx.textPosition = CGPoint(x: (mediaBox.width - width) / 2, y: mediaBox.height / 2)
    CTLineDraw(line, ctx)
}

let pdfURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard let pdf = CGContext(pdfURL as CFURL, mediaBox: &mediaBox, nil) else { fail("cannot create PDF context") }
for label in ["PAGE ONE", "PAGE TWO", "PAGE THREE"] {
    pdf.beginPDFPage(nil)
    drawPage(label, in: pdf)
    pdf.endPDFPage()
}
pdf.closePDF()

guard let bitmap = CGContext(
    data: nil, width: Int(mediaBox.width), height: Int(mediaBox.height), bitsPerComponent: 8,
    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("cannot create bitmap context") }
drawPage("PAGE ONE", in: bitmap)
guard let image = bitmap.makeImage(),
      let png = CGImageDestinationCreateWithURL(
          URL(fileURLWithPath: CommandLine.arguments[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fail("cannot render PNG") }
CGImageDestinationAddImage(png, image, nil)
guard CGImageDestinationFinalize(png) else { fail("cannot write PNG") }
