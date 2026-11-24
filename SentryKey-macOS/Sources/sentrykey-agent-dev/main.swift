import Foundation
import SentryKeyAgent
import SentryKeyAgentDevSupport
import SentryKeyProtocol

// Development agent: the real ssh-agent socket, queue and secure channel,
// with a stand-in phone that holds a software key (see SoftwarePhone) and
// lives in this process instead of behind Bluetooth. For trying the agent
// with a real `ssh`. Not the product: the product's keys are on the iPhone
// and in the Mac's Secure Enclave.

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

private let usage = """
    usage: sentrykey-agent-dev --socket <path> [--behaviour approve|deny|silent|wrong-key|unreachable]
    """

private var socketPath: String?
private var behaviour = SoftwarePhone.Behaviour.approve
private var isPhoneReachable = true

private var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--socket":
        socketPath = arguments.next()
    case "--behaviour":
        switch arguments.next() {
        case "approve": behaviour = .approve
        case "deny": behaviour = .deny
        case "silent": behaviour = .neverAnswer
        case "wrong-key": behaviour = .signWithAnotherKey
        case "unreachable": isPhoneReachable = false
        default: fail(usage)
        }
    default:
        fail(usage)
    }
}
guard let socketPath else { fail(usage) }

@Sendable private func log(_ line: String) {
    FileHandle.standardError.write(Data(("sentrykey-agent-dev: " + line + "\n").utf8))
}

private let phone: SoftwarePhone
do {
    phone = try SoftwarePhone(behaviour: behaviour) { approval in
        // Stands for the phone's prompt. No host name: the Mac's idea of
        // which host this is cannot be trusted.
        log("stand-in phone approves a login as \(approval.userName) (host key type \(approval.hostKeyAlgorithm))")
    }
} catch {
    fail("cannot create the stand-in key: \(error)")
}

// Identity keys of the two devices. Software keys here; a Secure Enclave key
// on each device in the product. Pairing is what would exchange them.
private let macIdentity = SoftwareIdentity()
private let phoneIdentity = SoftwareIdentity()
private let macIdentityKey = macIdentity.publicKey

private let connector = LoopbackPhoneConnector(
    phoneIdentity: phoneIdentity,
    pairedMacKey: { $0 == IdentityFingerprint.of(publicKey: macIdentityKey) ? macIdentityKey : nil },
    answer: { await phone.answer(to: $0) }
)
connector.setReachable(isPhoneReachable)

private let link = SecurePhoneLink(
    identity: macIdentity, phoneIdentityKey: phoneIdentity.publicKey, connector: connector
)
private let queue = SigningQueue(link: link)
Task {
    for await response in link.responses {
        await queue.deliver(response)
    }
}

private let keys = FixedPublicKeyStore(
    identity: AgentIdentity(keyBlob: phone.publicKeyBlob, comment: "sentrykey-dev")
)
private let agentSocket = AgentSocket(path: socketPath) {
    AgentSession(keys: keys, queue: queue, verifier: P256SignatureVerifier()) { event in
        log("\(event)")
    }
}
do {
    try agentSocket.start()
} catch {
    fail("cannot open the socket at \(socketPath): \(error)")
}

// The public key line goes to standard output so a script can capture it.
// Written directly: `print` would keep it in a buffer when the output is a
// file or a pipe, and this program never exits normally to flush it.
private let publicKeyLine = try OpenSSHPublicKey.line(keyBlob: phone.publicKeyBlob, comment: "sentrykey-dev")
FileHandle.standardOutput.write(Data((publicKeyLine + "\n").utf8))
log("listening on \(socketPath). Use: ssh -o IdentityAgent=\(socketPath) ...")
log("DEVELOPMENT ONLY: this key is in memory on the Mac and is lost when the agent stops.")

// Removes the socket file on Ctrl-C or `kill`.
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
private let stopSources = [SIGINT, SIGTERM].map { number in
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
        agentSocket.stop()
        exit(0)
    }
    source.resume()
    return source
}
dispatchMain()
