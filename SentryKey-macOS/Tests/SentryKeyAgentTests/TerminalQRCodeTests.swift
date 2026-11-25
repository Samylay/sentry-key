import SentryKeyBluetooth
import SentryKeyProtocol
import Testing

@Suite("Pairing code drawn in a terminal")
struct TerminalQRCodeTests {
    private let code = PairingOffer(
        macIdentityKey: [UInt8](repeating: 4, count: ChannelLimits.publicKeyLength),
        secret: [UInt8](repeating: 7, count: PairingLimits.secretLength)
    ).code

    @Test func drawsASquareCodeWithALightMargin() throws {
        let modules = try #require(TerminalQRCode.modules(for: code))

        #expect(modules.count > 21)
        #expect(modules.allSatisfy { $0.count == modules.count })
        // The margin: nothing dark on the outer two rows and columns.
        for row in modules.prefix(2) + modules.suffix(2) {
            #expect(!row.contains(true))
        }
        #expect(modules.allSatisfy { !$0.prefix(2).contains(true) && !$0.suffix(2).contains(true) })
        #expect(modules.contains { $0.contains(true) })
    }

    @Test func drawsDifferentCodesForDifferentTexts() {
        #expect(TerminalQRCode.modules(for: code) != TerminalQRCode.modules(for: code + "x"))
    }

    @Test func drawsOneLineOfTextPerRow() throws {
        let modules = try #require(TerminalQRCode.modules(for: code))
        let lines = try #require(TerminalQRCode.lines(for: code))

        #expect(lines.count == modules.count)
    }
}
