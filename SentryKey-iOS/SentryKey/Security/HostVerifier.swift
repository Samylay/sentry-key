import CryptoKit
import Foundation
import SentryKeyProtocol

/// Checks that the server really signed the session in session-bind, so the
/// host key the phone shows is the server ssh is talking to, not a name or
/// key the Mac made up.
///
/// NEEDS LINE-BY-LINE HUMAN REVIEW. The rule (Ed25519 over the session ID)
/// was confirmed with Python on a real OpenSSH 10.2 login, not yet with
/// CryptoKit on a device.
enum HostVerifier {
    static func isValid(_ bind: SessionBind) -> Bool {
        guard let parts = try? HostKeySignature.ed25519(hostKey: bind.hostKey, serverSignature: bind.serverSignature),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: parts.publicKey)
        else {
            return false
        }
        return key.isValidSignature(Data(parts.signature), for: Data(bind.sessionID))
    }
}
