import Foundation

/// Auto-update is intentionally disabled in this fork.
///
/// Upstream MakLock ships updates through Sparkle from its own appcast. Those builds don't contain
/// this fork's changes, so installing one would silently replace the fork with stock MakLock.
/// Sparkle is therefore never started: no feed URL is configured (see Info.plist) and nothing in
/// the app creates an updater. To update, build from the fork and reinstall.
enum UpdateService {
    /// Kept so the call site in `AppDelegate` stays unchanged. Does nothing.
    static func start() {}

    /// Where fork builds come from.
    static let forkURL = URL(string: "https://github.com/dalarondo/MakLock")!
}
