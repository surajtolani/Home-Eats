import Foundation
import Security

/// A minimal wrapper around the Keychain Services API (the `Security`
/// framework directly — this repo has no third-party dependencies, and none
/// is needed here) for storing exactly one thing: the signed-in user's JWT
/// from the backend's `POST /auth/verify-code` (see `AccountsAPIClient`/
/// `AccountSession`). A JWT is a credential, not a preference — unlike
/// `UserDefaults` (a plain plist on disk, readable by anything with
/// filesystem access to the app's container), the Keychain encrypts items
/// at rest and ties them to the device's passcode/biometric state. No
/// special entitlement is needed here: an app reading/writing its own
/// Keychain items (scoped by `kSecAttrService`/`kSecAttrAccount` below) is
/// allowed by default — the Keychain Sharing entitlement is only for
/// sharing items *across* an app group, which isn't needed for a single
/// app's own login token.
enum KeychainTokenStore {
    /// Scopes every query below to just this one stored item, so this can
    /// never collide with (or accidentally read) anything else that might
    /// end up in this app's Keychain later. `account` is a fixed constant
    /// rather than, say, a user id, because there's only ever one signed-in
    /// user per device at a time in this app (see `AccountSession`) — a
    /// fresh sign-in as someone else simply overwrites this same item.
    private static let service = "family.homeeats.app.authToken"
    private static let account = "current"

    /// Reads the currently stored JWT, or `nil` if there isn't one —
    /// `AccountSession` treats "no token" and "signed out" as the same
    /// state.
    static func readToken() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores (or replaces) the JWT — called once, right after
    /// `POST /auth/verify-code` succeeds (see `AccountSession.completeSignIn`).
    /// Tries an update first (the common case is really "replace whatever
    /// token, if any, is already here"); `SecItemUpdate` fails with
    /// `errSecItemNotFound` when there's nothing to update yet, which is
    /// exactly when this falls back to adding a brand new item instead.
    static func saveToken(_ token: String) {
        let data = Data(token.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery() as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard updateStatus == errSecItemNotFound else { return }

        var addQuery = baseQuery()
        addQuery[kSecValueData as String] = data
        // Readable as soon as the device has been unlocked once since boot,
        // and never migrated to a new device via iCloud Keychain or backed
        // up — this token is inherently tied to one phone already (the SMS
        // code it was exchanged for went to this specific device), so there
        // is no reason for it to roam, and every reason to keep the blast
        // radius of a leaked/restored backup as small as possible.
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    /// Removes the stored token. Called both on an explicit "Sign Out" tap
    /// and automatically the moment the backend reports the token is no
    /// longer valid (see `AccountsAPIClient`'s 401 handling) — either way,
    /// deleting an item that isn't there (`errSecItemNotFound`) is a no-op,
    /// not an error worth surfacing.
    static func deleteToken() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
