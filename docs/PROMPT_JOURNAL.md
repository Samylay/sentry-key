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

### P-007 · 2026-11-23 · Red team onboarding and attack decision trees

- **Author:** michael-rousseau
- **Tool / model:** Claude Code (Claude Fable 5.2)
- **Goal:** Get a late-joining teammate up to speed for the red team role and prepare a design-level attack plan.
- **Prompt (summary):** Several prompts over 2026-11-19 and 2026-11-23: (1) explain the project from the brief and the repository; (2) "do you see places where I could find flaws?"; (3) write a README focused on decision trees covering every case, with an explanation of how Bluetooth works; (4) correction after reading it: Bluetooth is optional and the project covers SSH only; (5) make the trees more readable as diagrams. Then: install a Mermaid renderer to check the diagrams; write one clean prompt covering the whole guide; propose dependency and secret scanning tools. Last: "aligne sur doc/Arch", after the assistant reported that the guide contradicted `docs/ARCHITECTURE.md` from pull request #1. Then: "vérifie le guide contre docs/THREAT_MODEL.md", and "ajoute les quatre tests, on se base sur ARCHITECTURE".
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
  - `docs/red-team/README.md`: system and attacker model, local network primer, nine attack decision trees (pairing, channel, transport, sign requests, key storage, Mac agent, log, availability, platform), a state matrix and a finding template. After prompt 4, the transport was changed from BLE to the local network, the BLE primer moved to an appendix with its own optional subtree, and git commit signing was marked out of scope. After prompt 5, the text trees became Mermaid flowcharts, each followed by a table of attacks. After the last prompt, the guide was rewritten against `docs/ARCHITECTURE.md`: Bluetooth primer back in the main text, local network material removed, trees redone for Face ID on every signature and session-bind verification, plus a table of what the design already answers, a per-milestone plan and ten open questions for the team. A comparison with `docs/THREAT_MODEL.md` showed that it follows the earlier README design. Four items it covers were added to the guide (socket peer check T6.11, returned signature T2.10, log across reinstall T7.9, the five trust boundaries), and the divergence between the two team documents was added as open question 11.
  - Secret scanning with Gitleaks 8.30.1: `.pre-commit-config.yaml`, `.github/workflows/gitleaks.yml` (actions pinned to commits) and a section in `CONTRIBUTING.md`. Three other tools were proposed and not selected: a dependency allowlist check with Dependabot, GitHub's native secret scanning and CodeQL, MobSF for the J4 audit.
- **Decision:** Modified. The first version of the guide was written against `main` and assumed a local network transport and automatic approval, on the author's indication that Bluetooth was optional. It contradicted `docs/ARCHITECTURE.md` (pull request #1) and was rewritten to follow it. Of the four tools proposed, only Gitleaks was selected. The entry is numbered P-007 because P-003 to P-006 are used on the unmerged `docs/architecture` branch.
- **Human verification:** PENDING: human to complete. To check:
  - every item marked `[verify]` in the guide: ssh-agent protocol and `session-bind@openssh.com`, background behaviour of the iOS app over Bluetooth, the `publickey-hostbound` method, Secure Enclave use from a macOS agent on a free account;
  - the guide against `docs/ARCHITECTURE.md` again if pull request #1 changes before it is merged;
  - the ten open questions in section 7 of the guide: they are the assistant's reading of the architecture and none has been discussed with the team;
  - the `gitleaks` workflow on GitHub: it was validated locally only and has never run there.
- **Commit / PR:**

### P-008 · 2026-11-23 · Could SentryKey work without an iPhone app?

- **Author:** Samylay
- **Tool / model:** Claude Code (Claude Opus 5.5)
- **Goal:** Check whether the iPhone's built-in passkeys could replace a custom iPhone app.
- **Prompt (verbatim):** "can't we do it without an app"
- **Output (summary):** Searched primary sources (OpenSSH `PROTOCOL.u2f`, the SSH-Passkeys paper arXiv 2507.09022, Apple developer forum threads). Technically possible: OpenSSH accepts `webauthn-sk-ecdsa-sha2-nistp256@openssh.com` signatures, and an iPhone passkey can act as a cross-device (hybrid) authenticator. Reasons against it:
  - iCloud Keychain passkeys sync, so the Mac would hold the same key, which defeats the goal of leaving nothing on the Mac;
  - the known approach (SSH-Passkeys) needs a PAM module on every server, so `git push` to GitHub would not work; the alternative, a hybrid (caBLE) client on the Mac, is more work than the app;
  - non-Apple clients make the iPhone scan a QR code for every login, and the macOS system `ssh` lacks FIDO support;
  - the brief ("make the iPhone a security device") and the iOS developer role assume an iPhone app.
- **Decision:** No design change. The custom iPhone app stays.
- **Human verification:** PENDING: human to complete. Check:
  - whether the course brief requires a custom iPhone app;
  - the claim that iCloud Keychain passkeys are synced rather than bound to the device.
- **Commit / PR:** N/A (design question only)

### P-009 · 2026-11-23 · Flow diagrams

