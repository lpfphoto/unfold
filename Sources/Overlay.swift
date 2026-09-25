import AppKit
import IOSurface
import QuartzCore

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A click-through, borderless window covering the built-in display.
///
/// It samples everything behind it through a WindowServer-aware backdrop layer and applies a *variable*
/// blur whose radius grows linearly from the hinge (bottom edge, 0) to the top edge (`topRadius`),
/// i.e. proportional to each row's distance from the virtual image plane, with a matching darkening ramp.
@MainActor
final class Overlay {
    struct Look {
        var topRadius: Double   // blur radius at the top edge, points
        var topDim: Double      // darkening at the top edge, 0...1
        var masks: Masks?       // black edges + corner pin, nil = none

        static let clear = Look(topRadius: 0, topDim: 0, masks: nil)
        var isClear: Bool { topRadius < 0.25 && topDim < 0.002 }
    }

    /// What the edge mask and the corner-pin map are drawn from; `key` changes whenever they would.
    struct Masks {
        var geometry: ViewGeometry
        var size: CGSize        // display in points
        var key: [Double]
    }

    private var window: NSWindow?
    private var backdrop: CALayer?
    private var dimLayer = CALayer()
    private var edgeLayer = CALayer()
    private var lastRadius = -1.0
    private var warping = false
    private var lastMaskKey: [Double]?
    // Both images live in IOSurfaces shared with the WindowServer, so a frame hands over a reference instead
    // of encoding and copying ~200 KB of pixels into the transaction.
    private let edgeSurfaces = SurfaceRing(pixelFormat: 0x4247_5241, bytesPerElement: 4)   // 'BGRA', 8 bit
    private let warpSurfaces = SurfaceRing(pixelFormat: 0x6C36_3472, bytesPerElement: 8)   // 'l64r', 16-bit LE RGBA
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
        if isVisible && lockScreen == onLockScreen { return }   // per-frame hot path: already up
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
        lastMaskKey = nil
        isVisible = true
        Log.write("overlay shown win=\(window.windowNumber) frame=\(Int(screen.frame.width))x\(Int(screen.frame.height)) space=[\(space)] variableBlur=\(backdrop != nil)")
    }

    /// Re-fits the window after a display change (resolution, clamshell).
    func refit() {
        guard let window else { return }
        guard let screen = Self.builtInScreen else {
            if isVisible { hide() }
            return
        }
        if window.frame != screen.frame { window.setFrame(screen.frame, display: false) }
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
        if let masks = look.masks {
            if masks.key != lastMaskKey { draw(masks) }
        } else if lastMaskKey != nil {
            edgeLayer.contents = nil
            if warping { backdrop?.setValue(0.0, forKeyPath: "filters.displacementMap.inputAmount") }
            warping = false
            lastMaskKey = nil
        }
        // Quantised to 1/8 pt: fine enough to be invisible, coarse enough to skip redundant commits.
        let radius = (max(look.topRadius, 0) * 8).rounded() / 8
        if radius != lastRadius {
            if let backdrop {
                backdrop.setValue(radius, forKeyPath: "filters.variableBlur.inputRadius")
            } else {
                // No variable blur available: uniform blur at the mid-height value.
                WindowServer.setBackgroundBlur(Int((radius / 2).rounded()), for: window)
            }
            lastRadius = radius
        }
        backdrop?.isHidden = radius == 0 && !warping
        CATransaction.commit()
    }

    /// Renders the edge mask and the corner-pin map straight into shared surfaces and hands them over.
    private func draw(_ masks: Masks) {
        lastMaskKey = masks.key
        let (columns, rows) = masks.geometry.edgeMaskSize()
        if let surface = edgeSurfaces.next(width: columns, height: rows) {
            surface.lock(options: [], seed: nil)
            let drawn = masks.geometry.fillEdgeMask(into: surface.baseAddress, bytesPerRow: surface.bytesPerRow, columns: columns, rows: rows)
            surface.unlock(options: [], seed: nil)
            edgeLayer.contents = drawn ? surface : nil
        }
        guard let backdrop else { return }
        var amount: Double?
        if let surface = warpSurfaces.next(width: 96, height: 64) {
            surface.lock(options: [], seed: nil)
            amount = masks.geometry.fillFitWarp(size: masks.size, into: surface.baseAddress, bytesPerRow: surface.bytesPerRow, columns: 96, rows: 64)
            surface.unlock(options: [], seed: nil)
            if let amount {
                backdrop.setValue(surface, forKeyPath: "filters.displacementMap.inputMaskImage")
                backdrop.setValue(amount, forKeyPath: "filters.displacementMap.inputAmount")
            }
        }
        if amount == nil && warping { backdrop.setValue(0.0, forKeyPath: "filters.displacementMap.inputAmount") }
        warping = amount != nil
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

        // Darkening that follows the same distance ramp as the blur. The ramp image is black with that alpha,
        // so it is drawn directly: a black layer *masked* by the ramp looks the same but costs the
        // WindowServer an extra full-screen offscreen pass every frame.
        dimLayer = CALayer()
        dimLayer.contents = ramp
        dimLayer.contentsGravity = .resize
        dimLayer.opacity = 0
        dimLayer.frame = root.bounds
        dimLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        root.addSublayer(dimLayer)

        // Black edges outside the virtual screen; the low-res mask is feathered, so linear upscaling is invisible.
        edgeLayer = CALayer()
        edgeLayer.frame = root.bounds
        edgeLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        edgeLayer.contentsGravity = .resize
        edgeLayer.magnificationFilter = .linear
        root.addSublayer(edgeLayer)

        w.contentView = content
        window = w
        return w
    }

    /// Vertical alpha ramp: 1 at the top edge, 0 at the hinge, linear in between (= s / H), colour black.
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

    /// Private CABackdropLayer with CAFilter("displacementMap") for the corner pin, followed by
    /// CAFilter("variableBlur"), configured like NSVisualEffectView's behind-window backdrop but at full
    /// resolution so the rows near the hinge stay pixel-sharp. Both filters take their parameters in points.
    private static func makeVariableBlurBackdrop(mask: CGImage) -> CALayer? {
        guard let layerClass = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              let filterClass = NSClassFromString("CAFilter") as? NSObject.Type,
              let filter = filterClass.perform(NSSelectorFromString("filterWithType:"), with: "variableBlur")?
                .takeUnretainedValue() as? NSObject else { return nil }
        filter.setValue("variableBlur", forKey: "name")
        filter.setValue(mask, forKey: "inputMaskImage")
        filter.setValue(true, forKey: "inputNormalizeEdges")
        filter.setValue(0.0, forKey: "inputRadius")

        var filters: [Any] = []
        if let displacement = filterClass.perform(NSSelectorFromString("filterWithType:"), with: "displacementMap")?
            .takeUnretainedValue() as? NSObject {
            displacement.setValue("displacementMap", forKey: "name")
            displacement.setValue(NSValue(point: NSPoint(x: 0.5, y: 0.5)), forKey: "inputOffset")   // 0.5 = no shift
            displacement.setValue(0.0, forKey: "inputAmount")
            filters.append(displacement)
        }
        filters.append(filter)

        let layer = layerClass.init()
        layer.setValue(true, forKey: "windowServerAware")
        layer.setValue(1.0, forKey: "scale")
        layer.setValue("NSCGSWindowBehindWindowCaptureBackdropGroup", forKey: "groupName")
        layer.filters = filters
        layer.isHidden = true
        return layer
    }
}

