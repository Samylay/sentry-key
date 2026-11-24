import SentryKeyAgent
import SentryKeyProtocol
import Testing

@Suite("Queue of sign requests")
struct SigningQueueTests {
    let link = RecordingLink()
    let timeout = ManualTimeout()

    private func makeQueue(maxWaiting: Int = SigningQueue.defaultMaxWaiting) -> SigningQueue {
        SigningQueue(link: link, maxWaiting: maxWaiting, waitForTimeout: timeout.wait)
    }

    @Test func returnsThePhoneSignatureToTheCaller() async {
        let queue = makeQueue()
        async let outcome = queue.sign(keyBlob: [1], data: [2], bind: nil)

        #expect(await link.nextSign() == .sign(id: id(0), keyBlob: [1], data: [2], bind: nil))
        await queue.deliver(PhoneResponse(id: id(0), outcome: .signature(blob: [9])))

        #expect(await outcome == .signature(blob: [9]))
    }

    @Test func returnsThePhoneRefusalToTheCaller() async {
        let queue = makeQueue()
        async let outcome = queue.sign(keyBlob: [1], data: [2], bind: nil)

        _ = await link.nextSign()
        await queue.deliver(PhoneResponse(id: id(0), outcome: .refused(.deniedByUser)))

        #expect(await outcome == .refused(.deniedByUser))
    }

    @Test func ignoresAnAnswerToAnotherRequest() async {
        let queue = makeQueue()
        async let outcome = queue.sign(keyBlob: [1], data: [2], bind: nil)

        _ = await link.nextSign()
        await queue.deliver(PhoneResponse(id: id(5), outcome: .signature(blob: [9])))
        await queue.deliver(PhoneResponse(id: id(0), outcome: .refused(.busy)))

        #expect(await outcome == .refused(.busy))
    }

    @Test func givesUpAfterTheTimeoutAndTellsThePhone() async {
        let queue = makeQueue()
        async let outcome = queue.sign(keyBlob: [1], data: [2], bind: nil)

        _ = await link.nextSign()
        timeout.fire()

        #expect(await outcome == .timedOut)
        #expect(await link.nextCancel() == .cancel(id: id(0)))
    }

    @Test func doesNotGiveALateAnswerToTheNextRequest() async {
        let queue = makeQueue()
        async let first = queue.sign(keyBlob: [1], data: [2], bind: nil)
        _ = await link.nextSign()
        timeout.fire()
        #expect(await first == .timedOut)

        async let second = queue.sign(keyBlob: [1], data: [3], bind: nil)
        #expect(await link.nextSign()?.id == id(1))
        // The phone answers the first request after the Mac gave up on it.
        await queue.deliver(PhoneResponse(id: id(0), outcome: .signature(blob: [9])))
        await queue.deliver(PhoneResponse(id: id(1), outcome: .refused(.deniedByUser)))

        #expect(await second == .refused(.deniedByUser))
    }

    @Test func failsAtOnceWhenThePhoneIsUnreachable() async {
        let queue = makeQueue()
        await link.goDown()

        #expect(await queue.sign(keyBlob: [1], data: [2], bind: nil) == .phoneUnreachable)
    }

    @Test func keepsAnAnswerThatArrivesWhileTheRequestIsBeingSent() async {
        let queue = makeQueue()
        await link.answerInsideSend { request in
            await queue.deliver(PhoneResponse(id: request.id, outcome: .signature(blob: [7])))
        }

        #expect(await queue.sign(keyBlob: [1], data: [2], bind: nil) == .signature(blob: [7]))
    }

    @Test func sendsOneRequestAtATime() async {
        let queue = makeQueue()
        async let first = queue.sign(keyBlob: [1], data: [1], bind: nil)
        _ = await link.nextSign()
        async let second = queue.sign(keyBlob: [1], data: [2], bind: nil)
        #expect(await eventually { await queue.waitingCount == 1 })

        // The second request is held back until the first is answered.
        #expect(await link.sent.count == 1)
        await queue.deliver(PhoneResponse(id: id(0), outcome: .refused(.deniedByUser)))
        #expect(await link.nextSign() == .sign(id: id(1), keyBlob: [1], data: [2], bind: nil))
        await queue.deliver(PhoneResponse(id: id(1), outcome: .signature(blob: [4])))

        #expect(await first == .refused(.deniedByUser))
        #expect(await second == .signature(blob: [4]))
    }

    @Test func refusesAtOnceWhenTooManyRequestsWait() async {
        let queue = makeQueue(maxWaiting: 1)
        async let first = queue.sign(keyBlob: [1], data: [1], bind: nil)
        _ = await link.nextSign()
        async let second = queue.sign(keyBlob: [1], data: [2], bind: nil)
        #expect(await eventually { await queue.waitingCount == 1 })

        #expect(await queue.sign(keyBlob: [1], data: [3], bind: nil) == .queueFull)

        await queue.deliver(PhoneResponse(id: id(0), outcome: .refused(.deniedByUser)))
        _ = await link.nextSign()
        await queue.deliver(PhoneResponse(id: id(1), outcome: .refused(.deniedByUser)))
        _ = await (first, second)
    }
}