- **Author:** Samylay
- **Tool / model:** Claude Code (Claude Opus 5.5)
- **Goal:** Draw the protocol flows for the J2 "protocol diagram" deliverable.
- **Prompt (verbatim):** "ok now lets do a diagram for flux"
- **Output (summary):** `docs/FLOWS.md` with four Mermaid diagrams taken from `ARCHITECTURE.md`: an overview with trust boundaries, pairing, the secure-channel handshake, and signing (including the J3 vs J4 difference and the timeout path). Each diagram was rendered in headless Chrome to check that it parses; a semicolon that broke the signing diagram and a note too wide to read were fixed. `ARCHITECTURE.md` now links to the file.
- **Decision:** Accepted. Mermaid was chosen because GitHub renders it and it needs no new dependency in the repo.
- **Human verification:** PENDING: human to complete. Check:
  - that each diagram matches `ARCHITECTURE.md`, especially the handshake order (the document does not say which side sends first) and the step at which the phone verifies the server;
  - that the diagrams render on GitHub.
- **Commit / PR:** PR #1 (branch `docs/architecture`)

### P-010 · 2026-11-23 · Adversarial review of the flow diagrams

- **Author:** Samylay
- **Tool / model:** Claude Code (Claude Opus 5.5), with a Claude Fable 5.2 subagent as reviewer and editor
- **Goal:** Have the diagrams from P-009 attacked by a second model, then fix what it finds.
- **Prompt (verbatim):** "adversarial review and opti it by a fable agent"
- **Output (summary):** The reviewer checked `docs/FLOWS.md` against `ARCHITECTURE.md` and `CLAUDE.md` and rewrote it. Main fixes:
  - added the residual risk (approval is bound to the server, not to the local process), which was missing;
  - a "trusted for / not trusted for" table, because the old boundary label hid that the Mac is trusted at pairing time;
  - the handshake no longer implies facts the design does not state (who sends first, whether nonces are signed); these are listed as "not specified";
  - added replay protection, reconnection by stored identifier, and the audit-log head check;
  - the timeout branch now covers denial, and the error text no longer reuses the "phone unreachable" message;
  - consistent `[J4]` and `[Stretch]` tags, consistent actor names, and an overview redrawn without crossing edges.
  The diagrams were rendered again in headless Chrome: all four parse.
- **Problems the reviewer found in `ARCHITECTURE.md` (not changed, for the team to decide):**
  - The handshake signature covers only each side's own ephemeral key, so a recorded handshake message can be replayed. A common fix is to sign both ephemeral keys, both nonces and both identities.
  - Where the host name "recorded on first use" comes from is not stated, nor what the phone shows for an unknown fingerprint.
  - In J3, how the Mac learns the host name is not stated, since the ssh-agent protocol carries none.
  - SSHSIG (git commit signing) has no session-bind, so what the phone shows for it is not defined.
  - The pairing authentication construction and the QR code's validity period are not defined. Anyone who photographs the QR code holds the secret.
  - Timestamps appear only in the module list, not in the channel flow.
  - Undefined failure paths: explicit denial vs timeout, Face ID failure, and what happens on a log head mismatch.
- **Decision:** Accepted the diagram changes. The architecture issues are recorded here for the team.
- **Human verification:** PENDING: human to complete. Check:
  - every "not specified" point, and decide which ones ARCHITECTURE.md should settle;
  - the handshake replay concern before any channel code is written;
  - that the diagrams render on GitHub.
- **Commit / PR:** PR #1 (branch `docs/architecture`)

### P-011 · 2026-11-23 · Recovery key system

