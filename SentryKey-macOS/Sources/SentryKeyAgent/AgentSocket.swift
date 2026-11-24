import Foundation
import os
import SentryKeyProtocol

public enum AgentSocketError: Error, Equatable {
    /// Longer than a Unix socket address allows (about 100 bytes).
    case pathTooLong
    /// The socket's folder exists but is not a private folder of this user.
    case unsafeDirectory
    /// Something else is at the socket path: another running agent, or a
    /// file that is not a socket. Nothing is deleted.
    case pathInUse
    case alreadyStarted
    case system(call: String, code: Int32)
}

/// The Unix socket ssh connects to (`IdentityAgent` in `~/.ssh/config`).
///
/// Each connection gets its own thread and its own `AgentSession`, and its
/// messages are answered strictly in order, as ssh expects. Threads rather
/// than tasks, because the socket calls block.
public final class AgentSocket: Sendable {
    /// ssh opens one or two connections per login. The limit only stops a
    /// local process from taking unlimited threads.
    public static let maxConnections = 16
    /// A connection that sends nothing for this long is closed.
    static let idleSeconds = 300
    /// A client that stops reading must not block a thread forever.
    static let writeTimeoutSeconds = 5

    private struct State {
        var listenDescriptor: Int32 = -1
        var stopDescriptor: Int32 = -1
        var connections = 0
    }

    private let path: String
    private let makeSession: @Sendable () -> AgentSession
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Entered while the accept thread runs, so `stop()` can wait for it.
    private let acceptThread = DispatchGroup()

    public init(path: String, makeSession: @escaping @Sendable () -> AgentSession) {
        self.path = path
        self.makeSession = makeSession
    }

    /// Creates the socket and starts accepting connections.
    public func start() throws {
        guard state.withLock({ $0.listenDescriptor }) == -1 else { throw AgentSocketError.alreadyStarted }
        let address = try UnixSocketAddress(path: path)
        try preparePrivateDirectory()
        try removeStaleSocket(address)

        let listenDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenDescriptor >= 0 else { throw AgentSocketError.system(call: "socket", code: errno) }
        do {
            guard address.withPointer({ bind(listenDescriptor, $0, $1) }) == 0 else {
                throw AgentSocketError.system(call: "bind", code: errno)
            }
            // The folder is already private; this is a second barrier.
            guard chmod(path, 0o600) == 0 else { throw AgentSocketError.system(call: "chmod", code: errno) }
            guard listen(listenDescriptor, 8) == 0 else { throw AgentSocketError.system(call: "listen", code: errno) }
        } catch {
            close(listenDescriptor)
            throw error
        }

        var pipeEnds: [Int32] = [-1, -1]
        guard pipe(&pipeEnds) == 0 else {
            close(listenDescriptor)
            throw AgentSocketError.system(call: "pipe", code: errno)
        }
        let stopReadDescriptor = pipeEnds[0]
        let stopWriteDescriptor = pipeEnds[1]
        state.withLock {
            $0.listenDescriptor = listenDescriptor
            $0.stopDescriptor = stopWriteDescriptor
        }
        acceptThread.enter()
        Thread.detachNewThread { [self] in
            acceptConnections(listenDescriptor: listenDescriptor, stopDescriptor: stopReadDescriptor)
        }
    }

    /// Stops accepting connections and returns once the socket file is
    /// removed. Connections already open finish on their own.
    public func stop() {
        let stopDescriptor = state.withLock { state -> Int32 in
            defer { state.stopDescriptor = -1 }
            return state.stopDescriptor
        }
        guard stopDescriptor >= 0 else { return }
        var byte: UInt8 = 0
        _ = write(stopDescriptor, &byte, 1)
        close(stopDescriptor)
        acceptThread.wait()
    }

    // MARK: Setup

    /// The socket's folder must belong to this user and be closed to
    /// everyone else, so no other account can reach or replace the socket.
    private func preparePrivateDirectory() throws {
        let directory = (path as NSString).deletingLastPathComponent
        if mkdir(directory, 0o700) == 0 { return }
        guard errno == EEXIST else { throw AgentSocketError.system(call: "mkdir", code: errno) }

        var info = stat()
        guard lstat(directory, &info) == 0 else { throw AgentSocketError.system(call: "lstat", code: errno) }
        let isDirectory = info.st_mode & S_IFMT == S_IFDIR
        let isOurs = info.st_uid == geteuid()
        let isPrivate = info.st_mode & 0o077 == 0
        guard isDirectory, isOurs, isPrivate else { throw AgentSocketError.unsafeDirectory }
    }

