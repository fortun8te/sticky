# AGENTS.md — read this before writing any code

You are working on **Sticky**: a file portal between the MacBook's notch and a
Windows PC. Drag a file at the notch, it lands on the PC. Send from the PC, it
appears at the notch. That is the whole product.

`PLAN.md` has the reasoning. `AUDIT.md` has the evidence. **This file is the
contract.** Where they disagree, this file wins.

---

## 1. Absolute rules

Violating any of these fails CI. Do not work around the lint — if you believe a
rule is wrong, stop and escalate.

**Never, anywhere in this repo:**

| Banned | Why |
|---|---|
| `NSEvent.addGlobalMonitorForEvents` | The previous build watched the cursor at 25 Hz. Use `.onDrop` / `NSDraggingDestination`. |
| `CGEvent.tapCreate`, `AXIsProcessTrusted`, `AXUIElement*` | Requires Accessibility. We never ask for it. |
| `globalShortcut`, `RegisterHotKey`, any global hotkey | The previous build stole ⌘⇧V system-wide. |
| `osascript`, `NSAppleScript`, System Events | Requires Automation. |
| `NSApp.activate(ignoringOtherApps:)` | Steals focus from Finder mid-drag. |
| `dlopen` of any `PrivateFrameworks` path | boring.notch does this. We don't ship it. |
| Any selector beginning `_` | The previous build called `_setCanExcessOverlap:`. |
| `CGWindowListCreateImage`, screen capture APIs | Not our business. |
| Literal colours / corner radii / spacing in view files | Use `DS.*` tokens. |
| Hardcoded notch dimensions | Measure at runtime. See §3. |
| Spring constants outside `Motion.swift` | One source of truth. |
| Empty `catch {}` | See §5. |

**Always:**
- The notch panel is `ignoresMouseEvents = true` unless a drag is in flight.
- `canBecomeKey` and `canBecomeMain` both return `false` on the notch panel.
- The panel is created once at max envelope and **never resized**. `setFrameOrigin` only.
- Nothing is ever drawn in the top `safeAreaInsets.top` points.

---

## 2. Scope discipline

Sticky is **not** a clipboard manager, a shelf, a launcher, a media widget, a
notification centre, or a dashboard. The previous build died of exactly this
drift — 23% of its code was a clipboard product nobody asked for.

The notch shows **the current transfer and nothing else**, and disappears when
there isn't one. Everything else lives in the menu bar.

If a task seems to require a new persistent surface, it is out of scope.
Escalate; do not build it.

---

## 3. The geometry law

Measured on the target hardware. Do not substitute published figures — they are
wrong for this machine.

```
notch      = 185.0 × 32.0 pt   (370 × 64 px @2x)
safeArea   = 32.0 pt           menuBar = 33.0 pt   ← different values, never interchangeable
notch origin x = 771.0         screen midX = 864.0 ← the notch is 0.5 pt LEFT of centre
```

```swift
// CORRECT — the only sanctioned way to get notch geometry
let originX = screen.auxiliaryTopLeftArea!.width
let width   = screen.frame.width
            - screen.auxiliaryTopLeftArea!.width
            - screen.auxiliaryTopRightArea!.width
let height  = screen.safeAreaInsets.top

// WRONG — off by 0.5 pt, which is 1 px at 2x, which is a visible seam
let originX = screen.frame.midX - width / 2
```

- All of it comes from one `NotchGeometry` value. Views read it; nothing
  recomputes its own coordinates.
- Any value reaching a `Path` is snapped to whole **pixels**:
  `(v * scale).rounded() / scale`.
- Displays are keyed by `CGDisplayCreateUUIDFromDisplayID`, never by `NSScreen`
  identity, array index, or `localizedName`.
- The portal exists only on the built-in display (the one where
  `auxiliaryTopLeftArea != nil`). No fake notch on the 27". Ever.

---

## 4. Drag handling

- Detection is `.onDrop` / `NSDraggingDestination`. Event-driven. No polling.
- The drop surface must be `Color.black.opacity(0.001)` — a fully transparent
  view does not receive Finder drags.
- `window.alphaValue` stays at `1`. Visual transparency comes from
  `isOpaque = false` + `backgroundColor = .clear`. Setting window alpha to 0
  makes the window inert to drag hit-testing.
- **Accept file promises, not just file URLs.** Dragging from the screenshot
  thumbnail, Photos, Mail, or a browser gives you an `NSFilePromiseReceiver`,
  not a `.fileURL`. Handling only `.fileURL` silently drops those — one of the
  most common ways a drop target feels broken. Register for both.

---

## 5. Errors

The previous build had 64 `catch` blocks, 13 of them empty, which is why nobody
could diagnose why haptics did nothing.

- No empty catch. Ever.
- A failure that is genuinely expected is **logged with which branch was taken**,
  not swallowed. `logger.debug("haptic skipped: no force-touch device")` is fine;
  `catch {}` is not.
- User-facing errors name the actual cause: "PC offline", "Firewall blocked",
  "Not enough space", "Checksum mismatch". Never "Something went wrong."

---

## 6. Working agreements

- **Read `docs/PROTOCOL.md` before touching transport.** It is the single source
  of truth for the wire format. Do not extend it unilaterally — if the spec is
  ambiguous, that is a bug in the spec; fix the spec first, in its own commit.
- **Do not implement both sides of the protocol.** Two independent readings of
  the spec is the point.
- **Do not write the test for code you wrote.** Harnesses are authored by an
  agent that has not seen the implementation.
- **Every task has a machine-checkable gate.** If yours doesn't, ask for one
  before starting.
- **Two strikes.** Fail the same gate twice, stop and write up what you tried.
  Do not try a third approach unsupervised.
- Match the surrounding code. Do not introduce a new dependency without asking.

---

## 7. Where things live

```
mac/Sticky/            Swift 6 · SwiftUI + AppKit
  Geometry/            NotchGeometry — the only source of coordinates
  Portal/              the notch panel, shape, states
  MenuBar/             status item + panel
  Transfer/            protocol client/server, discovery, pairing
  Design/              DesignSystem.swift (tokens), Motion.swift (springs), Icons.swift
win/Sticky/            .NET 9 · WPF + H.NotifyIcon.Wpf
  Tray/                status icon, menu, toasts
  DropWidget/          the always-on-top drop target
  Transfer/            protocol client/server, discovery, pairing
docs/PROTOCOL.md       wire format — both sides read this
docs/ICONS.md          every icon, verified to resolve
docs/TASKS.md          task cards with IDs, deps and gates
scripts/lint.sh        the rules in §1, enforced
```

## 8. Commands

```bash
scripts/lint.sh                    # run before every commit
swift build && swift test          # mac
dotnet build && dotnet test        # windows
scripts/roundtrip.sh               # phase 3 gate — real two-machine transfer
```
