import AppKit

/// User-facing feature switches (menu bar popover). Stored in UserDefaults; all default to on.
enum FeatureFlags {
    /// Leaving a protected app re-locks it (otherwise it stays unlocked until it quits).
    static let lockOnLeave = "lockOnLeave"
    /// Keep locked apps blurred while they sit in the background.
    static let backgroundShield = "backgroundShield"
    /// Hide locked apps when Mission Control opens so their contents aren't shown there.
    static let hideInMissionControl = "hideInMissionControl"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            lockOnLeave: true,
            backgroundShield: true,
            hideInMissionControl: true,
        ])
    }

    static func isOn(_ key: String) -> Bool {
        UserDefaults.standard.bool(forKey: key)
    }
}

/// One on-screen window as reported by the window server.
struct WindowInfo {
    let id: CGWindowID
    let pid: pid_t
    let ownerName: String
    let layer: Int
    let alpha: Double
    /// Global bounds, top-left origin (CoreGraphics coordinates).
    let bounds: CGRect
}

enum WindowLister {
    /// All on-screen windows, front to back.
    static func snapshot() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { entry in
            guard let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let pid = entry[kCGWindowOwnerPID as String] as? Int32,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            let alpha = entry[kCGWindowAlpha as String] as? Double ?? 1
            let owner = entry[kCGWindowOwnerName as String] as? String ?? ""
            return WindowInfo(id: id, pid: pid, ownerName: owner, layer: layer, alpha: alpha, bounds: bounds)
        }
    }

    /// Normal-level, visible, reasonably sized windows of one process, largest first.
    static func appWindows(pid: pid_t, in snapshot: [WindowInfo]) -> [WindowInfo] {
        snapshot
            .filter { $0.pid == pid && $0.layer == 0 && $0.alpha > 0 && $0.bounds.width >= 80 && $0.bounds.height >= 80 }
            .sorted { $0.bounds.width * $0.bounds.height > $1.bounds.width * $1.bounds.height }
    }

    /// Mission Control (and App Exposé) put a full-width window owned by `WindowManager` at
    /// layer 14 across the top of the screen while they are open; it does not exist otherwise.
    static func isMissionControlOpen(in snapshot: [WindowInfo]) -> Bool {
        let screenWidth = NSScreen.screens.first?.frame.width ?? 0
        return snapshot.contains {
            $0.ownerName == "WindowManager" && $0.layer == 14 && $0.bounds.width >= screenWidth * 0.9
        }
    }

    /// Convert CoreGraphics (top-left origin) bounds to Cocoa (bottom-left origin) coordinates.
    static func cocoaFrame(_ bounds: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
    }
}

/// Keeps closed overlay windows alive for a moment before they are freed.
///
/// Overlays are often closed from inside their own event handling: a click on a shield starts the
/// lock, which closes that shield; the Cancel button closes the window it lives in; Esc and Touch ID
/// callbacks tear windows down mid-callback. Freeing a window (and its view hierarchy) while one of
/// its own methods is still on the stack leaves a dangling object that crashes later, when the main
/// autorelease pool drains. Retiring the window hands the last reference to a later run-loop turn.
enum WindowGraveyard {
    private static var retired: [NSWindow] = []

    static func retire(_ window: NSWindow) {
        window.ignoresMouseEvents = true
        window.close()
        retired.append(window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            retired.removeAll { $0 === window }
        }
    }

    /// Hold any object (e.g. a hotkey whose handler is currently running) until the next turns.
    static func retireObject(_ object: AnyObject) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { _ = object }
    }
}

/// Blur layer that reports clicks instead of swallowing them.
private final class ShieldView: NSVisualEffectView {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// "Always locked": keeps a passive blur over the windows of every protected app that is
/// currently locked, even while it sits in the background. When the app is brought forward
/// the regular lock overlay (Touch ID) takes over, so there is no window of exposed content.
///
/// The shield floats above normal windows — otherwise macOS raising the app's window on
/// activation would put the window above the shield. To avoid blurring OTHER apps' windows
/// that overlap it, the parts of the shield covered by windows in front are cut out.
///
/// Both features can be switched off from the menu bar popover (see `FeatureFlags`).
final class ShieldService {
    static let shared = ShieldService()

    private struct Shield {
        let window: LockOverlayWindow
        let view: ShieldView
        var signature: String
        let bundleID: String
    }

    private var shields: [CGWindowID: Shield] = [:]
    private var timer: Timer?
    private var apps: [ProtectedApp] = []
    private var protectionEnabled = false
    private var missionControlWasOpen = false
    private var lastConfigRefresh = Date.distantPast
    private let ourPID = ProcessInfo.processInfo.processIdentifier

    private init() {}

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        removeAll()
    }

    /// Drop the shields of one app (its real lock overlay is taking over).
    func release(bundleIdentifier: String) {
        for (id, shield) in shields where shield.bundleID == bundleIdentifier {
            WindowGraveyard.retire(shield.window)
            shields[id] = nil
        }
    }

    private func removeAll() {
        shields.values.forEach { WindowGraveyard.retire($0.window) }
        shields.removeAll()
    }

