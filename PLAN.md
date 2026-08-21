# Sticky — Rebuild Plan

**Status:** plan only. No implementation yet.
**Repo:** `fortun8te/sticky` (reused; history kept; rebuilt on a branch)
**Target:** macOS 26.5+ (Swift 6.3 / Xcode 26.6) ↔ Windows 11 (.NET 9)
**Written:** 2026-08-21

---

## 0. What Sticky is

A file portal between this MacBook Pro and the Windows PC.

Drag a file at the MacBook's notch → it lands on the PC. Send from the PC → it
appears at the notch. That is the entire product.

Two surfaces, and only two:

1. **The notch portal.** Transient. Appears only during a drag or a transfer.
   Shows the current transfer and nothing else.
2. **A menu-bar item.** Ordinary, boring, dependable. Pairing, sending, errors,
   pending queue, settings.

There is no click-to-open notch dashboard. No shelf. No clipboard manager. No
music widget. The notch is not a place you go; it is a thing that happens.

**Replaces:** messaging myself files in Telegram Saved Messages.

### 0.1 Feature set

Each of these earns its place by needing **no new surface** — they ride on the
notch, the menu bar, or an affordance the OS already provides. Anything that
would add a persistent window is out.

| # | Feature | Why it's minimal |
|---|---|---|
| F-1 | **Drag in → send.** Drop files at the notch, they land on the PC. | The product. |
| F-2 | **Receive → notch.** The portal opens on its own, direction reversed. | Same surface, mirrored. |
| F-3 | **The menu-bar icon is also a drop target.** | The only way to send in clamshell, on an external-only setup, or on a Mac with no notch. Zero new UI. |
| F-4 | **Drag out.** A just-received file can be dragged straight from the portal into any app. | Symmetric with F-1 and uses the same surface. Needs `NSFilePromiseProvider`. |
| F-5 | **File promises in.** Accept drags from the screenshot thumbnail, Photos, Mail and browsers — not just Finder. | Not a feature so much as *not being broken*: those drags carry an `NSFilePromiseReceiver`, not a `.fileURL`, and an app that handles only file URLs silently drops them. The single most common reason a drop target feels unreliable. |
| F-6 | **Batch while sending.** A transfer in flight accepts more files dropped onto it. | Gives you "gather then send" without a persistent tray. See §15.6. |
| F-7 | **Recents — last 5, with re-send.** | A bounded menu section, not a shelf. It disappears when the menu closes. |
| F-8 | **QuickLook thumbnails on chips.** | Needed for the chip row to look like the reference at all. `QLThumbnailGenerator`, symbol fallback. |
| F-9 | **Finder Quick Action: "Send to PC".** | Uses macOS's own right-click affordance. Also the only keyboard path — and it needs no hotkey, so it doesn't violate the input rule. |
| F-10 | **Pending queue with resume.** PC offline → queued, not silently failed. Interrupted transfers resume from a byte offset. | Menu-only. The protocol already carries `resume` offsets. |
| F-11 | **Windows: drop widget, Send To, and Explorer context menu.** | Three affordances because you *cannot* drop onto a Windows tray icon (§6). |
| F-12 | **Toast on arrival with "Open Folder".** | The OS's own notification surface. |

**Parked, deliberately:** explicit "Send Text", more than one peer,
wake-on-LAN for the PC, transfer history beyond five, any clipboard behaviour,
any always-visible surface on macOS.

**Note on F-4 and F-5:** these are the two that make Sticky feel like a system
feature rather than an app. Both are pure drag-and-drop plumbing, both are
frequently got wrong, and both are gated in `docs/TASKS.md` T-204.

---

## 1. Post-mortem: what the old build actually was

I read the repo at `c6cc8f0` rather than trusting the earlier summary. Several
claims in that summary do not survive contact with the code.

### 1.1 The salvage list was wrong

The previous post-mortem said to **keep** "the native Swift Mac direction", "the
native .NET Windows tray direction", "streaming into temporary files",
"checksums", and "device identity and certificate-pinning concepts", and to
**remove** "legacy PKCS#12 certificate-import code".

None of that exists.

```
3,342 lines. 100% TypeScript on Electron.
Swift files: 0
C# files:    0
```

`grep` across all of `src/` returns **zero** hits for `createHash`, `sha256`,
`sha1`, `tls.`, `https.`, `X509`, `hmac`, `randomBytes`, `pairing`, `pinning`,
`secret`. There is no checksum, no certificate, no PKCS#12, no device identity,
no pairing, and no native code of any kind.

**Consequence:** Phase 1 is not "delete Electron and keep the native parts."
There are no native parts. This is a from-zero native build. The honest salvage
list is at §1.7.

### 1.2 The defect the old post-mortem never mentioned — and the worst one

`src/main/peer.ts` serves files over **plaintext HTTP with no authentication**:

```ts
private udp = dgram.createSocket({ type: 'udp4', reuseAddr: true })  // :265
this.server = http.createServer((req, res) => { ... })               // :276
export const UDP_PORT = 47831
export const HTTP_PORT = 47832
```

No TLS. No pairing. No tokens. No integrity check. Any device on the same Wi‑Fi
can write files into `~/Downloads/Sticky` and read what is offered. On a café or
co-working network this is a remote file-write primitive.

This is the single most serious defect in the old build and it was not on the
list. Fixing it is not polish; it is the reason pairing and mutual TLS are
Phase 4 gates below.

### 1.3 Keyboard hijacking — exact causes

| Line | Code | Effect |
|---|---|---|
| `index.ts:750` | `systemPreferences.isTrustedAccessibilityClient(true)` | The `true` argument **prompts**. Runs unconditionally at every launch. |
| `index.ts:767` | `globalShortcut.register('Command+Shift+V')` | Steals a system-wide chord from every other app. |
| `inject.ts:411` | `osascript -e 'tell application "System Events" to keystroke "v" using command down'` | Synthesises a paste into whatever app was last focused. |
| `inject.ts:336,395` | further System Events automation | Requires the Automation permission too. |

The app was *designed* to type on the user's behalf. That is why it felt like it
had taken over the keyboard — it had. The README says so plainly: *"It overwrites
the clipboard, pastes into the last app you clicked."*

### 1.4 The giant hitbox — a points/pixels bug

`src/main/notch.ts`:

```ts
export const MAC_IDLE_W = 188      // real notch is 185.0 pt
export const MAC_HIT_W  = 370      // 185 × 2 — this is the notch width in PIXELS
```

`370` is the notch measured in **pixels** on a 2× Retina display, used as
**points**. `placeNotchWindow()` then pins that as a hard floor:

```ts
win.setMinimumSize(MAC_HIT_W, idleH)
```

So an interactive window exactly **twice as wide as the notch** sat at the top of
the screen at all times. That is the "huge annoying hitbox", and it was one
unit-conversion mistake.

### 1.5 Glitchiness — exact causes

- `index.ts:765` — `setInterval(tickHover, 40)`: the cursor is polled 25×/second,
  forever, whether or not anything is happening.
- `index.ts:782` — a second 2-second interval that shells out to `osascript` to
  ask which app is focused.
- `notch.ts` — `win.setBounds()` on **every** state change, resizing the real
  OS window mid-animation instead of animating content inside a fixed window.
- `notch.ts:69` — a **private AppKit selector** reached through FFI:
  ```ts
  objc.msgBool(nsWin, objc.sel('_setCanExcessOverlap:'), 1)
  ```
  plus `setFrameTopLeftPoint:` / `setContentSize:` driven behind Electron's back.
  Two layout systems fighting over the same window.
- 64 `catch` blocks, 13 of them completely empty.

### 1.6 Haptics — why they silently did nothing

`haptic.ts` reaches `NSHapticFeedbackManager` through `koffi` FFI into
`objc_msgSend`. The pattern constants are actually correct
(`generic 0 / alignment 1 / levelChange 2`). The failure is diagnostic:

```ts
} catch {
  /* Magic Mouse / no Taptic Engine */
}
```

