import Foundation

/// The "Allow Claude access" switch, the endpoint's port and its key.
enum ClaudeAccess {
    static let enabledKey = "claude.enabled"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// One port per app, so a debug run never takes the installed app's.
    static var port: UInt16 {
        #if DEBUG
            DataEnvironment.current == .sandbox ? 52742 : 52743
        #else
            52741
        #endif
    }

    static var url: String { "http://127.0.0.1:\(port)/mcp" }

    private static var keychain: Keychain { Keychain(account: "claude-endpoint") }
    private static var cached: String?

    /// Made the first time it's asked for. Sandbox data is made up, so its
    /// key is fixed, for scripted checks. Nil while the Keychain refuses to
    /// read the saved key: making a new one then would cut off every Claude
    /// set up with it, so requests are refused and the next one tries again.
    static var key: String? {
        #if DEBUG
            if DataEnvironment.current == .sandbox { return "compass-sandbox" }
        #endif
        if let cached { return cached }
        do {
            guard let saved = try keychain.readSaved() else { return newKey() }
            cached = saved
            return saved
        } catch {
            return nil
        }
    }

    /// Replaces the key, so anything set up with the old one stops working.
    @discardableResult
    static func newKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let key = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        do { try keychain.write(key) } catch {
            storeLog.error("Couldn't save Claude's key, so it lasts until Compass quits: \(error.localizedDescription, privacy: .public)")
        }
        cached = key
        return key
    }

    /// The command that adds Compass to Claude Code, for this user only.
    static var claudeCodeCommand: String? {
        key.map { "claude mcp add --scope user --transport http compass \(url) --header \"Authorization: Bearer \($0)\"" }
    }

    /// The bridge inside this app, for Claude desktop's config.
    static var bridgePath: String {
        Bundle.main.bundleURL.appending(path: "Contents/MacOS/compass-mcp").path
    }

    /// The entry for `mcpServers` in Claude desktop's claude_desktop_config.json.
    static var claudeDesktopEntry: String? {
        guard let key else { return nil }
        let entry: [String: Any] = [
            "compass": [
                "command": bridgePath,
                "env": [
                    "COMPASS_PORT": String(port), "COMPASS_KEY": key,
                    "COMPASS_BUNDLE_ID": Bundle.main.bundleIdentifier ?? "com.seanjaymanuel.Compass"
                ]
            ]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: entry, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
