# SentryKey red team guide

Working notes for whoever holds the red team role at the current milestone. The role rotates, so this file is written to be picked up cold.

It contains three things:

1. A model of the system and of the attackers we consider.
2. A primer on the transport, limited to what matters for attacking SentryKey: the local network by default, Bluetooth Low Energy as an option (appendix A).
3. Decision trees: for each part of the system, the questions to ask about the implementation and the attack to try for each answer.

Scope: our own app, our own devices, and at J4 the other group's app with their agreement. Nothing here is to be run against devices or networks that are not ours.

**Status:** there is no code yet. Every tree is written against the design in the root `README.md`. Items marked **[verify]** are claims about Apple or OpenSSH behaviour that nobody on the team has confirmed on a real device or in the documentation. Confirm them before writing them into a report.

**Known gap:** this guide was written against `main`. Pull request #1 adds `docs/ARCHITECTURE.md`, which differs from what is assumed here on three points: Bluetooth is the transport, every signature requires Face ID, and automatic approval is out of scope. Until the guide is aligned, read appendix A and the Bluetooth diagram of T3 as the main transport material, and treat the automatic-approval branches of T4 and T5 as not applicable.

**Scope, as reported to the red team on 2026-11-23:**

- SentryKey signs **SSH user authentication only**. `git push` over SSH is in scope because it is an SSH authentication. Signing git commits or arbitrary files with the key is out of scope, and the app refusing such requests is something to test (T4.2).
- The transport is the **local network**. **Bluetooth is optional.** Bluetooth-specific material is in appendix A and in the Bluetooth diagram of T3 (attacks T3.B1 to T3.B6).

## 1. System model

```
            Mac (untrusted host)                         iPhone (trusted device)
 ┌──────────────────────────────────────┐        ┌──────────────────────────────────┐
 │ ssh / git                            │        │ SentryKey app                    │
 │    │  agent protocol                 │        │   channel  ── policy engine      │
 │    ▼  (unix socket, SSH_AUTH_SOCK)   │  LAN   │                │                 │
 │ SentryKey agent ── channel ══════════╪════════╪══► channel     ▼                 │
 │    │                                 │        │           Secure Enclave (P-256) │
 │ Mac identity key, pairing record     │        │   signed, hash-chained log       │
 └──────────────────────────────────────┘        └──────────────────────────────────┘
        boundary 1: socket      boundary 2: network      boundary 3: app ↔ enclave
```

### Assets

| ID | Asset | Where it lives | What losing it means |
|---|---|---|---|
| AS1 | SSH private key | iPhone Secure Enclave | Not extractable by design. The realistic loss is *use*, not theft. |
| AS2 | Ability to obtain a signature | The whole chain | An attacker logs in to our servers or pushes to our repositories. This is the asset that matters. |
| AS3 | Mac identity key and pairing record | Mac | Whoever holds it is "the Mac" to the iPhone. |
| AS4 | Session keys | Memory on both sides | Read and forge channel traffic. |
| AS5 | Decision log | iPhone | Lose the ability to prove what was approved. |
| AS6 | Metadata: host names, times, user names | Channel, log, console | Privacy leak, and a map of our infrastructure. |

### Attackers

| ID | Attacker | Capability |
|---|---|---|
| AT1 | Malware on the Mac | Runs as the logged-in user. Reads the user's files, connects to the user's sockets, starts processes. This is the attacker the project exists to stop. |
| AT2 | Network attacker | On the same Wi-Fi. Listens, injects, redirects traffic, announces fake services, connects to any open port. |
| AT3 | Relay pair | Only if Bluetooth is built. Two radios, one near the iPhone and one near the Mac, forwarding traffic between them. |
| AT4 | Phone thief | Holds the iPhone, locked or unlocked. |
| AT5 | Mac thief | Holds the Mac, locked or unlocked, without the iPhone. |
| AT6 | Malicious server | A host we connect to with agent forwarding enabled. |
| AT7 | The legitimate user | Denies having approved something. |

### Which tree to open

```mermaid
flowchart LR
  classDef q fill:#e8f0fe,stroke:#3b6fd4,color:#12305f
  classDef tree fill:#fff4d6,stroke:#b7791f,color:#5c3d00
  start("Where is the attacker?"):::q
  start -->|"code running on the Mac (AT1)"| t1["T4 sign requests<br/>T6 Mac agent<br/>T1 re-pairing"]:::tree
  start -->|"on the network only (AT2)"| t2["T1 pairing<br/>T2 channel<br/>T3 transport<br/>T8 availability"]:::tree
  start -->|"two radios (AT3), Bluetooth only"| t3["T3 Bluetooth diagram"]:::tree
  start -->|"holds the iPhone (AT4)"| t4["T5 key storage<br/>T7 log<br/>T9 platform"]:::tree
  start -->|"holds the Mac (AT5)"| t5["T6 Mac agent<br/>T3 proximity"]:::tree
  start -->|"remote server (AT6)"| t6["T6 agent forwarding"]:::tree
  start -->|"legitimate user disputes an action (AT7)"| t7["T7 log"]:::tree
```

## 2. Local network primer

The default transport is the one from the brief's reference architecture: iPhone and Mac on the same Wi-Fi, talking directly to each other. The brief states that this network is not trusted.

### 2.1 Connection

- One side opens a listening port, the other connects to it, usually over TCP. On Apple platforms this is Network.framework: `NWListener`, `NWConnection`, `NWBrowser`.
- **Design question for the team:** which side listens? A listener is reachable by every device on the network, so the listening side carries the exposure (tree T3).

### 2.2 Discovery

- **Bonjour** (mDNS + DNS-SD) is how the two devices find each other without a fixed address. A device announces a service type, for example `_sentrykey._tcp`, by multicast. Every device on the network receives the announcement.
- Announcements are not authenticated. Any device can announce the same service name.
- The alternative is to put an address and port in the pairing QR code. It goes stale when the address changes.
- Either way, discovery only says where to connect. It proves nothing about who answers.

### 2.3 What a device on the same network can do

- **Listen.** On an open network, to everything. On a network with a shared password, to other clients' traffic once it has captured their connection handshake.
- **Redirect.** ARP spoofing makes the victim send its traffic through the attacker. A fake Bonjour answer does the same at the discovery level.
- **Impersonate the network.** An access point with the same name and a stronger signal attracts clients.
- **Connect** to any listening port, and send anything.
- Consequence: same as for any transport, all confidentiality and authentication come from the application channel (ECDH + HKDF + AES-GCM). If a security property depends on the Wi-Fi being private, that is a finding.

### 2.4 Framing

- TCP delivers a stream of bytes with no message boundaries. One send can arrive in several pieces, and several sends can arrive glued together.
- The app must define its own framing, typically a length prefix followed by the message.
- That framing code parses attacker-controlled input before any authentication has happened, which makes it a prime target (T3.9).

### 2.5 iOS specifics that shape the attack surface

