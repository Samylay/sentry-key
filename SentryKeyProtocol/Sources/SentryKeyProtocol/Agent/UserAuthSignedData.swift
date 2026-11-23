/// The data ssh asks the agent to sign for a public-key login: RFC 4252,
/// section 7, or OpenSSH's host-bound variant (OpenSSH PROTOCOL, section
/// 3.1), which adds the server host key at the end.
///
/// The phone parses it to show the user name, to check that the key is its
/// own, and, from J4, to check that `sessionID` and `serverHostKey` match the
/// session-bind it verified. Anything that does not parse is not a login and
/// must be refused.
public struct UserAuthSignedData: Equatable, Sendable {
    public let sessionID: [UInt8]
    public let userName: String
    public let isHostBound: Bool
    public let keyAlgorithm: String
    public let keyBlob: [UInt8]
    /// Present only for the host-bound method.
    public let serverHostKey: [UInt8]?

    static let userAuthRequestMessage: UInt8 = 50
    static let service = "ssh-connection"
    static let publicKeyMethod = "publickey"
    static let hostBoundMethod = "publickey-hostbound-v00@openssh.com"

    /// Longest user name accepted. RFC 4252 sets no limit; 256 is far above
    /// what real systems allow.
    public static let maxUserNameLength = 256

    public static func parse(_ data: [UInt8]) throws -> UserAuthSignedData {
        var reader = WireReader(data)
        let sessionID = try reader.readString(maxLength: AgentLimits.maxSessionIDLength)
        guard try reader.readByte() == userAuthRequestMessage else {
            throw WireError.unexpectedValue("message type")
        }
        let userName = try reader.readUTF8String(maxLength: maxUserNameLength)
        guard try reader.readUTF8String(maxLength: 64) == service else {
            throw WireError.unexpectedValue("service")
        }
        let method = try reader.readUTF8String(maxLength: 64)
        guard method == publicKeyMethod || method == hostBoundMethod else {
            throw WireError.unexpectedValue("authentication method")
        }
        // Signed data always has this flag set; false would be a query.
        guard try reader.readBool() else {
            throw WireError.unexpectedValue("has-signature flag")
        }
        let keyAlgorithm = try reader.readUTF8String(maxLength: 64)
        let keyBlob = try reader.readString(maxLength: AgentLimits.maxKeyLength)
        let isHostBound = method == hostBoundMethod
        let serverHostKey = isHostBound
            ? try reader.readString(maxLength: AgentLimits.maxKeyLength)
            : nil
        try reader.expectEnd()

        return UserAuthSignedData(
            sessionID: sessionID,
            userName: userName,
            isHostBound: isHostBound,
            keyAlgorithm: keyAlgorithm,
            keyBlob: keyBlob,
            serverHostKey: serverHostKey
        )
    }
}
