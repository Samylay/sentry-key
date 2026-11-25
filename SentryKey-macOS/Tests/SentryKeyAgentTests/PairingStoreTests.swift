import CryptoKit
import Foundation
import SentryKeyAgent
import SentryKeyProtocol
import Testing

/// A folder for one test, removed when the test ends.
private final class TemporaryAgentFolder {
    let folder = AgentFolder(path: NSTemporaryDirectory() + "sk-store-" + String(UInt32.random(in: 0...UInt32.max), radix: 16))

    deinit {
        try? FileManager.default.removeItem(atPath: folder.path)
    }
}

private func permissions(of path: String) -> mode_t {
    var info = stat()
    lstat(path, &info)
    return info.st_mode & 0o777
}

private func makePhone() throws -> PairedPhone {
    let identityKey = Array(P256.Signing.PrivateKey().publicKey.x963Representation)
    let sshPoint = Array(P256.Signing.PrivateKey().publicKey.x963Representation)
    return PairedPhone(identityKey: identityKey, sshKeyBlob: try ECDSAP256.publicKeyBlob(x963Point: sshPoint))
}

@Suite("What the agent keeps on disk")
struct PairingStoreTests {
    private let temporary = TemporaryAgentFolder()
    private var folder: AgentFolder { temporary.folder }

    @Test func remembersThePairedPhone() throws {
        let phone = try makePhone()
        try PairingStore(folder: folder).save(phone)

        // A new store, as after the agent restarts.
        let reloaded = PairingStore(folder: folder)
        #expect(reloaded.load() == phone)
        #expect(reloaded.identity() == AgentIdentity(keyBlob: phone.sshKeyBlob, comment: "sentrykey"))
    }

    @Test func remembersWhichBluetoothDeviceThePhoneIs() throws {
        let identifier = UUID()
        try PairingStore(folder: folder).save(try makePhone(), bluetoothIdentifier: identifier)

        #expect(PairingStore(folder: folder).bluetoothIdentifier() == identifier)
    }

    @Test func offersNoKeyBeforePairing() {
        let store = PairingStore(folder: folder)

        #expect(store.load() == nil)
        #expect(store.identity() == nil)
    }

    @Test func forgetsThePhone() throws {
        let store = PairingStore(folder: folder)
        try store.save(try makePhone())

        store.forget()

        #expect(store.load() == nil)
    }

    @Test func keepsItsFilesPrivate() throws {
        try PairingStore(folder: folder).save(try makePhone())

        #expect(permissions(of: folder.path) == 0o700)
        #expect(permissions(of: folder.path + "/paired-phone.json") == 0o600)
    }

    @Test func refusesAFolderOtherUsersCanEnter() throws {
        try FileManager.default.createDirectory(
            atPath: folder.path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755]
        )

        #expect(throws: AgentStorageError.unsafeDirectory) {
            try PairingStore(folder: folder).save(try makePhone())
        }
    }

    @Test func ignoresAFileThatIsNotAPairingRecord() throws {
        try FileManager.default.createDirectory(
            atPath: folder.path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        for content in ["", "not json", #"{"identityKey":"AAAA","sshKeyBlob":"AAAA"}"#] {
            FileManager.default.createFile(atPath: folder.path + "/paired-phone.json", contents: Data(content.utf8))
            #expect(PairingStore(folder: folder).load() == nil, "content: \(content)")
        }
    }

    // A hosted CI runner is a virtual machine without a Secure Enclave.
    @Test(.enabled(if: SecureEnclave.isAvailable))
    func keepsTheSameMacIdentityKeyAcrossRestarts() throws {
        let first = try MacIdentityKey.loadOrCreate(in: folder)
        let second = try MacIdentityKey.loadOrCreate(in: folder)

        #expect(first.publicKey == second.publicKey)
        #expect(first.publicKey.count == ChannelLimits.publicKeyLength)
        #expect(permissions(of: folder.path + "/mac-identity.key") == 0o600)
    }

    @Test(.enabled(if: SecureEnclave.isAvailable))
    func macIdentityKeyOpensAChannel() throws {
        let mac = try MacIdentityKey.loadOrCreate(in: folder)
        let phoneKey = P256.Signing.PrivateKey()
        let now = Date()

        // The Secure Enclave signs the hello: the phone accepts it against
        // the Mac's public key.
        let handshake = try MacHandshake(
            identity: mac, phoneIdentityKey: Array(phoneKey.publicKey.x963Representation), now: now
        )
        let hello = handshake.hello
        let signed = MacHello.signedBytes(
            version: hello.version, macFingerprint: hello.macFingerprint,
            phoneFingerprint: IdentityFingerprint.of(publicKey: Array(phoneKey.publicKey.x963Representation)),
            nonce: hello.nonce, ephemeralKey: hello.ephemeralKey, timestamp: hello.timestamp
        )
        let macKey = try P256.Signing.PublicKey(x963Representation: mac.publicKey)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: hello.signature)

        #expect(macKey.isValidSignature(signature, for: Data(signed)))
    }
}
