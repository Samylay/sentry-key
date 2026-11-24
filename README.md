# SentryKey

**Your iPhone as a hardware SSH key for your Mac.**

Malicious npm/PyPI packages routinely search developer machines for `~/.ssh` and other plain-text credentials. With SentryKey, the SSH private key is generated inside the iPhone's Secure Enclave and never leaves it, so there is nothing on the Mac to steal.

Master 2 group project: *"Make the iPhone a security device"*.

## How it works

```sh
 ssh / git ──► SentryKey agent (Mac) ══ encrypted BLE channel ══► SentryKey app (iPhone)
               SSH_AUTH_SOCK                                     Face ID on every request
               forwards sign requests                            Secure Enclave signs (P-256)
          ◄── signature ◄════════════════════════════════════════
```

1. **Pairing:** the Mac shows a QR code with its public key and fingerprint. The iPhone scans it and both sides confirm the fingerprint, then they derive a session channel (ECDH P-256 + HKDF + AES-GCM).
2. **Sign request:** `ssh` asks the Mac agent for a signature. The agent forwards the request (host, key, nonce, counter, timestamp) to the iPhone.
3. **Approval:** the iPhone shows a local notification. The user opens it, reads the request (host, key) and approves with Face ID, or denies it. There is no auto-approval, no session approval and no reuse window: every signature needs its own Face ID.
4. **Signature:** the Secure Enclave signs with an `ecdsa-sha2-nistp256` key protected by `biometryCurrentSet`. Each request uses a fresh `LAContext`, so a previous Face ID can never be reused. The Mac agent returns the signature to `ssh`.
5. **Log:** every approval and denial is appended to a hash-chained, signed log.

**Security goal:** Face ID on every signature, enforced by the Secure Enclave rather than by app code. Even a bug in the app or a compromised Mac cannot get a signature without the user's face.

**Trade-off:** each `ssh` connection or `git push` costs one Face ID. We accept this cost in exchange for a guarantee that the hardware enforces.

## Constraints

- **Free Apple developer account:** no push notifications, iCloud, NFC, AutoFill or Network Extension. The installed app expires after 7 days, so reinstall from Xcode before every demo.
- **Test device:** iPhone 14 Pro.
- **Crypto:** CryptoKit only. No homemade crypto and no unvetted third-party dependencies.

## Milestones

| Milestone | Deliverable | Status |
|---|---|---|
| J1 · Scoping | Validated topic + [STRIDE threat model](docs/THREAT_MODEL.md) | ✅ |
| J2 · Architecture | Protocol diagram, justified crypto choices | ⏳ |
| J3 · MVP | `git push` signed by the iPhone | ⏳ |
| J4 · Cross-audit | Audit of another group's app (OWASP MASVS) + fixes to ours | ⏳ |
| J5 · Defense | Live demo + individual oral | ⏳ |

## Repository layout

| Path | Contents |
|---|---|
| `SentryKeyProtocol/` | Shared Swift package: SSH wire formats, ssh-agent messages, framing, approval checks. See its README |
| `SentryKey-iOS/` | iPhone app (SwiftUI) and its Xcode project. See its README |
| `SentryKey-macOS/` | Mac agent: the ssh-agent socket and the queue of sign requests, with a stand-in phone for development. See its README |
| `docs/UI_RESEARCH.md` | Real-app screens studied before designing the iPhone UI |
| `docs/BLE_WAKE_TEST.md` | The device test for the riskiest open question: does the Mac wake the backgrounded app over Bluetooth? Not run yet |
| `docs/PRODUCTION_CHECKLIST.md` | Everything that must change before SentryKey could ship: missing parts, temporary code, unmeasured limits, reviews owed |
| `docs/PROMPT_JOURNAL.md` | Mandatory log of every AI prompt used on the project |
| `docs/red-team/README.md` | Red team guide: attacker model, BLE primer, attack decision trees |
| `CONTRIBUTING.md` | Team rules: reviews, AI usage, commits |
| `.github/pull_request_template.md` | Review checklist applied to every merge |

Still to come: the Bluetooth link, the secure channel, real pairing, and the Mac menu bar app.
