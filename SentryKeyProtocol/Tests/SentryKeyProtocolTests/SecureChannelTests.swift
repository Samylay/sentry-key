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

    /// - Parameter recentHellos: a fresh cache by default, so a test can
    ///   accept the same hello twice; pass one to test replay refusal.
    func phoneAccepts(
        _ hello: MacHello, at time: Date? = nil,
        recentHellos: RecentHelloNonces = RecentHelloNonces()
    ) throws(ChannelError) -> PhoneHandshake.Accepted {
        try PhoneHandshake.accept(
            hello, identity: phone,
            pairedMacKey: { $0 == IdentityFingerprint.of(publicKey: mac.publicKey) ? mac.publicKey : nil },
            recentHellos: recentHellos,
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
        let (mac, phone) = try devices.connect()

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

    @Test func macFinishesAHandshakeOnlyOnce() throws {
        let handshake = try devices.macHandshake()
        let answer = try devices.phoneAccepts(handshake.hello).answer
        _ = try handshake.finish(with: answer)

        // A second channel would have the same keys and counter: refused.
        #expect(throws: ChannelError.closed) { try handshake.finish(with: answer) }
    }

    @Test func phoneRefusesAHelloItAlreadyAccepted() throws {
        let recentHellos = RecentHelloNonces()
        let hello = try devices.macHandshake().hello
        _ = try devices.phoneAccepts(hello, recentHellos: recentHellos)

        // Recorded off the air and played back a minute later.
        #expect(throws: ChannelError.replayedHello) {
            try devices.phoneAccepts(hello, at: devices.now.addingTimeInterval(60), recentHellos: recentHellos)
        }
    }

    @Test func phoneStillAcceptsANewHelloFromTheSameMac() throws {
        let recentHellos = RecentHelloNonces()
        _ = try devices.phoneAccepts(try devices.macHandshake().hello, recentHellos: recentHellos)

        _ = try devices.phoneAccepts(try devices.macHandshake().hello, recentHellos: recentHellos)
    }

    @Test func phoneDoesNotRecordARefusedHello() throws {
        let recentHellos = RecentHelloNonces()
        let hello = try devices.macHandshake().hello
        #expect(throws: ChannelError.timestampOutOfWindow) {
            try devices.phoneAccepts(hello, at: devices.now.addingTimeInterval(tolerance + 1), recentHellos: recentHellos)
        }

        // Refused for its time, not as a replay: it was never recorded.
        _ = try devices.phoneAccepts(hello, recentHellos: recentHellos)
    }

    @Test func helloCacheForgetsNoncesOnlyOnceTheirHelloHasExpired() {
        let cache = RecentHelloNonces()
        let nonce = [UInt8](repeating: 9, count: ChannelLimits.nonceLength)
        let stamp = UInt64(devices.now.timeIntervalSince1970)
        #expect(cache.insertIfNew(nonce, timestamp: stamp, now: devices.now))

        #expect(!cache.insertIfNew(nonce, timestamp: stamp, now: devices.now.addingTimeInterval(tolerance)))
        #expect(cache.insertIfNew(nonce, timestamp: stamp, now: devices.now.addingTimeInterval(tolerance + 1)))
    }

    @Test func helloCacheFailsClosedWhenFull() {
        let cache = RecentHelloNonces()
        let stamp = UInt64(devices.now.timeIntervalSince1970)
        for value in 0..<RecentHelloNonces.capacity {
            var nonce = [UInt8](repeating: 0, count: ChannelLimits.nonceLength)
            nonce[0] = UInt8(value & 0xFF)
            nonce[1] = UInt8(value >> 8)
            #expect(cache.insertIfNew(nonce, timestamp: stamp, now: devices.now))
        }

        let fresh = [UInt8](repeating: 0xEE, count: ChannelLimits.nonceLength)
        #expect(!cache.insertIfNew(fresh, timestamp: stamp, now: devices.now))
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
            identity: otherPhone, pairedMacKey: { _ in devices.mac.publicKey },
            recentHellos: RecentHelloNonces(), now: devices.now
        ).answer

        #expect(throws: ChannelError.invalidSignature) { try handshake.finish(with: answer) }
    }

    @Test func givesEveryConnectionItsOwnKeys() throws {
        let (firstMac, _) = try devices.connect()
        let (_, secondPhone) = try devices.connect()

        let sealed = try firstMac.seal([1], now: devices.now)

        #expect(throws: ChannelError.authenticationFailed) { try secondPhone.open(sealed, now: devices.now) }
    }
}

@Suite("Sealed channel messages")
struct SecureChannelTests {
    private let devices = PairedDevices()
    private var now: Date { devices.now }

    @Test func deliversSeveralMessagesInOrder() throws {
        let (mac, phone) = try devices.connect()

        for value in UInt8(0)..<5 {
            let sealed = try mac.seal([value], now: now)
            #expect(try phone.open(sealed, now: now) == [value])
        }
    }

    @Test func deliversAnEmptyMessage() throws {
        let (mac, phone) = try devices.connect()

        #expect(try phone.open(try mac.seal([], now: now), now: now) == [])
    }