Every failure is swallowed, so a silent no-op is indistinguishable from a
misconfigured call, a wrong thread, or a suppressed system setting.

For the record, on this machine the hardware is fine:

```
ForceSupported     = Yes
ActuationSupported = Yes
ForceSuppressed    = No     (system haptics enabled)
```

Haptics were never a hardware problem. They were an FFI-plus-silence problem.

### 1.7 What is actually worth keeping

- `src/main/peer.test.ts` — the `sanitizeRel()` **test vectors**: `../etc/passwd`,
  `foo/../../x`, `C:`, `foo:bar`, `shot<>.png`, `con.txt`, `nul`, `photo.`.
  These encode real cross-OS filename traps and port directly to the new tests.
- Port numbers `47831` / `47832` — arbitrary but fine, and already firewalled.
- The product intuition.

Everything else goes.

### 1.8 One claim I could not substantiate

The earlier post-mortem lists a "private-key prompt" caused by "a certificate
imported through macOS Keychain during startup." There is no certificate,
Keychain, or PKCS#12 code anywhere in this repo. The prompt users actually saw
at launch is the **Accessibility** prompt from `index.ts:750`. I've written the
rebuild rule against the cause I can prove, and kept a Keychain-prompt gate in
§9 anyway because the new build *will* store a private key and must not
reintroduce one.

---

## 2. What I read, and what we take from each

All source read directly, not summarised from blog posts.

