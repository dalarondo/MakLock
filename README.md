<p align="center">
  <img src="Resources/icon.png" width="128" height="128" alt="MakLock icon">
</p>

<h1 align="center">MakLock</h1>

<p align="center">
  <strong>Lock any macOS app with Touch ID, Apple Watch, or password.</strong><br>
  Free, open source, and more powerful than paid alternatives.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-black?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/swift-5.9%2B-FFD213?style=flat-square" alt="Swift">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-white?style=flat-square" alt="License"></a>
  <a href="https://github.com/dutkiewiczmaciej/MakLock/stargazers"><img src="https://img.shields.io/github/stars/dutkiewiczmaciej/MakLock?style=flat-square&color=FFD213" alt="Stars"></a>
  <a href="https://github.com/dutkiewiczmaciej/MakLock/releases/latest"><img src="https://img.shields.io/github/v/release/dutkiewiczmaciej/MakLock?style=flat-square&label=release" alt="Release"></a>
  <a href="https://github.com/dutkiewiczmaciej/MakLock/releases"><img src="https://img.shields.io/github/downloads/dutkiewiczmaciej/MakLock/total?style=flat-square&color=34C759&label=downloads&v=2" alt="Downloads"></a>
</p>

---

## About this fork

This is a personal fork of [dutkiewiczmaciej/MakLock](https://github.com/dutkiewiczmaciej/MakLock) that turns it into an **always-locked** app locker. The changes live on the `always-locked-per-window` branch; `main` is kept identical to upstream.

### What's different from upstream

| Area | Upstream | This fork |
|------|----------|-----------|
| **When an app locks** | Unlocked until the app quits, or idle / sleep | Re-locks the moment you switch away, so every return (Dock click, Cmd+Tab) needs auth again |
| **Overlay** | Full-screen blur on every monitor | Blur and unlock card cover **only the locked app's windows**, following them as they move, resize, or open |
| **App with no window yet** | n/a | A small placeholder card appears at the window's last position and snaps onto the real window when it opens |
| **Backing out** | Panic key only (which unlocks) | **Cancel** button and **Esc** drop the lock *without* unlocking and hide the app, for accidental Dock clicks |
| **60 s overlay timeout** | Unlocks the app | Cancels the lock and hides the app instead |
| **Background apps** | Contents visible until you switch to them | Locked apps stay blurred in the background (shield); clicking one starts the unlock |
| **Mission Control** | Locked windows appear unblurred | Locked apps are hidden while Mission Control is open; unlocked apps still show |
| **Lock latency** | -- | Also reacts to un-hide, starts Touch ID sooner, shorter card animation, cached icons |
| **Settings** | -- | Menu bar popover toggles for lock-on-leave, background blur, and hiding in Mission Control (all on by default) |

### Known limitations

- macOS gives apps no way to pause another app's launch or activation, so the lock lands just after the app comes forward; a window can flash for a moment. Stopping that would need Apple's Endpoint Security entitlement.
- Mission Control and Exposé show real window snapshots, which is why locked apps are hidden there instead of blurred.
- Builds from this fork are ad-hoc signed, not notarized, and Sparkle auto-update or `brew upgrade` will replace them with the stock release.

### Installing this fork

Only building from source installs these changes (the DMG and Homebrew cask are upstream's):

```bash
git clone -b always-locked-per-window https://github.com/dalarondo/MakLock.git
cd MakLock
xcodebuild -project MakLock.xcodeproj -scheme MakLock -configuration Release \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO build
```

Then copy the built `MakLock.app` to `/Applications` and re-sign it with `codesign --force --deep -s - /Applications/MakLock.app`.

---

## What is MakLock?

MakLock is a lightweight menu bar app that protects your macOS applications with Touch ID, Apple Watch proximity, or a backup password. When someone tries to open or switch to a protected app, MakLock blocks access with a blur overlay and requires authentication.

Unlike App Store alternatives, MakLock is distributed directly — giving it full overlay and process management capabilities that sandboxed apps simply cannot offer.

## Why MakLock?

| Feature | MakLock | AppLocker ($17.99) | Cisdem AppCrypt ($19.99/yr) |
|---------|:-------:|:------------------:|:---------------------------:|
| **Price** | **Free forever** | 1 app free, paid for more | Trial only |
| **Open source** | **Yes** | No | No |
| **Touch ID** | **Yes** | Paid only | No |
| **Lock on app switch** | **Yes** | No (launch only) | Yes (direct version) |
| **Apple Watch unlock** | **Yes** (wrist detection) | No | No |
| **Full-screen overlay** | **Yes** (blur, all monitors) | Yes (solid, single monitor) | Dialog box |
| **No content flash** | **Yes** (NSPanel) | No (brief flash on launch) | N/A |
| **Auto-close apps** | **Yes** | No (sandbox) | Yes (direct version) |
| **Close apps on sleep** | **Yes** | No | No |
| **Auto-lock on idle** | **Yes** | No | Yes |
| **Auto-lock on sleep** | **Yes** | No | No |
| **Panic key** | **Yes** | No | No |
| **Multi-monitor** | **Yes** | Unknown | No |
| **Bypass resistant** | **Yes** | No (Bundle ID edit) | Unknown |
| **Can't be deleted without auth** | N/A | No (sandbox) | Yes (direct version) |

AppLocker (App Store) is sandboxed — it can only intercept app launches, not activations. If an app is already running, switching back shows content without authentication. Its overlay can also freeze the entire Mac, requiring a hard reboot. MakLock uses a non-activating NSPanel overlay that never steals focus, preventing these issues.

## Features

- [x] Lock apps with Touch ID (single prompt)
- [x] Password fallback for Macs without Touch ID
- [x] Apple Watch proximity unlock with wrist detection
- [x] Full-screen blur overlay on all monitors
- [x] Auto-lock after idle timeout (configurable)
- [x] Auto-lock on sleep/wake
- [x] Auto-close inactive apps (prevents notification snooping)
- [x] Close protected apps on sleep (privacy on shared laptops)
- [x] Menu bar app (no Dock icon, runs silently)
- [x] Panic key emergency exit (`Cmd+Opt+Shift+Ctrl+U`)
- [x] Esc / Cancel to back out of a lock without unlocking *(this fork)*
- [x] Per-window overlay, background shield, Mission Control hiding *(this fork)*
- [x] System app blacklist (Terminal, Xcode, etc. can never be locked)
- [x] Multi-monitor support
- [x] First launch onboarding
- [x] Settings with tabbed UI
- [x] Automatic updates via Sparkle 2
- [ ] Trusted Wi-Fi auto-unlock *(coming in v1.1)*
- [ ] Per-window overlay *(coming in v1.2)*

## Screenshots

<p align="center">
  <img src="Resources/screenshots/overlay.png" width="720" alt="Lock overlay">
  <br><em>Full-screen blur overlay with Touch ID unlock</em>
</p>

<p align="center">
  <img src="Resources/screenshots/settings.png" width="560" alt="Settings window">
  <br><em>Settings with protected apps management</em>
</p>

<p align="center">
  <img src="Resources/screenshots/menubar.png" width="280" alt="Menu bar">
  <br><em>Menu bar with quick toggle and status</em>
</p>

## Installation

### Download

**[Download MakLock 1.0.0](https://github.com/dutkiewiczmaciej/MakLock/releases/latest)** — open the DMG and drag to Applications.

> Signed with Developer ID and notarized by Apple. No Gatekeeper warnings — just download and run.

### Homebrew

```bash
brew tap dutkiewiczmaciej/tap
brew install --cask maklock
```

### Build from Source

```bash
git clone https://github.com/dutkiewiczmaciej/MakLock.git
cd MakLock
open MakLock.xcodeproj
```

Build and run with `Cmd+R`. Requires Xcode 15+ and macOS 13+.

## How It Works

1. **App Monitor** — watches for protected app launches and activations via NSWorkspace
2. **Lock Overlay** — instantly shows a full-screen blur overlay on all displays
3. **Authentication** — prompts Touch ID, checks Apple Watch proximity, or asks for password
4. **Re-lock on quit** — Cmd+Q clears authentication, so the next launch requires re-auth (even for apps that stay alive in background like Messages)
5. **Auto-lock** — re-locks on idle timeout, sleep, or when Apple Watch leaves range
6. **Auto-close** — optionally terminates inactive protected apps to prevent notification snooping

## Architecture

MakLock is a native Swift/SwiftUI application distributed outside the App Store for full system access.

```
MakLock/
  App/        Entry point, AppDelegate
  Core/       Services (AppMonitor, Auth, Watch, Overlay, Idle, Sleep, Inactivity)
  UI/         Design system, Components, Settings, Lock Overlay
  Models/     Data models (ProtectedApp, AppSettings, LockSession)
  Resources/  Assets, Info.plist, Entitlements
```

**Key frameworks:** SwiftUI, AppKit, LocalAuthentication, CoreBluetooth, IOKit, ServiceManagement, HotKey (SPM), Sparkle 2 (SPM)

## Safety

MakLock includes multiple safety mechanisms to ensure you never get locked out:

- **Panic key** — `Cmd+Option+Shift+Control+U` instantly dismisses all overlays
- **System blacklist** — Terminal, Xcode, Activity Monitor, and other critical apps can never be locked
- **Timeout failsafe** — overlays auto-dismiss after 60 seconds without interaction
- **Dev mode** — DEBUG builds include a Skip button and 10-second auto-dismiss

## Requirements

- macOS 13.0 (Ventura) or later
- Apple Silicon or Intel Mac
- Touch ID recommended (password fallback available)
- Apple Watch with watchOS 9+ for proximity unlock (optional)

## Contributing

Contributions are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

If you find MakLock useful, consider giving it a [star on GitHub](https://github.com/dutkiewiczmaciej/MakLock) — it helps others discover the project.

## License

[MIT](LICENSE) — Made by [MakMak](https://github.com/dutkiewiczmaciej)
