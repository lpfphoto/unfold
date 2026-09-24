// Renders Resources/AppIcon.icns: a laptop glyph that goes from blurred (left) to sharp (right).
import AppKit
import CoreImage

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"
let size = 1024.0

func render() -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Background gradient
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let colors = [CGColor(srgbRed: 0.10, green: 0.12, blue: 0.30, alpha: 1),
                  CGColor(srgbRed: 0.33, green: 0.25, blue: 0.78, alpha: 1),
                  CGColor(srgbRed: 0.93, green: 0.55, blue: 0.75, alpha: 1)] as CFArray
    let g = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 924, y: 924), options: [])
    ctx.restoreGState()

    // Glyph layer
    let glyphCtx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                             space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let cfg = NSImage.SymbolConfiguration(pointSize: 470, weight: .light)
    let sym = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
    let tinted = NSImage(size: sym.size, flipped: false) { r in
        sym.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true
    }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: glyphCtx, flipped: false)
    let s = tinted.size
    tinted.draw(in: CGRect(x: (size - s.width) / 2, y: (size - s.height) / 2 - 10, width: s.width, height: s.height))
    NSGraphicsContext.current = nil
    let glyph = CIImage(cgImage: glyphCtx.makeImage()!)

    // Blend blurred → sharp from left to right
    let blurred = glyph.clampedToExtent().applyingGaussianBlur(sigma: 26).cropped(to: glyph.extent)
    let mask = CIFilter(name: "CILinearGradient", parameters: [
        "inputPoint0": CIVector(x: 330, y: 0), "inputColor0": CIColor.black,
        "inputPoint1": CIVector(x: 690, y: 0), "inputColor1": CIColor.white,
    ])!.outputImage!.cropped(to: glyph.extent)
    let mixed = glyph.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: blurred, kCIInputMaskImageKey: mask])
    let ci = CIContext()
    let mixedCG = ci.createCGImage(mixed, from: glyph.extent)!

    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 30, color: CGColor(gray: 0, alpha: 0.35))
    ctx.draw(mixedCG, in: CGRect(x: 0, y: 0, width: size, height: size))
    ctx.restoreGState()
    return ctx.makeImage()!
}

let img = render()
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: img, size: .zero).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "\(outDir)/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/AppIcon.png"))
print("✓ \(outDir)/AppIcon.icns")