    @Test func hidesTheContent() throws {
        let (mac, _) = try devices.connect()
        let secret = [UInt8](repeating: 0xAB, count: 64)

        let sealed = try mac.seal(secret, now: now)

        #expect(sealed.count == SecureChannel.headerLength + secret.count + SecureChannel.tagLength)
        let ciphertext = Array(sealed.dropFirst(SecureChannel.headerLength).prefix(secret.count))
        #expect(ciphertext != secret)
    }

    @Test func refusesAMessageReceivedTwice() throws {
        let (mac, phone) = try devices.connect()
        let sealed = try mac.seal([1], now: now)
        _ = try phone.open(sealed, now: now)

        #expect(throws: ChannelError.unexpectedCounter) { try phone.open(sealed, now: now) }
    }

    @Test func refusesMessagesOutOfOrder() throws {
        let (mac, phone) = try devices.connect()
        _ = try mac.seal([1], now: now)
        let second = try mac.seal([2], now: now)

        // The first message was lost, or held back to be delivered later.
        #expect(throws: ChannelError.unexpectedCounter) { try phone.open(second, now: now) }
    }

    @Test func refusesAMessageSentBackToItsAuthor() throws {
        let (mac, _) = try devices.connect()
        let sealed = try mac.seal([1], now: now)

        #expect(throws: ChannelError.authenticationFailed) { try mac.open(sealed, now: now) }
    }

    @Test func refusesAnyAlteredByte() throws {
        let length = try devices.connect().mac.seal([1, 2, 3, 4], now: now).count

        // A new connection per byte: a receiver closes after one failure.
        for index in 0..<length {
            let (mac, phone) = try devices.connect()
            var altered = try mac.seal([1, 2, 3, 4], now: now)
            altered[index] ^= 0x01
            #expect(throws: ChannelError.self, "byte \(index)") {
                _ = try phone.open(altered, now: now)
            }
        }
    }

    @Test func refusesEveryTruncation() throws {
        let length = try devices.connect().mac.seal([1, 2, 3, 4], now: now).count

        for prefix in 0..<length {
            let (mac, phone) = try devices.connect()
            let original = try mac.seal([1, 2, 3, 4], now: now)
            #expect(throws: ChannelError.self, "length \(prefix)") {
                _ = try phone.open(Array(original.prefix(prefix)), now: now)
            }
        }
    }

    @Test func refusesToOpenAMessageThatIsTooLarge() throws {
        let (_, phone) = try devices.connect()
        let tooLarge = [UInt8](
            repeating: 0, count: SecureChannel.headerLength + SecureChannel.maxPlaintextLength + SecureChannel.tagLength + 1
        )

        #expect(throws: ChannelError.messageTooLarge) { try phone.open(tooLarge, now: now) }
    }

    @Test func refusesAMessageFromTooFarInTheFuture() throws {
        let (mac, phone) = try devices.connect()
        let sealed = try mac.seal([1], now: now.addingTimeInterval(tolerance + 1))

        #expect(throws: ChannelError.timestampOutOfWindow) { try phone.open(sealed, now: now) }
    }

    @Test func copiesOfAChannelShareOneCounter() throws {
        let (mac, phone) = try devices.connect()
        let copy = mac

        // With a struct, both would seal under counter 0: a reused nonce.
        let first = try mac.seal([1], now: now)
        let second = try copy.seal([2], now: now)

        #expect(first.prefix(SecureChannel.headerLength) != second.prefix(SecureChannel.headerLength))
        #expect(try phone.open(first, now: now) == [1])
        #expect(try phone.open(second, now: now) == [2])
    }

    @Test func refusesAMessageDeliveredTooLate() throws {
        let (mac, phone) = try devices.connect()
        let sealed = try mac.seal([1], now: now)

        #expect(throws: ChannelError.timestampOutOfWindow) {
            try phone.open(sealed, now: now.addingTimeInterval(tolerance + 1))
        }
    }

    @Test func staysClosedAfterOneBadMessage() throws {
        let (mac, phone) = try devices.connect()
        let good = try mac.seal([1], now: now)
        var bad = good
        bad[bad.count - 1] ^= 0x01
        #expect(throws: ChannelError.authenticationFailed) { try phone.open(bad, now: now) }

        // Even the genuine message is refused now: no second guess.
        #expect(throws: ChannelError.closed) { try phone.open(good, now: now) }
        #expect(throws: ChannelError.closed) { try phone.seal([2], now: now) }
    }

    @Test func refusesToSealAMessageThatIsTooLarge() throws {
        let (mac, _) = try devices.connect()
        let tooLarge = [UInt8](repeating: 0, count: SecureChannel.maxPlaintextLength + 1)

        #expect(throws: ChannelError.messageTooLarge) { try mac.seal(tooLarge, now: now) }
    }

    @Test func sealsTheLargestAllowedMessage() throws {
        let (mac, phone) = try devices.connect()
        let largest = [UInt8](repeating: 7, count: SecureChannel.maxPlaintextLength)

        #expect(try phone.open(try mac.seal(largest, now: now), now: now) == largest)
    }

    @Test func stopsBeforeItsCounterCouldWrap() throws {
        let macKey = P256.KeyAgreement.PrivateKey()
        let phoneKey = P256.KeyAgreement.PrivateKey()
        let fingerprint = [UInt8](repeating: 1, count: ChannelLimits.fingerprintLength)
        let nonce = [UInt8](repeating: 2, count: ChannelLimits.nonceLength)
        let channel = try SecureChannel(
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
