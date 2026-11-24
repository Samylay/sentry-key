/// The two handshake messages that open the secure channel on each
/// Bluetooth connection (ARCHITECTURE.md, Channel), and the exact bytes
/// each side signs.
///
/// This file only encodes and parses. The cryptography is in
/// `SecureChannel.swift`.
///
/// NEEDS LINE-BY-LINE HUMAN REVIEW: `parse` reads untrusted input, from any
/// device in Bluetooth range, before anyone is authenticated.

public enum ChannelLimits {
    /// The only protocol version. A peer announcing another one is refused:
    /// there is no negotiation, so nothing to downgrade.
    public static let version: UInt8 = 1
    /// Random value each side contributes to a connection.
    public static let nonceLength = 32
    /// SHA-256 of an identity public key.
    public static let fingerprintLength = 32
    /// Uncompressed P-256 point: 0x04, then X and Y.
    public static let publicKeyLength = 65
    /// Raw ECDSA P-256 signature: r then s.
    public static let signatureLength = 64
    /// How far a timestamp may be from the receiver's clock, in seconds,
    /// either way. Wide enough for two clocks that are not synchronized to
    /// the second, narrow enough to bound how long a recorded message stays
    /// usable. A first guess, not a measured value.
    public static let clockToleranceSeconds: UInt64 = 300
}

/// Mac to phone, first message of a connection.
public struct MacHello: Equatable, Sendable {
    public let version: UInt8
    /// Which Mac this is: a phone can be paired with several.
    public let macFingerprint: [UInt8]
    public let nonce: [UInt8]
    /// The Mac's ephemeral key for this connection only.
    public let ephemeralKey: [UInt8]
    /// Seconds since 1970, by the Mac's clock.
    public let timestamp: UInt64
    /// By the Mac identity key, over `MacHello.signedBytes`.
    public let signature: [UInt8]

    public init(
        version: UInt8, macFingerprint: [UInt8], nonce: [UInt8],
        ephemeralKey: [UInt8], timestamp: UInt64, signature: [UInt8]
    ) {
        self.version = version
        self.macFingerprint = macFingerprint
        self.nonce = nonce
        self.ephemeralKey = ephemeralKey
        self.timestamp = timestamp
        self.signature = signature
    }

    /// What the Mac identity key signs. The phone's fingerprint is included
    /// so a message meant for one phone is useless against another.
    public static func signedBytes(
        version: UInt8, macFingerprint: [UInt8], phoneFingerprint: [UInt8],
        nonce: [UInt8], ephemeralKey: [UInt8], timestamp: UInt64
    ) -> [UInt8] {
        var writer = WireWriter()
        // A label of its own, so this signature can never be taken for the
        // phone's, or for anything else these keys might sign.
        writer.writeString("SentryKey handshake: Mac")
        writer.writeByte(version)
        writer.writeString(macFingerprint)
        writer.writeString(phoneFingerprint)
        writer.writeString(nonce)
        writer.writeString(ephemeralKey)
        writer.writeUInt64(timestamp)
        return writer.bytes
    }

    public func encoded() -> [UInt8] {
        var writer = WireWriter()
        writer.writeByte(version)
        writer.writeString(macFingerprint)
        writer.writeString(nonce)
        writer.writeString(ephemeralKey)
        writer.writeUInt64(timestamp)
        writer.writeString(signature)
        return writer.bytes
    }

    public static func parse(body: [UInt8]) throws -> MacHello {
        var reader = WireReader(body)
        let version = try reader.readByte()
        // Checked first: the rest of the layout belongs to this version.
        guard version == ChannelLimits.version else {
            throw WireError.unexpectedValue("channel version \(version)")
        }
        let hello = MacHello(
            version: version,
            macFingerprint: try reader.readFixed(ChannelLimits.fingerprintLength, "fingerprint"),
            nonce: try reader.readFixed(ChannelLimits.nonceLength, "nonce"),
            ephemeralKey: try reader.readFixed(ChannelLimits.publicKeyLength, "ephemeral key"),
            timestamp: try reader.readUInt64(),
            signature: try reader.readFixed(ChannelLimits.signatureLength, "signature")
        )
        try reader.expectEnd()
        return hello
    }
}

/// Phone to Mac, the answer to `MacHello`.
public struct PhoneHello: Equatable, Sendable {
    public let nonce: [UInt8]
    /// The phone's ephemeral key for this connection only.
    public let ephemeralKey: [UInt8]
    /// By the phone identity key, over `PhoneHello.signedBytes`.
    public let signature: [UInt8]

    public init(nonce: [UInt8], ephemeralKey: [UInt8], signature: [UInt8]) {
        self.nonce = nonce
        self.ephemeralKey = ephemeralKey
        self.signature = signature
    }

    /// What the phone identity key signs: everything both sides sent. It
    /// covers the Mac's nonce and ephemeral key, so an answer recorded on
    /// one connection does not verify on another.
    public static func signedBytes(
        version: UInt8, macFingerprint: [UInt8], phoneFingerprint: [UInt8],
        macNonce: [UInt8], phoneNonce: [UInt8],
        macEphemeralKey: [UInt8], phoneEphemeralKey: [UInt8]
    ) -> [UInt8] {
        var writer = WireWriter()
        writer.writeString("SentryKey handshake: phone")
        writer.writeByte(version)
        writer.writeString(macFingerprint)
        writer.writeString(phoneFingerprint)
        writer.writeString(macNonce)
        writer.writeString(phoneNonce)
        writer.writeString(macEphemeralKey)
        writer.writeString(phoneEphemeralKey)
        return writer.bytes
    }

    public func encoded() -> [UInt8] {
        var writer = WireWriter()
        writer.writeString(nonce)
        writer.writeString(ephemeralKey)
        writer.writeString(signature)
        return writer.bytes
    }

    public static func parse(body: [UInt8]) throws -> PhoneHello {
        var reader = WireReader(body)
        let hello = PhoneHello(
            nonce: try reader.readFixed(ChannelLimits.nonceLength, "nonce"),
            ephemeralKey: try reader.readFixed(ChannelLimits.publicKeyLength, "ephemeral key"),
            signature: try reader.readFixed(ChannelLimits.signatureLength, "signature")
        )
        try reader.expectEnd()
        return hello
    }
}

extension WireReader {
    /// Reads a `string` that must have exactly `length` bytes.
    mutating func readFixed(_ length: Int, _ name: String) throws -> [UInt8] {
        let value = try readString(maxLength: length)
        guard value.count == length else {
            throw WireError.unexpectedValue("\(name) length")
        }
        return value
    }

    mutating func readUInt64() throws -> UInt64 {
        let high = UInt64(try readUInt32())
        let low = UInt64(try readUInt32())
        return high << 32 | low
    }
}

extension WireWriter {
    mutating func writeUInt64(_ value: UInt64) {
        writeUInt32(UInt32(truncatingIfNeeded: value >> 32))
        writeUInt32(UInt32(truncatingIfNeeded: value))
    }
}
