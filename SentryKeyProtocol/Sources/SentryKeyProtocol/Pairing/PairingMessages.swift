import Foundation

/// The messages of pairing (ARCHITECTURE.md, Pairing): what the QR code
/// carries, what the phone sends back, and what the Mac confirms.
///
/// This file only encodes and parses. The cryptography is in `Pairing.swift`.
///
/// NEEDS LINE-BY-LINE HUMAN REVIEW: `parse` reads a QR code anyone could
/// show to the camera, and messages from any device in Bluetooth range.

public enum PairingLimits {
    public static let version: UInt8 = 1
    /// Random secret shown in the QR code. Long enough that guessing it,
    /// online or from a recorded exchange, is not a concern.
    public static let secretLength = 32
    /// HMAC-SHA256 output.
    public static let tagLength = 32
    /// A QR code holding the offer is about 150 characters.
    public static let maxCodeLength = 512
    /// How long the Mac accepts an answer to a QR code it showed. Long
    /// enough to pick up the phone and scan, short enough that a photo of
    /// the screen is useless later. A first guess, not a measured value.
    public static let offerLifetimeSeconds: TimeInterval = 120
}

/// What the Mac shows as a QR code: its identity key, and a secret only a
/// device that saw the screen can know.
public struct PairingOffer: Equatable, Sendable {
    /// Starts every SentryKey pairing code, so any other QR code is
    /// refused before its content is looked at.
    public static let prefix = "SENTRYKEY-PAIR:"

    public let macIdentityKey: [UInt8]
    public let secret: [UInt8]

    public init(macIdentityKey: [UInt8], secret: [UInt8]) {
        self.macIdentityKey = macIdentityKey
        self.secret = secret
    }

    /// The text of the QR code.
    public var code: String {
        var writer = WireWriter()
        writer.writeByte(PairingLimits.version)
        writer.writeString(macIdentityKey)
        writer.writeString(secret)
        return Self.prefix + Data(writer.bytes).base64EncodedString()
    }

    public static func parse(code: String) throws -> PairingOffer {
        guard code.utf8.count <= PairingLimits.maxCodeLength else {
            throw WireError.lengthTooLarge(code.utf8.count)
        }
        guard code.hasPrefix(prefix), let data = Data(base64Encoded: String(code.dropFirst(prefix.count))) else {
            throw WireError.unexpectedValue("pairing code")
        }
        var reader = WireReader(data)
        let version = try reader.readByte()
        guard version == PairingLimits.version else {
            throw WireError.unexpectedValue("pairing version \(version)")
        }
        let offer = PairingOffer(
            macIdentityKey: try reader.readFixed(ChannelLimits.publicKeyLength, "Mac identity key"),
            secret: try reader.readFixed(PairingLimits.secretLength, "pairing secret")
        )
        try reader.expectEnd()
        return offer
    }
}

/// Phone to Mac: the phone's two public keys, with proof that they come
/// from the device that scanned the QR code.
public struct PairingRequest: Equatable, Sendable {
    public let phoneIdentityKey: [UInt8]
    /// The SSH public key blob, the one to install on servers.
    public let sshKeyBlob: [UInt8]
    /// HMAC over `PairingTranscript.bytes`, keyed with the pairing secret.
    public let tag: [UInt8]

    public init(phoneIdentityKey: [UInt8], sshKeyBlob: [UInt8], tag: [UInt8]) {
        self.phoneIdentityKey = phoneIdentityKey
        self.sshKeyBlob = sshKeyBlob
        self.tag = tag
    }

    public func encoded() -> [UInt8] {
        var writer = WireWriter()
        writer.writeString(phoneIdentityKey)
        writer.writeString(sshKeyBlob)
        writer.writeString(tag)
        return writer.bytes
    }

    public static func parse(body: [UInt8]) throws -> PairingRequest {
        var reader = WireReader(body)
        let request = PairingRequest(
            phoneIdentityKey: try reader.readFixed(ChannelLimits.publicKeyLength, "phone identity key"),
            sshKeyBlob: try reader.readString(maxLength: AgentLimits.maxKeyLength),
            tag: try reader.readFixed(PairingLimits.tagLength, "pairing tag")
        )
        try reader.expectEnd()
        return request
    }
}

/// Mac to phone: the Mac received the keys and recorded them.
public struct PairingConfirmation: Equatable, Sendable {
    /// HMAC over the same transcript, with the Mac's label.
    public let tag: [UInt8]

    public init(tag: [UInt8]) {
        self.tag = tag
    }

    public func encoded() -> [UInt8] {
        var writer = WireWriter()
        writer.writeString(tag)
        return writer.bytes
    }

    public static func parse(body: [UInt8]) throws -> PairingConfirmation {
        var reader = WireReader(body)
        let confirmation = PairingConfirmation(tag: try reader.readFixed(PairingLimits.tagLength, "pairing tag"))
        try reader.expectEnd()
        return confirmation
    }
}

/// What both tags authenticate: every key exchanged, so swapping any one of
/// them breaks the pairing.
public enum PairingTranscript {
    public enum Side: String, Sendable {
        case phone = "SentryKey pairing: phone"
        case mac = "SentryKey pairing: Mac"
    }

    public static func bytes(side: Side, macIdentityKey: [UInt8], phoneIdentityKey: [UInt8], sshKeyBlob: [UInt8]) -> [UInt8] {
        var writer = WireWriter()
        // A label per side: the Mac's tag can never be replayed as the
        // phone's, or the reverse.
        writer.writeString(side.rawValue)
        writer.writeByte(PairingLimits.version)
        writer.writeString(macIdentityKey)
        writer.writeString(phoneIdentityKey)
        writer.writeString(sshKeyBlob)
        return writer.bytes
    }
}
