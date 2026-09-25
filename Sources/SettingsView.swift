import SwiftUI

struct SettingsView: View {
    @ObservedObject var engine: Engine
    @ObservedObject var settings: Settings
    @ObservedObject var login: LoginItem
    var onPreview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 16) {
                    gaugeCard
                    behaviourCard
                }
                .frame(width: 420)
                VStack(spacing: 16) {
                    effectCard
                    perspectiveCard
                }
                .frame(width: 340)
            }

            HStack {
                Button(action: onPreview) {
                    Label("Play Preview", systemImage: "play.fill")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(engine.previewing)
                Spacer()
                Button("Log") { NSWorkspace.shared.open(Log.url) }
                    .controlSize(.large)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 34)   // clears the transparent title bar
        .padding(.bottom, 22)
        .fixedSize()
    }

    private var gaugeCard: some View {
        Card {
            LidGauge(phi: Double(engine.angle), beta: Double(engine.planeAngle),
                     edgeMask: settings.perspective || settings.topFade > 0
                        ? engine.geometry(phi: Double(engine.angle), beta: Double(engine.planeAngle)).edgeMask(columns: 120) : nil)
                .frame(height: 170)
                .opacity(engine.sensorAvailable || engine.previewing ? 1 : 0.35)
            Text("The picture stays fixed in space at β = \(Int(settings.clearAbove))°. Each row blurs in proportion to its distance from the image plane (s · sin α).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var effectCard: some View {
        Card(title: "Effect") {
            SliderRow(title: "Image plane β (sharp from)", value: $settings.clearAbove, range: 45...135, step: 1, format: { "\(Int($0.rounded()))°" })
            SliderRow(title: "Blur at top", value: $settings.blurRadius, range: 10...150, format: { "\(Int($0)) pt" })
            SliderRow(title: "Dimming at top", value: $settings.dim, range: 0...0.9, format: { "\(Int(($0 * 100).rounded())) %" })
            SliderRow(title: "Top edge fade", value: $settings.topFade, range: 0...10, format: { String(format: "%.1f cm", $0) })
        }
    }

    private var perspectiveCard: some View {
        Card(title: "Perspective") {
            ToggleRow(title: "Virtual screen", subtitle: "Everything outside the fixed virtual screen turns black.", isOn: $settings.perspective)
            Group {
                ToggleRow(title: "Corner-pin the picture", subtitle: "Stretches the whole desktop into the virtual screen instead of just masking it.", isOn: $settings.cornerPin)
                SliderRow(title: "Eye distance to hinge", value: $settings.eyeDistance, range: 30...90, format: { "\(Int($0)) cm" })
                SliderRow(title: "Eye height above keyboard", value: $settings.eyeHeight, range: 5...60, format: { "\(Int($0)) cm" })
                SliderRow(title: "Soft edge", value: $settings.feather, range: 0...8, format: { String(format: "%.1f cm", $0) })
            }
            .disabled(!settings.perspective)
            .opacity(settings.perspective ? 1 : 0.45)
        }
    }

    private var behaviourCard: some View {
        Card(title: "Behavior") {
            ToggleRow(title: "Also when closing", subtitle: "The effect plays in reverse, live, as you close the lid.", isOn: $settings.blurWhileClosing)
            ToggleRow(title: "Follow the resting lid", subtitle: "The virtual screen settles wherever the lid rests, so moving it from any angle starts the effect right away.", isOn: $settings.releaseWhenStill)
            SliderRow(title: "After", value: $settings.releaseDelay, range: 0.5...5, format: { String(format: "%.1f s", $0) })
                .disabled(!settings.releaseWhenStill)
                .opacity(settings.releaseWhenStill ? 1 : 0.45)
            ToggleRow(title: "Show on lock screen", subtitle: "Needed if your Mac locks immediately after waking.", isOn: $settings.showOnLockScreen)
            ToggleRow(title: "Launch at login", subtitle: nil, isOn: Binding(get: { login.isEnabled }, set: { login.set($0) }))
            if let error = login.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text("Unfold").font(.title2.weight(.semibold))
                Text(status).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Enabled", isOn: $settings.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.large)
        }
    }

    private var status: String {
        if !engine.sensorAvailable { return "No lid angle sensor found" }
        if engine.previewing { return "Playing preview…" }
        return settings.enabled ? "Active · lid at \(engine.angle)°" : "Paused · lid at \(engine.angle)°"
    }
}

private struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title).font(.headline)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.6)))
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    let format: (Double) -> String

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary)
            }
            if let step {
                Slider(value: $value, in: range, step: step)
            } else {
                Slider(value: $value, in: range)
            }
        }
    }
}

