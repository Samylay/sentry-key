#if canImport(CryptoKit)
import CryptoKit
import Foundation
import Testing
@testable import SentryKeyProtocol

/// An identity key held in memory, standing in for a Secure Enclave key.
private struct SoftwareIdentity: IdentitySigner {
    private let key = P256.Signing.PrivateKey()

    var publicKey: [UInt8] { Array(key.publicKey.x963Representation) }

    func signature(for message: [UInt8]) throws -> [UInt8] {
        Array(try key.signature(for: Data(message)).rawRepresentation)
    }
}

/// A Mac and a phone that have been paired: each knows the other's key.
private struct PairedDevices {
    let mac = SoftwareIdentity()
    let phone = SoftwareIdentity()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func macHandshake(at time: Date? = nil) throws -> MacHandshake {
        try MacHandshake(identity: mac, phoneIdentityKey: phone.publicKey, now: time ?? now)
    }

    func phoneAccepts(_ hello: MacHello, at time: Date? = nil) throws(ChannelError) -> PhoneHandshake.Accepted {
        try PhoneHandshake.accept(
            hello, identity: phone,
            pairedMacKey: { $0 == IdentityFingerprint.of(publicKey: mac.publicKey) ? mac.publicKey : nil },
            now: time ?? now
        )
    }

    /// A finished handshake: the two ends of one connection.
    func connect() throws -> (mac: SecureChannel, phone: SecureChannel) {
        let handshake = try macHandshake()
        let accepted = try phoneAccepts(handshake.hello)
        return (try handshake.finish(with: accepted.answer), accepted.channel)
    }
}

private let tolerance = TimeInterval(ChannelLimits.clockToleranceSeconds)

@Suite("Channel handshake")
struct ChannelHandshakeTests {
    private let devices = PairedDevices()

    @Test func opensAChannelThatWorksBothWays() throws {
        var (mac, phone) = try devices.connect()

        let request = try mac.seal([1, 2, 3], now: devices.now)
        #expect(try phone.open(request, now: devices.now) == [1, 2, 3])
        let answer = try phone.seal([4, 5], now: devices.now)
        #expect(try mac.open(answer, now: devices.now) == [4, 5])
    }

    @Test func tellsThePhoneWhichMacConnected() throws {
        let accepted = try devices.phoneAccepts(try devices.macHandshake().hello)

        #expect(accepted.macFingerprint == IdentityFingerprint.of(publicKey: devices.mac.publicKey))
    }

    @Test func phoneRefusesAMacItIsNotPairedWith() throws {
        let stranger = SoftwareIdentity()
        let hello = try MacHandshake(identity: stranger, phoneIdentityKey: devices.phone.publicKey, now: devices.now).hello

        #expect(throws: ChannelError.unknownPeer) { try devices.phoneAccepts(hello) }
    }

    @Test func phoneRefusesAStrangerClaimingToBeThePairedMac() throws {
        let stranger = SoftwareIdentity()
        let forged = try MacHandshake(identity: stranger, phoneIdentityKey: devices.phone.publicKey, now: devices.now).hello
        let hello = MacHello(
            version: forged.version,
            macFingerprint: IdentityFingerprint.of(publicKey: devices.mac.publicKey),
            nonce: forged.nonce, ephemeralKey: forged.ephemeralKey,
            timestamp: forged.timestamp, signature: forged.signature
        )

        #expect(throws: ChannelError.invalidSignature) { try devices.phoneAccepts(hello) }
    }

    @Test func phoneRefusesAHelloMeantForAnotherPhone() throws {
        let otherPhone = SoftwareIdentity()
        let hello = try MacHandshake(identity: devices.mac, phoneIdentityKey: otherPhone.publicKey, now: devices.now).hello

        #expect(throws: ChannelError.invalidSignature) { try devices.phoneAccepts(hello) }
    }

