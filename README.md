# LetMeTalk

Use the inline button on a wired 3.5 mm headset as a **push-to-talk key for Claude Code voice mode**, instead of
letting it open Apple Music.

LetMeTalk is a tiny macOS menu-bar app (one Swift file, no dependencies, no special permissions). It makes the
headset button arrive as a real keyboard key, Space by default. Claude Code's own voice mode, set to **tap**, does
the rest.

---

## Quick start

1. **Build, install and launch the app:**

       ./build.sh --install

   A mic icon appears in the menu bar. Turn on **Open at Login** in its menu so it's always running.

2. **Switch Claude Code's voice mode to tap.** In any Claude Code session:

       /voice tap

3. **Use it:** focus the Claude Code window, **click** the headset button once, speak, then **click** it again to
   finish.

> **Don't hold the button while you talk.** The headset mutes its own microphone while the button is down. See
> [Why hold-to-talk can't work](#why-hold-to-talk-cant-work).

---

## The logic chain

Each press travels through five layers. Knowing which layer does what explains every behavior, including the
failures.

```
 ┌──────────────────────┐   button press shorts the mic line
 │ 1. Headset (TRRS)    │──────────────────────────────────────────┐
 └──────────────────────┘                                          │
                                                                   ▼
 ┌──────────────────────────────────────────────────────────────────────────┐
 │ 2. Mac audio codec ("Headset" HID service, transport = Audio)            │
 │    detects the short → reports HID Consumer Play/Pause (page 0x0C, 0xCD) │
 │    side effect: the mic input is digital silence while the short lasts   │
 └──────────────────────────────────────────────────────────────────────────┘
                                                                   │
                                                                   ▼
 ┌──────────────────────────────────────────────────────────────────────────┐
 │ 3. HID event system   ◀── LetMeTalk sets UserKeyMapping here             │
 │    WITHOUT the app:  Play/Pause → media key → Now Playing → opens Music  │
 │    WITH the app:     Play/Pause rewritten → Keyboard Space (0x07, 0x2C)  │
 │                      real key-down, native auto-repeat, real key-up      │
 └──────────────────────────────────────────────────────────────────────────┘
                                                                   │
                                                                   ▼
 ┌──────────────────────────────────────────────────────────────────────────┐
 │ 4. Frontmost app: Terminal                                               │
 │    turns key presses into characters for the program running in it.      │
 │    Terminals never send key-UP to the program; a held key shows up only  │
 │    as a stream of repeated characters.                                   │
 └──────────────────────────────────────────────────────────────────────────┘
                                                                   │
                                                                   ▼
 ┌──────────────────────────────────────────────────────────────────────────┐
 │ 5. Claude Code voice mode                                                │
 │    /voice hold: records while the Space repeats keep coming              │
 │    /voice tap:  one Space tap starts recording, the next tap stops it    │
 └──────────────────────────────────────────────────────────────────────────┘
```

### Layer by layer

1. **Headset.** A standard 4-pole (TRRS, CTIA) headset has one wire for the microphone. The inline button works by
   shorting that mic wire to ground. There is no separate button wire.
2. **Mac audio codec.** The Mac notices the drop in mic impedance and reports it as a button press through an HID
   service named `Headset` on the `Audio` transport. Its usage is Consumer Control, which it reports as
   **Play/Pause** (usage page `0x0C`, usage `0xCD`), with separate down and up events. The mic reads **digital silence**
   for exactly as long as the short lasts.
3. **HID event system.** This is where LetMeTalk acts. By default, macOS turns Play/Pause into a media-key event,
   and with no player running, the system's Now Playing handling launches Music. LetMeTalk sets a
   `UserKeyMapping` on the `Headset` service that rewrites Play/Pause into an ordinary keyboard key. Because the
   rewrite happens inside the HID system, the media layer never sees a Play/Pause, so Music never opens. What comes
   out behaves exactly like a physical keyboard key, including macOS's own auto-repeat while it's held. This is the
   same mechanism `hidutil` and the Modifier Keys settings use.
4. **Terminal.** The key goes to whichever app is in front. A terminal forwards characters to the program inside
   it, not raw key events, so it can't report "key released". A held key looks like
   `space … space space space …`, and the release is just the stream stopping.
5. **Claude Code voice mode.** `/voice hold` treats that stream of repeats as "held" and records until it stops.
   `/voice tap` treats a single press as a toggle: press to start, press to stop.

### Why hold-to-talk can't work

Putting layers 1, 2 and 5 together: **in hold mode you hold the button, holding the button shorts the mic, and a
shorted mic records silence.** Claude Code was working correctly; it was recording zeros.

This was measured, not guessed (see [Evidence](#evidence)): speech came in at about −27 dBFS, dropped to **−120
dBFS** (exact zero) the instant the button went down, and came back the instant it was released. On screen, that
shows as an underscore that never advances during the hold, then a brief green flash at release, when audio returns
just as recording ends.

### Why tap mode works

In tap mode, each click shorts the mic for only about 100 to 250 ms. Between the two clicks the button is up, so
the mic is live and your speech is recorded normally.

**Tip:** start speaking a beat after the first click and stop a beat before the second. Anything said during a
click itself is lost.

---

## The app

### Menu

| Item | What it does |
|---|---|
| **Headset Button → <key>** | On/off. Off removes the remap and gives the button back to the system, so Music behavior returns. |
| **Choose Key…** | Opens a small window; press the key the button should become. Any single key works, including a modifier on its own (for example Right Option). |
| **Open at Login** | Registers the app with macOS Login Items through `SMAppService`. |
| **Quit LetMeTalk** | Removes the remap and quits. |

### Menu-bar icon

| Icon | Meaning |
|---|---|
| `mic.fill` (solid mic) | Active: the remap is applied to a connected headset. |
| `mic.slash` | No wired headset found. Plug it in; the remap applies automatically about a second later. |
| `mic` (outline) | Turned off from the menu. |

### What it does internally

- At launch, it finds every HID service whose transport is `Audio` and that conforms to Consumer Control (the
  headset button). It sets `UserKeyMapping` to `[{Src: 0x0C000000CD, Dst: 0x07000000xx}]`, where `xx` is the chosen
  key's HID keyboard usage (Space = `0x2C`).
- The mapping lives on the device's service, which macOS discards when the headset is unplugged. The app subscribes
  to IOKit "service appeared/disappeared" notifications and re-applies the mapping about a second after any change.
- When the app quits, or you turn it off, it sets the mapping back to an empty list.
- Settings live in `UserDefaults` (domain `app.letmetalk.LetMeTalk`): `enabled`, `keyCode`, `keyName`. The domain
  only exists after a setting has been changed from the menu.
- It uses only public APIs: `IOHIDEventSystemClientCreateSimpleClient`, `IOHIDEventSystemClientCopyServices`,
  `IOHIDServiceClientSetProperty`, `IOServiceAddMatchingNotification`, and `SMAppService`.
- It needs **no** Accessibility or Input Monitoring permission, and it never sees or records anything you type.

### Limitations

- **One key, not a combination.** The HID remap maps one usage to one usage, so ⌥Space and the like aren't possible.
- **Global.** The key goes to whichever app is in front. Click the button only when the Claude Code window is focused,
  or a space gets typed somewhere else.
- **One button.** The Mac only reported Play/Pause from the tested headset. A headset whose other buttons are wired
  for volume (`0xE9` / `0xEA`) isn't remapped; those keep their normal volume function.
- **Built-in 3.5 mm jack only.** USB and Bluetooth headsets show up as different HID services (transport `USB` or
  `Bluetooth`) and are deliberately not matched.

---

## Troubleshooting

| Symptom | Likely cause | Check or fix |
|---|---|---|
| Music opens | App not running, or the remap is missing | Check that the icon is solid. Run the `hidutil … --get` command below; it should list a mapping. Relaunch the app. |
| Underscore appears but nothing is transcribed; green flash on release | Claude Code is in **hold** mode, so the mic is muted for the whole hold | Run `/voice tap`. |
| One space typed, no recording | Voice mode is off, or it's in hold mode and you clicked | Run `/voice tap`. |
| A space appears in the wrong app | The key went to the frontmost app | Focus the Claude Code window first. |
| First or last word missing | You were speaking during a click, when the mic is shorted | Pause briefly after the first click and before the second. |
| Icon shows `mic.slash` with the headset plugged in | The headset isn't detected as a remote-capable headset (for example a 3-pole plug, or a CTIA/OMTP wiring mismatch) | Run the `hidutil list` command below. |
| Need the button back right now | | Quit the app, or run the clear command below. |

### Useful commands

```sh
# Is the app running?
pgrep -lx LetMeTalk

# Which headset services exist? (look for Product "Headset", Transport "Audio")
hidutil list | grep -i headset

# Current mapping on the headset (empty list = no remap)
hidutil property --matching '{"Product":"Headset","Transport":"Audio"}' --get UserKeyMapping

# Apply the Space remap by hand, without the app (lost on unplug or restart)
hidutil property --matching '{"Product":"Headset","Transport":"Audio"}' \
  --set '{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0xC000000CD,"HIDKeyboardModifierMappingDst":0x70000002C}]}'

# Clear it by hand
hidutil property --matching '{"Product":"Headset","Transport":"Audio"}' --set '{"UserKeyMapping":[]}'

# App settings
defaults read app.letmetalk.LetMeTalk
```

In `hidutil` output, the mapping values print in decimal: `51539607757` is `0xC000000CD` (Play/Pause), and
`30064771116` is `0x70000002C` (Space).

---

## Evidence

These measurements, taken while building the app, are the basis for the design. All of them came from short
listen-only probes on a Mac using its built-in headphone jack.

| Probe | What it showed |
|---|---|
| Raw HID + event tap, no remap | Button = HID Consumer `0xCD` value 1/0 from the `Headset` service, then media key `NX_KEYTYPE_PLAY` (16) with separate down (`0xA`) and up (`0xB`) events. Hold duration preserved; rapid clicks stay individual (no "next track"). |
| Event tap swallowing the media key | Space typed, **but Music still opened**: media handling receives the press before a session event tap can drop it. Approach rejected. |
| Synthesized Space from an event tap | One key-down with **no auto-repeat** (macOS doesn't repeat synthesized keys), so the terminal saw a single space. Approach rejected. |
| `UserKeyMapping` remap | **No** media-key events at all. Real Space down, then auto-repeat every ~83 ms after a ~500 ms delay, then up. Music stayed closed. |
| Mic level during holds | About −27 dBFS speaking before a hold, **−120 dBFS** (exact zero) for the entire hold (two holds, 4.8 s and 3.5 s), speech back immediately after release. |
| `/voice tap` | Click, speak, click: transcription works (confirmed by the user). |

---

## Notes for agents working on this repo

### Files

| File | Purpose |
|---|---|
| `LetMeTalk.swift` | The entire app: remap, device watching, key picker, menu. |
| `Info.plist` | Bundle metadata. `LSUIElement` = menu-bar only, no Dock icon. Bundle ID `app.letmetalk.LetMeTalk`. |
| `build.sh` | `swiftc` → `.app` bundle → `codesign` (hardened runtime, timestamped). `--install` copies to `/Applications` and relaunches. |
| `.githooks/` | Privacy gate (pre-commit), and a check that the remote repo is private (pre-push). |

### Build and signing

- `./build.sh` signs with the first `Developer ID Application` identity in the keychain. Override it with
  `SIGN_IDENTITY="…" ./build.sh`.
- `codesign --timestamp` contacts Apple's timestamp server. If a build hangs at the `codesign` step, it's waiting on
  that server or on a keychain access prompt on the screen. Check for a dialog before killing it.
- Signing with a stable identity keeps the app's identity constant across rebuilds, which keeps Login Items stable.

### Verifying a change

1. `./build.sh --install`
2. `pgrep -lx LetMeTalk`, then the `hidutil … --get` command above. The `Dst` value should match the chosen key.
3. Ask the human to: click the button in a text field (one space per click, no Music), then click, speak, click in
   Claude Code with `/voice tap`.
4. Unplug and replug the headset, wait 2 s, and repeat step 2. The mapping should be back.

### Probing rules

If you need to observe input events:

- Use **listen-only** event taps, filtered to the events under study (for example only `keyCode == 49`, or only
  system-defined events). **Never log all keystrokes.** An unfiltered tap records everything the human types,
  including messages and passwords.
- Write probe output to a scratch directory outside the repo, and delete it when you're done.
- For audio, log **levels only** (RMS dBFS). Never save or transmit audio.
- Run probes in the background with a time limit, and tell the human exactly what to press and when.

### Design decisions (don't re-litigate without new evidence)

- **HID remap, not an event tap.** An event tap can't stop Music from launching, and synthesized keys don't
  auto-repeat. The remap fixes both natively and needs no permissions.
- **Tap mode lives in Claude Code, not in the app.** An app-side "latch" (click holds the key down with synthesized
  repeats, next click releases) was prototyped and dropped. `/voice tap` already does it natively, and the latch
  would have needed Accessibility permission and an event tap.
- **No hosted CI.** Checks run locally through the git hooks.

### Git hooks and privacy

Enable the hooks once per clone:

    git config core.hooksPath .githooks

- **pre-commit:** runs `.githooks/privacy-gate --staged`. It refuses home-directory paths, IPv4 addresses,
  non-noreply email addresses, session links and common credential formats. It also refuses any term listed in the
  untracked `.git/info/privacy-denylist` (personal emails, signing team IDs, surnames and similar, one per line). That
  list stays out of the repo on purpose. `LICENSE` is exempt from the denylist, because its copyright line is the
  deliberate author credit.
- The gate also refuses **machine types** (computer model and chip names; the full pattern is in
  `.githooks/privacy-gate`), so development notes don't describe the hardware they ran on.
- **pre-push:** refuses unless GitHub reports the remote as `PRIVATE`. It re-runs the gate on all tracked files, and
  rejects commits whose author or committer email isn't a noreply address, or whose message has a session link.
- Commits use the GitHub noreply address (repo-local `user.email`).

### Before open-sourcing

- [ ] Remove the PRIVATE check from `.githooks/pre-push`.
- [x] Add a license (MIT, see `LICENSE`).
- [x] Use a neutral bundle ID (`app.letmetalk.LetMeTalk`).
- [ ] Run `.githooks/privacy-gate --tracked` and review the full history (`git log -p`), not just the current tree.

---

## License

MIT. See [`LICENSE`](LICENSE).
