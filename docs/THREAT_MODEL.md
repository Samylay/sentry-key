# SentryKey STRIDE Threat Model

**Status:** J1 design artifact. This model describes the intended design; it is not evidence that the mitigations have been implemented or tested.

## System and security goals

SentryKey lets an iPhone hold an SSH signing key while a macOS SSH agent relays signing requests over an encrypted Bluetooth Low Energy (BLE) channel. The private key is generated and used in the iPhone Secure Enclave and is not exported to the Mac. The iPhone applies policy before signing. The Mac receives only the public key and signatures.

The security goals are:

- Keep the SSH private key unavailable to the Mac, including if ordinary Mac files are read by malware.
- Authenticate the paired Mac and protect request/response integrity and confidentiality in transit.
- Prevent replay or alteration of signing requests and enforce the iPhone's approval policy.
- Make approval decisions auditable without treating the log as proof that a compromised endpoint behaved honestly.

## Scope, assumptions, and trust boundaries

In scope: QR-based pairing, key generation/storage/use, BLE transport, the Mac SSH agent, request validation, approval policy, signatures, and the decision log. The SSH server and the wider Apple operating systems are external dependencies.

Assumptions to validate during implementation: CryptoKit provides the approved primitives; the Secure Enclave key is P-256 and access-controlled with `biometryCurrentSet`; pairing uses ECDH P-256, HKDF, and AES-GCM; requests carry a nonce, monotonic counter, timestamp, host context, and key identifier. Exact encodings, authenticated fields, key lifecycle, BLE background behavior, and recovery/unpairing behavior are not specified yet. No defense below should be considered implemented until verified in code and on-device.

Trust boundaries:

1. **Mac process boundary:** SSH client ↔ local SentryKey agent via `SSH_AUTH_SOCK`. Other local processes may attempt to connect to or impersonate the client.
2. **Device boundary:** Mac agent ↔ iPhone app over BLE. Radio traffic is observable, injectable, replayable, and disruptable by a nearby attacker.
3. **Pairing boundary:** QR data and fingerprint confirmation establish which Mac is trusted. The display, camera, and the user's comparison/confirmation are part of this boundary.
4. **iPhone security boundary:** untrusted request data enters the app; policy and Secure Enclave operations are intended to control signing.
5. **External boundary:** returned signatures are used by SSH and verified by remote servers. A compromised Mac can use signatures it legitimately obtains even though it cannot extract the private key.

## STRIDE analysis

| STRIDE category | Threat scenario and impact | Planned controls and verification |
|---|---|---|
| **Spoofing** | An attacker presents a fake Mac during pairing, substitutes QR data, or impersonates the local agent/client. The iPhone may pair with an attacker or sign requests the user attributes to another process. | Bind pairing to the Mac's public key and show a fingerprint for confirmation on both devices. Authenticate every channel message with session keys. Validate the local socket peer where supported and restrict socket permissions. Test QR substitution, wrong fingerprint, and unauthorized local clients. |
| **Tampering** | A nearby attacker or compromised Mac changes the host, key identifier, payload, policy fields, or response in transit. | Use authenticated encryption (AES-GCM) with unique nonces; authenticate all security-relevant request fields and enforce strict message schemas and size limits. Verify the SSH signature format and signed payload end to end. Test altered, truncated, malformed, and oversized messages. |
| **Repudiation** | A device owner or compromised endpoint disputes whether a request was approved, or an attacker edits/deletes local decision history. A hash chain alone does not prevent truncation or replacement. | Append decisions to a hash-chained, signed log as designed; record enough request context to explain the decision while minimizing sensitive data. Define signing-key protection and checkpoints/export if tamper evidence across app reinstall is required. Test edits, deletion, reordering, and truncation. Treat a local log as tamper-evident only within its stated storage and key assumptions. |
| **Information disclosure** | Malware reads credentials from the Mac; BLE observers learn request details; logs expose hostnames or sensitive signing context; pairing/session secrets leak. | Generate and use the private key in Secure Enclave without export. Use authenticated encryption for BLE; minimize and redact logs; avoid storing session secrets beyond their lifetime. Verify key attributes and that private key material is never serialized or logged. Note that the Mac still sees request metadata and can observe/use returned signatures. |
| **Denial of service** | Radio interference, BLE disconnects, repeated malformed requests, or an attacker flooding the agent/app prevents signing or drains device resources/battery. | Bound and validate input, rate-limit requests, use bounded timeouts/retries, and fail closed when channel state or freshness checks fail. Do not claim availability against radio jamming; test resource limits and recovery after disconnect. |
| **Elevation of privilege** | A compromised Mac abuses the agent as a signing oracle, forges host context, replays an approved request, or bypasses policy; a bug in request parsing/policy causes unauthorized signing. | Make the iPhone authoritative for approval; bind each request to the active session, key, payload, host context, nonce/counter, and freshness window; reject repeats and enforce per-host policy, session approval, proximity, and rate limits. Require Face ID for configured anomalies and use `biometryCurrentSet` key access control. Test stale/replayed requests, host changes, counter rollback, biometric changes, and policy bypass attempts. |

## Important residual risks

- A fully compromised Mac can request signatures and use signatures it receives. SentryKey protects key extraction; it cannot make a compromised Mac trustworthy. The phone-side policy and user-visible request context must limit this signing-oracle risk.
- Host identity is not trustworthy merely because the agent reports a hostname. The design must define how host context is authenticated or displayed, and what the SSH signature actually binds. User and policy decisions should not rely on unauthenticated host labels.
- BLE proximity is an imperfect signal and may be relayed. It should not serve as the sole authorization factor.
- QR confirmation depends on users comparing the right fingerprint on both screens; pairing UX and recovery/unpairing rules remain to be specified.
- A local signed/hash-chained log cannot prove completeness if an attacker can delete the whole log or control the signing environment. Persistence, key custody, and export/checkpoint strategy remain open.
- Malicious or faulty iOS/macOS software, Secure Enclave/OS compromise, physical coercion, radio jamming, and SSH server compromise are outside this design's protection.

