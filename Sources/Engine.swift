import AppKit
import Combine
import QuartzCore

/// Couples the hinge angle to the overlay, following the "image fixed in space" model:
///
///       Y │ image plane (virtual wallpaper, at β from the base)
///         │    ╱ lid at φ
///         │─ ─╱   ← a row at distance s from the hinge is s·sin(α) away from the plane, α = β − φ
///         │α ╱
///         │ ╱
///         └───────── base (X)
///
/// Each row's blur and darkening are proportional to that distance: sharp at the hinge, strongest at the
/// top edge, and zero everywhere once the lid reaches the plane (φ ≥ β). Below `blackBelow` the whole
/// picture fades to black. Nothing ever scales.
///
/// On top, `ViewGeometry` blacks out everything the eye would see *outside* the virtual screen, since the
/// tilted physical lid appears wider at the top than the fixed virtual screen behind it.
///
/// The overlay is put up (fully closed, i.e. black) *before* the Mac sleeps, so the first frame after
/// the lid opens already shows the effect.
@MainActor
final class Engine: ObservableObject {
    static let shared = Engine()

    @Published private(set) var angle: Int = 0
    @Published private(set) var sensorAvailable = false
    @Published private(set) var previewing = false

    let settings = Settings.shared
    private let sensor = LidSensor()
    private let overlay = Overlay()
    private var timer: Timer?
    private var isFast = false
    private var readFailures = 0
    private var cancellables = Set<AnyCancellable>()

    private var rawAngle: Double = 180
    private var phi: Double = 180         // displayed (spring-smoothed) lid angle, degrees
    private var phiVelocity: Double = 0
    private var lastTick: CFTimeInterval = 0
    private var wakeSession = false       // true from sleep until the lid has been opened up to the plane
    private var previewStart: CFTimeInterval = 0
    private var traceUntil: CFTimeInterval = 0   // log every frame until then (after waking)
    private var lastTraceLine: CFTimeInterval = 0

    private static let idleInterval = 1.0 / 12
    private static let fastInterval = 1.0 / 120
    private static let previewDuration = 3.2
    private static let openAngle = 180.0
    private let displaySize = ViewGeometry.builtInDisplaySize
    private var maskCache: (key: [Double], image: CGImage?)?

