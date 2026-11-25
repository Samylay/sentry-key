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

    /// Largest file the agent reads from its folder. Its files are a few
    /// hundred bytes; anything bigger was not written by the agent.
    static let maxFileLength = 64 * 1024

    /// Creates the folder if needed, and refuses one that other users can
    /// enter or that belongs to someone else.
    func prepare() throws {
        if mkdir(path, 0o700) == 0 { return }
        guard errno == EEXIST else { throw AgentStorageError.system(call: "mkdir", code: errno) }
        guard Self.isPrivate(path, type: S_IFDIR) else { throw AgentStorageError.unsafeDirectory }
    }

    /// True if `path` is itself (not through a symbolic link) of `type`,
    /// belongs to this user, and gives other users no access at all.
    private static func isPrivate(_ path: String, type: mode_t) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == type && info.st_uid == geteuid() && info.st_mode & 0o077 == 0
    }

    func write(_ data: Data, to name: String) throws {
        try prepare()
        try data.write(to: URL(fileURLWithPath: file(name)), options: .atomic)
        guard chmod(file(name), 0o600) == 0 else { throw AgentStorageError.system(call: "chmod", code: errno) }
    }

    /// Reads one of the agent's files, or returns nil if the folder or the
    /// file could have been written by another user: a planted
    /// `paired-phone.json` would make another phone "the phone". Checking
    /// the folder is enough to stop a swap after the check, since only this
    /// user can change what it contains.
    func read(_ name: String) -> Data? {
        guard Self.isPrivate(path, type: S_IFDIR), Self.isPrivate(file(name), type: S_IFREG),
              let data = FileManager.default.contents(atPath: file(name)),
              data.count <= Self.maxFileLength
        else {
            return nil
        }
        return data
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
        /// Which Bluetooth device to call. Nil for a phone recorded
        /// without Bluetooth, as in tests.
        let bluetoothIdentifier: UUID?
    }

    private static let fileName = "paired-phone.json"
    private let folder: AgentFolder

    public init(folder: AgentFolder) {
        self.folder = folder
    }

    public func save(_ phone: PairedPhone, bluetoothIdentifier: UUID? = nil) throws {
        let record = Record(
            identityKey: Data(phone.identityKey), sshKeyBlob: Data(phone.sshKeyBlob),
            bluetoothIdentifier: bluetoothIdentifier
        )
        try folder.write(try JSONEncoder().encode(record), to: Self.fileName)
    }

    /// The paired phone, or nil when there is none or the file is not a
    /// well-formed record.
    public func load() -> PairedPhone? {
        loadRecord().map { PairedPhone(identityKey: Array($0.identityKey), sshKeyBlob: Array($0.sshKeyBlob)) }
    }

    /// The paired phone's Bluetooth identifier. It only says which device
    /// to call: the handshake is what proves it is the phone.
    public func bluetoothIdentifier() -> UUID? {
        loadRecord()?.bluetoothIdentifier
    }

    private func loadRecord() -> Record? {
        guard let data = folder.read(Self.fileName),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.identityKey.count == ChannelLimits.publicKeyLength,
              // A point on the curve, not just 65 bytes.
              (try? P256.Signing.PublicKey(x963Representation: record.identityKey)) != nil,
              (try? ECDSAP256.x963Point(fromPublicKeyBlob: Array(record.sshKeyBlob))) != nil
        else {
            return nil
        }
        return record
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
