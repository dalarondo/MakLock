import AppKit

/// Overlay panel that blocks interaction with one window of a protected app.
/// Uses NSPanel with .nonactivatingPanel so MakLock does NOT become the active app
/// when the overlay is shown — this lets the system Touch ID dialog keep focus.
final class LockOverlayWindow: NSPanel {
    /// CGWindowID of the app window this panel covers. `nil` for the placeholder shown
    /// while the app has no window open yet; it adopts the first real window that appears.
    var targetWindowID: CGWindowID?

    init(covering frame: NSRect, targetWindowID: CGWindowID?) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.targetWindowID = targetWindowID
        // Covering a real window: stay in the normal layer, ordered directly above it, so
        // other apps' windows can still sit on top. Placeholder: float until it has a target.
        self.level = targetWindowID == nil ? .floating : .normal
        self.collectionBehavior = [.fullScreenAuxiliary]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.ignoresMouseEvents = false
        self.hasShadow = false
        self.isReleasedWhenClosed = false
        self.animationBehavior = .none
        self.hidesOnDeactivate = false
        self.becomesKeyOnlyIfNeeded = true
    }

    /// Whether the window should accept key status.
    /// Disabled during Touch ID (system dialog needs focus), enabled for password input.
    var allowKeyStatus = false

    override var canBecomeKey: Bool { allowKeyStatus }
    override var canBecomeMain: Bool { false }
}
