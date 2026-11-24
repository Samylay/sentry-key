# Before SentryKey can ship

Everything that has to change between the code as it is and a version that real users could rely on. Written on 2026-11-24 from the code on `feature/mac-agent`. Update it when an item is done: an item is removed only once it is merged and verified.

"Ship" here means more than the J5 demo. Items needed for the demo are marked **[J3]** or **[J4]**, after the milestone that plans them in `docs/ARCHITECTURE.md`. Items marked **[product]** go beyond the course project.

## 1. It does not work end to end yet

No iPhone has ever signed an SSH login. These are missing, not unfinished.

| Missing | Where it goes | Milestone |
|---|---|---|
| Bluetooth link: peripheral on the iPhone, central on the Mac | `BLEPeripheral` in `SentryKey-iOS/`, `BLECentral` in a Mac app target. The Mac side implements `PhoneLink` (`SentryKey-macOS/Sources/SentryKeyAgent/Ports.swift`) | J3 |
| Secure channel over a real transport, with real keys. The channel exists and the Mac agent uses it (`SecurePhoneLink`), but only against a stand-in phone in the same process and with software identity keys: no Secure Enclave key implements `IdentitySigner`, and the iPhone app does not use `PhoneChannelSession` | `SentryKey-iOS/`, the Mac app | J3 |
| Real pairing: QR payload, one-time secret, exchange of public keys | `SentryKeyProtocol/`, `AppModel.pair`, a pairing window on the Mac | J3 |
| Phone identity key and Mac identity key, both in a Secure Enclave | `KeyStore.swift`, a Mac `IdentityKey` | J3 |
| Local notification when a request arrives in the background | `AppModel.swift:178` | J3 |
| Mac menu bar app: status, pairing, recent signatures | New app target. Needed for the Bluetooth permission, which a command-line tool cannot hold | J3 |
| Hash-chained audit log, head mirrored on the Mac | `AppModel.swift:38`: the history is an in-memory array, lost when the app closes | J4 |
| Recovery key, recovery code and key registry | `docs/ARCHITECTURE.md`, Recovery | J4 |

The riskiest open question is still open: whether the Mac can reliably wake the backgrounded iPhone app over Bluetooth. If it cannot, the design changes.

## 2. Temporary code that must not ship

| Item | File | What to do |
|---|---|---|
| **Pairing accepts any QR code** under 1 KB and stores nothing about the Mac | `SentryKey-iOS/SentryKey/AppModel.swift:101-110` | Replace with real pairing. As it is, any QR code "pairs" the phone and no Mac is authenticated. |
| **Answers go nowhere**: `sendResponse` is an empty closure, and nothing calls `receive(_:)` but the demo | `SentryKey-iOS/SentryKey/AppModel.swift` | Wire both to `PhoneChannelSession` over Bluetooth. |
| **Stand-in phone with a software key on the Mac** | `SentryKey-macOS/Sources/SentryKeyAgentDevSupport/`, `Sources/sentrykey-agent-dev/` | Never link from a shipping target. Before a release, check the dependency list of every product. Consider moving both targets out of the shipped package. |
| **Fixed public key store** | `FixedPublicKeyStore` in `Ports.swift` | Replace with a store that reads the key recorded at pairing. |
| **Demo request** | `SentryKey-iOS/SentryKey/DemoRequest.swift`, `Views/SettingsView.swift:33` | Already inside `#if DEBUG`. Confirm on a Release build that the entry is gone. |
| **Placeholder bundle identifier** `com.example.SentryKey`, empty signing team | `SentryKey-iOS/SentryKey.xcodeproj/project.pbxproj:190,215` | Set the real identifier and team. |
| **No app icon**, no asset catalog | `SentryKey-iOS/` | Add an asset catalog with an icon. |
| **Development agent logs the user name** of each login | `Sources/sentrykey-agent-dev/main.swift` | Development only, but CLAUDE.md forbids names in logs: the real agent must log fingerprints and event kinds only, as `AgentEvent` does. |

## 3. Values chosen without measurement

Each is a guess. Measure on real use, then record the reasoning in `docs/ARCHITECTURE.md`.

| Value | Now | File |
|---|---|---|
| Prompts before the phone refuses, and the cooldown | 5 per 60 s, then 120 s | `SentryKeyProtocol/.../Approval/PromptRateLimiter.swift:17` |
| Time the user has to answer on the phone | 30 s | `AppModel.answerTime`, `AppModel.swift:59` |
| Time the Mac waits for the phone | 45 s | `SigningQueue.defaultAnswerTime` |
| Requests allowed to wait on the Mac | 8 | `SigningQueue.defaultMaxWaiting` |
| Agent connections at once | 16 | `AgentSocket.maxConnections` |
| Idle time before a connection is closed, write timeout | 300 s, 5 s | `AgentSocket.swift` |
| How far a timestamp may be from the receiver's clock | 300 s | `ChannelLimits.clockToleranceSeconds` |
| Time the Mac waits for the phone's handshake answer | 10 s | `SecurePhoneLink.defaultHandshakeTime` |

