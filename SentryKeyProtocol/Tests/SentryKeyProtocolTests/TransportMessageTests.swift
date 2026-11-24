import Testing
@testable import SentryKeyProtocol

@Suite("Messages on the Bluetooth link")
struct TransportMessageTests {
    @Test(arguments: [
        TransportMessage.pairingRequest([1, 2, 3]),
        TransportMessage.pairingConfirmation([4, 5]),
        TransportMessage.channel([6, 7, 8, 9]),
        TransportMessage.channel([]),
    ])
    func survivesEncoding(message: TransportMessage) throws {
        #expect(try TransportMessage.parse(message.encoded()) == message)
    }

    @Test func kindsAreNeverConfused() {
        let body: [UInt8] = [1, 2, 3]
        let encodings = [
            TransportMessage.pairingRequest(body).encoded(),
            TransportMessage.pairingConfirmation(body).encoded(),
            TransportMessage.channel(body).encoded(),
        ]
        #expect(Set(encodings).count == 3)
    }

    @Test func anEmptyMessageIsRejected() {
        #expect(throws: WireError.truncated) { try TransportMessage.parse([]) }
    }

    @Test func anUnknownKindIsRejected() {
        #expect(throws: WireError.unexpectedValue("transport message kind 0")) {
            try TransportMessage.parse([0, 1, 2])
        }
        #expect(throws: WireError.unexpectedValue("transport message kind 200")) {
            try TransportMessage.parse([200])
        }
    }

    @Test func anOversizedMessageIsRejected() {
        let tooLong = [UInt8](repeating: 3, count: TransportMessage.maxLength + 1)
        #expect(throws: WireError.lengthTooLarge(TransportMessage.maxLength + 1)) {
            try TransportMessage.parse(tooLong)
        }
    }

    @Test func theLargestSealedMessageFits() throws {
        // Header (16), largest plaintext, tag (16), kind byte.
        let sealedLength = 16 + AgentLimits.maxMessageLength + 16
        let message = TransportMessage.channel([UInt8](repeating: 0, count: sealedLength))

        #expect(message.encoded().count <= TransportMessage.maxLength)
        #expect(try TransportMessage.parse(message.encoded()) == message)
    }

    @Test func crossesTheLinkInSmallChunks() throws {
        let message = TransportMessage.channel([UInt8](repeating: 9, count: 1000))
        // 20 bytes: the smallest write Bluetooth guarantees.
        let chunks = try Framing.chunks(for: message.encoded(), chunkSize: 20, maxMessageLength: TransportMessage.maxLength)
        var reassembler = Reassembler(maxMessageLength: TransportMessage.maxLength)
        var received: [[UInt8]] = []
        for chunk in chunks {
            received += try reassembler.append(chunk)
        }

        #expect(received.count == 1)
        #expect(try TransportMessage.parse(received[0]) == message)
    }

    @Test func identifiersAreThreeDifferentUUIDs() {
        let identifiers = [BluetoothLayout.service, BluetoothLayout.toPhone, BluetoothLayout.toMac]
        #expect(Set(identifiers).count == 3)
        #expect(identifiers.allSatisfy { $0.count == 36 })
    }
}
