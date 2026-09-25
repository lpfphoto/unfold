import CoreGraphics
import Foundation

/// Perspective model for the "virtual screen fixed in space" illusion (side view, X towards the viewer, Y up):
///
///                         ● eye E = (D, h)
///       Y │ virtual screen at β
///         │     ╱ physical lid at φ
///         │    ╱
///         │   ╱
///         └──────────────── X (base)
///
/// A point on the physical lid (u across, s up from the hinge) is visible only if the line of sight
/// from E through it lands inside the virtual rectangle (same size as the real display) on the plane at β.
/// Everything else turns black, with a soft falloff inside the virtual edges.
///
/// With `cornerPin`, the picture is not just masked but warped: a homography maps the whole desktop into
/// that trapezoid ("fit": bottom corners at the hinge, top corners where the virtual screen's top edge
/// appears), so nothing is cut off and the rows towards the top are foreshortened like a tilted screen.
///
/// Independently of that (not physically motivated, but it reads better), the physical top edge fades to
/// black over `topFade · sin α`, so the picture never ends abruptly at the lid's upper edge; the fade
/// narrows as the lid approaches β and is gone once it gets there.
struct ViewGeometry {
    var phi: Double            // lid angle, degrees
    var beta: Double           // virtual screen angle, degrees
    var width: Double          // display width, cm
    var height: Double         // display height, cm
    var eyeDistance: Double    // D: horizontal distance eye ↔ hinge, cm
    var eyeHeight: Double      // h: eye height above the hinge / keyboard, cm
    var feather: Double        // falloff width at the virtual edges when α = 90°, cm
    var topFade: Double        // fade to black at the *physical* top edge when α = 90°, cm
    var perspective = true     // false: only the top fade, no virtual-screen edges
    var cornerPin = false      // warp the picture into the virtual screen (fit) instead of cutting it off at the top

    var alpha: Double { beta - phi }

    /// Lowest lid angle at which the front of the display faces the eye at all.
    var viewingAngle: Double { atan2(eyeHeight, eyeDistance) * 180 / .pi }

    /// Below the viewing angle the eye would only see the back of the lid and the projection breaks down.
    /// Rather than blacking the screen out, hold the shape it has just above that angle, keeping α, so the
    /// edges still narrow away smoothly as the plane swings onto the lid.
    private var viewable: ViewGeometry {
        let minimum = viewingAngle + 2
        guard phi < minimum else { return self }
        var g = self
        g.phi = minimum
        g.beta = minimum + alpha
        return g
    }

    /// Per row s (cm from the hinge): the ray parameter t (≥ 1 when the virtual plane is behind the lid)
    /// and s', the height on the virtual screen where that row's line of sight lands. nil = no hit.
    func project(row s: Double) -> (t: Double, sv: Double)? {
        let rad = Double.pi / 180
        let (sb, cb) = (sin(beta * rad), cos(beta * rad))
        let (sp, cp) = (sin(phi * rad), cos(phi * rad))
        let nE = -sb * eyeDistance + cb * eyeHeight          // plane normal · E  (< 0: eye in front of the plane)
        let nP = s * (-sb * cp + cb * sp)                     // plane normal · P  = −s·sin α
        let denominator = nE - nP
        guard nE < 0, denominator < 0 else { return nil }
        let t = nE / denominator
        let qx = eyeDistance + t * (s * cp - eyeDistance)
        let qy = eyeHeight + t * (s * sp - eyeHeight)
        return (t, qx * cb + qy * sb)
    }

    /// Pixel size of the edge mask for a given width (the height follows the display's aspect ratio).
    func edgeMaskSize(columns: Int = 240) -> (columns: Int, rows: Int) {
        (columns, max(2, Int((Double(columns) * height / width).rounded())))
    }