| Reference | License | Take | Reject |
|---|---|---|---|
| **[DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit)** | MIT | The `NotchShape` path math (§3.3). Fixed oversized panel, content animates inside — never resize the window. Zero global monitors; hover via SwiftUI `.onHover`. | Positions the notch from `frame.midX` — **off by 0.5 pt** (§3.1). Rebuilds the panel on *every* screen-parameter change, even when hidden. No Reduce Motion support at all. |
| **[NotchDrop](https://github.com/Lakr233/NotchDrop)** | MIT | The `.onDrop`-based drag target (event-driven, no polling). The `Color.black.opacity(0.001)` trick — a fully transparent view does not receive Finder drags. | `NSApp.activate(ignoringOtherApps: true)` on every open — steals focus from Finder mid-drag. A `.flagsChanged` global keyboard monitor for a cosmetic hover. A dead `.leftMouseDragged` monitor with no subscribers. `canBecomeKey`/`canBecomeMain` both `true`. A 1 Hz polling timer for the lifetime of the app. |
| **[boring.notch](https://github.com/TheBoredTeam/boring.notch)** | — | **UUID-keyed displays** via `CGDisplayCreateUUIDFromDisplayID` — the one piece worth lifting nearly verbatim (§3.4). Fixed-size window, `setFrameOrigin` only. `canBecomeKey`/`canBecomeMain` = `false`. Generous drop region sized to the *open* notch, not the closed pinhole. | A private `SkyLight.framework` `SLSRemoveWindowsFromSpaces` dlopen hack. An XPC helper for Accessibility we don't need. A `+4` fudge factor on notch width with no explanation. Animation constants scattered across ~10 files with an unfixed `// TODO: Move all animations to this file`. |
| **[Atoll](https://github.com/Ebullioscopic/Atoll)** | — | Haptic tick on discrete snap (`.generic` / `.alignment`). The documented lesson that granting Accessibility does **not** notify a running process. | It is a fork of boring.notch that **regressed**: resizes the real `NSWindow` on every state change; `canBecomeKey`/`canBecomeMain` flipped to `true`; multi-display state keyed by `NSScreen` object identity and `localizedName` (two identical monitors collide). |
| **[Clicky](https://github.com/farzaa/clicky)** | MIT | Not a notch app, but the **best structural reference here.** Native Swift, 7.7k LOC. `DesignSystem.swift` is a single 880-line token namespace — one source of truth for every colour, radius, spacing step and duration (§9.1). `OverlayWindow` is the exact window posture we want (below). | Its push-to-talk uses `CGEvent.tapCreate` on `.keyDown/.keyUp/.flagsChanged` — requires Accessibility. This is precisely what Sticky must never do. Its near-black surface ramp (`#101211`) is right for a floating panel and **wrong for the notch**, which must be pure black (§9.3). |

Clicky's `OverlayWindow.swift:14-52` is the posture Sticky copies:

```swift
self.isOpaque = false
self.backgroundColor = .clear
self.level = .screenSaver
self.ignoresMouseEvents = true          // click-through by default
self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
self.hasShadow = false
self.hidesOnDeactivate = false
override var canBecomeKey:  Bool { false }   // never steals focus
override var canBecomeMain: Bool { false }
```

Clicky sets `ignoresMouseEvents = true` and never changes it, because its overlay
is purely decorative. Sticky needs it toggled — and that toggle is the entire
hitbox guarantee (§4.1).

---

## 3. The geometry law

Every clipping, seam and misalignment bug in the old build came from guessing at
numbers. So this section is measured, not assumed.

### 3.1 Measured on this machine (2026-08-21)

```
macOS 26.5.1 (25F80) · arm64 · Xcode 26.6 · Swift 6.3.3
Built-in Retina Display: 1728 × 1117 pt @2x  (3456 × 2234 px)

safeAreaInsets.top    = 32.0 pt        ← camera housing height
menubarHeight         = 33.0 pt        ← frame.maxY − visibleFrame.maxY
NOTCH                 = 185.0 × 32.0 pt   (370 × 64 px)
auxiliaryTopLeftArea  = (0,   1085, 771, 32)
auxiliaryTopRightArea = (956, 1085, 772, 32)
```

**Finding 1 — the notch is not horizontally centred.**

```
left aux width  = 771.0
right aux width = 772.0
notch spans x = 771 … 956,  midpoint = 863.5
screen midX = 864.0
→ the notch sits 0.5 pt LEFT of screen centre
```

This is not a fluke: `1728 − 185 = 1543`, an odd number, so it *cannot* split
evenly. Any code that computes

```swift
x = screen.frame.midX - notchWidth / 2      // ← WRONG
```

is off by half a point, which at 2× is a **one-pixel** misalignment — an
antialiased grey seam down one edge of the notch. DynamicNotchKit does exactly
this, and boring.notch's drop region does too.

**The law:**
```swift
let notchOriginX = screen.auxiliaryTopLeftArea!.width   // never derive from midX
let notchWidth   = screen.frame.width
                 - screen.auxiliaryTopLeftArea!.width
                 - screen.auxiliaryTopRightArea!.width
let notchHeight  = screen.safeAreaInsets.top
```

**Finding 2 — the menu bar is 1 pt taller than the notch.**

```
notch    occupies y 1085 … 1117   (32 pt)
menu bar occupies y 1084 … 1117   (33 pt)
visibleFrame.maxY = 1084
```

There is a 1 pt band below the notch that is still menu bar. Anything that
assumes `notchHeight == menuBarHeight` will seam by one point. The two numbers
are never interchangeable and are never hardcoded.

### 3.2 The rules that follow

1. Measure at runtime. Zero hardcoded notch dimensions anywhere in the codebase —
   enforced by a lint (§9.4).
2. `notchOriginX` comes from `auxiliaryTopLeftArea.width`. Never from `midX`.
3. `notchHeight` is `safeAreaInsets.top`. `menuBarHeight` is
   `frame.maxY − visibleFrame.maxY`. They are different variables.
4. **One geometry model.** A single `NotchGeometry` value computes every
   number — window frame, drawn path, drop-sensor rect, animation targets. Views
   read from it; nothing computes its own coordinates. The old build had four
   disagreeing sources (`MAC_IDLE_W`, `MAC_OPEN_W`, `MAC_HIT_W`, and whatever
   `setBounds` last wrote).
5. All geometry snaps to the backing store: any value that reaches a path is
   rounded to a whole **pixel** (`round(v * scale) / scale`), not a whole point.
6. **The camera region is permanently empty.** No text, icon, border or animated
   element ever enters the top `safeAreaInsets.top` points. Content begins at
   `notchHeight + 10 pt`. Enforced by a debug-build assertion on content bounds.

### 3.3 The shape

DynamicNotchKit, boring.notch and Atoll all ship a byte-identical `NotchShape`
(originally Kai Azim's). It works, and it is what we use — two quadratic curves
per side, with the concave shoulder produced by placing the control point at the
inner corner:

```swift
path.addQuadCurve(                                    // top-left, convex
    to:      CGPoint(x: rect.minX + topR, y: rect.minY + topR),
    control: CGPoint(x: rect.minX + topR, y: rect.minY))
path.addLine(to: CGPoint(x: rect.minX + topR, y: rect.maxY - botR))
path.addQuadCurve(                                    // bottom-left, CONCAVE
    to:      CGPoint(x: rect.minX + topR + botR, y: rect.maxY),
    control: CGPoint(x: rect.minX + topR,        y: rect.maxY))
// … mirrored on the right
```

Both radii are `animatableData` (an `AnimatablePair`), so SwiftUI interpolates
the corner radii themselves during expand/collapse rather than scaling a static
shape. That is why it reads as one machined object flexing instead of a picture
being stretched.

Radii: closed `(top: 6, bottom: 14)` → open `(top: 15, bottom: 20)`.

Verified available on this toolchain (compiled against `arm64-apple-macos26.0`):
`ConcentricRectangle(corners:isUniform:)`, `RoundedRectangle(style: .continuous)`,
`Canvas` + `.blur` + `.alphaThreshold`, and `.glassEffect()`.

### 3.4 Displays

Multi-display state is keyed by a hardware-stable UUID, never by `NSScreen`
identity or `localizedName`:

```swift
let displayID = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(...))
```

- The portal lives on the **built-in display only** — the one where
  `auxiliaryTopLeftArea != nil`.
- No fake notch on the 27". Ever.
- Clamshell, or a Mac with no notch: menu-bar item only in v1. The portal simply
  does not exist.
- `didChangeScreenParametersNotification` fires in bursts; it is **debounced
  (250 ms)** and handled in exactly one place, which recomputes geometry and
  repositions. It does not tear down and rebuild the window.

### 3.5 The constraint nobody else has

The 27" is mounted **above** the MacBook. The notch sits on the top edge of the
built-in display, which is the seam where the cursor crosses to the other screen.
Dragging a file *up* toward the notch and overshooting by a few pixels sends the
cursor — and the drag — onto the 27".

This is specific to this desk and no reference app accounts for it. Mitigations,
to be validated in Phase 2 with the 27" connected:

- The drop sensor extends **downward** from the notch, not upward, so the usable
  target is entirely below the seam.
- Once armed, arming is **sticky**: a brief (~120 ms) grace period during which
  crossing to the other display does not disarm, so an overshoot-and-return still
  completes.
- Measure the real cursor-crossing behaviour before tuning these numbers. If the
  seam proves hostile, the fallback is a small dead-zone at the very top of the
  sensor.

> **On published notch tables.** Several sources list the 16" MacBook Pro notch as
> 220 × 38 pt and the 14" as 185 × 32 pt. On this 16" machine it measures
> **185 × 32 pt**, identical to the 14" figure — which is correct, because both
> panels are ~254 ppi and the camera module is physically the same size. The
> published 16" figure is wrong. This is the whole argument for measuring rather
> than tabulating.

---

## 4. The notch portal — full interaction spec

### 4.1 The hitbox guarantee

The old build's hitbox was a 370 pt always-interactive window. The new one is
structural, not incidental:

```swift
// idle — the default, and the resting state of the app
panel.ignoresMouseEvents = true
```

The window is **click-through by default** (Clicky's posture). It flips to
`false` only while a valid Finder drag is in flight, and flips straight back on
drag-end. There is no state in which an idle Sticky can intercept a click.

This matters because NotchDrop and boring.notch both leave `ignoresMouseEvents`
at its default of `false` and rely on "no SwiftUI content happens to claim those
coordinates." That is an accident of omission. Ours is an invariant, and it is
release-gated (§11).

The window is also sized tightly to the notch envelope and never spans the full
menu bar, so status items to the left and right are never covered in the first
place — belt and braces.

### 4.2 States

**Hidden** (the resting state)
- Draws zero pixels outside the physical cutout.
- `ignoresMouseEvents = true`. No hover behaviour. No idle glow. No indicator.
- Keyboard focus stays wherever it was. `canBecomeKey` and `canBecomeMain` both
  return `false`, so it cannot take focus even if something tried.
- No `NSApp.activate(ignoringOtherApps:)`. Ever. NotchDrop calls this on every
  open and it yanks focus out of Finder mid-drag.

**Approaching** — entered only when Finder is carrying files
- Detection is `.onDrop` via `NSDraggingDestination`. Event-driven. No cursor
  polling, no global monitors, no pasteboard scraping.
- The drop surface is `Color.black.opacity(0.001)`. A genuinely transparent view
  does not receive Finder drags — this is a real macOS behaviour, independently
  worked around in NotchDrop (whose author left the comment *"fuck you apple and
  0.001 is the smallest we can have"*) and mirrored in boring.notch. Separately,
  `window.alphaValue` must stay at `1`; visual transparency comes from
  `isOpaque = false` + `backgroundColor = .clear`, never from window alpha.
- Sensor extent: **16 pt** either side of the cutout, **24 pt** below it. It
  never extends above the cutout (§3.5).
- Shoulders begin growing downward; a faint magnetic glow appears.
- Nothing is drawn inside the camera region.
- Opening motion: spring, response `0.42`, damping `0.8`, ~400 ms.

**Armed** — the dragged file reaches the centre
- Width snaps to a compact portal, ≤ 320 pt. Depth below the notch ≤ 70 pt.
- One thumbnail, or a stacked-files glyph.
- Filename, middle-truncated. Or "4 files".
- Label: "Release to send to PC".
- **One** haptic, `.alignment`, on the lock. Never repeated while hovering.
- A 40–70 ms scale pulse to ~1.05×.

**Moving away**
- The lock releases immediately.
- 100 ms grace before closing, so a jittery hand doesn't cause flicker.
- Collapse ~400 ms. Dropping outside the portal does nothing at all.

**Sending**
- Stays compact. Filename, PC name, direction arrow, thin progress line.
- No large percentage counter unless the transfer exceeds two seconds.
- Progress reflects **bytes acknowledged by the receiver**, not bytes written to
  the socket. A local write buffer is not progress.
- Cancel lives in the menu bar, not as a tiny button in the notch.

**Receiving**
- Same shape opens on its own; direction visually reversed.
- Shows the Windows machine name and the filename or count.
- Lands in `~/Downloads/Sticky`, collision-safe, never overwriting.

**Success**
- Compact checkmark, "Sent" or "Received". One `.levelChange` haptic.
- Optional quiet sound, off by default.
- Visible ~900 ms, then gone completely.

**Failure**
- Compact warning glyph and a **specific** reason: "PC offline",
  "Firewall blocked", "Not enough space", "Checksum mismatch".
- Visible ~2.5 s. Menu-bar icon keeps an error badge. "Retry" appears in the menu.
- Never "Something went wrong."

### 4.3 Motion

Springs, not curves — because springs are interruptible and velocity-continuous.
Apple's own framing, from WWDC18 *Designing Fluid Interfaces*: interfaces should
be *"responsive, redirectable, interruptible."* A cubic-bezier animation has a
fixed path and must either finish or hard-cut when interrupted. That hard-cut is
a large part of what "vibecoded" looks like in motion.

**Rules:**
- Every animation re-targets from its **current presentation value**, never
  restarts from the origin. Reversing mid-flight is a first-class case, not an
  edge case — the drag can leave and re-enter twice a second and it must track.
- Asymmetric: opening is springy (`bouncy`-ish); closing is `smooth`, no bounce.
  Overshoot on something you flicked feels right; overshoot on something that
  merely faded in feels wrong.
- **All spring constants live in one file.** boring.notch has an unfixed
  `// TODO: Move all animations to this file` and constants scattered across ten
  files. We start centralized.

Apple-documented defaults, for reference: legacy `.spring()` is
`response: 0.5, dampingFraction: 0.825, blendDuration: 0`. The iOS 17+ presets
`.smooth` / `.snappy` / `.bouncy` all default to `duration: 0.5, extraBounce: 0`.

**The magnetic morph.** The Dynamic Island's merge effect is not published by
Apple, but the technique that reproduces it is a first-party API — blur the
alpha, then threshold it back to a hard edge:

```swift
Canvas { ctx, size in
    ctx.addFilter(.blur(radius: 8))
    ctx.addFilter(.alphaThreshold(min: 0.5, color: .black))
    // draw the notch body and the incoming file blob into ctx
}
```

Order matters: blur creates the gradient, threshold clips it. Two shapes near
each other fuse into one continuous form instead of overlapping. Verified to
compile on this toolchain.

**Reduce Motion.** DynamicNotchKit has zero support for this; we treat it as a
gate. Apple's HIG gives a literal checklist, and two of its five bullets hit us
directly: *"replacing transitions in x-, y-, and z-axes with fades"* and
*"avoiding animating into and out of blurs"*. So when
`accessibilityReduceMotion` is on:
- springs → 150 ms fades
- the blur/threshold morph is **disabled entirely**, not merely shortened
- geometry, content and haptics stay identical

### 4.4 Haptics

`NSHapticFeedbackManager`, called natively — no FFI. Apple's documented patterns:

| Pattern | Apple's stated purpose | Our use |
|---|---|---|
| `.alignment` | *"in response to the alignment of an object the user is dragging around"* | The lock, when the file snaps to the target. This is literally what it is for. |
| `.levelChange` | moving between discrete levels | Transfer complete. |
| `.generic` | when nothing else applies | Unused. |

Rules, from Apple's docs:
- **Never cache the performer.** *"Because the current input device may change at
  any time, you should request the default performer whenever you need to provide
  haptic feedback."* Fetch `defaultPerformer` at each call site.
- Main thread.
- Expect legitimate no-ops: *"a Force Touch trackpad won't provide haptic
  feedback if the user isn't touching the trackpad."* So a silent no-op during a
  trackpad drag is a bug; during a mouse drag it is correct.
- **Failures are recorded, never swallowed.** The old build's empty
  `catch { /* Magic Mouse */ }` made "broken" and "correctly silent"
  indistinguishable. We log which branch we took.

On this machine the hardware is confirmed capable: `ForceSupported = Yes`,
`ActuationSupported = Yes`, `ForceSuppressed = No`.

---

## 5. Menu bar

Deliberately dull. An `NSStatusItem` plus a `KeyablePanel: NSPanel` with
`[.borderless, .nonactivatingPanel]` at `.floating` — Clicky's exact pattern,
which is the right one because a menu-bar panel *does* sometimes need focus (a
text field during pairing) whereas the notch portal never does.

```
Windows PC — Connected / Offline
Send Files…
Pending Transfers            (n)
Open Received Files
Retry Last Transfer
Pair or Forget Device
─────────────────
Launch at Login              ✓
Reduced Motion               (follows system)
Quit Sticky
```

Pairing may open an ordinary window. **Settings never appear in the notch.**

---

## 6. Architecture

### macOS
- Native Swift 6 / SwiftUI, `.app`, no Electron, no FFI, no private APIs.
- SwiftUI draws the portal contents. AppKit owns the panel, drag handling,
  display positioning and haptics.
- The panel is created **once**, sized to the largest envelope it will ever need
  — open portal **plus shadow padding plus animation overshoot** — and never
  resized. `setFrameOrigin` only. This is the single most important structural
  decision, and it is where Atoll regressed from boring.notch.
  - Reason: an `NSWindow`'s `contentView` bounds is a **hard clip** that SwiftUI
    cannot draw past. A spring that overshoots to 1.05×, or a shadow with a 20 pt
    blur, will be sliced off at the window edge. boring.notch reserves
    `shadowPadding = 20` for exactly this. That is the mechanism behind "text and
    borders clipped" in the old build.
- Window posture (§2), collection behaviour
  `[.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]` — the
  same four flags in every shipping notch app I read.
- Level: `.statusBar + 8`. Above the menu bar band, well below `.popUpMenu`/
  `.screenSaver` (101). Note: a macOS 26.3 regression is reported where windows
  at very high levels intercept events across their whole transparent area, so we
  stay low and keep the window small.
- One process provides both the portal and the menu-bar item.
- **Unsandboxed, Developer ID + notarized + stapled.** Not App Store. Hardened
  Runtime on.

### Windows
- **WPF on .NET 9** with `H.NotifyIcon.Wpf`.
  - Not WinUI 3: it has **no tray-icon API at all** (the request has sat open on
    `microsoft-ui-xaml` for years) and has documented drag-drop rough edges on
    borderless/topmost windows. Those are our two most critical features.
  - WPF's drag-drop and tray plumbing are twenty-year-old, boring, Win32-backed
    code. That is exactly the mandate.

**A finding that changes the design: you cannot drop files onto a Windows tray
icon.** The notification area has no drop-target message — a tray icon is a
bitmap in a strip owned by `explorer.exe`, not an `HWND` that can register
`WM_DROPFILES` or an `IDropTarget`. Microsoft has also stated drag-to-open onto
taskbar buttons is unsupported on Windows 11. There is no API to hook.

So the Windows send path is three layered affordances:
1. **A small always-on-top drop widget** — a real borderless `HWND` with
   `AllowDrop = true`. This is the Windows analogue of the notch and the primary
   gesture.
2. **A "Send to Mac" Send To shortcut** — a `.lnk` in `shell:sendto`. Zero admin,
   zero registry, and standard Windows UX for twenty years.
3. **An Explorer context-menu entry** via `HKCU\Software\Classes\*\shell\` — no
   admin needed. On Windows 11 it lands under "Show more options"; that is one
   extra click, not a broken feature. The `IExplorerCommand` + sparse-MSIX route
   that would promote it to the top level is a large lift for one click saved —
   explicitly deferred.

- Toasts: `Microsoft.Windows.AppNotifications` (Windows App SDK). The old
  CommunityToolkit path is deprecated. Critically, `Register()` now handles COM
  registration automatically for **unpackaged** apps — the historic
  AppUserModelID/Start-Menu-shortcut dance is no longer required. Notifications
  do not work from elevated processes, so the tray app runs as standard user.
- Autorun: `HKCU\...\CurrentVersion\Run`. Visible and disableable in Settings →
  Startup, unlike a scheduled task. **Only write the value when the stored path
  actually differs** — an app that rewrites its own Run key on every launch trips
  a documented Defender heuristic (`Trojan:Win32/Wacatac.G!ml`).

### Shared
One written protocol document and one shared corpus of test vectors. Neither side
independently guesses at: size limits, folder semantics, error codes, pairing
fields, progress accounting, or filename collision rules.

---

## 7. Network — local-first, v1

Same LAN. No account, no cloud, no relay, no third party.

**Discovery: our own UDP multicast announce, not mDNS.** This is a deliberate
reversal of the obvious choice, on evidence:
- Windows has no general-purpose mDNS responder available to Win32/.NET apps.
- Apple's Bonjour (`mDNSResponder.exe`, shipped with iTunes) binds UDP 5353 and
  can contend with a third-party responder.
- Every .NET mDNS library is a third-party maintenance risk.
- **LocalSend does not use mDNS either** — it runs its own UDP multicast
  announce/response protocol for precisely these reasons.

So: a small JSON announce on a multicast group, periodic, with a TCP/HTTPS
subnet-scan fallback for networks that drop multicast. ~100 lines we own and can
debug, which fits the mandate better than a dependency we cannot fix.

**Transport shape:** LocalSend's, which is well proven — `prepare-upload`
(declaring files, sizes and SHA-256) → `upload` per file → `cancel`. Reverse
endpoints for the pull direction. One port number for both TCP and UDP, so the
firewall story is a single number.

**When the PC is offline:** Sticky says "PC offline". The transfer becomes
**pending**, never a silent success. Files are held in app-managed temporary
storage where safely possible. Pending items are visible and cancellable in the
menu.

**Reconnection:** event-driven first — `NWPathMonitor` on macOS and
`NetworkChange` on Windows fire an immediate reconnect on network change or wake
— with a flat 30–60 s retry timer underneath as a dumb fallback. This is
deliberately *better* than Syncthing, which relies on the polling interval alone
and has open issues about 5–15 minute post-wake reconnection gaps.

**Address changes:** never cache an IP. Forget the dead address, re-run
discovery, redial. Target: a successful transfer within **30 s** of both devices
becoming reachable.

**Windows firewall — the real cause of "it only worked one way".** Outbound is
allowed by default on all profiles; inbound on a **Public**-classified network is
dropped silently at the WFP layer. `TcpListener.Start()` still succeeds — the
bind is fine, it's the inbound SYNs that never arrive. So the Windows box works
perfectly as a *client* and fails silently as a *receiver*. That asymmetry is
exactly the reported bug.

Mitigations, all three:
1. Start the listener at first launch so the OS prompt fires once, early, while
   the user is present — not at the moment of the first inbound transfer.
2. Ship an elevated installer step that pre-creates an inbound rule scoped to the
   **program path** (not the port) across Private + Public:
   ```
   netsh advfirewall firewall add rule name="Sticky" dir=in action=allow ^
     program="C:\Program Files\Sticky\Sticky.exe" enable=yes profile=any
   ```
3. Detect and explain. Query the network category via `INetworkListManager`; if
   it reads Public, show a banner *before* a transfer fails. Pairing performs a
   real inbound round-trip as a self-test and reports "Windows Firewall may be
   blocking incoming files" rather than a generic timeout.

**Size ceiling:** the old build claimed 8 GB in its README with `MAX_BYTES = 8 *
1024**3` and no verification. v1 ships an honest, tested ceiling and raises it
only after large-transfer and disk-space tests pass.

---

## 8. Pairing and security

The old build had none of this. It is not polish; it closes a remote file-write
hole on any shared network.

**Identity — Syncthing's model, the cleanest of the three studied.** A device's
ID *is* the SHA-256 of its own self-signed certificate. You cannot forge an ID
without the matching private key, so the ID is self-verifying and there is no
separate pin database to keep in sync.

**First pairing (TOFU with a human in the loop):**
1. Both devices display their names.
2. A six-digit code derived from both fingerprints appears on both screens.
3. The human confirms the codes match, on both machines.
4. Each stores the other's certificate fingerprint permanently.

**After pairing:** no PIN, no prompts, no Accessibility, no Keychain dialog.

**Mutual TLS with fingerprint pinning on both ends.** Not just the client — the
receiver validates the sender's certificate too. LocalSend does *not* do this
(its fingerprint is opportunistic; the human accept-dialog is the real gate),
which is why an unpaired device on the LAN can still prompt you. Ours refuses at
the TLS layer.
- Swift: `sec_protocol_options_set_verify_block` on `NWProtocolTLS.Options`,
  comparing the leaf certificate's SHA-256 against the pin. Default chain
  validation is replaced, not augmented — a self-signed cert will never pass it.
- .NET: `RemoteCertificateValidationCallback` on both
  `SslClientAuthenticationOptions` and `SslServerAuthenticationOptions`. Compute
  the hash explicitly with `GetCertHash(HashAlgorithmName.SHA256)` — do not use
  `Thumbprint`, which is SHA-1 on older APIs.

**Key storage — and specifically, no launch prompt.**
- The repeated *"wants to use your confidential information stored in Keychain"*
  dialog is almost always caused by an **unstable code signature** (ad-hoc or
  changing between builds, so macOS cannot recognise the app as the same one), or
  by deleting-and-recreating the item on each write, which discards the ACL.
- So: sign every build the user runs with a **stable Developer ID**; create the
  item with a plain accessibility constant and **no** `SecAccessControl` flags
  (`.userPresence`/`.biometryAny` exist to *force* interactive auth — they are
  the wrong tool here); and `SecItemUpdate` in place rather than delete+add.
- Windows: DPAPI `ProtectedData.Protect(..., DataProtectionScope.CurrentUser)`
  with per-install entropy, written under `%LOCALAPPDATA%`, plus a restrictive
  ACL (`SetAccessRuleProtection(isProtected: true, preserveInheritance: false)`,
  current user only) as defence in depth. Not Credential Manager — it caps blobs
  at 2,560 bytes and has no maintained first-party .NET wrapper.

**Receiving files:**
- Stream to a temp file **in the destination directory** — atomic rename only
  works within one volume; cross-volume degrades silently to copy+delete.
- Verify SHA-256 **before** the rename. Never expose a file at its final name
  until it is verified.
- `fsync` the file, rename, then `fsync` the directory.
- On Windows use `ReplaceFile` / `MoveFileEx` with
  `MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH` — plain `File.Move` is
  **not** guaranteed atomic. Retry with backoff for ~1 s: antivirus and Search
  indexing routinely hold a transient lock on a just-written file.
- Reject `../` traversal and absolute paths.
- Clean up orphaned `.part` files on launch.
- Decide deliberately about the `com.apple.quarantine` xattr — a file moving
  between two of the user's own machines arguably should not be quarantined.

**Filename rules (both directions), from the old test vectors plus what they
missed:**
- Reserved names `CON PRN AUX NUL COM1-9 LPT1-9` — illegal **with any extension**
  (`NUL.txt` collapses to `NUL`). Prefix with `_`.
- Illegal characters `< > : " / \ | ? *` and control chars U+0000–U+001F.
- Strip trailing dots and spaces explicitly. Windows strips them silently on
  normal paths but *preserves* them under `\\?\`, creating files Explorer cannot
  open.
- Case-insensitive collision check before writing; auto-rename `name (2).ext`,
  and **log the rename** rather than silently overwriting.
- **Unicode normalization — the one the old build missed entirely.** macOS emits
  **NFD** (`é` = `e` + U+0301); Windows/NTFS convention is **NFC** (`é` = U+00E9).
  NTFS does no normalization of its own, so the two are byte-different strings
  that look identical and break `File.Exists` and collision logic. Normalize to
  NFC once, at the Windows write boundary:
  ```csharp
  string safe = incoming.Normalize(NormalizationForm.FormC);
  ```
  Windows → Mac needs nothing; APFS handles NFC input correctly.
- MAX_PATH: .NET 5+ already bypasses the 260-char check for `System.IO`. Ship the
  `longPathAware` manifest anyway for native interop. Individual path components
  are still capped at ~255 chars by NTFS.

---

## 9. Clipboard

**Cut from v1.** It caused the product confusion (the old README describes a
paste pill, not a file portal), and it is the direct reason the old build wanted
Accessibility and synthetic keystrokes. The notch is a file portal.

If it ever returns: an explicit "Send Text to Mac/PC" action. Never a watcher on
either system clipboard. Receiving text does not replace the clipboard — the user
presses Copy.

---

## 10. Visual direction — how we avoid looking vibecoded

### 10.1 The references, and what each one settles

| Reference | Verdict |
|---|---|
| **Nook / Tray** (small black tray, dashed drop region, thumbnail row) | **This is the target.** Small, black, one job, legible at a glance. Compact tab pills, a dashed inner boundary that reads as "put things here", file thumbnails in a single row with two-line truncated names, one item lifted on hover. Everything Sticky needs and nothing it doesn't. |
| **MediaMate** | The right *proportion* for the compact pill — content sits in a short, wide band directly under the cutout, never encroaching on the camera. |
| **The dock + Support panel** | Over-scoped, as you said. Take the surface craft — the near-black panel, the restrained icon row, the way the popover hangs off a strip — and drop the ambition. |
| **[macnotch.io](https://macnotch.io/)** | The counter-example. "Your notch, your productivity hub", with Media, Notifications, Calendar, Tasks, Bluetooth, System HUD, Pomodoro, Session Lock as modules. This is exactly what old Sticky drifted into. Nice pills; wrong product. |

**The rule this yields:** Sticky's portal is a *tray that appears when it has a
reason to*. It borrows Nook's visual language — dashed drop boundary, thumbnail
row, compact pill — but never persists. Close the transfer and it is gone.

Multi-file transfers render as that thumbnail row. Single-file is one thumbnail
plus a name. That's the whole visual vocabulary.

### 10.2 The pure-black rule

The notch area is **physically black hardware**. Anything that touches the bezel
must be flat `#000` — no material, no blur, no near-black.

This is settled by DynamicNotchKit's own source, which fills the shape touching
the bezel with flat `.foregroundStyle(.black)` while using a separate
`NSVisualEffectView` for panel content that genuinely floats over the desktop.
The authors drew exactly this distinction.

So Clicky's beautiful `#101211` surface ramp is **right for the menu-bar panel**
and **wrong for the notch body**. A near-black that reads as premium against a
desktop wallpaper reads as a visible grey rectangle stuck to a black bezel.

- Notch body: `#000000`, flat, no material.
- Menu-bar panel: a Clicky-style near-black ramp with `NSVisualEffectView`.

### 10.3 Corners

- Every rounded rect uses `style: .continuous` — Apple's superellipse, curvature-
  continuous. `.circular` has a curvature discontinuity where the arc meets the
  edge and it reads as "off" without the viewer knowing why.
- **Concentric corner rule:** a nested element's radius is
  `outerRadius − padding`. macOS 26 gives us `ConcentricRectangle` to do this
  automatically (verified available on this toolchain); where it can't be used,
  the arithmetic is explicit, never eyeballed.
- The notch silhouette itself uses the hand-built `NotchShape` (§3.3), because
  no public API draws a concave corner.

### 10.4 Typography

- System font throughout. macOS HIG: Headline 13 pt semibold, Footnote 10 pt,
  **11 pt is the floor for readable UI text.** Nothing in the portal goes below
  11 pt.
- Filenames: `.lineLimit(1)` + `.truncationMode(.middle)`. Middle, not tail —
  because the extension and the disambiguating tail of a filename carry the
  information, which is why Finder truncates the same way.
- **Never `.minimumScaleFactor`.** It makes text shrink as content changes and is
  a primary source of the "everything wobbles" look.
- `.monospacedDigit()` on anything numeric that updates — byte counts, percent,
  elapsed time. Without it, digit-width changes make the layout jitter every
  frame.
- Reserve layout width for the longest state so nothing reflows mid-transfer.

### 10.5 Icons

- SF Symbols only. **Never emoji.** Emoji in place of symbols is the single
  fastest visual tell of a machine-made interface.
- Symbol weight matches adjacent text weight. A semibold label next to a regular
  glyph looks broken even when nothing is technically wrong.
- Size with `.imageScale` / font size, not hardcoded frames.

### 10.6 The tells we are explicitly banning

From the design-critique research, the list of things that make an interface read
as machine-generated — all banned in this codebase:

purple-to-blue gradients · emoji as icons · uniform 8 px everything · excessive
corner radius · drop shadows on flat surfaces · glassmorphism applied
indiscriminately · more than one accent colour · mixed icon weights · centred
everything · generic sans-serif in place of the system font

The positive inverse, which is what disciplined native macOS UI actually does:
one accent colour, a deliberate spacing scale rather than a single repeated
value, optical rather than mathematical alignment, materials only where content
genuinely floats, and shadows only where something is genuinely lifted.

### 10.7 The token file, and the lint that enforces it

Clicky's `DesignSystem.swift` is the pattern: a single `DS` namespace holding
`Colors`, `Spacing`, `CornerRadius`, `Animation` and `StateLayer`, with every
value named and sourced. Nothing in a view computes its own colour or radius.

Sticky ships the same, plus a **CI lint** that fails the build on:
- a literal colour in any view file
- a literal corner radius or spacing value in any view file
- a hardcoded notch dimension anywhere (§3.2)
- any spring constant declared outside the animation file
- `NSEvent.addGlobalMonitorForEvents`, `CGEvent.tapCreate`, `AXIsProcessTrusted`,
  `globalShortcut`, or `osascript` anywhere in the tree

That last rule is the one that makes the keyboard promise structural rather than
a matter of everyone remembering. NotchDrop avoids Accessibility purely by never
having added it — one careless contributor away from regression. Ours fails CI.

### 10.8 Frame-by-frame QA checklist

Run against a screen recording, at normal speed and stepped:

- [ ] Notch edge aligns to the physical cutout with **no** grey seam on either side
- [ ] Corner joins are continuous — no visible curvature break where arc meets edge
- [ ] No sub-pixel shimmer on any edge during the whole animation
- [ ] No clipped descenders (g, y, p) at any size
- [ ] No clipped shadow at the window boundary
- [ ] Nothing enters the camera region at any frame
- [ ] Text baselines align across the row
- [ ] Optical spacing is even — not merely mathematically equal
- [ ] Progress line does not jitter as digits change width
- [ ] Reversing the drag mid-animation tracks smoothly; no snap, no restart
- [ ] Idle state draws literally zero pixels outside the cutout

A full write-up of the visual research — squircle math, HIG type sizes, SF Symbol
rendering modes, the concentric-corner rule, and the sourced code behind each —
is here: https://claude.ai/code/artifact/6fd5c194-1807-44a2-b54d-745f13f78d2f

### 10.9 The file-chip pattern (from the Nook Tray references)

The Tray screenshot is Sticky's exact use case already drawn, so we take its
vocabulary directly rather than inventing one:

- **File chip:** a rounded square (`.continuous`), SF Symbol glyph centred in the
  upper area, filename beneath in ~11 pt, middle-truncated. One chip per file.
- **Accent stroke:** a thin cool-cyan hairline around each chip on near-black.
  Exactly **one** accent colour in the whole surface — this is what keeps it
  looking engineered rather than decorated.
- **Dashed inset container** holding the chip row. This is the affordance that
  says "things go here" without a word of copy, and it is why the Tray reads
  instantly.
- **A small floating action row** below the tray — round buttons, evenly spaced,
  one job each. Sticky's version is at most: send, clear, cancel.
- Chips sit in a **single row**. No wrapping, no grid. Overflow scrolls
  horizontally or collapses to "+3".

The Snippets screenshot is the other end of the scale — masonry cards, a FAB, a
numbered history column. That is the MacNotch direction, and it is out of scope.
Same app, same craft, wrong size for what Sticky does.

**Type and glyph sizes** for the chip row are taken from macOS HIG: filename at
11 pt (the readable floor), glyph weight matched to it. Nothing smaller.

---

## 11. Build order

Each phase has an exit condition. The next phase does not start until it passes.
The ordering exists to stop the specific failure of the old build: polish applied
to a foundation that didn't work.

### Phase 1 — Clean foundation
Branch `rebuild/native` off `main` in the existing repo. History preserved.
- Delete the Electron app, the clipboard/paste subsystem, `inject.ts`,
  `haptic.ts`, `notch.ts`, the global shortcut, the Accessibility request, the
  cursor polling, and the `fx` window.
- Keep the `sanitizeRel` test vectors; port them to both new test suites.
- Scaffold: Swift package + Xcode project; .NET 9 WPF solution.
- Land the CI lint from §10.7 **first**, so the forbidden APIs can never come back.

**Exit:** both apps build from a clean checkout. `grep` for `globalShortcut`,
`AXIsProcessTrusted`, `osascript`, `CGEvent`, `addGlobalMonitorForEvents`,
`koffi`, `_setCanExcessOverlap` returns nothing. CI enforces it.

### Phase 2 — Hardware-perfect shell (no networking at all)
Only the notch geometry and real Finder drop handling. Transfers are faked.
- `NotchGeometry` as the single source of truth.
- Fixed oversized panel; content animates inside it.
- All six states driven by a mock transfer.

**Exit:**
- Zero idle pixels outside the physical cutout, verified by screenshot diff.
- Nothing ever drawn under the camera.
- Menu-bar items left and right of the notch remain clickable, verified by
  clicking them while Sticky runs.
- `ignoresMouseEvents` is `true` in every non-drag state, asserted in a test.
- Real Finder files arm and drop reliably, 20 consecutive times.
- Passes on: built-in alone; **built-in with the 27" mounted above** (§3.5);
  clamshell; and after a sleep/wake cycle.

### Phase 3 — Prove transfer before any polish
- Mac sends a known file to Windows. Windows sends it back.
- SHA-256 must match at every hop.
- Repeat with: spaces, Unicode (NFD *and* NFC forms of the same name), reserved
  names, trailing dots, duplicate names, an empty file, a 4 GB file.
- Folders, both directions, identically.

**Exit:** both directions pass repeatedly, on the same pair of builds, on a real
LAN. Not simulated, not loopback.

### Phase 4 — Pairing and hostile cases
- Pair, restart both apps, reconnect with no second code.
- Every unpaired operation is refused at the TLS layer.
- Wrong PIN; copied certificate; malformed filenames; insufficient disk space.
- Windows private key correctly DPAPI-protected and ACL'd.

**Exit:** an unpaired machine on the same LAN can do nothing at all.

### Phase 5 — Lifecycle reliability
Sleep/wake both machines. Change Wi-Fi. Change IP. Disable the Windows firewall
rule. Disconnect mid-transfer. Reconnect with pending items. Cancel and verify
temp-file cleanup.

**Exit:** recovery works without restarting either app. Reconnect within 30 s.

### Phase 6 — Motion and Windows polish
**Only now** the magnetic morph, lock pulse, progress motion and haptics. The
Windows tray gets matching language, icons, progress and failure reasons.

### Phase 7 — Three-critic release loop
Every release candidate reviewed by three separate passes:
1. **Visual** — the §10.8 checklist, frame by frame.
2. **Reliability / security** — pairing, retries, corruption, sleep, firewall.
3. **First-time user** — install, pair, transfer, without prior knowledge.

Rejections return to the owning phase. The loop ends when the gates pass, not
when the app compiles.

---

## 12. Release gates

Not done until every one of these is recorded on the real machines.

**Permissions and input**
- [ ] Ten cold launches, no Accessibility prompt, no Keychain prompt, no
      private-key prompt
- [ ] Typing in another app continues uninterrupted while Sticky opens and
      transfers
- [ ] No global shortcut is registered by Sticky at any point
- [ ] CI lint for forbidden APIs is green

**Notch**
- [ ] Zero idle pixels and zero hitbox outside the physical cutout
- [ ] No text, icon or border ever enters the camera region
- [ ] Real Finder drag/drop succeeds 20 times consecutively
- [ ] Correct on external-above-built-in, clamshell, and after display changes
- [ ] Reduce Motion produces fades, no blur animation, identical geometry

**Transfer**
- [ ] Mac → Windows and Windows → Mac hashes match
- [ ] Files, folders, Unicode (NFD and NFC), reserved names and duplicates behave
      identically both ways
- [ ] Progress reflects receiver-acknowledged bytes
- [ ] A failed or cancelled transfer leaves no file at the destination name
- [ ] Orphaned `.part` files are cleaned up on next launch

**Network**
- [ ] Sleep/wake recovery works
- [ ] IP change recovery within 30 s
- [ ] Offline sends clearly queue or clearly fail — never silently vanish
- [ ] Firewall and disk-space errors name the actual cause
- [ ] An unpaired device on the same LAN can neither send nor read

**Craft**
- [ ] A screen recording passes the §10.8 checklist at normal speed and stepped

---

## 13. Research ledger

Research is done. This records what is settled so nobody re-litigates it, and —
more usefully — what research *cannot* answer, so those go to Phase 2 as
prototype tasks rather than as more reading.

### Settled — do not re-research

| Question | Answer | Evidence |
|---|---|---|
| Notch geometry on the target Mac | 185 × 32 pt; origin from `auxiliaryTopLeftArea.width`; 0.5 pt left of centre | Measured directly (§3.1) |
| Published notch tables | Wrong for the 16" (they say 220 × 38) | Contradicted by measurement |
| Notch silhouette path | Kai Azim's `NotchShape`, two quad curves per side | Read in three codebases, byte-identical |
| Window posture | Clicky's `OverlayWindow` + `canBecomeKey/Main = false` | Source read (§2) |
| Collection behaviour | `[.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]` | Identical in every shipping notch app read |
| Transparent view misses Finder drags | Real; needs `opacity(0.001)`, and `window.alphaValue` must stay `1` | NotchDrop + boring.notch, independently |
| Drop-in-a-tray-icon on Windows | **Impossible.** No drop-target message exists | Microsoft statements + API surface |
| Windows framework | WPF + `H.NotifyIcon.Wpf`; WinUI 3 has no tray API at all | MS issue tracker |
| Discovery mechanism | Own UDP multicast, not mDNS | Windows has no usable responder; LocalSend reached the same conclusion |
| Why transfers went one-way | Windows Public-profile inbound is dropped silently at the WFP layer; `TcpListener.Start()` still succeeds | MS docs |
| Identity model | Device ID = SHA-256 of own self-signed cert | Syncthing |
| Keychain launch prompts | Caused by unstable code signature or delete+recreate, not by accessibility constants | Apple docs + forums |
| Haptic pattern for a drag lock | `.alignment` — Apple documents it for exactly this | Apple docs |
| Reduce Motion obligations | Apple's 5-bullet HIG checklist; two bullets hit us | HIG, quoted |
| macOS 26 APIs available here | `ConcentricRectangle`, `.continuous`, `Canvas`+`alphaThreshold`, `glassEffect` | Compiled against `arm64-apple-macos26.0` |
| NFD/NFC filename corruption | Real; normalise to NFC at the Windows write boundary only | MS docs + Unicode UAX-15 |

### Unresolved — and only a prototype can settle them

These are Phase 2 spike tasks, each timeboxed. **Do not answer them with more
web research.**

1. **The 27"-above-the-notch seam.** How does the cursor actually behave crossing
   the top edge mid-drag, and does the 120 ms sticky-arm grace hold? Needs the
   second display physically connected. This is the single biggest unknown and
   nothing published covers it.
2. **Does `opacity(0.001)` still work on macOS 26.5?** Every source for this is
   from older releases. Verify on this exact OS before designing around it, and
   find the actual threshold.
3. **Haptic timing under a live drag.** Apple documents that feedback is
   suppressed when the user is not touching the trackpad. During a drag they
   *are* touching it — confirm the lock haptic actually fires, and that it does
   not double-fire on re-entry.
4. **The 0.5 pt centring offset on the 27".** Confirmed on the built-in panel;
   check whether an external display's geometry introduces its own rounding.
5. **Menu-bar clickability under our exact window.** Every reference app relies
   on "nothing happens to claim those pixels." We assert `ignoresMouseEvents`
   instead — verify by clicking every status item with Sticky running.
6. **Real throughput and the honest size ceiling** on this LAN, which sets the
   v1 limit (§15.2).
7. **macOS 26.3+ overlay regression.** A reported regression makes high-level
   windows intercept events across their whole transparent area. We sit at
   `.statusBar + 8`, below the affected range — confirm on 26.5.

---

## 14. How this gets built — Codex and subagents

The work is executed by agents. That is a constraint on how the plan is written,
not an afterthought: every phase gate above is machine-checkable on purpose.

### 14.1 Repo files that make agents behave

These now exist in the repo — they are not aspirational:

- **[`AGENTS.md`](AGENTS.md)** — the contract every agent reads first: banned
  APIs, the geometry law, scope discipline, drag handling, error rules. Short and
  absolute; the rationale lives here in PLAN.md.
- **[`docs/TASKS.md`](docs/TASKS.md)** — ~30 task cards with IDs, dependencies,
  single-owner markers and a machine-checkable gate each. This is the work queue.
- **[`docs/PROTOCOL.md`](docs/PROTOCOL.md)** — the wire format, in full: ports,
  identity, discovery, pairing, the prepare/upload/cancel/progress endpoints,
  status codes, and the receiver-side filename sanitiser with its test vectors.
- **[`docs/ICONS.md`](docs/ICONS.md)** — every icon, each one verified to resolve
  (61/61 on this OS via `scripts/symcheck.swift`), plus the Windows mapping.
  SF Symbols are licensed for Apple platforms only, so Windows uses Lucide (ISC).
- **[`scripts/lint.sh`](scripts/lint.sh)** — the rules, enforced. Runs clean on
  the tree today and fires on all nine rule classes against a probe file.

### 14.2 The lint is the real supervisor

The §10.7 CI lint exists because agents optimise for the immediate task. An agent
told "make the notch open when a drag starts" will reach for a global mouse
monitor, because that is the most obvious solution and three reference codebases
do it. The lint is what makes that impossible rather than merely discouraged.

Banned outright, failing CI: `addGlobalMonitorForEvents`, `CGEvent.tapCreate`,
`AXIsProcessTrusted`, `globalShortcut`, `osascript`, `NSApp.activate`, `dlopen`,
any `_`-prefixed selector, literal colours and radii in view files, hardcoded
notch dimensions, spring constants outside the animation file.

### 14.3 Decomposition

Phases are sequential and gated; **work inside a phase parallelises**.

| Phase | Parallel tracks | Notes |
|---|---|---|
| 1 | (a) strip Electron · (b) Swift scaffold · (c) .NET scaffold · (d) CI lint | (d) merges first |
| 2 | (a) `NotchGeometry` + shape · (b) panel + hitbox · (c) state machine on mock data · (d) menu-bar item | (a) blocks (b) and (c) |
| 3 | (a) protocol impl Mac · (b) protocol impl Windows · (c) round-trip harness | Both read `docs/PROTOCOL.md`; (c) written **first**, by a third agent |
| 4 | (a) pairing UX · (b) TLS pinning both sides · (c) hostile-input suite | |
| 5 | (a) reconnect logic · (b) firewall detection · (c) lifecycle test matrix | |
| 6 | (a) motion · (b) haptics · (c) Windows polish | Single owner for (a) — motion by committee is how it starts looking vibecoded |
| 7 | three critics in parallel | |

### 14.4 Rules for delegated work

- **The test harness is written before the implementation, by a different agent.**
  Phase 3's round-trip harness is authored by an agent that has not seen either
  transport implementation. An agent that writes both the code and its test will
  write a test the code passes.
- **No agent implements both sides of the protocol.** Two independent readings of
  `docs/PROTOCOL.md` is the point — it catches ambiguity in the spec, which is
  where cross-platform bugs live.
- **Geometry, security, and motion are single-owner.** These are the three areas
  where a merge of two reasonable approaches produces something incoherent.
- **Every task states its gate.** Not "make the notch look good" but "zero pixels
  outside the cutout in a screenshot diff; assertion passes." A task without a
  machine-checkable exit condition does not get delegated.
- **Screenshot diffs, not opinions.** Phase 2 and 6 verification is a captured
  frame compared against a reference, because "looks right" does not survive
  delegation.
- **Errors are never swallowed.** The old build had 13 empty catch blocks. Any
  new empty catch fails review. If a failure is genuinely expected, it is logged
  with which branch was taken (§4.4).

### 14.5 What is never delegated

- The decision in §15.6 (transient portal vs. persistent tray) — product shape.
- Accepting a phase gate. A gate is passed when the evidence exists, and a human
  looks at the evidence.
- Anything that would add a permission prompt. If an agent concludes it needs
  Accessibility, that is escalated, not implemented.

### 14.6 Escalation

Three strikes: an agent that fails the same gate twice stops and writes up what
it tried. It does not try a third approach unsupervised — that is how the private
`_setCanExcessOverlap:` selector got into the old build.

---

## 15. Decisions — locked

These were open. They are now settled so the build can start. Any of them can be
reopened, but not by silence — someone has to argue against them.

**15.1 Visual direction: v8.** White light only — there is no accent colour in
this app. The spill borrows its hue from the file's own pixels, the way the
Dynamic Island borrows album art. The notch is elastic: it extends 3pt on hover,
8pt tall and 14pt wide when armed, with both corner radii animating as
`animatableData`, and settles with a small overshoot. Motion is 44-sample
exposure blur, never a `scaleY` stretch.

**15.2 The five metaphor concepts are dead.** Mechanical aperture, liquid
coalescence, pure light, magnetic field, physical post — all rendered, all
rejected. Two failed on execution (liquid softens the notch itself; the iris is
invisible at 24pt) and the rest read as *themed* rather than native. Apple's
actual language is restrained and physical without being metaphorical. The
research is kept in `docs/CONCEPTS.md`; the direction is not.

**15.3 The literal NameDrop screen-warp is OUT of v1.**
NameDrop bends the whole top of the screen because the OS is distorting its own
pixels. A third-party overlay cannot do that. Verified on this machine:
- `screencapture` is blocked without a Screen Recording grant, so any
  capture-based approach needs a permission prompt and a permanent purple
  menu-bar indicator. Banned by AGENTS.md §1.
- `CALayer.backgroundFilters` still *accepts and retains* a `CIBumpDistortion`,
  and all twelve distortion filters are present — but it is documented as having
  broken around Big Sur, custom filters stopped compositing in 12.5, and there is
  no authoritative statement for macOS 26.
- `NSVisualEffectView.behindWindow` **is** supported, which proves the OS samples
  the desktop behind a window with no app permission. Backdrop sampling is not
  the barrier; supplying our own filter is.
- `NSGlassEffectView` exists with public `cornerRadius`, `style`, `tintColor`,
  `contentView` — and a private `_path` we will not touch.

**The call:** do not build the signature moment on `backgroundFilters`. It is
undocumented-adjacent behaviour that may already be dead and can die on any OS
update — precisely the failure that put a private `_setCanExcessOverlap:`
selector in the old build. Liquid Glass refraction is the sanctioned path and
goes in **Phase 6 as an enhancement, never a dependency**. If it works, the
portal gains a real backdrop bend. If it doesn't, v1 is unaffected.

**15.4 The portal is transient, with in-flight batching.** It appears on drag,
accepts further files dropped onto an transfer already in flight, and is gone
when the transfer completes. No persistent tray. This keeps the chip row and the
gather-then-send workflow without a stateful surface that can drift back into
being a dashboard.

**15.5 Windows drop target: an always-visible edge tab**, bottom-centre, sitting
directly above the taskbar and horizontally aligned to the Mac's notch. Not
appears-on-drag — that needs a low-level mouse hook, which is added complexity
and AV suspicion for a discoverability gain we can get with a small permanent tab.

**15.6 v1 transfer ceiling: 2 GB**, tested, raised only after the large-file and
disk-space gates pass. The old build's unverified 8 GB claim is not inherited.

**15.7 Repo: branch `rebuild/native`**, history preserved, merged to `main` when
the Phase 3 round-trip gate passes.

**15.8 The name stays "Sticky" for now.** It is the wrong name — it describes
things that adhere and stay, and this is about a crossing — but renaming is not
blocking and the repo, remote and docs all reference it. Revisit before any
public release.

---

## 16. Still genuinely open

Only two, and neither blocks Phase 1 or 2:

1. **Does Liquid Glass refract the desktop from an overlay panel?** Decides
   whether §15.3's Phase 6 enhancement is possible at all. A live-window spike,
   not more reading.
2. **The 27" seam.** How the cursor behaves crossing the display boundary
   mid-drag, and whether the 120 ms sticky-arm holds. Needs the second display
   connected. Already SPIKE-2A in `docs/TASKS.md`.
