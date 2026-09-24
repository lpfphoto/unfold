import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private let angleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        Engine.shared.start()
        LoginItem.shared.enableOnFirstLaunch()
        setUpStatusItem()

        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--hold"), i + 1 < args.count, let v = Double(args[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Engine.shared.hold(angle: v) }
        } else if args.contains("--preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Engine.shared.preview() }
        } else if !Self.launchedAtLogin {
            showSettings()
        }
    }

    /// Clicking the Dock icon brings the settings window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Login-item launches happen right after Finder starts; don't pop the window up then.
    private static var launchedAtLogin: Bool {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
              let launched = finder.launchDate else { return false }
        return Date().timeIntervalSince(launched) < 60
    }

    // MARK: - Settings window

    @objc func showSettings() {
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView(
                engine: .shared, settings: .shared, login: .shared,
                onPreview: { [weak self] in self?.startPreview() }
            ))
            let window = NSWindow(contentViewController: controller)
            window.title = "Unfold"
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("UnfoldSettings")
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func startPreview() {
        Engine.shared.preview()
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "Unfold")

        let menu = NSMenu()
        menu.delegate = self
        angleItem.isEnabled = false
        menu.addItem(angleItem)
        menu.addItem(.separator())
        enabledItem.target = self
        menu.addItem(enabledItem)
        menu.addItem(withTitle: "Play Preview", action: #selector(previewFromMenu), keyEquivalent: "p").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit Unfold", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let engine = Engine.shared
        angleItem.title = engine.sensorAvailable ? "Lid angle: \(engine.angle)°" : "No lid angle sensor found"
        enabledItem.state = Settings.shared.enabled ? .on : .off
    }

    @objc private func toggleEnabled() {
        Settings.shared.enabled.toggle()
    }

    @objc private func previewFromMenu() {
        // Let the menu finish closing so the preview starts on a clean screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { Engine.shared.preview() }
    }
}

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.mainMenu = makeMainMenu()
        app.run()
    }

    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Unfold", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Unfold", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Unfold", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        return main
    }
}
