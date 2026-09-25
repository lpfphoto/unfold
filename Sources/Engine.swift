import AppKit
import Combine
import CoreVideo
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
/// top edge, and zero everywhere once the lid reaches the plane (φ ≥ β).
///
/// On top, `ViewGeometry` blacks out everything the eye would see *outside* the virtual screen, since the
/// tilted physical lid appears wider at the top than the fixed virtual screen behind it.
///
/// When the lid comes to rest part-way (e.g. propped at 80° in bed), the virtual screen swings over to
/// the lid after a moment (a soft, critically damped glide of `plane`): the black wedges retreat into the
/// corners, the top fade narrows and the blur recedes with sin α, until the lid shows the full picture.
/// This works at any angle, above β too: wherever the lid last rested, moving it starts the effect right
/// away. Opening further, the smoothed lid pushes the plane along (always `planeMargin` behind it, so α ≤ 0
/// and nothing flickers). Sleep resets the plane to β, so opening from closed is exactly the configured
/// animation.
///
/// The overlay is put up (as if fully closed) *before* the Mac sleeps, so the first frame after the lid
/// opens already shows the effect.
@MainActor
final class Engine: ObservableObject {
    static let shared = Engine()

    @Published private(set) var angle: Int = 0
    @Published private(set) var sensorAvailable = false
    @Published private(set) var previewing = false
    /// Current angle of the virtual screen (≤ the configured β; lower after re-anchoring at a resting lid).
    @Published private(set) var planeAngle: Int = 90

    let settings = Settings.shared
    private let poller = SensorPoller()
    private let overlay = Overlay()
    private var timer: Timer?
    private var displayLink: CVDisplayLink?
    private let frames = FrameGate()
    private var isFast = false
    private var cancellables = Set<AnyCancellable>()

    private var rawAngle: Double = 180
    // The sensor reports whole degrees, so a smooth movement arrives as a staircase of 1° steps. A
    // critically damped α-β filter (position + velocity) turns that into a continuous angle: it follows
    // steady movement without lag and averages the steps away. Rest detection still uses `rawAngle`.
    private var lidAngle: Double = 180
    private var lidVelocity: Double = 0
    private static let filterOmega = 14.0
    private var phi: Double = 180         // displayed (spring-smoothed) lid angle, degrees
    private var phiVelocity: Double = 0
    private var lastTick: CFTimeInterval = 0
    private var wakeSession = false       // true from sleep until the lid has been opened up to the plane
    private var openingFromClosed = false // same span, but also ends once a resting lid takes over the plane
    private var previewStart: CFTimeInterval = 0
    private var traceUntil: CFTimeInterval = 0   // log every frame until then (after waking)
    private var lastTraceLine: CFTimeInterval = 0

    // Rest detection: the lid counts as moving once it leaves ±`restHysteresis` around the anchor angle
    // (the sensor has 1° resolution and can flicker by a degree, so this doubles as a velocity threshold).
    private var anchorAngle: Double = 180
    private var lastMotion: CFTimeInterval = 0
    private var wasResting = false
    private var plane: Double = 90         // effective virtual-screen angle β_eff, degrees
    private var glide: (from: Double, to: Double, start: CFTimeInterval)?   // plane swinging onto a resting lid
    private static let restHysteresis = 2.0
    /// The plane stays this far behind the lid when following it. Readings within the 2° hysteresis are at
    /// most 1° off the anchor, so 1° keeps sensor flicker from ever producing α > 0.
    private static let planeMargin = 1.0
    /// Swing of the virtual screen onto a resting lid: a fixed-length ease on a cubic Bézier curve
    /// (control points as in a CSS/Core Animation timing function).
    private static let glideDuration = 0.7
    private static let glideCurve = CubicBezier(0.4, 0.0, 0.2, 1.0)

    private static let idleInterval = 1.0 / 12
    private static let fastInterval = 1.0 / 120
    private static let previewDuration = 3.2
    private static let openAngle = 180.0
    private let displaySize = ViewGeometry.builtInDisplaySize
    private var screenPoints = Overlay.builtInScreen?.frame.size ?? CGSize(width: 1728, height: 1117)

