import Foundation
import ServiceManagement

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    /// Master switch.
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "enabled") } }
    /// Also blur live while the lid is being closed (not only after waking).
    @Published var blurWhileClosing: Bool { didSet { defaults.set(blurWhileClosing, forKey: "blurWhileClosing") } }
    /// Let the effect fade away when the lid stays still part-way open.
    @Published var releaseWhenStill: Bool { didSet { defaults.set(releaseWhenStill, forKey: "releaseWhenStill") } }
    /// Seconds without lid movement before the effect lets go.
    @Published var releaseDelay: Double { didSet { defaults.set(releaseDelay, forKey: "releaseDelay") } }
    /// Draw the effect above the lock screen that appears when the Mac wakes.
    @Published var showOnLockScreen: Bool { didSet { defaults.set(showOnLockScreen, forKey: "showOnLockScreen") } }
    /// Angle (degrees) below which the whole picture fades to black; fully black at 0°.
    @Published var blackBelow: Double { didSet { defaults.set(blackBelow, forKey: "blackBelow") } }
    /// β: angle (degrees) of the virtual image plane. Once the lid reaches it, the screen is completely sharp.
    @Published var clearAbove: Double { didSet { defaults.set(clearAbove, forKey: "clearAbove") } }
    /// Blur radius at the top edge when the lid is 90° away from the image plane, in points.
    @Published var blurRadius: Double { didSet { defaults.set(blurRadius, forKey: "blurRadius") } }
    /// Darkening at the top edge when the lid is 90° away from the image plane, 0...1.
    @Published var dim: Double { didSet { defaults.set(dim, forKey: "dim") } }

    /// Black out everything outside the virtual screen as seen from the eye position.
    @Published var perspective: Bool { didSet { defaults.set(perspective, forKey: "perspective") } }
    /// Horizontal distance eye ↔ hinge, cm.
    @Published var eyeDistance: Double { didSet { defaults.set(eyeDistance, forKey: "eyeDistance") } }
    /// Eye height above the keyboard, cm.
    @Published var eyeHeight: Double { didSet { defaults.set(eyeHeight, forKey: "eyeHeight") } }
    /// Fade to black at the physical top edge (at α = 90°), cm; shrinks to nothing at β.
    @Published var topFade: Double { didSet { defaults.set(topFade, forKey: "topFade") } }
    /// Width of the blur-to-black falloff at the virtual edges, cm.
    @Published var feather: Double { didSet { defaults.set(feather, forKey: "feather") } }

    private init() {
        defaults.register(defaults: [
            "enabled": true,
            "blurWhileClosing": true,
            "showOnLockScreen": true,
            "releaseWhenStill": true,
            "releaseDelay": 0.5,
            "blackBelow": 20.0,
            "clearAbove": 90.0,
            "blurRadius": 70.0,
            "dim": 0.35,
            "perspective": true,
            "eyeDistance": 55.0,
            "eyeHeight": 25.0,
            "feather": 3.0,
            "topFade": 4.0,
        ])
        enabled = defaults.bool(forKey: "enabled")
        blurWhileClosing = defaults.bool(forKey: "blurWhileClosing")
        showOnLockScreen = defaults.bool(forKey: "showOnLockScreen")
        releaseWhenStill = defaults.bool(forKey: "releaseWhenStill")
        releaseDelay = defaults.double(forKey: "releaseDelay")
        blackBelow = defaults.double(forKey: "blackBelow")
        clearAbove = defaults.double(forKey: "clearAbove")
        blurRadius = defaults.double(forKey: "blurRadius")
        dim = defaults.double(forKey: "dim")
        perspective = defaults.bool(forKey: "perspective")
        eyeDistance = defaults.double(forKey: "eyeDistance")
        eyeHeight = defaults.double(forKey: "eyeHeight")
        feather = defaults.double(forKey: "feather")
        topFade = defaults.double(forKey: "topFade")
    }
}

@MainActor
final class LoginItem: ObservableObject {
    static let shared = LoginItem()
    @Published private(set) var isEnabled = SMAppService.mainApp.status == .enabled
    @Published private(set) var error: String?

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Registers once on first launch so the effect is there after every restart.
    func enableOnFirstLaunch() {
        let key = "didOfferLoginItem"
        // Only once the app has been installed, so test builds don't register themselves.
        guard Bundle.main.bundlePath.hasPrefix("/Applications/"), !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        set(true)
    }
}