- **Author:** Samylay
- **Tool / model:** Claude Code (Claude Opus 5.5)
- **Goal:** Replace the vague "offline backup key" with a complete recovery design.
- **Prompt (verbatim):** "we should have a recovery keys system"
- **Output (summary):** Looked up how hardware SSH keys handle recovery (Yubico's SSH guide and backup advice, Secretive): a Secure Enclave key cannot be exported, so the standard answer is a second key installed on every server in advance. Added a "Recovery (J4)" section to `ARCHITECTURE.md`:
  - a P-256 recovery key generated by the iPhone app in memory, shown once as a recovery code (base32 groups plus a SHA-256 checksum), checked by typing back two groups, then erased from the phone;
  - a key registry on the Mac listing which key fingerprints are installed for which `user@host`;
  - a table of what each loss destroys (phone, Face ID re-enrolment, app deletion, Mac) and what to do;
  - rotation: the Mac rebuilds the recovery key in memory for at most 15 minutes, you replace the keys on each server, and the old code is treated as used;
  - residual risks (a found paper code gives access without Face ID; Mac malware during recovery) and the alternatives considered (a second iPhone, a YubiKey).
  Also added modules `RecoveryCode`, `RecoverySetup`, `KeyRegistry` and `RecoveryMode`, updated the J4 scope, synced `CLAUDE.md`, and added diagram 5 (setup and rotation) to `FLOWS.md`, rendered in headless Chrome.
- **Decision:** Accepted as the proposed design, pending team review. The recovery key is P-256 rather than Ed25519 so it reuses the `SSHWire` code and stays within the algorithms CLAUDE.md allows.
- **Human verification:** PENDING: human to complete. Check:
  - that `P256.Signing.PrivateKey(rawRepresentation:)` round-trips the 32-byte code on the device;
  - that the team accepts the residual risks of a paper code, and the 15-minute window;
  - that the key registry storing `user@host` on the Mac is acceptable (it is not a log, but it does hold host names);
  - whether `docs/THREAT_MODEL.md`, which says recovery is not specified, should now reference this section.
- **Commit / PR:** PR #1 (branch `docs/architecture`)

### P-012 · 2026-11-23 · Document SentryKey STRIDE model

- **Author:** <!-- your name -->
- **Tool / model:** OpenAI Codex (GPT-6)
- **Goal:** Document the project's J1 STRIDE threat model based on the validated README design.
- **Prompt (summary or verbatim):** Continue from J1, use README as the subject reference, follow this prompt journal's logging practice, and document SentryKey's STRIDE model.
- **Output (summary):** Added `docs/THREAT_MODEL.md` with system goals, scope and assumptions, trust boundaries, one analysis for each STRIDE category, planned controls and verification ideas, residual risks, and J1 follow-up points. Linked it from the README milestone table.
- **Decision:** Accepted as a design draft; implementation claims are explicitly marked as planned or requiring validation.
- **Human verification:** Pending teammate review against the project brief and protocol decisions; no implementation or device verification was performed.
- **Commit / PR:** Pending.

### P-013 · 2026-11-23 · Review of the repo against the brief, then Face ID on every signature

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

### P-014 · 2026-11-23 · Start of J3: SentryKeyProtocol package (SSH formats, agent messages, framing)

- **Author:** Samylay
- **Tool / model:** Claude Code (Claude Opus 5.5)
- **Goal:** Start the J3 MVP before the team has a Mac and the iPhone available, with the parts that can be built and tested on Linux.
- **Prompt (verbatim):** "we're skipping teammate reviews so everything and start the J3 even without mac and iphone we'll smooth out the kinks next time"
- **Process decision:** Samylay decided to merge without teammate review for now. PR #5 and this PR were merged by the author once the secret scan passed. This departs from `CONTRIBUTING.md` (one reviewer per merge), and the team may want to review these changes afterwards.
- **Output (summary):**
  - `SentryKeyProtocol/`, a Swift package with no dependencies: a bounds-checked SSH wire reader and writer, `ecdsa-sha2-nistp256` key and signature blobs from CryptoKit's formats, ssh-agent requests and replies, `session-bind@openssh.com`, parsing of the data signed for a login (including `publickey-hostbound-v00`), and length-prefixed framing for the socket and BLE.
  - 43 tests, run in Apple's official `swift:6.2-noble` Docker image (Swift 6.2.4): all pass, no compiler warnings.
  - Ground truth: wire formats were checked against RFC 9987 and OpenSSH `PROTOCOL` / `PROTOCOL.agent`. Test vectors come from a real OpenSSH 10.2 login through a stand-in agent, which `sshd` accepted, and a real `ssh-agent` confirmed the reply codes. The procedure is in `SentryKeyProtocol/README.md`. The user name in the vectors was replaced before commit.
- **Decision:** Accepted. Code that needs CryptoKit (handshake, channel, anti-replay, pairing, recovery code) waits for a Mac.
- **Human verification:** PENDING: human to complete. Check:
  - line-by-line review of every parser (`Wire.swift`, `AgentMessages.swift`, `UserAuthSignedData.swift`, `Framing.swift`), since they handle untrusted input;
  - that `swift test` passes on a Mac with Xcode;
  - the limits in `AgentLimits` and the choice to reject boolean values other than 0 and 1.
- **Commit / PR:** branch `feature/protocol-package`

### P-015 · 2026-11-23 · J3: approval checks and the iPhone app screens

- **Author:** Samylay
- **Tool / model:** Claude Code (Claude Opus 5.5), with the Appllama MCP for UI research
- **Goal:** Continue J3 without a Mac: the checks the phone runs before prompting, and the SwiftUI screens.
- **Prompt (verbatim):** "merge them, keep going on J3, usee apple ui kit and appllama"
- **Process decision:** PRs #6 and #7 were merged by Samylay's instruction, without teammate review (see P-014).
- **Output (summary):**
  - Package, `Approval/`: `LoginApprovalCheck` (the login must match the session-bind: same key, same session, same host key; refuses non-logins, a missing or forwarded session-bind, and user names with invisible or bidi characters), `HostKeySignature` (Ed25519 only), `SSHFingerprint` and `OpenSSHPublicKey` (checked against `ssh-keygen` output), `KnownHosts`, `PromptRateLimiter`. 70 tests pass in `swift:6.2-noble`.
  - Ground truth for the server check: Python's Ed25519 verified that, in the captured OpenSSH 10.2 login, the server signs the session ID itself, and rejected a tampered ID.
  - `SentryKey-iOS/`: SwiftUI app with Welcome, Pairing (VisionKit QR scanner), the approval sheet, Home (public key, recent requests) and Settings (named servers, a Debug demo request). `KeyStore` (Secure Enclave key via CryptoKit, Face ID through `LAContext.evaluateAccessControl`) and `HostVerifier` (CryptoKit Ed25519).
  - "Apple UI kit" was read as Apple's native SwiftUI controls and HIG. Layouts were studied on Appllama first (Xverse, Dashlane, X, Zengo, Keeper); see `docs/UI_RESEARCH.md`.
- **Review:** a separate Claude (Opus 5.5) pass reviewed the app code without the author's reasoning. It found no certain compile errors and 7 runtime issues, all fixed: a crash when a request expires during Face ID, a new key created silently after a backup restore, the approval sheet visible in the app switcher, the Face ID passcode fallback, system interruptions treated as denials, state wiped when read while locked, and the scanner starting too early.
- **Decision:** Accepted as a first draft. The app sources only pass `swiftc -parse` (and `AppModel`/`Storage` type-check with stand-ins for Apple-only types): no iOS SDK build and no device run were possible. No `.xcodeproj` is committed, because one written without Xcode could not be checked; `SentryKey-iOS/README.md` gives the steps. Pairing accepts any QR code until the payload format is specified, and this must not ship.
- **Human verification:** PENDING: human to complete. Check:
  - build in Xcode and fix compile errors;
  - line-by-line review of `KeyStore.swift`, `HostVerifier.swift`, `LoginApproval.swift`, `HostKeySignature.swift`, `DisplayText.swift`;
  - on the iPhone 14 Pro: the demo request shows exactly one Face ID prompt per signature, and enrolling a new face makes the key unusable;
  - the rate-limit defaults (5 per minute, 2-minute cooldown) and the 30-second answer time.
- **Commit / PR:** branch `feature/ios-app-ui`

### P-016 · 2026-11-24 · First build on a Mac: compile fix and Xcode project

- **Author:** michael-rousseau
- **Tool / model:** Claude Code (Claude Fable 5.2)
- **Goal:** Build and run both Swift projects on a Mac for the first time, as a developer.
- **Prompt (summary):** "we should create the xcode project, can you check both swift project, I want to test them (not as red team, just as a developer)". Then installing Xcode, running the app in the simulator, and questions on what the QR code and the two phone keys are for.
- **Output (summary):**
  - `SentryKeyProtocol`: one compile error, in `Approval/PromptRateLimiter.swift`. The closure passed to `recent.removeAll` read `self.window` while `self.recent` was being modified, which Swift rejects as overlapping access. Fixed by copying `window` to a local constant first. Behaviour is unchanged. All 70 tests pass with Xcode 27.2.
  - `SentryKey-iOS`: `SentryKey.xcodeproj` written by hand (synchronized folder group, local package reference, usage descriptions in build settings), then validated with `xcodebuild`: builds for device in Debug and Release and for the simulator, with no errors or warnings in our code. The app launches in the simulator and shows the Welcome and pairing screens.
  - `SentryKey-iOS/README.md` updated: the nine manual steps to create the project are replaced by how to open and build it.
- **Decision:** Accepted. The bundle identifier is a placeholder (`com.example.SentryKey`) and the signing team is empty, so each developer sets their own without committing it.
- **Human verification:** PENDING: human to complete. Check:
  - line-by-line review of the two-line change in `PromptRateLimiter.swift` (security code);
  - that the project opens in the Xcode interface, which was not tried: only `xcodebuild` was used;
  - a run on the iPhone 14 Pro: pairing, the demo request, one Face ID per signature. Nothing past the pairing screen has run anywhere yet.
- **Commit / PR:** pull request #9

### P-017 · 2026-11-24 · J3 development plan and the Mac to phone link messages

- **Author:** michael-rousseau
- **Tool / model:** Claude Code (Claude Fable 5.2)
- **Goal:** Decide what to build next to reach J3, and fix the interface the remaining work packages share.
- **Prompt (verbatim):** "ok, c'est pushed. c'est quoi la suite? on se fait un plan de dev?" The author then chose: a plan for the whole team up to J3, the Mac agent as his own work package, and no device testing on his Mac.
- **Output (summary):**
  - An inventory of the code against `docs/ARCHITECTURE.md`: the SSH formats, the approval checks and the iPhone screens exist; the Mac agent, all Bluetooth code, the secure channel and real pairing do not.
  - A plan in seven work packages: A Mac agent, B secure channel, C Bluetooth wake-up prototype (the riskiest open question, to run first on a Mac with the iPhone), D Bluetooth transport, E real pairing, F local notification, G integration and demo. A, B and C can start in parallel.
  - `SentryKeyProtocol/Sources/SentryKeyProtocol/Link/LinkMessages.swift`: `PhoneRequest` (sign, cancel), `PhoneResponse` (signature or a refusal reason) and `RequestID`, encoded with the existing `WireWriter` and `WireReader` and the existing size limits. 15 tests: round trips, every truncation, trailing bytes, unknown types, oversized fields, and a pass through `Framing` and `Reassembler`.
  - Two findings from the inventory: `AppModel.receive` and `sendResponse` carry no request identifier, and the code already verifies session-bind and refuses non-Ed25519 host keys, which is stricter than the J3 row of the architecture ("reported by the Mac, labelled unverified").
- **Decision:** Accepted. The request identifier was added because the Mac times out before the phone does: without it a late answer could be matched to the next request. The assignment of packages B to F is a proposal, not agreed with the team. The architecture document was not changed: whether to keep the stricter J3 behaviour is for the team to decide.
- **Human verification:** PENDING: human to complete. Check:
  - line-by-line review of `LinkMessages.swift` (it parses untrusted input on both devices);
  - that the team agrees on the message set before the Bluetooth and channel work builds on it, in particular the `cancel` message and the list of refusal reasons;
  - the plan itself with Samylay and Axel.
- **Commit / PR:** branch `feature/phone-link-messages`, stacked on pull request #9

### P-018 · 2026-11-24 · Mac agent: ssh-agent socket, request queue and a stand-in phone

- **Author:** michael-rousseau
- **Tool / model:** Claude Code (Claude Fable 5.2)
- **Goal:** Build work package A of the J3 plan (P-017): the Mac agent, testable on a Mac alone, without an iPhone.
- **Prompt (summary):** Approval of the plan from P-017, in which the author took the Mac agent and stated that device tests would happen on another Mac. No further prompt: the assistant implemented the package from the plan.
- **Output (summary):**
  - `SentryKey-macOS/`, a Swift package with no third-party dependency. Library `SentryKeyAgent`: `AgentSocket` (Unix socket in a `0700` folder, socket `0600`, peers of another user refused, at most 16 connections, never deletes a path that is not a dead socket), `AgentSession` (lists the phone's key, keeps the session-bind, refuses key management and forwarded connections without asking the phone), `SigningQueue` (one request at a time, answers matched by `RequestID`, 45-second timeout followed by a `cancel`, at most 8 waiting), `P256SignatureVerifier` (the phone's signature is checked before `ssh` gets it).
  - `SentryKeyAgentDevSupport` and `sentrykey-agent-dev`: a stand-in phone with a software P-256 key held in memory, which runs `LoginApprovalCheck` and the Ed25519 session-bind check like the real phone. Separate targets, so the real agent cannot link a key that lives on the Mac.
  - `SentryKeyProtocol`: `ECDSAP256.rawSignature(fromSignatureBlob:)`, the inverse of `signatureBlob`, strict on mpint form.
  - Tests: 35 in the agent package (queue, session, real socket), 3 more in the protocol package (88 in total). No test sleeps.
  - `Scripts/try-with-local-ssh.sh`: a real OpenSSH 10.5 client logs in to a throwaway `sshd` on 127.0.0.1 through the agent. Run on 2026-11-24: accepted with the approving phone; refused with a phone that denies, signs with another key, is unreachable, or never answers.
- **Decision:** Accepted as a first version, with these choices by the assistant, to confirm:
  - one thread per connection with blocking socket calls, bridged to async code with a semaphore, rather than Network.framework or dispatch sources;
  - a connection that carries a forwarding session-bind, or more than one session-bind, can no longer sign (agent forwarding is unsupported);
  - a sign request without session-bind is still sent to the phone, which refuses it: the phone stays the only place that decides.
  One bug was found by the script, not by the unit tests: the public key line stayed in the `print` buffer when standard output was a file. Fixed.
- **Human verification:** PENDING: human to complete. Check:
  - line-by-line review of `AgentSocket.swift`, `AgentSession.swift`, `SigningQueue.swift`, `P256SignatureVerifier.swift`, `SoftwarePhone.swift` and the new function in `ECDSAP256.swift`;
  - rerun `swift test` in both packages and `Scripts/try-with-local-ssh.sh --with-timeout`;
  - that no shipping target ever depends on `SentryKeyAgentDevSupport`;
  - the limits chosen without measurement: 45-second timeout, 16 connections, 8 waiting requests, 5-minute idle time.
- **Commit / PR:** branch `feature/mac-agent`, stacked on `feature/phone-link-messages` and on pull request #9

### P-019 · 2026-11-24 · CI job running the Swift tests

- **Author:** michael-rousseau
- **Tool / model:** Claude Code (Claude Fable 5.2)
- **Goal:** Have the unit tests run on every pull request, not only on the author's Mac.
- **Prompt (verbatim):** "ajoute un job swift test dans la ci, et explique moi tout ce que tu as fait"
- **Output (summary):** `.github/workflows/swift-test.yml`: one job per package (`SentryKeyProtocol`, `SentryKey-macOS`) running `swift test` on the `macos-26` runner, on pull requests and on `main`. The token is read-only, the checkout action is pinned to the same commit as in the Gitleaks workflow, and a package missing from a branch is skipped with a notice. A "Tests in CI" section was added to `CONTRIBUTING.md`.
- **Decision:** Accepted. The runner is pinned to `macos-26` rather than `macos-latest`. Its default Xcode is 26.6, older than the Xcode 27.2 the code was written and tested with, so a compiler difference is possible. The script that logs in to a local `sshd` and the iPhone app build were left out of CI: neither was asked for, and the first has never run on a hosted runner.
- **Human verification:** PENDING: human to complete. Check:
  - the first run of the workflow on GitHub: it was validated as YAML only, and has never run;
  - that both packages compile with the runner's Xcode 26.6;
  - whether the team wants the job to be a required check in the branch protection of `main`.
- **Commit / PR:** pull request #11

### P-020 · 2026-11-24 · List of what must change before shipping

- **Author:** michael-rousseau
- **Tool / model:** Claude Code (Claude Fable 5.2)
- **Goal:** Have one place that lists everything standing between the current code and a version that could be shipped.
- **Prompt (verbatim):** "ecrit dans un fichier tout ce qu'il faudra changer pour envoyer en prod"
- **Output (summary):** `docs/PRODUCTION_CHECKLIST.md`, in eight sections: parts that do not exist yet, temporary code that must not ship (pairing that accepts any QR code, the stand-in phone, placeholders), limits chosen without measurement, limits of what is supported, what was never run on a device, reviews and verifications still owed, continuous integration gaps, and distribution. Items come from a search of the code for temporary markers, from the READMEs, the architecture document and the journal.
- **Decision:** Accepted. "Production" was read as more than the J5 demo, so the last section covers distribution, which the free Apple developer account does not allow. Items are tagged J3, J4 or product.
- **Human verification:** PENDING: human to complete. Check:
  - the file and line references, which will drift as the code changes;
  - that nothing temporary is missing from section 2: the list comes from comments and READMEs, so undocumented shortcuts are not in it;
  - the distribution section: the statements about the paid developer program and notarization were written from the assistant's knowledge, not checked against Apple's current documentation.
- **Commit / PR:** pull request #11

### P-021 · 2026-11-24 · Secure channel: handshake and AES-GCM messages

- **Author:** michael-rousseau
- **Tool / model:** Claude Code (Claude Fable 5.2)
- **Goal:** Build work package B of the J3 plan (P-017): the secure channel between the Mac and the phone, in the shared package.
- **Prompt (verbatim):** "tu peux commencer partie B du plan?"
- **Output (summary):**
  - `SentryKeyProtocol/Sources/SentryKeyProtocol/Channel/HandshakeMessages.swift`: `MacHello` and `PhoneHello`, their encoding, strict parsing, and the exact bytes each side signs. No cryptography, so it builds on Linux.
  - `Channel/SecureChannel.swift` (CryptoKit): `MacHandshake`, `PhoneHandshake` and `SecureChannel`. Ephemeral P-256 ECDH signed by the identity keys, HKDF-SHA256 with the two nonces as salt, one AES-256-GCM key per direction, a counter used as the nonce and checked strictly, a timestamp on every message, and a channel that stays closed after any failure. Identity keys come through an `IdentitySigner` protocol.
  - 35 new tests (123 in the package): every altered byte of both handshake messages and of a sealed message is refused, as are a stranger, a hello meant for another phone, an answer from another connection or another phone, an old or future timestamp, an ephemeral key not on the curve, a replayed, reordered or reflected message, every truncation, an oversized message, and a counter about to wrap.
  - `.gitleaks.toml`: the default rules plus one exception. The secret scanner flagged `private let ephemeralKey: P256.KeyAgreement.PrivateKey`, taking the type name for a secret, as it had in P-018. The exception lets through those two exact CryptoKit type names and nothing else. Checked that a fake secret is still reported with this configuration.
  - Checked on Linux with the Docker command from the package README: the package builds with Swift 6.2 and 96 tests pass, the CryptoKit-dependent ones being compiled out.
- **Decision:** Accepted as a first version. `docs/FLOWS.md` lists several points the architecture does not specify. The assistant chose, and these are proposals for the team, not decisions:
  - the Mac sends its handshake message first;
  - what each signature covers (see the package README);
  - the phone relies on the signed timestamp for freshness, with a 5-minute tolerance, rather than on a third handshake message;
  - `MacHello` carries the Mac's identity fingerprint in clear.
  `docs/ARCHITECTURE.md` was not changed. Nothing uses the channel yet: wiring it to Bluetooth and to Secure Enclave keys is work package D.
- **Human verification:** PENDING: human to complete. Check:
  - line-by-line review of `SecureChannel.swift` and `HandshakeMessages.swift` by the security architect: this is the project's main crypto code;
  - the four choices above, then record the agreed ones in `docs/ARCHITECTURE.md`;
  - the CryptoKit calls against Apple's documentation: `hkdfDerivedSymmetricKey`, `AES.GCM.seal` and `open` with an explicit nonce, and that `P256.KeyAgreement.PublicKey(x963Representation:)` rejects points off the curve (one test relies on it);
  - with real Secure Enclave keys on both devices, which could not be tried here;
  - that the team accepts the exception added to the secret scanner in `.gitleaks.toml`.
- **Commit / PR:** branch `feature/secure-channel`, stacked on pull request #11

### P-022 · 2026-11-24 · The agent through the secure channel, and the iPhone app on the link messages

- **Author:** michael-rousseau
- **Tool / model:** Claude Code (Claude Fable 5.2)
- **Goal:** Make work packages A and B fit together before Bluetooth exists, and bring the iPhone app in line with the link messages from P-017.
- **Prompt (verbatim):** "fais A et c sur une branche, j'ai merge 9". A and C were two of five options the assistant had listed: A, plug the channel into the agent; C, the iPhone side of the link messages.
- **Output (summary):**
  - `SentryKeyProtocol/.../Channel/ChannelSessions.swift`: `MacChannelSession` and `PhoneChannelSession`, one connection seen from each side. They take the messages received and return the messages to send, and do no input or output.
  - `SentryKey-macOS`: `SecurePhoneLink`, a `PhoneLink` that opens a connection, runs the handshake, seals requests and opens answers, with a handshake timeout and one retry on a fresh connection. New ports `PhoneConnector` and `PhoneConnection`, which Bluetooth will implement.
  - Development targets: `LoopbackPhoneConnector`, an in-memory connection whose phone end runs `PhoneChannelSession`, and `SoftwareIdentity`. The development agent now reaches its stand-in phone through the real handshake and channel.
  - `SentryKey-iOS/SentryKey/AppModel.swift`: `receive(_:)` takes a `PhoneRequest`, every answer is a `PhoneResponse` with the request's identifier and a refusal reason, and a `cancel` from the Mac closes the open prompt.
  - Tests: 9 for the sessions (132 in the protocol package), 10 for `SecurePhoneLink` (45 in the agent package). `Scripts/try-with-local-ssh.sh --with-timeout` passes: a real OpenSSH 10.5 login goes through the handshake and AES-GCM. The iPhone app builds for iOS in Debug and Release. The protocol package still builds and passes on Linux.
- **Decision:** Accepted, after two faults found while testing:
  - **The test helper `ManualTimeout`, written for P-018, was wrong.** It was built on one shared `AsyncStream`. Cancelling a task that iterates a stream ends the stream for good, so after the first cancelled wait every later timeout fired at once. Tests that depended on it passed or failed by chance, and the claim in P-018 that they were stable rested on five lucky runs. It was rewritten with one continuation per wait. The agent tests then passed 25 runs out of 25.
  - The in-memory connection kept accepting sends after it was closed, so a request could wait forever for an answer. It now fails. Time limits were added to the two test suites that wait on streams, so a missing answer fails a test instead of hanging it.
  The `AppModel` change was not run: it compiles, and the demo request needs a device.
- **Human verification:** PENDING: human to complete. Check:
  - line-by-line review of `ChannelSessions.swift` and `SecurePhoneLink.swift`, in particular that two sends can never reach the phone out of order, and what happens to a request in flight when the connection drops;
  - `AppModel.swift`: the refusal reason chosen for each case, and that a `cancel` for a request that is not the open one changes nothing;
  - on the iPhone 14 Pro: the demo request still reaches the approval sheet and signs;
  - whether no answer should be sent after a `cancel` (the choice made here), or an explicit one.
- **Commit / PR:** branch `feature/channel-integration`, stacked on pull request #12

### P-023 · 2026-11-24 · Local notification for a sign request (work package F)

- **Author:** michael-rousseau
- **Tool / model:** Claude Code (Claude Fable 5.2)
- **Goal:** Tell the user a sign request is waiting when the app is not on screen, since Face ID needs the app in the foreground.
- **Prompt (verbatim):** "tu peux faire 4 PR pour ca? prototype de réveil Bluetooth (lot C), transport Bluetooth (D), appairage (E), notification (F)". This entry covers F. The assistant took the four in the order F, E, D, C, because each builds on the previous one.
- **Output (summary):**
  - `SentryKey-iOS/SentryKey/ApprovalNotifier.swift`: a local notification posted when a request arrives while the app is not on screen, and removed when the request is answered, expires or is cancelled by the Mac.
  - The notification names neither the server nor the account: it shows on the lock screen (red team guide, T9.2).
  - Permission is asked at the end of pairing. `AppModel.isOnScreen` follows the scene phase.
  - A second Debug button, "Show a demo request in 5 seconds", to try it without a Mac.
- **Decision:** Accepted. The text of the notification is deliberately vague, which costs the user a tap before they know which server is asking. Time Sensitive notifications are not used: the architecture notes they are not available on a free account.
- **Human verification:** PENDING: human to complete. Nothing here was run: it builds for iOS in Debug and Release, and the simulator cannot pair, so it cannot reach a demo request. On the iPhone 14 Pro, check:
  - the permission prompt appears after pairing;
  - with the delayed demo: the notification shows with the app in the background and with the phone locked, and tapping it opens the approval sheet;
  - the notification disappears after approving, denying and after the 30-second expiry;
  - whether the app, when woken over Bluetooth rather than by a timer, is still allowed to post it. That is the architecture's first open question.
- **Commit / PR:** branch `feature/local-notification`, stacked on pull request #13

### P-024 · 2026-11-24 · Pairing by QR code (work package E)

- **Author:** michael-rousseau
- **Tool / model:** Claude Code (Claude Fable 5.2)
- **Goal:** Replace the temporary pairing, which accepted any QR code, with the real one.
- **Prompt (verbatim):** the same request as P-023 ("tu peux faire 4 PR pour ca? ..."), then "tu peux creer une PR poru chacune apres". This entry covers E.
- **Output (summary):**
  - `SentryKeyProtocol/.../Pairing/`: `PairingOffer` (the QR code), `PairingRequest`, `PairingConfirmation`, and `MacPairing` and `PhonePairing`, which check them with HMAC-SHA256 keyed by the one-time secret. 17 tests, 149 in the package.
  - `Channel/SecureEnclaveIdentity.swift`: an `IdentitySigner` backed by a Secure Enclave key, for both devices.
  - iPhone: `IdentityKeyStore` (the phone identity key, no Face ID, usable after first unlock), `AppModel.pair` reads a real code and prepares the request, a "Waiting for your Mac" screen, the paired Macs saved with the app's state, and a Debug-only "Pair without a Mac" so the demo request stays usable.
  - Mac: `PairingStore` (the paired phone, replacing the fixed key store for the real agent) and `MacIdentityKey` (Secure Enclave). 8 tests, 53 in the agent package.
  - Checked on this Mac that a command-line tool with no signature can create a Secure Enclave key and sign with it. The architecture had left this to verify.
- **Decision:** Accepted. Two points the architecture leaves open were decided by the assistant and are proposals: an HMAC over a labelled transcript of the three public keys, and a QR code valid 2 minutes for one phone. The iPhone's `KeyStore.swift` was deliberately not touched: the identity key has its own file, at the cost of repeating about thirty lines of Keychain code.
- **Human verification:** PENDING: human to complete. Check:
  - line-by-line review of `Pairing.swift`, `PairingMessages.swift`, `IdentityKeyStore.swift`, `PairingStore.swift` and `SecureEnclaveIdentity.swift`;
  - the two proposals above, then write the agreed ones into `docs/ARCHITECTURE.md`;
  - **nothing on the iPhone was run**: it builds for iOS. The Secure Enclave calls for the identity key, and whether that key really works with the phone locked, need the iPhone 14 Pro;
  - a Release build no longer shows "Pair without a Mac";
  - the two Secure Enclave tests are skipped on the CI runner, which has no Secure Enclave: they only run on a real Mac.
- **Commit / PR:** branch `feature/pairing`, stacked on pull request #14

### P-025 · 2026-11-24 · Bluetooth transport on both devices (work package D)

- **Author:** michael-rousseau
- **Tool / model:** Claude Code (Claude Fable 5.2)
- **Goal:** Carry pairing and the secure channel over Bluetooth, between the iPhone and the Mac.
- **Prompt (verbatim):** the same request as P-023 ("tu peux faire 4 PR pour ca? ..."). This entry covers D.
- **Output (summary):**
  - `SentryKeyProtocol/.../Transport/TransportMessage.swift`: the service's identifiers and a kind byte separating pairing messages from channel messages. 8 tests, 157 in the package.
  - iPhone: `Bluetooth/BLEPeripheral.swift` (peripheral, one reassembler per connected device, at most four devices, state restoration) and `PhoneLinkController.swift` (one `PhoneChannelSession` per device, pairing messages, answers routed back to the Mac that asked). The Bluetooth permission text, and an `Info.plist` for the `bluetooth-peripheral` background mode.
  - Mac: target `SentryKeyBluetooth` with `BluetoothLink` (central), `BluetoothPhoneConnector` (a `PhoneConnector`), `BluetoothPairing`, and a QR code drawn in a terminal. Executable `sentrykey-agent` with `pair` and `run`, using the Mac's Secure Enclave identity key and the pairing store, with its Bluetooth usage text embedded in the binary.
  - 4 tests for the QR code and the stored Bluetooth identifier, 57 in the agent package.
- **Decision:** Accepted as untested code, and labelled as such in every file. **None of the Bluetooth code has run**: this Mac cannot be used with the iPhone, and running the agent here would have asked the user for a Bluetooth permission on a managed machine. What was checked: both devices' code compiles, the iPhone app builds in Debug and Release and still launches in the simulator, the generated `Info.plist` carries the background mode, the agent binary contains its usage text, and the development agent's real `ssh` check still passes.
  One mistake corrected on the way: the background mode was first set through a build setting, which Xcode ignored without a word. It needs a real `Info.plist`.
- **Human verification:** PENDING: human to complete. This is the entry with the most left to check:
  - line-by-line review of `BLEPeripheral.swift`, `PhoneLinkController.swift`, `BluetoothLink.swift`, `BluetoothPhone.swift` and `TransportMessage.swift`;
  - on the iPhone 14 Pro and a Mac: `sentrykey-agent pair`, then `run`, then a real `ssh` login approved with Face ID;
  - whether macOS grants Bluetooth to the command-line agent;
  - the CoreBluetooth calls against Apple's documentation, in particular state restoration (`willRestoreState`), the single answer to a batch of writes, and writes with response being acknowledged in order;
  - that `SentryKeyApp.init` runs when iOS relaunches the app in the background, which the transport relies on.
- **Commit / PR:** branch `feature/bluetooth-transport`, stacked on pull request #15
