<p align="center"><img src="docs/icon.png" width="128" alt="TinyMacro icon"></p>

<h1 align="center">TinyMacro</h1>

<p align="center">
  A tiny mouse &amp; keyboard macro recorder for macOS.<br>
  Record it once, then loop it, speed it up, or turn it into its own app.
</p>

<p align="center">
  <a href="https://github.com/xaslin/TinyMacro/releases/latest/download/TinyMacro.zip"><b>Download</b></a> ·
  <a href="https://xaslin.github.io/TinyMacro/">Website</a> ·
  <a href="LICENSE">MIT License</a>
</p>

---

## What it does

TinyMacro is one small window with six buttons: **Open · Save · Rec · Play · .app · Prefs**.

- **Record** mouse moves, clicks, double-clicks, drags, scrolling and keystrokes, including modifier keys.
- **Play** it back at the exact pace you recorded. Timing comes from each event's hardware timestamp, and a real-time thread does the playback.
- **Loop**: play once, *N* times, or until stopped, with an optional **wait between runs**.
- **Speed**: 0.25× to 100×.
- **Global shortcuts** work from any app, and you can change them in Prefs. They're removed from the recording automatically.
- **Save / open** recordings as `.tinyrec` files.
- **Export as app**: turn a recording into a standalone `.app` that plays the macro when opened.
- **Safe stop**: stopping mid-playback releases any held keys and mouse buttons.
- **Private**: no network access, no analytics, no accounts.

## Shortcuts

| Action | Default |
|---|---|
| Record / stop | `⌃⌥⇧R` (Control + Option + Shift + R) |
| Play / stop | `⌃⌥⇧P` (Control + Option + Shift + P) |
| Open · Save · Export | `⌘O` · `⌘S` · `⌘E` |
| Prefs | `⌘,` |

## Settings (Prefs)

| Setting | Options |
|---|---|
| Shortcuts | Click and press any combo with ⌃/⌥/⌘, or a bare F-key |
| Playback speed | 0.25× · 0.5× · 1× · 2× · 4× · 8× · 16× · 50× · 100× |
| Repeat | Play once · Repeat *N* times · Repeat until stopped |
| Wait between runs | Seconds (decimals OK), not affected by speed |
| Options | Keep on top · Record mouse movement · Hide while playing |
| Permissions | Live status + buttons that open System Settings |

## Install

1. Download [`TinyMacro.zip`](https://github.com/xaslin/TinyMacro/releases/latest/download/TinyMacro.zip), unzip it, and move **TinyMacro.app** to Applications.
2. The app isn't notarized, so macOS blocks the first launch. Open it once, then go to **System Settings → Privacy & Security → Open Anyway**.
   Or in Terminal: `xattr -dr com.apple.quarantine /Applications/TinyMacro.app`
3. When asked, allow TinyMacro under **Accessibility** (for playback) and **Input Monitoring** (for recording keys), then quit and reopen it.

Requires macOS 14 Sonoma or later. Works on Apple Silicon and Intel.

## Build from source

Needs the Xcode Command Line Tools (`xcode-select --install`). There's no Xcode project.

```sh
git clone https://github.com/xaslin/TinyMacro.git
cd TinyMacro
./build.sh            # → build/TinyMacro.app
```

macOS ties permissions to the app's code signature. To keep permissions across rebuilds, run this once:

```sh
scripts/setup_signing.sh   # creates a local "TinyMacro Local Signing" certificate
```

Or sign with your own identity: `SIGN_IDENTITY="Apple Development: …" ./build.sh`.

### Project layout

```
Sources/main.swift        the whole app (AppKit, ~1200 lines)
Info.plist                bundle metadata
Resources/AppIcon.icns    app icon
build.sh                  compile + bundle + sign
scripts/make_icon.swift   regenerates the icon
scripts/setup_signing.sh  optional stable local signing identity
docs/                     GitHub Pages website
```

## How it works

- **Recording**: a listen-only `CGEventTap` runs on its own real-time thread and stores each event as serialized `CGEvent` data, along with the gap since the previous event.
- **Playback**: events are decoded up front, then posted with `CGEvent.post(tap: .cghidEventTap)` on a real-time thread that waits with `mach_wait_until` against an absolute schedule, so timing never drifts.
- **Shortcuts**: registered with Carbon `RegisterEventHotKey`, which needs no extra permission.
- **App Nap** is disabled while recording or playing, so background throttling can't add lag.

## Disclaimer

TinyMacro is an independent project inspired by the simplicity of TinyTask for Windows. It isn't affiliated with or endorsed by TinyTask's authors, and it shares no code with it.

Use macros responsibly. Automating some apps or games may break their terms of service.

## License

[MIT](LICENSE) © 2026 Nathaniel
