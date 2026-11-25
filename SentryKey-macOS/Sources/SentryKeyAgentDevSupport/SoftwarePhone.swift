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
public actor SoftwarePhone: PhoneLink {
    public enum Behaviour: Sendable {
        case approve
        case deny
        /// The phone is reachable but the user never answers.
        case neverAnswer
        /// Answers with a signature from another key.
        case signWithAnotherKey
        /// The phone cannot be reached at all.
        case unreachable
    }

    public struct Unreachable: Error {}

    /// The stand-in's SSH public key blob, to install on the test server.
    public nonisolated let publicKeyBlob: [UInt8]
    /// Answers to pass to `SigningQueue.deliver`.
    public nonisolated let responses: AsyncStream<PhoneResponse>

    // The secret scanner takes the type name on this line for a secret.
    private let standInKey: P256.Signing.PrivateKey // gitleaks:allow
    private let behaviour: Behaviour
    private let onApproval: @Sendable (LoginApproval) -> Void
    private let answer: AsyncStream<PhoneResponse>.Continuation

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
        // The queue sends one request at a time, so answers never pile up.
        (responses, answer) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(4))
    }

    public func send(_ request: PhoneRequest) async throws {
        if case .unreachable = behaviour { throw Unreachable() }
        guard case .sign(let id, let keyBlob, let data, let bind) = request else { return }

        let approval: LoginApproval
        do {
            approval = try LoginApprovalCheck.check(
                requestKeyBlob: keyBlob, data: data, bind: bind, ourKeyBlob: publicKeyBlob
            )
        } catch {
            answer.yield(PhoneResponse(id: id, outcome: .refused(.invalidRequest)))
            return
        }
        // `LoginApprovalCheck` guarantees `bind` exists.
        guard let bind, Self.serverSigned(bind) else {
            answer.yield(PhoneResponse(id: id, outcome: .refused(.invalidRequest)))
            return
        }

        switch behaviour {
        case .approve:
            onApproval(approval)
            answer.yield(PhoneResponse(id: id, outcome: try signature(over: data, with: standInKey)))
        case .signWithAnotherKey:
            answer.yield(PhoneResponse(id: id, outcome: try signature(over: data, with: P256.Signing.PrivateKey())))
        case .deny:
            answer.yield(PhoneResponse(id: id, outcome: .refused(.deniedByUser)))
        case .neverAnswer, .unreachable:
            break
        }
    }

    private func signature(over data: [UInt8], with key: P256.Signing.PrivateKey) throws -> PhoneResponse.Outcome {
        let raw = try key.signature(for: Data(data)).rawRepresentation
        return .signature(blob: try ECDSAP256.signatureBlob(rawSignature: Array(raw)))
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
