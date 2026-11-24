import Foundation
@testable import SentryKeyAgent
import SentryKeyProtocol
import Testing

/// A folder for one test's socket, removed when the test ends.
private final class TemporaryFolder {
    let path: String

    /// Short on purpose: a socket path is limited to about 100 bytes.
    init() {
        path = NSTemporaryDirectory() + "sk-" + String(UInt32.random(in: 0...UInt32.max), radix: 16)
    }

    var socketPath: String { path + "/agent.sock" }

    func create(permissions: Int) throws {
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: permissions]
        )
    }

    deinit {
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// A blocking client, playing ssh.
private final class TestClient {
    private let descriptor: Int32

    init(path: String) throws {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        let address = try UnixSocketAddress(path: path)
        guard address.withPointer({ connect(descriptor, $0, $1) }) == 0 else {
            throw AgentSocketError.system(call: "connect", code: errno)
        }
        // A test that gets no answer fails instead of hanging.
        var limit = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
    }

    deinit {
        close(descriptor)
    }

    func send(_ bytes: [UInt8]) {
        _ = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    }

    func sendMessage(body: [UInt8]) {
        var framed = WireWriter()
        framed.writeString(body)
        send(framed.bytes)
    }

    /// The next complete message, length prefix included, or nil when the
    /// agent closed the connection.
    func readMessage() -> [UInt8]? {
        guard let prefix = readExactly(4) else { return nil }
        let length = prefix.reduce(0) { $0 << 8 | Int($1) }
        guard let body = readExactly(length) else { return nil }
        return prefix + body
    }

    private func readExactly(_ count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        var received = 0
        while received < count {
            let step = bytes[received...].withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            guard step > 0 else { return nil }
            received += step
        }
        return bytes
    }
}

private func permissions(of path: String) -> mode_t {
    var info = stat()
    lstat(path, &info)
    return info.st_mode & 0o777
}

// Serialized: every test blocks its thread on socket calls.
@Suite("Agent socket", .serialized)
struct AgentSocketTests {
    private let folder = TemporaryFolder()
    private let identity = AgentIdentity(keyBlob: [1, 2, 3], comment: "phone")

    private func makeSocket() -> AgentSocket {
        let keys = FixedPublicKeyStore(identity: identity)
        let queue = SigningQueue(link: RecordingLink(), waitForTimeout: ManualTimeout().wait)
        return AgentSocket(path: folder.socketPath) {
            AgentSession(keys: keys, queue: queue, verifier: P256SignatureVerifier())
        }
    }

    @Test func answersAClientOverTheSocket() throws {
        let agent = makeSocket()
        try agent.start()
        defer { agent.stop() }

        let client = try TestClient(path: folder.socketPath)
        client.sendMessage(body: AgentRequestBody.requestIdentities)

        #expect(client.readMessage() == AgentResponse.identities([identity]).encoded())
    }

    @Test func answersSeveralMessagesInOrderOnOneConnection() throws {
        let agent = makeSocket()
        try agent.start()
        defer { agent.stop() }

        let client = try TestClient(path: folder.socketPath)
        client.sendMessage(body: AgentRequestBody.requestIdentities)
        client.sendMessage(body: [19])
        client.sendMessage(body: AgentRequestBody.requestIdentities)

        #expect(client.readMessage() == AgentResponse.identities([identity]).encoded())
        #expect(client.readMessage() == AgentResponse.failure.encoded())
        #expect(client.readMessage() == AgentResponse.identities([identity]).encoded())
    }

    @Test func keepsTheSocketAndItsFolderPrivate() throws {
        let agent = makeSocket()
        try agent.start()
        defer { agent.stop() }

        #expect(permissions(of: folder.path) == 0o700)
        #expect(permissions(of: folder.socketPath) == 0o600)
    }

    @Test func closesTheConnectionOnAnOversizedMessage() throws {
        let agent = makeSocket()
        try agent.start()
        defer { agent.stop() }

        let client = try TestClient(path: folder.socketPath)
        client.send([0x7F, 0xFF, 0xFF, 0xFF])

        #expect(client.readMessage() == nil)
    }

    @Test func closesTheConnectionOnAMalformedMessage() throws {
        let agent = makeSocket()
        try agent.start()
        defer { agent.stop() }

        let client = try TestClient(path: folder.socketPath)
        client.sendMessage(body: [AgentMessageType.signRequest.rawValue, 0])

        #expect(client.readMessage() == nil)
    }

    @Test func refusesAFolderOtherUsersCanEnter() throws {
        try folder.create(permissions: 0o755)

        #expect(throws: AgentSocketError.unsafeDirectory) { try makeSocket().start() }
    }

    @Test func neverDeletesAFileThatIsNotASocket() throws {
        try folder.create(permissions: 0o700)
        FileManager.default.createFile(atPath: folder.socketPath, contents: Data("keep me".utf8))

        #expect(throws: AgentSocketError.pathInUse) { try makeSocket().start() }
        #expect(FileManager.default.contents(atPath: folder.socketPath) == Data("keep me".utf8))
    }

    @Test func doesNotTakeOverARunningAgent() throws {
        let running = makeSocket()
        try running.start()
        defer { running.stop() }

        #expect(throws: AgentSocketError.pathInUse) { try makeSocket().start() }

        let client = try TestClient(path: folder.socketPath)
        client.sendMessage(body: AgentRequestBody.requestIdentities)
        #expect(client.readMessage() != nil)
    }

    @Test func replacesTheSocketOfAnAgentThatDied() throws {
        try folder.create(permissions: 0o700)
        // A socket file nobody listens on, as a killed agent leaves behind.
        let dead = socket(AF_UNIX, SOCK_STREAM, 0)
        let address = try UnixSocketAddress(path: folder.socketPath)
        #expect(address.withPointer { bind(dead, $0, $1) } == 0)
        close(dead)

        let agent = makeSocket()
        try agent.start()
        defer { agent.stop() }

        let client = try TestClient(path: folder.socketPath)
        client.sendMessage(body: AgentRequestBody.requestIdentities)
        #expect(client.readMessage() != nil)
    }

    @Test func removesTheSocketFileWhenStopped() throws {
        let agent = makeSocket()
        try agent.start()
        #expect(FileManager.default.fileExists(atPath: folder.socketPath))

        agent.stop()

        #expect(!FileManager.default.fileExists(atPath: folder.socketPath))
    }

    @Test func refusesAPathTooLongForASocket() {
        let agent = AgentSocket(path: "/tmp/" + String(repeating: "a", count: 200)) {
            fatalError("no connection is expected")
        }

        #expect(throws: AgentSocketError.pathTooLong) { try agent.start() }
    }

    @Test func cannotBeStartedTwice() throws {
        let agent = makeSocket()
        try agent.start()
        defer { agent.stop() }

        #expect(throws: AgentSocketError.alreadyStarted) { try agent.start() }
    }
}
