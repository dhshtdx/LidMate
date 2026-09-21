# LidMate

[中文](README.md) | **English**

> A tiny macOS menu-bar app for laptop + external monitor setups:
> **sleep on lid close**, and **auto-mirror the desktop to the laptop screen
> when your monitor switches to another input source** (e.g. a gaming console
> or a work PC on HDMI/DP), then restore the extended layout when it switches back.

---

## ⚠️ Run the compatibility self-test first (important)

**LidMate's "display follow" depends entirely on one hardware capability:
whether your monitor can report its *current input source* over DDC/CI
(VCP `0x60`).**

Many monitors **do not support reading this register**, or always return the
same value no matter which input is active. On those machines LidMate
**simply cannot work**. So before installing anything, run:

```bash
bash tools/selftest.sh
```

The script walks you through switching your monitor's input once, then tells
you the verdict. **Only continue if it prints ✅.**

---

## What it does

### 1. Sleep on lid close

When a MacBook is connected to **both power and an external display**, macOS
enters **clamshell mode**: closing the lid keeps the machine awake and drives
only the external screen — and **there is no setting anywhere to turn this off**.
LidMate polls the lid state once per second and runs `pmset sleepnow` as soon
as the lid closes.

### 2. Display follow

When the external monitor **switches to another input source** (say you hand it
over to a Windows PC or a game console):

- The desktop is automatically **mirrored onto the built-in laptop screen**
- So there is **nowhere for the cursor to go, nowhere for keyboard focus to
  escape, and no way for a window to get stranded on an invisible screen**
- The menu bar and Dock stay on the laptop

Switching back to the Mac's input restores the extended layout automatically.

---

## Installation

1. Download `LidMate.dmg`, mount it, drag `LidMate.app` into Applications
2. If macOS warns about an unidentified developer (the app is only ad-hoc
   signed), right-click → Open
3. A laptop-shaped icon appears in the menu bar (**no Dock icon, no windows —
   that is by design**)
4. On first launch it auto-detects your displays and learns the Mac's input code
5. Click the menu-bar icon → enable **合盖即睡** (sleep on lid close) and
   **显示器跟随** (display follow)

> To start at login: tick **登录时自动启动** in the menu.

---

## Menu reference

```
合盖即睡              Sleep on lid close            ← toggle
显示器跟随            Display follow                ← toggle
────────────────
跟随的显示器 ▸        Which display to follow ▸      ← pick when you have several
重新学习当前显示器     Re-learn current displays      ← after changing cable/port
显示器自检（兼容性）   Compatibility self-test        ← runs in Terminal
────────────────
登录时自动启动         Start at login
查看日志              View log  (~/Library/Logs/LidMate.log)
────────────────
关于 LidMate           About
退出 LidMate           Quit
```

---

## How it works

```
Every 1s: read the monitor's VCP 0x60 (current input source)
      │
      ├─ equals "the Mac's input code" ──→ keep/restore extended layout, external is main
      │
      └─ does not equal ──┐
                          │  sliding-window vote: ≥2 abnormal out of the last 4
                          ↓
               mirror onto the built-in screen (cursor & focus locked to the laptop)
```

**Resolution, refresh rate and arrangement are all read live from
`displayplacer list` and preserved verbatim** — your System Settings
preferences are never overwritten. The extended layout is saved as a
"profile" (`~/Library/Logs/LidMate.log.layout`) and simply replayed on restore.

---

## Pitfalls we hit (probably the most valuable part of this repo)

### ① Never use `enabled:false` to "turn off" the external display

Our first approach was to run
`displayplacer "id:<external> enabled:false"` to remove the external display
from the layout. The result:

- The display **immediately disappears from macOS's display enumeration**
- But when the monitor switches *back* to the Mac's input, **no HPD change
  occurs at all**
- So macOS never re-adds the display, and `enabled:true` can't find it
- **The only recovery is physically unplugging and replugging the cable**

Reproduced twice. Sleep/wake does not bring it back either — see ③ below.

### ② DDC readings flap wildly during the switch

For several seconds while the monitor changes input, VCP `0x60` alternates
between "the Mac's input code" and a constant junk value (`2809` on our unit).

A naive "N consecutive abnormal reads" rule gets **reset by every stray good
read**, pushing the trigger ten-plus seconds out — or preventing it entirely.

