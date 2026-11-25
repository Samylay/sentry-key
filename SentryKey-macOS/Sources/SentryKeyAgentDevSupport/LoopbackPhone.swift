import Foundation
import os
import SentryKeyAgent
import SentryKeyProtocol

/// Connects the agent to a phone that lives in the same process, in place of
/// Bluetooth. Nothing else is skipped: each connection runs the real
/// handshake and every message is sealed by the real channel, on the phone's
/// side with `PhoneChannelSession`, the type the iPhone app will use.
///
/// DEVELOPMENT AND TESTS ONLY.
public final class LoopbackPhoneConnector: PhoneConnector {
    public struct Unreachable: Error {}

    private struct State {
        var isReachable = true
        var connectionCount = 0
        var connections: [LoopbackPhoneConnection] = []
    }

    private let phoneIdentity: any IdentitySigner
    private let pairedMacKey: @Sendable ([UInt8]) -> [UInt8]?
    private let answer: @Sendable (PhoneRequest) async -> PhoneResponse?
    private let now: @Sendable () -> Date
    /// Shared by every connection, as on the real phone.
    private let recentHellos = RecentHelloNonces()
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// - Parameters:
    ///   - pairedMacKey: the Macs this phone is paired with, by fingerprint.
    ///   - answer: what the phone does with a request. Nil means silence.
    public init(
        phoneIdentity: any IdentitySigner,
        pairedMacKey: @escaping @Sendable ([UInt8]) -> [UInt8]?,
        now: @escaping @Sendable () -> Date = { Date() },
        answer: @escaping @Sendable (PhoneRequest) async -> PhoneResponse?
    ) {
        self.phoneIdentity = phoneIdentity
        self.pairedMacKey = pairedMacKey
        self.now = now
        self.answer = answer
    }

    /// How many connections were opened so far.
    public var connectionCount: Int { state.withLock { $0.connectionCount } }

    /// Makes the phone unreachable, or reachable again.
    public func setReachable(_ isReachable: Bool) {
        state.withLock { $0.isReachable = isReachable }
    }

    /// Cuts every open connection, as when the phone goes out of range.
    public func dropConnections() async {
        let connections = state.withLock { state -> [LoopbackPhoneConnection] in
            defer { state.connections = [] }
            return state.connections
        }
        for connection in connections {
            await connection.close()
        }
    }

    public func connect() async throws -> any PhoneConnection {
        let connection = LoopbackPhoneConnection(
            session: PhoneChannelSession(
                identity: phoneIdentity, pairedMacKey: pairedMacKey, recentHellos: recentHellos
            ),
            now: now, answer: answer
        )
        let isReachable = state.withLock { state -> Bool in
            guard state.isReachable else { return false }
            state.connectionCount += 1
            state.connections.append(connection)
            return true
        }
        guard isReachable else { throw Unreachable() }
        return connection
    }
}

/// One in-memory connection: what the Mac sends is handled by the phone's
/// session at once, and what the phone sends waits to be received.
actor LoopbackPhoneConnection: PhoneConnection {
    private var session: PhoneChannelSession
    private let now: @Sendable () -> Date
    private let answer: @Sendable (PhoneRequest) async -> PhoneResponse?
    private nonisolated let toMac: AsyncStream<[UInt8]>
    private let fromPhone: AsyncStream<[UInt8]>.Continuation
    private var isClosed = false

    init(
        session: PhoneChannelSession,
        now: @escaping @Sendable () -> Date,
        answer: @escaping @Sendable (PhoneRequest) async -> PhoneResponse?
    ) {
        self.session = session
        self.now = now
        self.answer = answer
        (toMac, fromPhone) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
    }

    func send(_ message: [UInt8]) async throws {
        // A dead connection must fail loudly, or the Mac would wait for
        // an answer that cannot come.
        guard !isClosed else { throw PhoneLinkError.connectionLost }
        do {
            switch try session.receive(message, now: now()) {
            case .handshakeAnswer(let hello):
                fromPhone.yield(hello)
            case .request(let request):
                guard let response = await answer(request) else { return }
                fromPhone.yield(try session.seal(response, now: now()))
            }
        } catch {
            // A phone that refuses a message drops the connection and says
            // nothing: the Mac only sees the connection end.
            close()
        }
    }

    nonisolated func receive() async throws -> [UInt8] {
        for await message in toMac {
            return message
        }
        throw PhoneLinkError.connectionLost
    }

    func close() {
        isClosed = true
        fromPhone.finish()
    }
}
