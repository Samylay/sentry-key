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

### P-005 · 2026-11-19 · Face ID for every signature, passkey framing, "why not Touch ID"

- **Author:** Samylay
- **Tool / model:** Claude Code (Claude Opus 5.5)
- **Goal:** Simplify the design and settle what SentryKey protects.
- **Prompt (summary):** The team proposed dropping SSH in favour of Mac and iPhone public keys, with the Mac's public key in the Apple Keychain ("so a compromise would only be on Apple's side"). They also proposed dropping zero-touch for "just full Face ID", and described the app as "a passkey that can be used for anything". Follow-up questions covered the Secure Enclave, whether the Keychain is shared between Mac and iPhone, and whether the Mac has its own Secure Enclave. Final decision: "we'll stick to the SSH plan".
- **Output (summary):**
  - **Full Face ID:** agreed. It removes the everyday key, the policy engine, the rate-limit tiers and proximity auto-approval.
  - **The Keychain argument:** the public key is not secret, so storing it in the Keychain only protects it against replacement. The real risk is malware bypassing the check on the Mac, or reading what it unlocks. The protected secret must be unrecoverable without the phone: SSH, or a vault wrapped with ECDH.
  - **Passkey framing:** a real WebAuthn passkey is impossible on a free account (it needs AutoFill and associated domains; a USB security key needs a restricted entitlement). Suggested instead: a passkey-style authenticator core with SSH as its first integration.
  - **The Mac has a Secure Enclave** (checked: Apple M5, Touch ID present). So the Mac identity key goes in the Mac's Secure Enclave, and the document now answers "why not just Touch ID?": a trusted separate display, device separation, one key for several Macs.
  - **Keychain items are not shared between devices.** Secure Enclave keys never sync, and iCloud is unavailable.
  - `ARCHITECTURE.md` and `CLAUDE.md` updated: single Face ID-gated SSH key, phone and Mac identity keys, backup key, a new residual-risk statement, `complete` file protection for the log, and zero-touch and WebAuthn listed as out of scope.
- **Decision:** Accepted. SSH kept as the use case. Face ID required for every signature.
- **Human verification:** PENDING: human to complete. Check:
  - the claim that a third-party app cannot act as a WebAuthn passkey provider or a virtual USB security key on a free account;
  - that a Mac Secure Enclave key works for an app signed with a Personal Team certificate;
  - the new residual-risk statement (approval is bound to the server, not to the local process).
- **Commit / PR:** branch `docs/architecture`

### P-006 · 2026-11-19 · Export of the session transcript

- **Author:** Samylay
- **Tool / model:** Claude Code (Claude Opus 5.5)
- **Goal:** Keep the full conversation behind entries P-001 to P-005 in the repo.
- **Prompt (verbatim):** "push the transcript of this conv in git, in a dedicated folder"
- **Output (summary):** A script converted the raw session log to `transcripts/2026-11-19-session-1.md`, keeping messages, replies, tool-call notes and the two reviewer reports, and dropping internal reasoning, raw tool output and metadata. The export was scanned for tokens and personal email addresses before committing; none were found. Added `transcripts/README.md`.
- **Decision:** Accepted.
- **Human verification:** PENDING: human to complete. Skim the transcript before the repo is shared, and decide whether the course allows it to be public.
- **Commit / PR:** branch `docs/architecture`

### P-007 · 2026-11-23 · Document SentryKey STRIDE model

- **Author:** <!-- your name -->
- **Tool / model:** OpenAI Codex (GPT-6)
- **Goal:** Document the project's J1 STRIDE threat model based on the validated README design.
- **Prompt (summary or verbatim):** Continue from J1, use README as the subject reference, follow this prompt journal's logging practice, and document SentryKey's STRIDE model.
- **Output (summary):** Added `docs/THREAT_MODEL.md` with system goals, scope and assumptions, trust boundaries, one analysis for each STRIDE category, planned controls and verification ideas, residual risks, and J1 follow-up points. Linked it from the README milestone table.
- **Decision:** Accepted as a design draft; implementation claims are explicitly marked as planned or requiring validation.
- **Human verification:** Pending teammate review against the project brief and protocol decisions; no implementation or device verification was performed.
- **Commit / PR:** Pending.

