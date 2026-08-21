# Task cards

One card = one agent = one branch = one gate. A card without a machine-checkable
gate does not get delegated — ask for one first.

`⊘ single-owner` means do not split this across agents; merging two reasonable
approaches here produces something incoherent.

Read `AGENTS.md` before starting anything.

---

## Phase 1 — foundation

### T-101 · Land the lint ⊘
**deps** none · **first merge, before anything else**
Wire `scripts/lint.sh` into CI on every push and as a pre-commit hook.
**Gate** `scripts/lint.sh` exits 0 on a clean tree and exits 1 with a named
violation for each of the 9 rules (verify with a throwaway probe file, then
delete it).

### T-102 · Strip the Electron build
**deps** T-101
Delete `src/`, `electron.vite.config.ts`, `package.json`, `package-lock.json`,
`resources/`, `build/`. Keep `.github/` (rewritten in T-105).
**Gate** `grep -rE 'globalShortcut|AXIsProcessTrusted|osascript|koffi|_setCanExcessOverlap|electron'`
returns nothing outside `AUDIT.md`.

### T-103 · Swift scaffold
**deps** T-102
`mac/` — SwiftUI app, macOS 26 target, the folder layout in AGENTS.md §7, a
`LSUIElement` accessory app with no Dock icon and no main window.
**Gate** `swift build` succeeds; the app launches, shows a status item, and
`log stream` shows no permission prompt.

### T-104 · .NET scaffold
**deps** T-102
`win/` — .NET 9 WPF, `H.NotifyIcon.Wpf`, tray icon, no main window,
`longPathAware` in the manifest.
**Gate** `dotnet build` succeeds; tray icon appears; app runs as standard user.

### T-105 · CI
**deps** T-103, T-104
Two-job matrix (macos-latest, windows-latest): lint → build → test.
**Gate** green on a clean push.

### T-106 · Port the sanitiser + vectors
**deps** T-103, T-104 · **two agents, one per platform, neither sees the other's code**
Implement `docs/PROTOCOL.md` §8.1 exactly. Vectors are in that section.
**Gate** identical vector table passes on both platforms, including the NFD→NFC
case (`café.pdf` must be 9 bytes on the wire, not 10) and `NUL.txt` → `_NUL.txt`.

---

## Phase 2 — hardware-perfect shell (no networking)

### T-201 · NotchGeometry ⊘
**deps** T-103
The single source of every coordinate. Runtime measurement per AGENTS.md §3,
UUID-keyed displays, 250 ms debounced `didChangeScreenParametersNotification`.
**Gate** unit test asserts, on the built-in display: width `185.0`, height `32.0`,
originX `771.0`, and `originX != frame.midX - width/2`. Handles a nil
`auxiliaryTopLeftArea` by reporting no-notch rather than crashing.

### T-202 · Panel + hitbox ⊘
**deps** T-201
`NSPanel`, `[.borderless, .nonactivatingPanel]`, level `.statusBar + 8`,
collection behaviour per AGENTS.md, `canBecomeKey/Main = false`,
`ignoresMouseEvents = true` by default. Created once at max envelope
(open portal + 20 pt shadow + overshoot), never resized.
**Gate** (a) test asserts `ignoresMouseEvents == true` in every non-drag state;
(b) `setFrame` appears nowhere outside init; (c) every menu-bar status item is
clickable with Sticky running, verified by script.

### T-203 · NotchShape + chip row
**deps** T-201
The shape from PLAN §3.3. Chip visual per PLAN §10.9 — rounded `.continuous`
square, glyph, 11 pt middle-truncated filename, one accent hairline, dashed
container, single row with `+N` overflow.
**Gate** screenshot diff against a reference at 1× and 2×: zero non-black pixels
outside the cutout in the idle state; no content above `y = notchHeight + 10`.

### T-204 · Drop detection + file promises
**deps** T-202
`.onDrop` with `Color.black.opacity(0.001)`. Register for **both** `.fileURL`
and `NSFilePromiseReceiver`.
**Gate** all five succeed 20× consecutively: Finder file, Finder folder,
multi-select, **the macOS screenshot floating thumbnail**, and an image dragged
out of Safari. The last two are file promises and will fail if only `.fileURL`
is handled.

