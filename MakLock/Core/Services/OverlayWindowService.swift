import AppKit
import HotKey
import SwiftUI

/// Manages the lock overlay: one panel per window of the protected app, kept glued to
/// those windows while locked. Also owns the Esc-to-cancel hotkey and the timeout failsafe.
final class OverlayWindowService {
    static let shared = OverlayWindowService()

    private var overlayWindows: [LockOverlayWindow] = []
    private var timeoutTimer: Timer?
    private var trackingTimer: Timer?
    private var currentApp: ProtectedApp?

    /// Last known frame of each protected app's main window. When the app is re-opened from
    /// hidden/closed, the placeholder goes exactly where its window is about to appear.
    private var lastFrames: [String: NSRect] = [:]

    /// Registered only while an overlay is up, so Esc is never swallowed otherwise.
    private var escapeHotKey: HotKey?

    /// Callback when overlay is dismissed after successful authentication.
    /// Passes the name of the unlocked app.
    var onUnlocked: ((String) -> Void)?

    /// Callback when the lock is removed without authenticating (cancel, Esc, user left,
    /// timeout). Lets the menu bar icon return to its normal state.
    var onCancelled: (() -> Void)?

    private init() {}

    // MARK: - Show / hide

    /// Show the lock overlay over the protected app's windows.
    func show(for app: ProtectedApp) {
        // Don't show duplicate overlays
        guard overlayWindows.isEmpty else { return }

        currentApp = app

        // Don't hide the protected app — the overlay blur covers its content,
        // and hiding it causes macOS to reassign app focus, which interferes
        // with the system Touch ID dialog.

        let targets = windowTargets(for: app.bundleIdentifier)
        if let first = targets.first { lastFrames[app.bundleIdentifier] = first.frame }
        if targets.isEmpty {
            createPlaceholderOverlay(for: app)
        } else {
            createWindowOverlays(for: app, targets: targets)
        }
        startTracking(for: app)
        startTimeoutTimer()
        registerEscapeKey()

        // The real lock takes over from the passive background shield.
        ShieldService.shared.release(bundleIdentifier: app.bundleIdentifier)

        NSLog("[MakLock] Overlay shown for: %@", app.name)
    }

    /// Unlock: remove the overlay, mark the app authenticated and bring it forward.
    func hide() {
        let bundleID = currentApp?.bundleIdentifier
        teardown()

        // Mark the app as authenticated so it won't re-lock immediately
        if let bundleID {
            AppMonitorService.shared.markAuthenticated(bundleID)

            // Small delay ensures overlay panels and Touch ID dialog are fully dismissed
            // before attempting to bring the app forward.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.activateProtectedApp(bundleIdentifier: bundleID)
            }
        }