    @Test func phoneRefusesAnyAlteredByteOfTheHello() throws {
        let original = try devices.macHandshake().hello.encoded()

        for index in original.indices {
            var altered = original
            altered[index] ^= 0x01
            #expect(throws: (any Error).self, "byte \(index)") {
                _ = try devices.phoneAccepts(try MacHello.parse(body: altered))
            }
        }
    }

    @Test func phoneAcceptsAHelloAtTheEdgeOfTheClockTolerance() throws {
        let hello = try devices.macHandshake().hello

        _ = try devices.phoneAccepts(hello, at: devices.now.addingTimeInterval(tolerance))
        _ = try devices.phoneAccepts(hello, at: devices.now.addingTimeInterval(-tolerance))
    }

    @Test func phoneRefusesARecordedHelloPlayedBackLater() throws {
        let hello = try devices.macHandshake().hello

        #expect(throws: ChannelError.timestampOutOfWindow) {
            try devices.phoneAccepts(hello, at: devices.now.addingTimeInterval(tolerance + 1))
        }
    }

    @Test func phoneRefusesAHelloFromTooFarInTheFuture() throws {
        let hello = try devices.macHandshake(at: devices.now.addingTimeInterval(tolerance + 1)).hello

        #expect(throws: ChannelError.timestampOutOfWindow) { try devices.phoneAccepts(hello) }
    }

    @Test func phoneRefusesAnEphemeralKeyThatIsNotOnTheCurve() throws {
        // Signed by the real Mac, so only the curve check can stop it.
        let badKey = [0x04] + [UInt8](repeating: 0xFF, count: ChannelLimits.publicKeyLength - 1)
        let nonce = [UInt8](repeating: 1, count: ChannelLimits.nonceLength)
        let macFingerprint = IdentityFingerprint.of(publicKey: devices.mac.publicKey)
        let timestamp = UInt64(devices.now.timeIntervalSince1970)
        let signature = try devices.mac.signature(for: MacHello.signedBytes(
            version: ChannelLimits.version, macFingerprint: macFingerprint,
            phoneFingerprint: IdentityFingerprint.of(publicKey: devices.phone.publicKey),
            nonce: nonce, ephemeralKey: badKey, timestamp: timestamp
        ))
        let hello = MacHello(
            version: ChannelLimits.version, macFingerprint: macFingerprint, nonce: nonce,
            ephemeralKey: badKey, timestamp: timestamp, signature: signature
        )

        #expect(throws: ChannelError.malformed) { try devices.phoneAccepts(hello) }
    }

    @Test func macRefusesAnyAlteredByteOfTheAnswer() throws {
        let handshake = try devices.macHandshake()
        let original = try devices.phoneAccepts(handshake.hello).answer.encoded()

        for index in original.indices {
            var altered = original
            altered[index] ^= 0x01
            #expect(throws: (any Error).self, "byte \(index)") {
                _ = try handshake.finish(with: try PhoneHello.parse(body: altered))
            }
        }
    }

    @Test func macRefusesAnAnswerRecordedOnAnotherConnection() throws {
        let earlier = try devices.macHandshake()
        let recordedAnswer = try devices.phoneAccepts(earlier.hello).answer
        let current = try devices.macHandshake()

        #expect(throws: ChannelError.invalidSignature) { try current.finish(with: recordedAnswer) }
    }

    @Test func macRefusesAnAnswerFromAnotherPhone() throws {
        let otherPhone = SoftwareIdentity()
        let handshake = try devices.macHandshake()
        // The other phone is paired with this Mac too, and answers in place
        // of the phone the Mac called.
        let answer = try PhoneHandshake.accept(
            try MacHandshake(identity: devices.mac, phoneIdentityKey: otherPhone.publicKey, now: devices.now).hello,
            identity: otherPhone, pairedMacKey: { _ in devices.mac.publicKey }, now: devices.now
        ).answer

        #expect(throws: ChannelError.invalidSignature) { try handshake.finish(with: answer) }
    }

    @Test func givesEveryConnectionItsOwnKeys() throws {
        var (firstMac, _) = try devices.connect()
        var (_, secondPhone) = try devices.connect()

        let sealed = try firstMac.seal([1], now: devices.now)

        #expect(throws: ChannelError.authenticationFailed) { try secondPhone.open(sealed, now: devices.now) }
    }
}

@Suite("Sealed channel messages")
struct SecureChannelTests {
    private let devices = PairedDevices()
    private var now: Date { devices.now }

    @Test func deliversSeveralMessagesInOrder() throws {
        var (mac, phone) = try devices.connect()

        for value in UInt8(0)..<5 {
            let sealed = try mac.seal([value], now: now)
            #expect(try phone.open(sealed, now: now) == [value])
        }
    }

    @Test func deliversAnEmptyMessage() throws {
        var (mac, phone) = try devices.connect()

        #expect(try phone.open(try mac.seal([], now: now), now: now) == [])
    }

    @Test func hidesTheContent() throws {
        var (mac, _) = try devices.connect()
        let secret = [UInt8](repeating: 0xAB, count: 64)

        let sealed = try mac.seal(secret, now: now)

        #expect(sealed.count == SecureChannel.headerLength + secret.count + SecureChannel.tagLength)
        let ciphertext = Array(sealed.dropFirst(SecureChannel.headerLength).prefix(secret.count))
        #expect(ciphertext != secret)
    }

