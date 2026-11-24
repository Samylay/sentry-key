# SentryKey Mac agent

The Mac side of SentryKey: what `ssh` talks to. A Swift package with no third-party dependencies, built on `SentryKeyProtocol`.

**Status:** the ssh-agent socket, the request queue and the secure channel work together, checked with a real OpenSSH 10.5 login. The phone is still a stand-in inside the same process: there is no Bluetooth and no pairing yet, so this does not sign with an iPhone.

## What is in it

| Target | Contents |
|---|---|
| `SentryKeyAgent` | The agent's logic, as a library. |
| `SentryKeyBluetooth` | The Mac as a Bluetooth central: `BluetoothPhoneConnector` (connections to the paired phone), `BluetoothPairing`, and the pairing code drawn in a terminal. **Never run**: see below. |
| `sentrykey-agent` | The real agent as a command-line tool: `pair`, then `run`. It links no development target. **Never run against an iPhone.** |
| `SentryKeyAgentDevSupport` | `SoftwarePhone`, a stand-in phone with a software key, `SoftwareIdentity`, and `LoopbackPhoneConnector`, an in-memory connection in place of Bluetooth. Development and tests only. |
| `sentrykey-agent-dev` | A command-line agent wired to the stand-in phone, to try the agent with a real `ssh`. |

Inside `SentryKeyAgent`:

| File | Role |
|---|---|
| `AgentSocket` | The Unix socket `ssh` connects to. Private folder (`0700`), private socket (`0600`), peers of another user refused, one thread per connection. |
| `AgentSession` | One connection: answers each ssh-agent message. Lists the phone's key, remembers the session-bind, sends sign requests to the queue. Everything else (adding, removing or locking keys) gets a failure. |
| `SigningQueue` | Sends one request at a time to the phone, matches each answer to its request by identifier, and gives up after 45 seconds. |
| `SecurePhoneLink` | The `PhoneLink` that goes through the secure channel: opens a connection, runs the handshake, seals each request and opens each answer. Keeps the connection for the next requests, and starts again with a new handshake after any error. |
| `Ports` | The interfaces the rest plugs into: `PhoneLink` (the way to the phone), `PhoneConnector` and `PhoneConnection` (a raw connection that carries messages, which Bluetooth will implement), `PublicKeyStore`, `SignatureVerifying`. |
| `P256SignatureVerifier` | Checks the phone's signature with CryptoKit before `ssh` sees it. |
| `PairingStore` | The agent's private folder on disk, the record of the paired phone (public keys only), and `MacIdentityKey`, the Mac identity key in the Mac's Secure Enclave. |

The menu bar app is not here yet. Until it is, `sentrykey-agent` is a command-line tool, with the text macOS requires before granting Bluetooth embedded in the binary.

## What the agent decides, and what it does not

The Mac is the untrusted side. The agent forwards the sign request and the session-bind to the phone, and the phone decides. The agent's own checks only do three things:

- spare the phone useless requests: a key that is not the phone's, key management messages;
- refuse a **forwarded** agent connection, so a remote host cannot ask for signatures through this Mac;
- protect `ssh` from a wrong answer: a signature that does not verify is dropped.

When the phone refuses, does not answer or cannot be reached, `ssh` gets a failure. There is no key on disk to fall back on, by design.

## Tests

```bash
swift test
```

57 tests, none of which sleeps: timeouts are injected and fired by hand.

## Try it with a real ssh

```bash
Scripts/try-with-local-ssh.sh
```

The script starts a throwaway `sshd` on 127.0.0.1 (own configuration, host key and `authorized_keys` in a temporary folder), starts `sentrykey-agent-dev`, and logs in through it with each behaviour of the stand-in phone. Only the approving phone may get in. Each login goes through the real handshake and AES-GCM channel, between the agent and the stand-in phone. Add `--with-timeout` to also try the phone that never answers, which waits 45 seconds. Your `~/.ssh` and the system `sshd` are not touched.

By hand:

```bash
swift run sentrykey-agent-dev --socket /tmp/sentrykey-dev/agent.sock
# prints a public key line: add it to the server's authorized_keys, then
ssh -o IdentityAgent=/tmp/sentrykey-dev/agent.sock user@server
```

`--behaviour deny|silent|wrong-key|unreachable` makes the stand-in phone misbehave.

**The stand-in phone is not the product.** Its key is an ordinary key in the agent's memory, created at each start and never written to disk. It exists so the agent can be developed before the Bluetooth link does. It lives in its own target, which the real agent must never link.

## With a real iPhone

```bash
swift run sentrykey-agent pair    # shows a QR code: scan it in the iPhone app
swift run sentrykey-agent run     # then point ssh at the socket it prints
```

**None of this has been run.** The Bluetooth code on both devices was written from Apple's documentation and checked by the compiler only: there was no Mac that could be used with the iPhone. Expect to fix things the first time. Known unknowns:

- whether macOS grants Bluetooth to a command-line tool from the usage text embedded in its binary, or only to the terminal it runs in;
- whether the Mac's stored identifier still reaches the phone after the phone's Bluetooth address rotates (an open question in the architecture);
- during pairing the Mac connects to the first device that advertises the SentryKey service. Another device advertising it nearby makes the pairing fail until the code expires. It cannot make a wrong phone pair.

## Security review

Needs line-by-line human review, as CLAUDE.md requires:

- `AgentSocket.swift`: socket permissions, the stale socket check, the peer check, and the bridge from a connection thread to async code.
- `AgentSession.swift`: which messages reach the phone, and the forwarding rule.
- `SigningQueue.swift`: matching answers to requests, and the timeout.
- `SecurePhoneLink.swift`: when a connection is opened, reused and dropped, and that sends stay in order.
- `BluetoothLink.swift` and `BluetoothPhone.swift`: everything received is untrusted, and pairing ignores any request that fails the check.
- `PairingStore.swift`: file permissions, and what the Mac identity key file does and does not protect.
- `P256SignatureVerifier.swift` and `ECDSAP256.rawSignature(fromSignatureBlob:)` in `SentryKeyProtocol`: crypto and parsing.