        NSLog("[MakLock] Overlay dismissed")
    }

    /// Remove the overlay WITHOUT authenticating (user switched away while locked).
    func dismissWithoutAuth() {
        guard isShowing else { return }
        teardown()
        onCancelled?()
        NSLog("[MakLock] Overlay dismissed without auth (user left app)")
    }

    /// User backed out (Cancel button, Esc, accidental Dock click): remove the lock WITHOUT
    /// authenticating and hide the app so its content stays out of view. Re-opening the app
    /// locks it again.
    func cancelAndHide() {
        guard let bundleID = currentApp?.bundleIdentifier else { return }
        dismissWithoutAuth()
        AppMonitorService.shared.clearPending(bundleID)
        NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleID })?
            .hide()
        NSLog("[MakLock] Lock cancelled, app hidden: %@", bundleID)
    }

    /// Dismiss all overlays (used by panic key).
    func dismissAll() {
        hide()
    }

    /// Stop timers/hotkey, cancel any Touch ID evaluation and close every overlay panel.
    private func teardown() {
        stopTimeoutTimer()
        stopTracking()
        // Esc may be what triggered this teardown: don't free the hotkey inside its own handler.
        if let hotKey = escapeHotKey { WindowGraveyard.retireObject(hotKey) }
        escapeHotKey = nil

        // Cancel any in-progress Touch ID evaluation
        AuthenticationService.shared.cancelAuthentication()

        // Cancel/Touch ID callbacks run inside these windows' own views, so don't free them yet.
        overlayWindows.forEach { WindowGraveyard.retire($0) }
        overlayWindows.removeAll()
        currentApp = nil
    }

    // MARK: - State

    /// Whether an overlay is currently displayed.
    var isShowing: Bool {
        !overlayWindows.isEmpty
    }

    /// Bundle identifier of the currently locked app (if any).
    var currentBundleIdentifier: String? {
        currentApp?.bundleIdentifier
    }

    /// Display name of the currently locked app (if any).
    var currentAppName: String? {
        currentApp?.name
    }

    // MARK: - Input modes

    /// During Touch ID: pass through mouse events so system dialog gets interaction.
    /// After auth: restore mouse capture for overlay blocking.
    func setTouchIDMode(_ active: Bool) {
        for window in overlayWindows {
            window.ignoresMouseEvents = active
        }
    }

    /// Enable key window status on overlay windows (needed for password input).
    func enableKeyboardInput() {
        setTouchIDMode(false)
        for window in overlayWindows {
            window.allowKeyStatus = true
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Esc cancels the lock while it is showing. A Carbon hotkey needs no extra
    /// permissions, and works even though the overlay never becomes the key window.
    private func registerEscapeKey() {
        let hotKey = HotKey(key: .escape, modifiers: [])
        hotKey.keyDownHandler = { [weak self] in
            self?.cancelAndHide()
        }
        escapeHotKey = hotKey
    }

    // MARK: - Overlay windows

    private struct WindowTarget {
        let id: CGWindowID
        let frame: NSRect   // Cocoa coordinates (bottom-left origin)
    }

    /// On-screen, normal-level windows of the app, largest first.
    private func windowTargets(for bundleIdentifier: String) -> [WindowTarget] {
        guard let pid = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleIdentifier })?.processIdentifier
        else { return [] }
        return WindowLister.appWindows(pid: pid, in: WindowLister.snapshot()).map {
            WindowTarget(id: $0.id, frame: WindowLister.cocoaFrame($0.bounds))
        }
    }

    /// Build one overlay panel. Only the primary hosts the Touch ID / password UI.
    private func makeOverlay(for app: ProtectedApp, frame: NSRect, targetID: CGWindowID?, isPrimary: Bool) -> LockOverlayWindow {
        let window = LockOverlayWindow(covering: frame, targetWindowID: targetID)
        window.contentView = NSHostingView(rootView: LockOverlayView(
            appName: app.name,
            bundleIdentifier: app.bundleIdentifier,
            isPrimary: isPrimary,
            onDismiss: { [weak self] in
                let name = self?.currentApp?.name ?? "app"
                self?.hide()
                self?.onUnlocked?(name)
            }
        ))
        // Don't make key or activate — system Touch ID dialog needs focus
        if let targetID {
            window.order(.above, relativeTo: Int(targetID))
        } else {
            window.orderFront(nil)
        }
        return window
    }

    private func createWindowOverlays(for app: ProtectedApp, targets: [WindowTarget]) {
        for (index, target) in targets.enumerated() {
            overlayWindows.append(makeOverlay(for: app, frame: target.frame, targetID: target.id, isPrimary: index == 0))
        }
    }

    /// Small centered prompt used while the app has no window open yet (e.g. Dock click on a
    /// windowless Messages). It is adopted by the first real window that appears.
    private func createPlaceholderOverlay(for app: ProtectedApp) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame: NSRect
        if let last = lastFrames[app.bundleIdentifier],
           NSScreen.screens.contains(where: { $0.frame.intersects(last) }) {
            frame = last
        } else {
            let size = NSSize(width: 480, height: 360)
            frame = NSRect(x: screen.frame.midX - size.width / 2,
                           y: screen.frame.midY - size.height / 2,
                           width: size.width, height: size.height)
        }
        overlayWindows.append(makeOverlay(for: app, frame: frame, targetID: nil, isPrimary: true))
    }

    // MARK: - Tracking

    private func startTracking(for app: ProtectedApp) {
        stopTracking()
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.syncOverlays(for: app)
        }
    }

    private func stopTracking() {
        trackingTimer?.invalidate()
        trackingTimer = nil
    }

    /// Keep overlays glued to the app's windows as they move, resize, open or close.
    private func syncOverlays(for app: ProtectedApp) {
        guard !overlayWindows.isEmpty else { return }
        let targets = windowTargets(for: app.bundleIdentifier)
        let targetIDs = Set(targets.map(\.id))
        if let first = targets.first { lastFrames[app.bundleIdentifier] = first.frame }

        // Placeholder primary: adopt the largest real window once one appears.
        if let primary = overlayWindows.first, primary.targetWindowID == nil, let first = targets.first {
            primary.targetWindowID = first.id
            primary.level = .normal
            primary.setFrame(first.frame, display: true)
        }

        // Primary window (hosts the Touch ID / password UI) closed: rebuild so another
        // window (or a placeholder) takes over.
        if let primaryID = overlayWindows.first?.targetWindowID, !targetIDs.contains(primaryID) {
            overlayWindows.forEach { WindowGraveyard.retire($0) }
            overlayWindows.removeAll()
            if targets.isEmpty {
                createPlaceholderOverlay(for: app)
            } else {
                createWindowOverlays(for: app, targets: targets)
            }
            return
        }

        // Drop overlays whose window closed.
        overlayWindows.removeAll { window in
            guard let id = window.targetWindowID, !targetIDs.contains(id) else { return false }
            WindowGraveyard.retire(window)
            return true
        }

        // Follow moves/resizes; cover newly opened windows.
        for target in targets {
            if let window = overlayWindows.first(where: { $0.targetWindowID == target.id }) {
                if window.frame != target.frame { window.setFrame(target.frame, display: true) }
                window.order(.above, relativeTo: Int(target.id))
            } else {
                overlayWindows.append(makeOverlay(for: app, frame: target.frame, targetID: target.id, isPrimary: false))
            }
        }
    }

    // MARK: - App activation

    /// Bring the protected app to the foreground after successful auth.
    /// Only activates if the app is already running — never launches a closed app.
    private func activateProtectedApp(bundleIdentifier: String) {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            NSLog("[MakLock] App not running, skipping activation: %@", bundleIdentifier)
            return
        }
        app.activate()
        NSLog("[MakLock] Activated app: %@", bundleIdentifier)
    }

    // MARK: - Timeout

    /// Failsafe so a stuck overlay can never trap the user. Timing out cancels the lock
    /// and hides the app — it does NOT unlock it.
    private func startTimeoutTimer() {
        let timeout = SafetyManager.isDevMode
            ? SafetyManager.devModeTimeout
            : SafetyManager.overlayTimeout

        timeoutTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            NSLog("[MakLock Safety] Overlay timeout reached (%.0fs) — cancelling lock", timeout)
            self?.cancelAndHide()
        }
    }

    private func stopTimeoutTimer() {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
    }
}