    @Test func refusesAMessageReceivedTwice() throws {
        var (mac, phone) = try devices.connect()
        let sealed = try mac.seal([1], now: now)
        _ = try phone.open(sealed, now: now)

        #expect(throws: ChannelError.unexpectedCounter) { try phone.open(sealed, now: now) }
    }

    @Test func refusesMessagesOutOfOrder() throws {
        var (mac, phone) = try devices.connect()
        _ = try mac.seal([1], now: now)
        let second = try mac.seal([2], now: now)

        // The first message was lost, or held back to be delivered later.
        #expect(throws: ChannelError.unexpectedCounter) { try phone.open(second, now: now) }
    }

    @Test func refusesAMessageSentBackToItsAuthor() throws {
        var (mac, _) = try devices.connect()
        let sealed = try mac.seal([1], now: now)

        #expect(throws: ChannelError.authenticationFailed) { try mac.open(sealed, now: now) }
    }

    @Test func refusesAnyAlteredByte() throws {
        var (mac, phone) = try devices.connect()
        let original = try mac.seal([1, 2, 3, 4], now: now)

        for index in original.indices {
            var altered = original
            altered[index] ^= 0x01
            // A copy: the real receiver would be closed after one failure.
            var receiver = phone
            #expect(throws: ChannelError.self, "byte \(index)") {
                _ = try receiver.open(altered, now: now)
            }
        }
        #expect(try phone.open(original, now: now) == [1, 2, 3, 4])
    }

    @Test func refusesEveryTruncation() throws {
        var (mac, phone) = try devices.connect()
        let original = try mac.seal([1, 2, 3, 4], now: now)

        for length in 0..<original.count {
            var receiver = phone
            #expect(throws: ChannelError.self, "length \(length)") {
                _ = try receiver.open(Array(original.prefix(length)), now: now)
            }
        }
    }

    @Test func refusesAMessageDeliveredTooLate() throws {
        var (mac, phone) = try devices.connect()
        let sealed = try mac.seal([1], now: now)

        #expect(throws: ChannelError.timestampOutOfWindow) {
            try phone.open(sealed, now: now.addingTimeInterval(tolerance + 1))
        }
    }

    @Test func staysClosedAfterOneBadMessage() throws {
        var (mac, phone) = try devices.connect()
        let good = try mac.seal([1], now: now)
        var bad = good
        bad[bad.count - 1] ^= 0x01
        #expect(throws: ChannelError.authenticationFailed) { try phone.open(bad, now: now) }

        // Even the genuine message is refused now: no second guess.
        #expect(throws: ChannelError.closed) { try phone.open(good, now: now) }
        #expect(throws: ChannelError.closed) { try phone.seal([2], now: now) }
    }

    @Test func refusesToSealAMessageThatIsTooLarge() throws {
        var (mac, _) = try devices.connect()
        let tooLarge = [UInt8](repeating: 0, count: SecureChannel.maxPlaintextLength + 1)

        #expect(throws: ChannelError.messageTooLarge) { try mac.seal(tooLarge, now: now) }
    }

    @Test func sealsTheLargestAllowedMessage() throws {
        var (mac, phone) = try devices.connect()
        let largest = [UInt8](repeating: 7, count: SecureChannel.maxPlaintextLength)

        #expect(try phone.open(try mac.seal(largest, now: now), now: now) == largest)
    }

    @Test func stopsBeforeItsCounterCouldWrap() throws {
        let macKey = P256.KeyAgreement.PrivateKey()
        let phoneKey = P256.KeyAgreement.PrivateKey()
        let fingerprint = [UInt8](repeating: 1, count: ChannelLimits.fingerprintLength)
        let nonce = [UInt8](repeating: 2, count: ChannelLimits.nonceLength)
        var channel = try SecureChannel(
            role: .mac, ephemeralKey: macKey,
            peerEphemeralKey: Array(phoneKey.publicKey.x963Representation),
            macNonce: nonce, phoneNonce: nonce,
            macFingerprint: fingerprint, phoneFingerprint: fingerprint,
            firstSendCounter: UInt64.max - 1
        )

        _ = try channel.seal([1], now: now)

        #expect(throws: ChannelError.counterExhausted) { try channel.seal([2], now: now) }
        #expect(throws: ChannelError.closed) { try channel.seal([3], now: now) }
    }
}
#endif
