#if canImport(CryptoKit)
import CryptoKit
import Foundation
import Testing
@testable import SentryKeyProtocol

private struct TestIdentity: IdentitySigner {
    private let key = P256.Signing.PrivateKey()

    var publicKey: [UInt8] { Array(key.publicKey.x963Representation) }

    func signature(for message: [UInt8]) throws -> [UInt8] {
        Array(try key.signature(for: Data(message)).rawRepresentation)
    }
}

@Suite("One connection, from each side")
struct ChannelSessionsTests {
    private let mac = TestIdentity()
    private let phone = TestIdentity()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private let request = PhoneRequest.sign(id: RequestID(rawValue: 3), keyBlob: [1], data: [2, 3], bind: nil)
    private let response = PhoneResponse(id: RequestID(rawValue: 3), outcome: .refused(.deniedByUser))

    private func makeSessions() throws -> (mac: MacChannelSession, phone: PhoneChannelSession) {
        let macKey = mac.publicKey
        return (
            try MacChannelSession(identity: mac, phoneIdentityKey: phone.publicKey, now: now),
            PhoneChannelSession(identity: phone, pairedMacKey: { _ in macKey }, recentHellos: RecentHelloNonces())
        )
    }

    /// Runs the handshake between the two sessions.
    private func connect() throws -> (mac: MacChannelSession, phone: PhoneChannelSession) {
        var (macSession, phoneSession) = try makeSessions()
        guard case .handshakeAnswer(let answer) = try phoneSession.receive(macSession.hello, now: now) else {
            throw ChannelError.malformed
        }
        #expect(try macSession.receive(answer, now: now) == nil)
        return (macSession, phoneSession)
    }

    @Test func carriesARequestAndItsAnswer() throws {
        var (macSession, phoneSession) = try connect()

        let sealedRequest = try macSession.seal(request, now: now)
        #expect(try phoneSession.receive(sealedRequest, now: now) == .request(request))
        let sealedResponse = try phoneSession.seal(response, now: now)
        #expect(try macSession.receive(sealedResponse, now: now) == response)
    }

    @Test func opensOnlyAfterTheHandshake() throws {
        var (macSession, phoneSession) = try makeSessions()
        #expect(!macSession.isOpen)
        #expect(phoneSession.macFingerprint == nil)

        guard case .handshakeAnswer(let answer) = try phoneSession.receive(macSession.hello, now: now) else {
            Issue.record("expected a handshake answer")
            return
        }
        _ = try macSession.receive(answer, now: now)

        #expect(macSession.isOpen)
        #expect(phoneSession.macFingerprint == IdentityFingerprint.of(publicKey: mac.publicKey))
    }

    @Test func macCannotSendARequestBeforeTheHandshake() throws {
        var (macSession, _) = try makeSessions()

        #expect(throws: ChannelError.closed) { try macSession.seal(request, now: now) }
    }

    @Test func phoneCannotAnswerBeforeTheHandshake() throws {
        var (_, phoneSession) = try makeSessions()

        #expect(throws: ChannelError.closed) { try phoneSession.seal(response, now: now) }
    }

    @Test func phoneTreatsAnythingBeforeTheHandshakeAsAHello() throws {
        var (_, phoneSession) = try makeSessions()

        // A stranger sends a request in clear instead of a hello.
        #expect(throws: ChannelError.malformed) { try phoneSession.receive(request.encoded(), now: now) }
    }

    @Test func phoneRefusesAHelloReplayedOnAnotherConnection() throws {
        let macKey = mac.publicKey
        let shared = RecentHelloNonces()
        let macSession = try MacChannelSession(identity: mac, phoneIdentityKey: phone.publicKey, now: now)
        var first = PhoneChannelSession(identity: phone, pairedMacKey: { _ in macKey }, recentHellos: shared)
        var second = PhoneChannelSession(identity: phone, pairedMacKey: { _ in macKey }, recentHellos: shared)
        _ = try first.receive(macSession.hello, now: now)

        // A device in range plays the recorded hello on its own connection.
        #expect(throws: ChannelError.replayedHello) { try second.receive(macSession.hello, now: now) }
        #expect(second.macFingerprint == nil)
    }

    @Test func phoneClosesAfterARefusedHello() throws {
        var (macSession, _) = try makeSessions()
        var strangerToThisMac = PhoneChannelSession(
            identity: phone, pairedMacKey: { _ in nil }, recentHellos: RecentHelloNonces()
        )

        #expect(throws: ChannelError.unknownPeer) { try strangerToThisMac.receive(macSession.hello, now: now) }
        // A second attempt on the same connection is not even looked at.
        #expect(throws: ChannelError.closed) { try strangerToThisMac.receive(macSession.hello, now: now) }
        #expect(throws: ChannelError.closed) { try macSession.seal(request, now: now) }
    }

    @Test func macClosesAfterABadHandshakeAnswer() throws {
        var (macSession, phoneSession) = try makeSessions()
        guard case .handshakeAnswer(var answer) = try phoneSession.receive(macSession.hello, now: now) else {
            Issue.record("expected a handshake answer")
            return
        }
        answer[answer.count - 1] ^= 0x01

        #expect(throws: ChannelError.invalidSignature) { try macSession.receive(answer, now: now) }
        #expect(throws: ChannelError.closed) { try macSession.seal(request, now: now) }
    }

    @Test func sessionsCloseAfterAnAlteredMessage() throws {
        var (macSession, phoneSession) = try connect()
        var sealed = try macSession.seal(request, now: now)
        sealed[sealed.count - 1] ^= 0x01

        #expect(throws: ChannelError.authenticationFailed) { try phoneSession.receive(sealed, now: now) }
        #expect(throws: ChannelError.closed) { try phoneSession.seal(response, now: now) }
    }

    @Test func aSealedMessageThatIsNotARequestClosesThePhoneSession() throws {
        var (macSession, phoneSession) = try connect()
        // Valid encryption around something that is not a request: only a
        // Mac holding the session keys could send it.
        let sealed = try macSession.sealBody([99], now: now)

        #expect(throws: ChannelError.malformed) { try phoneSession.receive(sealed, now: now) }
        #expect(throws: ChannelError.closed) { try phoneSession.receive(sealed, now: now) }
    }
}
#endif