    func start() {
        if let first = poller.start() { rawAngle = first }
        sensorAvailable = poller.latest.available
        phi = rawAngle
        lidAngle = rawAngle
        // Launch counts as "at rest": the plane starts where the lid is, so nothing appears until it moves.
        anchorAngle = rawAngle
        lastMotion = -.greatestFiniteMagnitude
        plane = settings.clearAbove
        if settings.releaseWhenStill { plane = rawAngle - Self.planeMargin }
        wasResting = true
        publishPlane()

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
        Log.write("start sensor=\(sensorAvailable) angle=\(Int(rawAngle)) enabled=\(settings.enabled) lockScreen=\(settings.showOnLockScreen) β=\(Int(settings.clearAbove))° R=\(Int(settings.blurRadius)) dim=\(settings.dim) perspective=\(settings.perspective) eye=\(Int(settings.eyeDistance))/\(Int(settings.eyeHeight))cm display=\(displaySize)")

        settings.$showOnLockScreen.dropFirst().sink { [weak self] _ in self?.overlay.tearDown() }.store(in: &cancellables)
        // Any setting change: re-evaluate on the next tick (and redraw a settled overlay).
        settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.settingsChanged() }
        }.store(in: &cancellables)

        render()
        setFast(false)
    }

    /// Plays the opening animation once without touching the lid.
    func preview() {
        previewing = true
        previewStart = CACurrentMediaTime()
        phi = 0
        phiVelocity = 0
        resetPlane()
        render()
        setFast(true)
    }

    /// Debug aid (`--hold 35`): freezes the effect at a fixed lid angle.
    func hold(angle: Double) {
        stopLoop()
        phi = angle
        render()
    }

    // MARK: - Sleep / wake

    private func prepareForSleep(_ reason: String) {
        Log.write("\(reason) angle=\(Int(rawAngle)) phi=\(Int(phi))")
        guard settings.enabled else { return }
        wakeSession = true
        openingFromClosed = true
        phi = 0            // as if closed: maximally frosted
        phiVelocity = 0
        resetPlane()
        noteMotion(now: CACurrentMediaTime(), force: true)   // don't let the armed state relax before sleep
        render()
    }

    private func didWake(_ reason: String) {
        lastTick = CACurrentMediaTime()
        if let angle = poller.readNow() { rawAngle = angle }
        sensorAvailable = poller.latest.available
        lidAngle = rawAngle                       // woke up somewhere else: start the filter afresh
        lidVelocity = 0
        noteMotion(now: lastTick, force: true)   // the rest timer starts when the Mac wakes, not before
        traceUntil = lastTick + 8
        Log.write("\(reason) angle=\(Int(rawAngle)) sensor=\(sensorAvailable) overlayVisible=\(overlay.isVisible) phi=\(Int(phi)) wakeSession=\(wakeSession) plane=\(Int(plane.rounded()))")
        setFast(true, restart: true)             // the display link belongs to a display that just woke up
    }

    private func screensChanged() {
        screenPoints = Overlay.builtInScreen?.frame.size ?? screenPoints
        overlay.refit()
        if isFast { setFast(true, restart: true) }   // follow the built-in display's refresh again
    }

    private func settingsChanged() {
        if overlay.isVisible { render() }
        setFast(true)
    }

    // MARK: - Loop

    private func setFast(_ fast: Bool, restart: Bool = false) {
        if !restart, timer != nil || displayLink != nil, fast == isFast { return }
        stopLoop()
        isFast = fast
        poller.setFast(fast)
        lastTick = CACurrentMediaTime()
        // While animating, run in step with the built-in display and compute every frame for the moment it
        // will actually be shown, so the motion advances by exactly one refresh per frame (a free-running timer
        // drifts against the refresh and now and then doubles or skips a frame). CVDisplayLink, bound to that
        // display: NSScreen/NSView display links follow the main display, which may be a 60 Hz external one
        // while the lid's panel runs at 120 Hz.
        if fast, let link = makeDisplayLink() {
            displayLink = link
            CVDisplayLinkStart(link)
            return
        }
        let t = Timer(timeInterval: fast ? Self.fastInterval : Self.idleInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(now: CACurrentMediaTime()) }
        }
        t.tolerance = fast ? 0.001 : 0.02
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopLoop() {
        timer?.invalidate()
        timer = nil
        if let link = displayLink { CVDisplayLinkStop(link) }
        displayLink = nil
        frames.invalidate()
    }

    private func makeDisplayLink() -> CVDisplayLink? {
        guard let screen = Overlay.builtInScreen,
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithCGDisplay(id, &link) == kCVReturnSuccess, let link else { return nil }
        let gate = frames
        let generation = gate.begin()
        CVDisplayLinkSetOutputHandler(link) { _, _, outputTime, _, _ in
            // Display-link thread: hand the frame's presentation time to the main thread, at most one pending.
            if gate.post(FrameGate.seconds(hostTime: outputTime.pointee.hostTime), generation: generation) {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let time = gate.take(generation: generation) else { return }
                        Engine.shared.tick(now: time)
                    }
                }
            }
            return kCVReturnSuccess
        }
        return link
    }

    fileprivate func tick(now: CFTimeInterval) {
        let dt = min(max(now - lastTick, 1.0 / 480), 1.0 / 20)
        lastTick = now

        readSensor()
        filterLid(dt: dt)
        noteMotion(now: now)
        let target = targetAngle(now: now)
        let resting = isResting(now: now)
        if resting != wasResting {
            wasResting = resting
            if resting { openingFromClosed = false }
            Log.write(resting ? "lid at rest (\(Int(rawAngle))°): virtual screen swings over from \(Int(plane.rounded()))°" : "lid moving (\(Int(rawAngle))°)")
        }
        publishAngle(previewing ? target : rawAngle)

        if now < traceUntil && now - lastTraceLine > 0.1 {
            lastTraceLine = now
            let look = self.look(for: phi)
            Log.write("  trace sensor=\(Int(rawAngle)) filtered=\(String(format: "%.1f", lidAngle)) target=\(Int(target)) phi=\(String(format: "%.1f", phi)) R=\(String(format: "%.1f", look.topRadius)) plane=\(String(format: "%.1f", plane)) visible=\(overlay.isVisible)")
        }

        if !isFast {
            if abs(target - phi) > 0.05 || abs(planeGoal(resting: resting) - plane) > 0.01 {
                setFast(true)
            }
            return
        }

        // Critically damped spring on top of the filtered angle rounds off what is left of the steps.
        // Together (α-β ω14 + spring ω35) that is about half the jitter of a plain spring at the same lag.
        let omega = 35.0
        phiVelocity += (omega * omega * (target - phi) - 2 * omega * phiVelocity) * dt
        phi += phiVelocity * dt
        if abs(target - phi) < 0.05 && abs(phiVelocity) < 0.5 {
            phi = target
            phiVelocity = 0
        }

        updatePlane(resting: resting, now: now)
        render()

        // Settled: drop back to cheap polling; a partially frosted overlay stays as it is.
        if phi == target && glide == nil && plane == planeGoal(resting: resting) && !previewing { setFast(false) }
    }

    /// Moves the anchor (and restarts the rest timer) once the lid leaves the hysteresis band.
    private func noteMotion(now: CFTimeInterval, force: Bool = false) {
        guard force || abs(rawAngle - anchorAngle) >= Self.restHysteresis else { return }
        anchorAngle = rawAngle
        lastMotion = now
    }

    /// Opening from closed is the one case where the effect should play all the way up to β. The Mac wakes
    /// while the lid is still (nearly) shut, so stillness there must not count as rest, and short hesitations
    /// while opening shouldn't either; a lid that really stops part-way (in bed, say) still takes over.
    private static let closedAngle = 10.0
    private static let openingRestDelay = 1.5

    private func isResting(now: CFTimeInterval) -> Bool {
        guard settings.releaseWhenStill, !previewing else { return false }
        var delay = settings.releaseDelay
        if openingFromClosed {
            if anchorAngle < Self.closedAngle { return false }
            delay = max(delay, Self.openingRestDelay)
        }
        return now - lastMotion >= delay
    }

    /// Where the plane is heading: it holds while the lid moves and swings onto the lid once it rests.
    /// Only ever downwards; opening is handled by the push in `updatePlane`.
    private func planeGoal(resting: Bool) -> Double {
        guard settings.releaseWhenStill else { return settings.clearAbove }
        return resting ? min(plane, anchorAngle - Self.planeMargin) : plane
    }

    private func updatePlane(resting: Bool, now: CFTimeInterval) {
        let beta = settings.clearAbove
        guard settings.releaseWhenStill else {
            glide = nil
            if plane != beta { plane = beta; publishPlane() }
            return
        }
        var p = plane
        // Push: the *smoothed* lid (never ahead of what's drawn, and never the flickering raw value) drags
        // the plane open, `planeMargin` behind it, so α stays ≤ 0 however far the lid opens.
        let lid = min(phi, anchorAngle)
        if lid - Self.planeMargin > p {
            p = lid - Self.planeMargin
            glide = nil
        }
        // Swing onto a resting lid; if the lid moves mid-swing, the plane simply stays where it is.
        let goal = resting ? min(p, anchorAngle - Self.planeMargin) : p
        if !resting {
            glide = nil
        } else if let g = glide ?? (goal < p - 0.001 ? (from: p, to: goal, start: now) : nil) {
            let progress = min((now - g.start) / Self.glideDuration, 1)
            p = g.from + (g.to - g.from) * Self.glideCurve.value(at: progress)
            glide = progress < 1 ? g : nil
        }
        if p != plane { plane = p; publishPlane() }
    }

    private func resetPlane() {
        plane = settings.clearAbove
        glide = nil
        publishPlane()
    }

    private func publishPlane() {
        let rounded = Int(plane.rounded())
        if rounded != planeAngle { planeAngle = rounded }
    }

    /// The lid angle the effect should follow right now.
    private func targetAngle(now: CFTimeInterval) -> Double {
        if previewing {
            let p = (now - previewStart) / Self.previewDuration
            if p < 1 { return previewAngle(progress: p) }
            previewing = false
            // The preview ends fully sharp; if the real lid is resting, anchor the plane there right away
            // (not at the simulated end angle), so the return to the real angle stays sharp.
            if isResting(now: now) {
                plane = rawAngle - Self.planeMargin
                glide = nil
                publishPlane()
            }
        }
        if rawAngle >= settings.clearAbove { wakeSession = false; openingFromClosed = false }
        guard settings.enabled, wakeSession || settings.blurWhileClosing else { return Self.openAngle }
        return lidAngle
    }

    /// α-β filter, critically damped: θ = e^(−ω·dt), α = 1 − θ², β = (1 − θ)².
    private func filterLid(dt: Double) {
        if abs(rawAngle - lidAngle) > 8 {         // a jump no real movement produces in one tick: resync
            lidAngle = rawAngle
            lidVelocity = 0
            return
        }
        let theta = exp(-Self.filterOmega * dt)
        let predicted = lidAngle + lidVelocity * dt
        let residual = rawAngle - predicted
        lidAngle = predicted + (1 - theta * theta) * residual
        lidVelocity += (1 - theta) * (1 - theta) / dt * residual
        if abs(rawAngle - lidAngle) < 0.01 && abs(lidVelocity) < 0.05 {
            lidAngle = rawAngle
            lidVelocity = 0
        }
    }

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
        let beta = plane
        let alpha = beta - phi
        guard alpha > 0 else { return .clear }
        let distance = sin(min(alpha, 180) * .pi / 180)   // top-edge distance to the plane, in lid heights
        return Overlay.Look(topRadius: settings.blurRadius * distance, topDim: settings.dim * distance,
                            masks: masks(for: phi))
    }

    func geometry(phi: Double, beta: Double? = nil) -> ViewGeometry {
        ViewGeometry(phi: phi, beta: beta ?? plane, width: displaySize.width, height: displaySize.height,
                     eyeDistance: settings.eyeDistance, eyeHeight: settings.eyeHeight, feather: settings.feather,
                     topFade: settings.topFade, perspective: settings.perspective, cornerPin: settings.cornerPin)
    }

    /// The overlay redraws the masks only when the key changes: the angle moved by more than 0.02° or a
    /// setting changed.
    private func masks(for phi: Double) -> Overlay.Masks? {
        guard settings.perspective || settings.topFade > 0 else { return nil }
        let size = screenPoints
        let key = [(phi * 50).rounded(), (plane * 50).rounded(), settings.eyeDistance, settings.eyeHeight, settings.feather,
                   settings.topFade, settings.perspective ? 1 : 0, settings.cornerPin ? 1 : 0, size.width, size.height]
        return Overlay.Masks(geometry: geometry(phi: phi), size: size, key: key)
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

    /// Picks up the newest reading from the poll thread (never blocks on the hardware).
    private func readSensor() {
        let latest = poller.latest
        if let angle = latest.angle { rawAngle = angle }
        if latest.available != sensorAvailable { sensorAvailable = latest.available }
    }

    private func publishAngle(_ a: Double) {
        let rounded = Int(a.rounded())
        if rounded != angle { angle = rounded }
    }
}

