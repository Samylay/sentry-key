#if canImport(CryptoKit)
import CryptoKit
import Foundation
import Testing
@testable import SentryKeyProtocol

private func identityKey() -> [UInt8] {
    Array(P256.Signing.PrivateKey().publicKey.x963Representation)
}

private func sshKeyBlob() throws -> [UInt8] {
    try ECDSAP256.publicKeyBlob(x963Point: identityKey())
}

@Suite("Pairing")
struct PairingTests {
    private let macKey = identityKey()
    private let phoneKey = identityKey()
    private let sshKey: [UInt8]
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        sshKey = try sshKeyBlob()
    }

    /// The phone scans the Mac's code and builds its request.
    private func scan(_ mac: MacPairing) throws -> (phone: PhonePairing, request: PairingRequest) {
        var phone = try PhonePairing(code: mac.offer.code)
        let request = try phone.request(phoneIdentityKey: phoneKey, sshKeyBlob: sshKey)
        return (phone, request)
    }

    @Test func pairsAPhoneThatScannedTheCode() throws {
        var mac = MacPairing(macIdentityKey: macKey, now: now)
        let (phone, request) = try scan(mac)

        let accepted = try mac.accept(request, now: now)
        try phone.confirm(accepted.confirmation)

        #expect(accepted.phone == PairedPhone(identityKey: phoneKey, sshKeyBlob: sshKey))
        #expect(phone.macIdentityKey == macKey)
    }

    @Test func requestSurvivesTheWire() throws {
        var mac = MacPairing(macIdentityKey: macKey, now: now)
        let (phone, request) = try scan(mac)

        let accepted = try mac.accept(try PairingRequest.parse(body: request.encoded()), now: now)
        try phone.confirm(try PairingConfirmation.parse(body: accepted.confirmation.encoded()))
    }

    @Test func givesEveryCodeItsOwnSecret() {
        let first = MacPairing(macIdentityKey: macKey, now: now)
        let second = MacPairing(macIdentityKey: macKey, now: now)

        #expect(first.offer.secret != second.offer.secret)
        #expect(first.offer.secret.count == PairingLimits.secretLength)
    }

    @Test func refusesAPhoneThatDidNotSeeTheCode() throws {
        var mac = MacPairing(macIdentityKey: macKey, now: now)
        // A device in range knows the Mac's key but must guess the secret.
        let guessed = PairingOffer(macIdentityKey: macKey, secret: [UInt8](repeating: 0, count: PairingLimits.secretLength))
        var stranger = try PhonePairing(code: guessed.code)
        let request = try stranger.request(phoneIdentityKey: phoneKey, sshKeyBlob: sshKey)

        #expect(throws: PairingError.invalidTag) { try mac.accept(request, now: now) }
    }

    @Test func refusesKeysSwappedOnTheWay() throws {
        var mac = MacPairing(macIdentityKey: macKey, now: now)
        let (_, request) = try scan(mac)

        let swappedIdentity = PairingRequest(phoneIdentityKey: identityKey(), sshKeyBlob: request.sshKeyBlob, tag: request.tag)
        #expect(throws: PairingError.invalidTag) { try mac.accept(swappedIdentity, now: now) }

        let swappedSSHKey = PairingRequest(phoneIdentityKey: request.phoneIdentityKey, sshKeyBlob: try sshKeyBlob(), tag: request.tag)
        #expect(throws: PairingError.invalidTag) { try mac.accept(swappedSSHKey, now: now) }
    }

    @Test func refusesAnyAlteredByteOfTheRequest() throws {
        var mac = MacPairing(macIdentityKey: macKey, now: now)
        let (_, request) = try scan(mac)
        let original = request.encoded()

        for index in original.indices {
            var altered = original
            altered[index] ^= 0x01
            #expect(throws: (any Error).self, "byte \(index)") {
                _ = try mac.accept(try PairingRequest.parse(body: altered), now: now)
            }
        }
        // None of those attempts spent the code.
        _ = try mac.accept(request, now: now)
    }

    @Test func pairsOnlyOnePhonePerCode() throws {
        var mac = MacPairing(macIdentityKey: macKey, now: now)
        let (_, request) = try scan(mac)
        _ = try mac.accept(request, now: now)

        #expect(throws: PairingError.alreadyUsed) { try mac.accept(request, now: now) }
    }

    @Test func refusesACodeShownTooLongAgo() throws {
        var mac = MacPairing(macIdentityKey: macKey, now: now)
        let (_, request) = try scan(mac)

        #expect(throws: PairingError.expired) {
            try mac.accept(request, now: now.addingTimeInterval(PairingLimits.offerLifetimeSeconds))
        }
    }

    @Test func refusesOneKeyUsedForBothRoles() throws {
        let mac = MacPairing(macIdentityKey: macKey, now: now)
        var phone = try PhonePairing(code: mac.offer.code)
        let sameKeyAsSSH = try ECDSAP256.publicKeyBlob(x963Point: phoneKey)

        #expect(throws: PairingError.invalidKey) {
            try phone.request(phoneIdentityKey: phoneKey, sshKeyBlob: sameKeyAsSSH)
        }
    }

    @Test func macRefusesAKeyThatIsNotOnTheCurve() throws {
        var mac = MacPairing(macIdentityKey: macKey, now: now)
        let badKey = [0x04] + [UInt8](repeating: 0xFF, count: ChannelLimits.publicKeyLength - 1)
        // Made with the real secret, so only the key check can stop it.
        let tag = HMAC<SHA256>.authenticationCode(
            for: PairingTranscript.bytes(side: .phone, macIdentityKey: macKey, phoneIdentityKey: badKey, sshKeyBlob: sshKey),
            using: SymmetricKey(data: mac.offer.secret)
        )
        let request = PairingRequest(phoneIdentityKey: badKey, sshKeyBlob: sshKey, tag: Array(tag))

        #expect(throws: PairingError.invalidKey) { try mac.accept(request, now: now) }
    }

    @Test func phoneRefusesAConfirmationFromSomeoneWithoutTheSecret() throws {
        let mac = MacPairing(macIdentityKey: macKey, now: now)
        let (phone, _) = try scan(mac)

        let forged = PairingConfirmation(tag: [UInt8](repeating: 0, count: PairingLimits.tagLength))

        #expect(throws: PairingError.invalidTag) { try phone.confirm(forged) }
    }

    @Test func phoneDoesNotTakeItsOwnRequestForTheConfirmation() throws {
        let mac = MacPairing(macIdentityKey: macKey, now: now)
        let (phone, request) = try scan(mac)

        // The phone's own tag, sent back to it.
        #expect(throws: PairingError.invalidTag) { try phone.confirm(PairingConfirmation(tag: request.tag)) }
    }

    @Test func phoneRefusesAConfirmationBeforeItAskedAnything() throws {
        let mac = MacPairing(macIdentityKey: macKey, now: now)
        let phone = try PhonePairing(code: mac.offer.code)

        #expect(throws: PairingError.invalidTag) {
            try phone.confirm(PairingConfirmation(tag: [UInt8](repeating: 0, count: PairingLimits.tagLength)))
        }
    }

    @Test(arguments: [
        "",
        "https://example.com",
        "SENTRYKEY-PAIR:",
        "SENTRYKEY-PAIR:not base64 at all",
        "sentrykey-pair:AAAA",
        PairingOffer.prefix + String(repeating: "A", count: PairingLimits.maxCodeLength),
    ])
    func refusesACodeThatIsNotAPairingCode(code: String) {
        #expect(throws: PairingError.invalidCode) { try PhonePairing(code: code) }
    }

    @Test func refusesACodeFromAnotherVersion() throws {
        var writer = WireWriter()
        writer.writeByte(2)
        writer.writeString(macKey)
        writer.writeString([UInt8](repeating: 1, count: PairingLimits.secretLength))
        let code = PairingOffer.prefix + Data(writer.bytes).base64EncodedString()

        #expect(throws: PairingError.invalidCode) { try PhonePairing(code: code) }
    }

    @Test func refusesACodeWhoseMacKeyIsNotAKey() {
        let badKey = [0x04] + [UInt8](repeating: 0xFF, count: ChannelLimits.publicKeyLength - 1)
        let offer = PairingOffer(macIdentityKey: badKey, secret: [UInt8](repeating: 1, count: PairingLimits.secretLength))

        #expect(throws: PairingError.invalidCode) { try PhonePairing(code: offer.code) }
    }

    @Test func codeFitsInAQRCode() {
        let mac = MacPairing(macIdentityKey: macKey, now: now)

        #expect(mac.offer.code.utf8.count <= PairingLimits.maxCodeLength)
        #expect(mac.offer.code.hasPrefix(PairingOffer.prefix))
    }
}
#endif
