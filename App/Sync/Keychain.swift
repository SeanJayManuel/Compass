import Foundation
import Security

/// Holds the SimpleFIN access URL and Claude's endpoint key. They are credentials, so they live in the
/// Keychain and never in the store or the repo.
struct Keychain {
    struct Failure: LocalizedError {
        var status: OSStatus
        var errorDescription: String? {
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            return "The Keychain refused to save the SimpleFIN access (\(reason))."
        }
    }

    // Per app, so Compass Dev never reaches the real app's entry.
    var service = Bundle.main.bundleIdentifier ?? "com.seanjaymanuel.Compass"
    var account: String

    /// Whether an access URL is saved. Reads attributes only, so it never
    /// triggers a Keychain access prompt.
    func exists() -> Bool {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func read() -> String? {
        (try? readSaved()) ?? nil
    }

    /// Nil when nothing is saved; throws when something is saved but the
    /// Keychain won't hand it over (access denied after a reinstall, say).
    func readSaved() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw Failure(status: status) }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String) throws {
        // Update in place, so a failure never loses the access URL already saved.
        let data = Data(value.utf8)
        var status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery
            item[kSecValueData as String] = data
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
