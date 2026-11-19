# Prompt journal

Every prompt sent to an AI tool for this project is logged here, including ones whose output was discarded. This journal is a graded deliverable.

## Rules

- **One entry per prompt or per short conversation** with a single goal.
- **Never** paste secrets, keys or real personal data into a prompt. If you notice you did, write it here and rotate the secret.
- Record what you **did** with the output: accepted, modified or rejected, and why.
- Record how a **human verified** it. "It looked right" is not verification.
- Link the resulting commit or pull request when there is one.

## Entry template

Copy this block for each new entry. Number entries in order: P-001, P-002, and so on.

```markdown
### P-XXX · YYYY-MM-DD · Short title

- **Author:**
- **Tool / model:**
- **Goal:**
- **Prompt (summary or verbatim):**
- **Output (summary):**
- **Decision:** Accepted / Modified / Rejected, and why
- **Human verification:**
- **Commit / PR:**
```

---

## Entries

### P-000 · YYYY-MM-DD · First SentryKey proposal (generic Mac vault)

*To be completed by the teammate who generated the first SentryKey plan.*

- **Author:**
- **Tool / model:**
- **Goal:** Choose a project topic from the brief.
- **Prompt (summary or verbatim):**
- **Output (summary):** SentryKey, an iPhone security key that unlocks a local vault on the Mac through Face ID challenge-response. Includes QR pairing, nonce/timestamp/counter anti-replay, `biometryCurrentSet`, a hash-chained log and BLE proximity locking.
- **Decision:** Modified. The protocol was kept, but the protected asset changed. See P-002.
- **Human verification:**
- **Commit / PR:**

### P-001 · 2026-11-19 · Topic brainstorm from the project brief

- **Author:** <!-- your name -->
- **Tool / model:** Claude Code (Claude Opus 5.5)
- **Goal:** Read the brief and brainstorm app ideas that fit its constraints.
- **Prompt (summary):** Read the brief, brainstorm app ideas, then refocus on real iOS/macOS security pain points. Screen the ideas against the free Apple account and an iPhone 14 Pro. Reduce approval friction ("having to use my phone to approve something seems like bad UX").
- **Output (summary):** Six ideas: SSH key in the Secure Enclave, out-of-band integrity monitor, clipboard-free secure typing, proximity "snatch" lock, sensitive-screenshot scanner, and context-aware approval. Ruled out ideas that need NFC, push, iCloud, AutoFill, Network Extension or Screen Time. Proposed "zero-touch by default, prompt on anomaly": session approval, auto-approval when the phone is proven nearby, per-host policies and rate limits.
- **Decision:** Accepted the SSH key idea with the zero-touch policy layer. The team chose it over the generic vault.
- **Human verification:** Free-account limits checked against slide 4 of the brief. **Still to verify ourselves:**
  - Network Extension really requires a paid account.
  - Live Activities work on a free account.
  - BLE in the background can wake the iOS app reliably. This is the riskiest assumption; prototype it first.
- **Commit / PR:** N/A (design only)

### P-002 · 2026-11-19 · Review of the first SentryKey plan

- **Author:** <!-- your name -->
- **Tool / model:** Claude Code (Claude Opus 5.5)
- **Goal:** Critique the teammate's SentryKey plan (P-000) and merge it with the SSH idea.
- **Prompt (summary):** Pasted the teammate's plan and asked for an opinion, then asked whether the proposed fix adds a lot of complexity.
- **Output (summary):**
  - **Design flaw found:** the Mac verifies a signature and then opens a vault whose key is stored on the Mac. Malware can skip the check and read the key directly, so the signature is only a software gate (Elevation of Privilege).
  - **Fixes proposed:** either wrap the vault key with ECDH in the Secure Enclave (small cost, but needs a recovery code), or protect an SSH key, where no secret lives on the Mac at all.
  - **Other gaps:** background wake-up without push; Wi-Fi and BLE as two transports; Face ID on every action; RESILIENCE and CODE missing from the MASVS table; clock skew in timestamp checks.
- **Decision:** Accepted. The merged design keeps P-000's protocol and protects SSH keys instead of a vault.
- **Human verification:** <!-- e.g. team discussion on DATE; check the vault flaw against the CryptoKit docs -->
- **Commit / PR:** N/A (design only)

### P-003 · 2026-11-19 · Repository scaffold, prompt journal and CLAUDE.md

