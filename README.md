# Spartan

A macOS menu-bar app that watches the active window and flags AI-generated text in real time, scores any text you select with one keystroke, and runs full documents through the same detector.

When the active window settles for a beat, Spartan OCRs the visible text (Apple Vision), sends new passages to the [Pangram Labs v3 API](https://www.pangram.com), and draws a click-through overlay over the window: AI sentences get red highlights and a "Likely AI · NN%" badge (block-out mode replaces them with opaque rectangles). The Pangram model's per-window output drives sentence-level highlighting, so a single AI paragraph inside an otherwise human page lights up on its own.

## Privacy

**Spartan sends text from your active window to a third-party API (Pangram Labs).** Mitigations built in:

- **Per-app exclusions** — 1Password, Bitwarden, Apple Passwords, Keychain Access, and Messages are excluded out of the box; add any frontmost app with one click from the popover.
- **Pause toggle** — instantly silences continuous scanning.
- **Selection mode** — only scores text you explicitly highlight; no continuous scanning.
- **Local cache** — identical text is never re-billed, even across launches.

Redaction in block-out mode is cosmetic — the text underneath is still selectable in the real app.

## Setup

```bash
make cert   # one-time: self-signed cert so Screen Recording permission survives rebuilds
make run    # build, bundle, sign, launch
```

First run, from the menu-bar icon (text viewfinder):
1. **Grant access…** → enable Spartan under System Settings → Privacy & Security → Screen Recording → **Relaunch**.
2. Paste your Pangram API key (stored in the macOS Keychain).
3. For selection mode and the ⌘⇧A hotkey: **Grant…** Accessibility from the popover too.

## Controls

- **Scan: Continuous / Selection** — Continuous watches the whole active window; Selection only scores text you click-drag, popping a pinned verdict ("AI Generated · 97% AI") near it. Selection mode reads exact text via Accessibility (falls back to visual detection in apps without AX support); 15+ words required.
- **⌘⇧A** — score the current selection in any app, regardless of mode.
- **Check a document…** (or drag a PDF / docx / txt / md onto the popover) — section-by-section scoring with a weighted summary, exportable as CSV.
- **History (clock icon)** — every API-scored verdict, newest first, with the text, headline, source app, and a screenshot of the source region. Export as CSV; reveal the folder in Finder.
- **Threshold slider** — minimum AI likelihood to mark (re-renders instantly from cache; continuous mode).
- **Highlight / Block out** — tint vs. opaque redaction (continuous mode).
- **Exclude X / Excluded apps** — per-app pause; persistent across launches.
- **Budget panel** — daily cap (default 500), $/check estimate.
- **Recent scans** — per-passage scores; `⊙` = cache hit, `≈` = fuzzy match (no API call), `?` on a badge = passage under Pangram's 75-word reliability floor.

## Cost controls

Identical text is never re-billed (hash cache + fuzzy line matching across scroll positions, persisted to disk). At most 8 new passages per scan, 20 requests/min, 5 concurrent, soft cap of 500 checks/day (auto-pauses).

## Development

```bash
make build   # swift build -c release
make check   # logic checks (chunker / geometry / cache / windows / verdicts) — no Xcode required
make app     # rebuild + re-sign dist/Spartan.app
```

If Screen Recording permission misbehaves after signature changes: `tccutil reset ScreenCapture com.mdumas.spartan`.

## Storage

`~/Library/Application Support/Spartan/`:

- `cache.json` — persistent passage cache.
- `History/YYYY-MM-DD.jsonl` — verdict log (newline-delimited JSON).
- `History/shots/<uuid>.png` — source-region screenshots referenced by the log.

Retention defaults to 30 days; older days are purged at startup.
