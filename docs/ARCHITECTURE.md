# SentryKey architecture

> Revised after two design reviews (Apple platform and security, prompt P-004) and the team's decision to require Face ID for every signature (prompt P-005).

## Pitch

**SentryKey: your iPhone is your SSH key.**

Malicious npm and PyPI packages routinely steal developers' SSH keys from `~/.ssh`. With SentryKey, the key is created inside the iPhone's Secure Enclave and never leaves it, so there is nothing on the Mac to steal.

Every signature requires Face ID on the phone, enforced by the Secure Enclave itself, and the phone shows which server is asking, verified by the phone rather than reported by the Mac. Every signature is recorded in a tamper-evident log.

SentryKey works on the passkey model (challenge-response, non-exportable key, biometric approval on a separate device). SSH is its first integration.

## Why an iPhone and not the Mac's own Touch ID?

Apple silicon Macs also have a Secure Enclave and Touch ID, and tools such as Secretive already keep SSH keys there. The iPhone adds:

1. **A display the Mac cannot fake.** Malware on a compromised Mac controls its screen. It can trigger a Touch ID prompt when you expect one and use your touch to sign something else. The iPhone shows information it has verified itself.
2. **Device separation.** A signature needs the phone *and* your face. Compromising the Mac is not enough.
3. **One key for several Macs:** work, home, lab.
4. **It works on Macs without Touch ID,** or with the lid closed.

## Core technologies

All Apple frameworks. **No third-party dependencies.**

| Area | Technology |
|---|---|
| Language and UI | Swift, SwiftUI (iOS app + macOS menu bar app) |
| Keys | Secure Enclave on both devices via CryptoKit (see below) |
| Cryptography | CryptoKit: P-256 ECDSA (SSH signatures), ephemeral P-256 ECDH + HKDF + AES-GCM (channel), SHA-256 (log chain); Curve25519 / Security.framework to verify server host-key signatures |
| User authentication | LocalAuthentication (Face ID), foreground only |
| Transport | CoreBluetooth: the iPhone is a peripheral in the `bluetooth-peripheral` background mode, the Mac is the central |
| Pairing | QR code: generated with CoreImage on the Mac, scanned with AVFoundation on the iPhone |
| Notifications | UserNotifications, local only (no push; Time Sensitive notifications are not available on a free account) |
| SSH integration | Standard `ssh-agent` protocol over a Unix socket, plus OpenSSH's `session-bind@openssh.com` extension |
| Tests | XCTest / Swift Testing; signatures checked against `ssh-keygen -Y verify` and a real `ssh` login |
| Tools | Xcode (one workspace), Git/GitHub, LightBlue or nRF Connect for Bluetooth debugging |

## Keys

| Key | Where | Access control | Use |
|---|---|---|---|
| **SSH signing key** | iPhone Secure Enclave | `WhenUnlockedThisDeviceOnly` + `.privateKeyUsage` + `.biometryCurrentSet` | Signs SSH requests. Face ID on every use, enforced by the chip |
| **Phone identity key** | iPhone Secure Enclave | `AfterFirstUnlockThisDeviceOnly` + `.privateKeyUsage` | Authenticates the phone during the channel handshake |
| **Mac identity key** | Mac Secure Enclave (Apple silicon) | `.privateKeyUsage` | Authenticates the Mac during the channel handshake |
| **Backup SSH key** | Offline (generated at setup, kept on paper or another device) | — | Recovery if the phone is lost or Face ID is re-enrolled |

Keys are never reused across roles. The two devices only ever share **public** keys, exchanged once at pairing. Nothing syncs through iCloud: every Keychain item is `ThisDeviceOnly`.

**Recovery is mandatory.** A `biometryCurrentSet` key is destroyed if Face ID is re-enrolled, and it is lost with the phone. Setup therefore includes the backup key and a list of the servers each key is installed on, so keys can be revoked.

## Modules