- **Author:** Samylay
- **Tool / model:** Claude Code (Claude Opus 5.5)
- **Goal:** Set up the GitHub repo and the prompt journal, then encode the project's requirements for future AI sessions.
- **Prompt (summary):** "We need a prompt journal, and naturally a GitHub repo." Then: "We'll make a CLAUDE.md for the future sessions that will encode the project's requirements."
- **Output (summary):**
  - `README.md` (pitch, protocol, constraints, milestones), `CONTRIBUTING.md` (the brief's AI rules, workflow, pitfalls), `.github/pull_request_template.md` (review checklist), `.gitignore`.
  - This journal, with entries P-000 to P-003.
  - `CLAUDE.md`: project summary, free-account and hardware constraints, crypto and data-protection rules, the brief's AI rules (no secrets, no new dependencies, no pushing to `main`, flag crypto code for review), and a mandatory procedure for keeping this journal up to date.
  - Help debugging the first push (a fine-grained token without write permission gave a 403).
- **Decision:** Accepted. Docs written in English by team choice.
- **Human verification:** PENDING: human to complete. Check:
  - that the lists of available and unavailable features in `CLAUDE.md` match slide 4 of the brief;
  - that the AI rules in `CLAUDE.md` and `CONTRIBUTING.md` match slide 8;
  - that the team agrees with the workflow rules (branches, one reviewer).
- **Commit / PR:** `ff645f7` (initial scaffold); CLAUDE.md on branch `docs/claude-md`

### P-004 · 2026-11-19 · Architecture document and two AI design reviews

- **Author:** Samylay
- **Tool / model:** Claude Code (Claude Opus 5.5), plus two Claude subagents used as reviewers
- **Goal:** Write the reference architecture, then have it reviewed from an Apple-platform angle and a security angle before saving it.
- **Prompt (summary):**
  - "Summarise the pitch and core technologies and modules we'll use."
  - "Save it as ARCHITECTURE.md and log it, after running two reviewers, one that fetches and uses iOS dev skills and another for security, with skills as well."
  - No iOS or security skills are installed. Both reviewers instead checked claims against official sources with web fetches.
- **Earlier decisions made in this conversation:**
  - A native Swift Mac agent instead of the suggested Chrome extension: an extension cannot serve `SSH_AUTH_SOCK`, and its Bluetooth access needs an open page and a user click.
  - Roles follow slide 11 of the brief: project lead, security architect, iOS developer, rotating red team.
- **Output (summary):**
  - A first draft of `docs/ARCHITECTURE.md`.
  - The **iOS reviewer** (sources: Apple developer docs, TN3115, TN3127, Core Bluetooth guide) found:
    - a `biometryCurrentSet` key cannot auto-approve, and Face ID needs the foreground;
    - approval needs "notification → foreground → Face ID" and does not fit in a ~10 s background wake;
    - no relaunch after a force-quit, a Bluetooth toggle or before the first unlock; state restoration is opt-in;
    - `NSFileProtectionComplete` blocks logging while the phone is locked;
    - background advertising hides services from the Mac, so scan only at pairing and then reconnect by identifier;
    - missing pieces: BLE framing, timeouts, Info.plist keys; sign the Mac agent with the Personal Team certificate, not ad hoc;
    - the proximity lock has no documented macOS API.
  - The **security reviewer** (sources: OpenSSH PROTOCOL.agent, openssh.org/agent-restrict.html, RFC 5656) found:
    - **critical:** sign requests carry no host name, so the Mac could fake one and per-host policy was invalid; fix by verifying `session-bind@openssh.com` on the phone and keying policy on host-key fingerprints;
    - **critical:** zero-touch contradicted Face ID gating (same finding as the iOS reviewer);
    - "proven nearby" does not stop malware on the Mac;
    - the pairing fingerprint comparison did not authenticate the phone's key;
    - the channel had no forward secrecy or key separation;
    - risk of lockout after losing the phone or re-enrolling Face ID;
    - the audit log could be truncated, and it recorded host names, which CLAUDE.md forbids;
    - notification spam (MFA fatigue);
    - the SSH signature format (mpint encoding) was undocumented.
  - The **revised ARCHITECTURE.md** addresses these with:
    - two hardware-enforced key tiers plus a separate channel key;
    - session-bind verification on the phone, and hosts identified by fingerprint;
    - a one-time secret in the QR code to authenticate the phone's keys at pairing;
    - an ephemeral signed ECDH handshake with one key per direction;
    - a mandatory backup key;
    - a log head mirrored on the Mac;
    - BLE lifecycle constraints;
    - the MVP reduced to the strong key only, with the policy engine moved to J4.
  - **`CLAUDE.md` updated** so it no longer contradicts the design: key tiers, host-identity rule, file protection classes.
- **Decision:** Accepted the review findings. Two calls of my own:
  - The log head is mirrored on the Mac instead of the log being signed with yet another key. The iOS reviewer judged the extra key not worth it; the security reviewer suggested it.
  - Proximity lock kept as a stretch goal, with its uncertainty listed in the document.
- **Human verification:** PENDING: human to complete. Check:
  - the claims the reviewers could not verify: CryptoKit's `signature(for:)` hashes with SHA-256 internally and `rawRepresentation` is r‖s; whether Secure Enclave keys survive an app reinstall; whether the stored BLE identifier survives address rotation; whether a macOS central sees overflow-area service UUIDs;
  - that `session-bind` verification fits the team's capacity at J4: it means verifying Ed25519, ECDSA and RSA host-key signatures on the phone;
  - that the team agrees to move the policy engine and the everyday key to J4;
  - the `CLAUDE.md` changes.
- **Commit / PR:** branch `docs/architecture`
