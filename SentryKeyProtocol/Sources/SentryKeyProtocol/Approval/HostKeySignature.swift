/// Splits the server's host key and signature from session-bind into the
/// raw values CryptoKit verifies (HostVerifier in the iOS app).
///
/// Checked against a real OpenSSH 10.2 login: for `ssh-ed25519`, the server
/// signs the session identifier itself (the key exchange hash), and
/// `Curve25519.Signing.PublicKey(rawRepresentation:)
/// .isValidSignature(_:for: sessionID)` is the check.
///
/// Only Ed25519 host keys are supported for now. It is OpenSSH's preferred
/// host key type and the one GitHub offers. Other types are refused.
public enum HostKeySignature {
    public struct Ed25519: Equatable, Sendable {
        /// 32-byte public key.
        public let publicKey: [UInt8]
        /// 64-byte signature.
        public let signature: [UInt8]
    }

    public static func ed25519(hostKey: [UInt8], serverSignature: [UInt8]) throws -> Ed25519 {
        var key = WireReader(hostKey)
        guard try key.readUTF8String(maxLength: 64) == "ssh-ed25519" else {
            throw WireError.unexpectedValue("host key algorithm")
        }
        let publicKey = try key.readString(maxLength: 32)
        try key.expectEnd()

        var signature = WireReader(serverSignature)
        guard try signature.readUTF8String(maxLength: 64) == "ssh-ed25519" else {
            throw WireError.unexpectedValue("signature algorithm")
        }
        let raw = try signature.readString(maxLength: 64)
        try signature.expectEnd()

        guard publicKey.count == 32, raw.count == 64 else {
            throw WireError.unexpectedValue("Ed25519 length")
        }
        return Ed25519(publicKey: publicKey, signature: raw)
    }
}
