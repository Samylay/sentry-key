import CryptoKit
import Foundation
import SentryKeyProtocol

public enum AgentStorageError: Error, Equatable {
    /// The folder exists but is not a private folder of this user.
    case unsafeDirectory
    case secureEnclaveUnavailable
    case system(call: String, code: Int32)
}

/// The agent's folder on disk. Everything in it is readable by this user
/// only, like the socket's folder.
public struct AgentFolder: Sendable {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    func file(_ name: String) -> String {
        path + "/" + name
    }

    /// Creates the folder if needed, and refuses one that other users can
    /// enter or that belongs to someone else.
    func prepare() throws {
        if mkdir(path, 0o700) == 0 { return }
        guard errno == EEXIST else { throw AgentStorageError.system(call: "mkdir", code: errno) }

        var info = stat()
        guard lstat(path, &info) == 0 else { throw AgentStorageError.system(call: "lstat", code: errno) }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            throw AgentStorageError.unsafeDirectory
        }
    }

    func write(_ data: Data, to name: String) throws {
        try prepare()
        try data.write(to: URL(fileURLWithPath: file(name)), options: .atomic)
        guard chmod(file(name), 0o600) == 0 else { throw AgentStorageError.system(call: "chmod", code: errno) }
    }

    func read(_ name: String) -> Data? {
        FileManager.default.contents(atPath: file(name))
    }
}

/// Remembers the phone this Mac is paired with: its identity key, and the
/// SSH public key offered to `ssh`.
///
/// Public keys only. The file is still kept private: replacing it would make
/// another phone "the phone", or offer another SSH key (red team guide,
/// T6.10). A process of the same user can do that, which is the limit of
/// what a file can protect on a compromised Mac.
public struct PairingStore: PublicKeyStore {
    private struct Record: Codable {
        let identityKey: Data
        let sshKeyBlob: Data
    }

    private static let fileName = "paired-phone.json"
    private let folder: AgentFolder

    public init(folder: AgentFolder) {
        self.folder = folder
    }

    public func save(_ phone: PairedPhone) throws {
        let record = Record(identityKey: Data(phone.identityKey), sshKeyBlob: Data(phone.sshKeyBlob))
        try folder.write(try JSONEncoder().encode(record), to: Self.fileName)
    }

    /// The paired phone, or nil when there is none or the file is not a
    /// well-formed record.
    public func load() -> PairedPhone? {
        guard let data = folder.read(Self.fileName),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.identityKey.count == ChannelLimits.publicKeyLength,
              (try? ECDSAP256.x963Point(fromPublicKeyBlob: Array(record.sshKeyBlob))) != nil
        else {
            return nil
        }
        return PairedPhone(identityKey: Array(record.identityKey), sshKeyBlob: Array(record.sshKeyBlob))
    }

    public func forget() {
        unlink(folder.file(Self.fileName))
    }

    public func identity() -> AgentIdentity? {
        load().map { AgentIdentity(keyBlob: $0.sshKeyBlob, comment: "sentrykey") }
    }
}

/// The Mac identity key, in the Mac's Secure Enclave (ARCHITECTURE.md,
/// Keys). It proves to the phone, at each connection, that this is the Mac
/// it was paired with.
///
/// The file holds CryptoKit's `dataRepresentation`: a blob the Secure
/// Enclave encrypted, useless on any other Mac. It is not protected against
/// another process of this user on this Mac, which could ask the chip to
/// sign with it (red team guide, T6.6). That gives such a process the Mac's
/// place on the channel, and nothing more: every signature still needs
/// Face ID on the phone.
///
/// NEEDS LINE-BY-LINE HUMAN REVIEW (crypto code).
public enum MacIdentityKey {
    private static let fileName = "mac-identity.key"

    /// Loads the key, creating it on first use.
    public static func loadOrCreate(in folder: AgentFolder) throws -> SecureEnclaveIdentity {
        guard SecureEnclave.isAvailable else { throw AgentStorageError.secureEnclaveUnavailable }
        if let stored = folder.read(fileName) {
            return SecureEnclaveIdentity(key: try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: stored))
        }
        let key = try SecureEnclave.P256.Signing.PrivateKey()
        try folder.write(key.dataRepresentation, to: fileName)
        return SecureEnclaveIdentity(key: key)
    }
}
