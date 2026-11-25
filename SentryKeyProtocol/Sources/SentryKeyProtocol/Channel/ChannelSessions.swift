#if canImport(CryptoKit)
import Foundation

// One connection seen from each side: the handshake, then sign requests and
// their answers inside the secure channel.
//
// These types do no input or output. They take the messages received and
// return the messages to send, so the same code serves Bluetooth on the
// devices and an in-memory connection in tests.
//
// NEEDS LINE-BY-LINE HUMAN REVIEW (security code).

/// The Mac's end of one connection to the phone.
public struct MacChannelSession {
    private enum State {
        case waitingForAnswer(MacHandshake)
        case open(SecureChannel)
        case closed
    }

    /// The first message to send to the phone.
    public let hello: [UInt8]
    private var state: State

    public init(identity: any IdentitySigner, phoneIdentityKey: [UInt8], now: Date) throws {
        let handshake = try MacHandshake(identity: identity, phoneIdentityKey: phoneIdentityKey, now: now)
        hello = handshake.hello.encoded()
        state = .waitingForAnswer(handshake)
    }

    /// True once the phone's answer has been checked.
    public var isOpen: Bool {
        if case .open = state { return true }
        return false
    }

    /// Handles one message from the phone. Returns nil for the handshake
    /// answer, which only opens the channel, and a response afterwards.
    /// After any error the session is closed: drop the connection.
    public mutating func receive(_ message: [UInt8], now: Date) throws(ChannelError) -> PhoneResponse? {
        switch state {
        case .waitingForAnswer(let handshake):
            state = .closed
            guard let answer = try? PhoneHello.parse(body: message) else { throw .malformed }
            state = .open(try handshake.finish(with: answer))
            return nil

        case .open(var channel):
            state = .closed
            let body = try channel.open(message, now: now)
            guard let response = try? PhoneResponse.parse(body: body) else { throw .malformed }
            state = .open(channel)
            return response

        case .closed:
            throw .closed
        }
    }

    /// Encrypts a request for the phone. Only once the session is open.
    public mutating func seal(_ request: PhoneRequest, now: Date) throws(ChannelError) -> [UInt8] {
        try sealBody(request.encoded(), now: now)
    }

    /// Not public: the Mac only ever sends requests. Tests use it to send
    /// the phone something else under valid encryption.
    mutating func sealBody(_ body: [UInt8], now: Date) throws(ChannelError) -> [UInt8] {
        guard case .open(var channel) = state else { throw .closed }
        state = .closed
        let sealed = try channel.seal(body, now: now)
        state = .open(channel)
        return sealed
    }
}

/// The phone's end of one connection from a Mac.
public struct PhoneChannelSession {
    private enum State {
        case waitingForHello
        case open(SecureChannel)
        case closed
    }

    public enum Incoming: Equatable {
        /// The Mac's hello was accepted: send this answer back.
        case handshakeAnswer([UInt8])
        case request(PhoneRequest)
    }

    /// Which paired Mac this connection comes from, once it has proved it.
    public private(set) var macFingerprint: [UInt8]?

    private let identity: any IdentitySigner
    private let pairedMacKey: @Sendable ([UInt8]) -> [UInt8]?
    private var state = State.waitingForHello

    /// - Parameter pairedMacKey: the identity public key of the paired Mac
    ///   with this fingerprint, or nil if there is none.
    public init(identity: any IdentitySigner, pairedMacKey: @escaping @Sendable ([UInt8]) -> [UInt8]?) {
        self.identity = identity
        self.pairedMacKey = pairedMacKey
    }

    /// Handles one message from the Mac. After any error the session is
    /// closed: drop the connection.
    public mutating func receive(_ message: [UInt8], now: Date) throws(ChannelError) -> Incoming {
        switch state {
        case .waitingForHello:
            state = .closed
            guard let hello = try? MacHello.parse(body: message) else { throw .malformed }
            let accepted = try PhoneHandshake.accept(
                hello, identity: identity, pairedMacKey: pairedMacKey, now: now
            )
            macFingerprint = accepted.macFingerprint
            state = .open(accepted.channel)
            return .handshakeAnswer(accepted.answer.encoded())

        case .open(var channel):
            state = .closed
            let body = try channel.open(message, now: now)
            guard let request = try? PhoneRequest.parse(body: body) else { throw .malformed }
            state = .open(channel)
            return .request(request)

        case .closed:
            throw .closed
        }
    }

    /// Encrypts an answer for the Mac. Only once the session is open.
    public mutating func seal(_ response: PhoneResponse, now: Date) throws(ChannelError) -> [UInt8] {
        guard case .open(var channel) = state else { throw .closed }
        state = .closed
        let sealed = try channel.seal(response.encoded(), now: now)
        state = .open(channel)
        return sealed
    }
}
#endif
