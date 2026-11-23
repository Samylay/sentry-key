/// ssh-agent message types used by SentryKey (RFC 9987, checked against a
/// real OpenSSH 10.2 ssh-agent).
public enum AgentMessageType: UInt8 {
    case failure = 5
    case success = 6
    case requestIdentities = 11
    case identitiesAnswer = 12
    case signRequest = 13
    case signResponse = 14
    case `extension` = 27
}

/// Limits applied to every field read from ssh. They are far above anything
/// a P-256 login needs, and they stop a client from making us allocate
/// large buffers.
public enum AgentLimits {
    /// Maximum length of one agent message, type byte included.
    public static let maxMessageLength = 256 * 1024
    /// Maximum length of a key blob, host key or signature field.
    public static let maxKeyLength = 16 * 1024
    /// Maximum length of the data to sign.
    public static let maxDataLength = 64 * 1024
    /// Maximum length of a session identifier (a SHA-512 hash is 64 bytes).
    public static let maxSessionIDLength = 64
    /// Maximum length of an extension name.
    public static let maxExtensionNameLength = 128
}

/// The `session-bind@openssh.com` extension (OpenSSH PROTOCOL.agent): ssh
/// tells the agent which server it is talking to, with the server's own
/// signature as proof. From J4, the phone verifies `serverSignature` over
/// `sessionID` with `hostKey` itself.
public struct SessionBind: Equatable, Sendable {
    public let hostKey: [UInt8]
    public let sessionID: [UInt8]
    public let serverSignature: [UInt8]
    public let isForwarding: Bool

    public init(hostKey: [UInt8], sessionID: [UInt8], serverSignature: [UInt8], isForwarding: Bool) {
        self.hostKey = hostKey
        self.sessionID = sessionID
        self.serverSignature = serverSignature
        self.isForwarding = isForwarding
    }
}

/// A request from ssh to the agent, after validation.
public enum AgentRequest: Equatable, Sendable {
    case requestIdentities
    case sign(keyBlob: [UInt8], data: [UInt8], flags: UInt32)
    case sessionBind(SessionBind)
    /// An extension SentryKey does not implement. Reply with `.failure`.
    case unsupportedExtension(name: String)
    /// Any other message type, such as adding or removing keys. SentryKey's
    /// keys live on the phone, so these always get `.failure`.
    case unsupported(type: UInt8)

    public static let sessionBindName = "session-bind@openssh.com"

    /// Parses one message body: the type byte and its contents, without the
    /// uint32 length prefix (see `Reassembler`).
    public static func parse(body: [UInt8]) throws -> AgentRequest {
        guard body.count <= AgentLimits.maxMessageLength else {
            throw WireError.lengthTooLarge(body.count)
        }
        var reader = WireReader(body)
        let type = try reader.readByte()

        switch AgentMessageType(rawValue: type) {
        case .requestIdentities:
            try reader.expectEnd()
            return .requestIdentities

        case .signRequest:
            let keyBlob = try reader.readString(maxLength: AgentLimits.maxKeyLength)
            let data = try reader.readString(maxLength: AgentLimits.maxDataLength)
            let flags = try reader.readUInt32()
            try reader.expectEnd()
            return .sign(keyBlob: keyBlob, data: data, flags: flags)

        case .extension:
            let name = try reader.readUTF8String(maxLength: AgentLimits.maxExtensionNameLength)
            guard name == sessionBindName else {
                // Contents of unknown extensions are never parsed.
                return .unsupportedExtension(name: name)
            }
            let bind = SessionBind(
                hostKey: try reader.readString(maxLength: AgentLimits.maxKeyLength),
                sessionID: try reader.readString(maxLength: AgentLimits.maxSessionIDLength),
                serverSignature: try reader.readString(maxLength: AgentLimits.maxKeyLength),
                isForwarding: try reader.readBool()
            )
            try reader.expectEnd()
            return .sessionBind(bind)

        default:
            return .unsupported(type: type)
        }
    }
}

/// A key the agent offers to ssh.
public struct AgentIdentity: Equatable, Sendable {
    public let keyBlob: [UInt8]
    public let comment: String

    public init(keyBlob: [UInt8], comment: String) {
        self.keyBlob = keyBlob
        self.comment = comment
    }
}

/// A reply from the agent to ssh.
public enum AgentResponse: Equatable, Sendable {
    case failure
    case success
    case identities([AgentIdentity])
    case signature(blob: [UInt8])

    /// The full message to write to the socket, uint32 length prefix included.
    public func encoded() -> [UInt8] {
        var body = WireWriter()
        switch self {
        case .failure:
            body.writeByte(AgentMessageType.failure.rawValue)
        case .success:
            body.writeByte(AgentMessageType.success.rawValue)
        case .identities(let identities):
            body.writeByte(AgentMessageType.identitiesAnswer.rawValue)
            body.writeUInt32(UInt32(identities.count))
            for identity in identities {
                body.writeString(identity.keyBlob)
                body.writeString(identity.comment)
            }
        case .signature(let blob):
            body.writeByte(AgentMessageType.signResponse.rawValue)
            body.writeString(blob)
        }
        var message = WireWriter()
        message.writeString(body.bytes)
        return message.bytes
    }
}
