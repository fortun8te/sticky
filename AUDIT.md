# Codebase Audit — `fortun8te/sticky` @ `c6cc8f0`

First full analysis of the existing build, done by reading the source rather than
summarising it. This is the evidence base for [PLAN.md](PLAN.md); the plan cites
it and does not repeat it.

**Verdict: rewrite, not refactor.** Not because the code is bad line-by-line, but
because it is a different product (a clipboard paste tool) on a runtime we are
leaving (Electron), with a security model that cannot be patched into place.

---

## 1. Shape of the thing

```
3,342 lines · 100% TypeScript on Electron · 16 source files
Swift: 0    C#: 0    native modules: koffi (FFI) only
Runtime deps: chokidar, koffi          Tests: 2 files, 115 lines
```

Composition by purpose:

```
app shell / glue            1136   33%  #############
clipboard / paste / history  779   23%  #########
transfer                     751   22%  ########
notch / window / ui          602   18%  #######
haptics                       74    2%
```

**Only 22% of the codebase is the thing we actually want.** 23% is the clipboard
product we are cutting. A third is Electron glue that disappears with the
runtime. This ratio is the argument against refactoring.

18 IPC channels exist; 13 of them serve clipboard, history, paste and
click-through concerns that v2 does not have.

---

## 2. Defects, by severity

### S1 — Unauthenticated plaintext file transfer

`src/main/peer.ts:265,276`

```ts
private udp = dgram.createSocket({ type: 'udp4', reuseAddr: true })
this.server = http.createServer((req, res) => { ... })
export const UDP_PORT  = 47831
export const HTTP_PORT = 47832
```

`grep` across all of `src/` for `createHash`, `sha256`, `sha1`, `tls.`,
`https.`, `X509`, `hmac`, `randomBytes`, `pairing`, `pinning`, `secret` returns
**zero hits**.

There is no transport encryption, no device identity, no pairing, no session
token, and no integrity check. Any host on the same L2 network can `POST` into
`~/Downloads/Sticky` and enumerate what is offered. On any shared network this is
a remote file-write primitive.

The previous post-mortem did not list this.

### S2 — Keyboard and input takeover

| Location | Code | Effect |
|---|---|---|
| `index.ts:750` | `systemPreferences.isTrustedAccessibilityClient(true)` | The `true` argument **prompts**. Called unconditionally on every launch. |
| `index.ts:767` | `globalShortcut.register(isMac ? 'Command+Shift+V' : 'Control+Shift+V')` | Claims a system-wide chord from every other app. |
| `inject.ts:411` | `osascript -e 'tell application "System Events" to keystroke "v" using command down'` | Synthesises a paste into the previously-focused app. |
| `inject.ts:336,395` | further System Events automation | Also requires the Automation permission. |

This was not a bug. The README states the intent: *"It overwrites the clipboard,
pastes into the last app you clicked."* The app was built to type on the user's
behalf, which requires exactly these permissions.

### S3 — Private API via FFI

`notch.ts:69`

```ts
objc.msgBool(nsWin, objc.sel('_setCanExcessOverlap:'), 1)
```

An undocumented AppKit selector, reached through `koffi` → `objc_msgSend`, plus
`setFrameTopLeftPoint:` and `setContentSize:` driven directly against the
`NSWindow` behind Electron's back. Two layout systems writing to the same window
each frame. This is both a stability risk and a distribution risk.

### S4 — Oversized hitbox from a units error

`notch.ts:6-11`

```ts
export const MAC_IDLE_W = 188   // measured notch is 185.0 pt
export const MAC_HIT_W  = 370   // = 185 x 2 — the notch width in PIXELS
```

`370` is the notch measured in **device pixels** on a 2× display, used as
**points**. `placeNotchWindow()` pins it as a hard minimum:

```ts
win.setMinimumSize(MAC_HIT_W, idleH)
```

Result: a permanently interactive window exactly twice as wide as the notch. The
"huge annoying hitbox" is this one line.

`MAC_IDLE_W = 188` is also a guess; the measured value is `185.0`.

### S5 — Polling and per-frame window resizing

```ts
index.ts:765   setInterval(tickHover, 40)        // 25 Hz cursor poll, forever
index.ts:782   setInterval(async () => {...}, 2000)  // shells out to osascript every 2 s
notch.ts       win.setBounds(bounds, animate)    // resizes the real window per state change
```

`refreshMacTarget` spawns an `osascript` process every two seconds for the life
of the app. `setBounds` on every state change fights Core Animation instead of
animating content inside a fixed window.

### S6 — Systemic error suppression

64 `catch` blocks; 13 completely empty. Notably `haptic.ts:70`:

```ts
} catch {
  /* Magic Mouse / no Taptic Engine */
}
```

A silent no-op is indistinguishable from a wrong-thread call, a bad selector, or
a suppressed system setting. This is why "haptics didn't work" was never
diagnosable.

For the record, the hardware was never the problem — on the target machine:
`ForceSupported = Yes`, `ActuationSupported = Yes`, `ForceSuppressed = No`.

### S7 — Unverified claims

`MAX_BYTES = 8 * 1024 * 1024 * 1024` and a README claiming 8 GB, with no
large-transfer test anywhere in the suite. Test coverage is 115 lines total,
entirely path-sanitisation and inbox planning — **no transport test, no
round-trip test, no integrity test.**

---

## 3. Corrections to the earlier post-mortem

The post-mortem that preceded this audit is right about the symptoms and wrong
about the code. Recorded so the errors do not propagate into the plan:

| Claim | Reality |
|---|---|
| Keep "the native Swift Mac direction" | No Swift exists. |
| Keep "the native .NET Windows tray direction" | No C# exists. |
| Keep "streaming into temporary files" | Streams exist, but no verified temp→rename flow. |
| Keep "checksums" | No hashing of any kind. |
| Keep "device identity and certificate-pinning concepts" | Neither exists. |
| Remove "legacy PKCS#12 certificate-import code" | No certificate code exists. |
| "Private-key prompt from Keychain import at startup" | No Keychain or PKCS#12 code. The launch prompt is **Accessibility**, `index.ts:750`. |
| "2 GB ceiling, remove the 500 GB claim" | The constant is 8 GB; the README says 8 GB. Neither figure appears. |
| "Polled the cursor 40 times a second" | Every 40 ms — 25 Hz. |

---

## 4. Salvage list — what actually survives

**Keep:**
- `src/main/peer.test.ts` — the `sanitizeRel` vectors: `../etc/passwd`,
  `foo/../../x`, `C:`, `foo:bar`, `shot<>.png`, `con.txt`, `nul`, `photo.`.
  These encode real cross-OS traps and port to both new suites unchanged.
- Ports `47831` / `47832`.
- The `Downloads/Sticky` destination convention.
- The product intuition.

**Missing from those vectors, and required in v2:** Unicode NFD↔NFC
normalisation, case-insensitive collision on NTFS, and `NUL.txt`-style reserved
names *with* an extension.

**Delete:** everything else.

---

## 5. What this implies for the rebuild

1. Phase 1 is scaffolding, not migration. There is nothing to port.
2. The security model is a from-scratch design, not a hardening pass.
3. The notch must be rebuilt on measured geometry — every dimension in the old
   code is either a guess (`188`) or a units error (`370`).
4. A CI lint banning the S2/S3 API surface must land **before** any feature work,
   or the same permissions will be reintroduced the first time something is
   inconvenient.
5. Test coverage starts at effectively zero for transport. The Phase 3 gate
   (round-trip with hash equality) is the first real test this project will have.