    /// Alpha mask for the black edges (row 0 = top of the display). Opaque black = hidden, clear = visible.
    func edgeMask(columns: Int = 240) -> CGImage? {
        let (columns, rows) = edgeMaskSize(columns: columns)
        let bytesPerRow = columns * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * rows)
        let filled = pixels.withUnsafeMutableBytes { fillEdgeMask(into: $0.baseAddress!, bytesPerRow: bytesPerRow, columns: columns, rows: rows) }
        guard filled else { return nil }
        return pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                      space: Self.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }

    /// Writes the edge mask as black + alpha, 4 bytes per pixel with alpha last (RGBA or BGRA alike, the colour
    /// bytes are zero), into memory the caller owns: a buffer or an IOSurface shared with the WindowServer.
    /// Returns false (and writes nothing) when there is no mask. Runs every animation frame.
    func fillEdgeMask(into base: UnsafeMutableRawPointer, bytesPerRow: Int, columns: Int, rows: Int) -> Bool {
        guard alpha > 0 else { return false }
        let distance = sin(min(alpha, 90) * .pi / 180)
        let f = max(feather * distance, 0.01)
        let ft = topFade * distance
        let view = viewable
        let half = (columns + 1) / 2

        // Column positions (distance from the centre line, cm) are the same for every row.
        var us = [Double](repeating: 0, count: half)
        for c in 0..<half { us[c] = (0.5 - (Double(c) + 0.5) / Double(columns)) * width }

        us.withUnsafeBufferPointer { us in
            for r in 0..<rows {
                let px = (base + r * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                let s = (1 - (Double(r) + 0.5) / Double(rows)) * height
                var rowVisibility = ft > 0.001 ? smoothstep((height - s) / ft) : 1   // physical top-edge fade
                var t = 1.0
                if perspective, let p = view.project(row: s) {
                    t = p.t
                    // Falls off inside the virtual top edge; with corner pinning the whole picture fits, so no cut.
                    let top = cornerPin ? 1 : smoothstep((height - p.sv) / f)
                    let bottom = smoothstep(1 + p.sv / f)            // shared with the physical edge: fade only below it
                    rowVisibility *= top * bottom
                }
                memset(px, 0, columns * 4)
                guard rowVisibility > 0 else {
                    for c in 0..<columns { px[c * 4 + 3] = 255 }
                    continue
                }
                // Left/right symmetric: compute one half, mirror it.
                for c in 0..<half {
                    let side = perspective ? smoothstep((width / 2 - t * us[c]) / f) : 1
                    let value = UInt8(((1 - rowVisibility * side) * 255).rounded())
                    px[c * 4 + 3] = value
                    px[(columns - 1 - c) * 4 + 3] = value
                }
            }
        }
        return true
    }

    /// Displacement map for the corner pin, as consumed by Core Animation's `displacementMap` filter with
    /// `inputOffset = (0.5, 0.5)` (measured, the filter is undocumented): an output point samples the backdrop at
    /// x + (R − 0.5) · amount and y_up + (G − 0.5) · amount (points; row 0 of the map = top edge), and B blends
    /// between the untouched backdrop (0) and the displaced one (1). `size` is the display in points.
    /// nil when there is nothing to warp.
    func fitWarp(size: CGSize, columns: Int = 96, rows: Int = 64) -> (map: CGImage, amount: Double)? {
        let bytesPerRow = columns * 8
        var pixels = [UInt16](repeating: 0, count: columns * rows * 4)
        let amount = pixels.withUnsafeMutableBytes { fillFitWarp(size: size, into: $0.baseAddress!, bytesPerRow: bytesPerRow, columns: columns, rows: rows) }
        guard let amount else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        let image = pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: columns, height: rows, bitsPerComponent: 16, bytesPerRow: bytesPerRow,
                      space: Self.sRGB, bitmapInfo: info.rawValue)?.makeImage()
        }
        return image.map { ($0, amount) }
    }

    /// Writes the corner-pin map as 16-bit little-endian RGBA into caller-owned memory (a buffer or an
    /// IOSurface) and returns the matching `inputAmount`, or nil (writing nothing) when there is nothing to warp.
    func fillFitWarp(size: CGSize, into base: UnsafeMutableRawPointer, bytesPerRow: Int, columns: Int = 96, rows: Int = 64) -> Double? {
        guard cornerPin, perspective, alpha > 0, let top = viewable.project(row: height), top.t > 1.0001 else { return nil }
        // Unit coordinates, v up from the hinge. The desktop (unit square) goes onto this trapezoid:
        let halfTop = 0.5 / top.t
        guard let pin = Homography(square: [(0, 0), (1, 0), (0.5 + halfTop, 1), (0.5 - halfTop, 1)]) else { return nil }

        let count = columns * rows
        var dx = [Double](repeating: 0, count: count), dy = dx
        var maxShift = 0.5
        dx.withUnsafeMutableBufferPointer { dx in
            dy.withUnsafeMutableBufferPointer { dy in
                for r in 0..<rows {
                    let v = 1 - (Double(r) + 0.5) / Double(rows)
                    for c in 0..<columns {
                        let u = (Double(c) + 0.5) / Double(columns)
                        // Which desktop point lands here? Outside the trapezoid (black anyway) clamp to the edge.
                        var (x, y) = pin.inverse(u, v)
                        x = min(max(x, 0), 1)
                        y = min(max(y, 0), 1)
                        let i = r * columns + c
                        dx[i] = (x - u) * size.width
                        dy[i] = (y - v) * size.height
                        maxShift = max(maxShift, abs(dx[i]), abs(dy[i]))
                    }
                }
            }
        }
        // amount = 2 · maxShift keeps every channel inside [0, 1] around the 0.5 centre; B = 1: fully displaced.
        let amount = 2 * maxShift * 1.02
        for r in 0..<rows {
            let px = (base + r * bytesPerRow).assumingMemoryBound(to: UInt16.self)
            for c in 0..<columns {
                let i = r * columns + c
                px[c * 4] = UInt16(((0.5 + dx[i] / amount) * 65535).rounded()).littleEndian
                px[c * 4 + 1] = UInt16(((0.5 + dy[i] / amount) * 65535).rounded()).littleEndian
                px[c * 4 + 2] = UInt16(65535).littleEndian
                px[c * 4 + 3] = UInt16(65535).littleEndian
            }
        }
        return amount
    }

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private func smoothstep(_ x: Double) -> Double {
        let v = min(max(x, 0), 1)
        return v * v * (3 - 2 * v)
    }

    /// Physical size of the built-in display in cm (16" MacBook Pro as fallback).
    static var builtInDisplaySize: CGSize {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetOnlineDisplayList(16, &ids, &count)
        for id in ids.prefix(Int(count)) where CGDisplayIsBuiltin(id) != 0 {
            let mm = CGDisplayScreenSize(id)
            if mm.width > 0 && mm.height > 0 { return CGSize(width: mm.width / 10, height: mm.height / 10) }
        }
        return CGSize(width: 34.5, height: 22.3)
    }
}

