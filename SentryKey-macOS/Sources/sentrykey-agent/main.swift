import Foundation
import SentryKeyAgent
import SentryKeyBluetooth
import SentryKeyProtocol

// The SentryKey agent for the Mac, as a command-line tool until the menu
// bar app exists.
//
//   sentrykey-agent pair   show a pairing code and wait for the iPhone
//   sentrykey-agent run    serve ssh, sending sign requests to the iPhone
//   sentrykey-agent probe  measure whether and how fast the iPhone answers
//
// NOT YET RUN AGAINST AN IPHONE. The Bluetooth half is checked by the
// compiler only.

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("sentrykey-agent: " + message + "\n").utf8))
    exit(1)
}

@Sendable private func log(_ line: String) {
    FileHandle.standardError.write(Data(("sentrykey-agent: " + line + "\n").utf8))
}

private let usage = """
    usage: sentrykey-agent pair [--folder <path>]
           sentrykey-agent run  [--folder <path>] [--socket <path>]
           sentrykey-agent probe [--folder <path>] [--count <n>] [--interval <seconds>] [--reconnect]
    """

private var arguments = CommandLine.arguments.dropFirst().makeIterator()
guard let command = arguments.next(), ["pair", "run", "probe"].contains(command) else { fail(usage) }

private var folderPath = NSHomeDirectory() + "/Library/Application Support/SentryKey"
private var socketPath: String?
private var probeCount = 10
private var probeInterval = 30
private var probeReconnects = false
while let argument = arguments.next() {
    switch argument {
    case "--folder":
        guard let value = arguments.next() else { fail(usage) }
        folderPath = value
    case "--socket":
        guard let value = arguments.next() else { fail(usage) }
        socketPath = value
    case "--count":
        guard let value = arguments.next().flatMap(Int.init), value > 0 else { fail(usage) }
        probeCount = value
    case "--interval":
        guard let value = arguments.next().flatMap(Int.init), value >= 0 else { fail(usage) }
        probeInterval = value
    case "--reconnect":
        probeReconnects = true
    default:
        fail(usage)
    }
}

private let folder = AgentFolder(path: folderPath)
private let store = PairingStore(folder: folder)
private let identity: SecureEnclaveIdentity
do {
    identity = try MacIdentityKey.loadOrCreate(in: folder)
} catch {
    fail("cannot use the Mac identity key in \(folderPath): \(error)")
}

switch command {
case "pair":
    Task {
        do {
            let result = try await BluetoothPairing.pair(identity: identity) { code in
                print("On the iPhone, open SentryKey and scan this code. It is valid for 2 minutes.\n")
                print((TerminalQRCode.lines(for: code) ?? [code]).joined(separator: "\n"))
                print("")
            }
            try store.save(result.phone, bluetoothIdentifier: result.phoneIdentifier)
            print("Paired. Install this public key on the servers you log in to:\n")
            print(try OpenSSHPublicKey.line(keyBlob: result.phone.sshKeyBlob, comment: "sentrykey"))
            exit(0)
        } catch {
            fail("pairing failed: \(error)")
        }
    }

case "probe":
    // Answers the architecture's first open question, on a real iPhone:
    // does the phone still answer the Mac when its app is in the
    // background, or the phone locked? See docs/BLE_WAKE_TEST.md.
    //
    // Each probe is a sign request the phone refuses at once, without
    // showing anything: its data is not an SSH login. A refusal therefore
    // proves the app woke up, ran the handshake and read the request.
    guard let phone = store.load(), let phoneIdentifier = store.bluetoothIdentifier() else {
        fail("no paired iPhone. Run: sentrykey-agent pair")
    }
    let count = probeCount
    let interval = probeInterval
    let reconnects = probeReconnects
    Task {
        @Sendable func makeQueue() -> SigningQueue {
            let link = SecurePhoneLink(
                identity: identity, phoneIdentityKey: phone.identityKey,
                connector: BluetoothPhoneConnector(phoneIdentifier: phoneIdentifier)
            )
            let queue = SigningQueue(link: link) { try? await Task.sleep(for: .seconds(15)) }
            Task {
                for await response in link.responses {
                    await queue.deliver(response)
                }
            }
            return queue
        }
        var queue = makeQueue()
        var answered = 0
        for number in 1...count {
            // A new link drops the connection, so each probe also measures
            // connecting again and a new handshake.
            if reconnects, number > 1 { queue = makeQueue() }
            let start = ContinuousClock.now
            let outcome = await queue.sign(keyBlob: phone.sshKeyBlob, data: [0], bind: nil)
            let seconds = Double((ContinuousClock.now - start).components.seconds)
                + Double((ContinuousClock.now - start).components.attoseconds) / 1e18
            let time = String(format: "%.2f s", seconds)
            switch outcome {
            case .refused(.invalidRequest):
                answered += 1
                print("probe \(number)/\(count): answered in \(time)")
            case .timedOut:
                print("probe \(number)/\(count): NO ANSWER after \(time) (connected, phone silent)")
            case .phoneUnreachable:
                print("probe \(number)/\(count): UNREACHABLE after \(time) (no connection or no handshake)")
            default:
                print("probe \(number)/\(count): unexpected answer \(outcome) after \(time)")
            }
            if number < count { try? await Task.sleep(for: .seconds(interval)) }
        }
        print("\(answered) of \(count) probes answered.")
        exit(answered == count ? 0 : 1)
    }

default:
    guard let phone = store.load(), let phoneIdentifier = store.bluetoothIdentifier() else {
        fail("no paired iPhone. Run: sentrykey-agent pair")
    }
    let link = SecurePhoneLink(
        identity: identity, phoneIdentityKey: phone.identityKey,
        connector: BluetoothPhoneConnector(phoneIdentifier: phoneIdentifier)
    )
    let queue = SigningQueue(link: link)
    Task {
        for await response in link.responses {
            await queue.deliver(response)
        }
    }
    let path = socketPath ?? folder.path + "/agent.sock"
    let agentSocket = AgentSocket(path: path) {
        // Event kinds only: no host name, user name or key in the output.
        AgentSession(keys: store, queue: queue, verifier: P256SignatureVerifier()) { event in
            log("\(event)")
        }
    }
    do {
        try agentSocket.start()
    } catch {
        fail("cannot open the socket at \(path): \(error)")
    }
    log("listening on \(path)")
    log("in ~/.ssh/config:  IdentityAgent \"\(path)\"")

    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    for number in [SIGINT, SIGTERM] {
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler {
            agentSocket.stop()
            exit(0)
        }
        source.resume()
        // Kept alive for the life of the process.
        _ = Unmanaged.passRetained(source as AnyObject)
    }
}
dispatchMain()
