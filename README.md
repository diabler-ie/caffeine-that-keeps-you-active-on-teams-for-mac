# caffeine-that-keeps-you-active-on-teams-for-mac

A macOS menu bar app that does what [Caffeine](http://lightheadsw.com/caffeine/) does — hold a power assertion so your display and Mac stay awake — **AND** also moves your cursor 1 pixel every 30 seconds, because that's the part Caffeine doesn't do, and that's why Caffeine alone doesn't keep Microsoft Teams from flipping you to "Away".

The full name is the name. It is searchable. If you found this repo by Googling "caffeine doesn't work with teams mac" or "teams keeps marking me away mac", congratulations, you are the target audience.

## Why this exists

Microsoft Teams (and Slack, and a few others) decide you're "Away" based on macOS's idle timer. The macOS idle timer ticks up unless there's HID input — a real keypress or a real mouse move. A power assertion (which is what `caffeinate`, Caffeine.app, Amphetamine, etc. all produce) keeps the *system* from going to sleep, but it does not reset the HID idle timer. Teams doesn't care about your power assertions. It cares about whether your fingers have moved in the last five minutes.

So you have three options:

1. Twitch in your seat every five minutes.
2. Run a generic mouse jiggler 24/7 (annoying when you're actually at the keyboard reading something).
3. This thing — which gates the jiggle on a deliberate user action (clicking the menu bar icon), and combines it with a power assertion so you don't need a second app for the keep-awake part.

## What it does

- Lives in the menu bar as a coffee cup icon.
- **Left-click** the icon: toggle on/off (indefinite).
- **Right-click** the icon: menu with timed activation (5min / 15min / 30min / 1hr / 2hr / 5hr / indefinite), "Activate at launch" toggle, About, Quit.
- When active:
  - Holds an `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep, …)` — same mechanism Caffeine uses.
  - Synthesizes two `CGEvent.mouseMoved` events every 30s: +1px right, then −1px back. Invisible to the eye, sufficient to reset the HID idle timer.
- When inactive: releases the assertion, stops jiggling.

## How it works

```
┌──────────────────────────┐
│       LaunchAgent        │  launchd starts the app at login.
│                          │  KeepAlive only on non-zero exit, so
│                          │  "Quit" from the menu actually quits.
└────────────┬─────────────┘
             │
┌────────────▼─────────────┐
│   NSStatusItem menu bar  │  user clicks → toggles `active` flag
│   (cup.and.saucer icon)  │
└────────────┬─────────────┘
             │  when active:
   ┌─────────┴──────────┐
   │                    │
┌──▼──────────────┐  ┌──▼──────────────────────┐
│ IOPMAssertion   │  │ DispatchSourceTimer 30s │
│ (display sleep) │  │      ↓                  │
│                 │  │  jiggleOnce()           │
│                 │  │      ↓                  │
│                 │  │  CGEvent .mouseMoved    │
│                 │  │  +1px right / −1px back │
└─────────────────┘  └────────┬────────────────┘
                              │
                     ┌────────▼──────────┐
                     │   IOHIDSystem     │
                     │  idle timer reset │
                     │  Teams thinks you │
                     │  are still alive  │
                     └───────────────────┘
```

## Install

Requires Xcode command line tools (`swiftc`) and a macOS account you can grant Accessibility to.

```bash
git clone <this repo> ~/src/caffeine-that-keeps-you-active-on-teams-for-mac
cd ~/src/caffeine-that-keeps-you-active-on-teams-for-mac
./install.sh
```

`install.sh`:
1. Creates the app bundle at `~/Applications/Caffeine That Keeps You Active On Teams For Mac.app`.
2. Compiles the binary (ad-hoc signed).
3. Installs the LaunchAgent at `~/Library/LaunchAgents/com.kevin.caffeine-that-keeps-you-active-on-teams-for-mac.plist`.
4. `launchctl load`s it.

Then you have to **grant Accessibility** — System Settings → Privacy & Security → Accessibility → add the app bundle. Kick the process so launchd respawns it under the fresh grant:

```bash
pkill -f 'caffeine-that-keeps-you-active-on-teams-for-mac'
```

Confirm it's working:

```bash
tail -f ~/Library/Logs/caffeine-that-keeps-you-active-on-teams-for-mac.log
```

While toggled on, you want one `jiggle … moved=true` line every 30 seconds.

## The TCC gotcha

Symptom: `moved=false` in the log while the app is toggled on. The power assertion still works, but Teams flips you to Away because the cursor isn't actually moving.

Cause: the binary is ad-hoc signed, and macOS pins Accessibility grants to the binary's `cdhash`. Every rebuild changes the cdhash, orphaning the grant. The TCC row still exists and System Settings still shows it enabled — but `CGEvent.post()` silently no-ops.

Fix: in System Settings → Privacy & Security → Accessibility, remove the app and re-add it, then `pkill -f 'caffeine-that-keeps-you-active-on-teams-for-mac'` so launchd respawns it under the fresh grant. `build.sh` prints the new cdhash after every rebuild as a reminder.

Skip the dance permanently by signing with a Developer ID ($99/yr). Or disable SIP and edit `TCC.db` directly — not recommended.

## Files

| File | Purpose |
| --- | --- |
| `caffeine-that-keeps-you-active-on-teams-for-mac.swift` | The whole program. NSApplication + NSStatusItem menu bar + IOPMAssertion + CGEvent jiggle + logging. |
| `build.sh` | Compile, copy binary into app bundle, ad-hoc resign, print TCC reminder. |
| `install.sh` | One-shot setup: app bundle + build + LaunchAgent + load. |
| `Info.plist` | App bundle metadata. `LSUIElement=true` so there's no dock icon. |
| `LaunchAgent.plist` | launchd spec with `__HOME__` placeholder; `install.sh` substitutes `$HOME`. |

## Tuning

Defaults in the swift file:

```swift
let cycleSeconds: TimeInterval = 30   // between jiggles
let delta: CGFloat = 1                // pixels per move
let holdMs: UInt32 = 150              // ms between the two moves
```

1 pixel is enough for the HID event system to reset the idle timer. Bigger deltas are useful for seeing the jiggle happen during debugging.

`Activate at launch` is on by default — flip it in the menu if you'd rather start each session toggled off.

## Debugging

The log at `~/Library/Logs/caffeine-that-keeps-you-active-on-teams-for-mac.log` shows the lifecycle:

```
10:08:03 === Caffeine That Keeps You Active On Teams For Mac started PID=12345 ===
10:08:03 assertion acquired id=1234567
10:08:03 activated indefinitely
10:08:33 jiggle start=(595,881) mid=(596,881) end=(595,881) moved=true
10:09:03 jiggle start=(595,881) mid=(596,881) end=(595,881) moved=true
…
10:14:03 deactivated
10:14:03 assertion released id=1234567
```

- `moved=true` — cursor position actually changed. The jiggle is doing its job.
- `moved=false` with the app toggled on — stale TCC grant, see above.
- `assertion failed result=<n>` — `IOPMAssertionCreateWithName` failed. Rare; the macOS power management daemon was unhappy.

Sanity-check the assertion is real:

```bash
pmset -g assertions | grep -i caffeine
```

While the app is on, you should see a `PreventUserIdleDisplaySleep` line owned by the binary, reason "Caffeine That Keeps You Active On Teams For Mac is keeping the display awake".

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/com.kevin.caffeine-that-keeps-you-active-on-teams-for-mac.plist
rm ~/Library/LaunchAgents/com.kevin.caffeine-that-keeps-you-active-on-teams-for-mac.plist
pkill -f 'caffeine-that-keeps-you-active-on-teams-for-mac' 2>/dev/null
rm -rf "$HOME/Applications/Caffeine That Keeps You Active On Teams For Mac.app"
rm -f ~/Library/Logs/caffeine-that-keeps-you-active-on-teams-for-mac.{log,err}
defaults delete com.kevin.caffeine-that-keeps-you-active-on-teams-for-mac 2>/dev/null
# remove entry from System Settings → Privacy & Security → Accessibility
```

## License

MIT.
