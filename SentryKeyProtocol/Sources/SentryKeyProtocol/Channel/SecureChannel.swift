// CryptoKit does not exist on Linux, where part of the team builds and
// tests this package. There, this file compiles to nothing.
#if canImport(CryptoKit)
import CryptoKit
import Foundation

// The secure channel between the Mac agent and the phone (ARCHITECTURE.md,
// Channel). CryptoKit only: P-256 ECDSA and ECDH, HKDF-SHA256, AES-256-GCM.
//
// NEEDS LINE-BY-LINE HUMAN REVIEW (crypto code).
//
// Shape of one connection:
//
//   Mac                                   phone
//    | MacHello: ephemeral key, nonce,      |
//    |   timestamp, signed by the Mac       |
//    |------------------------------------->| checks version, known Mac,
//    |                                      |   signature, timestamp
//    |   PhoneHello: ephemeral key, nonce,  |
//    |   signed by the phone over both      |
//    |<-------------------------------------|
//    | checks the signature                 |
//    |                                      |
//    |   both: ECDH, then HKDF gives one AES-GCM key per direction
//    |                                      |
//    |<======== sealed messages ===========>|
//
// The phone's signature covers the Mac's fresh nonce, so the Mac knows the
// phone is live. The Mac's signature cannot cover the phone's nonce (it is
// sent first), so the phone relies on the signed timestamp: a recorded
// MacHello is refused once it is older than the clock tolerance. Within
// that time, replaying it gets an answer but no channel, because sealing a
// message needs the ephemeral private key, which only the Mac had.

public enum ChannelError: Error, Equatable {
    /// The message is not well formed.
    case malformed
    /// The Mac is not one this phone is paired with.
    case unknownPeer
    case invalidSignature
    /// A timestamp too far from this device's clock.
    case timestampOutOfWindow
    /// A message arrived out of order, twice, or after one was lost.
    case unexpectedCounter
    /// The key has sealed as many messages as it safely can.
    case counterExhausted
    /// AES-GCM refused the message: it was altered, or made for another
    /// connection or the other direction.
    case authenticationFailed
    case messageTooLarge
    /// An earlier message failed. The connection must be dropped.
    case closed
}

/// An identity key that can sign: a Secure Enclave key on a device, an
/// ordinary key in tests. The channel never sees the private key.
public protocol IdentitySigner: Sendable {
    /// The public key as an uncompressed point (65 bytes).
    var publicKey: [UInt8] { get }
    /// An ECDSA P-256 signature over SHA-256 of `message`: r then s, 64 bytes.
    func signature(for message: [UInt8]) throws -> [UInt8]
}

public enum IdentityFingerprint {
    /// SHA-256 of an identity public key. Names a paired device.
    public static func of(publicKey: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: publicKey))
    }
}

/// The Mac's side of the handshake.
public struct MacHandshake {
    /// The message to send to the phone.
    public let hello: MacHello

    private let ephemeralKey: P256.KeyAgreement.PrivateKey
    private let macFingerprint: [UInt8]
    private let phoneIdentityKey: [UInt8]

    /// - Parameter phoneIdentityKey: the phone's identity public key,
    ///   recorded at pairing.
    public init(identity: any IdentitySigner, phoneIdentityKey: [UInt8], now: Date) throws {
        let ephemeralKey = P256.KeyAgreement.PrivateKey()
        let ephemeralPublic = Array(ephemeralKey.publicKey.x963Representation)
        let macFingerprint = IdentityFingerprint.of(publicKey: identity.publicKey)
        let nonce = Self.randomNonce()
        let timestamp = UInt64(max(0, now.timeIntervalSince1970))

        let signature = try identity.signature(for: MacHello.signedBytes(
            version: ChannelLimits.version,
            macFingerprint: macFingerprint,
            phoneFingerprint: IdentityFingerprint.of(publicKey: phoneIdentityKey),
            nonce: nonce,
            ephemeralKey: ephemeralPublic,
            timestamp: timestamp
        ))
        self.hello = MacHello(
            version: ChannelLimits.version, macFingerprint: macFingerprint, nonce: nonce,
            ephemeralKey: ephemeralPublic, timestamp: timestamp, signature: signature
        )
        self.ephemeralKey = ephemeralKey
        self.macFingerprint = macFingerprint
        self.phoneIdentityKey = phoneIdentityKey
    }

    /// Checks the phone's answer and opens the channel.
    public func finish(with answer: PhoneHello) throws(ChannelError) -> SecureChannel {
        let phoneFingerprint = IdentityFingerprint.of(publicKey: phoneIdentityKey)
        let signed = PhoneHello.signedBytes(
            version: hello.version,
            macFingerprint: macFingerprint, phoneFingerprint: phoneFingerprint,
            macNonce: hello.nonce, phoneNonce: answer.nonce,
            macEphemeralKey: hello.ephemeralKey, phoneEphemeralKey: answer.ephemeralKey
        )
        guard isValid(signature: answer.signature, over: signed, identityKey: phoneIdentityKey) else {
            throw .invalidSignature
        }
        return try SecureChannel(
            role: .mac, ephemeralKey: ephemeralKey, peerEphemeralKey: answer.ephemeralKey,
            macNonce: hello.nonce, phoneNonce: answer.nonce,
            macFingerprint: macFingerprint, phoneFingerprint: phoneFingerprint
        )
    }