- **Local network permission.** iOS asks the user before the app may talk to local devices. The app declares `NSLocalNetworkUsageDescription` and its Bonjour service types in `Info.plist`. Recent macOS versions have a similar prompt for the agent. **[verify]**
- **Background execution.** iOS suspends an app shortly after it leaves the foreground, and its sockets stop being serviced. A free account has no push notifications to wake it. Over the local network, the app probably has to be open on screen to answer a request. This is the riskiest assumption behind the zero-touch goal. **[verify]**
- **Locked phone.** Same limit, plus the key protection class (tree T5).
- **Networks that block device-to-device traffic.** Guest, school and corporate Wi-Fi often isolate clients. Nothing to attack, but the demo fails. A personal hotspot is the usual workaround.

### 2.6 Proximity

- Being on the same network does not mean being near. Campus networks span buildings, and a VPN puts a remote machine on the local network.
- A network name is not an identity. Anyone can create a network with the same name.
- Without Bluetooth there is no proximity signal at all. Any policy rule that says "auto-approve when the phone is nearby" has to be dropped or redefined, and the red team should ask which.

### 2.7 Tools

| Tool | Use |
|---|---|
| Wireshark, `tcpdump` | Capture traffic on our own machines. Check that nothing readable crosses the network. |
| `dns-sd -B` | Browse Bonjour services. See what the app announces. |
| `nc` | Connect to the listener by hand and send arbitrary bytes. First tool to reach for. |
| A second Mac running our own code | The simplest fake agent or fake iPhone. |
| Bettercap | ARP and mDNS spoofing, on our own network only. |

Adding any of these to the repository as a dependency follows the vetting rule in `CONTRIBUTING.md`.

## 3. Decision trees

How to read them:

- Each tree is one or more diagrams followed by a table.
- **Blue** boxes are questions about the implementation. Answer them by reading the code or by testing. The answer is on the arrow.
- **Red** boxes are attacks to try. The ID (for example `T1.3`) is what a finding report cites. The table under the diagram says exactly what to do.
- **Green** boxes are the secure answer. Still confirm it with a test.
- **Yellow** boxes are things to report or a pointer to another tree.
- STRIDE letters in the tables: **S**poofing, **T**ampering, **R**epudiation, **I**nformation disclosure, **D**enial of service, **E**levation of privilege.

### T1. Pairing

Authenticating the two keys:

```mermaid
flowchart LR
  classDef q fill:#e8f0fe,stroke:#3b6fd4,color:#12305f
  classDef atk fill:#fde2e2,stroke:#c0392b,color:#7b1e1e
  classDef ok fill:#dff5e3,stroke:#2e8b57,color:#14532d
  classDef note fill:#fff4d6,stroke:#b7791f,color:#5c3d00
  q1("What is in the QR code?"):::q
  q2("How does the Mac authenticate the iPhone key<br/>that comes back over the network?"):::q
  q3("Can the user confirm<br/>without really comparing?"):::q
  q4("How long is the<br/>displayed fingerprint?"):::q
  q5("Is the secret single use<br/>and short lived?"):::q
  q6("Is it written to a log, a file<br/>or the pasteboard on the Mac?"):::q
  q1 -->|"only the Mac public key and fingerprint"| q2
  q1 -->|"a secret: one-time code or key"| q5
  q2 -->|"it does not: first to answer wins"| a1["T1.1<br/>rogue phone answers first"]:::atk
  q2 -->|"user compares a fingerprint on both screens"| q3
  q2 -->|"iPhone proves it knows something from the QR"| q5
  q3 -->|"yes, it is just a button"| a2["T1.2<br/>man in the middle + click-through"]:::atk
  q3 -->|"no"| q4
  q4 -->|"a few characters"| a3["T1.3<br/>fingerprint collision"]:::atk
  q4 -->|"long"| ok1(["OK"]):::ok
  q5 -->|"no"| a4["T1.4<br/>reuse a captured QR code"]:::atk
  q5 -->|"yes"| q6
  q6 -->|"yes"| a5["T1.5<br/>malware reads it, pairs a rogue phone"]:::atk
  q6 -->|"no, memory only"| ok2(["OK"]):::ok
```

Pairing lifecycle:

```mermaid
flowchart LR
  classDef q fill:#e8f0fe,stroke:#3b6fd4,color:#12305f
  classDef atk fill:#fde2e2,stroke:#c0392b,color:#7b1e1e
  classDef ok fill:#dff5e3,stroke:#2e8b57,color:#14532d
  classDef note fill:#fff4d6,stroke:#b7791f,color:#5c3d00
  q7("Can pairing start without the user<br/>physically acting on both devices?"):::q
  q8("Is the number of paired devices limited<br/>and the list visible?"):::q
  q9("Does the session key derivation<br/>include both public keys?"):::q
  q10("After unpairing, does the other side<br/>refuse the old keys?"):::q
  q7 -->|"Mac side: a command or a file change is enough"| a6["T1.6<br/>silent pairing by malware"]:::atk
  q7 -->|"iPhone side: accepts a new pairing over an existing one"| a7["T1.7<br/>replace the legitimate Mac"]:::atk
  q7 -->|"no"| ok3(["OK"]):::ok
  q8 -->|"unlimited or hidden"| a8["T1.8<br/>extra device goes unnoticed"]:::atk
  q8 -->|"yes"| ok4(["OK"]):::ok
  q9 -->|"no"| a9["T1.9<br/>identity misbinding"]:::atk
  q9 -->|"yes"| ok5(["OK"]):::ok
  q10 -->|"no"| a10["T1.10<br/>revoked device keeps working"]:::atk
  q10 -->|"yes"| ok6(["OK"]):::ok
```

| ID | STRIDE | Attack |
|---|---|---|
| T1.1 | S | Answer the pairing from a second phone before the real one does. |
| T1.2 | S | Sit in the middle during pairing and rely on the user clicking through. |
| T1.3 | S | Generate keys until the truncated fingerprint collides with the real one. |
| T1.4 | S | Reuse a photographed or logged QR code later. |
| T1.5 | I | As AT1, read the secret from where the Mac wrote it, then pair a rogue phone. |
| T1.6 | E | As AT1, start a pairing silently and enrol an attacker phone. |
| T1.7 | S | Send a pairing request to an already paired iPhone and replace the legitimate Mac. |
| T1.8 | E | Enrol one more device and check that nobody notices. |
| T1.9 | S | Make each side believe it is talking to someone else, because the keys are not bound into the session. |
| T1.10 | E | Unpair, then keep using the old keys. |

### T2. Application channel

Keys and nonces:

