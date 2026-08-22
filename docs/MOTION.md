# MOTION.md — the transfer moment, complete brief

This is the full handoff for the motion work (Phase 6, T-600/T-601). It contains
**everything decided so far** — treat it as heavy direction, not scripture:
where it specifies numbers, match them; where it names a rejected direction, do
not resurrect it; and **you are explicitly asked to produce at least one
original variation of your own** on top of the specified ones (see §9).

Read `AGENTS.md` first — it wins over this file where they disagree.

---

## 1. The moment, in one paragraph

Sticky has **no middle**. Only the commit (letting go of a drag at the notch)
and the arrival. No progress bar, no percentage, no "sending…" state, ever. The
transfer moment is ~1 second of light and glass around the aperture, and then
nothing — the screen returns exactly to rest. If any element persists after the
moment, the design has failed.

## 1a. The gateway frame — the governing metaphor (user's own words)

"You're throwing it into the notch, so all the glow from the entire screen goes
**into** the notch on the Mac. It then **explodes from the bottom** into the
rest of the screen on the Windows machine. Like between two star systems, where
you've got a gateway and it just fires shit off."

This is the organising idea and it makes the two ends **asymmetric by design**:

- **Mac = INTAKE.** Light does not wash the screen — it *converges*. Soft radial
  spokes reach inward from across the screen toward the notch, a wide blurred
  ring contracts onto it, the bloom gathers AT the aperture and is brightest as
  everything arrives. The file rides the collapse (ease-IN). Three beats:
  charge (quiet — spokes reach in) → converge (peak) → swallowed (the last
  light closes in). Intensity must BUILD; the charge beat is restrained
  (spokes ~0.4, bloom ~0.15) or there is no story.
- **Windows = EXHAUST.** The mouth ignites compact and hot at the sill, then
  spokes and an expanding ring *erupt outward* from the bottom edge into the
  screen; the file is fired out riding the wavefront, decelerating (ease-OUT);
  the front expands and fades. Three beats: ignition → eruption → settle.
- One directional throughput. Nothing on the Mac expands; nothing on Windows
  contracts.

Mockup: `docs/mockups/v16.jpg` (source `src/v16.swift`), including the **seam
frame** — both machines in shot at the peak instant, Windows erupting above the
bezel while the Mac swallows below it. That frame is the product in one image.

**Taskbar rule extended:** on Windows, *every* light layer — spokes, ring,
bloom, not just the blur wave — is masked to stop ~6 pt above the taskbar with
a short eased falloff (`BottomMask` in the rig). First render violated this and
it read as a broken app instantly.

v14/v15 remain the reference for the wash/blur/lens *materials*; v16 supplies
the light *choreography*. Combine: v14's blur wave + soft square lens, with
v16's converging/erupting spoke-and-ring light replacing the static bloom.

## 2. The observed chronology (from real NameDrop frame captures)

1. **Contact** — the top of the screen begins to *blur away*; a faint glow at
   the aperture.
2. **The rise** — a screen-wide light rises from the bottom corners toward the
   notch, converging on it, while the blur wave descends.
3. **The glass** — a lens/glass body forms at the aperture, visibly refracting
   (dispersing) what is around and behind it.
4. **Through** — the file posts up through the glass into the slot
   (exposure-blur streak, ease-IN ballistics: 70 ms anticipation dip of ~7 pt,
   then ~130 ms accelerating launch).
5. **Disperse** — the light disperses the glass back out; the blur lifts;
   everything sharpens to rest.

The parametric ripple everyone tries to copy is the garnish. **Blur + bloom +
glass is the meal.**

### 2a. Second capture set — sideways contact (both screens visible)

A further set of real frames, phones touching edge-to-edge, adds these facts:

- **Both screens glow simultaneously, before any content moves.** The receiving
  phone's dark screen blooms softly from its contact edge while the sender's
  content blurs. The event has two ends from the first frame — it is never
  "send, then receive".
- On the sender, the glow starts at the aperture **and** a subtle glow rises
  from the opposite (bottom) edge; they meet, the wash deepens, "the warping
  happens".
- **Once interconnected, the droplet/lens appears on both sides.**
- At peak wash the sender's content is almost entirely dissolved — far more
  than feels safe until you see it; it recovers completely in under half a
  second.
- There is no hard edge in any frame at any scale. Every boundary is a wide
  falloff.

**Consequence for Sticky:** the Windows client mirrors the moment — its bottom
edge blooms and forms its own lens *in the same instant* as the Mac's notch
(one event, two mouths — see the v9 seam mock in the plan history). Progress
still comes only from receiver-acknowledged bytes; the simultaneity is visual,
not a claim about the network.

