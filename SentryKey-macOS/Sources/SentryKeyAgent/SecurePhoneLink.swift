import Foundation
import SentryKeyProtocol

public enum PhoneLinkError: Error, Equatable {
    /// The phone accepted the connection but did not answer the handshake.
    case handshakeTimedOut
    case connectionLost
}

/// Reaches the phone through the secure channel: opens a connection, runs
/// the handshake, then encrypts each request and decrypts each answer
/// (ARCHITECTURE.md, Channel).
///
/// A connection is opened when a request needs one and kept for the next
/// requests. After any error it is dropped, and the next request starts
/// again with a new handshake and new keys.
///
/// NEEDS LINE-BY-LINE HUMAN REVIEW (security code).
public actor SecurePhoneLink: PhoneLink {
    public static let defaultHandshakeTime: Duration = .seconds(10)

    private struct OpenConnection {
        let connection: any PhoneConnection
        var session: MacChannelSession
        let reader: Task<Void, Never>
        /// Tells this connection apart from an earlier one that a reader
        /// task may still be finishing.
        let number: Int
        /// Sign requests sent on this connection and not answered yet. If
        /// the connection ends, their answer can never come.
        var unanswered: Set<RequestID> = []
    }

    /// Answers from the phone, to pass to `SigningQueue.deliver`.
    public nonisolated let responses: AsyncStream<PhoneResponse>
    private let answers: AsyncStream<PhoneResponse>.Continuation
    /// Requests whose connection ended before the phone answered, to pass
    /// to `SigningQueue.requestLost`. `SigningQueue.listen(to:)` does both.
    public nonisolated let lostRequests: AsyncStream<RequestID>
    private let losses: AsyncStream<RequestID>.Continuation

    private let identity: any IdentitySigner
    private let phoneIdentityKey: [UInt8]
    private let connector: any PhoneConnector
    private let now: @Sendable () -> Date
    private let waitForHandshakeTimeout: @Sendable () async -> Void

    private var open: OpenConnection?
    private var connectionCount = 0
    private var isSending = false
    private var waitingSenders: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - identity: the Mac identity key.
    ///   - phoneIdentityKey: the phone's identity public key, from pairing.
    ///   - waitForHandshakeTimeout: returns when the phone has had long
    ///     enough to answer the handshake. Injected so tests do not sleep.
    public init(
        identity: any IdentitySigner,
        phoneIdentityKey: [UInt8],
        connector: any PhoneConnector,
        now: @escaping @Sendable () -> Date = { Date() },
        waitForHandshakeTimeout: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(for: SecurePhoneLink.defaultHandshakeTime)
        }
    ) {
        self.identity = identity
        self.phoneIdentityKey = phoneIdentityKey
        self.connector = connector
        self.now = now
        self.waitForHandshakeTimeout = waitForHandshakeTimeout
        // The queue sends one sign request at a time, so answers never pile up.
        (responses, answers) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(4))
        (lostRequests, losses) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(4))
    }

    public func send(_ request: PhoneRequest) async throws {
        // One send at a time: two sealed messages reaching the phone in the
        // wrong order would break the counter and close the channel.
        await takeTurn()
        defer { passTurn() }

        if case .cancel = request, open == nil {
            // Nothing to cancel on a phone we are not connected to.
            return
        }
        if open != nil {
            do {
                try await sendOnOpenConnection(request)
                return
            } catch {
                // The connection may have died since its last use: try once
                // more on a new one.
                await dropConnection()
            }
        }
        try await connect()
        do {
            try await sendOnOpenConnection(request)
        } catch {
            await dropConnection()
            throw error
        }
    }

    private func sendOnOpenConnection(_ request: PhoneRequest) async throws {
        guard var current = open else { throw PhoneLinkError.connectionLost }
        let sealed = try current.session.seal(request, now: now())
        // Recorded before sending: the counter has moved, whatever happens
        // next, and the connection may end while the send is under way.
        switch request {
        case .sign(let id, _, _, _): current.unanswered.insert(id)
        case .cancel(let id): current.unanswered.remove(id)
        }
        open = current
        do {
            try await current.connection.send(sealed)
        } catch {
            // Not delivered: `send` retries it on a new connection, so it
            // is not lost with this one.
            if case .sign(let id, _, _, _) = request, open?.number == current.number {
                open?.unanswered.remove(id)
            }
            throw error
        }
    }

    private func connect() async throws {
        var session = try MacChannelSession(identity: identity, phoneIdentityKey: phoneIdentityKey, now: now())
        let connection = try await connector.connect()
        do {
            try await connection.send(session.hello)
            let answer = try await receiveHandshakeAnswer(from: connection)
            _ = try session.receive(answer, now: now())
        } catch {
            await connection.close()
            throw error
        }

        connectionCount += 1
        let number = connectionCount
        let reader = Task {
            while let message = try? await connection.receive() {
                guard handle(message, onConnection: number) else { break }
            }
            await connectionEnded(number)
        }
        open = OpenConnection(connection: connection, session: session, reader: reader, number: number)
    }

    private func receiveHandshakeAnswer(from connection: any PhoneConnection) async throws -> [UInt8] {
        try await withThrowingTaskGroup(of: [UInt8].self) { group in
            group.addTask { try await connection.receive() }
            group.addTask { [waitForHandshakeTimeout] in
                await waitForHandshakeTimeout()
                throw PhoneLinkError.handshakeTimedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw PhoneLinkError.connectionLost }
            return first
        }
    }

    /// Decrypts one message from the phone. Returns false when the
    /// connection must be dropped.
    private func handle(_ message: [UInt8], onConnection number: Int) -> Bool {
        guard var current = open, current.number == number else { return false }
        do {
            let response = try current.session.receive(message, now: now())
            if let response {
                current.unanswered.remove(response.id)
                answers.yield(response)
            }
            open = current
            return true
        } catch {
            return false
        }
    }

    /// Closes the open connection, if any. The next request starts a new
    /// one with a new handshake.
    public func close() async {
        await takeTurn()
        defer { passTurn() }
        await dropConnection()
    }

    private func connectionEnded(_ number: Int) async {
        guard let current = open, current.number == number else { return }
        open = nil
        reportLost(current)
        await current.connection.close()
    }

    private func dropConnection() async {
        guard let current = open else { return }
        open = nil
        reportLost(current)
        current.reader.cancel()
        await current.connection.close()
    }

    /// The phone can no longer answer these: the queue fails them now
    /// instead of waiting for its timeout.
    private func reportLost(_ connection: OpenConnection) {
        for id in connection.unanswered { losses.yield(id) }
    }

    private func takeTurn() async {
        guard isSending else {
            isSending = true
            return
        }
        await withCheckedContinuation { waitingSenders.append($0) }
    }

    private func passTurn() {
        if waitingSenders.isEmpty {
            isSending = false
        } else {
            waitingSenders.removeFirst().resume()
        }
    }
}
