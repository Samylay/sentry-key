import Testing
@testable import SentryKeyProtocol

@Suite("SSH wire types")
struct WireTests {
    @Test func uint32RoundTrip() throws {
        var writer = WireWriter()
        writer.writeUInt32(0xDEAD_BEEF)
        #expect(writer.bytes == [0xDE, 0xAD, 0xBE, 0xEF])
        var reader = WireReader(writer.bytes)
        #expect(try reader.readUInt32() == 0xDEAD_BEEF)
        try reader.expectEnd()
    }

    @Test func stringRoundTrip() throws {
        var writer = WireWriter()
        writer.writeString("ssh-connection")
        var reader = WireReader(writer.bytes)
        #expect(try reader.readUTF8String(maxLength: 64) == "ssh-connection")
    }

    @Test func truncatedUInt32IsRejected() {
        var reader = WireReader([0, 0, 1])
        #expect(throws: WireError.truncated) { try reader.readUInt32() }
    }

    @Test func stringLongerThanInputIsRejected() {
        var reader = WireReader([0, 0, 0, 5, 1, 2])
        #expect(throws: WireError.truncated) { try reader.readString(maxLength: 100) }
    }

    @Test func stringOverLimitIsRejectedBeforeReading() {
        // Claims 4 GiB: must fail on the limit, not try to read or allocate.
        var reader = WireReader([0xFF, 0xFF, 0xFF, 0xFF])
        #expect(throws: WireError.lengthTooLarge(0xFFFF_FFFF)) { try reader.readString(maxLength: 1024) }
    }

    @Test func booleanOtherThanZeroOrOneIsRejected() {
        var reader = WireReader([2])
        #expect(throws: WireError.invalidBoolean(2)) { try reader.readBool() }
    }

    @Test func invalidUTF8IsRejected() {
        var reader = WireReader([0, 0, 0, 1, 0xFF])
        #expect(throws: WireError.invalidUTF8) { try reader.readUTF8String(maxLength: 10) }
    }

    @Test func trailingBytesAreRejected() throws {
        var reader = WireReader([1, 9])
        _ = try reader.readByte()
        #expect(throws: WireError.trailingBytes(1)) { try reader.expectEnd() }
    }

    @Test(arguments: [
        // (magnitude, expected mpint encoding)
        ([UInt8](), [UInt8]([0, 0, 0, 0])),
        ([0, 0, 0], [0, 0, 0, 0]),
        ([0x7F], [0, 0, 0, 1, 0x7F]),
        ([0x00, 0x7F], [0, 0, 0, 1, 0x7F]),
        ([0x80], [0, 0, 0, 2, 0x00, 0x80]),
        ([0x00, 0x00, 0xFF, 0x01], [0, 0, 0, 3, 0x00, 0xFF, 0x01]),
    ])
    func mpintEncoding(magnitude: [UInt8], expected: [UInt8]) {
        var writer = WireWriter()
        writer.writeMPInt(unsignedBigEndian: magnitude)
        #expect(writer.bytes == expected)
    }
}
