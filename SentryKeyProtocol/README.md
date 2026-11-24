# SentryKeyProtocol

The Swift package shared by the iPhone app and the Mac agent. It has no dependencies, and Xcode opens it directly (`Package.swift`).

## What is in it

| Folder | Contents |
|---|---|
| `SSHWire/` | Bounds-checked reader and writer for SSH wire types (RFC 4251). `ecdsa-sha2-nistp256` public key and signature blobs (RFC 5656), to and from CryptoKit's formats. |
| `Agent/` | ssh-agent requests and replies (RFC 9987), the `session-bind@openssh.com` extension, and the data `ssh` signs for a login, including OpenSSH's `publickey-hostbound-v00` variant. |
| `Framing/` | Length-prefixed framing for the agent socket, and splitting into chunks for BLE. |
| `Link/` | The messages the Mac agent and the phone exchange inside the secure channel: a sign request with its session-bind, a cancellation, and the phone's answer. Each carries a request identifier, so a late answer is never taken for the answer to the next request. |
| `Channel/` | The secure channel between the Mac and the phone: the two handshake messages, then AES-GCM messages with one key and one counter per direction. See below. |
| `Pairing/` | Pairing by QR code: the offer the Mac shows, the phone's request and the Mac's confirmation. See below. |
| `Approval/` | What the phone checks before it prompts: the login matches session-bind, the user name is safe to show, Ed25519 host key signature parts, fingerprints, server names recorded on first use, and the prompt rate limit. |

Not yet written: the recovery code.

**Security review:** everything here parses untrusted input from `ssh` or Bluetooth. It needs line-by-line human review, as CLAUDE.md requires.

## The secure channel

`Channel/SecureChannel.swift` uses CryptoKit only: P-256 ECDSA and ECDH, HKDF-SHA256 and AES-256-GCM. It follows the Channel section of `docs/ARCHITECTURE.md`.

1. The Mac sends `MacHello`: an ephemeral ECDH key, a random nonce and a timestamp, signed by the Mac identity key.
2. The phone checks, in this order, that the Mac is one it is paired with, that the signature is valid, and that the timestamp is within 5 minutes of its own clock. Only then does it use its identity key, to sign `PhoneHello`: its own ephemeral key and nonce, over everything both sides sent.
3. Both derive one AES-GCM key per direction with HKDF. The salt is the two nonces. The info holds the protocol version, both identity fingerprints and the direction.
4. Each message carries a counter and a timestamp, both authenticated. The counter is also the AES-GCM nonce. The receiver accepts only the next counter, so a message cannot be replayed, reordered or silently dropped, and a message sent back to its author fails because the directions have different keys.
5. After any failure the channel refuses everything: the connection is dropped and the next one starts with a new handshake and new keys.

**Choices made where the architecture is silent.** `docs/FLOWS.md` lists these as not specified. They are proposals, to be confirmed by the team and then written into the architecture:

- **The Mac speaks first**, because it opens the Bluetooth connection.
- **What each signature covers.** The Mac signs the version, both identity fingerprints, its nonce, its ephemeral key and the timestamp. The phone signs the version, both fingerprints, both nonces and both ephemeral keys. Each starts with a different label, so one can never be taken for the other.
- **The phone's freshness check is the signed timestamp**, since the Mac cannot sign the phone's nonce in a two-message handshake. A recorded `MacHello` replayed within the 5 minutes gets an answer but no channel: sealing a message needs the ephemeral private key. A third message would remove this dependence on the clocks.
- **The clock tolerance is 5 minutes**, for the handshake and for every message. Not measured.
- **`MacHello` names the Mac** by the fingerprint of its identity key, sent in clear, so a phone paired with several Macs knows which key to check. Someone listening can tell two connections come from the same Mac.

`Channel/ChannelSessions.swift` wraps this for each side: `MacChannelSession` and `PhoneChannelSession` take the messages received and return the messages to send, handshake first, then sign requests and their answers. They do no input or output, so the same code serves Bluetooth on the devices and an in-memory connection in tests.

The identity keys reach this code through the `IdentitySigner` protocol, so the same code runs with Secure Enclave keys on a device and with ordinary keys in tests.

CryptoKit does not exist on Linux. There, `SecureChannel.swift` and its tests compile to nothing, and the rest of the package builds and is tested as before.

## Pairing

`Pairing/Pairing.swift` uses CryptoKit's HMAC-SHA256. It follows the Pairing section of `docs/ARCHITECTURE.md`.

1. The Mac shows a QR code: its identity public key and a random 32-byte secret, valid for 2 minutes.
2. The phone scans it, creates its two keys, and sends their public halves with an HMAC, keyed with the secret, over the three keys involved.
3. The Mac checks the HMAC, records the phone's keys, and answers with an HMAC of its own over the same keys. The QR code is then spent.
4. The phone checks that answer. Only then is it paired.

The QR code is the one thing that does not cross the radio. It gives the phone the Mac's real key, and only the phone that saw the screen can compute the HMAC, so an attacker in Bluetooth range can neither swap a key nor pair in the phone's place.

**Choices made where the architecture is silent** (`docs/FLOWS.md` lists both as not specified). Proposals, to be confirmed by the team:

- **How the secret authenticates the keys:** an HMAC over a labelled transcript of all three public keys, with a different label on each side.
- **How long the QR code is valid:** 2 minutes, for one phone. A request with a wrong HMAC does not spend the code, or any device in range could cancel a pairing by answering first.

Also added: the Mac refuses a phone whose identity key and SSH key are the same key, since the architecture forbids one key in two roles.

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
