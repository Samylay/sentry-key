/// What travels over Bluetooth between the Mac and the phone, before any
/// encryption: each message says which protocol it belongs to.
///
/// A connection carries pairing messages (once) or secure channel messages
/// (always). The kind byte keeps them apart, so a pairing message can never
/// be read as a channel message or the reverse.
///
/// NEEDS LINE-BY-LINE HUMAN REVIEW: `parse` reads bytes from any device in
/// Bluetooth range, before anyone is authenticated.

/// The Bluetooth identifiers of the SentryKey service. Random values,
/// generated once for this project.
public enum BluetoothLayout {
    public static let service = "D054D7C7-1974-49B5-A3FA-26079D597B43"
    /// The Mac writes here. Messages to the phone.
    public static let toPhone = "64AEBB3C-923C-4C43-A4FC-F637F059B31A"
    /// The phone notifies here. Messages to the Mac.
    public static let toMac = "7C90EAF7-824F-4228-9414-DFC7D311F418"
}

public enum TransportMessage: Equatable, Sendable {
    /// Phone to Mac: `PairingRequest`.
    case pairingRequest([UInt8])
    /// Mac to phone: `PairingConfirmation`.
    case pairingConfirmation([UInt8])
    /// Either way: a handshake message or a sealed message of the channel.
    case channel([UInt8])
    /// Phone to Mac: "I have no channel with you, start a new handshake."
    /// Sent when the phone refuses a channel message, typically after iOS
    /// relaunched the app and its sessions were lost. Not authenticated:
    /// anyone in range could send it, but all it can do is make the Mac
    /// drop its connection and reconnect, which jamming the radio does too.
    case channelReset

    /// Longest message accepted from the radio: a sealed message of the
    /// largest size, with its header, tag and kind byte.
    public static let maxLength = AgentLimits.maxMessageLength + 64

    private enum Kind: UInt8 {
        case pairingRequest = 1
        case pairingConfirmation = 2
        case channel = 3
        case channelReset = 4
    }

    /// The message without a length prefix: `Framing` adds one when it
    /// splits the message into Bluetooth-sized chunks.
    public func encoded() -> [UInt8] {
        switch self {
        case .pairingRequest(let body): [Kind.pairingRequest.rawValue] + body
        case .pairingConfirmation(let body): [Kind.pairingConfirmation.rawValue] + body
        case .channel(let body): [Kind.channel.rawValue] + body
        case .channelReset: [Kind.channelReset.rawValue]
        }
    }

    public static func parse(_ message: [UInt8]) throws -> TransportMessage {
        guard message.count <= maxLength else { throw WireError.lengthTooLarge(message.count) }
        guard let first = message.first else { throw WireError.truncated }
        let body = Array(message.dropFirst())
        switch Kind(rawValue: first) {
        case .pairingRequest: return .pairingRequest(body)
        case .pairingConfirmation: return .pairingConfirmation(body)
        case .channel: return .channel(body)
        case .channelReset:
            guard body.isEmpty else { throw WireError.unexpectedValue("channel reset with a body") }
            return .channelReset
        case nil: throw WireError.unexpectedValue("transport message kind \(first)")
        }
    }
}
