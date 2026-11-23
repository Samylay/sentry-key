# CLAUDE.md

Instructions for Claude Code sessions on this repository. This is a graded Master 2 group project, and AI usage itself is assessed. Follow these rules over your own defaults.

## Project

**SentryKey** makes the iPhone a hardware SSH key for the Mac.
- The private key (`ecdsa-sha2-nistp256`) is generated in the iPhone's Secure Enclave and never leaves it.
- A Mac agent speaks the `ssh-agent` protocol on `SSH_AUTH_SOCK` and forwards sign requests to the iPhone over an encrypted BLE channel.
- **Every signature requires Face ID**, enforced by the Secure Enclave. The phone shows the server it has verified itself.
- Every signature is appended to a hash-chained log.

Automatic (zero-touch) approval was considered and deliberately rejected as too complex (prompt P-005). Don't reintroduce it unless the team asks.

`docs/ARCHITECTURE.md` is the reference design. Read it before writing code, and keep it in sync when the design changes. `docs/PROMPT_JOURNAL.md` holds the history of design decisions.

## Hard constraints

- **Free Apple developer account.** Not available: push notifications (APNs), iCloud/CloudKit, Core NFC, native password AutoFill, associated domains, Network Extension, Family Controls. Never propose a design that depends on them. The installed app expires after 7 days.
- **Available:** camera, Vision, Core ML, Core Motion, location (including background), BLE (including background modes), Keychain, Secure Enclave, Face ID, local network (Bonjour, not raw multicast), local notifications.
- **Test device:** iPhone 14 Pro. Its UWB chip is not usable, since Macs have none.
- **Architecture imposed by the brief:** the iPhone is the sensor, the Mac is the hub. The local network is untrusted. Pairing is by QR code. Every message is signed and timestamped.
- **Crypto:** CryptoKit, Security.framework and LocalAuthentication only. Never write custom crypto. Use AES-GCM, SHA-256/HMAC, P-256 ECDSA, P-256 ECDH + HKDF. Protect against replay with a nonce, a monotonic counter and a timestamp with a tolerance window.
- **Keys** (details in `docs/ARCHITECTURE.md`):
  - SSH signing key in the iPhone's Secure Enclave: `WhenUnlockedThisDeviceOnly` + `.privateKeyUsage` + `.biometryCurrentSet`;
  - a separate phone identity key and a Mac identity key (in the Mac's Secure Enclave) for the channel handshake;
  - an offline backup key.
  Never reuse a key across roles, and never sync keys through iCloud.
- **Host identity:** the ssh-agent protocol carries no host name. Never trust a host name supplied by the Mac. The phone identifies hosts by verifying `session-bind@openssh.com` and using the host-key fingerprint.
- **Data protection:** Keychain items are always `ThisDeviceOnly`. Files, including the audit log, use `complete` protection. Hide the app snapshot in the app switcher. No secrets, keys, host names or locations in logs; use fingerprints.

## Rules for AI-generated work (from the course brief)

- **Never** ask for, accept or write real secrets, private keys or personal data in code, prompts or logs. Use obvious placeholders.
- **Never add a dependency.** Propose it to the human with a justification and let them vet it. AI tools sometimes invent package names, and attackers register them.
- **Never push to `main`, merge, or approve a pull request.** Work on a branch (`feature/...`, `fix/...`, `docs/...`). A human teammate who is not the author approves every merge.
- **Flag crypto and security code explicitly** in your reply as "needs line-by-line human review". Write tests for it, including edge cases: tampered messages, replayed nonces, wrong keys, oversized input.
- Validate the format and size of all input from the network or BLE before using it.
- Keep code simple enough that every team member can explain all of it at the oral. Prefer clarity over cleverness, and explain non-obvious choices in short comments.
- Follow the PR checklist in `.github/pull_request_template.md` and the rules in `CONTRIBUTING.md`.

## Prompt journal: mandatory, every session

`docs/PROMPT_JOURNAL.md` is a graded deliverable. Keeping it current is part of every task, not an afterthought.

- **Before finishing any task** that produced code, docs or design decisions, append an entry using the template in that file.
  - Use the next free number (`P-XXX`) and today's date.
  - **Author** is the human you are working with. Ask once per session if you don't know their name.
  - **Tool / model** is "Claude Code" plus your model name.
  - **Prompt:** summarize the human's requests faithfully. Quote them where the wording matters.
  - **Decision:** what was accepted, modified or rejected, and why.
- **Never fill in "Human verification" yourself.** Write `PENDING: human to complete`, plus a short list of what specifically needs checking: crypto calls, claims about Apple APIs you could not confirm, tests you could not run on a device.
- One entry per coherent goal. Several small requests toward one goal can share an entry.
- Reference the entry in commit messages that contain AI-generated work, for example `Add pairing QR screen (prompt P-007)`.
- If something sensitive was pasted into a session, say so in the entry so the team can rotate it.

## Workflow notes

- The team may work on shared or guest machines (the original setup was a macOS Guest account that wipes on logout). Don't rely on Claude's own memory between sessions: this file and the repo are the source of truth. Remind the human to push before logging out.
- Pushing to GitHub needs the human's credentials. Never ask them to paste a token into the chat or into the remote URL.

## Milestones

J1 topic + STRIDE · J2 architecture + justified crypto choices · J3 MVP (`git push` signed by the iPhone) · J4 cross-audit using OWASP MASVS, then fixes · J5 live demo + individual oral.

**Riskiest open question, to prototype first:** can the Mac reliably wake the backgrounded iOS app over BLE, show a local notification, then get a Face ID-gated Secure Enclave signature back?
