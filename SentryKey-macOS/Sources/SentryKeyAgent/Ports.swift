import SentryKeyProtocol

/// The way to the phone. The Bluetooth central implements it; tests and the
/// development agent use a stand-in.
///
/// Answers do not come back through this protocol: whoever owns the link
/// passes each `PhoneResponse` it receives to `SigningQueue.deliver`.
public protocol PhoneLink: Sendable {
    /// Sends one request. Throws when the phone cannot be reached. An
    /// implementation must give up by itself rather than wait forever:
    /// the queue's timeout only starts once this call has returned.
    func send(_ request: PhoneRequest) async throws
}

/// One open connection to the phone, carrying whole messages in order.
/// Bluetooth on the real agent, an in-memory connection in development.
///
/// It gives no security by itself: `SecurePhoneLink` runs the handshake and
/// the encryption on top of it.
public protocol PhoneConnection: Sendable {
    func send(_ message: [UInt8]) async throws
    /// Waits for the next message from the phone. Throws when the
    /// connection is lost, and when the calling task is cancelled: a call
    /// that ignored cancellation would make a timeout wait forever.
    func receive() async throws -> [UInt8]
    func close() async
}

/// Opens connections to the paired phone.
public protocol PhoneConnector: Sendable {
    /// Throws when the phone cannot be reached.
    func connect() async throws -> any PhoneConnection
}

/// The phone's SSH public key, recorded at pairing.
public protocol PublicKeyStore: Sendable {
    /// The key offered to ssh, or nil when no phone is paired.
    func identity() -> AgentIdentity?
}

/// Checks a signature the phone returned before ssh sees it.
public protocol SignatureVerifying: Sendable {
    func isValid(signatureBlob: [UInt8], data: [UInt8], publicKeyBlob: [UInt8]) -> Bool
}

/// What happened to a sign request, for the menu bar and for the logs.
///
/// Events carry no host name, user name or key material: CLAUDE.md forbids
/// them in logs.
public enum AgentEvent: Equatable, Sendable {
    case signed
    case refusedByPhone(RefusalReason)
    case timedOut
    case phoneUnreachable
    case queueFull
    /// ssh went away (Ctrl-C) before the phone answered.
    case cancelledByClient
    /// The phone answered with a signature that does not verify.
    case invalidSignatureFromPhone
    /// ssh asked for a key that is not the paired phone's.
    case unknownKeyRequested
    /// The request came through a forwarded agent connection.
    case forwardedRequestRefused
}

/// A fixed key, for the development agent and for tests. The real store
/// reads the key recorded at pairing.
public struct FixedPublicKeyStore: PublicKeyStore {
    private let stored: AgentIdentity?

    public init(identity: AgentIdentity?) {
        self.stored = identity
    }

    public func identity() -> AgentIdentity? {
        stored
    }
}