/// Projective map from the unit square to a quad (Heckbert's square-to-quad), with its inverse.
/// Corners in order: (0,0), (1,0), (1,1), (0,1).
struct Homography {
    private let m: [Double]      // row-major 3×3, forward (square → quad)
    private let inv: [Double]    // inverse (quad → square)

    init?(square quad: [(Double, Double)]) {
        let (x0, y0) = quad[0], (x1, y1) = quad[1], (x2, y2) = quad[2], (x3, y3) = quad[3]
        let dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3
        let dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3
        let den = dx1 * dy2 - dx2 * dy1
        guard abs(den) > 1e-12 else { return nil }
        let g = (dx3 * dy2 - dx2 * dy3) / den
        let h = (dx1 * dy3 - dx3 * dy1) / den
        m = [x1 - x0 + g * x1, x3 - x0 + h * x3, x0,
             y1 - y0 + g * y1, y3 - y0 + h * y3, y0,
             g, h, 1]
        let (a, b, c, d, e, f, gg, hh, i) = (m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8])
        let det = a * (e * i - f * hh) - b * (d * i - f * gg) + c * (d * hh - e * gg)
        guard abs(det) > 1e-12 else { return nil }
        inv = [(e * i - f * hh) / det, (c * hh - b * i) / det, (b * f - c * e) / det,
               (f * gg - d * i) / det, (a * i - c * gg) / det, (c * d - a * f) / det,
               (d * hh - e * gg) / det, (b * gg - a * hh) / det, (a * e - b * d) / det]
    }

    func forward(_ u: Double, _ v: Double) -> (Double, Double) { apply(m, u, v) }
    func inverse(_ x: Double, _ y: Double) -> (Double, Double) { apply(inv, x, y) }

    private func apply(_ t: [Double], _ u: Double, _ v: Double) -> (Double, Double) {
        let w = t[6] * u + t[7] * v + t[8]
        return ((t[0] * u + t[1] * v + t[2]) / w, (t[3] * u + t[4] * v + t[5]) / w)
    }
}