## 3. Colour law

- Light is **warm monochrome**: white `#FFF6E5` into amber `#FFC178`. These are
  research-synthesised values (Apple publishes none) — tune freely within
  warm-white/amber; never leave that family.
- **Never** the Apple-Intelligence aurora (`#BC82F3`/`#F5B9EA`/`#8D9FFF`…). A
  file-transfer tool must not read as an AI feature.
- Rainbow/spectral colour may appear **only as chromatic dispersion at a
  refracting edge** — soft, low-opacity, red/blue offset at the glass boundary.
  Never as a fill, sweep, or decorative gradient.
- There is no accent colour anywhere in this app.

## 4. Gradient hygiene (AGENTS.md §9 — enforced)

- No gradient ends in `Color.clear` (transparent black → grey fringe). End in
  the same hue at `.opacity(0)`.
- Every fade is an eased ramp, ≥3 stops; the blur-wave edge band is ≥25% of its
  travel.
- ≤4 additive (`plusLighter`) layers per frame. Check renders for 8-bit banding.
- No thin drawn rings on glass — rims are wide blurred gradient strokes.
- No glint "blobs" (they read as an eye — rejected). Sheen is a linear top wash.

## 5. Glass bodies — status

- **REJECTED: the hanging teardrop/droplet.** Verdict: uncanny. Do not bring it
  back.
- **PICKED: `v14.jpg` — v11's composition with the lens as a soft square.**
  Blur wave + large bloom (v11 exactly), the file launch from v7 (anticipation
  dip → ease-IN, exposure-blur streak), and the lens a
  `RoundedRectangle(cornerRadius: 24, style: .continuous)` ~150×110 pt grown,
  refracting a magnified backdrop, rim = wide blurred gradient strokes
  (lw 3.5–4.5, blur 6, opacity ≤ 0.35). Source: `docs/mockups/src/v14.swift`.
- Earlier candidates, kept as references (one JPG each in `docs/mockups/`;
  render rig in `docs/mockups/src/`):
  - **A · ISLAND** (`v13a.jpg`) — rounded-rect glass plate *around* the notch
    (the iOS Liquid Glass widget look), veil light.
  - **B · CHIP** (`v13b.jpg`) — compact near-square lens floating just below
    the aperture, corner-ray light.
  - **C · THROAT** (`v13c.jpg`) — the notch itself extends; its lower half
    becomes glass; contracting-ring light.
- Corner style is always `.continuous`. Glass never has a hard black fill —
  it refracts a magnified backdrop (`scaleEffect ~1.4, anchor: .top`,
  `+brightness ~0.1`).

## 6. Light treatments (interchangeable with bodies)

- **Veil** — one radial field centred on the aperture, revealed bottom-up by an
  eased linear mask.
- **Rays** — two soft corner beams (blur ≥30) brightening toward the notch.
- **Tide** — a contracting ring centred on the aperture (radius ~470→66 pt),
  stroked wide (150/270 pt) and heavily blurred.

## 7. Implementation mapping (verified on macOS 26.5 — see PLAN §15.3/15.3a)

| Component | API | Notes |
|---|---|---|
| Blur wave over the real desktop | `NSVisualEffectView` `.behindWindow` + animated `maskImage` | public API, no permission; smoothness of the mask animation is SPIKE material |
| Glass body | SwiftUI `.glassEffect(_:in: some Shape)` hosted in `NSHostingView` | accepts arbitrary concave shapes — verified; AppKit's `NSGlassEffectView` only has cornerRadius, don't use it |
| Bloom, rays, veil, ring, sill | our own additive drawing | ours entirely |
| File streak | ONE-pass exposure blur (`Canvas`/`CAReplicatorLayer`) | the N-view sample stack in the mockup rig is a stills technique — never ship it |
| Parametric pixel displacement of the desktop | **unavailable** | `CALayer.backgroundFilters` is dead since Big Sur (proven); ScreenCaptureKit needs Screen Recording — banned |
| Haptics | `.alignment` on commit, `.levelChange` on arrival | fetch `defaultPerformer` fresh each call; log no-ops |

- The wash may pass over the menu bar during the moment (<1 s), as NameDrop
  washes the status bar. The **hitbox never grows** and the camera cutout shows
  only the black notch.
- Reduce Motion: springs → 150 ms fades; the blur wave and glass morph are
  **disabled entirely**, not shortened; geometry and haptics unchanged.
