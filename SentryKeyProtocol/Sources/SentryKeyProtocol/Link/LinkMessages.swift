/// Messages exchanged between the Mac agent and the phone once the secure
/// channel is open (ARCHITECTURE.md, Signing).
///
/// `encoded()` returns a message body without a length prefix: `Framing`
/// adds the prefix when the body is split into chunks, and `Reassembler`
/// removes it on the other side.
///
/// NEEDS LINE-BY-LINE HUMAN REVIEW: `parse` reads untrusted input on both
/// devices.

/// Names one sign request on the link.
///
/// The Mac gives up on a request after a timeout while the phone may still
/// be showing its prompt. Without an identifier, the late answer would be
/// taken for the answer to the next request.
public struct RequestID: Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

/// Mac to phone.
public enum PhoneRequest: Equatable, Sendable {
    /// Asks for one signature. `bind` is the session-bind `ssh` sent on the
    /// same agent connection, or nil if it sent none.
    case sign(id: RequestID, keyBlob: [UInt8], data: [UInt8], bind: SessionBind?)
    /// The Mac no longer waits for this request: the phone drops its prompt.
    case cancel(id: RequestID)

    public var id: RequestID {
        switch self {
        case .sign(let id, _, _, _), .cancel(let id): return id
        }
    }

    public func encoded() -> [UInt8] {
        var writer = WireWriter()
        switch self {
        case .sign(let id, let keyBlob, let data, let bind):
            writer.writeByte(PhoneRequestType.sign.rawValue)
            writer.writeUInt32(id.rawValue)
            writer.writeString(keyBlob)
            writer.writeString(data)
            writer.writeBool(bind != nil)
            if let bind {
                writer.writeString(bind.hostKey)
                writer.writeString(bind.sessionID)
                writer.writeString(bind.serverSignature)
                writer.writeBool(bind.isForwarding)
            }
        case .cancel(let id):
            writer.writeByte(PhoneRequestType.cancel.rawValue)
            writer.writeUInt32(id.rawValue)
        }
        return writer.bytes
    }

    public static func parse(body: [UInt8]) throws -> PhoneRequest {
        guard body.count <= AgentLimits.maxMessageLength else {
            throw WireError.lengthTooLarge(body.count)
        }
        var reader = WireReader(body)
        let type = try reader.readByte()

        switch PhoneRequestType(rawValue: type) {
        case .sign:
            let id = RequestID(rawValue: try reader.readUInt32())
            let keyBlob = try reader.readString(maxLength: AgentLimits.maxKeyLength)
            let data = try reader.readString(maxLength: AgentLimits.maxDataLength)
            var bind: SessionBind?
            if try reader.readBool() {
                bind = SessionBind(
                    hostKey: try reader.readString(maxLength: AgentLimits.maxKeyLength),
                    sessionID: try reader.readString(maxLength: AgentLimits.maxSessionIDLength),
                    serverSignature: try reader.readString(maxLength: AgentLimits.maxKeyLength),
                    isForwarding: try reader.readBool()
                )
            }
            try reader.expectEnd()
            return .sign(id: id, keyBlob: keyBlob, data: data, bind: bind)

        case .cancel:
            let id = RequestID(rawValue: try reader.readUInt32())
            try reader.expectEnd()
            return .cancel(id: id)

        case nil:
            throw WireError.unexpectedValue("phone request type \(type)")
        }
    }
}

/// Why the phone did not sign. The Mac uses it for its error message only:
/// it is never a reason to retry with another key.
public enum RefusalReason: UInt8, Sendable, CaseIterable {
    case deniedByUser = 1
    case expired = 2
    /// Another request is already waiting for the user.
    case busy = 3
    /// The request failed the phone's checks before any prompt.
    case invalidRequest = 4
    case rateLimited = 5
    /// No signing key, or Face ID could not unlock it.
    case keyUnavailable = 6
}

/// Phone to Mac: the answer to one `PhoneRequest.sign`.
public struct PhoneResponse: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// An SSH signature blob, as `ECDSAP256.signatureBlob` builds it.
        case signature(blob: [UInt8])
        case refused(RefusalReason)
    }

    public let id: RequestID
    public let outcome: Outcome

    public init(id: RequestID, outcome: Outcome) {
        self.id = id
        self.outcome = outcome
    }

    public func encoded() -> [UInt8] {
        var writer = WireWriter()
        switch outcome {
        case .signature(let blob):
            writer.writeByte(PhoneResponseType.signature.rawValue)
            writer.writeUInt32(id.rawValue)
            writer.writeString(blob)
        case .refused(let reason):
            writer.writeByte(PhoneResponseType.refused.rawValue)
            writer.writeUInt32(id.rawValue)
            writer.writeByte(reason.rawValue)
        }
        return writer.bytes
    }

    public static func parse(body: [UInt8]) throws -> PhoneResponse {
        guard body.count <= AgentLimits.maxMessageLength else {
            throw WireError.lengthTooLarge(body.count)
        }
        var reader = WireReader(body)
        let type = try reader.readByte()

        switch PhoneResponseType(rawValue: type) {
        case .signature:
            let id = RequestID(rawValue: try reader.readUInt32())
            let blob = try reader.readString(maxLength: AgentLimits.maxKeyLength)
            try reader.expectEnd()
            return PhoneResponse(id: id, outcome: .signature(blob: blob))

        case .refused:
            let id = RequestID(rawValue: try reader.readUInt32())
            let rawReason = try reader.readByte()
            guard let reason = RefusalReason(rawValue: rawReason) else {
                throw WireError.unexpectedValue("refusal reason \(rawReason)")
            }
            try reader.expectEnd()
            return PhoneResponse(id: id, outcome: .refused(reason))

        case nil:
            throw WireError.unexpectedValue("phone response type \(type)")
        }
    }
}

private enum PhoneRequestType: UInt8 {
    case sign = 1
    case cancel = 2
}

private enum PhoneResponseType: UInt8 {
    case signature = 1
    case refused = 2
}
