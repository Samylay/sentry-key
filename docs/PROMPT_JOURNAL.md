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