```mermaid
flowchart LR
  classDef q fill:#e8f0fe,stroke:#3b6fd4,color:#12305f
  classDef atk fill:#fde2e2,stroke:#c0392b,color:#7b1e1e
  classDef ok fill:#dff5e3,stroke:#2e8b57,color:#14532d
  classDef note fill:#fff4d6,stroke:#b7791f,color:#5c3d00
  q1("When is ECDH performed?"):::q
  q2("How is the AES-GCM nonce chosen?"):::q
  q3("Is the counter persisted across<br/>restart, crash and reboot?"):::q
  q4("Do both directions share one key<br/>and one counter space?"):::q
  q5("Are message type, direction and counter<br/>inside the authenticated data?"):::q
  q1 -->|"once at pairing, reused forever"| a1["T2.1<br/>no forward secrecy"]:::atk
  q1 -->|"fresh ephemeral keys per session,<br/>authenticated by the long-term keys"| ok1(["OK"]):::ok
  q2 -->|"counter"| q3
  q2 -->|"random 96 bits"| n1["Acceptable at our volume.<br/>Confirm the random source."]:::note
  q2 -->|"fixed, or derived from the timestamp"| a2["T2.2<br/>nonce reuse"]:::atk
  q3 -->|"no, restarts at zero under the same key"| a2
  q3 -->|"yes"| ok2(["OK"]):::ok
  q4 -->|"yes"| a3["T2.3<br/>reflection and nonce collision"]:::atk
  q4 -->|"no"| ok3(["OK"]):::ok
  q5 -->|"no"| a4["T2.4<br/>header tampering"]:::atk
  q5 -->|"yes"| ok4(["OK"]):::ok
```

Replay and error handling:

```mermaid
flowchart LR
  classDef q fill:#e8f0fe,stroke:#3b6fd4,color:#12305f
  classDef atk fill:#fde2e2,stroke:#c0392b,color:#7b1e1e
  classDef ok fill:#dff5e3,stroke:#2e8b57,color:#14532d
  classDef note fill:#fff4d6,stroke:#b7791f,color:#5c3d00
  q6("What does the receiver check<br/>against replay?"):::q
  q7("What if the two clocks disagree?"):::q
  q8("Is every failure answered<br/>the same way?"):::q
  q9("What happens after<br/>a decryption failure?"):::q
  q6 -->|"timestamp only"| a5["T2.5<br/>replay inside the window"]:::atk
  q6 -->|"counter only, kept in memory"| a6["T2.6<br/>replay after restart"]:::atk
  q6 -->|"persisted counter, strictly greater,<br/>plus timestamp"| q7
  q7 -->|"requests are rejected"| n2["See T8.3"]:::note
  q7 -->|"the window widens automatically"| a5
  q8 -->|"no: different errors or timings"| a7["T2.7<br/>error oracle"]:::atk
  q8 -->|"yes"| ok5(["OK"]):::ok
  q9 -->|"the session continues"| a8["T2.8<br/>unlimited forgery attempts"]:::atk
  q9 -->|"the session closes"| ok6(["OK"]):::ok
```

| ID | STRIDE | Attack |
|---|---|---|
| T2.1 | I | Steal a long-term or session key once (AS3 or AS4), then decrypt traffic recorded earlier. |
| T2.2 | I, T | Force a restart and capture two messages sent with the same nonce. Nonce reuse in GCM breaks both confidentiality and authenticity. |
| T2.3 | T | Send a message back to its sender, and look for the same nonce used in both directions. |
| T2.4 | T | Change the header of a captured message and check whether it is still accepted. |
| T2.5 | T | Replay a message inside the tolerance window. Measure how wide the window is. |
| T2.6 | T | Restart the receiver, then replay an old message. |
| T2.7 | I | Compare responses to a bad tag, a bad counter and a bad format to learn what is checked first. |
| T2.8 | T | Send forged messages repeatedly on one session. The session should close at the first failure. |

### T3. Transport and proximity

Everything here applies to the local network transport. The Bluetooth diagram at the end applies only if that transport is built. Read appendix A first.

Listener and discovery:

```mermaid
flowchart LR
  classDef q fill:#e8f0fe,stroke:#3b6fd4,color:#12305f
  classDef atk fill:#fde2e2,stroke:#c0392b,color:#7b1e1e
  classDef ok fill:#dff5e3,stroke:#2e8b57,color:#14532d
  classDef note fill:#fff4d6,stroke:#b7791f,color:#5c3d00
  q1("Which side listens<br/>for connections?"):::q
  q2("On which interfaces?"):::q
  q3("Does the app answer when it is<br/>not in the foreground? (verify)"):::q
  q4("How does each side<br/>find the other?"):::q
  q5("What does the<br/>announcement contain?"):::q
  q1 -->|"the Mac agent"| q2
  q1 -->|"the iPhone app"| q3
  q2 -->|"all of them"| a1["T3.1<br/>reach the listener from another network"]:::atk
  q2 -->|"the Wi-Fi interface only"| ok1(["OK"]):::ok
  q3 -->|"no"| n1["Zero-touch needs the app open on screen.<br/>Report the design gap (matrix S2, S3)."]:::note
  q3 -->|"yes"| n2["See T5.6"]:::note
  q4 -->|"Bonjour service name"| a2["T3.2<br/>announce the same service"]:::atk
  q4 -->|"address stored at pairing"| a3["T3.3<br/>take over the address"]:::atk
  q4 -->|"Bonjour"| q5
  q5 -->|"user name, device name, key fingerprint,<br/>anything stable"| a4["T3.4<br/>track the user"]:::atk
  q5 -->|"nothing identifying"| ok2(["OK"]):::ok
```

On the wire:

```mermaid
flowchart LR
  classDef q fill:#e8f0fe,stroke:#3b6fd4,color:#12305f
  classDef atk fill:#fde2e2,stroke:#c0392b,color:#7b1e1e
  classDef ok fill:#dff5e3,stroke:#2e8b57,color:#14532d
  classDef note fill:#fff4d6,stroke:#b7791f,color:#5c3d00
  s1("Always try"):::q
  q6("Is TLS added underneath<br/>the application channel?"):::q
  q7("Does anything rely on it?<br/>(identity, replay protection)"):::q
  s1 -->|"before the handshake"| a5["T3.5<br/>pre-handshake leak"]:::atk
  s1 -->|"in the path"| a6["T3.6<br/>modify, drop, reorder, duplicate"]:::atk
  s1 -->|"in the path"| a7["T3.7<br/>sizes and timing"]:::atk
  q6 -->|"no"| ok3(["Fine: the application channel<br/>carries the security"]):::ok
  q6 -->|"yes"| q7
  q7 -->|"yes"| a8["T3.8<br/>certificate validation"]:::atk
  q7 -->|"no"| ok4(["OK"]):::ok
```

Parsing and connections:

```mermaid
flowchart LR
  classDef q fill:#e8f0fe,stroke:#3b6fd4,color:#12305f
  classDef atk fill:#fde2e2,stroke:#c0392b,color:#7b1e1e
  classDef ok fill:#dff5e3,stroke:#2e8b57,color:#14532d
  classDef note fill:#fff4d6,stroke:#b7791f,color:#5c3d00
  q8("Maximum message length,<br/>checked before allocating?"):::q
  q9("Declared length checked<br/>against what arrives?"):::q
  q10("Incomplete messages dropped<br/>after a timeout?"):::q
  q11("Decoded message validated before use?<br/>(types, sizes, required fields)"):::q
  q12("Limit on unauthenticated<br/>connections?"):::q
  q13("Handshake timeout?"):::q
  q8 -->|"no"| a9["T3.9a<br/>huge message"]:::atk
  q8 -->|"yes"| q9
  q9 -->|"no"| a10["T3.9b<br/>length mismatch"]:::atk
  q9 -->|"yes"| q10
  q10 -->|"no"| a11["T3.9c<br/>unfinished messages"]:::atk
  q10 -->|"yes"| q11
  q11 -->|"no"| a12["T3.9d<br/>malformed fields"]:::atk
  q11 -->|"yes"| ok5(["OK"]):::ok
  q12 -->|"no"| a13["T3.10<br/>hold many connections"]:::atk
  q12 -->|"yes"| q13
  q13 -->|"no"| a14["T3.11<br/>connect and stay silent"]:::atk
  q13 -->|"yes"| ok6(["OK"]):::ok
```