/// Cubic Bézier timing curve from (0, 0) to (1, 1) with control points (x1, y1), (x2, y2),
/// evaluated like `CAMediaTimingFunction`: solve x(t) = progress, return y(t).
struct CubicBezier {
    let x1, y1, x2, y2: Double
    init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) { (self.x1, self.y1, self.x2, self.y2) = (x1, y1, x2, y2) }

    private func sample(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
    }
    private func slope(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * a + 6 * u * t * (b - a) + 3 * t * t * (1 - b)
    }

    func value(at progress: Double) -> Double {
        let x = min(max(progress, 0), 1)
        var t = x
        for _ in 0..<8 {                      // Newton–Raphson, falls back to bisection on flat slopes
            let dx = sample(t, x1, x2) - x
            if abs(dx) < 1e-6 { return sample(t, y1, y2) }
            let d = slope(t, x1, x2)
            if abs(d) < 1e-6 { break }
            t = min(max(t - dx / d, 0), 1)
        }
        var lo = 0.0, hi = 1.0
        t = x
        for _ in 0..<30 {
            let v = sample(t, x1, x2)
            if abs(v - x) < 1e-6 { break }
            if v < x { lo = t } else { hi = t }
            t = (lo + hi) / 2
        }
        return sample(t, y1, y2)
    }
}


/// Hands display-link frames from the CVDisplayLink thread to the main thread: keeps only the newest
/// presentation time, never queues more than one pending frame, and drops frames of a stopped link.
private final class FrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private var pending: CFTimeInterval?

    func begin() -> Int { lock.withLock { generation += 1; pending = nil; return generation } }
    func invalidate() { lock.withLock { generation += 1; pending = nil } }

    /// Returns true if the main thread needs to be woken (nothing pending yet).
    func post(_ time: CFTimeInterval, generation g: Int) -> Bool {
        lock.withLock {
            guard g == generation else { return false }
            let wake = pending == nil
            pending = time
            return wake
        }
    }

    func take(generation g: Int) -> CFTimeInterval? {
        lock.withLock {
            guard g == generation else { return nil }
            defer { pending = nil }
            return pending
        }
    }

    private static let secondsPerHostTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    /// Host time (mach ticks) → the CACurrentMediaTime() time base.
    static func seconds(hostTime: UInt64) -> CFTimeInterval { Double(hostTime) * secondsPerHostTick }
}
