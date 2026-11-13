import Foundation

/// The chosen mark and accent, shared with the Dock tile plug-in so the Dock
/// keeps showing them after Compass quits (the install command also draws the
/// bundled icon from them, since macOS 27.2 skips the plug-in for a build that
/// isn't notarized). The plug-in runs in the Dock's
/// helper, outside Compass's sandbox, so it can't read Compass's own
/// defaults: the app copies the choice to a domain of its own
/// (a shared-preference exception in the entitlements) and posts a
/// notification so a loaded tile redraws.
nonisolated enum DockTileShare {
    static let markKey = "mark"
    static let accentKey = "accent"

    /// The app's bundle ID plus ".dock", so Compass Dev never changes the
    /// real app's tile. The plug-in, whose ID is the app's plus
    /// ".docktile", passes its own.
    static func suite(appID: String) -> String { appID + ".dock" }
    static func changed(appID: String) -> Notification.Name { Notification.Name(appID + ".dock.changed") }

    static func save(mark: AppMark, accent: UInt32) {
        guard let appID = Bundle.main.bundleIdentifier, let defaults = UserDefaults(suiteName: suite(appID: appID)) else { return }
        guard defaults.string(forKey: markKey) != mark.rawValue || defaults.integer(forKey: accentKey) != Int(accent) else { return }
        defaults.set(mark.rawValue, forKey: markKey)
        defaults.set(Int(accent), forKey: accentKey)
        DistributedNotificationCenter.default().postNotificationName(changed(appID: appID), object: nil, deliverImmediately: true)
    }

    /// Nil until Compass has run once with the plug-in installed.
    static func load(appID: String) -> (mark: AppMark, accent: UInt32)? {
        guard let defaults = UserDefaults(suiteName: suite(appID: appID)),
            let mark = defaults.string(forKey: markKey).flatMap(AppMark.init(rawValue:)),
            defaults.object(forKey: accentKey) != nil
        else { return nil }
        return (mark, UInt32(truncatingIfNeeded: defaults.integer(forKey: accentKey)))
    }
}
