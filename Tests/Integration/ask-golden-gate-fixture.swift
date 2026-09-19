import Foundation
import CoreGraphics
import CoreImage
import CoreText
import ImageIO
import UniformTypeIdentifiers

private let width = 1_200
private let height = 800
private let qrPayload = "MACVIS-GOLDEN-GATE-2026"

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("fixture generation failed: \(message)\n".utf8))
    exit(1)
}

private func drawText(
    _ text: String,
    in context: CGContext,
    x: CGFloat,
    y: CGFloat,
    size: CGFloat,
    color: CGColor = CGColor(gray: 0.08, alpha: 1)
) {
    let attributes: [CFString: Any] = [
        kCTFontAttributeName: CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil),
        kCTForegroundColorAttributeName: color,
    ]
    guard let attributed = CFAttributedStringCreate(
        nil, text as CFString, attributes as CFDictionary
    ) else {
        fail("could not create attributed text")
    }
    let line = CTLineCreateWithAttributedString(attributed)
    context.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, context)
}

private func makeQRCode() -> CGImage {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
        fail("CIQRCodeGenerator is unavailable")
    }
    filter.setValue(Data(qrPayload.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage else {
        fail("CIQRCodeGenerator produced no output")
    }
    let scaled = output.samplingNearest().transformed(
        by: CGAffineTransform(scaleX: 10, y: 10)
    )
    guard let image = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(
        scaled, from: scaled.extent.integral
    ) else {
        fail("could not render QR code")
    }
    return image
}

guard CommandLine.arguments.count == 2 else {
    fail("usage: ask-golden-gate-fixture.swift <output.png>")
}

let outputPath = CommandLine.arguments[1]
guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
          data: nil,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: 0,
          space: colorSpace,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ) else {
    fail("could not create drawing context")
}

context.setShouldAntialias(true)
context.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.93, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: width, height: height))

// A fixed illustrated scene gives the model shapes, colors, text, and a machine-readable QR.
context.setFillColor(CGColor(red: 0.38, green: 0.72, blue: 0.94, alpha: 1))
context.fill(CGRect(x: 0, y: 280, width: width, height: height - 280))
context.setFillColor(CGColor(red: 0.31, green: 0.68, blue: 0.29, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: width, height: 280))

context.setFillColor(CGColor(red: 1.0, green: 0.82, blue: 0.16, alpha: 1))
context.fillEllipse(in: CGRect(x: 80, y: 555, width: 130, height: 130))

context.setFillColor(CGColor(red: 0.77, green: 0.54, blue: 0.31, alpha: 1))
context.fill(CGRect(x: 350, y: 150, width: 390, height: 260))
context.beginPath()
context.move(to: CGPoint(x: 305, y: 410))
context.addLine(to: CGPoint(x: 545, y: 610))
context.addLine(to: CGPoint(x: 785, y: 410))
context.closePath()
context.setFillColor(CGColor(red: 0.72, green: 0.16, blue: 0.13, alpha: 1))
context.fillPath()

context.setFillColor(CGColor(red: 0.26, green: 0.14, blue: 0.07, alpha: 1))
context.fill(CGRect(x: 505, y: 150, width: 82, height: 150))
context.setFillColor(CGColor(red: 0.76, green: 0.91, blue: 1.0, alpha: 1))
context.fill(CGRect(x: 390, y: 290, width: 82, height: 76))
context.fill(CGRect(x: 620, y: 290, width: 82, height: 76))

context.setFillColor(CGColor(red: 0.36, green: 0.20, blue: 0.08, alpha: 1))
context.fill(CGRect(x: 160, y: 150, width: 45, height: 190))
context.setFillColor(CGColor(red: 0.08, green: 0.43, blue: 0.15, alpha: 1))
context.fillEllipse(in: CGRect(x: 90, y: 290, width: 185, height: 180))

drawText("GOLDEN GATE EVAL", in: context, x: 285, y: 710, size: 46)
drawText("TEXT + QR + ILLUSTRATED SCENE", in: context, x: 285, y: 662, size: 24)

let qr = makeQRCode()
let qrRect = CGRect(x: 865, y: 105, width: 260, height: 260)
context.setFillColor(CGColor(gray: 1, alpha: 1))
context.fill(qrRect.insetBy(dx: -18, dy: -18))
context.interpolationQuality = .none
context.draw(qr, in: qrRect)
drawText("SCAN ME", in: context, x: 920, y: 62, size: 25)

guard let image = context.makeImage() else {
    fail("could not finalize scene image")
}
let outputURL = URL(fileURLWithPath: outputPath)
guard let destination = CGImageDestinationCreateWithURL(
    outputURL as CFURL, UTType.png.identifier as CFString, 1, nil
) else {
    fail("could not create PNG destination")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    fail("could not write PNG to \(outputPath)")
}