    func start() {
        sensorAvailable = sensor.open()
        readSensor()
        phi = rawAngle

        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                MainActor.assumeIsolated { self?.prepareForSleep(n.name.rawValue) }
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                MainActor.assumeIsolated { self?.didWake(n.name.rawValue) }
            }
        }
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            DistributedNotificationCenter.default().addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { Log.write("\(name) angle=\(Int(self?.rawAngle ?? -1))") }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        Log.write("start sensor=\(sensorAvailable) angle=\(Int(rawAngle)) enabled=\(settings.enabled) lockScreen=\(settings.showOnLockScreen) β=\(Int(settings.clearAbove))° black<\(Int(settings.blackBelow))° R=\(Int(settings.blurRadius)) dim=\(settings.dim) perspective=\(settings.perspective) eye=\(Int(settings.eyeDistance))/\(Int(settings.eyeHeight))cm display=\(displaySize)")

        settings.$showOnLockScreen.dropFirst().sink { [weak self] _ in self?.overlay.tearDown() }.store(in: &cancellables)
        // Any setting change: re-evaluate on the next tick (and redraw a settled overlay).
        settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.settingsChanged() }
        }.store(in: &cancellables)

        setFast(false)
    }

    /// Plays the opening animation once without touching the lid.
    func preview() {
        previewing = true
        previewStart = CACurrentMediaTime()
        phi = 0
        phiVelocity = 0
        render()
        setFast(true)
    }

    /// Debug aid (`--hold 35`): freezes the effect at a fixed lid angle.
    func hold(angle: Double) {
        timer?.invalidate()
        timer = nil
        phi = angle
        render()
    }

    // MARK: - Sleep / wake

    private func prepareForSleep(_ reason: String) {
        Log.write("\(reason) angle=\(Int(rawAngle)) phi=\(Int(phi))")
        guard settings.enabled else { return }
        wakeSession = true
        phi = 0            // as if closed: black, maximally frosted
        phiVelocity = 0
        render()
    }

    private func didWake(_ reason: String) {
        lastTick = CACurrentMediaTime()
        if !sensor.isOpen || sensor.read() == nil { sensorAvailable = sensor.open() }
        readSensor()
        traceUntil = lastTick + 8
        Log.write("\(reason) angle=\(Int(rawAngle)) sensor=\(sensorAvailable) overlayVisible=\(overlay.isVisible) phi=\(Int(phi)) wakeSession=\(wakeSession)")
        setFast(true)
    }

    private func screensChanged() {
        guard overlay.isVisible else { return }
        overlay.show(onLockScreen: settings.showOnLockScreen)  // re-fits the frame to the built-in screen
    }

    private func settingsChanged() {
        if overlay.isVisible { render() }
        setFast(true)
    }

    // MARK: - Loop

    private func setFast(_ fast: Bool) {
        if timer != nil && fast == isFast { return }
        timer?.invalidate()
        isFast = fast
        lastTick = CACurrentMediaTime()
        let t = Timer(timeInterval: fast ? Self.fastInterval : Self.idleInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = fast ? 0.001 : 0.02
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastTick, 1.0 / 480), 1.0 / 20)
        lastTick = now

        readSensor()
        let target = targetAngle(now: now)
        publishAngle(previewing ? target : rawAngle)

        if now < traceUntil && now - lastTraceLine > 0.1 {
            lastTraceLine = now
            let look = self.look(for: phi)
            Log.write("  trace sensor=\(Int(rawAngle)) target=\(Int(target)) phi=\(String(format: "%.1f", phi)) R=\(String(format: "%.1f", look.topRadius)) black=\(String(format: "%.2f", look.black)) visible=\(overlay.isVisible)")
        }

        if !isFast {
            if abs(effectiveAngle(target) - effectiveAngle(phi)) > 0.05 { setFast(true) }
            return
        }

        // Critically damped spring on the angle: smooths the 1°-resolution sensor, never overshoots.
        let omega = 18.0
        phiVelocity += (omega * omega * (target - phi) - 2 * omega * phiVelocity) * dt
        phi += phiVelocity * dt
        if abs(target - phi) < 0.05 && abs(phiVelocity) < 0.5 {
            phi = target
            phiVelocity = 0
        }
        render()

        // Settled: drop back to cheap polling; a partially frosted overlay stays as it is.
        if phi == target && !previewing { setFast(false) }
    }

    /// The lid angle the effect should follow right now.
    private func targetAngle(now: CFTimeInterval) -> Double {
        if previewing {
            let p = (now - previewStart) / Self.previewDuration
            if p < 1 { return previewAngle(progress: p) }
            previewing = false
        }
        if rawAngle >= settings.clearAbove { wakeSession = false }
        guard settings.enabled, wakeSession || settings.blurWhileClosing else { return Self.openAngle }
        return rawAngle
    }

    /// Angles at or beyond the image plane all look the same (sharp); clamp so they compare equal.
    private func effectiveAngle(_ a: Double) -> Double { min(a, settings.clearAbove) }

    /// Simulated lid: starts closed, holds briefly, then opens with an ease-in-out past the image plane.
    private func previewAngle(progress p: Double) -> Double {
        let hold = 0.1
        let end = settings.clearAbove + 10
        guard p > hold else { return 0 }
        let q = (p - hold) / (1 - hold)
        let eased = q < 0.5 ? 4 * q * q * q : 1 - pow(-2 * q + 2, 3) / 2
        return end * eased
    }

    /// The trigonometry from the sketch.
    private func look(for phi: Double) -> Overlay.Look {
        let beta = settings.clearAbove
        let alpha = beta - phi
        guard alpha > 0 else { return .clear }
        let distance = sin(min(alpha, 180) * .pi / 180)   // top-edge distance to the plane, in lid heights
        let blackBelow = settings.blackBelow
        var black = 0.0
        if blackBelow > 0 && phi < blackBelow {
            let t = max(phi, 0) / blackBelow
            black = 1 - t * t * (3 - 2 * t)
        }
        return Overlay.Look(topRadius: settings.blurRadius * distance, topDim: settings.dim * distance,
                            black: black, edgeMask: edgeMask(for: phi))
    }

    func geometry(phi: Double) -> ViewGeometry {
        ViewGeometry(phi: phi, beta: settings.clearAbove, width: displaySize.width, height: displaySize.height,
                     eyeDistance: settings.eyeDistance, eyeHeight: settings.eyeHeight, feather: settings.feather,
                     topFade: settings.topFade, perspective: settings.perspective)
    }

    /// Recomputed only when the angle moved by more than 0.02° or a setting changed.
    private func edgeMask(for phi: Double) -> CGImage? {
        guard settings.perspective || settings.topFade > 0 else { return nil }
        let key = [(phi * 50).rounded(), settings.clearAbove, settings.eyeDistance, settings.eyeHeight, settings.feather,
                   settings.topFade, settings.perspective ? 1 : 0]
        if let cache = maskCache, cache.key == key { return cache.image }
        let image = geometry(phi: phi).edgeMask()
        maskCache = (key, image)
        return image
    }

    private func render() {
        let look = self.look(for: phi)
        if look.isClear {
            overlay.hide()
        } else {
            overlay.show(onLockScreen: settings.showOnLockScreen)
            overlay.apply(look)
        }
    }

    private func readSensor() {
        if let a = sensor.read() {
            rawAngle = a
            readFailures = 0
            if !sensorAvailable { sensorAvailable = true }
        } else {
            readFailures += 1
            if readFailures % 60 == 0 { sensorAvailable = sensor.open() }
        }
    }

    private func publishAngle(_ a: Double) {
        let rounded = Int(a.rounded())
        if rounded != angle { angle = rounded }
    }
}
