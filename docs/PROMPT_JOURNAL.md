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

### P-007 · 2026-11-23 · Red team onboarding and attack decision trees

- **Author:** michael-rousseau
- **Tool / model:** Claude Code (Claude Fable 5.2)
- **Goal:** Get a late-joining teammate up to speed for the red team role and prepare a design-level attack plan.
- **Prompt (summary):** Several prompts over 2026-11-19 and 2026-11-23: (1) explain the project from the brief and the repository; (2) "do you see places where I could find flaws?"; (3) write a README focused on decision trees covering every case, with an explanation of how Bluetooth works; (4) correction after reading it: Bluetooth is optional and the project covers SSH only; (5) make the trees more readable as diagrams. Then: install a Mermaid renderer to check the diagrams; write one clean prompt covering the whole guide; propose dependency and secret scanning tools.
- **Consolidated prompt:** written afterwards, on 2026-11-23, to restate the whole conversation as one request. It was not the prompt actually sent. It is kept so that a teammate can regenerate or extend the guide.

  ```text
  You are helping the red team of SentryKey, a Master 2 group project.

  Read these first: README.md, CONTRIBUTING.md, docs/PROMPT_JOURNAL.md and the
  brief "Projet M2.pdf". Do not rely on anything that is not in them.

  Context
  - SentryKey makes an iPhone act as a hardware SSH key for a Mac. The private
    key is a P-256 key in the iPhone's Secure Enclave. A Mac agent behind
    SSH_AUTH_SOCK forwards each sign request to the iPhone over an encrypted,
    authenticated channel (ECDH P-256, HKDF, AES-GCM). A policy engine on the
    iPhone auto-approves, asks for Face ID, or denies. Decisions go to a
    hash-chained, signed log.
  - Scope: SSH user authentication only. Signing git commits or files is out
    of scope. The transport is the local Wi-Fi, which is not trusted.
    Bluetooth Low Energy is an optional second transport.
  - Constraints: free Apple developer account, iPhone 14 Pro, CryptoKit only,
    no third-party dependency.
  - There is no code yet. Work from the design.

  Task
  Write docs/red-team/README.md, in English, for a teammate who takes the red
  team role without having followed the project. It must let them review the
  design now and test the implementation later. Sections:

  1. System model: a diagram of the components and trust boundaries, a table
     of assets, a table of attackers (malware running as the user on the Mac,
     attacker on the same network, phone thief, Mac thief, malicious server
     reached with agent forwarding, the legitimate user denying an action),
     and a diagram that maps each attacker to the trees to open.
  2. Local network primer, limited to what matters for attacking this system:
     connection and listener, Bonjour discovery, what a device on the same
     network can do, message framing over TCP, iOS limits (local network
     permission, background suspension, locked phone), why being on the same
     network is not proximity, and tools.
  3. Decision trees, one per area: pairing, application channel, transport
     and proximity, sign requests and policy engine, key storage on the
     iPhone, Mac agent, decision log, availability and recovery, platform
     hygiene. Each tree asks questions about the implementation, branches on
     every possible answer including the secure one, and ends in an attack to
     try, a secure outcome, or something to report. Draw them as Mermaid
     flowcharts, left to right, several small diagrams per tree, with
     questions in blue, attacks in red, secure answers in green and notes in
     yellow. Give every attack a stable ID such as T4.1. Under each tree, a
     table with ID, STRIDE category and the exact action to perform.
  4. State matrix: combinations of iPhone state and Mac state, with the
     secure outcome expected for the same ssh command in each.
  5. From tree to finding: how to use the trees before and after code exists,
     a finding report template, and the order in which to run the trees.
  Appendix: Bluetooth Low Energy primer (radio, roles, GATT, pairing and why
  the app must not rely on it, iOS specifics, signal strength and relay,
  tools), used only if that transport is built.

  Rules
  - Mark every claim about Apple or OpenSSH behaviour that you have not
    confirmed in documentation with [verify]. Do not invent API names,
    entitlements or protocol fields.
  - Design-level only: no exploit code, and nothing aimed at devices or
    networks other than the team's own.
  - Say which outcomes are your proposal rather than a team decision.
  - Do not add dependencies or tools to the repository.
  ```
- **Output (summary):**
  - Project summary and a ranked list of design weaknesses. The main ones: the Mac agent is a signing oracle for malware when auto-approval is on; the host name shown to the iPhone is an unverified claim by the Mac; zero-touch conflicts with a `biometryCurrentSet` key; BLE proximity is relayable.
  - `docs/red-team/README.md`: system and attacker model, local network primer, nine attack decision trees (pairing, channel, transport, sign requests, key storage, Mac agent, log, availability, platform), a state matrix and a finding template. After prompt 4, the transport was changed from BLE to the local network, the BLE primer moved to an appendix with its own optional subtree, and git commit signing was marked out of scope. After prompt 5, the text trees became Mermaid flowcharts, each followed by a table of attacks.
  - Secret scanning with Gitleaks 8.30.1: `.pre-commit-config.yaml`, `.github/workflows/gitleaks.yml` (actions pinned to commits) and a section in `CONTRIBUTING.md`. Three other tools were proposed and not selected: a dependency allowlist check with Dependabot, GitHub's native secret scanning and CodeQL, MobSF for the J4 audit.
- **Decision:** Modified. The guide was kept after two corrections by the author: scope (SSH only, Bluetooth optional) and format (diagrams instead of text trees). Of the four tools proposed, only Gitleaks was selected. **Known gap:** the guide was written against `main`. It does not yet reflect `docs/ARCHITECTURE.md` from pull request #1, which makes Bluetooth the transport, requires Face ID for every signature and drops automatic approval. The entry is numbered P-007 because P-003 to P-006 are used on the unmerged `docs/architecture` branch.
- **Human verification:** PENDING: human to complete. To check:
  - every item marked `[verify]` in the guide: ssh-agent protocol and `session-bind@openssh.com`, background behaviour of the iOS app, local network permission on macOS, Secure Enclave use from a macOS agent on a free account;
  - the guide against `docs/ARCHITECTURE.md` once pull request #1 is merged, and which trees no longer apply;
  - the `gitleaks` workflow on GitHub: it was validated locally only and has never run there.
- **Commit / PR:**