    /// Removes a socket left by an agent that is no longer running. Never
    /// removes anything else.
    private func removeStaleSocket(_ address: UnixSocketAddress) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            guard errno == ENOENT else { throw AgentSocketError.system(call: "lstat", code: errno) }
            return
        }
        guard info.st_mode & S_IFMT == S_IFSOCK else { throw AgentSocketError.pathInUse }

        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw AgentSocketError.system(call: "socket", code: errno) }
        defer { close(probe) }
        // An agent that answers is alive: leave it alone.
        guard address.withPointer({ connect(probe, $0, $1) }) != 0 else { throw AgentSocketError.pathInUse }
        guard unlink(path) == 0 else { throw AgentSocketError.system(call: "unlink", code: errno) }
    }

    // MARK: Connections

    private func acceptConnections(listenDescriptor: Int32, stopDescriptor: Int32) {
        defer {
            close(listenDescriptor)
            close(stopDescriptor)
            unlink(path)
            state.withLock { $0.listenDescriptor = -1 }
            acceptThread.leave()
        }
        while true {
            var descriptors = [
                pollfd(fd: listenDescriptor, events: Int16(POLLIN), revents: 0),
                pollfd(fd: stopDescriptor, events: Int16(POLLIN), revents: 0),
            ]
            let ready = poll(&descriptors, 2, -1)
            if ready < 0 && errno == EINTR { continue }
            // A byte or a hang-up on the stop pipe means `stop()` was called.
            guard ready > 0, descriptors[1].revents == 0 else { return }

            let connection = accept(listenDescriptor, nil, nil)
            guard connection >= 0 else { continue }
            guard isFromThisUser(connection), reserveConnection() else {
                close(connection)
                continue
            }
            configure(connection)
            Thread.detachNewThread { [self] in
                serve(connection)
                close(connection)
                state.withLock { $0.connections -= 1 }
            }
        }
    }

    private func reserveConnection() -> Bool {
        state.withLock { state in
            guard state.connections < Self.maxConnections else { return false }
            state.connections += 1
            return true
        }
    }

    /// The folder permissions already keep other accounts out. This check
    /// does not depend on them.
    private func isFromThisUser(_ connection: Int32) -> Bool {
        var user: uid_t = 0
        var group: gid_t = 0
        return getpeereid(connection, &user, &group) == 0 && user == geteuid()
    }

    private func configure(_ connection: Int32) {
        var enabled: Int32 = 1
        // A client that closes early must not kill the agent with SIGPIPE.
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var idle = timeval(tv_sec: Self.idleSeconds, tv_usec: 0)
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &idle, socklen_t(MemoryLayout<timeval>.size))
        var writeTimeout = timeval(tv_sec: Self.writeTimeoutSeconds, tv_usec: 0)
        setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &writeTimeout, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Reads messages and answers each one before reading the next. Returns
    /// when the client closes, goes idle, or sends something malformed.
    private func serve(_ connection: Int32) {
        let session = makeSession()
        var reassembler = Reassembler(maxMessageLength: AgentLimits.maxMessageLength)
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)

        while true {
            let count = read(connection, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return }

            guard let bodies = try? reassembler.append(buffer[0..<count]) else { return }
            for body in bodies {
                let response = waitFor { try? await session.handle(body: body) }
                guard let response, writeAll(response.encoded(), to: connection) else { return }
            }
        }
    }

    private func writeAll(_ bytes: [UInt8], to connection: Int32) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let count = bytes[sent...].withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return false }
            sent += count
        }
        return true
    }
}

/// Runs an async operation from a connection thread and blocks that thread
/// until it finishes. Only for threads this file created: blocking a thread
/// of the Swift concurrency pool this way could deadlock it.
private func waitFor<Result: Sendable>(_ operation: @escaping @Sendable () async -> Result) -> Result {
    let result = OSAllocatedUnfairLock<Result?>(initialState: nil)
    let finished = DispatchSemaphore(value: 0)
    Task {
        let value = await operation()
        result.withLock { $0 = value }
        finished.signal()
    }
    finished.wait()
    return result.withLock { $0 }!
}

/// A `sockaddr_un` for a path, in the form the socket calls take.
struct UnixSocketAddress {
    private var address = sockaddr_un()

    init(path: String) throws {
        let bytes = Array(path.utf8)
        // One byte is kept for the terminating zero.
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw AgentSocketError.pathTooLong
        }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    }

    func withPointer<Result>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> Result) -> Result {
        withUnsafePointer(to: address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}
