# iOS UI research

Before writing the iPhone screens, we studied how top-grossing iOS apps design the same moments: scanning a code to link a device, approving a request from another device, and confirming success. Source: the [Appllama](https://appllama.io) library of real app screens, on 2026-11-23. Screen IDs are given so the team can open each one (`app_id/screen_id`). The images themselves are not in the repository.

## References

| Moment | App | Screen | What we took |
|---|---|---|---|
| Approve a request | Xverse | `1552272513/oth_v6xnr` Connection Request | The origin at the top, facts in grouped rows, Deny and Accept side by side at equal width |
| Approve a request | SafePal | `1548297139/oth_r8vnm` Sign Message | Counter-example: the user types what to sign. SentryKey must show what it verified, never ask the user to fill it in |
| Introduce the app | X | `333903271/onb_2upix` Passkey Setup | Large left-aligned title, three icon rows with one promise each, primary button pinned at the bottom |
| Explain pairing | Dashlane | `517914548/oth_gnlz8` Add 2FA Token | Icon tile, steps in a card, one primary Scan QR Code button |
| Confirm success | Dashlane | `517914548/oth_ouzfe` 2FA Setup Success | Icon tile, large title, one sentence on what happens next, one button |
| Scan a QR code | Zengo | `1440147115/oth_onyc2` WalletConnect QR Scanner | Dark full-screen camera, title and Cancel at the top |
| Security key list | Keeper | `287170072/oth_vykxu` Security Keys | Empty state with an explanation instead of a blank list |

## Decisions

- **Native controls only.** Form, List, LabeledContent, ShareLink and VisionKit's `DataScannerViewController`. They follow Dynamic Type, dark mode and VoiceOver without extra work, and every teammate can explain them at the oral.
- **The approval sheet cannot be swiped away.** Swiping would leave the request hanging until the Mac times out. The user picks Deny or Approve, or the request expires on screen (30 seconds).
- **Approve carries the Face ID symbol**, so the user knows what happens next. Deny is the bordered button and is on the left, as in the Xverse reference.
- **A first-time server is marked "New server" in orange**, with its fingerprint and a sentence asking the user to compare it with the published one. The name field is optional, and names are checked for invisible and bidi characters (`DisplayText`).
- **Pairing is a one-way door.** Back works from Pairing to Welcome. Once paired, the app replaces onboarding with Home and there is no way back.
- **The app switcher snapshot is covered** by a plain screen with the app symbol, so fingerprints and server names do not leak there.
