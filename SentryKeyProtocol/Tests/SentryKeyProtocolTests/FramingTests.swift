import Testing
@testable import SentryKeyProtocol

@Suite("Length-prefixed framing")
struct FramingTests {
    private let message: [UInt8] = (0..<300).map { UInt8($0 % 251) }

    @Test(arguments: [1, 7, 20, 182, 303, 304, 1000])
    func chunksReassembleToTheMessage(chunkSize: Int) throws {
        let chunks = try Framing.chunks(for: message, chunkSize: chunkSize, maxMessageLength: 1024)
        #expect(chunks.allSatisfy { $0.count <= chunkSize })
        var reassembler = Reassembler(maxMessageLength: 1024)
        var received: [[UInt8]] = []
        for chunk in chunks {
            received += try reassembler.append(chunk)
        }
        #expect(received == [message])
        #expect(reassembler.pendingByteCount == 0)
    }

    @Test func severalMessagesInOneRead() throws {
        let a = try Framing.chunks(for: [1, 2], chunkSize: 100, maxMessageLength: 10)[0]
        let b = try Framing.chunks(for: [3], chunkSize: 100, maxMessageLength: 10)[0]
        var reassembler = Reassembler(maxMessageLength: 10)
        #expect(try reassembler.append(a + b + [0, 0]) == [[1, 2], [3]])
        #expect(reassembler.pendingByteCount == 2)
    }

    @Test func realAgentMessageThroughTheReassembler() throws {
        var reassembler = Reassembler(maxMessageLength: AgentLimits.maxMessageLength)
        let bodies = try reassembler.append(CapturedVectors.signRequestMessage)
        #expect(bodies.count == 1)
        #expect(try AgentRequest.parse(body: bodies[0]) != .requestIdentities)
    }

    @Test func zeroLengthIsRejected() {
        var reassembler = Reassembler(maxMessageLength: 10)
        #expect(throws: FramingError.emptyMessage) { try reassembler.append([0, 0, 0, 0]) }
    }

    @Test func oversizedLengthIsRejectedBeforeTheBodyArrives() {
        var reassembler = Reassembler(maxMessageLength: 10)
        #expect(throws: FramingError.messageTooLarge(11)) { try reassembler.append([0, 0, 0, 11]) }
    }

    @Test func sendingLimitsAreChecked() {
        #expect(throws: FramingError.invalidChunkSize(0)) { try Framing.chunks(for: [1], chunkSize: 0, maxMessageLength: 10) }
        #expect(throws: FramingError.emptyMessage) { try Framing.chunks(for: [], chunkSize: 5, maxMessageLength: 10) }
        #expect(throws: FramingError.messageTooLarge(11)) {
            try Framing.chunks(for: [UInt8](repeating: 0, count: 11), chunkSize: 5, maxMessageLength: 10)
        }
    }
}