```
sentry-key/                      One Xcode workspace
├── SentryKeyProtocol/           Local Swift package (iOS + macOS)
│   ├── Messages                 Message types, binary encoding, strict size/format checks
│   ├── Framing                  Splitting and reassembling messages over the BLE MTU
│   ├── Handshake                Ephemeral ECDH signed by both identity keys (forward secrecy)
│   ├── SecureChannel            HKDF → one AES-GCM key per direction, counter nonces
│   ├── AntiReplay               Monotonic counter; timestamp as a coarse window only
│   ├── Pairing                  QR payload, one-time pairing secret
│   └── SSHWire                  ssh-agent messages, SSH key/signature formats, mpint encoding,
│                                parsing of the data to be signed (USERAUTH, SSHSIG)
│
├── SentryKey-iOS/               iPhone app ("the sensor")
│   ├── KeyStore                 Secure Enclave keys, public key export in SSH format
│   ├── PairingView              QR scan, enrolment of the phone's keys
│   ├── BLEPeripheral            Advertising, state restoration, wake-up on write
│   ├── HostVerifier             Checks the server's session-bind signature; host-key fingerprint → name
│   ├── ApprovalFlow             Local notification → app in foreground → Face ID → signature
│   └── AuditLog                 Hash-chained log, chain head mirrored on the Mac
│
└── SentryKey-macOS/             Mac agent ("the hub"), not sandboxed
    ├── IdentityKey              Mac identity key in the Mac's Secure Enclave
    ├── SSHAgentServer           Unix socket, ssh-agent protocol, forwards session-bind
    ├── RequestQueue             Pending requests, timeouts, "phone unreachable" errors
    ├── BLECentral               Reconnects to the known iPhone without scanning
    ├── PairingWindow            Shows the QR code
    └── MenuBar                  Status, recent signatures, log viewer
```

The shared package holds all protocol, crypto and SSH-format code, so it is written and tested once. It is the part the security architect reviews line by line.

## Main flows

### Pairing (once, both devices in hand)
1. The Mac shows a QR code containing its identity public key and a **one-time pairing secret**. The QR is the out-of-band channel, so it authenticates the Mac to the phone.
2. The phone scans it, generates its Secure Enclave keys, and sends their public keys back over BLE, authenticated with the pairing secret. A man-in-the-middle who swaps the phone's keys cannot produce a valid authentication without the QR.
3. The Mac stores the phone's public keys and BLE identifier, and shows the SSH public key to install on servers. The pairing secret is discarded.
4. **Assumption to state in the threat model:** the Mac is not compromised at pairing time.

The Mac scans for the phone only during pairing, with the app in the foreground, because iOS hides advertised services from non-iOS scanners while the app is in the background. Afterwards, the Mac reconnects to the stored identifier with `retrievePeripherals(withIdentifiers:)` + `connect()`, which never times out, and repeats it after every disconnection.

### Channel (each connection)
1. Each side generates an ephemeral P-256 ECDH key and signs it with its identity key. Each verifies the other's signature with the key stored at pairing.
2. HKDF derives one AES-GCM key per direction, with a salt built from both session nonces and an `info` covering the protocol version, both identity fingerprints and the direction.
3. Nonces are a per-direction 96-bit counter. The connection is closed if a counter would wrap.
4. **How this meets "every message is signed":** the handshake is signed by both identity keys, and every following message is authenticated by AES-GCM under keys derived from it. Signing every message individually would add cost without stopping any additional attack.

### Signing (every SSH use)
1. `ssh` connects to a server and sends the agent a `session-bind@openssh.com` message: the server's host key, the session identifier, and the server's signature over it (OpenSSH 8.9 and later).
2. `ssh` sends a sign request. The Mac agent forwards both messages to the phone over the channel and keeps the request pending.
3. The phone checks it itself, **without trusting anything the Mac says about the host**:
   - the server's signature over the session identifier is valid for that host key;
   - the data to be signed is an SSH login request for that same session, or a git commit signature (SSHSIG) with the `git` namespace. Anything else is denied.
