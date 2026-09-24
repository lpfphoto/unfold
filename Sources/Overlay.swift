import AppKit
import QuartzCore

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A click-through, borderless window covering the built-in display.
///
/// It samples everything behind it through a WindowServer-aware backdrop layer and applies a *variable*
/// blur whose radius grows linearly from the hinge (bottom edge, 0) to the top edge (`topRadius`),
/// i.e. proportional to each row's distance from the virtual image plane. A matching darkening ramp and
/// a uniform black layer let the picture "slip into black" as the lid closes.
@MainActor
final class Overlay {
    struct Look {
        var topRadius: Double   // blur radius at the top edge, points
        var topDim: Double      // darkening at the top edge, 0...1
        var black: Double       // uniform fade to black, 0...1
        var edgeMask: CGImage?  // black outside the virtual screen (perspective), nil = none

        static let clear = Look(topRadius: 0, topDim: 0, black: 0, edgeMask: nil)
        var isClear: Bool { topRadius < 0.25 && topDim < 0.002 && black < 0.002 }
    }

    private var window: NSWindow?
    private var backdrop: CALayer?
    private var dimLayer = CALayer()
    private var edgeLayer = CALayer()
    private var blackLayer = CALayer()
    private var lastRadius = -1.0
    private var onLockScreen = false

    private(set) var isVisible = false

    /// The display that sits in the lid. nil in clamshell mode, so external monitors are never blurred.
    static var builtInScreen: NSScreen? {
        NSScreen.screens.first { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }
    }

    func show(onLockScreen lockScreen: Bool) {
        guard let screen = Self.builtInScreen else {
            if isVisible { hide() }
            return
        }
        if window != nil && lockScreen != onLockScreen { tearDown() }
        let window = self.window ?? makeWindow()
        if window.frame != screen.frame { window.setFrame(screen.frame, display: false) }
        guard !isVisible else { return }
        window.orderFrontRegardless()
        let space = lockScreen ? WindowServer.moveAboveLockScreen(window) : "normal"
        onLockScreen = lockScreen
        lastRadius = -1
        isVisible = true
        Log.write("overlay shown win=\(window.windowNumber) frame=\(Int(screen.frame.width))x\(Int(screen.frame.height)) space=[\(space)] variableBlur=\(backdrop != nil)")
    }

    func hide() {
        guard isVisible, let window else { return }
        apply(.clear)
        window.orderOut(nil)
        isVisible = false
        Log.write("overlay hidden")
    }

    func tearDown() {
        hide()
        window?.close()
        window = nil
        backdrop = nil
    }

    func apply(_ look: Look) {
        guard let window else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimLayer.opacity = Float(min(max(look.topDim, 0), 1))
        blackLayer.opacity = Float(min(max(look.black, 0), 1))
        edgeLayer.contents = look.edgeMask
        // Quantised to 1/8 pt: fine enough to be invisible, coarse enough to skip redundant commits.
        let radius = (max(look.topRadius, 0) * 8).rounded() / 8
        if radius != lastRadius {
            if let backdrop {
                backdrop.setValue(radius, forKeyPath: "filters.variableBlur.inputRadius")
                backdrop.isHidden = radius == 0
            } else {
                // No variable blur available: uniform blur at the mid-height value.
                WindowServer.setBackgroundBlur(Int((radius / 2).rounded()), for: window)
            }
            lastRadius = radius
        }
        CATransaction.commit()
    }

    // MARK: - Construction

    private func makeWindow() -> NSWindow {
        let frame = Self.builtInScreen?.frame ?? .zero
        let w = OverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none
        w.canBecomeVisibleWithoutLogin = true

        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        content.wantsLayer = true
        content.autoresizingMask = [.width, .height]
        let root = content.layer!

        let ramp = Self.distanceRamp()

        if let backdrop = Self.makeVariableBlurBackdrop(mask: ramp) {
            backdrop.frame = root.bounds
            backdrop.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            root.addSublayer(backdrop)
            self.backdrop = backdrop
        } else {
            w.backgroundColor = NSColor.black.withAlphaComponent(0.002) // surface for the window-level blur
            Log.write("variable blur unavailable, falling back to uniform window blur")
        }

        // Darkening that follows the same distance ramp as the blur.
        dimLayer = CALayer()
        dimLayer.backgroundColor = NSColor.black.cgColor
        dimLayer.opacity = 0
        dimLayer.frame = root.bounds
        dimLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        let dimMask = CALayer()
        dimMask.contents = ramp
        dimMask.frame = dimLayer.bounds
        dimMask.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        dimLayer.mask = dimMask
        root.addSublayer(dimLayer)

        // Black edges outside the virtual screen; the low-res mask is feathered, so linear upscaling is invisible.
        edgeLayer = CALayer()
        edgeLayer.frame = root.bounds
        edgeLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        edgeLayer.contentsGravity = .resize
        edgeLayer.magnificationFilter = .linear
        root.addSublayer(edgeLayer)

        blackLayer = CALayer()
        blackLayer.backgroundColor = NSColor.black.cgColor
        blackLayer.opacity = 0
        blackLayer.frame = root.bounds
        blackLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        root.addSublayer(blackLayer)

        w.contentView = content
        window = w
        return w
    }

    /// Vertical alpha ramp: 1 at the top edge, 0 at the hinge, linear in between (= s / H).
    /// Row 0 of the bitmap is the visual top when used as layer contents or as a filter mask.
    private static func distanceRamp() -> CGImage {
        let height = 1024
        var pixels = [UInt16](repeating: 0, count: height * 4)
        for y in 0..<height {
            let alpha = 1 - Double(y) / Double(height - 1)
            pixels[y * 4 + 3] = UInt16((alpha * 65535).rounded())
        }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        let ctx = pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: 1, height: height, bitsPerComponent: 16, bytesPerRow: 8,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info.rawValue)
        }!
        return ctx.makeImage()!
    }

    /// Private CABackdropLayer + CAFilter("variableBlur"), configured like NSVisualEffectView's behind-window
    /// backdrop but at full resolution so the rows near the hinge stay pixel-sharp.
    private static func makeVariableBlurBackdrop(mask: CGImage) -> CALayer? {
        guard let layerClass = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              let filterClass = NSClassFromString("CAFilter") as? NSObject.Type,
              let filter = filterClass.perform(NSSelectorFromString("filterWithType:"), with: "variableBlur")?
                .takeUnretainedValue() as? NSObject else { return nil }
        filter.setValue("variableBlur", forKey: "name")
        filter.setValue(mask, forKey: "inputMaskImage")
        filter.setValue(true, forKey: "inputNormalizeEdges")
        filter.setValue(0.0, forKey: "inputRadius")

        let layer = layerClass.init()
        layer.setValue(true, forKey: "windowServerAware")
        layer.setValue(1.0, forKey: "scale")
        layer.setValue("NSCGSWindowBehindWindowCaptureBackdropGroup", forKey: "groupName")
        layer.filters = [filter]
        layer.isHidden = true
        return layer
    }
}
