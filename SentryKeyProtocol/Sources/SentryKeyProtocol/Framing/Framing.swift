/// Length-prefixed framing: each message is sent as a uint32 length followed
/// by its bytes. ssh-agent uses this format on its socket, and SentryKey
/// uses the same one over BLE, where a message is split into chunks no larger
/// than the negotiated write length.
public enum FramingError: Error, Equatable {
    case emptyMessage
    case messageTooLarge(Int)
    case invalidChunkSize(Int)
}

public enum Framing {
    /// Prefixes `message` with its length and splits the result into chunks
    /// of at most `chunkSize` bytes, in sending order.
    public static func chunks(for message: [UInt8], chunkSize: Int, maxMessageLength: Int) throws -> [[UInt8]] {
        guard chunkSize > 0 else { throw FramingError.invalidChunkSize(chunkSize) }
        guard !message.isEmpty else { throw FramingError.emptyMessage }
        guard message.count <= maxMessageLength else { throw FramingError.messageTooLarge(message.count) }

        var framed = WireWriter()
        framed.writeString(message)
        let bytes = framed.bytes
        return stride(from: 0, to: bytes.count, by: chunkSize).map {
            Array(bytes[$0..<min($0 + chunkSize, bytes.count)])
        }
    }
}

/// Rebuilds messages from bytes that arrive in pieces of any size.
///
/// A length of zero or above the limit throws. The stream is then out of
/// sync and cannot be trusted: close the connection and drop the reassembler.
public struct Reassembler {
    public let maxMessageLength: Int
    private var buffer: [UInt8] = []

    public init(maxMessageLength: Int) {
        self.maxMessageLength = maxMessageLength
    }

    /// Adds received bytes and returns every message they complete, in order.
    public mutating func append(_ bytes: some Collection<UInt8>) throws -> [[UInt8]] {
        buffer.append(contentsOf: bytes)
        var messages: [[UInt8]] = []
        while buffer.count >= 4 {
            let length = buffer[0..<4].reduce(0) { $0 << 8 | Int($1) }
            guard length > 0 else { throw FramingError.emptyMessage }
            // Checked before waiting for the body, so a huge length never
            // makes us buffer data.
            guard length <= maxMessageLength else { throw FramingError.messageTooLarge(length) }
            guard buffer.count >= 4 + length else { break }
            messages.append(Array(buffer[4..<4 + length]))
            buffer.removeFirst(4 + length)
        }
        return messages
    }

    /// Bytes received that do not form a complete message yet.
    public var pendingByteCount: Int { buffer.count }
}