Location and proximity:

```mermaid
flowchart LR
  classDef q fill:#e8f0fe,stroke:#3b6fd4,color:#12305f
  classDef atk fill:#fde2e2,stroke:#c0392b,color:#7b1e1e
  classDef ok fill:#dff5e3,stroke:#2e8b57,color:#14532d
  classDef note fill:#fff4d6,stroke:#b7791f,color:#5c3d00
  q14("Is location or proximity<br/>used in the policy?"):::q
  q15("What counts as near<br/>or trusted?"):::q
  q16("Who reports the<br/>network name?"):::q
  q14 -->|"no"| n3["Skip to T4"]:::note
  q14 -->|"yes"| q15
  q15 -->|"reachable, or on the same network"| a15["T3.12<br/>join the network"]:::atk
  q15 -->|"a trusted network name"| q16
  q15 -->|"any rule at all"| a18["T3.15<br/>phone on the desk, user away"]:::atk
  q16 -->|"the Mac"| a16["T3.13<br/>the Mac vouches for itself"]:::atk
  q16 -->|"the iPhone"| a17["T3.14<br/>network with the same name"]:::atk
```

Bluetooth (optional):

```mermaid
flowchart LR
  classDef q fill:#e8f0fe,stroke:#3b6fd4,color:#12305f
  classDef atk fill:#fde2e2,stroke:#c0392b,color:#7b1e1e
  classDef ok fill:#dff5e3,stroke:#2e8b57,color:#14532d
  classDef note fill:#fff4d6,stroke:#b7791f,color:#5c3d00
  b1("How is the peer recognised<br/>before the handshake?"):::q
  b2("What is readable<br/>without pairing?"):::q
  b3("What counts as near?"):::q
  b4("Who measures the<br/>signal strength?"):::q
  b5("Does any property depend on<br/>Bluetooth link encryption?"):::q
  b1 -->|"device name, service UUID<br/>or CoreBluetooth identifier"| x1["T3.B1<br/>advertise the same name"]:::atk
  b1 -->|"nothing: the handshake decides"| ok7(["OK"]):::ok
  b2 -->|"characteristics"| x2["T3.B2<br/>read everything before pairing"]:::atk
  b2 -->|"advertising packet"| x3["T3.B3<br/>track the phone"]:::atk
  b3 -->|"being connected"| x4["T3.B4<br/>relay"]:::atk
  b3 -->|"signal strength above a threshold"| b4
  b4 -->|"the Mac, which reports it"| x5["T3.B5<br/>the Mac reports a strong signal"]:::atk
  b4 -->|"the iPhone"| x6["T3.B6<br/>raise the signal"]:::atk
  b5 -->|"yes"| n4["Finding. See A.4."]:::note
  b5 -->|"no"| ok8(["OK"]):::ok
```

| ID | STRIDE | Attack |
|---|---|---|
| T3.1 | E | Reach the listener from another network: VPN, hotspot, second interface. |
| T3.2 | S | Announce the same Bonjour service from another machine. Expected: connection, then failure at the channel handshake. Anything more is a finding. |
| T3.3 | S | Take over the stored address with ARP spoofing. Same expected result. |
| T3.4 | I | Identify and follow the user from what the announcement contains. |
| T3.5 | I | Connect with `nc`. Record what the peer sends unprompted and how it answers garbage. Anything beyond handshake material is a leak. |
| T3.6 | T | From the path (ARP spoofing, fake access point), modify, drop, reorder and duplicate packets. Expected: the session closes and nothing is accepted. |
| T3.7 | I | From the path, record sizes and timing. Note what they reveal: when the user connects, to how many hosts. |
| T3.8 | S | Present a wrong certificate. Accepting any certificate is the usual AI-generated shortcut. |
| T3.9a | D | Announce a huge message and exhaust memory. |
| T3.9b | T | Send short, extra, zero-length and split messages. |
| T3.9c | D | Start many messages and never finish them. |
| T3.9d | T | Send malformed fields, wrong types, empty or oversized strings. |
| T3.10 | D | Hold many connections open and see whether the real peer is starved. |
| T3.11 | D | Connect and stay silent. |
| T3.12 | S | Be on the network: shared Wi-Fi, VPN, access point with the same name. |
| T3.13 | S | As AT1, report the trusted network name. A compromised Mac must not vouch for itself. |
| T3.14 | S | Create a network with the trusted name. |
| T3.15 | E | Leave the phone on the desk with the Mac unlocked and the user away. Check whether signing is still automatic. |
| T3.B1 | S | Advertise the same name and UUID from another device. Expect failure at the handshake. |
| T3.B2 | I | Read every characteristic with nRF Connect before pairing. Note what leaks. |
| T3.B3 | I | Follow the user's phone from its advertisement. |
| T3.B4 | S | Relay (AT3). Cheap version first: how far away, through walls, is the phone still "near"? |
| T3.B5 | S | As AT1, report a strong signal. |
| T3.B6 | S | Raise the signal: closer antenna, amplifier, relay with gain. |

### T4. Sign requests and the policy engine

This is where the central claim of the project is tested: malware on the Mac must not be able to get a signature the user did not intend.

Starting point: any process of the user can connect to the agent's unix socket. That is normal, so assume AT1 can send sign requests.

What the iPhone knows about a request:

```mermaid
flowchart LR
  classDef q fill:#e8f0fe,stroke:#3b6fd4,color:#12305f
  classDef atk fill:#fde2e2,stroke:#c0392b,color:#7b1e1e
  classDef ok fill:#dff5e3,stroke:#2e8b57,color:#14532d
  classDef note fill:#fff4d6,stroke:#b7791f,color:#5c3d00
  q1("What does the iPhone know<br/>about the request?"):::q
  q2("Does it reject anything that is not a well-formed<br/>SSH user authentication request?"):::q
  q3("Does it show the user what it parsed?<br/>(user name, key, type)"):::q
  q4("Is a request without<br/>binding refused?"):::q
  q1 -->|"only what the Mac agent says:<br/>host, user, purpose"| a1["T4.1<br/>false host label"]:::atk
  q1 -->|"it parses the data to sign itself"| q2
  q1 -->|"the request is bound to the server host key<br/>(OpenSSH session binding, verify)"| q4
  q2 -->|"no"| a2["T4.2<br/>sign something that is not an SSH login"]:::atk
  q2 -->|"yes"| q3
  q3 -->|"no"| a3["T4.3<br/>prompt shows less than what is signed"]:::atk
  q3 -->|"yes"| ok1(["OK"]):::ok
  q4 -->|"no, silently accepted"| a4["T4.4<br/>downgrade: omit the binding"]:::atk
  q4 -->|"yes"| ok2(["OK"]):::ok
```

