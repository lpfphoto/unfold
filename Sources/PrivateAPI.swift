import AppKit
import Darwin

/// Thin, fail-safe wrappers around private WindowServer (SkyLight) calls.
/// Every symbol is resolved at runtime; if Apple removes one, the app falls back gracefully.
enum WindowServer {
    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias SetBlurFn = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceCreateFn = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceSetLevelFn = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpacesFn = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindowsFn = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_LAZY)

    private static func symbol<T>(_ names: String...) -> T? {
        for name in names {
            if let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) ?? (skyLight.flatMap { dlsym($0, name) }) {
                return unsafeBitCast(p, to: T.self)
            }
        }
        return nil
    }

    private static let mainConnection: MainConnectionFn? = symbol("SLSMainConnectionID", "CGSMainConnectionID")
    private static let setBlur: SetBlurFn? = symbol("SLSSetWindowBackgroundBlurRadius", "CGSSetWindowBackgroundBlurRadius")
    private static let spaceCreate: SpaceCreateFn? = symbol("SLSSpaceCreate")
    private static let spaceSetLevel: SpaceSetLevelFn? = symbol("SLSSpaceSetAbsoluteLevel")
    private static let showSpaces: ShowSpacesFn? = symbol("SLSShowSpaces")
    private static let addWindows: AddWindowsFn? = symbol("SLSSpaceAddWindowsAndRemoveFromSpaces")

    // MARK: Variable backdrop blur

    static var canBlur: Bool { mainConnection != nil && setBlur != nil }

    /// Gaussian-blurs everything behind `window` with the given radius (0 = off).
    @discardableResult
    static func setBackgroundBlur(_ radius: Int, for window: NSWindow) -> Int32 {
        guard let conn = mainConnection, let setBlur, window.windowNumber > 0 else { return -1 }
        return setBlur(conn(), Int32(window.windowNumber), Int32(max(0, radius)))
    }

    // MARK: Lock screen space

    private static var lockSpace: Int32?

    static var canUseLockScreen: Bool {
        mainConnection != nil && spaceCreate != nil && spaceSetLevel != nil && showSpaces != nil && addWindows != nil
    }

    /// Absolute space levels used by the WindowServer: 0 desktop, 100 setup assistant, 200 security agent,
    /// 300 screen lock, 400 notification center at screen lock. 400 sits just above the lock screen.
    private static let aboveLockScreenLevel: Int32 = 400

    /// Moves `window` into a dedicated space that sits above everything, including the lock screen.
    @discardableResult
    static func moveAboveLockScreen(_ window: NSWindow) -> String {
        guard canUseLockScreen, let conn = mainConnection?(), window.windowNumber > 0 else { return "unavailable" }
        var info = ""
        if lockSpace == nil, let spaceCreate, let spaceSetLevel, let showSpaces {
            let space = spaceCreate(conn, 1, 0)
            let level = spaceSetLevel(conn, space, aboveLockScreenLevel)
            let shown = showSpaces(conn, [space] as CFArray)
            lockSpace = space
            info = "created space \(space) level=\(level) show=\(shown) "
        }
        guard let space = lockSpace, let addWindows else { return info + "no space" }
        let added = addWindows(conn, space, [window.windowNumber] as CFArray, 7)
        return info + "add=\(added)"
    }
}
