import Testing
@testable import SentryKeyProtocol

@Suite("Data signed for an SSH login")
struct UserAuthTests {
    private var realSignedData: [UInt8] {
        var message = WireReader(CapturedVectors.signRequestMessage)
        var body = WireReader(try! message.readString(maxLength: AgentLimits.maxMessageLength))
        _ = try! body.readByte()
        _ = try! body.readString(maxLength: AgentLimits.maxKeyLength)
        return try! body.readString(maxLength: AgentLimits.maxDataLength)
    }

    private var realSessionBind: SessionBind {
        var message = WireReader(CapturedVectors.sessionBindMessage)
        let body = try! message.readString(maxLength: AgentLimits.maxMessageLength)
        guard case .sessionBind(let bind) = try! AgentRequest.parse(body: body) else { fatalError("not a session-bind") }
        return bind
    }

    @Test func parsesRealHostBoundLogin() throws {
        let parsed = try UserAuthSignedData.parse(realSignedData)
        #expect(parsed.userName == "tester")
        #expect(parsed.isHostBound)
        #expect(parsed.keyAlgorithm == "ecdsa-sha2-nistp256")
        #expect(parsed.keyBlob == CapturedVectors.keyBlob)
    }

    /// The check the phone makes in J4: the login it signs belongs to the
    /// session and the server that session-bind proved.
    @Test func realLoginMatchesItsSessionBind() throws {
        let parsed = try UserAuthSignedData.parse(realSignedData)
        #expect(parsed.sessionID == realSessionBind.sessionID)
        #expect(parsed.serverHostKey == realSessionBind.hostKey)
    }

    @Test func parsesPlainPublicKeyLogin() throws {
        let data = build(method: "publickey", hostKey: nil)
        let parsed = try UserAuthSignedData.parse(data)
        #expect(!parsed.isHostBound)
        #expect(parsed.serverHostKey == nil)
    }

    @Test func queryWithoutSignatureIsRejected() {
        #expect(throws: WireError.unexpectedValue("has-signature flag")) {
            try UserAuthSignedData.parse(build(method: "publickey", hostKey: nil, hasSignature: false))
        }
    }

    @Test func otherMethodIsRejected() {
        #expect(throws: WireError.unexpectedValue("authentication method")) {
            try UserAuthSignedData.parse(build(method: "password", hostKey: nil))
        }
    }

    @Test func hostBoundWithoutHostKeyIsRejected() {
        #expect(throws: WireError.truncated) {
            try UserAuthSignedData.parse(build(method: "publickey-hostbound-v00@openssh.com", hostKey: nil))
        }
    }

    @Test func plainLoginWithExtraFieldIsRejected() {
        #expect(throws: WireError.self) {
            try UserAuthSignedData.parse(build(method: "publickey", hostKey: [1, 2, 3]))
        }
    }

    @Test func gitCommitSignatureIsNotALogin() {
        // SSHSIG data starts with the magic "SSHSIG", not a session ID string.
        let sshsig = Array("SSHSIG".utf8) + [0, 0, 0, 3] + Array("git".utf8)
        #expect(throws: WireError.self) { try UserAuthSignedData.parse(sshsig) }
    }

    private func build(method: String, hostKey: [UInt8]?, hasSignature: Bool = true) -> [UInt8] {
        var writer = WireWriter()
        writer.writeString([UInt8](repeating: 7, count: 32))
        writer.writeByte(50)
        writer.writeString("tester")
        writer.writeString("ssh-connection")
        writer.writeString(method)
        writer.writeBool(hasSignature)
        writer.writeString("ecdsa-sha2-nistp256")
        writer.writeString(CapturedVectors.keyBlob)
        if let hostKey { writer.writeString(hostKey) }
        return writer.bytes
    }
}