4. The phone posts a local notification. It shows the server, identified by its **host-key fingerprint** and the name the phone recorded on first use, and the username.
5. The user taps it, the app comes to the foreground, Face ID unlocks the key, and the Secure Enclave signs.
6. The phone returns the signature. The Mac waits about 30–60 seconds, then fails the request with a clear error.
7. The Mac agent converts the signature to SSH format and returns it to `ssh`.

**Anti-spam:** if prompts exceed a limit per minute, the phone denies new requests for a cooldown period. This stops "MFA fatigue" attacks that flood the user with prompts.

**Residual risk:** approval is bound to the server, not to the local process that asked. Malware on the Mac could open its own connection to a server you are about to approve and receive the signature. Because each Face ID gives exactly one signature, the attack needs your approval each time and is limited to servers you already use.

### Audit log
- Each entry records the time, the host-key fingerprint (not the name), the username, the decision and the hash of the previous entry.
- The latest chain head and counter are mirrored on the Mac, and each side checks the other's on reconnect. This detects a truncated or deleted log.
- Signing only happens with the phone unlocked and the app in the foreground, so the log can use `complete` file protection.

## Platform constraints that shape the design

- **Face ID needs the foreground.** That's why each signature needs a notification tap.
- **A woken app gets about 10 seconds:** enough to post the notification, not to run Face ID.
- **iOS does not relaunch the app after a force-quit**, and recent iOS versions don't relaunch it after Bluetooth is toggled off in Control Center or after Airplane Mode either. After a reboot, there is no relaunch until the first unlock. The Mac shows "Phone unreachable: open SentryKey". Record the iOS version used for tests.
- **State restoration is opt-in:** `CBPeripheralManagerOptionRestoreIdentifierKey` + `peripheralManager(_:willRestoreState:)`.
- **Mac agent signing:** sign with the free Personal Team "Apple Development" certificate, not ad hoc. Otherwise macOS asks for Bluetooth permission again after every build.
- **Pointing SSH at the agent:** use `IdentityAgent` in `~/.ssh/config`.
- **Info.plist keys:** `NSBluetoothAlwaysUsageDescription` (both apps), `NSFaceIDUsageDescription`, `NSCameraUsageDescription`.
- **The 7-day expiry:** re-run from Xcode before demos, but never delete the app, as that may destroy the Secure Enclave keys and force a re-pair.

## Scope by milestone

| Milestone | Scope |
|---|---|
| J3 MVP | Pairing, channel, Face ID signing, `ssh` and `git push` working. The host shown on the phone is still the one reported by the Mac, and labelled "unverified" |
| J4 hardening | Session-bind verification on the phone, audit log with mirrored head, prompt rate limit, backup key flow |
| Stretch | Git commit signing (SSHSIG), Mac proximity lock |

## Out of scope (deliberate)

- **Automatic (zero-touch) approval.** It needs a second key not gated on Face ID and a policy engine. The team judged the added complexity and audit surface not worth it.
- **A real web passkey (WebAuthn).** Being a passkey provider needs AutoFill and associated domains, which are not available on a free account. Acting as a USB security key for the Mac needs a restricted entitlement.
- **Unlocking the macOS login screen.**
- **Browser extensions.** A Chrome extension cannot serve `SSH_AUTH_SOCK`, and its Bluetooth access needs an open page and a user click.
- **iCloud sync of keys.** It is unavailable on a free account, and a secret shared with the Mac would defeat the design.
- **Any non-Apple dependency.**

## Open questions (to verify on the device)

- Can the Mac reliably wake the backgrounded app over BLE so it posts the notification? **Prototype this first.**
- Does the Mac's stored peripheral identifier survive the iPhone's Bluetooth address rotation once the devices are bonded?
- Do the Secure Enclave keys survive an app reinstall after the 7-day expiry?
- Is there a supported way for the Mac agent to lock the screen (for the proximity-lock stretch goal)?
- Exact limits: prompts per minute, cooldown length, request timeout.
