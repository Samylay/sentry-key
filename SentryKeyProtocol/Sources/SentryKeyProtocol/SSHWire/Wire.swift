import Foundation

/// Errors raised while decoding untrusted bytes. Any of them means the
/// message is rejected as a whole.
public enum WireError: Error, Equatable {
    /// The input ended before a field was complete.
    case truncated
    /// A length field exceeds the limit given by the caller.
    case lengthTooLarge(Int)
    /// Bytes are left after the last expected field.
    case trailingBytes(Int)
    /// A boolean byte other than 0 or 1.
    case invalidBoolean(UInt8)
    /// A string field is not valid UTF-8.
    case invalidUTF8
    /// A field has a well-formed but unexpected value, such as the wrong algorithm name.
    case unexpectedValue(String)
}

/// Reads SSH wire types (RFC 4251, section 5) from untrusted bytes.
///
/// Every read checks bounds first, and every variable-length read takes a
/// maximum length that is checked before any memory is allocated.
public struct WireReader {
    private let bytes: [UInt8]
    public private(set) var offset = 0

    public init(_ bytes: some Collection<UInt8>) {
        self.bytes = Array(bytes)
    }

    /// Number of bytes not read yet.
    public var remaining: Int { bytes.count - offset }

    public mutating func readByte() throws -> UInt8 {
        guard remaining >= 1 else { throw WireError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    /// Reads a `boolean`. RFC 4251 lets readers treat any non-zero value as
    /// true; we reject values other than 0 and 1 so malformed input fails early.
    public mutating func readBool() throws -> Bool {
        let value = try readByte()
        switch value {
        case 0: return false
        case 1: return true
        default: throw WireError.invalidBoolean(value)
        }
    }

    public mutating func readUInt32() throws -> UInt32 {
        guard remaining >= 4 else { throw WireError.truncated }
        defer { offset += 4 }
        return bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// Reads a `string`: a uint32 length, then that many bytes.
    public mutating func readString(maxLength: Int) throws -> [UInt8] {
        let length = Int(try readUInt32())
        guard length <= maxLength else { throw WireError.lengthTooLarge(length) }
        guard remaining >= length else { throw WireError.truncated }
        defer { offset += length }
        return Array(bytes[offset..<offset + length])
    }

    /// Reads a `string` and decodes it as UTF-8.
    public mutating func readUTF8String(maxLength: Int) throws -> String {
        let raw = try readString(maxLength: maxLength)
        guard let text = String(bytes: raw, encoding: .utf8) else { throw WireError.invalidUTF8 }
        return text
    }

    /// Reads all remaining bytes.
    public mutating func readRest() -> [UInt8] {
        defer { offset = bytes.count }
        return Array(bytes[offset...])
    }

    /// Fails if any byte is left. Call it after the last field so that
    /// appended data is never silently ignored.
    public func expectEnd() throws {
        guard remaining == 0 else { throw WireError.trailingBytes(remaining) }
    }
}

/// Writes SSH wire types (RFC 4251, section 5).
public struct WireWriter {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    public mutating func writeByte(_ value: UInt8) {
        bytes.append(value)
    }

    public mutating func writeBool(_ value: Bool) {
        bytes.append(value ? 1 : 0)
    }

    public mutating func writeUInt32(_ value: UInt32) {
        bytes.append(contentsOf: [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ])
    }

    /// Writes a `string`: a uint32 length, then the bytes.
    public mutating func writeString(_ value: some Collection<UInt8>) {
        precondition(value.count <= Int(UInt32.max), "string too long for the SSH wire format")
        writeUInt32(UInt32(value.count))
        bytes.append(contentsOf: value)
    }

    public mutating func writeString(_ value: String) {
        writeString(Array(value.utf8))
    }

    /// Writes a non-negative integer, given as big-endian bytes, as an SSH
    /// `mpint`: leading zero bytes are removed, and one zero byte is added
    /// when the top bit is set, so the value is not read as negative. Zero
    /// is written as an empty string.
    public mutating func writeMPInt(unsignedBigEndian magnitude: some Collection<UInt8>) {
        var digits = Array(magnitude.drop(while: { $0 == 0 }))
        if let first = digits.first, first & 0x80 != 0 {
            digits.insert(0, at: 0)
        }
        writeString(digits)
    }
}
