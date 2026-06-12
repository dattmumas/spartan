# Spartan

A macOS menu-bar app that watches the active window and flags AI-generated text in real time.

When you stop scrolling for ~0.8s, Spartan OCRs the visible text (Apple Vision), sends new passages to the [Pangram Labs](https://www.pangram.com) detection API, and draws a transparent click-through overlay over the window: passages scoring above your threshold get a red highlight and an "AI NN%" badge — or an opaque block-out, if you prefer.

## Privacy

**Spartan sends text visible in your active window to a third-party API (Pangram Labs).** Use the pause toggle around sensitive content (password managers, banking, private messages). Redaction in block mode is cosmetic — the text underneath is still selectable in the real app.

## Setup

```bash
make cert   # one-time: self-signed cert so Screen Recording permission survives rebuilds
make run    # build, bundle, sign, launch
```

First run, from the menu-bar icon (text viewfinder symbol):
1. **Grant access…** → enable Spartan under System Settings → Privacy & Security → Screen Recording → **Relaunch**.
2. Paste your Pangram API key (stored in the macOS Keychain).

## Controls

- **Scan: Continuous / Selection** — Continuous watches the whole active window; Selection only scores text you select (click-drag), popping a pinned verdict ("AI Generated · 97% AI") near the selection. Selection mode reads the exact selected text via Accessibility (grant once from the popover; falls back to visual detection in apps without AX support) and makes zero API calls until you select something. Select 15+ words for a score.
- **Threshold slider** — minimum AI likelihood to mark (re-renders instantly from cache; continuous mode).
- **Highlight / Block out** — tint vs. opaque redaction (continuous mode).
- **Scanning enabled** — global pause.
- **Recent scans** — per-passage scores; `⊙` = cache hit, `≈` = fuzzy match (no API call), `?` on a badge = passage under Pangram's 75-word reliability floor.

## Cost controls

Identical text is never re-billed (hash cache + fuzzy line matching across scroll positions). At most 8 new passages per scan, 20 requests/min, 2 concurrent, soft cap of 500 checks/day (auto-pauses).

## Development

```bash
make build   # swift build -c release
make check   # logic checks (chunker / geometry / cache) — no Xcode required
make app     # rebuild + re-sign dist/Spartan.app
```

If Screen Recording permission misbehaves after signature changes: `tccutil reset ScreenCapture com.mdumas.spartan`.
