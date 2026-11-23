# SentryKey

**Your iPhone as a hardware SSH key for your Mac.**

Malicious npm/PyPI packages routinely search developer machines for `~/.ssh` and other plain-text credentials. With SentryKey, the SSH private key is generated inside the iPhone's Secure Enclave and never leaves it, so there is nothing on the Mac to steal.

Master 2 group project: *"Make the iPhone a security device"*.

## How it works

```sh
 ssh / git ──► SentryKey agent (Mac) ══ encrypted BLE channel ══► SentryKey app (iPhone)
               SSH_AUTH_SOCK                                     policy engine
               forwards sign requests                            Secure Enclave signs (P-256)
          ◄── signature ◄════════════════════════════════════════
```

1. **Pairing:** the Mac shows a QR code with its public key and fingerprint. The iPhone scans it and both sides confirm the fingerprint, then they derive a session channel (ECDH P-256 + HKDF + AES-GCM).
2. **Sign request:** `ssh` asks the Mac agent for a signature. The agent forwards the request (host, key, nonce, counter, timestamp) to the iPhone.
3. **Policy:** the iPhone decides whether to auto-approve, ask for Face ID, or deny (per-host rules, session approval, proximity, rate limits).
4. **Signature:** the Secure Enclave signs with an `ecdsa-sha2-nistp256` key protected by `biometryCurrentSet`. The Mac agent returns the signature to `ssh`.
5. **Log:** every decision is appended to a hash-chained, signed log.

**UX goal:** zero-touch by default, prompt only when something looks wrong.

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
| `docs/PROMPT_JOURNAL.md` | Mandatory log of every AI prompt used on the project |
| `docs/red-team/README.md` | Red team guide: attacker model, BLE primer, attack decision trees |
| `CONTRIBUTING.md` | Team rules: reviews, AI usage, commits |
| `.github/pull_request_template.md` | Review checklist applied to every merge |

The iOS app, the macOS agent and the security dossier will be added as the project progresses.
