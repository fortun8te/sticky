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
- Live candidates, one JPG each in `docs/mockups/` (pick pending; render rig
  source in `docs/mockups/src/`):
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

## 9. Your task

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
