import CryptoKit
import Foundation
import SentryKeyAgent
import SentryKeyProtocol

/// Stands in for the iPhone on a developer's Mac, so the agent can be tried
/// with a real `ssh` before the Bluetooth link exists.
///
/// DEVELOPMENT AND TESTS ONLY. Its signing key is an ordinary key in this
/// process's memory, which is exactly what SentryKey exists to avoid. It is
/// never written to disk, and this target is not linked by the real agent.
///
/// It runs the same checks as the phone before signing (`LoginApprovalCheck`
/// and the server's signature over the session), so a request the phone
/// would refuse is refused here too. It asks nobody: `Behaviour` decides.
public actor SoftwarePhone {
    public enum Behaviour: Sendable {
        case approve
        case deny
        /// The phone is reachable but the user never answers.
        case neverAnswer
        /// Answers with a signature from another key.
        case signWithAnotherKey
    }

    /// The stand-in's SSH public key blob, to install on the test server.
    public nonisolated let publicKeyBlob: [UInt8]

    // The secret scanner takes the type name on this line for a secret.
    private let standInKey: P256.Signing.PrivateKey // gitleaks:allow
    private let behaviour: Behaviour
    private let onApproval: @Sendable (LoginApproval) -> Void

    /// - Parameter onApproval: called with what the phone would display,
    ///   just before signing.
    public init(
        behaviour: Behaviour = .approve,
        onApproval: @escaping @Sendable (LoginApproval) -> Void = { _ in }
    ) throws {
        let key = P256.Signing.PrivateKey()
        self.standInKey = key
        self.behaviour = behaviour
        self.onApproval = onApproval
        self.publicKeyBlob = try ECDSAP256.publicKeyBlob(x963Point: Array(key.publicKey.x963Representation))
    }

    /// What the phone answers to one request, or nil when it stays silent.
    public func answer(to request: PhoneRequest) -> PhoneResponse? {
        // A cancel needs no answer, and there is no prompt here to drop.
        guard case .sign(let id, let keyBlob, let data, let bind) = request else { return nil }

        let approval: LoginApproval
        do {
            approval = try LoginApprovalCheck.check(
                requestKeyBlob: keyBlob, data: data, bind: bind, ourKeyBlob: publicKeyBlob
            )
        } catch {
            return PhoneResponse(id: id, outcome: .refused(.invalidRequest))
        }
        // `LoginApprovalCheck` guarantees `bind` exists.
        guard let bind, Self.serverSigned(bind) else {
            return PhoneResponse(id: id, outcome: .refused(.invalidRequest))
        }

        switch behaviour {
        case .approve:
            onApproval(approval)
            return signedResponse(id: id, data: data, key: standInKey)
        case .signWithAnotherKey:
            return signedResponse(id: id, data: data, key: P256.Signing.PrivateKey())
        case .deny:
            return PhoneResponse(id: id, outcome: .refused(.deniedByUser))
        case .neverAnswer:
            return nil
        }
    }

    private func signedResponse(id: RequestID, data: [UInt8], key: P256.Signing.PrivateKey) -> PhoneResponse {
        guard let raw = try? key.signature(for: Data(data)).rawRepresentation,
              let blob = try? ECDSAP256.signatureBlob(rawSignature: Array(raw))
        else {
            return PhoneResponse(id: id, outcome: .refused(.keyUnavailable))
        }
        return PhoneResponse(id: id, outcome: .signature(blob: blob))
    }

    /// The same rule as `HostVerifier` in the iOS app: the server signed the
    /// session identifier with its Ed25519 host key.
    private static func serverSigned(_ bind: SessionBind) -> Bool {
        guard let parts = try? HostKeySignature.ed25519(hostKey: bind.hostKey, serverSignature: bind.serverSignature),
              let hostKey = try? Curve25519.Signing.PublicKey(rawRepresentation: parts.publicKey)
        else {
            return false
        }
        return hostKey.isValidSignature(Data(parts.signature), for: Data(bind.sessionID))
    }
}

/// An identity key held in memory. On the devices, identity keys live in a
/// Secure Enclave.
///
/// DEVELOPMENT AND TESTS ONLY, like `SoftwarePhone`.
public struct SoftwareIdentity: IdentitySigner {
    private let key = P256.Signing.PrivateKey()

    public init() {}

    public var publicKey: [UInt8] {
        Array(key.publicKey.x963Representation)
    }

    public func signature(for message: [UInt8]) throws -> [UInt8] {
        Array(try key.signature(for: Data(message)).rawRepresentation)
    }
}
