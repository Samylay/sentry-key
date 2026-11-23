import Testing
@testable import SentryKeyProtocol

/// Strips the uint32 length prefix, checking that it matches.
private func body(of message: [UInt8]) -> [UInt8] {
    var reader = WireReader(message)
    let body = try! reader.readString(maxLength: AgentLimits.maxMessageLength)
    precondition(reader.remaining == 0)
    return body
}

@Suite("ssh-agent messages")
struct AgentTests {
    @Test func parsesRealRequestIdentities() throws {
        #expect(try AgentRequest.parse(body: body(of: CapturedVectors.requestIdentitiesMessage)) == .requestIdentities)
    }

    @Test func parsesRealSessionBind() throws {
        guard case .sessionBind(let bind) = try AgentRequest.parse(body: body(of: CapturedVectors.sessionBindMessage)) else {
            Issue.record("expected session-bind")
            return
        }
        #expect(bind.sessionID.count == 32)
        #expect(bind.isForwarding == false)
        var hostKey = WireReader(bind.hostKey)
        #expect(try hostKey.readUTF8String(maxLength: 64) == "ssh-ed25519")
        var signature = WireReader(bind.serverSignature)
        #expect(try signature.readUTF8String(maxLength: 64) == "ssh-ed25519")
    }

    @Test func parsesRealSignRequest() throws {
        guard case .sign(let keyBlob, _, let flags) = try AgentRequest.parse(body: body(of: CapturedVectors.signRequestMessage)) else {
            Issue.record("expected a sign request")
            return
        }
        #expect(keyBlob == CapturedVectors.keyBlob)
        #expect(flags == 0)
    }

    @Test func identitiesAnswerMatchesWhatSSHAccepted() {
        let answer = AgentResponse.identities([AgentIdentity(keyBlob: CapturedVectors.keyBlob, comment: "sentrykey-test")])
        #expect(answer.encoded() == CapturedVectors.identitiesAnswerMessage)
    }

    /// Codes checked against a real OpenSSH 10.2 ssh-agent.
    @Test func failureAndSuccessEncodings() {
        #expect(AgentResponse.failure.encoded() == [0, 0, 0, 1, 5])
        #expect(AgentResponse.success.encoded() == [0, 0, 0, 1, 6])
        #expect(AgentResponse.identities([]).encoded() == [0, 0, 0, 5, 12, 0, 0, 0, 0])
    }

    @Test func unknownExtensionIsNotParsedFurther() throws {
        var writer = WireWriter()
        writer.writeByte(27)
        writer.writeString("query")
        writer.writeByte(0xFF) // garbage the agent must not look at
        #expect(try AgentRequest.parse(body: writer.bytes) == .unsupportedExtension(name: "query"))
    }

    @Test func otherTypesAreUnsupported() throws {
        #expect(try AgentRequest.parse(body: [17, 1, 2, 3]) == .unsupported(type: 17)) // add identity
        #expect(try AgentRequest.parse(body: [99]) == .unsupported(type: 99))
    }

    @Test func emptyBodyIsRejected() {
        #expect(throws: WireError.truncated) { try AgentRequest.parse(body: []) }
    }

    @Test func signRequestWithTrailingBytesIsRejected() {
        let tampered = body(of: CapturedVectors.signRequestMessage) + [0]
        #expect(throws: WireError.trailingBytes(1)) { try AgentRequest.parse(body: tampered) }
    }

    @Test func truncatedSessionBindIsRejected() {
        let full = body(of: CapturedVectors.sessionBindMessage)
        #expect(throws: WireError.truncated) { try AgentRequest.parse(body: Array(full.dropLast())) }
    }

    @Test func requestIdentitiesWithContentsIsRejected() {
        #expect(throws: WireError.trailingBytes(1)) { try AgentRequest.parse(body: [11, 0]) }
    }

    @Test func oversizedBodyIsRejected() {
        let huge = [UInt8](repeating: 0, count: AgentLimits.maxMessageLength + 1)
        #expect(throws: WireError.lengthTooLarge(huge.count)) { try AgentRequest.parse(body: huge) }
    }
}
