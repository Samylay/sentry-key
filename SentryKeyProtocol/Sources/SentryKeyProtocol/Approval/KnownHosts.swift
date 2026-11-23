/// Names the user gave to servers, keyed by host-key fingerprint.
///
/// The phone never takes a host name from the Mac. The first time a server
/// appears, the prompt shows only its fingerprint and the user may name it.
/// Afterwards the prompt shows that name next to the fingerprint.
public struct KnownHosts: Codable, Equatable, Sendable {
    public static let maxNameLength = 40
    public static let maxHosts = 256

    public enum Failure: Error, Equatable, Sendable {
        case invalidFingerprint
        case invalidName
        case full
    }

    private var names: [String: String] = [:]

    public init() {}

    public var count: Int { names.count }

    public func name(forFingerprint fingerprint: String) -> String? {
        names[fingerprint]
    }

    /// Records or renames a server. Surrounding spaces are removed.
    public mutating func remember(name: String, forFingerprint fingerprint: String) throws(Failure) {
        guard Self.isFingerprint(fingerprint) else { throw .invalidFingerprint }
        let trimmed = name.trimmingSpaces()
        guard DisplayText.isSafe(trimmed, maxLength: Self.maxNameLength) else { throw .invalidName }
        guard names[fingerprint] != nil || names.count < Self.maxHosts else { throw .full }
        names[fingerprint] = trimmed
    }

    public mutating func forget(fingerprint: String) {
        names[fingerprint] = nil
    }

    /// `SHA256:` followed by 43 base64 characters, as `SSHFingerprint` makes.
    static func isFingerprint(_ text: String) -> Bool {
        guard text.hasPrefix("SHA256:") else { return false }
        let body = text.dropFirst("SHA256:".count)
        return body.count == 43 && body.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar)
                || scalar == "+" || scalar == "/")
        }
    }
}

private extension String {
    func trimmingSpaces() -> String {
        var scalars = Substring(self)
        while scalars.first == " " { scalars.removeFirst() }
        while scalars.last == " " { scalars.removeLast() }
        return String(scalars)
    }
}