private struct ToggleRow: View {
    let title: String
    let subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

/// Live version of the hand sketch: side view (image plane, lid, horizontal distances) and front view
/// (per-row blur, red = heavy … green = none).
private struct LidGauge: View {
    let phi: Double
    let beta: Double
    let edgeMask: CGImage?

    private var alpha: Double { beta - phi }
    private var distance: Double { alpha > 0 ? sin(min(alpha, 180) * .pi / 180) : 0 }

    var body: some View {
        HStack(spacing: 18) {
            sideView
            frontView.frame(width: 120)
        }
    }

    private var sideView: some View {
        Canvas { ctx, size in
            let hinge = CGPoint(x: size.width * 0.34, y: size.height - 20)
            let lidLength = size.height - 44
            func dir(_ deg: Double) -> CGVector {
                let r = deg * .pi / 180
                return CGVector(dx: cos(r), dy: -sin(r))
            }
            let plane = dir(beta), lid = dir(min(max(phi, 0), 180))

            // Base
            var base = Path()
            base.move(to: hinge)
            base.addLine(to: CGPoint(x: min(hinge.x + lidLength * 1.2, size.width - 4), y: hinge.y))
            ctx.stroke(base, with: .color(.primary.opacity(0.75)), style: StrokeStyle(lineWidth: 5, lineCap: .round))

            // Image plane (virtual wallpaper)
            var planePath = Path()
            planePath.move(to: hinge)
            planePath.addLine(to: CGPoint(x: hinge.x + plane.dx * lidLength, y: hinge.y + plane.dy * lidLength))
            ctx.stroke(planePath, with: .color(.green), style: StrokeStyle(lineWidth: 4, lineCap: .round))

            // Horizontal distances from the lid rows to the plane
            if alpha > 0 && abs(plane.dy) > 0.01 {
                for i in 1...6 {
                    let s = Double(i) / 6
                    let p = CGPoint(x: hinge.x + lid.dx * lidLength * s, y: hinge.y + lid.dy * lidLength * s)
                    let t = (p.y - hinge.y) / plane.dy              // same height on the plane line
                    let q = CGPoint(x: hinge.x + plane.dx * t, y: p.y)
                    var line = Path()
                    line.move(to: p)
                    line.addLine(to: q)
                    ctx.stroke(line, with: .color(heat(s * distance)), lineWidth: 1.5)
                }
            }

            // Lid
            var lidPath = Path()
            lidPath.move(to: hinge)
            lidPath.addLine(to: CGPoint(x: hinge.x + lid.dx * lidLength, y: hinge.y + lid.dy * lidLength))
            ctx.stroke(lidPath, with: .color(.primary), style: StrokeStyle(lineWidth: 5, lineCap: .round))

            // α arc between lid and plane
            if alpha > 1 {
                var arc = Path()
                arc.addArc(center: hinge, radius: 22, startAngle: .degrees(-beta), endAngle: .degrees(-phi), clockwise: false)
                ctx.stroke(arc, with: .color(.secondary), lineWidth: 1)
            }

            let readout = Text("φ \(Int(phi))°").font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
            ctx.draw(readout, at: CGPoint(x: size.width, y: 0), anchor: .topTrailing)
            let alphaText = Text(alpha > 0 ? "α \(Int(alpha))°" : "sharp")
                .font(.system(size: 13, weight: .medium, design: .rounded)).monospacedDigit()
                .foregroundStyle(alpha > 0 ? Color.secondary : Color.green)
            ctx.draw(alphaText, at: CGPoint(x: size.width, y: 28), anchor: .topTrailing)
        }
    }

    private var frontView: some View {
        VStack(spacing: 0) {
            Canvas { ctx, size in
                let rows = 48
                let h = size.height / CGFloat(rows)
                for r in 0..<rows {
                    let s = 1 - (Double(r) + 0.5) / Double(rows)     // r = 0 is the top edge
                    ctx.fill(Path(CGRect(x: 0, y: CGFloat(r) * h, width: size.width, height: h + 0.5)), with: .color(heat(s * distance)))
                }
                if let edgeMask {
                    ctx.draw(Image(decorative: edgeMask, scale: 1), in: CGRect(origin: .zero, size: size))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.primary.opacity(0.85)))
            .frame(height: 82)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(.primary.opacity(0.5))
                .frame(width: 134, height: 7)
            Text("Front view").font(.caption2).foregroundStyle(.secondary).padding(.top, 8)
        }
    }

    /// green (sharp) → orange → red (heavy blur), like the sketch.
    private func heat(_ v: Double) -> Color {
        let v = min(max(v, 0), 1)
        return Color(hue: 0.33 * (1 - v), saturation: 0.85, brightness: 0.9)
    }
}