**Fix: a sliding-window vote** — look at the last `WINDOW` samples and declare
"switched away" when at least `BAD_NEEDED` of them are abnormal. It fires
immediately while still ignoring single-sample glitches:

```bash
hist="${hist}G"          # or B
hist="${hist: -$WINDOW}" # keep only the last WINDOW samples
badn=$(printf '%s' "$hist" | tr -cd 'B' | wc -c)
```

### ③ Watching HPD to detect the switch? Dead end.

It seems obvious: if macOS stops monitoring HPD after you disable a display,
why not write your own watcher for `AppleATCDPAltModePort`'s
`SinkActive` / `Plug` events?

We dug through the entire IORegistry. The verdict:

```
before switch:  atc1-dpphy SinkActive=1(events=55) Plug=33
after  switch:  atc1-dpphy SinkActive=1(events=55) Plug=33   ← not a single new event
```

**Reason: when the monitor switches to another input, the DP link stays
trained** (HPD stays high and the AUX/DDC channel stays alive — which is
exactly why that `2809` is still readable). The driver has nothing to log,
so there is no signal to watch.

### ④ Profile corruption: one "false success" permanently breaks things

In our first implementation, a failed restore still marked `state` as
success. The next time the monitor switched away, `save_profile` stored the
**mirrored** state as the "extended layout profile". From then on every
"restore" just **mirrored again** — stuck forever.

**Fix (three layers of defence):**

1. `save_profile` only saves when the layout **really is extended**, and
   **rejects any command containing `+`** (the mirror syntax)
2. `restore_profile` **verifies the result** after applying, falls back to a
   `.bak` copy, and retries up to 3 times per candidate
3. **A failed restore never marks the state as successful** — it keeps
   retrying instead of pretending it worked

---

## Known limitations

- **Apple Silicon only.** `m1ddc` does not support Intel Macs; on Intel you'd
  need `ddcctl` or Better Display's CLI (PRs welcome)
- **Follows one external display** (pick which one from the menu)
- **Requires the monitor to support reading VCP `0x60`** — see the self-test above
- While mirrored, the external display is driven at **the built-in screen's
  resolution**. Since the monitor is showing another device at that moment you
  normally can't see it, and it is restored the instant you switch back
- Switching latency is about **2–4 seconds** (tunable via `POLL` / `WINDOW` /
  `BAD_NEEDED` at the top of the script)

---

## Development / build

```bash
# 1. Get the third-party binaries (see vendor/README.md)
#    vendor/m1ddc
#    vendor/displayplacer

# 2. Build
bash build.sh
# produces dist/LidMate.app and dist/LidMate.dmg
```

Requires Xcode Command Line Tools (`swiftc` / `iconutil` / `hdiutil` / `codesign`).

### Project layout

```
LidMate/
├── LICENSE
├── THIRD-PARTY-NOTICES.md      # MIT notices for m1ddc / displayplacer
├── README.md                   # 中文
├── README.en.md                # English (this file)
├── build.sh
├── src/
│   ├── main.swift              # menu-bar app (discovery / learning / child processes)
│   ├── Info.plist              # LSUIElement = no Dock icon
│   └── resources/
│       ├── clamshell.sh        # sleep on lid close
│       └── displaysync.sh      # display follow (core logic)
├── tools/
│   ├── makeicon.swift
│   └── selftest.sh             # compatibility self-test
└── vendor/                     # third-party binaries
```

### Debugging

Log file: `~/Library/Logs/LidMate.log`

```
读数变化: present=1 input=[2809] 窗口=[GGGB] want=ours state=ours
外屏切走了 (input=2809, 窗口=[BBGB]) → 镜像到内屏（鼠标/焦点锁定在笔记本）
读数变化: present=1 input=[16] 窗口=[GGGG] want=ours state=away
外屏在显示本机 (input=16) → 还原扩展布局、外屏为主屏
```

`窗口=[GGGB]` is the sliding-window state: `G` = read the Mac's input code,
`B` = abnormal.

---

## License

MIT © 王灿 ([@dhshtdx](https://github.com/dhshtdx))

The bundled third-party tools are MIT as well:
[m1ddc](https://github.com/waydabber/m1ddc),
[displayplacer](https://github.com/jakehilborn/displayplacer).
See [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) for full notices.
