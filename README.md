# Sticky

Tiny Wispr-style paste pill for Windows + Mac. Type, paste, or drop files/folders into it. It overwrites the clipboard, pastes into the last app you clicked, and AirDrops to the other machine’s pill.

Windows monitor sits **above** the MacBook, so:

- Windows pill docks at the **bottom** (facing the Mac)
- Mac pill docks at the **top** (facing Windows — Wispr Flow keeps the Mac bottom)

Handoff uses the local network (UDP 47831 / HTTP 47832). Same Wi‑Fi. Allow the firewall prompt.

## Use it

1. Click a field in Slack / Notes / Finder / Explorer.
2. Type, paste, or drop files/folders into the pill.
3. Enter sends. The other pill catches it with an AirDrop-style fly.

- `Ctrl+Shift+V` / `⌘⇧V` shows the pill
- Hover the bar to interact; empty chrome clicks through
- Quit from the tray

On Mac: grant **Accessibility** + **Automation** (System Events). Add Sticky under System Settings → Privacy & Security → Accessibility.

## Dev

```bash
npm install
npm run dev
```
