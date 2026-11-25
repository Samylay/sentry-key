# Bluetooth wake-up test

The architecture's first open question, and the one the whole design rests on:

> Can the Mac reliably wake the backgrounded iOS app over BLE, show a local notification, then get a Face ID-gated Secure Enclave signature back?

This is the procedure to answer it on the real iPhone. It needs the iPhone 14 Pro and a Mac that can be used with it. **It has not been run: every result cell below is empty.**

If the answer is no for a state users will be in every day (phone locked in a pocket), the design changes, and it is better to know before more is built on it.

## What you need

- The iPhone 14 Pro with a **Debug** build of the app installed from Xcode.
- On the Mac, in `SentryKey-macOS/`: `swift build`.
- An SSH server to log in to, with OpenSSH 8.9 or later on the Mac. A throwaway local `sshd` is enough: see `Scripts/try-with-local-ssh.sh` for how to start one.

Write down before starting: the iOS version, the macOS version, the Mac model, and the commit tested.

## Step 0: does it work at all?

1. On the Mac: `swift run sentrykey-agent pair`. A QR code appears in the terminal.
   - macOS should ask whether the program may use Bluetooth. Note whether it asks for `sentrykey-agent` or for the terminal, or refuses outright.
2. On the iPhone: open SentryKey, Pair with your Mac, scan the code. iOS asks for Bluetooth.
3. The Mac prints "Paired" and a public key line. Install that line in the server's `authorized_keys`.
4. On the Mac: `swift run sentrykey-agent run`, then in another terminal `ssh -o IdentityAgent="<the socket it printed>" user@server`.
5. With the app open on the iPhone: the approval sheet appears, Face ID, and `ssh` logs in.

If any of these fails, stop and fix it: the rest means nothing until this works. This is also the first time any of the Bluetooth code runs.

## Step 1: does the phone answer?

`probe` sends a request the phone refuses at once without showing anything. An answer proves the app woke up, ran the handshake and read the request.

```bash
swift run sentrykey-agent probe --count 5 --interval 20 --reconnect
```

Put the phone in each state below, run the command, and note how many probes were answered and the slowest time. Then open the app, Settings › Bluetooth test log, and note in which app state the events were recorded. Clear the log between rows.

| # | State of the iPhone | Probes answered (of 5) | Slowest | App state in the log |
|---|---|---|---|---|
| 1 | App open on screen | | | |
| 2 | App in the background for 1 minute, phone unlocked | | | |
| 3 | App in the background for 30 minutes, phone unlocked | | | |
| 4 | Phone locked for 1 minute | | | |
| 5 | Phone locked for 30 minutes | | | |
| 6 | Phone locked overnight | | | |
| 7 | Phone restarted, **not** unlocked since | | | |
| 8 | Phone restarted, unlocked once, app not opened | | | |
| 9 | App closed from the app switcher (force-quit) | | | |
| 10 | Bluetooth switched off then on in Control Center, app not opened | | | |
| 11 | Airplane Mode on then off, app not opened | | | |
| 12 | Low Power Mode on, phone locked for 30 minutes | | | |
| 13 | Phone out of range for 10 minutes, then back, locked | | | |

The architecture expects rows 7, 9, 10 and 11 to fail, with the Mac reporting the phone as unreachable. Confirm that, and that row 8 works.

Without `--reconnect` the connection stays open between probes. Run rows 4 and 5 both ways: it tells whether keeping a connection open helps the app stay reachable.

## Step 2: does the notification appear, and can it be approved?

Step 1 does not show a notification. This step uses a real login.

For rows 2, 4 and 5 of the table, with `sentrykey-agent run` on the Mac:

1. Put the phone in the state.
2. Start the `ssh` login on the Mac.
3. Note whether the notification appears on the phone, and after how many seconds.
4. Tap it, approve with Face ID, and note whether `ssh` logs in before the Mac gives up (45 seconds).

| State | Notification shown | Seconds until shown | Login succeeded | Bluetooth test log shows "notification posted" in the background |
|---|---|---|---|---|
| App in the background, phone unlocked | | | | |
| Phone locked for 1 minute | | | | |
| Phone locked for 30 minutes | | | | |

Also check, on the locked phone: the notification shows no server and no user name.

## Reading the results

- **Rows 2 to 6 and 8 all answer, and step 2 succeeds:** the design holds. Record the results in `docs/ARCHITECTURE.md` under "Open questions" and close the question.
- **The phone answers but no notification appears:** the app is woken but may not be allowed to post one in that time. Look at the log: is "request received" there without "notification posted"?
- **The phone stops answering after a while in the background or locked:** iOS is no longer relaunching the app. Check that the Bluetooth test log shows "app launched" in the background state after such a gap. If it never does, state restoration is not working: the first thing to verify is that `SentryKeyApp.init` runs on a background relaunch.
- **Nothing answers once the app leaves the screen:** the user would have to open the app before every login. That is a different product, and the team should decide before going further.

Whatever the result, add a journal entry with the table filled in.
