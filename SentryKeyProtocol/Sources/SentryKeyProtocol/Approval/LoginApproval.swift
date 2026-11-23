/// What the phone shows for one SSH login, after checking the sign request
/// against the session-bind message ssh sent just before it.
public struct LoginApproval: Equatable, Sendable {
    /// The account on the server, checked with `DisplayText.isSafe`.
    public let userName: String
    /// The server's host key blob, from session-bind. The app shows its
    /// SHA-256 fingerprint and the name recorded on first use.
    public let hostKey: [UInt8]
    /// For example `ssh-ed25519`.
    public let hostKeyAlgorithm: String
}

/// Why the phone refuses a sign request without asking the user.
public enum ApprovalRefusal: Error, Equatable, Sendable {
    /// The request names a key that is not this phone's SSH key.
    case wrongKey
    /// The data to sign is not an SSH login request.
    case notALogin
    /// ssh sent no session-bind (OpenSSH older than 8.9, or the Mac dropped
    /// it), so the phone cannot tell which server this is.
    case noSessionBind
    /// The session-bind is for a forwarded agent. Not supported yet.
    case forwardedSession
    /// The login is for another session than the one session-bind proved.
    case sessionMismatch
    /// The host key inside the login differs from the session-bind one.
    case hostKeyMismatch
    /// The user name has invisible or reordering characters, or is too long.
    case unsafeUserName
}

public enum LoginApprovalCheck {
    /// Longest user name the prompt shows. Real Unix names are 32 at most.
    public static let maxUserNameLength = 64

    /// Checks a sign request before the phone prompts the user.
    ///
    /// The caller must also verify `bind.serverSignature` over
    /// `bind.sessionID` with `bind.hostKey` (HostVerifier, CryptoKit) before
    /// prompting. This function only checks that the login matches that
    /// session-bind, so it proves nothing on its own about the server.
    ///
    /// - Parameters:
    ///   - requestKeyBlob: the key blob in the sign request.
    ///   - data: the data to sign, from the sign request.
    ///   - bind: the latest session-bind received on this agent connection.
    ///   - ourKeyBlob: this phone's SSH public key blob.
    public static func check(
        requestKeyBlob: [UInt8],
        data: [UInt8],
        bind: SessionBind?,
        ourKeyBlob: [UInt8]
    ) throws(ApprovalRefusal) -> LoginApproval {
        guard requestKeyBlob == ourKeyBlob else { throw .wrongKey }

        let login: UserAuthSignedData
        do {
            login = try UserAuthSignedData.parse(data)
        } catch {
            throw .notALogin
        }
        guard login.keyAlgorithm == "ecdsa-sha2-nistp256", login.keyBlob == ourKeyBlob else {
            throw .wrongKey
        }

        guard let bind else { throw .noSessionBind }
        guard !bind.isForwarding else { throw .forwardedSession }
        guard login.sessionID == bind.sessionID else { throw .sessionMismatch }
        if let hostKey = login.serverHostKey, hostKey != bind.hostKey {
            throw .hostKeyMismatch
        }
        guard DisplayText.isSafe(login.userName, maxLength: maxUserNameLength) else {
            throw .unsafeUserName
        }

        let algorithm: String
        do {
            algorithm = try SSHFingerprint.algorithm(ofKeyBlob: bind.hostKey)
        } catch {
            throw .hostKeyMismatch
        }
        return LoginApproval(userName: login.userName, hostKey: bind.hostKey, hostKeyAlgorithm: algorithm)
    }
}