/// A few same-sized IOSurfaces used in turn: each frame writes into one the WindowServer isn't reading from.
private final class SurfaceRing {
    private let pixelFormat: UInt32
    private let bytesPerElement: Int
    private var surfaces: [IOSurface] = []
    private var size = (width: 0, height: 0)
    private var cursor = 0
    private static let limit = 4

    init(pixelFormat: UInt32, bytesPerElement: Int) {
        self.pixelFormat = pixelFormat
        self.bytesPerElement = bytesPerElement
    }

    func next(width: Int, height: Int) -> IOSurface? {
        if size != (width, height) {
            surfaces.removeAll()
            size = (width, height)
        }
        for k in 0..<surfaces.count {
            let i = (cursor + k) % surfaces.count
            if !surfaces[i].isInUse {
                cursor = i + 1
                return surfaces[i]
            }
        }
        if surfaces.count < Self.limit,
           let surface = IOSurface(properties: [.width: width, .height: height,
                                                .bytesPerElement: bytesPerElement, .pixelFormat: pixelFormat]) {
            surfaces.append(surface)
            cursor = surfaces.count
            return surface
        }
        guard !surfaces.isEmpty else { return nil }
        cursor += 1
        return surfaces[cursor % surfaces.count]      // all busy (shouldn't happen): reuse the oldest
    }
}
