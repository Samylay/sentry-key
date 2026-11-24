#if canImport(CryptoKit)
import CryptoKit
import Foundation

/// An identity key that lives in the device's Secure Enclave: the form the
/// Mac and phone identity keys take on real devices.
///
/// The private key never leaves the chip. This type only holds a handle to
/// it and asks the chip to sign.
///
/// NEEDS LINE-BY-LINE HUMAN REVIEW (crypto code).
public struct SecureEnclaveIdentity: IdentitySigner {
    private let key: SecureEnclave.P256.Signing.PrivateKey

    public init(key: SecureEnclave.P256.Signing.PrivateKey) {
        self.key = key
    }

    public var publicKey: [UInt8] {
        Array(key.publicKey.x963Representation)
    }

    public func signature(for message: [UInt8]) throws -> [UInt8] {
        Array(try key.signature(for: Data(message)).rawRepresentation)
    }
}
#endif
