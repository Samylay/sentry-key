# SentryKey flow diagrams

Diagrams of the flows described in [ARCHITECTURE.md](ARCHITECTURE.md). If the two disagree, ARCHITECTURE.md is the reference. GitHub renders the Mermaid blocks below.

## 1. Overview and trust boundaries

The iPhone decides. The Mac and the Bluetooth link only carry messages, and the phone does not trust them about which server is asking.

```mermaid
flowchart LR
  subgraph MAC["Mac: relays requests, not trusted about the host"]
    SSH["ssh / git"]
    AGENT["SentryKey agent<br/>(menu bar app)"]
    MSE[("Mac Secure Enclave<br/>Mac identity key")]
    MIRROR[("Mirrored log head")]
    SSH -- "ssh-agent protocol<br/>SSH_AUTH_SOCK" --> AGENT
    AGENT --- MSE
    AGENT --- MIRROR
  end

  subgraph PHONE["iPhone: verifies and decides"]
    APP["SentryKey app"]
    PSE[("iPhone Secure Enclave<br/>SSH signing key<br/>phone identity key")]
    LOG[("Hash-chained audit log")]
    USER(("You<br/>tap + Face ID"))
    APP --- PSE
    APP --- LOG
    USER --> APP
  end

  SERVER["SSH server / GitHub"]

  SSH <-- "SSH session<br/>(host key signs the session ID)" --> SERVER
  AGENT <-- "BLE link, encrypted with AES-GCM<br/>(the radio itself is untrusted)" --> APP
```

## 2. Pairing (once, both devices in hand)

The QR code is the out-of-band channel: it proves the Mac's key to the phone, and the one-time secret lets the Mac check that the phone's keys came from the phone that scanned it.

```mermaid
sequenceDiagram
  autonumber
  actor U as You
  participant M as Mac agent
  participant P as iPhone app

  Note over M,P: Assumption: the Mac is not compromised at pairing time
  M->>M: Generate a one-time pairing secret
  M->>U: Show QR code: Mac identity public key + pairing secret
  U->>P: Scan the QR code with the camera
  P->>P: Generate Secure Enclave keys: SSH signing key, phone identity key
  P->>M: BLE: phone public keys, authenticated with the pairing secret
  M->>M: Verify, store the phone's public keys and BLE identifier
  M->>M: Discard the pairing secret
  M->>U: Show the SSH public key to install on servers
  Note over U: Install the offline backup key on the same servers (J4)
```

## 3. Secure channel (every BLE connection)

Both sides sign a fresh ECDH key with their identity key, so each connection gets new keys (forward secrecy). Every later message is authenticated by AES-GCM under those keys.

```mermaid
sequenceDiagram
  participant M as Mac agent
  participant P as iPhone app

  M->>P: Ephemeral ECDH public key + nonce, signed by the Mac identity key
  P->>M: Ephemeral ECDH public key + nonce, signed by the phone identity key
  Note over M,P: Each side checks the other's signature with the public key stored at pairing
  Note over M,P: ECDH shared secret → HKDF → one AES-GCM key per direction<br/>HKDF salt: both nonces<br/>HKDF info: protocol version, both fingerprints, direction
  M->>P: AES-GCM message, nonce = per-direction counter
  P->>M: AES-GCM message, nonce = per-direction counter
  Note over M,P: If a counter would wrap, close the connection
```

## 4. Signing (every `ssh` login or `git push`)

```mermaid
sequenceDiagram
  autonumber
  participant S as SSH server
  participant C as ssh / git (Mac)
  participant M as Mac agent
  participant P as iPhone app
  actor U as You

  C->>S: Connect and run the key exchange
  S-->>C: Host key + its signature over the session ID
  C->>M: session-bind@openssh.com: host key, session ID, server signature
  C->>M: Sign request: the data to sign
  M->>P: Forward both over the secure channel
  Note over M: Request pending, timeout about 30 to 60 s

  Note over P: Woken in the background, about 10 s: enough to post a notification, not to run Face ID
  P->>P: Verify the server's signature over the session ID (J4)
  P->>P: Check the data is a login for that session, or a git signature (SSHSIG), otherwise deny
  P->>P: Prompt rate limit: too many prompts per minute means deny (J4)
  P->>U: Local notification: host-key fingerprint, recorded name, username
  U->>P: Tap: the app comes to the foreground
  U->>P: Face ID
  P->>P: The Secure Enclave signs (P-256)
  P->>P: Append the decision to the audit log
  P->>M: Signature
  M->>M: Convert to SSH signature format
  M->>C: Signature
  C->>S: Authentication succeeds

  alt No answer before the timeout
    M-->>C: Failure: "Phone unreachable: open SentryKey"
  end
```

**J3 MVP difference:** before session-bind verification lands in J4, the phone shows the host name reported by the Mac and labels it "unverified".