The cooldown is also a way for malware on the Mac to lock the user out of every server (red team guide, T8.1). Decide whether that is acceptable before fixing the numbers.

## 4. Limits of what is supported

| Limit | Where | Decision needed |
|---|---|---|
| Only **Ed25519** server host keys are accepted | `SentryKeyProtocol/.../Approval/HostKeySignature.swift` | Servers offering only RSA or ECDSA host keys cannot be used. Add them or document it. |
| **Agent forwarding** (`ssh -A`) is refused | `AgentSession.swift` | Keep refusing, or design how the phone shows a forwarded request. |
| **Git commit signing** (SSHSIG) is refused | `LoginApprovalCheck` | Stretch goal in the architecture. |
| `ssh` older than 8.9 sends no session-bind, so every request is refused | `LoginApprovalCheck`: `noSessionBind` | Document the minimum OpenSSH version. |
| The code is **stricter than the J3 row** of the architecture, which says "host reported by the Mac, labelled unverified" | `AppModel.swift:159` | Keep the code and correct the document. |

## 5. Never run on a device

Everything below compiles and nothing more. It has to be exercised on the iPhone 14 Pro, and the iOS version recorded.

- Creating the Secure Enclave key, and signing with it (`KeyStore.swift`).
- One Face ID gives exactly one signature. A second request must ask again.
- Enrolling a new face makes the key unusable (`biometryCurrentSet`), and the app says so.
- The QR scanner (`PairingView.swift`).
- The approval sheet, its timeout, and what happens when the app goes to the background mid-approval.
- Whether the keys survive re-running the app from Xcode after the 7-day expiry, and deleting it.
- The app snapshot is hidden in the app switcher.
- The notification does not show a server and a user name on the lock screen to whoever picks up the phone (red team guide, T9.2).

## 6. Review and verification still owed

- **15 journal entries** say `PENDING: human to complete` under "Human verification" (`docs/PROMPT_JOURNAL.md`). Each lists what to check.
- **Line-by-line review** by someone other than the author, required by CLAUDE.md for crypto and security code. Not done for any of: `KeyStore.swift`, `HostVerifier.swift`, `AppModel.swift`, `LoginApproval.swift`, `HostKeySignature.swift`, `DisplayText.swift`, `LinkMessages.swift`, `HandshakeMessages.swift`, `SecureChannel.swift`, `ECDSAP256.swift`, `ChannelSessions.swift`, `AgentSocket.swift`, `AgentSession.swift`, `SigningQueue.swift`, `SecurePhoneLink.swift`, `P256SignatureVerifier.swift`.
- **Pull requests #6, #7 and #8 were merged without teammate review** (journal entries P-014 and P-015). The rule is one reviewer who is not the author.
- **Red team pass**: none of the trees in `docs/red-team/README.md` has been run against code. Its section 7 lists twelve questions the design leaves open, among them who names a server on first use, and what a stranger's Bluetooth device can trigger before the handshake.
- **`docs/THREAT_MODEL.md` describes an earlier design** (per-host policy, session approval, proximity). It has to be brought in line with `docs/ARCHITECTURE.md`, and must state the assumption that the Mac is not compromised at pairing time.
- **The Xcode project was written by hand** and checked with `xcodebuild` only. Open it in Xcode once and confirm nothing is rewritten unexpectedly.
- One line carries a `gitleaks:allow` marker (`SoftwarePhone.swift`): a false positive on a type name. Recheck it whenever that file changes.

## 7. Continuous integration

- `swift-test` runs the two packages' unit tests. It has **never run**: confirm its first run, and that both packages compile with the runner's Xcode 26.6 (the code was written with Xcode 27.2).
- **The iPhone app is not built in CI.** A change that breaks it is only noticed on someone's Mac. Add an `xcodebuild` job for the simulator.
- `Scripts/try-with-local-ssh.sh` (a real `ssh` login through the agent) is not run in CI.
- Neither workflow is a **required check** on `main`, so a failing pull request can still be merged.

## 8. Distribution [product]

None of this is possible with the free Apple developer account the project is limited to.

- **The installed iPhone app stops working after 7 days.** Any real use needs the paid Apple Developer Program.
- TestFlight and the App Store need the paid program, an App Store review, and a privacy policy.
- A Mac app given to other people has to be signed with a Developer ID certificate and notarized, or macOS refuses to open it.
- The agent has to start at login and be found by `ssh`: a login item, and an `IdentityAgent` line in `~/.ssh/config` that the app adds with the user's consent.
- Updates: a way to ship a fix to both apps, and a protocol version check so an old phone and a new Mac fail clearly instead of oddly.
- Support for what goes wrong in the field: phone replaced, Mac replaced, Face ID re-enrolled, app deleted. This is the recovery design, which is not built.
- Personal data: the log holds server fingerprints, user names and times. Say what is kept, for how long, and let the user delete it (GDPR, and MASVS PRIVACY in the J4 audit).
