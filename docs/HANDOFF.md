# Sticky — handoff task list

Written for an agent picking this up cold. Read this whole file before touching
anything.

## What you are inheriting

A Mac↔Windows file portal. The **macOS half is built, running, and verified by
hand**: build green, 22 tests passing, idle CPU 0.0%, drag-in and drag-out both
confirmed end to end with real Finder drags.

The **Windows half has NEVER BEEN COMPILED.** There is no dotnet SDK on the
machine it was written on. Roughly 3,800 lines of C# were written and reviewed
by reading only. Treat every Windows file as unproven.

**No transfer between the two machines has ever happened.** Every send in
development ended in "queued" because no PC was on the network. That is the
gate everything else waits behind.

Branch: `rebuild/notch-overhaul`. Six commits, all pushed.

---

## P0 — Make Windows compile

Nothing below matters until this passes.

### T-1. Build it
```
dotnet build windows/StickyWin/StickyWin.csproj
```
Fix every error. Constructs flagged as highest-risk by review, in order:

1. **COM interop in `App.xaml.cs`** — the `IShellLinkW` / `IPersistFile`
   declarations and `[ComImport] class ShellLinkCoClass` used to write the
   Send To shortcut. Most likely single point of failure.
2. **XAML value-type resources in `App.xaml`** — `<Duration>`, `<CornerRadius>`
   and `<Color>` as keyed resources rely on type converters. If the build fails
   on App.xaml, look here first.
3. **Collection expressions** — `[.. items.Where(...)]` assigned to a
   pre-declared local, in `DiscoveryService.RemoveExpired` and
   `TransferService.DefaultTarget`. Note: five `Dictionary`-targeted collection
   expressions in `PairingService.cs` were already fixed (C# 12 does not allow
   them); check none remain elsewhere.
4. **`System.Threading.Timer` overloads**, including the
   `(TimeSpan, Timeout.InfiniteTimeSpan)` form.
5. `HMACSHA256.HashData`, `RandomNumberGenerator.GetInt32`,
   `CryptographicOperations.FixedTimeEquals`, `Convert.ToHexString`.

**Acceptance:** clean build, zero errors. Record any warnings.

### T-2. Review `TransferService.cs` for compile errors — NOT DONE
The review scout assigned to this file (1,096 lines, the largest) **never
completed** — it was killed by a provider rate limit. It is the only Windows
file with no compile review at all, and it holds the TLS listener, the pairing
handshake and the upload path.

If T-1 passes, this is moot. If T-1 produces a wall of errors, start here.

### T-3. Runtime defect review — NOT DONE
The scout assigned to hunt first-run runtime defects across the Windows
services also died to the same rate limit. Nobody has looked for:
- exceptions escaping `async void` or Timer callbacks (these kill the process)
- `.Result` / `.Wait()` deadlocks on the UI thread
- STA violations (WPF `Clipboard` touched off the UI thread)
- sockets / `SslStream` / `CancellationTokenSource` leaked on exception paths
- anything that throws on a clean machine before its directory exists

Do this review before running on hardware you care about.

---

## P1 — Pairing (the first thing a user does, and the most likely to fail)

### T-4. Understand the gate before you test it
`/api/v1/pair` is refused outside an open "pairing window", with a doubling
lockout after 5 wrong PINs (30s → 5min cap). The two sides latch differently:

- **Mac**: gate starts OPEN. It latches the first time `beginPairingWindow()`
  or `endPairingWindow()` is called — which happens when the tray menu is
  opened, when the pair dialog runs, and (new) whenever the shelf panel is open
  while an untrusted device is nearby.
- **Windows**: `EndPairingWindow()` runs at **startup**, so the gate is latched
  CLOSED from launch. Only `PairingWindow` opens it.

**Consequence:** the responder's gate must be open. Pair **from the Mac while
the PC's pairing window is open** — that is the reliable direction and the one
the Windows first-run flow is designed around.

### T-5. Test pairing, both directions
1. Mac → PC: type the PC's six-digit code on the Mac. The PC's pairing window
   should flip to paired within ~1s.
2. PC → Mac: type the Mac's code on the PC, with the Mac's shelf panel open.
3. Wrong code on each side → a sentence explaining it, never an exception.
4. 6+ wrong codes → lockout backs off and the displayed code does **not**
   change (it used to rotate, invalidating the code the user was reading).
5. Leave a code past 5 minutes → it expires, "New code" issues a fresh one.

**If pairing fails with "not accepted" despite a correct code, suspect the gate
(T-4) before suspecting the network or the crypto.**

### T-6. The handshake itself
`pinProof` = `HMAC-SHA256(key: PIN_utf8, "sticky-pair-response-v1" ‖
lowercase(responderFingerprint) ‖ lowercase(returnToken))`, lowercase hex.

