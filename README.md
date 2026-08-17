# Sticky

Always-on paste drop for Windows and Mac. Paste or drop files here, Sticky overwrites the clipboard with a clean payload, then drops it into the last app you clicked. History syncs through iCloud so going back to the other machine still has your clips.

## Use it

1. Click the field you want in Slack, Notes, Finder, Explorer, whatever.
2. Paste into Sticky, or drop files onto it.
3. Sticky copies clean Unicode text (or the files) and pastes into that last field.

- `Ctrl+Shift+V` / `⌘⇧V` shows Sticky
- Click a history row to drop it again
- Star pins a clip
- iCloud Drive folder `Sticky/history.json` is the Mac ↔ Windows handoff

On Mac, grant **Accessibility** and **Automation** (System Events) when prompted so paste-into-last-app works. If it doesn’t, add Sticky under System Settings → Privacy & Security → Accessibility, and allow it to control System Events under Privacy & Security → Automation.

## Dev

```bash
npm install
npm run dev
```

```bash
npm run dist:win
npm run dist:mac
```

Installs itself at login. Quit from the tray.
