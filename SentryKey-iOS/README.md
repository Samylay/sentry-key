# SentryKey iOS app

The iPhone side of SentryKey, in SwiftUI with Apple's own controls (Form, List, ShareLink, VisionKit's QR scanner). Screen layouts were studied on real apps first: see [docs/UI_RESEARCH.md](../docs/UI_RESEARCH.md).

**Status:** written without a Mac. Every file passes `swiftc -parse` on Linux, but nothing here has been compiled with the iOS SDK or run on a device. Expect a few compile fixes on first build.

## What works today (once built)

1. Welcome, then pairing: scan a QR code, which creates the SSH key in the Secure Enclave.
2. Home: the key's fingerprint, and Share / Copy of the public key line for GitHub or `authorized_keys`.
3. Settings › **Show a demo request** (Debug builds): the phone plays the server and `ssh`, then runs the real path: login checks, server signature check (`HostVerifier`), the approval sheet, Face ID, and a Secure Enclave signature.
4. Recent requests list, and named servers (swipe to delete).

## Not done yet (J3)

- **Pairing payload.** The QR format (Mac identity key + one-time secret) is not specified yet, so `AppModel.pair(qrPayload:)` accepts any QR code under 1 KB. Temporary: it must not ship like this.
- **BLE channel and Mac agent.** Nothing calls `AppModel.receive(...)` except the demo, and `sendResponse` goes nowhere.
- **Local notification** when a request arrives in the background (ApprovalFlow).
- **Audit log** with a hash chain (the history is in memory only).

## Create the Xcode project (once, on a Mac)

The repository holds the sources, not an `.xcodeproj`, because a project file written without Xcode could not be checked. Xcode 16 or later:

1. File › New › Project › iOS › App. Product Name `SentryKey`, Interface SwiftUI, Language Swift, Storage None. Save it in a **temporary** folder, not in the repository.
2. In Finder, move `SentryKey.xcodeproj` and `SentryKey/Assets.xcassets` from that temporary folder into this folder (`SentryKey-iOS/` and `SentryKey-iOS/SentryKey/`). Delete the rest of the temporary folder.
3. Open `SentryKey-iOS/SentryKey.xcodeproj`. The `SentryKey` group now shows this repository's files.
4. File › Add Package Dependencies › Add Local… › choose `SentryKeyProtocol/`, and add the `SentryKeyProtocol` library to the SentryKey target.
5. Target › General: Minimum Deployments iOS 17.0.
6. Target › Signing & Capabilities: your Personal Team, and a bundle identifier of your own.
7. Target › Info, add:
   - `Privacy - Camera Usage Description`: "SentryKey scans the pairing code shown by your Mac."
   - `Privacy - Face ID Usage Description`: "SentryKey asks for Face ID before each signature."
8. Build on the iPhone 14 Pro (the simulator has no Secure Enclave, so pairing fails there).
9. Commit the `.xcodeproj` (not `xcuserdata/`) so nobody repeats these steps.

## Try it on the iPhone

1. Pair with any QR code (temporary, see above).
2. Settings › Show a demo request.
3. Check the sheet: "New server", a fingerprint, account `git`. Type a name, tap Approve, look at the phone.
4. Back on Home, the request shows as Signed. Run the demo again: it shows a new fingerprint, because each demo uses a new server key.

## Security review

Needs line-by-line human review, as CLAUDE.md requires:
- `Security/KeyStore.swift`: Secure Enclave key, Keychain item, Face ID evaluation.
- `Security/HostVerifier.swift`: the server signature check.
- `AppModel.swift`: the order of checks in `receive(...)` and the timeout and Face ID race in `approve(...)`.