    static func randomNonce() -> [UInt8] {
        // SystemRandomNumberGenerator is the system's cryptographic source.
        var generator = SystemRandomNumberGenerator()
        return (0..<ChannelLimits.nonceLength).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }
}

/// The phone's side of the handshake.
public enum PhoneHandshake {
    public struct Accepted {
        /// The message to send back to the Mac.
        public let answer: PhoneHello
        public let channel: SecureChannel
        /// Which paired Mac opened this connection.
        public let macFingerprint: [UInt8]
    }

    /// Checks the Mac's message, then answers it.
    ///
    /// Nothing is signed for a Mac that is unknown, whose signature is
    /// wrong or whose timestamp is off: a stranger in Bluetooth range gets
    /// an error and no use of the phone's identity key.
    ///
    /// - Parameter pairedMacKey: the identity public key of the paired Mac
    ///   with this fingerprint, or nil if there is none.
    public static func accept(
        _ hello: MacHello,
        identity: any IdentitySigner,
        pairedMacKey: ([UInt8]) -> [UInt8]?,
        now: Date
    ) throws(ChannelError) -> Accepted {
        guard hello.version == ChannelLimits.version else { throw .malformed }
        guard let macIdentityKey = pairedMacKey(hello.macFingerprint),
              IdentityFingerprint.of(publicKey: macIdentityKey) == hello.macFingerprint
        else {
            throw .unknownPeer
        }
        let phoneFingerprint = IdentityFingerprint.of(publicKey: identity.publicKey)
        let signedByMac = MacHello.signedBytes(
            version: hello.version,
            macFingerprint: hello.macFingerprint, phoneFingerprint: phoneFingerprint,
            nonce: hello.nonce, ephemeralKey: hello.ephemeralKey, timestamp: hello.timestamp
        )
        guard isValid(signature: hello.signature, over: signedByMac, identityKey: macIdentityKey) else {
            throw .invalidSignature
        }
        // After the signature: an unsigned timestamp proves nothing.
        guard isWithinTolerance(hello.timestamp, of: now) else { throw .timestampOutOfWindow }

        let ephemeralKey = P256.KeyAgreement.PrivateKey()
        let ephemeralPublic = Array(ephemeralKey.publicKey.x963Representation)
        let nonce = MacHandshake.randomNonce()
        // Built first: a bad Mac ephemeral key is refused before signing.
        let channel = try SecureChannel(
            role: .phone, ephemeralKey: ephemeralKey, peerEphemeralKey: hello.ephemeralKey,
            macNonce: hello.nonce, phoneNonce: nonce,
            macFingerprint: hello.macFingerprint, phoneFingerprint: phoneFingerprint
        )
        let signature: [UInt8]
        do {
            signature = try identity.signature(for: PhoneHello.signedBytes(
                version: hello.version,
                macFingerprint: hello.macFingerprint, phoneFingerprint: phoneFingerprint,
                macNonce: hello.nonce, phoneNonce: nonce,
                macEphemeralKey: hello.ephemeralKey, phoneEphemeralKey: ephemeralPublic
            ))
        } catch {
            throw .invalidSignature
        }
        return Accepted(
            answer: PhoneHello(nonce: nonce, ephemeralKey: ephemeralPublic, signature: signature),
            channel: channel,
            macFingerprint: hello.macFingerprint
        )
    }
}

/// An open channel: seals the messages this side sends and opens the ones
/// it receives.
///
/// One key per direction, so a message can never be sent back to its
/// author. Each key counts its messages: the count is the AES-GCM nonce,
/// which therefore never repeats, and the receiver only accepts the next
/// count, so a message cannot be replayed, reordered or silently dropped.
public struct SecureChannel {
    enum Role {
        case mac
        case phone
    }

    /// Counter and timestamp, 8 bytes each. Sent in clear, authenticated.
    static let headerLength = 16
    static let tagLength = 16
    /// Longest message body, the same limit as the ssh-agent messages.
    public static let maxPlaintextLength = AgentLimits.maxMessageLength

    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sendCounter: UInt64
    private var receiveCounter: UInt64 = 0
    private var isClosed = false

