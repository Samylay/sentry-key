# SentryKey iOS app

The iPhone side of SentryKey, in SwiftUI with Apple's own controls (Form, List, ShareLink, VisionKit's QR scanner). Screen layouts were studied on real apps first: see [docs/UI_RESEARCH.md](../docs/UI_RESEARCH.md).

**Status:** builds with Xcode 27.2 for iOS (Debug and Release) with no errors or warnings in our code, and launches in the simulator up to the pairing screen. It has not been run on a device yet, so nothing past pairing (Secure Enclave key, Face ID, the demo request) has been exercised.

## What works today (once built)

1. Welcome, then pairing: scan a QR code, which creates the SSH key in the Secure Enclave.
2. Home: the key's fingerprint, and Share / Copy of the public key line for GitHub or `authorized_keys`.
3. Settings › **Show a demo request** (Debug builds): the phone plays the server and `ssh`, then runs the real path: login checks, server signature check (`HostVerifier`), the approval sheet, Face ID, and a Secure Enclave signature.
4. Recent requests list, and named servers (swipe to delete).
5. A local notification when a request arrives while the app is not on screen. It names neither the server nor the account, since it shows on the lock screen. To try it: Settings › **Show a demo request in 5 seconds**, then leave the app.

## Not done yet (J3)

- **Pairing cannot finish yet.** The app reads a real pairing code, creates its two Secure Enclave keys and prepares its request, then waits for the Mac's confirmation. Nothing carries those two messages until the Bluetooth link exists. In Debug builds, **Pair without a Mac (demo)** on the pairing screen creates the SSH key alone, so the demo request can still be tried.
- **BLE channel.** `AppModel.receive(_:)` takes the Mac's `PhoneRequest` and answers with a `PhoneResponse` carrying the same request identifier, but nothing calls it except the demo, and `sendResponse` goes nowhere. The phone's side of the secure channel exists in the shared package (`PhoneChannelSession`) and is not used by the app yet.
- **Audit log** with a hash chain (the history is in memory only).

## Open and build

Open `SentryKey-iOS/SentryKey.xcodeproj` in Xcode 16 or later. The project is committed, so there is nothing to create.

- The `SentryKey` folder is a synchronized group: a file added to the folder is part of the target without touching the project.
- The local package `../SentryKeyProtocol` is already linked, the minimum deployment is iOS 17.0, and the camera and Face ID usage descriptions are set in the build settings.
- The project file was written by hand and validated with `xcodebuild`, not created from Xcode's template. It has no asset catalog, so the app has no icon yet.

**On the simulator** (no signing needed): pick an iPhone simulator and Run. Only the Welcome and pairing screens work there. The QR scanner is not supported on a simulator, so the Scan button stays disabled, and there is no Secure Enclave to create the key.

From the command line, at the repository root:

```bash
xcodebuild -project SentryKey-iOS/SentryKey.xcodeproj -scheme SentryKey \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

If `xcode-select` still points at the Command Line Tools and you cannot change it, set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` instead.

**On the iPhone 14 Pro:** in the target's Signing & Capabilities, choose your Personal Team and replace the placeholder bundle identifier `com.example.SentryKey` with one of your own. Do not commit that change.

## Try it on the iPhone

1. On the pairing screen, tap **Pair without a Mac (demo)** (Debug builds).
2. Settings › Show a demo request.
3. Check the sheet: "New server", a fingerprint, account `git`. Type a name, tap Approve, look at the phone.
4. Back on Home, the request shows as Signed. Run the demo again: it shows a new fingerprint, because each demo uses a new server key.

## Security review

Needs line-by-line human review, as CLAUDE.md requires:
- `Security/KeyStore.swift`: Secure Enclave key, Keychain item, Face ID evaluation.
- `Security/HostVerifier.swift`: the server signature check.
- `AppModel.swift`: the order of checks in `receive(...)` and the timeout and Face ID race in `approve(...)`.
