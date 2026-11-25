// CryptoKit does not exist on Linux: there, this file compiles to nothing.
#if canImport(CryptoKit)
import CryptoKit
import Foundation

// Pairing (ARCHITECTURE.md, Pairing). Once, with both devices in hand:
//
//   Mac                                         phone
//    | shows a QR code: its identity key          |
//    |   and a one-time secret                    |
//    |  ~~~~~~~~~~~~~~ camera ~~~~~~~~~~~~~~~~~~> | keeps the Mac's key,
//    |                                            |   creates its two keys
//    |   PairingRequest: both phone public keys,  |
//    |   HMAC with the secret over all the keys   |
//    |<-------------------------------------------|
//    | checks the HMAC, records the keys          |
//    |   PairingConfirmation: HMAC, Mac's label   |
//    |------------------------------------------->| checks it: paired
//
// The QR code is the only thing that does not cross the radio, so it is
// what the trust rests on. It gives the phone the Mac's real key, and the
// secret lets the Mac tell the phone that scanned it from any other device
// in range: only that phone can compute the HMAC.
//
// CryptoKit only: HMAC-SHA256, compared in constant time.
//
// NEEDS LINE-BY-LINE HUMAN REVIEW (crypto code).

public enum PairingError: Error, Equatable {
    /// Not a SentryKey pairing code.
    case invalidCode
    /// The QR code was shown too long ago.
    case expired
    /// A phone was already paired with this QR code.
    case alreadyUsed
    /// The message was not made with the secret of this QR code.
    case invalidTag
    /// A key in the message is not a valid P-256 key, or the two phone
    /// keys are the same key.
    case invalidKey
}

/// A phone the Mac has paired with.
public struct PairedPhone: Equatable, Sendable {
    public let identityKey: [UInt8]
    public let sshKeyBlob: [UInt8]

    public init(identityKey: [UInt8], sshKeyBlob: [UInt8]) {
        self.identityKey = identityKey
        self.sshKeyBlob = sshKeyBlob
    }
}

/// The Mac's side of one pairing: one QR code, good for one phone.
public struct MacPairing {
    public let offer: PairingOffer
    private let expiry: Date
    private var isUsed = false

    public init(macIdentityKey: [UInt8], now: Date) {
        // SymmetricKey draws from the system's cryptographic generator.
        let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) }
        offer = PairingOffer(macIdentityKey: macIdentityKey, secret: secret)
        expiry = now.addingTimeInterval(PairingLimits.offerLifetimeSeconds)
    }

    /// Checks the phone's request. On success the QR code is spent, and the
    /// confirmation is to be sent back.
    ///
    /// A request with a wrong tag does not spend the code: otherwise any
    /// device in range could cancel a pairing by answering first with
    /// garbage. The secret is too long to be guessed by trying.
    public mutating func accept(
        _ request: PairingRequest, now: Date
    ) throws(PairingError) -> (phone: PairedPhone, confirmation: PairingConfirmation) {
        guard !isUsed else { throw .alreadyUsed }
        guard now < expiry else { throw .expired }

        let key = SymmetricKey(data: offer.secret)
        let expected = PairingTranscript.bytes(
            side: .phone, macIdentityKey: offer.macIdentityKey,
            phoneIdentityKey: request.phoneIdentityKey, sshKeyBlob: request.sshKeyBlob
        )
        guard HMAC<SHA256>.isValidAuthenticationCode(request.tag, authenticating: expected, using: key) else {
            throw .invalidTag
        }
        try checkPhoneKeys(identityKey: request.phoneIdentityKey, sshKeyBlob: request.sshKeyBlob)

        isUsed = true
        let confirmation = HMAC<SHA256>.authenticationCode(
            for: PairingTranscript.bytes(
                side: .mac, macIdentityKey: offer.macIdentityKey,
                phoneIdentityKey: request.phoneIdentityKey, sshKeyBlob: request.sshKeyBlob
            ),
            using: key
        )
        return (
            PairedPhone(identityKey: request.phoneIdentityKey, sshKeyBlob: request.sshKeyBlob),
            PairingConfirmation(tag: Array(confirmation))
        )
    }
}

/// The phone's side of one pairing, from the QR code it scanned.
public struct PhonePairing {
    /// The Mac's identity key, read from the QR code.
    public let macIdentityKey: [UInt8]
    private let secret: [UInt8]
    private var sent: (phoneIdentityKey: [UInt8], sshKeyBlob: [UInt8])?

    public init(code: String) throws(PairingError) {
        guard let offer = try? PairingOffer.parse(code: code),
              (try? P256.Signing.PublicKey(x963Representation: offer.macIdentityKey)) != nil
        else {
            throw .invalidCode
        }
        macIdentityKey = offer.macIdentityKey
        secret = offer.secret
    }

    /// Builds the message that gives the Mac this phone's public keys.
    public mutating func request(
        phoneIdentityKey: [UInt8], sshKeyBlob: [UInt8]
    ) throws(PairingError) -> PairingRequest {
        try checkPhoneKeys(identityKey: phoneIdentityKey, sshKeyBlob: sshKeyBlob)
        let tag = HMAC<SHA256>.authenticationCode(
            for: PairingTranscript.bytes(
                side: .phone, macIdentityKey: macIdentityKey,
                phoneIdentityKey: phoneIdentityKey, sshKeyBlob: sshKeyBlob
            ),
            using: SymmetricKey(data: secret)
        )
        sent = (phoneIdentityKey, sshKeyBlob)
        return PairingRequest(phoneIdentityKey: phoneIdentityKey, sshKeyBlob: sshKeyBlob, tag: Array(tag))
    }

    /// Checks the Mac's confirmation. Only then is the phone paired: until
    /// it arrives, the Mac may not have recorded anything.
    public func confirm(_ confirmation: PairingConfirmation) throws(PairingError) {
        guard let sent else { throw .invalidTag }
        let expected = PairingTranscript.bytes(
            side: .mac, macIdentityKey: macIdentityKey,
            phoneIdentityKey: sent.phoneIdentityKey, sshKeyBlob: sent.sshKeyBlob
        )
        guard HMAC<SHA256>.isValidAuthenticationCode(
            confirmation.tag, authenticating: expected, using: SymmetricKey(data: secret)
        ) else {
            throw .invalidTag
        }
    }
}

/// Both keys must be real P-256 keys, and two different ones: the
/// architecture forbids one key in two roles.
private func checkPhoneKeys(identityKey: [UInt8], sshKeyBlob: [UInt8]) throws(PairingError) {
    guard (try? P256.Signing.PublicKey(x963Representation: identityKey)) != nil,
          let sshPoint = try? ECDSAP256.x963Point(fromPublicKeyBlob: sshKeyBlob),
          (try? P256.Signing.PublicKey(x963Representation: sshPoint)) != nil,
          sshPoint != identityKey
    else {
        throw .invalidKey
    }
}
#endif
