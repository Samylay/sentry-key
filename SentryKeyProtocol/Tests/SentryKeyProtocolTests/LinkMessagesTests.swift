import Testing
@testable import SentryKeyProtocol

private let sampleBind = SessionBind(
    hostKey: [1, 2, 3],
    sessionID: Array(repeating: 7, count: 32),
    serverSignature: [4, 5, 6, 7],
    isForwarding: false
)

private let sampleSign = PhoneRequest.sign(
    id: RequestID(rawValue: 42),
    keyBlob: [9, 9],
    data: [1, 2, 3, 4, 5],
    bind: sampleBind
)

@Suite("Mac to phone link messages")
struct LinkMessagesTests {
    @Test func signRequestSurvivesEncoding() throws {
        #expect(try PhoneRequest.parse(body: sampleSign.encoded()) == sampleSign)
    }

    @Test func signRequestWithoutSessionBindSurvivesEncoding() throws {
        let request = PhoneRequest.sign(id: RequestID(rawValue: 0), keyBlob: [1], data: [2], bind: nil)
        #expect(try PhoneRequest.parse(body: request.encoded()) == request)
    }

    @Test func forwardingFlagIsKept() throws {
        let forwarded = SessionBind(hostKey: [1], sessionID: [2], serverSignature: [3], isForwarding: true)
        let request = PhoneRequest.sign(id: RequestID(rawValue: 1), keyBlob: [1], data: [2], bind: forwarded)
        guard case .sign(_, _, _, let bind) = try PhoneRequest.parse(body: request.encoded()) else {
            Issue.record("expected a sign request")
            return
        }
        #expect(bind?.isForwarding == true)
    }

    @Test func cancelSurvivesEncoding() throws {
        let cancel = PhoneRequest.cancel(id: RequestID(rawValue: .max))
        #expect(try PhoneRequest.parse(body: cancel.encoded()) == cancel)
        #expect(cancel.id == RequestID(rawValue: .max))
    }

    @Test func signatureResponseSurvivesEncoding() throws {
        let response = PhoneResponse(id: RequestID(rawValue: 42), outcome: .signature(blob: [1, 2, 3]))
        #expect(try PhoneResponse.parse(body: response.encoded()) == response)
    }

    @Test(arguments: RefusalReason.allCases)
    func refusalSurvivesEncoding(reason: RefusalReason) throws {
        let response = PhoneResponse(id: RequestID(rawValue: 7), outcome: .refused(reason))
        #expect(try PhoneResponse.parse(body: response.encoded()) == response)
    }

    @Test func requestWithTrailingBytesIsRejected() {
        #expect(throws: WireError.trailingBytes(1)) {
            try PhoneRequest.parse(body: sampleSign.encoded() + [0])
        }
    }

    @Test func responseWithTrailingBytesIsRejected() {
        let response = PhoneResponse(id: RequestID(rawValue: 1), outcome: .refused(.busy))
        #expect(throws: WireError.trailingBytes(2)) {
            try PhoneResponse.parse(body: response.encoded() + [0, 0])
        }
    }

    @Test func everyTruncationOfARequestIsRejected() {
        let full = sampleSign.encoded()
        for length in 0..<full.count {
            #expect(throws: WireError.self) {
                try PhoneRequest.parse(body: Array(full.prefix(length)))
            }
        }
    }

    @Test func everyTruncationOfAResponseIsRejected() {
        let full = PhoneResponse(id: RequestID(rawValue: 1), outcome: .signature(blob: [1, 2, 3])).encoded()
        for length in 0..<full.count {
            #expect(throws: WireError.self) {
                try PhoneResponse.parse(body: Array(full.prefix(length)))
            }
        }
    }

    @Test func unknownMessageTypesAreRejected() {
        #expect(throws: WireError.unexpectedValue("phone request type 99")) {
            try PhoneRequest.parse(body: [99, 0, 0, 0, 1])
        }
        #expect(throws: WireError.unexpectedValue("phone response type 0")) {
            try PhoneResponse.parse(body: [0, 0, 0, 0, 1])
        }
    }

    @Test func unknownRefusalReasonIsRejected() {
        #expect(throws: WireError.unexpectedValue("refusal reason 200")) {
            try PhoneResponse.parse(body: [2, 0, 0, 0, 1, 200])
        }
    }

    @Test func sessionBindPresenceMustBeZeroOrOne() {
        var writer = WireWriter()
        writer.writeByte(1)
        writer.writeUInt32(1)
        writer.writeString([1] as [UInt8])
        writer.writeString([2] as [UInt8])
        writer.writeByte(2)
        #expect(throws: WireError.invalidBoolean(2)) {
            try PhoneRequest.parse(body: writer.bytes)
        }
    }

    @Test func oversizedFieldsAreRejected() {
        let data = [UInt8](repeating: 0, count: AgentLimits.maxDataLength + 1)
        let tooMuchData = PhoneRequest.sign(id: RequestID(rawValue: 1), keyBlob: [1], data: data, bind: nil)
        #expect(throws: WireError.lengthTooLarge(AgentLimits.maxDataLength + 1)) {
            try PhoneRequest.parse(body: tooMuchData.encoded())
        }

        let longSessionID = SessionBind(
            hostKey: [1],
            sessionID: [UInt8](repeating: 0, count: AgentLimits.maxSessionIDLength + 1),
            serverSignature: [1],
            isForwarding: false
        )
        let badBind = PhoneRequest.sign(id: RequestID(rawValue: 1), keyBlob: [1], data: [1], bind: longSessionID)
        #expect(throws: WireError.lengthTooLarge(AgentLimits.maxSessionIDLength + 1)) {
            try PhoneRequest.parse(body: badBind.encoded())
        }

        let blob = [UInt8](repeating: 0, count: AgentLimits.maxKeyLength + 1)
        let bigSignature = PhoneResponse(id: RequestID(rawValue: 1), outcome: .signature(blob: blob))
        #expect(throws: WireError.lengthTooLarge(AgentLimits.maxKeyLength + 1)) {
            try PhoneResponse.parse(body: bigSignature.encoded())
        }
    }

    @Test func encodedRequestFitsTheFramingLimit() throws {
        let chunks = try Framing.chunks(
            for: sampleSign.encoded(), chunkSize: 20, maxMessageLength: AgentLimits.maxMessageLength
        )
        var reassembler = Reassembler(maxMessageLength: AgentLimits.maxMessageLength)
        var bodies: [[UInt8]] = []
        for chunk in chunks {
            bodies += try reassembler.append(chunk)
        }
        #expect(bodies.count == 1)
        #expect(try PhoneRequest.parse(body: bodies[0]) == sampleSign)
    }
}
