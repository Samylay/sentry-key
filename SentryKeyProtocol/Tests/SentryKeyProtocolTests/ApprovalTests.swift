import Foundation
import Testing
@testable import SentryKeyProtocol

/// The captured login, split into the pieces the phone receives.
private enum Captured {
    static var bind: SessionBind {
        var message = WireReader(CapturedVectors.sessionBindMessage)
        let body = try! message.readString(maxLength: AgentLimits.maxMessageLength)
        guard case .sessionBind(let bind) = try! AgentRequest.parse(body: body) else { fatalError("not a session-bind") }
        return bind
    }

    static var sign: (keyBlob: [UInt8], data: [UInt8]) {
        var message = WireReader(CapturedVectors.signRequestMessage)
        let body = try! message.readString(maxLength: AgentLimits.maxMessageLength)
        guard case .sign(let keyBlob, let data, _) = try! AgentRequest.parse(body: body) else { fatalError("not a sign request") }
        return (keyBlob, data)
    }
}

@Suite("Fingerprints and public key lines")
struct FingerprintTests {
    /// SHA-256 of the captured host key blob (Python hashlib), and the
    /// fingerprint `ssh-keygen -lf` printed for that same host key.
    @Test func hostKeyFingerprintMatchesSSHKeygen() throws {
        let digest = hex("81209f39608dad9b167339dd87ad84a44b2b438642097786ae33f7349ed15bab")
        #expect(try SSHFingerprint.sha256String(digest: digest) == "SHA256:gSCfOWCNrZsWczndh62EpEsrQ4ZCCXeGrjP3NJ7RW6s")
    }

    @Test func testKeyFingerprintMatchesSSHKeygen() throws {
        let digest = hex("0835b32ef59e6b2b34eba6f73571be04078613c99c6fc8cf7dab392dd6f542f0")
        #expect(try SSHFingerprint.sha256String(digest: digest) == "SHA256:CDWzLvWeays066b3NXG+BAeGE8mcb8jPfas5Ldb1QvA")
    }

    @Test func wrongDigestLengthIsRejected() {
        #expect(throws: WireError.self) { try SSHFingerprint.sha256String(digest: [1, 2, 3]) }
    }

    /// The line `ssh-keygen -y` printed for the test key, plus a comment.
    @Test func authorizedKeysLineMatchesSSHKeygen() throws {
        let line = try OpenSSHPublicKey.line(keyBlob: CapturedVectors.keyBlob, comment: "sentrykey")
        #expect(line == "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBJtSrvnH7ayTCgdcdMa2U4GLGB5LI85QaKEbGyqoT46kmzVFoIRxGNFZkka/Ba1hPB9IQ7w8iVv6oNDZPZI83lI= sentrykey")
    }

    @Test(arguments: ["", "two words", "x\nssh-rsa AAAA", "command=\"sh\"", String(repeating: "a", count: 65)])
    func unsafeCommentIsRejected(comment: String) {
        #expect(throws: WireError.self) { try OpenSSHPublicKey.line(keyBlob: CapturedVectors.keyBlob, comment: comment) }
    }

    @Test func hostKeyAlgorithm() throws {
        #expect(try SSHFingerprint.algorithm(ofKeyBlob: Captured.bind.hostKey) == "ssh-ed25519")
    }
}

@Suite("Text shown in a prompt")
struct DisplayTextTests {
    @Test(arguments: ["git", "deploy", "Mon serveur", "élève", "サーバー"])
    func ordinaryTextIsSafe(text: String) {
        #expect(DisplayText.isSafe(text, maxLength: 40))
    }

    @Test(arguments: [
        "",
        "root\u{202E}yolped",   // right-to-left override
        "ro\u{200B}ot",         // zero-width space
        "root\nadmin",          // newline
        "root\u{0}",            // NUL
        "a\u{00A0}b",           // no-break space looks like a space
        String(repeating: "a", count: 41),
    ])
    func trickyTextIsRefused(text: String) {
        #expect(!DisplayText.isSafe(text, maxLength: 40))
    }
}

@Suite("Login approval checks")
struct LoginApprovalTests {
    private func check(keyBlob: [UInt8] = Captured.sign.keyBlob,
                       data: [UInt8] = Captured.sign.data,
                       bind: SessionBind? = Captured.bind) throws(ApprovalRefusal) -> LoginApproval {
        try LoginApprovalCheck.check(requestKeyBlob: keyBlob, data: data, bind: bind, ourKeyBlob: CapturedVectors.keyBlob)
    }

    @Test func realLoginIsAccepted() throws {
        let approval = try check()
        #expect(approval.userName == "tester")
        #expect(approval.hostKey == Captured.bind.hostKey)
        #expect(approval.hostKeyAlgorithm == "ssh-ed25519")
    }

    @Test func otherKeyIsRefused() {
        var other = CapturedVectors.keyBlob
        other[other.count - 1] ^= 1
        #expect(throws: ApprovalRefusal.wrongKey) { try check(keyBlob: other) }
    }

    @Test func gitCommitDataIsRefusedForNow() {
        let sshsig = Array("SSHSIG".utf8) + [0, 0, 0, 3] + Array("git".utf8)
        #expect(throws: ApprovalRefusal.notALogin) { try check(data: sshsig) }
    }