### T-205 · State machine on mock data
**deps** T-203, T-204
Six states from PLAN §4.2, driven by a fake transfer. 100 ms close grace,
120 ms sticky-arm.
**Gate** state-transition test covers every edge including re-entry, and
drag-leave-then-return within the grace does not close.

### T-206 · Menu bar
**deps** T-103
Status item + `NSPanel` panel per PLAN §5, template image, icons per
`docs/ICONS.md` §4. **Also a drop target** (feature F-3).
**Gate** every menu item present and wired to a no-op; icon tints correctly in
both light and dark menu bars.

### T-207 · Design tokens + Motion ⊘
**deps** T-103
`Design/DesignSystem.swift` and `Design/Motion.swift`. Every colour, radius,
spacing step and spring lives here. Notch body is `#000` flat; menu-bar panel
uses the near-black ramp.
**Gate** lint's token rules pass with real view code present.

### SPIKE-2A · The 27" seam ⊘
**deps** T-204 · **timeboxed 1 day, requires the second display connected**
Measure cursor behaviour crossing the top edge mid-drag. Does the 120 ms
sticky-arm hold? Does the drag survive the display change?
**Deliverable** a written finding + tuned constants, or a documented fallback
dead-zone. This is the biggest unknown in the project (PLAN §13).

### SPIKE-2B · Verify `opacity(0.001)` on macOS 26.5
**deps** T-204 · **timeboxed 2 hours**
Every source for this is from older releases. Find the actual threshold on this
OS. **Deliverable** the verified value, written into AGENTS.md §4.

### SPIKE-2C · Haptic under live drag
**deps** T-205 · **timeboxed 2 hours**
Apple suppresses feedback when the user is not touching the trackpad — during a
drag they are. Confirm `.alignment` fires on lock, once, and not on re-entry.
**Deliverable** confirmed or a documented alternative trigger point.

---

## Phase 3 — prove transfer

### T-301 · Round-trip harness ⊘
**deps** T-106 · **written FIRST, by an agent that has seen neither transport impl**
`scripts/roundtrip.sh`: send a file Mac→Win, send it back, assert SHA-256
equality at every hop. Corpus: spaces, NFD and NFC forms of the same name,
reserved names, trailing dots, duplicate-but-different-case, empty file, 4 GB
file, a folder tree.
**Gate** the harness fails loudly against a deliberately broken stub.

### T-302 · Transport — macOS
**deps** T-301 · **must not read `win/`**
`docs/PROTOCOL.md` §§3, 6, 8. UDP multicast announce + HTTP-scan fallback.
**Gate** T-301 passes.

### T-303 · Transport — Windows
**deps** T-301 · **must not read `mac/`**
Same spec, independently.
**Gate** T-301 passes.

### T-304 · Progress accounting
**deps** T-302, T-303
`GET /v1/progress`. UI reads receiver-acknowledged bytes only.
**Gate** a test with a throttled receiver shows UI progress lagging socket
writes, not matching them.

---

## Phase 4 — pairing and hostile input

### T-401 · Identity + key storage ⊘ · T-402 · Pairing UX
### T-403 · Mutual TLS pinning ⊘ (both sides, one owner — this is the security boundary)
### T-404 · Hostile-input suite
**Gate for the phase** an unpaired machine on the same LAN can reach nothing but
`/v1/pair`; pair → restart both apps → reconnect with no second code; ten cold
launches with no Keychain and no Accessibility prompt.

---

## Phase 5 — lifecycle

### T-501 · Reconnect (event-driven + 30 s fallback)
### T-502 · Firewall detection and explanation (Windows) — PLAN §7
### T-503 · Pending queue + resume from offset
### T-504 · Lifecycle matrix: sleep/wake, Wi-Fi change, IP change, firewall off, mid-transfer disconnect
**Gate for the phase** recovery without restarting either app; transfer succeeds
within 30 s of both devices becoming reachable.

---

## Phase 6 — motion and polish

### T-601 · Motion ⊘ (single owner — motion by committee is how it starts looking vibecoded)
### T-602 · Haptics · T-603 · Reduce Motion · T-604 · Windows visual parity
### T-605 · App icon (docs/ICONS.md §7)
**Gate for the phase** the PLAN §10.8 checklist passes on a screen recording,
at normal speed and stepped frame by frame.
