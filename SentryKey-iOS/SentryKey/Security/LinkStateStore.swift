import Foundation
import Security

/// What the app needs to answer a Mac while the phone is locked, kept in
/// the Keychain (ARCHITECTURE.md, Keys).
///
/// `Storage`'s file uses `complete` protection, so it cannot be read while
/// the phone is locked. When iOS relaunches the app in the background for a
/// Bluetooth event, the app still has to recognise the paired Mac (to run
/// the handshake) and its own SSH public key (to check the request). Both
/// are public keys, so this item holds no secret. It uses the same rule as
/// the identity key: `AfterFirstUnlockThisDeviceOnly`, never synchronized.
///
/// The names of servers stay in the file: they are shown only once the user
/// has unlocked the phone to answer.
///
/// NEEDS LINE-BY-LINE HUMAN REVIEW (Keychain code, not yet run on a device).
struct LinkStateStore {
    struct State: Codable, Equatable {
        /// Identity public keys of the paired Macs.
        var pairedMacKeys: [[UInt8]] = []
        /// The SSH public key blob, a copy of what `KeyStore` gives while
        /// the phone is unlocked.
        var sshKeyBlob: [UInt8]?
    }

    enum Failure: Error {
        case keychain(OSStatus)
    }

    private static let service = "SentryKey"
    private static let account = "link-state"
    /// Far larger than a few public keys; refuses a corrupted item.
    private static let maxLength = 64 * 1024

    /// The saved state, or nil if there is none yet. Throws while the phone
    /// has not been unlocked since it started.
    func load() throws -> State? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, data.count <= Self.maxLength else { return nil }
            return try? JSONDecoder().decode(State.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw Failure.keychain(status)
        }
    }

    func save(_ state: State) throws {
        let data = try JSONEncoder().encode(state)
        let update = SecItemUpdate(
            baseQuery() as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        switch update {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = baseQuery()
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw Failure.keychain(status) }
        default:
            throw Failure.keychain(update)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: false, // never in iCloud Keychain
        ]
    }
}
