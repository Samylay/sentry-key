import CryptoKit
import Foundation
import Security

/// The phone identity key: it proves to the Mac, at each connection, that
/// this is the phone it was paired with (ARCHITECTURE.md, Keys).
///
/// NEEDS LINE-BY-LINE HUMAN REVIEW (crypto and Keychain code, not yet run on
/// a device).
///
/// A different key from the SSH signing key, with different rules:
/// - no Face ID, and usable once the phone has been unlocked since boot
///   (`AfterFirstUnlockThisDeviceOnly`). The secure channel has to open
///   with the phone locked in a pocket, or no request would ever arrive;
/// - it signs handshakes only, never an SSH login. What it can do without
///   the user is limited to opening the channel.
///
/// The Keychain code repeats `KeyStore`'s on purpose: that file is the SSH
/// key's and is still to be reviewed, so it was left untouched.
struct IdentityKeyStore {
    enum Failure: Error {
        case secureEnclaveUnavailable
        case accessControl
        case keychain(OSStatus)
    }

    private static let service = "SentryKey"
    private static let account = "phone-identity-key"

    func load() throws -> SecureEnclave.P256.Signing.PrivateKey? {
        guard SecureEnclave.isAvailable else { throw Failure.secureEnclaveUnavailable }
        guard let stored = try readBlob() else { return nil }
        return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: stored)
    }

    /// Loads the key, creating it if needed. Called only by pairing.
    func loadOrCreate() throws -> SecureEnclave.P256.Signing.PrivateKey {
        if let key = try load() { return key }
        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, [.privateKeyUsage], &error
        ) else {
            throw Failure.accessControl
        }
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: control)
        try saveBlob(key.dataRepresentation)
        return key
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: false, // never in iCloud Keychain
        ]
    }

    private func readBlob() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw Failure.keychain(status)
        }
    }

    private func saveBlob(_ blob: Data) throws {
        var item = baseQuery()
        item[kSecValueData as String] = blob
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }
}
