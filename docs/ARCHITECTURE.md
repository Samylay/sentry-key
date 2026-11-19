# SentryKey architecture

> Revised after two design reviews (Apple platform and security). See prompt journal entry P-004 for the findings and sources.

## Pitch

**SentryKey: your iPhone is your SSH key.**

Malicious npm and PyPI packages routinely steal developers' SSH keys from `~/.ssh`. With SentryKey, the keys are created inside the iPhone's Secure Enclave and never leave it, so there is nothing on the Mac to steal.

Everyday use needs no tap: with the phone nearby, `git push` just works. Sensitive servers require Face ID, and that rule is enforced by the Secure Enclave itself, not by app code. Every signature is recorded in a tamper-evident log.

**What SentryKey does not claim:** malware already running on the Mac can still *use* the low-risk key while the phone is reachable. It can never *steal* a key, and it can never use the high-security key without your face.

## Core technologies

All Apple frameworks. **No third-party dependencies.**

| Area | Technology |
|---|---|
| Language and UI | Swift, SwiftUI (iOS app + macOS menu bar app) |
| Keys | Secure Enclave via CryptoKit, two signing keys with different access control (see below) |
| Cryptography | CryptoKit: P-256 ECDSA (SSH signatures), ephemeral P-256 ECDH + HKDF + AES-GCM (channel), SHA-256 (log chain); Curve25519 / Security.framework to verify server host-key signatures |
| User authentication | LocalAuthentication (Face ID), foreground only |
| Transport | CoreBluetooth: the iPhone is a peripheral in the `bluetooth-peripheral` background mode, the Mac is the central |
| Pairing | QR code: generated with CoreImage on the Mac, scanned with AVFoundation on the iPhone |
| Notifications | UserNotifications, local only (no push; Time Sensitive notifications are not available on a free account) |
| SSH integration | Standard `ssh-agent` protocol over a Unix socket, plus OpenSSH's `session-bind@openssh.com` extension |
| Tests | XCTest / Swift Testing; signatures checked against `ssh-keygen -Y verify` and a real `ssh` login |
| Tools | Xcode (one workspace), Git/GitHub, LightBlue or nRF Connect for Bluetooth debugging |

## Keys: hardware-enforced tiers

The Secure Enclave cannot show Face ID from the background, and a key gated on Face ID needs it for every signature. "Zero-touch" and "Face ID" therefore cannot share one key. SentryKey uses two keys, which appear to SSH as two identities:

| Key | Access control | Use |
|---|---|---|
| **Everyday key** | `AfterFirstUnlockThisDeviceOnly` + `.privateKeyUsage` | Signs automatically when the policy allows, even with the phone locked in a pocket |
| **Strong key** | `WhenUnlockedThisDeviceOnly` + `.privateKeyUsage` + `.biometryCurrentSet` | Always requires Face ID; enforced by the Secure Enclave |
| **Channel identity key** | Secure Enclave key-agreement key | Authenticates the phone during the channel handshake; never used for SSH |

Each server decides which tier it accepts, through the public key listed in its `authorized_keys`. A production server lists only the strong key, so no bug in the app's policy code can auto-approve a login to it.

**Recovery is mandatory.** A `biometryCurrentSet` key is destroyed if Face ID is re-enrolled, and keys are lost with the phone. Setup includes generating a backup key kept offline, plus a list of the servers each key is installed on, so the keys can be revoked.

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
│   ├── KeyStore                 The three Secure Enclave keys, public key export in SSH format
│   ├── PairingView              QR scan, enrolment of the phone's keys
│   ├── BLEPeripheral            Advertising, state restoration, wake-up on write
│   ├── HostVerifier             Checks the server's session-bind signature; host-key fingerprint → name
│   ├── PolicyEngine             Decides auto / ask / deny for the everyday key
│   ├── ApprovalFlow             Local notification → app in foreground → Face ID → strong-key signature
│   └── AuditLog                 Hash-chained log, chain head mirrored on the Mac
│
└── SentryKey-macOS/             Mac agent ("the hub"), not sandboxed
    ├── SSHAgentServer           Unix socket, ssh-agent protocol, forwards session-bind
    ├── RequestQueue             Pending requests, timeouts, "phone unreachable" errors
    ├── BLECentral               Reconnects to the known iPhone without scanning
    ├── PairingWindow            Shows the QR code
    └── MenuBar                  Status, recent signatures, log viewer