This was verified **byte-for-byte identical** between Swift and C# by an
independent review, with both sides hashing the DER of the certificate actually
presented on the TLS connection. That is **code-level equivalence only** — the
two implementations have never run against each other. If pairing fails and the
gate is not the cause, instrument both sides to log the proof input and output
and diff them.

Backward compatibility: a **missing** `pinProof` still pairs (older builds); a
**present but wrong** one is refused.

---

## P2 — The actual product

### T-7. First real transfer
Mac → PC and PC → Mac. A small file, then something over 1 GB.
- Progress must reflect bytes acknowledged by the receiver, not bytes written
  to the socket.
- Files land in `~/Downloads/Sticky` (Mac) / the configured receive folder (PC),
  collision-safe, never overwriting.
- Interrupt mid-transfer (pull the network) → it queues and resumes.

### T-8. Clipboard across machines
Text works today. Known gaps, both needing protocol work:
- **Rich text**: only the plain-text fallback crosses. A v1.1 envelope would
  keep `text` for compatibility and add
  `flavors: [{uti, encoding, data}]`, with the Windows side mapping to `CF_RTF`
  and `CF_HTML` (the latter needs its `Version:0.9 / StartHTML:` preamble
  synthesised).
- **Images**: currently staged to a temp PNG and sent over the *file* channel,
  so they arrive as a file rather than as a clipboard image. Real image sync
  needs a `kind: "image"` envelope and the Windows side putting CF_DIB/PNG on
  its clipboard.
- Inbound is text-only by construction: `onClipboardReceived` is
  `(String, String) -> Void`, so every remote clip becomes `.text`.

---

## P3 — Windows features not built

### T-9. Explorer context menu (plan §6, F-11)
`HKCU\Software\Classes\*\shell\` — the third affordance. Not implemented.
The other two (drop widget, Send To) are.

### T-10. Autorun
`HKCU\...\CurrentVersion\Run`. Not implemented. Must be visible and
disableable in Settings → Startup.

### T-11. Real toasts
Arrival notification currently uses a tray balloon. For proper Windows toasts
with an "Open Folder" action, add to `StickyWin.csproj`:
```xml
<PackageReference Include="Microsoft.WindowsAppSDK" Version="1.6.*" />
<WindowsPackageType>None</WindowsPackageType>
```
then implement a second `IArrivalNotifier` using
`AppNotificationManager.Default.Register()` + `AppNotificationBuilder`, and
prefer it in `SetupTray` with the balloon as fallback. The interface and the
call site are already there — see the doc comment in `App.xaml.cs`.

---

## P4 — Polish and decisions

### T-12. The clipboard window is the odd one out
It is still default WPF light chrome while the drop pill and pairing window are
dark and tokenised. Restyle it through the `Sticky.*` resources in `App.xaml`.

### T-13. Type floor
Windows side uses a 12.5px floor; the Mac uses 11pt (≈14.7px). Deliberate —
11pt is macOS-small but Windows-large, and Windows' own UI floor is ~12px.
One-line change if you disagree.

### T-14. Unverified macOS interactions
Built and compiling, never confirmed on screen:
- hover-and-hold for 0.9s springs the shelf open (with a haptic)
- "Clear all" on the queue
- the chip right-click menu (Quick Look / Reveal / Send / Remove)

---

## Rules that are not negotiable

These come from the project's own plan and were expensive to get right.

1. **Idle draws zero pixels and runs no animation.** Verified: 0.0% CPU. Any
   change that reintroduces an idle animation is a regression.
2. **Never capture the keyboard, never require Accessibility.** No global
   monitors for key events, no `AXIsProcessTrusted`, no synthetic paste.
3. **The notch body is flat `#000`** where it meets the bezel. Material there
   reads as a grey rectangle glued to black hardware. Only the part that floats
   over the desktop is glass (`NSGlassEffectView`, macOS 26+).
4. **A view whose `hitTest` returns nil is NOT click-through** — the window
   still swallows the click. Only `ignoresMouseEvents = true` passes clicks
   through, and that also removes the window from drag routing. Hence two
   panels: a visual layer that never takes events, and a sensor sized to
   exactly the cutout at rest. Measured, not assumed.
5. **Never resize a window a drag is tracking against** — it cancels the
   dragging session and the drop silently fails.
6. **One warm ramp for ambient light; the OS accent for controls.** No second
   accent hue.

## Where the measured numbers live
`macos/Sticky/Tests/NotchLayoutTests.swift` pins the geometry invariants
(sensor extent, portal caps, pixel snapping, the clipboard action rect matching
the drawn button). If you change layout constants, these fail first — that is
intentional.