- Motion is never timer-driven — implicit animation only, so ProMotion paces it.
- Windows ships the same beats/timings/colours; bloom+streak must hold 60 fps;
  desktop blur is SPIKE-6B with a light-only fallback. A missing blur is
  acceptable, a stuttering one is not.

## 8. Geometry (measured — never hardcode elsewhere, see AGENTS.md §3)

Notch 185.0 × 32.0 pt; origin from `auxiliaryTopLeftArea.width` (the notch is
0.5 pt left of screen centre — `midX` math is off by a pixel); menu bar 33 pt
(1 pt taller than the notch); hitbox while dragging 217 × 56 pt, none at idle.

## 8a. The Windows end — mirrored, not copied

Mockup: `docs/mockups/v15.jpg` (source `src/v15.swift`). Same beats, same
timings, same warm white → amber, same soft-square lens. What differs, and why:

- **We render the BOTTOM slice of the 27"** — that edge faces the MacBook, so it
  is the seam. Everything happens there.
- **The PC has no notch, so its mouth is LIGHT, never a cutout.** A sill line at
  the screen edge plus a bloom above it. Drawing a black "fake notch" on the PC
  is banned — only the Mac has real hardware to blend into.
- **The mouth is aligned to the Mac's notch width (185 pt) and horizontally
  centred on it**, with a user-adjustable offset so it lines up with how the
  monitor physically sits above the laptop.
- **The blur wave rises upward.** On the Mac it descends from the top; here the
  seam is below, so the direction inverts. Same eased ≥25% band.
- **The arrival decelerates (ease-OUT).** The file left the Mac accelerating
  away; it arrives here slowing down. One continuous vector across the gap —
  it never reverses direction.
- **HARD RULE: the taskbar is never washed.** On the Mac the menu bar is grazed
  briefly and that is acceptable; on Windows the chrome sits *exactly on the
  seam*, so the wash is masked to stop ~6 pt above it with a short eased falloff.
  A washed-out taskbar reads as a broken app, not an effect. The first render of
  v15 got this wrong and it was obvious immediately — do not regress it.
- **Simultaneity:** this edge blooms in the *same frame* the Mac commits (§2a).
  Visual only — progress still comes solely from receiver-acknowledged bytes.
- Perf: bloom + lens + streak must hold 60 fps (T-604). The rising blur wave is
  SPIKE-6B; if no candidate holds frame rate, ship light-only. **A missing blur
  is acceptable, a stuttering one is not.**

## 9. Decision history — what was tried and judged

So the same ground is not re-explored blind:

| Version | Verdict |
|---|---|
| v7 — motion-blur launch, cyan light | Launch mechanics **good** (kept); cyan accent rejected — not Apple |
| v8 — white light, elastic notch | Colour law established; elastic hover kept |
| v9 — both screens, one seam | Concept **confirmed** by the sideways captures (§2a) |
| v11 — blur wave + bloom + ellipse lens | Composition **picked** — "really good" |
| v12 — hanging teardrop droplet | Shape **rejected** — "weird / uncanny". Do not revisit |
| v13 A/B/C — square glass bodies | Right family; rims still read too defined |
| **v14 — v11 composition + soft square lens** | **The pick.** Build this |
| v15 — the Windows end, mirrored | Composition confirmed; taskbar-wash bug found and fixed (§8a) |
| v16 — the gateway: intake / exhaust | **Choreography locked** — Mac converges, Windows erupts; seam frame is the money shot (§1a) |

Standing sensitivities from review: hard gradient cut-offs are the #1 recurring
complaint — when in doubt, softer and wider than feels necessary; glint "eyes"
and drawn rings read as uncanny; oversized organic blobs read as lava lamp.

## 10. Your task

1. Build the picked variation (or, if no pick is recorded yet, build **A** and
   keep the body/light code swappable) as a **live SwiftUI prototype** at true
   geometry, animated, interruptible mid-flight (retarget from presentation
   values — never restart).
2. **Produce at least one original variation of your own** within these
   constraints — different glass body, light treatment, or beat structure. The
   constraints are the contract; the composition is yours. Render it exactly
   like the others so it can be judged side by side.
3. Use the render rig in `docs/mockups/src/` (HARNESS.swift + v13.swift show
   the working pattern) for stills; judge your own renders by cropping to the
   notch region at full resolution (AGENTS.md §3.1) and iterate at least twice
   before presenting.
4. Gate: the §10.8 QA checklist in PLAN.md, plus — no `.clear` gradient
   endpoints anywhere (grep for it), and every animation reversible mid-flight.
