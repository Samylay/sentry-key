import CryptoKit
import Foundation
import SentryKeyAgent
import SentryKeyProtocol
import Testing

@Suite("One ssh connection to the agent")
struct AgentSessionTests {
    let phoneKey = P256.Signing.PrivateKey()
    let keyBlob: [UInt8]
    let link = RecordingLink()
    let queue: SigningQueue
    let events = EventLog()
    let session: AgentSession

    let bind = SessionBind(hostKey: [1, 2], sessionID: [3, 4], serverSignature: [5, 6], isForwarding: false)
    let data: [UInt8] = [10, 20, 30]

    init() throws {
        keyBlob = try ECDSAP256.publicKeyBlob(x963Point: Array(phoneKey.publicKey.x963Representation))
        queue = SigningQueue(link: link, waitForTimeout: ManualTimeout().wait)
        session = AgentSession(
            keys: FixedPublicKeyStore(identity: AgentIdentity(keyBlob: keyBlob, comment: "phone")),
            queue: queue,
            verifier: P256SignatureVerifier(),
            report: events.report
        )
    }

    /// Makes the phone answer every sign request by signing with `key`.
    private func phoneSigns(with key: P256.Signing.PrivateKey) async {
        await link.answerInsideSend { [queue] request in
            guard case .sign(let id, _, let data, _) = request,
                  let raw = try? key.signature(for: Data(data)).rawRepresentation,
                  let blob = try? ECDSAP256.signatureBlob(rawSignature: Array(raw))
            else { return }
            await queue.deliver(PhoneResponse(id: id, outcome: .signature(blob: blob)))
        }
    }

    private func phoneRefuses(_ reason: RefusalReason) async {
        await link.answerInsideSend { [queue] request in
            await queue.deliver(PhoneResponse(id: request.id, outcome: .refused(reason)))
        }
    }

    @Test func offersThePhoneKeyToSSH() async throws {
        let response = try await session.handle(body: AgentRequestBody.requestIdentities)

        #expect(response == .identities([AgentIdentity(keyBlob: keyBlob, comment: "phone")]))
    }

    @Test func offersNoKeyWhenNoPhoneIsPaired() async throws {
        let unpaired = AgentSession(
            keys: FixedPublicKeyStore(identity: nil), queue: queue, verifier: P256SignatureVerifier()
        )

        #expect(try await unpaired.handle(body: AgentRequestBody.requestIdentities) == .identities([]))
        #expect(try await unpaired.handle(body: AgentRequestBody.sign(keyBlob: keyBlob, data: data)) == .failure)
        #expect(await link.sent.isEmpty)
    }

    @Test func sendsTheSignRequestToThePhoneWithItsSessionBind() async throws {
        await phoneSigns(with: phoneKey)

        #expect(try await session.handle(body: AgentRequestBody.sessionBind(bind)) == .success)
        _ = try await session.handle(body: AgentRequestBody.sign(keyBlob: keyBlob, data: data))

        #expect(await link.sent == [.sign(id: id(0), keyBlob: keyBlob, data: data, bind: bind)])
    }

    @Test func returnsAValidSignatureToSSH() async throws {
        await phoneSigns(with: phoneKey)
        _ = try await session.handle(body: AgentRequestBody.sessionBind(bind))

        let response = try await session.handle(body: AgentRequestBody.sign(keyBlob: keyBlob, data: data))

        guard case .signature(let blob) = response else {
            Issue.record("expected a signature, got \(response)")
            return
        }
        #expect(P256SignatureVerifier().isValid(signatureBlob: blob, data: data, publicKeyBlob: keyBlob))
        #expect(events.all == [.signed])
    }

    @Test func doesNotPassOnASignatureMadeWithAnotherKey() async throws {
        await phoneSigns(with: P256.Signing.PrivateKey())
        _ = try await session.handle(body: AgentRequestBody.sessionBind(bind))

        #expect(try await session.handle(body: AgentRequestBody.sign(keyBlob: keyBlob, data: data)) == .failure)
        #expect(events.all == [.invalidSignatureFromPhone])
    }

    @Test func answersFailureWhenThePhoneRefuses() async throws {
        await phoneRefuses(.deniedByUser)
        _ = try await session.handle(body: AgentRequestBody.sessionBind(bind))

        #expect(try await session.handle(body: AgentRequestBody.sign(keyBlob: keyBlob, data: data)) == .failure)
        #expect(events.all == [.refusedByPhone(.deniedByUser)])
    }

    @Test func answersFailureWhenThePhoneIsUnreachable() async throws {
        await link.goDown()

        #expect(try await session.handle(body: AgentRequestBody.sign(keyBlob: keyBlob, data: data)) == .failure)
        #expect(events.all == [.phoneUnreachable])
    }

    @Test func leavesTheDecisionToThePhoneWhenSSHSentNoSessionBind() async throws {
        await phoneRefuses(.invalidRequest)

        _ = try await session.handle(body: AgentRequestBody.sign(keyBlob: keyBlob, data: data))

        #expect(await link.sent == [.sign(id: id(0), keyBlob: keyBlob, data: data, bind: nil)])
    }

    @Test func neverAsksThePhoneToSignForAnotherKey() async throws {
        let otherKey = try ECDSAP256.publicKeyBlob(
            x963Point: Array(P256.Signing.PrivateKey().publicKey.x963Representation)
        )

        #expect(try await session.handle(body: AgentRequestBody.sign(keyBlob: otherKey, data: data)) == .failure)
        #expect(await link.sent.isEmpty)
        #expect(events.all == [.unknownKeyRequested])
    }

    @Test(arguments: [
        [17, 0, 0, 0, 0],   // add a key
        [18, 0, 0, 0, 0],   // remove a key
        [19],               // remove all keys
        [22, 0, 0, 0, 0],   // lock the agent
        [200],              // not an ssh-agent message
    ] as [[UInt8]])
    func refusesKeyManagementWithoutAskingThePhone(body: [UInt8]) async throws {
        #expect(try await session.handle(body: body) == .failure)
        #expect(await link.sent.isEmpty)
    }

    @Test func refusesAnUnknownExtension() async throws {
        let body = AgentRequestBody.unknownExtension(named: "query")

        #expect(try await session.handle(body: body) == .failure)
        #expect(await link.sent.isEmpty)
    }

    @Test func refusesToSignOnAForwardedConnection() async throws {
        await phoneSigns(with: phoneKey)
        let forwarded = SessionBind(hostKey: [1], sessionID: [2], serverSignature: [3], isForwarding: true)
        _ = try await session.handle(body: AgentRequestBody.sessionBind(forwarded))
        // What the remote host would send next through the forwarded agent.
        _ = try await session.handle(body: AgentRequestBody.sessionBind(bind))

        #expect(try await session.handle(body: AgentRequestBody.sign(keyBlob: keyBlob, data: data)) == .failure)
        #expect(await link.sent.isEmpty)
        #expect(events.all == [.forwardedRequestRefused])
    }

    @Test func refusesToSignAfterASecondSessionBind() async throws {
        await phoneSigns(with: phoneKey)
        _ = try await session.handle(body: AgentRequestBody.sessionBind(bind))
        _ = try await session.handle(body: AgentRequestBody.sessionBind(bind))

        #expect(try await session.handle(body: AgentRequestBody.sign(keyBlob: keyBlob, data: data)) == .failure)
        #expect(await link.sent.isEmpty)
    }

    @Test func rejectsAMalformedMessage() async {
        // A sign request cut short after its type byte.
        await #expect(throws: WireError.self) {
            try await session.handle(body: [AgentMessageType.signRequest.rawValue, 0])
        }
    }
}
