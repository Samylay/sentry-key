import Testing
@testable import SentryKeyProtocol

@Suite("ecdsa-sha2-nistp256 encodings")
struct ECDSAP256Tests {
    @Test func publicKeyBlobMatchesWhatSSHAccepted() throws {
        let blob = try ECDSAP256.publicKeyBlob(x963Point: CapturedVectors.publicPoint)
        #expect(blob == CapturedVectors.keyBlob)
    }

    @Test func publicKeyBlobRoundTrip() throws {
        #expect(try ECDSAP256.x963Point(fromPublicKeyBlob: CapturedVectors.keyBlob) == CapturedVectors.publicPoint)
    }

    @Test func compressedPointIsRejected() {
        let compressed = [UInt8](repeating: 0x02, count: 1) + [UInt8](repeating: 1, count: 32)
        #expect(throws: WireError.self) { try ECDSAP256.publicKeyBlob(x963Point: compressed) }
    }

    @Test func otherCurveIsRejected() {
        var writer = WireWriter()
        writer.writeString("ecdsa-sha2-nistp256")
        writer.writeString("nistp384")
        writer.writeString(CapturedVectors.publicPoint)
        #expect(throws: WireError.unexpectedValue("curve name")) {
            try ECDSAP256.x963Point(fromPublicKeyBlob: writer.bytes)
        }
    }

    @Test func keyBlobWithTrailingBytesIsRejected() {
        #expect(throws: WireError.trailingBytes(1)) {
            try ECDSAP256.x963Point(fromPublicKeyBlob: CapturedVectors.keyBlob + [0])
        }
    }

    /// The signature blob built from r and s must equal the one sshd verified.
    @Test func signatureBlobMatchesWhatSSHDVerified() throws {
        let raw = CapturedVectors.signatureR + CapturedVectors.signatureS
        let blob = try ECDSAP256.signatureBlob(rawSignature: raw)
        let expected = AgentResponse.signature(blob: blob).encoded()
        #expect(expected == CapturedVectors.signResponseMessage)
    }

    @Test func signatureWithHighBitAndLeadingZeros() throws {
        // r has its top bit set (needs a 0x00 prefix); s starts with zero bytes.
        let r = [UInt8](repeating: 0xFF, count: 32)
        let s = [0, 0] + [UInt8](repeating: 0x11, count: 30)
        let blob = try ECDSAP256.signatureBlob(rawSignature: r + s)

        var reader = WireReader(blob)
        #expect(try reader.readUTF8String(maxLength: 64) == "ecdsa-sha2-nistp256")
        var inner = WireReader(try reader.readString(maxLength: 200))
        #expect(try inner.readString(maxLength: 40) == [0] + r)
        #expect(try inner.readString(maxLength: 40) == [UInt8](repeating: 0x11, count: 30))
        try inner.expectEnd()
        try reader.expectEnd()
    }

    @Test func wrongSignatureLengthIsRejected() {
        #expect(throws: WireError.self) { try ECDSAP256.signatureBlob(rawSignature: [UInt8](repeating: 1, count: 63)) }
    }

    @Test func rawSignatureMatchesWhatSSHDVerified() throws {
        let blob = try ECDSAP256.signatureBlob(rawSignature: CapturedVectors.signatureR + CapturedVectors.signatureS)
        #expect(try ECDSAP256.rawSignature(fromSignatureBlob: blob) == CapturedVectors.signatureR + CapturedVectors.signatureS)
    }

    @Test func rawSignatureRestoresLeadingZeros() throws {
        // r starts with zero bytes and s has its top bit set: the blob drops
        // the first and pads the second, and decoding must undo both.
        let r = [UInt8](repeating: 0, count: 3) + [UInt8](repeating: 0x11, count: 29)
        let s = [UInt8](repeating: 0xFF, count: 32)
        let blob = try ECDSAP256.signatureBlob(rawSignature: r + s)
        #expect(try ECDSAP256.rawSignature(fromSignatureBlob: blob) == r + s)
    }

    @Test func malformedSignatureBlobsAreRejected() throws {
        func blob(algorithm: String = ECDSAP256.algorithm, r: [UInt8], s: [UInt8], extra: [UInt8] = []) -> [UInt8] {
            var inner = WireWriter()
            inner.writeString(r)
            inner.writeString(s)
            var writer = WireWriter()
            writer.writeString(algorithm)
            writer.writeString(inner.bytes + extra)
            return writer.bytes
        }
        let one: [UInt8] = [1]

        #expect(throws: WireError.unexpectedValue("signature algorithm")) {
            try ECDSAP256.rawSignature(fromSignatureBlob: blob(algorithm: "ssh-ed25519", r: one, s: one))
        }
        #expect(throws: WireError.unexpectedValue("zero signature value")) {
            try ECDSAP256.rawSignature(fromSignatureBlob: blob(r: [], s: one))
        }
        #expect(throws: WireError.unexpectedValue("negative signature value")) {
            try ECDSAP256.rawSignature(fromSignatureBlob: blob(r: [0x80], s: one))
        }
        #expect(throws: WireError.unexpectedValue("signature value not in shortest form")) {
            try ECDSAP256.rawSignature(fromSignatureBlob: blob(r: [0, 1], s: one))
        }
        #expect(throws: WireError.unexpectedValue("signature value too long")) {
            try ECDSAP256.rawSignature(fromSignatureBlob: blob(r: [UInt8](repeating: 1, count: 33), s: one))
        }
        #expect(throws: WireError.trailingBytes(1)) {
            try ECDSAP256.rawSignature(fromSignatureBlob: blob(r: one, s: one, extra: [0]))
        }
        #expect(throws: WireError.trailingBytes(1)) {
            try ECDSAP256.rawSignature(fromSignatureBlob: blob(r: one, s: one) + [0])
        }
    }
}
