# SentryKey Mac agent

The Mac side of SentryKey: what `ssh` talks to. A Swift package with no third-party dependencies, built on `SentryKeyProtocol`.

**Status:** the ssh-agent socket and the request queue work, checked with a real OpenSSH 10.5 login. The phone is still a stand-in: there is no Bluetooth, no secure channel and no pairing yet, so this does not sign with an iPhone.

## What is in it

| Target | Contents |
|---|---|
| `SentryKeyAgent` | The agent's logic, as a library. |
| `SentryKeyAgentDevSupport` | `SoftwarePhone`, a stand-in phone with a software key. Development and tests only. |
| `sentrykey-agent-dev` | A command-line agent wired to the stand-in phone, to try the agent with a real `ssh`. |

Inside `SentryKeyAgent`:

| File | Role |
|---|---|
| `AgentSocket` | The Unix socket `ssh` connects to. Private folder (`0700`), private socket (`0600`), peers of another user refused, one thread per connection. |
| `AgentSession` | One connection: answers each ssh-agent message. Lists the phone's key, remembers the session-bind, sends sign requests to the queue. Everything else (adding, removing or locking keys) gets a failure. |
| `SigningQueue` | Sends one request at a time to the phone, matches each answer to its request by identifier, and gives up after 45 seconds. |
| `Ports` | The interfaces the rest plugs into: `PhoneLink` (the way to the phone), `PublicKeyStore`, `SignatureVerifying`. |
| `P256SignatureVerifier` | Checks the phone's signature with CryptoKit before `ssh` sees it. |

The menu bar app, the Bluetooth central and the Mac identity key are not here yet. They need an app bundle (for the Bluetooth permission) and will use this library: the Bluetooth central is one more `PhoneLink`.

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

35 tests, none of which sleeps: the queue's timeout is injected and fired by hand.

## Try it with a real ssh

```bash
Scripts/try-with-local-ssh.sh
```

The script starts a throwaway `sshd` on 127.0.0.1 (own configuration, host key and `authorized_keys` in a temporary folder), starts `sentrykey-agent-dev`, and logs in through it with each behaviour of the stand-in phone. Only the approving phone may get in. Add `--with-timeout` to also try the phone that never answers, which waits 45 seconds. Your `~/.ssh` and the system `sshd` are not touched.

By hand:

```bash
swift run sentrykey-agent-dev --socket /tmp/sentrykey-dev/agent.sock
# prints a public key line: add it to the server's authorized_keys, then
ssh -o IdentityAgent=/tmp/sentrykey-dev/agent.sock user@server
```

`--behaviour deny|silent|wrong-key|unreachable` makes the stand-in phone misbehave.

**The stand-in phone is not the product.** Its key is an ordinary key in the agent's memory, created at each start and never written to disk. It exists so the agent can be developed before the Bluetooth link does. It lives in its own target, which the real agent must never link.

## Security review

Needs line-by-line human review, as CLAUDE.md requires:

- `AgentSocket.swift`: socket permissions, the stale socket check, the peer check, and the bridge from a connection thread to async code.
- `AgentSession.swift`: which messages reach the phone, and the forwarding rule.
- `SigningQueue.swift`: matching answers to requests, and the timeout.
- `P256SignatureVerifier.swift` and `ECDSAP256.rawSignature(fromSignatureBlob:)` in `SentryKeyProtocol`: crypto and parsing.
