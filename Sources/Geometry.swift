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

    var alpha: Double { beta - phi }

    /// Lowest lid angle at which the front of the display faces the eye at all.
    var viewingAngle: Double { atan2(eyeHeight, eyeDistance) * 180 / .pi }

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

    /// Alpha mask for the black edges (row 0 = top of the display). Opaque black = hidden, clear = visible.
    func edgeMask(columns: Int = 240) -> CGImage? {
        guard alpha > 0 else { return nil }
        let rows = max(2, Int((Double(columns) * height / width).rounded()))
        var pixels = [UInt8](repeating: 0, count: columns * rows * 4)
        let distance = sin(min(alpha, 90) * .pi / 180)
        let f = max(feather * distance, 0.01)
        let ft = topFade * distance
        let facesEye = phi > viewingAngle

        for r in 0..<rows {
            let s = (1 - (Double(r) + 0.5) / Double(rows)) * height
            var rowVisibility = ft > 0.001 ? smoothstep((height - s) / ft) : 1   // physical top-edge fade
            var t = 1.0
            if perspective {
                if facesEye, let p = project(row: s) {
                    t = p.t
                    let top = smoothstep((height - p.sv) / f)        // falls off inside the virtual top edge
                    let bottom = smoothstep(1 + p.sv / f)            // shared with the physical edge: fade only below it
                    rowVisibility *= top * bottom
                } else {
                    rowVisibility = 0
                }
            }
            let rowStart = r * columns * 4
            guard rowVisibility > 0 else {
                for c in 0..<columns { pixels[rowStart + c * 4 + 3] = 255 }
                continue
            }
            // Left/right symmetric: compute one half, mirror it.
            for c in 0..<(columns + 1) / 2 {
                let u = (0.5 - (Double(c) + 0.5) / Double(columns)) * width
                let side = perspective ? smoothstep((width / 2 - t * u) / f) : 1
                let value = UInt8(((1 - rowVisibility * side) * 255).rounded())
                pixels[rowStart + c * 4 + 3] = value
                pixels[rowStart + (columns - 1 - c) * 4 + 3] = value
            }
        }
        let ctx = pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: columns * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        return ctx?.makeImage()
    }

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
