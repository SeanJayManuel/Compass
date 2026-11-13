import AppKit
import Core
import SwiftUI

/// Merchant logos, fetched once and kept on the Mac (fetch once,
/// keep local), from Google's icon service.
/// Only a website's name leaves the Mac (doordash.com), never amounts,
/// accounts or dates; `MerchantDomain` (seam 49) decides which merchants
/// have one, so people and transfers are never looked up. Any icon Google
/// finds is kept, however small (Costco's own is 16 pixels); only Google's
/// "not found" means no logo, remembered for a month before it's asked
/// again. Off in Settings > Data stops every request and shows initials.
///
/// With a logo.dev key in Settings > Data (Google's icons are too
/// small to fill the circle), logo.dev's sharp logos come first and Google's icon is the
/// fallback. Each source keeps its own files, so adding the key fetches
/// sharper logos without losing the ones on hand. The key, a publishable
/// one, is kept in the Keychain.
@MainActor @Observable
final class MerchantLogos {
    static let shared = MerchantLogos()
    static let enabledKey = "logos.fetch"

    /// Loaded images by domain; nil marks one known to have no logo.
    private(set) var images: [String: NSImage?] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []

    nonisolated private static var folder: URL {
        URL.applicationSupportDirectory.appending(path: "Compass/Logos", directoryHint: .isDirectory)
    }

    private static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static let keychain = Keychain(account: "logo-dev-key")

    /// The logo.dev key, read once and on each change in Settings.
    @ObservationIgnored private var key = MerchantLogos.keychain.read()

    /// Saves (or, empty, removes) the logo.dev key and fetches again with it.
    func setKey(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { Self.keychain.delete() } else { try Self.keychain.write(trimmed) }
        key = trimmed.isEmpty ? nil : trimmed
        images = [:]
    }

    var hasKey: Bool { key != nil }

    /// The logo for `merchant`, if there is one on hand; asks for it otherwise.
    func image(for merchant: String) -> NSImage? {
        guard Self.enabled, let domain = MerchantDomain.domain(for: merchant) else { return nil }
        if let known = images[domain] { return known }
        load(domain)
        return nil
    }

    private func load(_ domain: String) {
        guard !inFlight.contains(domain) else { return }
        inFlight.insert(domain)
        let key = key
        Task {
            var image: NSImage?
            if let key { image = await Self.cachedOrFetched(domain, source: .logoDev(key)) }
            if image == nil { image = await Self.cachedOrFetched(domain, source: .google) }
            images[domain] = .some(image)
            inFlight.remove(domain)
        }
    }

    enum Source: Sendable {
        case logoDev(String), google

        /// What its files are called: "costco.com.ld.png", "costco.com.png".
        nonisolated var suffix: String {
            switch self {
            case .logoDev: ".ld"
            case .google: ""
            }
        }

        nonisolated func url(for domain: String) -> URL? {
            switch self {
            case .logoDev(let key):
                var parts = URLComponents(string: "https://img.logo.dev/\(domain)")
                // A 404 rather than its letter stand-in when it has no logo.
                parts?.queryItems = [
                    URLQueryItem(name: "token", value: key), URLQueryItem(name: "size", value: "128"),
                    URLQueryItem(name: "format", value: "png"), URLQueryItem(name: "retina", value: "true"),
                    URLQueryItem(name: "fallback", value: "404")
                ]
                return parts?.url
            case .google:
                var parts = URLComponents(string: "https://www.google.com/s2/favicons")
                parts?.queryItems = [URLQueryItem(name: "domain", value: domain), URLQueryItem(name: "sz", value: "128")]
                return parts?.url
            }
        }
    }

    /// From disk when it's there, else from the network, saved for next time.
    @concurrent nonisolated private static func cachedOrFetched(_ domain: String, source: Source) async -> NSImage? {
        let file = folder.appending(path: "\(domain)\(source.suffix).png")
        // ".nologo", not the first build's ".none", which wrongly marked
        // small icons (Costco, DoorDash) as missing.
        let none = folder.appending(path: "\(domain)\(source.suffix).nologo")
        if let data = try? Data(contentsOf: file), let image = NSImage(data: data) { return image }
        if let checked = (try? none.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
            checked > .now.addingTimeInterval(-30 * 24 * 3600)
        {
            return nil
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // No answer at all (offline, a timeout) isn't "no logo": try again next time.
        guard let url = source.url(for: domain), let (data, response) = try? await URLSession.shared.data(from: url) else { return nil }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Both answer a site they don't know with 404.
        if status == 404 { try? Data().write(to: none); return nil }
        guard status == 200, let image = NSImage(data: data) else { return nil }
        try? data.write(to: file)
        return image
    }

    /// Settings' "Forget saved logos".
    func forget() {
        images = [:]
        try? FileManager.default.removeItem(at: Self.folder)
    }
}
