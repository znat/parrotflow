import Foundation
import Security

/// API keys in the login keychain, one item per model named in `models:`.
///
/// The point is that nothing has to be written into `config.yaml`, which is a
/// file people paste to each other. A model entry names no key at all and the
/// key lives here instead — see `KeySource.Kind.keychain`.
///
/// **Access is scoped to the code signature, not to the path.** The installed
/// app is signed (`scripts/release.sh`) and keeps its access across upgrades
/// signed with the same certificate. A `swift build` binary is not signed, so
/// macOS sees a different application and asks the user to allow it — once per
/// build, because an unsigned binary's identity changes every compile. That is
/// expected in development and invisible in the shipped app. `file:` still
/// works and is the way out of it.
enum Keychain {

    /// `ParrotFlow` or `ParrotFlow Dev`, split for the same reason
    /// `AppVariant.configDirectory` is: a key added while testing must not
    /// reach the copy that does your work, and neither may overwrite the other.
    static var service: String { AppVariant.displayName }

    /// What went wrong, in the words `--set-key` prints.
    struct Failure: LocalizedError {
        let status: OSStatus
        let doing: String
        var errorDescription: String? {
            let said = SecCopyErrorMessageString(status, nil) as String?
            return "could not \(doing) the keychain: \(said ?? "OSStatus \(status)")"
        }
    }

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// The key stored for a model, or nil when there is none.
    ///
    /// Nil for a denied prompt as well as for a missing item, and deliberately
    /// so: both mean this call cannot go out, and the caller — `LLM` — already
    /// has one path for that which leaves the transcript untouched.
    static func read(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    static func has(_ account: String) -> Bool { read(account) != nil }

    /// Write the key for a model, replacing whatever was there.
    ///
    /// `AfterFirstUnlockThisDeviceOnly`: never synced to iCloud, and readable
    /// after a reboot without the app being frontmost — the pipeline runs from
    /// a hotkey and cannot wait for someone to unlock anything.
    ///
    /// **Replacing means delete and add, not `SecItemUpdate`.** An update keeps
    /// the item's existing ACL, and the ACL decides whether this app can read
    /// the key back without asking for the login password. A key first stored
    /// by `--set-key` from a `swift build` binary belongs to that binary, so
    /// the app is a stranger to it and macOS asks on every launch — and
    /// re-entering the key did not help, because the update inherited the same
    /// ACL. A fresh item makes whoever writes it the owner, so entering the key
    /// again is the way out.
    static func write(_ key: String, account: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8), !trimmed.isEmpty else {
            throw Failure(status: errSecParam, doing: "write an empty key to")
        }
        var add = query(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        // Add first, so a key that was never there cannot be lost to a delete
        // followed by a failing add. Only a duplicate is worth removing.
        let added = SecItemAdd(add as CFDictionary, nil)
        if added == errSecSuccess { return }
        guard added == errSecDuplicateItem else {
            throw Failure(status: added, doing: "add to")
        }
        let removed = SecItemDelete(query(account) as CFDictionary)
        guard removed == errSecSuccess || removed == errSecItemNotFound else {
            throw Failure(status: removed, doing: "replace the key in")
        }
        let readded = SecItemAdd(add as CFDictionary, nil)
        guard readded == errSecSuccess else {
            throw Failure(status: readded, doing: "store the replacement key in")
        }
    }

    /// Forget the key for a model. Missing is not an error: the end state is
    /// the one asked for either way.
    static func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure(status: status, doing: "delete from")
        }
    }
}
