import CryptoKit
import Foundation
import LocalAuthentication
import Security
import SentryKeyProtocol

/// The SSH signing key, created in the Secure Enclave and never exported.
///
/// NEEDS LINE-BY-LINE HUMAN REVIEW (crypto and Keychain code, not yet run on
/// a device).
///
/// - Access control: `WhenUnlockedThisDeviceOnly` + `.privateKeyUsage` +
///   `.biometryCurrentSet`, as CLAUDE.md requires. Adding or removing a face
///   in Face ID settings invalidates the key for good.
/// - The Keychain holds only CryptoKit's `dataRepresentation`: a blob the
///   Secure Enclave encrypted, useless on any other device.
struct KeyStore {
    enum Failure: Error {
        case secureEnclaveUnavailable
        case accessControl
        case keychain(OSStatus)
        case faceIDRefused
    }

    private static let service = "SentryKey"
    private static let account = "ssh-signing-key"

    /// Same flags at creation and at every use.
    private static func accessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryCurrentSet],
            &error
        ) else {
            throw Failure.accessControl
        }
        return control
    }

    /// Loads the key, or nil if there is none. Never creates one: a missing
    /// key after pairing (new phone, restored backup) must be noticed, not
    /// silently replaced by a key the servers do not know.
    func load() throws -> SecureEnclave.P256.Signing.PrivateKey? {
        guard SecureEnclave.isAvailable else { throw Failure.secureEnclaveUnavailable }
        guard let stored = try readBlob() else { return nil }
        // Loading does not prompt. Face ID comes at signing time.
        return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: stored)
    }

    /// Loads the key, creating it if needed. Called only by pairing.
    func loadOrCreate() throws -> SecureEnclave.P256.Signing.PrivateKey {
        if let key = try load() { return key }
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: Self.accessControl())
        try saveBlob(key.dataRepresentation)
        return key
    }

    /// The key's SSH public key blob (`ecdsa-sha2-nistp256`), or nil if
    /// there is no key.
    func publicKeyBlob() throws -> [UInt8]? {
        guard let key = try load() else { return nil }
        return try ECDSAP256.publicKeyBlob(x963Point: Array(key.publicKey.x963Representation))
    }

    /// Asks for Face ID, then signs `data` once. Returns r || s (64 bytes),
    /// the input `ECDSAP256.signatureBlob(rawSignature:)` expects.
    func sign(_ data: [UInt8], reason: String) async throws -> [UInt8] {
        guard let stored = try readBlob() else { throw Failure.keychain(errSecItemNotFound) }
        let context = LAContext()
        // No "Enter Passcode" button: the key only accepts Face ID anyway.
        context.localizedFallbackTitle = ""
        // One evaluation authorizes this context for one signature. The
        // Secure Enclave checks it again itself, so skipping this call
        // cannot bypass Face ID: signing would fail instead.
        let allowed = try await context.evaluateAccessControl(
            Self.accessControl(),
            operation: .useKeySign,
            localizedReason: reason
        )
        guard allowed else { throw Failure.faceIDRefused }
        // From here on, signing must not show a second prompt (which would
        // block this thread). If the context is not enough, it fails instead.
        context.interactionNotAllowed = true
        let key = try SecureEnclave.P256.Signing.PrivateKey(
            dataRepresentation: stored,
            authenticationContext: context
        )
        let signature = try key.signature(for: Data(data))
        return Array(signature.rawRepresentation)
    }

    /// Removes the key. Servers that trusted it must be given the new one.
    func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain(status) }
    }

    // MARK: Keychain

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
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }
}

/// SHA-256 fingerprints, formatted like `ssh-keygen -l`.
enum Fingerprint {
    static func of(_ keyBlob: [UInt8]) -> String {
        let digest = Array(SHA256.hash(data: Data(keyBlob)))
        // A SHA-256 digest is always 32 bytes, so this cannot throw.
        return (try? SSHFingerprint.sha256String(digest: digest)) ?? "SHA256:?"
    }
}