    @Test func missingSessionBindIsRefused() {
        #expect(throws: ApprovalRefusal.noSessionBind) { try check(bind: nil) }
    }

    @Test func forwardedSessionIsRefused() {
        let real = Captured.bind
        let forwarded = SessionBind(hostKey: real.hostKey, sessionID: real.sessionID,
                                    serverSignature: real.serverSignature, isForwarding: true)
        #expect(throws: ApprovalRefusal.forwardedSession) { try check(bind: forwarded) }
    }

    /// A Mac replaying a login from another session.
    @Test func otherSessionIsRefused() {
        let real = Captured.bind
        var sessionID = real.sessionID
        sessionID[0] ^= 1
        let other = SessionBind(hostKey: real.hostKey, sessionID: sessionID,
                                serverSignature: real.serverSignature, isForwarding: false)
        #expect(throws: ApprovalRefusal.sessionMismatch) { try check(bind: other) }
    }

    /// A Mac pairing a real login with another server's session-bind.
    @Test func otherHostKeyIsRefused() {
        let real = Captured.bind
        var hostKey = real.hostKey
        hostKey[hostKey.count - 1] ^= 1
        let other = SessionBind(hostKey: hostKey, sessionID: real.sessionID,
                                serverSignature: real.serverSignature, isForwarding: false)
        #expect(throws: ApprovalRefusal.hostKeyMismatch) { try check(bind: other) }
    }

    @Test func spoofedUserNameIsRefused() {
        let data = login(userName: "root\u{202E}yolped")
        #expect(throws: ApprovalRefusal.unsafeUserName) { try check(data: data) }
    }

    /// Rebuilds the captured login with another user name.
    private func login(userName: String) -> [UInt8] {
        let real = try! UserAuthSignedData.parse(Captured.sign.data)
        var writer = WireWriter()
        writer.writeString(real.sessionID)
        writer.writeByte(50)
        writer.writeString(userName)
        writer.writeString("ssh-connection")
        writer.writeString("publickey-hostbound-v00@openssh.com")
        writer.writeBool(true)
        writer.writeString(real.keyAlgorithm)
        writer.writeString(real.keyBlob)
        writer.writeString(real.serverHostKey!)
        return writer.bytes
    }
}

@Suite("Server names recorded on first use")
struct KnownHostsTests {
    private let fingerprint = "SHA256:gSCfOWCNrZsWczndh62EpEsrQ4ZCCXeGrjP3NJ7RW6s"

    @Test func remembersAndRenames() throws {
        var hosts = KnownHosts()
        #expect(hosts.name(forFingerprint: fingerprint) == nil)
        try hosts.remember(name: "  GitHub ", forFingerprint: fingerprint)
        #expect(hosts.name(forFingerprint: fingerprint) == "GitHub")
        try hosts.remember(name: "Work server", forFingerprint: fingerprint)
        #expect(hosts.name(forFingerprint: fingerprint) == "Work server")
        #expect(hosts.count == 1)
        hosts.forget(fingerprint: fingerprint)
        #expect(hosts.count == 0)
    }

    @Test(arguments: ["github.com", "SHA256:short", "MD5:" + String(repeating: "a", count: 43),
                      "SHA256:" + String(repeating: "-", count: 43)])
    func badFingerprintIsRefused(text: String) {
        var hosts = KnownHosts()
        #expect(throws: KnownHosts.Failure.invalidFingerprint) { try hosts.remember(name: "x", forFingerprint: text) }
    }

    @Test func invisibleCharactersInNameAreRefused() {
        var hosts = KnownHosts()
        #expect(throws: KnownHosts.Failure.invalidName) {
            try hosts.remember(name: "Git\u{200B}Hub", forFingerprint: fingerprint)
        }
    }

    @Test func survivesEncoding() throws {
        var hosts = KnownHosts()
        try hosts.remember(name: "GitHub", forFingerprint: fingerprint)
        let decoded = try JSONDecoder().decode(KnownHosts.self, from: JSONEncoder().encode(hosts))
        #expect(decoded == hosts)
    }
}

@Suite("Prompt rate limit")
struct PromptRateLimiterTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    /// Asks the limiter at `seconds` after `start`.
    private func ask(_ limiter: inout PromptRateLimiter, at seconds: Double) -> Bool {
        limiter.shouldPrompt(at: start.addingTimeInterval(seconds))
    }

    @Test func blocksAfterTheLimitThenRecovers() {
        var limiter = PromptRateLimiter(maxPrompts: 3, window: 60, cooldown: 120)
        let firstThree = [0.0, 1, 2].map { ask(&limiter, at: $0) }
        #expect(firstThree == [true, true, true])
        let fourth = ask(&limiter, at: 3)
        #expect(!fourth)
        // Still blocked during the cooldown, even though the window passed.
        let duringCooldown = ask(&limiter, at: 100)
        #expect(!duringCooldown)
        let afterCooldown = ask(&limiter, at: 124)
        #expect(afterCooldown)
    }

    @Test func slowPromptsAreNeverBlocked() {
        var limiter = PromptRateLimiter(maxPrompts: 3, window: 60, cooldown: 120)
        let answers = (0..<10).map { ask(&limiter, at: Double($0) * 30) }
        #expect(answers.allSatisfy { $0 })
    }
}