Rules and session approval:

```mermaid
flowchart LR
  classDef q fill:#e8f0fe,stroke:#3b6fd4,color:#12305f
  classDef atk fill:#fde2e2,stroke:#c0392b,color:#7b1e1e
  classDef ok fill:#dff5e3,stroke:#2e8b57,color:#14532d
  classDef note fill:#fff4d6,stroke:#b7791f,color:#5c3d00
  q5("Where are the rules that choose between<br/>auto-approve, Face ID and deny?"):::q
  q6("What is a session approval bound to?<br/>('approve for N minutes')"):::q
  q7("Does it survive the Mac locking or sleeping,<br/>or the phone leaving the network?"):::q
  q8("Can the user see and revoke<br/>active approvals?"):::q
  q5 -->|"on the Mac"| a5["T4.5<br/>edit the rules"]:::atk
  q5 -->|"on the iPhone, editable from the Mac"| a6["T4.6<br/>send a rule change"]:::atk
  q5 -->|"on the iPhone, changed only there<br/>with Face ID"| ok3(["OK"]):::ok
  q6 -->|"nothing: any request in the window passes"| a7["T4.7<br/>ride the approval window"]:::atk
  q6 -->|"a host label"| n1["Combine with T4.1"]:::note
  q6 -->|"a specific host key<br/>and a request count"| n2["Better. Test the limits."]:::note
  q7 -->|"yes"| a8["T4.8<br/>use the window while the user is away"]:::atk
  q7 -->|"no"| ok4(["OK"]):::ok
  q8 -->|"no"| n3["Report as a usability finding"]:::note
  q8 -->|"yes"| ok5(["OK"]):::ok
```

Rate limits, prompt and errors:

```mermaid
flowchart LR
  classDef q fill:#e8f0fe,stroke:#3b6fd4,color:#12305f
  classDef atk fill:#fde2e2,stroke:#c0392b,color:#7b1e1e
  classDef ok fill:#dff5e3,stroke:#2e8b57,color:#14532d
  classDef note fill:#fff4d6,stroke:#b7791f,color:#5c3d00
  q9("Where are requests counted?"):::q
  q10("What happens at the limit?"):::q
  q11("Do denied and failed<br/>requests count?"):::q
  q12("Does the prompt state the host, the user name<br/>and the Mac it came from?"):::q
  q13("Can two prompts be queued?"):::q
  q14("Result on timeout, cancel,<br/>or app going to background?"):::q
  q15("Result on an internal error?<br/>(parse failure, missing rule, unknown host)"):::q
  q9 -->|"on the Mac"| a9["T4.9<br/>bypass the counter"]:::atk
  q9 -->|"on the iPhone"| q10
  q10 -->|"denied for everyone"| n4["See T8.1"]:::note
  q10 -->|"falls back to Face ID prompts"| a10["T4.10<br/>prompt flooding"]:::atk
  q11 -->|"no"| n5["Unlimited probing. Report."]:::note
  q11 -->|"yes"| ok6(["OK"]):::ok
  q12 -->|"no"| n6["The user cannot judge the request. Report."]:::note
  q12 -->|"yes"| q13
  q13 -->|"yes"| a11["T4.11<br/>race two requests"]:::atk
  q13 -->|"no"| ok7(["OK"]):::ok
  q14 -->|"anything other than deny"| a12["T4.12<br/>fail-open on the prompt"]:::atk
  q14 -->|"deny"| ok8(["OK"]):::ok
  q15 -->|"anything other than deny"| a13["T4.13<br/>fail-open on error"]:::atk
  q15 -->|"deny"| ok9(["OK"]):::ok
```

| ID | STRIDE | Attack |
|---|---|---|
| T4.1 | S, E | As AT1, send a request labelled "github.com" whose data to sign is an authentication for another server. The agent protocol does not carry the host name, so the label is an unverified claim. **[verify]** |
| T4.2 | E | Get other data signed with the SSH key: a git commit or file signature (out of scope, must be refused), or arbitrary bytes. |
| T4.3 | S | Find a field that is signed but not displayed, and change it. |
| T4.4 | E | Send the request without the host key binding and check whether it is still signed. |
| T4.5 | E | As AT1, edit the rules stored on the Mac. |
| T4.6 | E | As AT1, send a rule change over the channel. |
| T4.7 | E | As AT1, wait for the user to approve one request, then sign at will until the window closes. |
| T4.8 | E | Use an open approval window after the Mac locked, slept, or the phone left. |
| T4.9 | E | As AT1, reset or skip the counter kept on the Mac. |
| T4.10 | E | Flood the phone with prompts until the user approves one. |
| T4.11 | E | Send a malicious request at the same moment as a legitimate one, so that one approval covers both. |
| T4.12 | E | Let the prompt time out, cancel it, or background the app, and check that the answer is deny. |
| T4.13 | E | Trigger each internal error and check that the answer is deny. The brief requires fail-secure. |

### T5. Key storage on the iPhone

The SSH key in the Secure Enclave:

```mermaid
flowchart LR
  classDef q fill:#e8f0fe,stroke:#3b6fd4,color:#12305f
  classDef atk fill:#fde2e2,stroke:#c0392b,color:#7b1e1e
  classDef ok fill:#dff5e3,stroke:#2e8b57,color:#14532d
  classDef note fill:#fff4d6,stroke:#b7791f,color:#5c3d00
  q1("How is the Secure Enclave<br/>key protected?"):::q
  q2("Then how does<br/>zero-touch work?"):::q
  q3("Is the context dropped on lock, on background,<br/>on leaving the network? After how long?"):::q
  q1 -->|"biometry in the key's access control,<br/>checked by the enclave on every use"| q2
  q1 -->|"no biometry on the key: the app checks<br/>Face ID, then calls sign"| a3["T5.3<br/>software gate"]:::atk
  q2 -->|"it does not: Face ID every time"| n1["Secure, but the UX goal is not met.<br/>Report the contradiction."]:::note
  q2 -->|"an authenticated context is kept and reused"| q3
  q2 -->|"a second key without biometry<br/>for auto-approved hosts"| a2["T5.2<br/>get the weak key used"]:::atk
  q3 -->|"not on all of them, or after a long time"| a1["T5.1<br/>sign after the approval conditions are gone"]:::atk
  q3 -->|"yes, quickly"| ok1(["OK"]):::ok
```

Lock state and biometry changes:

```mermaid
flowchart LR
  classDef q fill:#e8f0fe,stroke:#3b6fd4,color:#12305f
  classDef atk fill:#fde2e2,stroke:#c0392b,color:#7b1e1e
  classDef ok fill:#dff5e3,stroke:#2e8b57,color:#14532d
  classDef note fill:#fff4d6,stroke:#b7791f,color:#5c3d00
  q4("Does Face ID fall back<br/>to the device passcode?"):::q
  q5("After a face is added,<br/>is the key still usable?"):::q
  q6("When is the key usable<br/>relative to the lock state?"):::q
  q4 -->|"yes"| a4["T5.4<br/>sign with the passcode"]:::atk
  q4 -->|"no"| ok2(["OK"]):::ok
  q5 -->|"yes"| a5["T5.5<br/>enrol a new face"]:::atk
  q5 -->|"no, the key is invalidated"| ok3(["OK"]):::ok
  q6 -->|"only while unlocked"| n2["Secure, but no signing from a locked phone.<br/>Check what the app does then (T8)."]:::note
  q6 -->|"after first unlock"| a6["T5.6<br/>sign from a locked phone"]:::atk
  q6 -->|"always"| n3["Finding"]:::note
```

Other stored data:

```mermaid
flowchart LR
  classDef q fill:#e8f0fe,stroke:#3b6fd4,color:#12305f
  classDef atk fill:#fde2e2,stroke:#c0392b,color:#7b1e1e
  classDef ok fill:#dff5e3,stroke:#2e8b57,color:#14532d
  classDef note fill:#fff4d6,stroke:#b7791f,color:#5c3d00
  q7("Where are the other secrets?<br/>(channel keys, pairing record, rules, log key)"):::q
  q8("File protection of the log<br/>and any database?"):::q
  q9("After reinstalling the app, are old<br/>keychain items reused or replaced?"):::q
  q7 -->|"UserDefaults or plain files"| a7["T5.7<br/>read them from a backup"]:::atk
  q7 -->|"keychain, without 'this device only'"| a7
  q7 -->|"keychain, this device only,<br/>suitable lock class"| ok4(["OK"]):::ok
  q8 -->|"less than complete protection"| a8["T5.8<br/>read while the phone is locked"]:::atk
  q8 -->|"complete protection"| ok5(["OK"]):::ok
  q9 -->|"reused without asking,<br/>or lost without recovery"| a9["T5.9<br/>leftover state"]:::atk
  q9 -->|"explicit and documented"| ok6(["OK"]):::ok
```

| ID | STRIDE | Attack |
|---|---|---|
| T5.1 | E | Get a signature after the conditions that justified the approval are gone: phone locked, app in background, device off the network. |
| T5.2 | E | Get the key without biometry used for a host that should need the strong one. Combine with T4.1. |
| T5.3 | E | The Face ID check is an `if` in the app, not a property of the key. Same class of flaw as the vault design rejected in journal entry P-002. Look for any path that reaches the sign call without passing the check. |
| T5.4 | E | As AT4 knowing the passcode, sign without the owner's face. |
| T5.5 | E | As AT4 with the passcode, enrol a new face, then sign. Expected with `biometryCurrentSet`: the key is invalidated. |
| T5.6 | E | As AT4, or AT3 if Bluetooth is built, obtain signatures from a locked, stolen or pocketed phone. |
| T5.7 | I | Read the secrets from a device backup or after migration to another device. |
| T5.8 | I | Read the log or database while the phone is locked. |
| T5.9 | S, D | Reinstall the app (it expires every 7 days on a free account). Look for a stale pairing that is still accepted, or a key that is lost with no recovery. |

### T6. Mac agent

Socket and identity key:

```mermaid
flowchart LR
  classDef q fill:#e8f0fe,stroke:#3b6fd4,color:#12305f
  classDef atk fill:#fde2e2,stroke:#c0392b,color:#7b1e1e
  classDef ok fill:#dff5e3,stroke:#2e8b57,color:#14532d
  classDef note fill:#fff4d6,stroke:#b7791f,color:#5c3d00
  q1("Where is the agent socket<br/>and with what permissions?"):::q
  q2("Does the agent check which<br/>process is connecting?"):::q
  q3("Where is the Mac<br/>identity key (AS3)?"):::q
  q4("Which processes may use it<br/>without a prompt?"):::q
  q1 -->|"world-accessible directory or loose mode"| a1["T6.1<br/>another local user sends requests"]:::atk
  q1 -->|"predictable path, created without checks"| a2["T6.2<br/>create the socket first"]:::atk
  q1 -->|"private directory, owner only"| ok1(["OK"]):::ok
  q2 -->|"no (normal)"| n1["All of T4 applies to AT1"]:::note
  q3 -->|"a file in the home directory"| a3["T6.3<br/>copy the identity key"]:::atk
  q3 -->|"the login keychain"| q4
  q3 -->|"the Mac's Secure Enclave,<br/>non-exportable (verify feasibility)"| n2["Cannot be copied.<br/>Can still be used on the Mac: T4."]:::note
  q4 -->|"any process of the user"| a3
  q4 -->|"only the agent"| ok2(["OK"]):::ok
```

Integrity, forwarding and fallback:

```mermaid
flowchart LR
  classDef q fill:#e8f0fe,stroke:#3b6fd4,color:#12305f
  classDef atk fill:#fde2e2,stroke:#c0392b,color:#7b1e1e
  classDef ok fill:#dff5e3,stroke:#2e8b57,color:#14532d
  classDef note fill:#fff4d6,stroke:#b7791f,color:#5c3d00
  q5("Can the user's own processes replace<br/>the agent binary or its configuration?"):::q
  q6("Is SSH_AUTH_SOCK the only thing<br/>pointing ssh at our agent?"):::q
  q7("Does the agent know a request came<br/>through a forwarded connection? (verify)"):::q
  q8("What does the agent write<br/>to disk or to the console?"):::q
  q9("What does the agent do when<br/>the iPhone is unreachable?"):::q
  q5 -->|"yes"| a4["T6.4<br/>swap the agent"]:::atk
  q5 -->|"no"| ok3(["OK"]):::ok
  q6 -->|"yes"| a5["T6.5<br/>fake agent in front of the real one"]:::atk
  q7 -->|"no"| a6["T6.6<br/>abuse agent forwarding"]:::atk
  q7 -->|"yes, and it refuses or prompts"| ok4(["OK"]):::ok
  q8 -->|"host names, user names, nonces, keys"| a7["T6.7<br/>read the agent's logs"]:::atk
  q8 -->|"nothing sensitive"| ok5(["OK"]):::ok
  q9 -->|"falls back to a key on disk"| a8["T6.8<br/>force the fallback"]:::atk
  q9 -->|"fails"| ok6(["OK. See T8 for what<br/>the user does next."]):::ok
```

| ID | STRIDE | Attack |
|---|---|---|
| T6.1 | E | Send requests to the socket from another local user account. |
| T6.2 | S | Create the socket path before the agent does and impersonate the agent. |
| T6.3 | S | As AT1, copy the identity key. Then act as the Mac from any device on the network. |
| T6.4 | T | Swap the agent binary or its configuration. Record what the iPhone can and cannot detect. |
| T6.5 | S | As AT1, repoint `SSH_AUTH_SOCK` to a fake agent that relays to the real one and alters or records requests. |
| T6.6 | E | As AT6, with `ssh -A` in use, request signatures for other hosts while the user is connected. |
| T6.7 | I | Read what the agent logged: host names, user names, nonces, keys. |
| T6.8 | E | Make the iPhone unreachable, then steal the fallback key from disk. If a fallback exists, the whole model is void. |

