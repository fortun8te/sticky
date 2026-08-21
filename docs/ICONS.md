# Icons

Every symbol in this file was verified to resolve on the target OS
(macOS 26.5, Xcode 26.6) with `NSImage(systemSymbolName:)` — 61/61. Do not
introduce a symbol without checking it the same way; invented SF Symbol names
that silently render nothing are a classic failure.

```bash
scripts/symcheck.swift    # run after adding any symbol
```

---

## 1. Rules

- **SF Symbols only on macOS. Never emoji.** Emoji standing in for symbols is the
  single fastest visual tell of a machine-made interface.
- Symbol weight matches adjacent text weight. A semibold label beside a regular
  glyph looks broken even when nothing is technically wrong.
- Size with `.imageScale` / font size — never a hardcoded frame.
- `.symbolRenderingMode(.hierarchical)` for anything with depth;
  `.monochrome` for the portal, which is one colour on black.
- One accent colour in the whole surface (`DS.Colors.accent`). Semantic
  colours — success, warning, error — are separate and do not count as accents.

---

## 2. Portal states

| State | Symbol | Notes |
|---|---|---|
| Hidden | — | nothing drawn |
| Approaching | — | shape only, no glyph |
| Armed | `arrow.down.to.line` | with "Release to send to PC" |
| Sending | `arrow.up.right` | direction is the icon; no separate label |
| Receiving | `arrow.down.left` | mirrored |
| Success | `checkmark` | ~900 ms, then gone |
| Failure | `exclamationmark.triangle.fill` | ~2.5 s, plus the reason |
| Paused / queued | `pause.circle.fill` | pending queue non-empty |

## 3. File chips

Resolved from UTI, falling back to `doc.fill`. Prefer a real QuickLook
thumbnail (`QLThumbnailGenerator`) where one exists; the symbol is the fallback.

| Kind | Symbol |
|---|---|
| Folder | `folder.fill` |
| Image | `photo.fill` |
| Video | `film.fill` |
| Audio | `music.note` |
| PDF | `doc.richtext.fill` |
| Archive | `doc.zipper` |
| Text / code | `text.document.fill` |
| Multiple | `square.stack.3d.up.fill` |
| Unknown | `doc.fill` |

## 4. Menu bar

| Item | Symbol |
|---|---|
| Status item, connected | `arrow.left.arrow.right` (template image) |
| Status item, offline | `wifi.slash` |
| Status item, transferring | `arrow.left.arrow.right` + animated accent dot |
| Status item, error | `exclamationmark.circle.fill`, error tint |
| Send Files… | `paperplane.fill` |
| Pending Transfers | `tray.full.fill` |
| Open Received Files | `folder.fill` |
| Retry Last Transfer | `arrow.clockwise` |
| Pair Device | `link` |
| Forget Device | `link.badge.plus` (rotated / struck) |
| Launch at Login | — (checkmark row) |
| Quit | `power` |
| Peer online | `circle.fill`, success tint |
| Peer offline | `circle.dotted`, dim |

**Status item is a template image**, so macOS tints it for light/dark menu bars
automatically. Do not ship two coloured variants.

## 5. Devices

`macbook` for this Mac, `pc` for the Windows machine. Both verified. Used in
pairing and in the transfer direction indicator; never decoratively.

---

## 6. Windows parity — and a licensing constraint

**SF Symbols may not be used on non-Apple platforms.** Apple's license restricts
them to Apple OSes, so exporting them into the WPF app is not an option, however
convenient it would be for visual parity.

Use **[Lucide](https://lucide.dev)** (ISC licence, ~1,600 icons, stroke style
close to SF Symbols). Ship as `Path` geometry in a resource dictionary, not as a
font, so stroke width can be matched to the text weight the same way.

| Sticky | SF Symbol (mac) | Lucide (win) |
|---|---|---|
| Send | `paperplane.fill` | `send` |
| Receive | `arrow.down.left` | `arrow-down-left` |
| Success | `checkmark` | `check` |
| Failure | `exclamationmark.triangle.fill` | `triangle-alert` |
| Pending | `tray.full.fill` | `inbox` |
| Retry | `arrow.clockwise` | `rotate-cw` |
| Pair | `link` | `link` |
| Offline | `wifi.slash` | `wifi-off` |
| Folder | `folder.fill` | `folder` |
| Settings | `gearshape.fill` | `settings` |

Stroke width 1.5 px at 16 px to sit correctly beside Segoe UI Regular. Windows
tray icon is a 16/20/24/32 px ICO of the same `arrow-left-right` mark.

---

## 7. App icon

One mark, used for both apps so they read as one product.

**Concept:** the notch silhouette itself — the measured 185×32 shape from
`NotchShape`, rendered as a solid aperture with a single file chip passing
through it. Black ground, one cyan stroke. It is literally what the app does, it
is unmistakable at 16 px because the silhouette is distinctive at any size, and
it needs no lettering.

- macOS: standard rounded-rect app icon, the aperture centred, `.icon` asset
  with the current macOS 26 layered format.
- Windows: the same mark, square, no rounding, in the ICO.
- Do **not** use a gradient. Do not use a purple-to-blue anything.
