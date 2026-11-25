import CryptoKit
import Foundation
import SentryKeyProtocol

/// Verifies an `ecdsa-sha2-nistp256` SSH signature with CryptoKit.
///
/// NEEDS LINE-BY-LINE HUMAN REVIEW (crypto code).
public struct P256SignatureVerifier: SignatureVerifying {
    public init() {}

    public func isValid(signatureBlob: [UInt8], data: [UInt8], publicKeyBlob: [UInt8]) -> Bool {
        guard let rawSignature = try? ECDSAP256.rawSignature(fromSignatureBlob: signatureBlob),
              let point = try? ECDSAP256.x963Point(fromPublicKeyBlob: publicKeyBlob),
              let key = try? P256.Signing.PublicKey(x963Representation: point),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: rawSignature)
        else {
            return false
        }
        // CryptoKit hashes `data` with SHA-256 itself, as RFC 5656 requires
        // for this key type.
        return key.isValidSignature(signature, for: Data(data))
    }
}
