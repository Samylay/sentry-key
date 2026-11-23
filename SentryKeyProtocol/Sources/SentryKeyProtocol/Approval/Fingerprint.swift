import Foundation

/// OpenSSH key fingerprints and public key lines.
///
/// The SHA-256 digest itself is computed by the caller with CryptoKit
/// (`SHA256.hash(data:)`), because this package must also build on Linux for
/// its tests and adds no dependencies. This file only formats the result.
public enum SSHFingerprint {
    /// Formats a SHA-256 digest of a key blob the way `ssh-keygen -l` does:
    /// `SHA256:` followed by base64 without padding.
    public static func sha256String(digest: [UInt8]) throws -> String {
        guard digest.count == 32 else {
            throw WireError.unexpectedValue("SHA-256 digest length")
        }
        let base64 = Data(digest).base64EncodedString()
        return "SHA256:" + base64.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    /// The key algorithm named at the start of an SSH public key blob,
    /// for example `ssh-ed25519`. Used to show the host key type.
    public static func algorithm(ofKeyBlob blob: [UInt8]) throws -> String {
        var reader = WireReader(blob)
        return try reader.readUTF8String(maxLength: 64)
    }
}

/// The one-line public key format of `authorized_keys` and GitHub's
/// "New SSH key" form.
public enum OpenSSHPublicKey {
    /// `ecdsa-sha2-nistp256 AAAA... comment`. The comment must be a short
    /// label made of letters, digits, `-`, `_`, `.` or `@`, so the line
    /// cannot carry options or a second key.
    public static func line(keyBlob: [UInt8], comment: String) throws -> String {
        let algorithm = try SSHFingerprint.algorithm(ofKeyBlob: keyBlob)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.@"))
        guard !comment.isEmpty, comment.count <= 64,
              comment.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) })
        else {
            throw WireError.unexpectedValue("public key comment")
        }
        return "\(algorithm) \(Data(keyBlob).base64EncodedString()) \(comment)"
    }
}
