import SentryKeyProtocol

/// One connection from ssh to the agent: answers each ssh-agent message in
/// turn (ARCHITECTURE.md, SSHAgentServer).
///
/// The agent decides nothing about a login. It forwards the request and the
/// session-bind to the phone, which checks them and asks the user. The Mac
/// is the untrusted side: its own checks only spare the phone useless
/// requests and protect ssh from a wrong answer.
public actor AgentSession {
    private enum Binding {
        /// ssh sent no session-bind yet.
        case none
        case bound(SessionBind)
        /// A forwarded connection, or more than one session-bind. Agent
        /// forwarding is not supported: a remote host must not be able to
        /// ask for signatures through this Mac.
        case forwarded
    }

    private let keys: any PublicKeyStore
    private let queue: SigningQueue
    private let verifier: any SignatureVerifying
    private let report: @Sendable (AgentEvent) -> Void
    private var binding = Binding.none

    public init(
        keys: any PublicKeyStore,
        queue: SigningQueue,
        verifier: any SignatureVerifying,
        report: @escaping @Sendable (AgentEvent) -> Void = { _ in }
    ) {
        self.keys = keys
        self.queue = queue
        self.verifier = verifier
        self.report = report
    }

    /// Handles one message body (no length prefix) and returns the reply.
    /// Throws when the message is malformed: the caller closes the
    /// connection, since the stream can no longer be trusted.
    public func handle(body: [UInt8]) async throws -> AgentResponse {
        switch try AgentRequest.parse(body: body) {
        case .requestIdentities:
            return .identities(keys.identity().map { [$0] } ?? [])

        case .sessionBind(let bind):
            if case .none = binding, !bind.isForwarding {
                binding = .bound(bind)
            } else {
                binding = .forwarded
            }
            return .success

        case .sign(let keyBlob, let data, _):
            return await sign(keyBlob: keyBlob, data: data)

        case .unsupportedExtension, .unsupported:
            // Adding, removing or locking keys: the key lives on the phone.
            return .failure
        }
    }

    private func sign(keyBlob: [UInt8], data: [UInt8]) async -> AgentResponse {
        guard let identity = keys.identity(), keyBlob == identity.keyBlob else {
            report(.unknownKeyRequested)
            return .failure
        }
        let bind: SessionBind?
        switch binding {
        case .none: bind = nil
        case .bound(let stored): bind = stored
        case .forwarded:
            report(.forwardedRequestRefused)
            return .failure
        }

        switch await queue.sign(keyBlob: keyBlob, data: data, bind: bind) {
        case .signature(let blob):
            // ssh would send a wrong signature to the server and report a
            // confusing failure. Checking here also catches a link that
            // delivered an answer meant for something else.
            guard verifier.isValid(signatureBlob: blob, data: data, publicKeyBlob: identity.keyBlob) else {
                report(.invalidSignatureFromPhone)
                return .failure
            }
            report(.signed)
            return .signature(blob: blob)
        case .refused(let reason):
            report(.refusedByPhone(reason))
        case .timedOut:
            report(.timedOut)
        case .phoneUnreachable:
            report(.phoneUnreachable)
        case .queueFull:
            report(.queueFull)
        }
        // Never a key on disk as a fallback: failing is the secure outcome.
        return .failure
    }
}
