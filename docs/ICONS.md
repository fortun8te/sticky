# Sticky icon system

## Rules

- macOS uses SF Symbols only. Never use emoji as UI icons.
- Menu-bar and portal glyphs are template images so macOS controls contrast.
- The only accent family is warm handoff light: `#FFF6E5` to `#FFC178`.
- No cyan, blue, mint, purple, rainbow, or Apple Intelligence palette.
- File previews use the file's own pixels; otherwise fall back to `doc.fill`.

## Verified macOS symbols

| Surface | Symbol |
|---|---|
| Menu bar / drag target | `arrow.up.arrow.down.circle` |
| Hover drop prompt | `tray.and.arrow.down.fill` |
| Ready / sending | `arrow.up.circle.fill` |
| Generic document fallback | `doc.fill` |
| Offline queue | `clock.arrow.circlepath` |
| Success | `checkmark.circle.fill` |
| Failure | `exclamationmark.triangle.fill` |
| Incoming files | `arrow.down.circle.fill` |
| Incoming message | `text.bubble.fill` |

## Windows mapping

The SVGs in `assets/icons` follow Lucide-style geometry for the WPF client.
They map conceptually to the macOS symbols above: paired/offline devices,
documents, folders, media, archive, code, success, failure, and unknown type.
Keep stroke weight, optical size, and corner language consistent when adding a
new icon on either platform.
