import Foundation
import SentryKeyAgent
import SentryKeyBluetooth
import SentryKeyProtocol

// The SentryKey agent for the Mac, as a command-line tool until the menu
// bar app exists.
//
//   sentrykey-agent pair   show a pairing code and wait for the iPhone
//   sentrykey-agent run    serve ssh, sending sign requests to the iPhone
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
    """

private var arguments = CommandLine.arguments.dropFirst().makeIterator()
guard let command = arguments.next(), ["pair", "run"].contains(command) else { fail(usage) }

private var folderPath = NSHomeDirectory() + "/Library/Application Support/SentryKey"
private var socketPath: String?
while let argument = arguments.next() {
    switch argument {
    case "--folder":
        guard let value = arguments.next() else { fail(usage) }
        folderPath = value
    case "--socket":
        guard let value = arguments.next() else { fail(usage) }
        socketPath = value
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