### T7. Decision log

```mermaid
flowchart LR
  classDef q fill:#e8f0fe,stroke:#3b6fd4,color:#12305f
  classDef atk fill:#fde2e2,stroke:#c0392b,color:#7b1e1e
  classDef ok fill:#dff5e3,stroke:#2e8b57,color:#14532d
  classDef note fill:#fff4d6,stroke:#b7791f,color:#5c3d00
  q1("Which key signs<br/>the log entries?"):::q
  q2("Is it the SSH key itself?"):::q
  q3("Is the head of the chain anchored<br/>anywhere outside the iPhone?"):::q
  q4("Are denied and failed<br/>requests logged?"):::q
  q5("Is the entry written before<br/>the signature is released?"):::q
  q6("What if the log cannot be written?<br/>(disk full, corrupted chain)"):::q
  q7("Does the entry record a hash<br/>of what was actually signed?"):::q
  q8("Who can read the log, and<br/>does it leave the device?"):::q
  q1 -->|"a software key held by the app"| a1["T7.1<br/>rewrite history"]:::atk
  q1 -->|"a Secure Enclave key"| q2
  q2 -->|"yes"| a2["T7.2<br/>cross-use of one key"]:::atk
  q2 -->|"no, a dedicated key"| ok1(["OK"]):::ok
  q3 -->|"no"| a3["T7.3<br/>truncate the log"]:::atk
  q3 -->|"yes"| ok2(["OK"]):::ok
  q4 -->|"no, only approvals"| a4["T7.4<br/>probing leaves no trace"]:::atk
  q4 -->|"yes"| ok3(["OK"]):::ok
  q5 -->|"no, after"| a5["T7.5<br/>signature without a record"]:::atk
  q5 -->|"yes"| ok4(["OK"]):::ok
  q6 -->|"signing continues"| a6["T7.6<br/>break the log, then act"]:::atk
  q6 -->|"signing stops"| ok5(["OK"]):::ok
  q7 -->|"no, only the label"| n1["With T4.1, the log says 'github.com'<br/>for a signature used elsewhere. Report."]:::note
  q7 -->|"yes"| ok6(["OK"]):::ok
  q8 -->|"always try"| a7["T7.7<br/>metadata in the log"]:::atk
```

| ID | STRIDE | Attack |
|---|---|---|
| T7.1 | T, R | With control of the app's storage, rewrite entries and re-sign them. |
| T7.2 | E | Craft a log entry that doubles as a valid SSH signature, or the reverse. Keys should have one purpose. |
| T7.3 | R | Delete the last N entries. A hash chain detects edits in the middle, not truncation. |
| T7.4 | R | Send requests that get denied and check that nothing is recorded. |
| T7.5 | R | Interrupt between signature and log write (kill the app, drop the link). |
| T7.6 | R | Fill or corrupt the log, then act unrecorded. |
| T7.7 | I | List what the log reveals. Host names and timestamps are personal and infrastructure data (MASVS PRIVACY). |

### T8. Availability and recovery

```mermaid
flowchart LR
  classDef q fill:#e8f0fe,stroke:#3b6fd4,color:#12305f
  classDef atk fill:#fde2e2,stroke:#c0392b,color:#7b1e1e
  classDef ok fill:#dff5e3,stroke:#2e8b57,color:#14532d
  classDef note fill:#fff4d6,stroke:#b7791f,color:#5c3d00
  s1("Flood of sign requests"):::q
  s2("Transport blocked"):::q
  s3("Clock changed on one device"):::q
  q1("Phone lost, broken, reset, or app expired:<br/>is there a recovery path?"):::q
  q2("Can a lost phone be revoked<br/>from the Mac alone?"):::q
  s4("Battery low, Wi-Fi off,<br/>Low Power Mode, force-quit app"):::q
  s1 -->|"requests get denied"| a1["T8.1<br/>lock out the legitimate user"]:::atk
  s1 -->|"prompts appear instead"| n1["See T4.10"]:::note
  s2 -->|"always try"| a2["T8.2<br/>block the transport"]:::atk
  a2 -->|"then watch what the user is offered"| n2["Any bypass is a finding: T6.8"]:::note
  s3 -->|"always try"| a3["T8.3<br/>clock skew"]:::atk
  q1 -->|"no"| n3["Availability finding:<br/>locked out of every server"]:::note
  q1 -->|"yes"| n4["Attack the recovery path. It is a second<br/>way in and usually the weaker one."]:::note
  q2 -->|"yes"| n5["Who else can trigger it? AT1 can."]:::note
  q2 -->|"no"| n6["A lost phone stays trusted. Report."]:::note
  s4 -->|"each state"| n7["Record the behaviour. Any state where the<br/>system relaxes a check to help is a finding."]:::note
```

| ID | STRIDE | Attack |
|---|---|---|
| T8.1 | D | Trigger the rate limit so that the legitimate user is locked out. |
| T8.2 | D | Hold connections, flood the listener, or push a device off the Wi-Fi. Check whether the user can still work. |
| T8.3 | D | Change the time on one device. Check whether all requests are rejected and whether the error is understandable. |

### T9. Platform hygiene (MASVS checklist items)

A checklist, not a tree: run every line.

| ID | STRIDE | Area | Check |
|---|---|---|---|
| T9.1 | I | Console and system logs | Run a full session with Console.app open. Search for keys, nonces, hosts. |
| T9.2 | I | App switcher snapshot | Background the app on a sensitive screen. Is the preview masked? |
| T9.3 | I | Pasteboard | Is anything copied (fingerprints, public keys)? Local only, with expiry? |
| T9.4 | I | Screenshots and recording | Is the pairing QR or an approval screen capturable while a secret is shown? |
| T9.5 | | Permissions | Does the app request more than local network, camera (QR) and Face ID? When? |
| T9.6 | E | URL schemes | Can another app open SentryKey straight into an approval or a pairing? |
| T9.7 | E | Debug leftovers | Test hosts, bypass flags, verbose modes in the release build. |
| T9.8 | T | Dependencies | Anything beyond Apple frameworks? Does each package exist and is it the real one? |
| T9.9 | I | Secrets in the repository | Search the history, not only the current tree. |
| T9.10 | | Jailbroken or debugged device | Does the app notice? Low priority, but MASVS RESILIENCE asks the question. |

## 4. State matrix

Run the same `ssh` command in each combination and record what happened. The "secure outcome" column is our proposal. The team has not decided these yet, and an undecided cell is itself a J1 finding.