    init(
        role: Role,
        ephemeralKey: P256.KeyAgreement.PrivateKey,
        peerEphemeralKey: [UInt8],
        macNonce: [UInt8],
        phoneNonce: [UInt8],
        macFingerprint: [UInt8],
        phoneFingerprint: [UInt8],
        firstSendCounter: UInt64 = 0
    ) throws(ChannelError) {
        let sharedSecret: SharedSecret
        do {
            // CryptoKit refuses a point that is not on the curve.
            let peerKey = try P256.KeyAgreement.PublicKey(x963Representation: peerEphemeralKey)
            sharedSecret = try ephemeralKey.sharedSecretFromKeyAgreement(with: peerKey)
        } catch {
            throw .malformed
        }

        func key(for direction: String) -> SymmetricKey {
            var info = WireWriter()
            info.writeString("SentryKey channel")
            info.writeByte(ChannelLimits.version)
            info.writeString(macFingerprint)
            info.writeString(phoneFingerprint)
            info.writeString(direction)
            return sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: Data(macNonce + phoneNonce),
                sharedInfo: Data(info.bytes),
                outputByteCount: 32
            )
        }
        let macToPhone = key(for: "Mac to phone")
        let phoneToMac = key(for: "phone to Mac")
        switch role {
        case .mac:
            sendKey = macToPhone
            receiveKey = phoneToMac
        case .phone:
            sendKey = phoneToMac
            receiveKey = macToPhone
        }
        sendCounter = firstSendCounter
    }

    /// Encrypts one message for the other side.
    public mutating func seal(_ plaintext: [UInt8], now: Date) throws(ChannelError) -> [UInt8] {
        guard !isClosed else { throw .closed }
        guard plaintext.count <= Self.maxPlaintextLength else { throw .messageTooLarge }
        // The last count is never used, so the counter cannot wrap and
        // reuse a nonce (ARCHITECTURE.md, Channel).
        guard sendCounter < UInt64.max else {
            isClosed = true
            throw .counterExhausted
        }
        var header = WireWriter()
        header.writeUInt64(sendCounter)
        header.writeUInt64(UInt64(max(0, now.timeIntervalSince1970)))

        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(
                Data(plaintext), using: sendKey,
                nonce: Self.nonce(for: sendCounter), authenticating: Data(header.bytes)
            )
        } catch {
            isClosed = true
            throw .authenticationFailed
        }
        sendCounter += 1
        return header.bytes + sealed.ciphertext + sealed.tag
    }

    /// Checks and decrypts one received message. After any failure the
    /// channel is closed: the caller drops the connection, and a new one
    /// starts with a new handshake.
    public mutating func open(_ message: [UInt8], now: Date) throws(ChannelError) -> [UInt8] {
        guard !isClosed else { throw .closed }
        do {
            return try openChecked(message, now: now)
        } catch {
            isClosed = true
            throw error
        }
    }

    private mutating func openChecked(_ message: [UInt8], now: Date) throws(ChannelError) -> [UInt8] {
        guard message.count >= Self.headerLength + Self.tagLength else { throw .malformed }
        guard message.count <= Self.headerLength + Self.maxPlaintextLength + Self.tagLength else {
            throw .messageTooLarge
        }
        let header = Array(message[..<Self.headerLength])
        var reader = WireReader(header)
        guard let counter = try? reader.readUInt64(), let timestamp = try? reader.readUInt64() else {
            throw .malformed
        }
        guard counter == receiveCounter else { throw .unexpectedCounter }

        let body = message[Self.headerLength...]
        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(
                nonce: Self.nonce(for: counter),
                ciphertext: Data(body.dropLast(Self.tagLength)),
                tag: Data(body.suffix(Self.tagLength))
            )
            plaintext = try AES.GCM.open(box, using: receiveKey, authenticating: Data(header))
        } catch {
            throw .authenticationFailed
        }
        // After authentication: an unauthenticated timestamp proves nothing.
        guard isWithinTolerance(timestamp, of: now) else { throw .timestampOutOfWindow }
        receiveCounter += 1
        return Array(plaintext)
    }

    /// The 96-bit AES-GCM nonce for a count: four zero bytes, then the
    /// count. Unique per key because each key has its own counter.
    private static func nonce(for counter: UInt64) throws -> AES.GCM.Nonce {
        var bytes = WireWriter()
        bytes.writeUInt32(0)
        bytes.writeUInt64(counter)
        return try AES.GCM.Nonce(data: Data(bytes.bytes))
    }
}

private func isValid(signature: [UInt8], over message: [UInt8], identityKey: [UInt8]) -> Bool {
    guard let key = try? P256.Signing.PublicKey(x963Representation: identityKey),
          let parsed = try? P256.Signing.ECDSASignature(rawRepresentation: signature)
    else {
        return false
    }
    return key.isValidSignature(parsed, for: Data(message))
}

private func isWithinTolerance(_ timestamp: UInt64, of now: Date) -> Bool {
    let current = UInt64(max(0, now.timeIntervalSince1970))
    let distance = timestamp > current ? timestamp - current : current - timestamp
    return distance <= ChannelLimits.clockToleranceSeconds
}
#endif
