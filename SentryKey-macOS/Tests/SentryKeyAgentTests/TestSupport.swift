import Foundation
import os
import SentryKeyAgent
import SentryKeyProtocol

/// A link that records what the queue sends. It can also fail, or answer
/// from inside `send`.
actor RecordingLink: PhoneLink {
    struct Down: Error {}

    private(set) var sent: [PhoneRequest] = []
    private var isDown = false
    private var answer: (@Sendable (PhoneRequest) async -> Void)?
    private nonisolated let sentRequests: AsyncStream<PhoneRequest>
    private let record: AsyncStream<PhoneRequest>.Continuation

    init() {
        (sentRequests, record) = AsyncStream.makeStream()
    }

    func goDown() {
        isDown = true
    }

    /// Runs `handler` during each `send`, before it returns.
    func answerInsideSend(_ handler: @escaping @Sendable (PhoneRequest) async -> Void) {
        answer = handler
    }

    func send(_ request: PhoneRequest) async throws {
        if isDown { throw Down() }
        sent.append(request)
        await answer?(request)
        record.yield(request)
    }

    /// Waits for the next sign request the queue sends, skipping cancels.
    nonisolated func nextSign() async -> PhoneRequest? {
        for await request in sentRequests {
            if case .sign = request { return request }
        }
        return nil
    }

    /// Waits for the next cancel the queue sends.
    nonisolated func nextCancel() async -> PhoneRequest? {
        for await request in sentRequests {
            if case .cancel = request { return request }
        }
        return nil
    }
}

/// A timeout the test fires by hand, so no test waits on a real clock.
struct ManualTimeout: Sendable {
    private let fired: AsyncStream<Void>
    private let trigger: AsyncStream<Void>.Continuation

    init() {
        (fired, trigger) = AsyncStream.makeStream()
    }

    var wait: @Sendable () async -> Void {
        { [fired] in
            for await _ in fired { return }
        }
    }

    func fire() {
        trigger.yield()
    }
}

/// Collects the events a session reports.
final class EventLog: Sendable {
    private let events = OSAllocatedUnfairLock<[AgentEvent]>(initialState: [])

    var all: [AgentEvent] { events.withLock { $0 } }

    var report: @Sendable (AgentEvent) -> Void {
        { [events] event in events.withLock { $0.append(event) } }
    }
}

/// Lets other tasks run until `condition` holds. Gives up after a fixed
/// number of turns rather than after a delay.
func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<100_000 {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}

/// ssh-agent request bodies, as ssh would send them (no length prefix).
enum AgentRequestBody {
    static let requestIdentities: [UInt8] = [AgentMessageType.requestIdentities.rawValue]

    static func sign(keyBlob: [UInt8], data: [UInt8]) -> [UInt8] {
        var writer = WireWriter()
        writer.writeByte(AgentMessageType.signRequest.rawValue)
        writer.writeString(keyBlob)
        writer.writeString(data)
        writer.writeUInt32(0)
        return writer.bytes
    }

    static func sessionBind(_ bind: SessionBind) -> [UInt8] {
        var writer = WireWriter()
        writer.writeByte(AgentMessageType.extension.rawValue)
        writer.writeString(AgentRequest.sessionBindName)
        writer.writeString(bind.hostKey)
        writer.writeString(bind.sessionID)
        writer.writeString(bind.serverSignature)
        writer.writeBool(bind.isForwarding)
        return writer.bytes
    }

    static func unknownExtension(named name: String) -> [UInt8] {
        var writer = WireWriter()
        writer.writeByte(AgentMessageType.extension.rawValue)
        writer.writeString(name)
        return writer.bytes
    }
}

func id(_ rawValue: UInt32) -> RequestID {
    RequestID(rawValue: rawValue)
}