| # | iPhone state | Mac state | Secure outcome |
|---|---|---|---|
| S1 | Unlocked, app in foreground | Unlocked | Per policy |
| S2 | Unlocked, app in background | Unlocked | Per policy |
| S3 | Locked, app in background | Unlocked | Deny or notify. Never sign silently unless the team has accepted T5.6. |
| S4 | Locked, never unlocked since reboot | Unlocked | Deny |
| S5 | App force-quit | Unlocked | Fail, with a clear message |
| S6 | Unreachable: other network or Wi-Fi off | Unlocked | Fail. No fallback key. |
| S7 | Reachable | Locked or screensaver | Deny auto-approval |
| S8 | Reachable | Asleep, then woken by a scheduled job | Deny auto-approval |
| S9 | Reachable, session approval active | User switched to another account | Deny |
| S10 | Two paired Macs reachable | Both sending | Each request attributed to the right Mac |
| S11 | Any | Agent restarted mid-session | New handshake, old session rejected |
| S12 | App restarted mid-session | Any | New handshake, counters not reset under an old key |
| S13 | Clock off by 10 minutes | Any | Reject, with a clear message |
| S14 | Face enrolment changed | Any | Key invalidated, re-pairing required |
| S15 | App reinstalled after expiry | Any | Explicit re-pairing or documented key survival |

S2 to S4 over the local network: the app may simply be unreachable (section 2.5). If so, record that, and record what the user is told.

## 5. From tree to finding

The brief's loop is specify, generate, review, test, attack. A finding at the attack step sends the function back to the specification step.

Before J3 (no code): walk each tree as a design review. Every question the team cannot answer, and every branch that ends in an attack under the current design, goes into the STRIDE model for J1.

From J3: turn each red box into a test and write up the ones that succeed.

```markdown
### F-XXX · Short title

- **Tree reference:** T4.1
- **STRIDE:** S, E
- **MASVS domain:** AUTH
- **Attacker:** AT1
- **Preconditions:**
- **Steps to reproduce:**
- **Observed result:**
- **Expected result:**
- **Impact:** which asset (AS1 to AS6), and what the attacker gains
- **Suggested fix:**
- **Status:** Open / Fixed in PR # / Accepted risk, and who accepted it
```

Suggested order once code exists: T4, T5, T1, T2, T6, T3, T7, T8, T9. The first three decide whether the project's main claim holds.

## Appendix A. Bluetooth Low Energy (optional transport)

Bluetooth is an optional second transport. Read this only if the team builds it. Its attacks are T3.B1 to T3.B6, in the Bluetooth diagram of T3.

### A.1 Radio and link

- BLE uses the 2.4 GHz band, split into 40 channels. Three are advertising channels (37, 38, 39). The other 37 carry data.
- A device that wants to be found **advertises**: it broadcasts small packets on the advertising channels. A device that wants to find others **scans**.
- Once connected, the two devices hop between data channels on a schedule agreed at connection time. A sniffer has to catch the connection request to follow the hopping.
- Advertising packets are always in clear text. Anyone nearby sees them.

### A.2 Roles

Two independent pairs of roles:

| Layer | Roles | Meaning |
|---|---|---|
| GAP (connection) | Peripheral / Central | The peripheral advertises. The central scans and initiates the connection. |
| GATT (data) | Server / Client | The server holds data. The client reads and writes it. |

In practice the peripheral is usually the GATT server. In CoreBluetooth these are `CBPeripheralManager` (peripheral) and `CBCentralManager` (central).

**Design question for the team:** which side is the peripheral? It changes the background behaviour on iOS (A.5) and who can impersonate whom (T3.B1).

### A.3 GATT: how data is exchanged

- A server exposes **services**. A service contains **characteristics**. Each has a UUID.
- A characteristic is a small value with permitted operations:
  - **read**: client fetches the value.
  - **write**: client sends a value and gets an acknowledgement.
  - **write without response**: same, without acknowledgement.
  - **notify** / **indicate**: server pushes a new value to subscribed clients. Indicate is acknowledged.
- Each operation carries a limited number of bytes: the negotiated MTU minus 3 bytes of header. The default MTU is 23, so 20 bytes of payload. Larger values are negotiated per connection. In CoreBluetooth, ask `maximumWriteValueLength(for:)` rather than assuming a number.
- A signature request does not fit in one packet. The app must **fragment and reassemble** messages. That reassembly code is hand-written parsing of attacker-controlled input, which makes it a prime target (T3.9).

### A.4 Security built into BLE, and why we do not rely on it

BLE has its own encryption, set up by **pairing**:

| Pairing method | Protection against a man in the middle |
|---|---|
| Just Works | None |
| Passkey entry | Yes |
| Numeric comparison | Yes |
| Out of band | Depends on the other channel |

- Pairing produces a long-term key. Storing it for later is called **bonding**.
- "LE Secure Connections" (Bluetooth 4.2 and later) uses ECDH P-256. The older "legacy pairing" is weak against a passive sniffer.
- On iOS the app does not choose the pairing method and cannot inspect the result. The system decides. **[verify]**
- Consequence: SentryKey treats the BLE link as an untrusted pipe, exactly like the brief treats the Wi-Fi network. All confidentiality and authentication come from the application channel (ECDH + HKDF + AES-GCM). If any security property depends on BLE link encryption being on, that is a finding.

### A.5 iOS specifics that shape the attack surface

- **No stable address.** iPhones use random addresses that rotate. CoreBluetooth never exposes the hardware address. It gives a per-device UUID that is only meaningful on that device. Identity therefore has to be cryptographic. Any check based on device name or identifier is spoofable.
- **Background execution.** The app needs the `bluetooth-peripheral` or `bluetooth-central` background mode to work with the screen off.
  - In the background, a peripheral's advertising is degraded: the local name is dropped and service UUIDs go to an "overflow area" that Apple documents as discoverable only by a device explicitly scanning for that UUID. Whether a Mac finds a backgrounded iPhone reliably is the riskiest assumption of the project. **[verify]**
  - In the background, a central must scan for specific service UUIDs and scans less often.
  - If the user force-quits the app, the system stops relaunching it for Bluetooth events. **[verify]**
- **Locked phone.** Bluetooth still works. Keychain items and Secure Enclave keys may not, depending on their protection class (tree T5).
- **Permissions.** Both apps need the Bluetooth usage description, and the Mac agent needs the user's Bluetooth consent. How this works for a command-line agent is unconfirmed. **[verify]**

### A.6 RSSI and proximity

- RSSI is the received signal strength, in dBm. Closer to zero means stronger.
- It is not a distance. It varies with body position, walls, pockets and antenna orientation, by tens of dB.
- An attacker can raise it with an amplifier or a directional antenna, and lower it with shielding.
- A **relay** defeats any proximity check based on "we can talk, so we are close". The relay forwards radio traffic unchanged, so encryption and signatures still verify. Cryptography proves *who*, not *where*.
- Real distance bounding needs time-of-flight hardware such as ultra-wideband. Whether that is usable between an iPhone 14 Pro and our Mac has not been checked. **[verify]**

### A.7 Tools

| Tool | Use |
|---|---|
| nRF Connect (iOS / Android) | Browse advertisements, connect, read and write characteristics by hand. First tool to reach for. |
| PacketLogger (Xcode additional tools) | Capture the Mac's own Bluetooth traffic at the host level. |
| LightBlue | Simulate a peripheral from a phone or Mac: quick fake SentryKey device. |
| nRF52840 dongle + Wireshark | Sniff traffic between two other devices. Needed for passive capture and replay tests. |
| A second Mac or phone running our own code | The simplest fake agent or fake iPhone. Often enough, and no extra hardware. |
