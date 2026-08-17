# Sticky

Tiny Wispr-style paste pill for Windows + Mac. Type, paste, or drop files/folders into it. It overwrites the clipboard, pastes into the last app you clicked, and hands off to the other machine’s pill.

Windows monitor sits **above** the MacBook, so:

- Windows pill docks at the **bottom** (facing the Mac)
- Mac pill lives in the **notch** (facing Windows — Wispr Flow keeps the Mac bottom)

Handoff uses the local network (UDP 47831 / HTTP 47832). Same Wi‑Fi. Allow the firewall / Local Network prompt. Files land in **Downloads/Sticky** on the other machine (folders stay folders, up to 8GB). Both machines need this build.

Hover the Mac **notch** to open the island, then click to type / paste / drop. The Windows pill sits at the bottom.

## Use it

1. Click a field in Slack / Notes / Finder / Explorer.
2. Type, paste, or drop files/folders into the pill.
3. Enter sends. Glass pearl + filament flies toward the other machine.

- `Ctrl+Shift+V` / `⌘⇧V` shows the pill
- Quit from the tray

On Mac: grant **Accessibility** + **Automation** (System Events). In `npm run dev` the TCC entry is **Electron**. Add Sticky after a packaged build.

## Dev

```bash
npm install
npm run dev
```