### P-007 · 2026-11-23 · Red team onboarding and attack decision trees

- **Author:** michael-rousseau
- **Tool / model:** Claude Code (Claude Fable 5.2)
- **Goal:** Get a late-joining teammate up to speed for the red team role and prepare a design-level attack plan.
- **Prompt (summary):** Several prompts over 2026-11-19 and 2026-11-23: (1) explain the project from the brief and the repository; (2) "do you see places where I could find flaws?"; (3) write a README focused on decision trees covering every case, with an explanation of how Bluetooth works; (4) correction after reading it: Bluetooth is optional and the project covers SSH only; (5) make the trees more readable as diagrams. Then: install a Mermaid renderer to check the diagrams; write one clean prompt covering the whole guide; propose dependency and secret scanning tools. Last: "aligne sur doc/Arch", after the assistant reported that the guide contradicted `docs/ARCHITECTURE.md` from pull request #1.
- **Consolidated prompt:** written afterwards, on 2026-11-23, to restate the whole conversation as one request. It was not the prompt actually sent. It is kept so that a teammate can regenerate or extend the guide.

  ```text
  You are helping the red team of SentryKey, a Master 2 group project.

  Read these first: docs/ARCHITECTURE.md (the reference design), CLAUDE.md,
  README.md, CONTRIBUTING.md, docs/PROMPT_JOURNAL.md and the brief
  "Projet M2.pdf". Do not rely on anything that is not in them, and do not
  contradict the architecture document: where you disagree with it, say so
  in a separate list of open questions.

  Context
  - SentryKey makes an iPhone act as a hardware SSH key for a Mac. The SSH
    key is a P-256 key in the iPhone's Secure Enclave, and every signature
    requires Face ID. A Mac agent speaks the ssh-agent protocol and forwards
    sign requests to the iPhone over Bluetooth Low Energy (iPhone peripheral,
    Mac central), inside an application channel: ephemeral ECDH signed by
    identity keys, HKDF, AES-GCM. The phone verifies the server itself with
    session-bind@openssh.com. Decisions go to a hash-chained log whose head
    is mirrored on the Mac.
  - Automatic approval is out of scope. Git commit signing and a Mac
    proximity lock are stretch goals.
  - Constraints: free Apple developer account, iPhone 14 Pro, Apple
    frameworks only.
  - There is no code yet. Work from the design.

  Task
  Write docs/red-team/README.md, in English, for a teammate who takes the red
  team role without having followed the project. It must let them review the
  design now and test the implementation later. Sections:

  1. System model: a diagram of the components and trust boundaries, a table
     of assets, a table of attackers (malware running as the user on the Mac,
     radio attacker, relay, phone thief, Mac thief, malicious server, the
     legitimate user denying an action), a table of what the design already
     answers and which test verifies it, and a diagram that maps each
     attacker to the trees to open.
  2. Bluetooth Low Energy primer, limited to what matters for attacking this
     system: radio, roles, GATT and framing, why link-level pairing is not
     relied on, how SentryKey uses BLE and what that exposes before the
     handshake, signal strength and relay, tools.
  3. Decision trees, one per area: pairing, application channel, Bluetooth
     transport, sign requests and approval, keys and storage on the iPhone,
     Mac agent, decision log, availability and recovery, platform hygiene.
     Each tree asks questions about the implementation, branches on every
     possible answer including the secure one, and ends in an attack to try,
     a secure outcome, or something to report. Draw them as Mermaid
     flowcharts, left to right, several small diagrams per tree, with
     questions in blue, attacks in red, secure answers in green and notes in
     yellow. Give every attack a stable ID such as T4.7. Under each tree, a
     table with ID, STRIDE category and the exact action to perform.
  4. State matrix: combinations of iPhone state and Mac state, with the
     outcome expected for the same ssh command in each.
  5. What to test at each milestone, given what the design defers to J4.
  6. A finding report template.
  7. Questions the design leaves open.

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
  - `docs/red-team/README.md`: system and attacker model, local network primer, nine attack decision trees (pairing, channel, transport, sign requests, key storage, Mac agent, log, availability, platform), a state matrix and a finding template. After prompt 4, the transport was changed from BLE to the local network, the BLE primer moved to an appendix with its own optional subtree, and git commit signing was marked out of scope. After prompt 5, the text trees became Mermaid flowcharts, each followed by a table of attacks. After the last prompt, the guide was rewritten against `docs/ARCHITECTURE.md`: Bluetooth primer back in the main text, local network material removed, trees redone for Face ID on every signature and session-bind verification, plus a table of what the design already answers, a per-milestone plan and ten open questions for the team.
  - Secret scanning with Gitleaks 8.30.1: `.pre-commit-config.yaml`, `.github/workflows/gitleaks.yml` (actions pinned to commits) and a section in `CONTRIBUTING.md`. Three other tools were proposed and not selected: a dependency allowlist check with Dependabot, GitHub's native secret scanning and CodeQL, MobSF for the J4 audit.
- **Decision:** Modified. The first version of the guide was written against `main` and assumed a local network transport and automatic approval, on the author's indication that Bluetooth was optional. It contradicted `docs/ARCHITECTURE.md` (pull request #1) and was rewritten to follow it. Of the four tools proposed, only Gitleaks was selected. The entry is numbered P-007 because P-003 to P-006 are used on the unmerged `docs/architecture` branch.
- **Human verification:** PENDING: human to complete. To check:
  - every item marked `[verify]` in the guide: ssh-agent protocol and `session-bind@openssh.com`, background behaviour of the iOS app over Bluetooth, the `publickey-hostbound` method, Secure Enclave use from a macOS agent on a free account;
  - the guide against `docs/ARCHITECTURE.md` again if pull request #1 changes before it is merged;
  - the ten open questions in section 7 of the guide: they are the assistant's reading of the architecture and none has been discussed with the team;
  - the `gitleaks` workflow on GitHub: it was validated locally only and has never run there.
- **Commit / PR:**

### P-008 · 2026-11-23 · Review of the repo against the brief, then Face ID on every signature

- **Author:** Axel Maral
- **Tool / model:** Claude (Claude Opus 5.5)
- **Goal:** Check the scaffold against the brief, then remove the conflict between "zero-touch" and a `biometryCurrentSet` key.
- **Prompt (summary):** Shared the brief (PDF) and the repo link with no instructions, then: "edit the project to require Face ID every time".
- **Output (summary):**
  - **Review:** a Secure Enclave key protected by `biometryCurrentSet` requires Face ID for every use, and Face ID cannot be shown while the app is in the background. "Zero-touch by default" is therefore impossible without turning Face ID into a software gate in the app.
  - **Other points raised:** the host name is not part of the SSH sign request (verify it with `session-bind@openssh.com`); SentryKey prevents key theft, not misuse by malware on the Mac; Secretive is prior art; a backup key is needed for recovery; SSH signatures need converting from raw/DER to `mpint`.
  - **Edit:** README updated. Face ID on every signature, approval through a local notification, a fresh `LAContext` per request, no auto-approval or session approval.
- **Decision:** Accepted. Supersedes the zero-touch policy layer chosen in P-001.
- **Human verification:** <!-- e.g. confirm on the iPhone 14 Pro that a biometryCurrentSet key prompts on every signature and that a background request cannot sign -->
- **Commit / PR:** branch `docs/faceid-every-signature`
