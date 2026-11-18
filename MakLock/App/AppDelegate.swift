import AppKit

/// Application delegate responsible for lifecycle and menu bar setup.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let menuBarController = MenuBarController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        FeatureFlags.registerDefaults()
        menuBarController.setup()

        // Auto-update is disabled in this fork (a stock upstream build would overwrite it)
        UpdateService.start()

        // Show onboarding on first launch
        OnboardingWindowController.shared.showIfNeeded()

        // Initialize safety manager and wire up panic key
        SafetyManager.shared.onPanicKeyPressed = { [weak self] in
            OverlayWindowService.shared.dismissAll()
            self?.menuBarController.iconState = .idle
        }

        // Initialize settings window controller (listens for openSettings notification)
        _ = SettingsWindowController.shared

        // Wire up app monitor → overlay
        AppMonitorService.shared.onProtectedAppDetected = { [weak self] app in
            // Auto-unlock if Watch is in range AND unlocked (on wrist).
            // If Watch is nearby but locked/off wrist, fall through to Touch ID.
            let watch = WatchProximityService.shared
            let watchCanUnlock = Defaults.shared.appSettings.useWatchUnlock
                && watch.isWatchInRange
                && (watch.isWatchUnlocked ?? true)
            if watchCanUnlock {
                AppMonitorService.shared.markAuthenticated(app.bundleIdentifier)
                WatchUnlockToast.shared.show(for: app.bundleIdentifier)
                return
            }
            OverlayWindowService.shared.show(for: app)
            self?.menuBarController.iconState = .locked
        }

        // Update icon when overlay is dismissed after successful auth
        OverlayWindowService.shared.onUnlocked = { [weak self] _ in
            self?.menuBarController.iconState = .active
        }

        // Keep locked apps blurred even while they sit in the background
        ShieldService.shared.start()

        // Lock removed without authenticating (Cancel, Esc, switched away, timeout)
        OverlayWindowService.shared.onCancelled = { [weak self] in
            self?.menuBarController.iconState = .active
        }

        // Start Watch proximity BEFORE app monitoring so Watch has time to connect.
        // This prevents false overlay triggers on app restart.
        if Defaults.shared.appSettings.useWatchUnlock {
            WatchProximityService.shared.startScanning()
        }

        // Delay app monitoring slightly to give Watch time to connect on startup.
        // Without this, protected running apps would trigger overlays before
        // the Watch connection is established.
        let monitorDelay: TimeInterval = Defaults.shared.appSettings.useWatchUnlock ? 8.0 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + monitorDelay) {
            AppMonitorService.shared.startMonitoring()
        }

        // Start auto-close monitoring if any protected app has auto-close enabled
        if ProtectedAppsManager.shared.apps.contains(where: { $0.autoClose }) {
            AppInactivityService.shared.startMonitoring()
        }

        // Wire up idle monitor → lock/close all running protected apps
        IdleMonitorService.shared.onIdleTimeoutReached = { [weak self] in
            self?.lockOrCloseProtectedApps()
        }

        // Start idle monitoring if enabled
        if Defaults.shared.appSettings.lockOnIdle {
            IdleMonitorService.shared.startMonitoring()
        }

        // Wire up sleep → close autoClose apps, lock others if lockOnSleep enabled
        SleepWakeService.shared.onSleep = { [weak self] in
            self?.lockOrCloseProtectedApps(showOverlays: Defaults.shared.appSettings.lockOnSleep)
        }

        // On wake, terminate any auto-close apps that survived sleep
        // and dismiss their overlays if any were shown
        SleepWakeService.shared.onWake = { [weak self] in
            self?.terminateAutoCloseApps()
        }

        // Start sleep/wake observer
        SleepWakeService.shared.startObserving()

        // Wire up Watch proximity → auto-unlock when Watch returns in range
        WatchProximityService.shared.onWatchInRange = { [weak self] in
            guard OverlayWindowService.shared.isShowing else { return }
            // Only auto-unlock if Watch is on wrist (unlocked)
            guard WatchProximityService.shared.isWatchUnlocked ?? true else { return }
            let lockedBundleID = OverlayWindowService.shared.currentBundleIdentifier
            OverlayWindowService.shared.hide()
            WatchUnlockToast.shared.show(for: lockedBundleID)
            self?.menuBarController.iconState = .active
        }

        // Wire up Watch proximity → lock/close when Watch leaves range
        WatchProximityService.shared.onWatchOutOfRange = { [weak self] in
            self?.lockOrCloseProtectedApps()
        }

    }

    // MARK: - Lock / Close Helpers

    /// Lock or close all running protected apps (idle, sleep, Watch out of range).
    /// Apps with autoClose → forceTerminate. Every other app is re-locked by clearing its
    /// unlock state; the background shield covers it and the Touch ID prompt appears when you
    /// actually open it. Only the app you are in right now gets the prompt immediately
    /// (if showOverlays is true), so a lock never pops up for an app you aren't using.
    private func lockOrCloseProtectedApps(showOverlays: Bool = true) {
        AppMonitorService.shared.clearAllAuthentications()
        let frontmostID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let runningBundleIDs = Set(NSWorkspace.shared.runningApplications.map(\.bundleIdentifier))
        let apps = ProtectedAppsManager.shared.apps.filter {
            $0.isEnabled && runningBundleIDs.contains($0.bundleIdentifier)
        }

        var showedOverlay = false
        for app in apps {
            if app.autoClose && !SafetyManager.isBlacklisted(app.bundleIdentifier) {
                if let running = NSWorkspace.shared.runningApplications.first(where: {
                    $0.bundleIdentifier == app.bundleIdentifier
                }) {
                    running.forceTerminate()
                    NSLog("[MakLock] Auto-closed: %@ (%@)", app.name, app.bundleIdentifier)
                }
            } else if showOverlays && app.bundleIdentifier == frontmostID {
                OverlayWindowService.shared.show(for: app)
                showedOverlay = true
            }
        }

        if showedOverlay {
            menuBarController.iconState = .locked
        }
    }

    /// Terminate any running auto-close apps (safety net for wake from sleep).
    /// Also dismisses overlay if it's showing for an auto-close app.
    private func terminateAutoCloseApps() {
        let runningBundleIDs = Set(NSWorkspace.shared.runningApplications.map(\.bundleIdentifier))
        let autoCloseApps = ProtectedAppsManager.shared.apps.filter {
            $0.isEnabled && $0.autoClose && runningBundleIDs.contains($0.bundleIdentifier)
        }

        for app in autoCloseApps {
            guard !SafetyManager.isBlacklisted(app.bundleIdentifier) else { continue }

            // Dismiss overlay if it's showing for this app
            if OverlayWindowService.shared.currentBundleIdentifier == app.bundleIdentifier {
                OverlayWindowService.shared.dismissAll()
            }

            if let running = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == app.bundleIdentifier
            }) {
                running.forceTerminate()
                AppMonitorService.shared.clearAuthentication(for: app.bundleIdentifier)
                NSLog("[MakLock] Auto-closed on wake: %@ (%@)", app.name, app.bundleIdentifier)
            }
        }
    }
}
