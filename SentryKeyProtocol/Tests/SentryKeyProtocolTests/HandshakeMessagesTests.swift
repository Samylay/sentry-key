import Testing
@testable import SentryKeyProtocol

private let sampleMacHello = MacHello(
    version: ChannelLimits.version,
    macFingerprint: [UInt8](repeating: 1, count: ChannelLimits.fingerprintLength),
    nonce: [UInt8](repeating: 2, count: ChannelLimits.nonceLength),
    ephemeralKey: [UInt8](repeating: 3, count: ChannelLimits.publicKeyLength),
    timestamp: 1_800_000_000,
    signature: [UInt8](repeating: 4, count: ChannelLimits.signatureLength)
)

private let samplePhoneHello = PhoneHello(
    nonce: [UInt8](repeating: 5, count: ChannelLimits.nonceLength),
    ephemeralKey: [UInt8](repeating: 6, count: ChannelLimits.publicKeyLength),
    signature: [UInt8](repeating: 7, count: ChannelLimits.signatureLength)
)

@Suite("Handshake messages")
struct HandshakeMessagesTests {
    @Test func macHelloSurvivesEncoding() throws {
        #expect(try MacHello.parse(body: sampleMacHello.encoded()) == sampleMacHello)
    }

    @Test func phoneHelloSurvivesEncoding() throws {
        #expect(try PhoneHello.parse(body: samplePhoneHello.encoded()) == samplePhoneHello)
    }

    @Test func timestampKeepsAllItsBits() throws {
        let late = MacHello(
            version: sampleMacHello.version, macFingerprint: sampleMacHello.macFingerprint,
            nonce: sampleMacHello.nonce, ephemeralKey: sampleMacHello.ephemeralKey,
            timestamp: 0x0102_0304_0506_0708, signature: sampleMacHello.signature
        )
        #expect(try MacHello.parse(body: late.encoded()).timestamp == 0x0102_0304_0506_0708)
    }

    @Test func anotherVersionIsRefused() {
        var body = sampleMacHello.encoded()
        body[0] = 2
        #expect(throws: WireError.unexpectedValue("channel version 2")) {
            try MacHello.parse(body: body)
        }
    }

    @Test func everyTruncationIsRejected() {
        let macHello = sampleMacHello.encoded()
        for length in 0..<macHello.count {
            #expect(throws: WireError.self) { try MacHello.parse(body: Array(macHello.prefix(length))) }
        }
        let phoneHello = samplePhoneHello.encoded()
        for length in 0..<phoneHello.count {
            #expect(throws: WireError.self) { try PhoneHello.parse(body: Array(phoneHello.prefix(length))) }
        }
    }

    @Test func trailingBytesAreRejected() {
        #expect(throws: WireError.trailingBytes(1)) {
            try MacHello.parse(body: sampleMacHello.encoded() + [0])
        }
        #expect(throws: WireError.trailingBytes(1)) {
            try PhoneHello.parse(body: samplePhoneHello.encoded() + [0])
        }
    }

    @Test func fieldsOfTheWrongLengthAreRejected() {
        let shortNonce = PhoneHello(
            nonce: [UInt8](repeating: 5, count: ChannelLimits.nonceLength - 1),
            ephemeralKey: samplePhoneHello.ephemeralKey,
            signature: samplePhoneHello.signature
        )
        #expect(throws: WireError.unexpectedValue("nonce length")) {
            try PhoneHello.parse(body: shortNonce.encoded())
        }

        let longKey = PhoneHello(
            nonce: samplePhoneHello.nonce,
            ephemeralKey: [UInt8](repeating: 6, count: ChannelLimits.publicKeyLength + 1),
            signature: samplePhoneHello.signature
        )
        #expect(throws: WireError.lengthTooLarge(ChannelLimits.publicKeyLength + 1)) {
            try PhoneHello.parse(body: longKey.encoded())
        }
    }

    @Test func theTwoSidesNeverSignTheSameBytes() {
        // Same values on both sides: only the label tells them apart.
        let field = [UInt8](repeating: 9, count: 32)
        let mac = MacHello.signedBytes(
            version: 1, macFingerprint: field, phoneFingerprint: field,
            nonce: field, ephemeralKey: field, timestamp: 0
        )
        let phone = PhoneHello.signedBytes(
            version: 1, macFingerprint: field, phoneFingerprint: field,
            macNonce: field, phoneNonce: field, macEphemeralKey: field, phoneEphemeralKey: field
        )
        #expect(!phone.starts(with: mac) && !mac.starts(with: phone))
    }
}
