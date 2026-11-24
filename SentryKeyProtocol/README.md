# SentryKeyProtocol

The Swift package shared by the iPhone app and the Mac agent. It has no dependencies, and Xcode opens it directly (`Package.swift`).

## What is in it

| Folder | Contents |
|---|---|
| `SSHWire/` | Bounds-checked reader and writer for SSH wire types (RFC 4251). `ecdsa-sha2-nistp256` public key and signature blobs (RFC 5656), to and from CryptoKit's formats. |
| `Agent/` | ssh-agent requests and replies (RFC 9987), the `session-bind@openssh.com` extension, and the data `ssh` signs for a login, including OpenSSH's `publickey-hostbound-v00` variant. |
| `Framing/` | Length-prefixed framing for the agent socket, and splitting into chunks for BLE. |
| `Link/` | The messages the Mac agent and the phone exchange inside the secure channel: a sign request with its session-bind, a cancellation, and the phone's answer. Each carries a request identifier, so a late answer is never taken for the answer to the next request. |
| `Approval/` | What the phone checks before it prompts: the login matches session-bind, the user name is safe to show, Ed25519 host key signature parts, fingerprints, server names recorded on first use, and the prompt rate limit. |

Not yet written, because it needs CryptoKit on a Mac: the handshake, the secure channel, anti-replay, pairing and the recovery code.

**Security review:** everything here parses untrusted input from `ssh` or Bluetooth. It needs line-by-line human review, as CLAUDE.md requires.

## Running the tests

On a Mac, from this folder:

```bash
swift test
```

On Linux, with Apple's official Swift image:

```bash
docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD":/pkg:ro -w /pkg swift:6.2-noble swift test --scratch-path /tmp/build
```

## Where the test vectors come from

`Tests/SentryKeyProtocolTests/CapturedVectors.swift` holds bytes from a real OpenSSH 10.2 login on 2026-11-23:

1. A throwaway `sshd` ran on 127.0.0.1, with its own configuration, host key and `authorized_keys` in a temporary folder.
2. A stand-in agent, a short Python script using the `cryptography` package, listened on a socket and signed with a throwaway P-256 key.
3. `ssh -o IdentityAgent=<socket>` logged in through it, and `sshd` accepted the signature.
4. Every request and reply was recorded. A real `ssh-agent` was also queried to confirm the reply codes (identities answer 12, failure 5).

The tests therefore check our encodings against bytes a real client sent and a real server accepted, not against our own reading of the RFCs.

The user name in the signed data was replaced with `tester` (same length) before committing, so that signature no longer verifies over the stored data. The test private key was not kept. The Python script is not in the repository, because the `cryptography` package is a dependency the team has not vetted.
