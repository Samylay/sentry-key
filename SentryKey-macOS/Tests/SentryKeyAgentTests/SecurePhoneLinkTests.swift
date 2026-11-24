import Foundation
import SentryKeyAgent
import SentryKeyAgentDevSupport
import SentryKeyProtocol
import Testing

/// A phone that accepts the connection and then says nothing at all.
private struct SilentPhoneConnector: PhoneConnector {
    private actor Connection: PhoneConnection {
        private nonisolated let nothing: AsyncStream<[UInt8]>
        private let end: AsyncStream<[UInt8]>.Continuation

        init() {
            (nothing, end) = AsyncStream.makeStream()
        }

        func send(_ message: [UInt8]) {}

        nonisolated func receive() async throws -> [UInt8] {
            for await message in nothing { return message }
            throw PhoneLinkError.connectionLost
        }

        func close() {
            end.finish()
        }
    }

    func connect() async throws -> any PhoneConnection {
        Connection()
    }
}

// A time limit, so a missing answer fails the test instead of hanging it.
@Suite("Link to the phone through the secure channel", .timeLimit(.minutes(1)))
struct SecurePhoneLinkTests {
    let macIdentity = SoftwareIdentity()
    let phoneIdentity = SoftwareIdentity()
    let timeout = ManualTimeout()

    let request = PhoneRequest.sign(id: id(0), keyBlob: [1], data: [2], bind: nil)

    /// A phone that answers every sign request with the same refusal, so a
    /// test can tell an answer arrived without building a real SSH login.
    private func makePhone(
        pairedWith macKey: [UInt8]? = nil,
        identity: SoftwareIdentity? = nil
    ) -> LoopbackPhoneConnector {
        let pairedKey = macKey ?? macIdentity.publicKey
        return LoopbackPhoneConnector(
            phoneIdentity: identity ?? phoneIdentity,
            pairedMacKey: { $0 == IdentityFingerprint.of(publicKey: pairedKey) ? pairedKey : nil },
            answer: { request in
                guard case .sign = request else { return nil }
                return PhoneResponse(id: request.id, outcome: .refused(.deniedByUser))
            }
        )
    }

    private func makeLink(to connector: any PhoneConnector) -> SecurePhoneLink {
        SecurePhoneLink(
            identity: macIdentity, phoneIdentityKey: phoneIdentity.publicKey,
            connector: connector, waitForHandshakeTimeout: timeout.wait
        )
    }

    private func nextResponse(from link: SecurePhoneLink) async -> PhoneResponse? {
        for await response in link.responses { return response }
        return nil
    }

    @Test func carriesARequestToThePhoneAndItsAnswerBack() async throws {
        let link = makeLink(to: makePhone())

        try await link.send(request)

        #expect(await nextResponse(from: link) == PhoneResponse(id: id(0), outcome: .refused(.deniedByUser)))
    }

    @Test func keepsOneConnectionForSeveralRequests() async throws {
        let phone = makePhone()
        let link = makeLink(to: phone)

        try await link.send(request)
        _ = await nextResponse(from: link)
        try await link.send(.sign(id: id(1), keyBlob: [1], data: [2], bind: nil))

        #expect(await nextResponse(from: link)?.id == id(1))
        #expect(phone.connectionCount == 1)
    }

    @Test func opensANewConnectionWhenTheFirstWasLost() async throws {
        let phone = makePhone()
        let link = makeLink(to: phone)
        try await link.send(request)
        _ = await nextResponse(from: link)

        await phone.dropConnections()
        try await link.send(.sign(id: id(1), keyBlob: [1], data: [2], bind: nil))

        #expect(await nextResponse(from: link)?.id == id(1))
        #expect(phone.connectionCount == 2)
    }

    @Test func failsWhenThePhoneCannotBeReached() async {
        let phone = makePhone()
        phone.setReachable(false)
        let link = makeLink(to: phone)

        await #expect(throws: LoopbackPhoneConnector.Unreachable.self) { try await link.send(request) }
    }

    @Test func getsNothingFromAnotherPhoneThanTheOnePairedWith() async {
        // Another phone, also paired with this Mac, receives the hello. It
        // was signed for the expected phone, so this one drops it.
        let link = makeLink(to: makePhone(identity: SoftwareIdentity()))

        await #expect(throws: PhoneLinkError.connectionLost) { try await link.send(request) }
    }

    @Test func getsNothingFromAPhoneThatDoesNotKnowThisMac() async {
        let link = makeLink(to: makePhone(pairedWith: SoftwareIdentity().publicKey))

        // The phone drops the connection without a word.
        await #expect(throws: PhoneLinkError.connectionLost) { try await link.send(request) }
    }

    @Test func givesUpWhenThePhoneDoesNotAnswerTheHandshake() async {
        let link = makeLink(to: SilentPhoneConnector())
        timeout.fire()

        await #expect(throws: PhoneLinkError.handshakeTimedOut) { try await link.send(request) }
    }

    @Test func doesNotConnectJustToCancel() async throws {
        let phone = makePhone()
        let link = makeLink(to: phone)

        try await link.send(.cancel(id: id(0)))

        #expect(phone.connectionCount == 0)
    }

    @Test func worksUnderTheQueueFromRequestToAnswer() async {
        let link = makeLink(to: makePhone())
        let queue = SigningQueue(link: link, waitForTimeout: ManualTimeout().wait)
        let pump = Task {
            for await response in link.responses {
                await queue.deliver(response)
            }
        }
        defer { pump.cancel() }

        #expect(await queue.sign(keyBlob: [1], data: [2], bind: nil) == .refused(.deniedByUser))
        #expect(await queue.sign(keyBlob: [1], data: [3], bind: nil) == .refused(.deniedByUser))
    }

    @Test func reportsAnUnreachablePhoneThroughTheQueue() async {
        let phone = makePhone()
        phone.setReachable(false)
        let queue = SigningQueue(link: makeLink(to: phone), waitForTimeout: ManualTimeout().wait)

        #expect(await queue.sign(keyBlob: [1], data: [2], bind: nil) == .phoneUnreachable)
    }
}