```

The shared package holds all protocol, crypto and SSH-format code, so it is written and tested once. It is the part the security architect reviews line by line.

## Main flows

### Pairing (once, both devices in hand)
1. The Mac generates its identity key and shows a QR code containing its public key and a **one-time pairing secret**. The QR is the out-of-band channel, so it authenticates the Mac to the phone.
2. The phone scans it, generates its three Secure Enclave keys, and sends their public keys back over BLE, authenticated with the pairing secret. A man-in-the-middle who swaps the phone's keys cannot produce a valid authentication without the QR.
3. The Mac stores the phone's public keys and BLE identifier, and shows the two SSH public keys to install on servers. The pairing secret is discarded.
4. **Assumption to state in the threat model:** the Mac is not compromised at pairing time.

The Mac scans for the phone only during pairing, with the app in the foreground, because iOS hides advertised services from non-iOS scanners while the app is in the background. Afterwards, the Mac reconnects to the stored identifier with `retrievePeripherals(withIdentifiers:)` + `connect()`, which never times out, and repeats it after every disconnection.

### Channel (each connection)
1. Each side generates an ephemeral P-256 ECDH key and signs it with its identity key. Each verifies the other's signature with the key stored at pairing.
2. HKDF derives one AES-GCM key per direction, with a salt built from both session nonces and an `info` covering the protocol version, both identity fingerprints and the direction.
3. Nonces are a per-direction 96-bit counter. The connection is closed if a counter would wrap.
4. **How this meets "every message is signed":** the handshake is signed by both long-term keys, and every following message is authenticated by AES-GCM under keys derived from it. Signing every message individually would add cost without stopping any additional attack.

### Signing (every SSH use)
1. `ssh` connects to a server and sends the agent a `session-bind@openssh.com` message: the server's host key, the session identifier, and the server's signature over it (OpenSSH 8.9 and later).
2. `ssh` sends a sign request. The Mac agent forwards both messages to the phone over the channel and keeps the request pending.
3. The phone checks it itself, **without trusting anything the Mac says about the host**:
   - the server's signature over the session identifier is valid for that host key;
   - the data to be signed is an SSH login request for that same session, or a git commit signature (SSHSIG) with the `git` namespace; anything else is denied.
4. The host is identified by its **host-key fingerprint**. The phone keeps its own fingerprint → name list, set on first use with Face ID.
5. Decision:
   - **Everyday key, auto-approve:** known host key, within the rate limits, Mac unlocked and connected.
   - **Everyday key, ask:** first use of a host key, rate limit reached, or a request without session-bind. A local notification is shown.
   - **Strong key:** always ask.
   - **Deny:** invalid signature, wrong data format, or the prompt limit is reached (to stop notification spam).
6. "Ask" path: the user taps the notification, the app comes to the foreground, Face ID runs, the phone signs, and it returns the signature. The Mac waits about 30–60 seconds, then fails the request with a clear error.
7. The Mac agent converts the signature to SSH format and returns it to `ssh`.

**Residual risk:** malware on the Mac can open a genuine connection to a server whose host key the phone already trusts, and get an everyday-key signature within the rate limits. This is why sensitive servers accept only the strong key.

### Audit log
- Each entry records the time, the key used, the host-key fingerprint (not the name), the decision and the hash of the previous entry.
- The latest chain head and counter are mirrored on the Mac, and each side checks the other's on reconnect. This detects a truncated or deleted log.
- The file uses `completeUntilFirstUserAuthentication` protection, so auto-approved signatures can be logged while the phone is locked.

## Platform constraints that shape the design

- **Face ID needs the foreground.** That's why the strong key needs a notification tap.
- **A woken app gets about 10 seconds.** That's enough for an auto-approved signature, not for a Face ID prompt.
- **iOS does not relaunch the app after a force-quit**, and recent iOS versions don't relaunch it after Bluetooth is toggled off in Control Center or after Airplane Mode either. After a reboot, there is no relaunch until the first unlock. The Mac shows "Phone unreachable: open SentryKey". Record the iOS version used for tests.
- **State restoration is opt-in:** `CBPeripheralManagerOptionRestoreIdentifierKey` + `peripheralManager(_:willRestoreState:)`.
- **Mac agent signing:** sign with the free Personal Team "Apple Development" certificate, not ad hoc. Otherwise macOS asks for Bluetooth permission again after every build.
- **Pointing SSH at the agent:** use `IdentityAgent` in `~/.ssh/config`.
- **Info.plist keys:** `NSBluetoothAlwaysUsageDescription` (both apps), `NSFaceIDUsageDescription`, `NSCameraUsageDescription`.
- **The 7-day expiry:** re-run from Xcode before demos, but never delete the app, as that may destroy the Secure Enclave keys and force a re-pair.

## Scope by milestone

| Milestone | Scope |
|---|---|
| J3 MVP | Pairing, channel, strong key only (Face ID for every signature), `ssh` and `git push` working |
| J4 hardening | Session-bind verification, everyday key + policy engine, rate limits, audit log with mirrored head |
| Stretch | Git commit signing, BLE proximity as a usability signal, Mac proximity lock |

## Out of scope (deliberate)

- **Unlocking the macOS login screen.**
- **Browser extensions.** A Chrome extension cannot serve `SSH_AUTH_SOCK`, and its Bluetooth access needs an open page and a user click.
- **Push notifications, iCloud, NFC:** not available on a free Apple account.
- **Any non-Apple dependency.**
- **Proximity as a security control.** BLE has no distance measurement and can be relayed, and malware on the Mac is already next to the phone. Proximity can only be a usability signal.

## Open questions (to verify on the device)

- Can the Mac reliably wake the backgrounded app over BLE? **Prototype this first.**
- Does the Mac's stored peripheral identifier survive the iPhone's Bluetooth address rotation once the devices are bonded?
- Do the Secure Enclave keys survive an app reinstall after the 7-day expiry?
- Is there a supported way for the Mac agent to lock the screen (for the proximity-lock stretch goal)?
- Exact limits: requests per minute, prompts per minute, request timeout.
