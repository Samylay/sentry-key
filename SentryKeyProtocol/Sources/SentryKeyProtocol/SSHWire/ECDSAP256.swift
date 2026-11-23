/// SSH encodings for `ecdsa-sha2-nistp256`, the only key type SentryKey
/// signs with (RFC 5656, section 3.1).
///
/// The inputs use the formats CryptoKit produces: `x963Representation` for
/// public keys and `rawRepresentation` (r followed by s) for signatures.
public enum ECDSAP256 {
    public static let algorithm = "ecdsa-sha2-nistp256"
    public static let curveName = "nistp256"

    /// Uncompressed point length: 0x04, then X and Y (32 bytes each).
    public static let x963PointLength = 65
    /// Raw signature length: r then s, 32 bytes each.
    public static let rawSignatureLength = 64

    /// Encodes a public key blob: string algorithm, string curve name, string point.
    public static func publicKeyBlob(x963Point point: [UInt8]) throws -> [UInt8] {
        try checkPoint(point)
        var writer = WireWriter()
        writer.writeString(algorithm)
        writer.writeString(curveName)
        writer.writeString(point)
        return writer.bytes
    }

    /// Decodes a public key blob and returns its uncompressed point. Rejects
    /// any other algorithm or curve, a wrong point size and trailing bytes.
    public static func x963Point(fromPublicKeyBlob blob: [UInt8]) throws -> [UInt8] {
        var reader = WireReader(blob)
        guard try reader.readUTF8String(maxLength: 64) == algorithm else {
            throw WireError.unexpectedValue("key algorithm")
        }
        guard try reader.readUTF8String(maxLength: 64) == curveName else {
            throw WireError.unexpectedValue("curve name")
        }
        let point = try reader.readString(maxLength: x963PointLength)
        try reader.expectEnd()
        try checkPoint(point)
        return point
    }

    /// Converts a raw signature (r then s) to an SSH signature blob:
    /// string algorithm, then a string holding mpint r and mpint s.
    public static func signatureBlob(rawSignature: [UInt8]) throws -> [UInt8] {
        guard rawSignature.count == rawSignatureLength else {
            throw WireError.unexpectedValue("raw signature length")
        }
        var inner = WireWriter()
        inner.writeMPInt(unsignedBigEndian: rawSignature[0..<32])
        inner.writeMPInt(unsignedBigEndian: rawSignature[32..<64])
        var writer = WireWriter()
        writer.writeString(algorithm)
        writer.writeString(inner.bytes)
        return writer.bytes
    }

    /// Checks the size and the uncompressed-point prefix. Whether the point
    /// is actually on the curve is left to CryptoKit, which checks it when
    /// it loads the key.
    private static func checkPoint(_ point: [UInt8]) throws {
        guard point.count == x963PointLength, point.first == 0x04 else {
            throw WireError.unexpectedValue("uncompressed P-256 point")
        }
    }
}