    // MARK: - Tick

    private func refreshConfigIfNeeded() {
        guard Date().timeIntervalSince(lastConfigRefresh) > 1 else { return }
        lastConfigRefresh = Date()
        apps = Defaults.shared.protectedApps.filter { $0.isEnabled && !SafetyManager.isBlacklisted($0.bundleIdentifier) }
        protectionEnabled = Defaults.shared.appSettings.isProtectionEnabled
    }

    /// Locked, running, visible protected apps (excluding the one with the active overlay).
    private func lockedApps() -> [pid_t: ProtectedApp] {
        let activeLock = OverlayWindowService.shared.currentBundleIdentifier
        var result: [pid_t: ProtectedApp] = [:]
        for app in apps where app.bundleIdentifier != activeLock {
            guard !AppMonitorService.shared.isAuthenticated(app.bundleIdentifier) else { continue }
            for running in NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier)
            where !running.isHidden && !running.isTerminated {
                result[running.processIdentifier] = app
            }
        }
        return result
    }

    private func tick() {
        refreshConfigIfNeeded()
        let shieldOn = FeatureFlags.isOn(FeatureFlags.backgroundShield)
        let hideInMC = FeatureFlags.isOn(FeatureFlags.hideInMissionControl)
        guard protectionEnabled, !apps.isEmpty, shieldOn || hideInMC else {
            removeAll()
            missionControlWasOpen = false
            return
        }

        let snapshot = WindowLister.snapshot()
        let locked = lockedApps()
        if hideInMC {
            handleMissionControl(snapshot: snapshot, locked: locked)
        } else {
            // Don't hide anything that was already in Mission Control when the switch is turned on.
            missionControlWasOpen = WindowLister.isMissionControlOpen(in: snapshot)
        }
        guard shieldOn, !locked.isEmpty else { removeAll(); return }

        var seen = Set<CGWindowID>()

        for (pid, app) in locked {
            for window in WindowLister.appWindows(pid: pid, in: snapshot) {
                seen.insert(window.id)
                update(shieldFor: window, app: app, snapshot: snapshot)
            }
        }

        for (id, shield) in shields where !seen.contains(id) {
            WindowGraveyard.retire(shield.window)
            shields[id] = nil
        }
    }

    /// Mission Control draws each app's real window, so an overlay can't cover it there.
    /// Instead, hide locked apps when it opens: hidden apps are left out of Mission Control.
    /// Unlocked apps are untouched and still show up.
    private func handleMissionControl(snapshot: [WindowInfo], locked: [pid_t: ProtectedApp]) {
        let open = WindowLister.isMissionControlOpen(in: snapshot)
        defer { missionControlWasOpen = open }
        guard open, !missionControlWasOpen else { return }

        // A lock that is mid-prompt counts as locked too.
        if OverlayWindowService.shared.isShowing {
            OverlayWindowService.shared.cancelAndHide()
        }
        for pid in locked.keys {
            NSRunningApplication(processIdentifier: pid)?.hide()
        }
        NSLog("[MakLock] Mission Control opened — hid %d locked app(s)", locked.count)
    }

    private func update(shieldFor target: WindowInfo, app: ProtectedApp, snapshot: [WindowInfo]) {
        // Windows in front of the target that would end up under our floating shield.
        let frontIndex = snapshot.firstIndex(where: { $0.id == target.id }) ?? 0
        let holes: [CGRect] = snapshot[..<frontIndex]
            .filter { $0.pid != ourPID && $0.layer <= 3 && $0.alpha >= 0.5 && $0.bounds.intersects(target.bounds) }
            .map { $0.bounds.intersection(target.bounds) }
        let signature = "\(target.bounds)|\(holes)"
        let frame = WindowLister.cocoaFrame(target.bounds)

        if var shield = shields[target.id] {
            if shield.signature != signature {
                shield.window.setFrame(frame, display: false)
                shield.view.maskImage = Self.maskImage(size: target.bounds.size, origin: target.bounds.origin, holes: holes)
                shield.signature = signature
                shields[target.id] = shield
            }
            return
        }

        let window = LockOverlayWindow(covering: frame, targetWindowID: nil)
        window.targetWindowID = target.id
        window.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]

        let view = ShieldView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .vibrantDark)
        view.maskImage = Self.maskImage(size: target.bounds.size, origin: target.bounds.origin, holes: holes)
        let bundleID = app.bundleIdentifier
        view.onClick = { AppMonitorService.shared.requestLock(for: bundleID) }

        window.contentView = view
        window.orderFront(nil)
        shields[target.id] = Shield(window: window, view: view, signature: signature, bundleID: bundleID)
    }

    /// Opaque everywhere except where other windows sit in front of the target window.
    private static func maskImage(size: CGSize, origin: CGPoint, holes: [CGRect]) -> NSImage {
        NSImage(size: size, flipped: true) { rect in
            NSColor.black.setFill()
            rect.fill()
            for hole in holes {
                let local = NSRect(x: hole.minX - origin.x, y: hole.minY - origin.y, width: hole.width, height: hole.height)
                local.fill(using: .clear)
            }
            return true
        }
    }
}
