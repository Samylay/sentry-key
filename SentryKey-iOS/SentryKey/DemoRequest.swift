#if DEBUG
import CryptoKit
import Foundation
import SentryKeyProtocol

/// Builds a realistic sign request on the phone, so the approval sheet,
/// HostVerifier and Face ID signing can be tested before the BLE channel
/// and the Mac agent exist.
///
/// It plays the server and ssh: a throwaway Ed25519 host key signs a random
/// session ID (as a real server does, see HostKeySignature), then the login
/// data is built the way OpenSSH builds it for `git@github.com`.
enum DemoRequest {
    @MainActor
    static func send(to model: AppModel) {
        guard let line = model.publicKeyLine,
              let encoded = line.split(separator: " ").dropFirst().first,
              let keyData = Data(base64Encoded: String(encoded))
        else { return }
        let ourKeyBlob = [UInt8](keyData)

        let hostKey = Curve25519.Signing.PrivateKey()
        let sessionID = [UInt8](SHA256.hash(data: Data(UUID().uuidString.utf8)))
        guard let rawSignature = try? hostKey.signature(for: Data(sessionID)) else { return }

        var hostKeyBlob = WireWriter()
        hostKeyBlob.writeString("ssh-ed25519")
        hostKeyBlob.writeString([UInt8](hostKey.publicKey.rawRepresentation))

        var signatureBlob = WireWriter()
        signatureBlob.writeString("ssh-ed25519")
        signatureBlob.writeString([UInt8](rawSignature))

        let bind = SessionBind(
            hostKey: hostKeyBlob.bytes,
            sessionID: sessionID,
            serverSignature: signatureBlob.bytes,
            isForwarding: false
        )

        var login = WireWriter()
        login.writeString(sessionID)
        login.writeByte(50) // SSH_MSG_USERAUTH_REQUEST
        login.writeString("git")
        login.writeString("ssh-connection")
        login.writeString("publickey-hostbound-v00@openssh.com")
        login.writeBool(true)
        login.writeString("ecdsa-sha2-nistp256")
        login.writeString(ourKeyBlob)
        login.writeString(hostKeyBlob.bytes)

        // The Mac numbers its requests. The demo has no Mac, so any number will do.
        let id = RequestID(rawValue: UInt32.random(in: 0...UInt32.max))
        model.receive(.sign(id: id, keyBlob: ourKeyBlob, data: login.bytes, bind: bind))
    }
}
#endif
