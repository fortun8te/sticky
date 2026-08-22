# Sticky Icon System

This is the design-only icon contract for Sticky. It defines the vector sources, optical rules, semantic colors, and platform integration. No app code is changed by this pass.

## Principles

- **Quiet first.** Icons support transfer state and file identity; they never compete with content.
- **One drawing system.** Every glyph uses a 24×24 grid, rounded terminals, and consistent optical weight.
- **Tint, do not bake.** SVGs draw with `currentColor`. Color belongs to platform brushes, not to the asset.
- **Recognizable at 16 px.** Each idea has one dominant shape and at most two supporting details.
- **Accessible by default.** Decorative icons are hidden from assistive tech; meaningful icons get an explicit label.

## Canonical grid

| Property | Value |
| --- | --- |
| Canvas | `24 × 24` |
| Safe area | Centered `20 × 20`, from `(2,2)` to `(22,22)` |
| Corner family | `2–4` radius for containers; platform round joins/caps |
| Source stroke | `1.5` on the 24 grid |
| Terminal style | Round cap and round join |
| Fill | None except where explicitly noted; current sources are stroke-only |
| Pixel alignment | Render at even sizes or use platform antialiasing; do not hand-nudge paths per size |
| Export format | PDF or XAML/SVG-backed vector. PNG only as a last-resort compatibility export |

Stroke weight scales linearly when the 24-grid source is resized:

| Rendered size | Effective stroke |
| ---: | ---: |
| 16 px | 1.0 |
| 20 px | 1.25 |
| 24 px | 1.5 |
| 32 px | 2.0 |
| 48 px | 3.0 |

Do not increase stroke weight merely because the icon is large. At display sizes, retain the same ratio so the family remains light and precise.

## Sources

All files live in `assets/icons/`.

| Asset | Meaning | Dominant cue |
| --- | --- | --- |
| `file.svg` | Generic binary/file transfer | Page with folded corner |
| `folder.svg` | Folder/directory | Closed folder silhouette |
| `image.svg` | Still image | Framed landscape and sun |
| `video.svg` | Video/movie | Framed play triangle |
| `audio.svg` | Audio/sound | Five-bar waveform |
| `archive.svg` | ZIP/TAR/compressed data | Boxed container with slot |
| `code.svg` | Source/config/developer text | Bracket pair in a rounded square |
| `document.svg` | Text/rich document | Page with reading lines |
| `unknown.svg` | Unrecognized type | Page with question mark |
| `success.svg` | Completed transfer | Circle with checkmark |
| `failure.svg` | Recoverable/user-visible failure | Triangle with exclamation mark |
| `device-unpaired.svg` | Discovered but not paired | Two devices, dotted link |
| `device-connecting.svg` | Pairing/handshake in progress | Devices, dashed directional link |
| `device-paired.svg` | Trusted paired device | Devices, solid link and check |
| `device-offline.svg` | Paired/unpaired peer unavailable | Devices, broken link and slash |

### Recommended type mapping

Use this mapping until a platform-specific preview exists. It intentionally matches the existing macOS shelf categories.

| Input | Icon |
| --- | --- |
| Directory | `folder` |
| `pdf` | `document` |
| `zip`, `tar`, `gz`, `bz2`, `xz` | `archive` |
| `mp4`, `mov`, `avi`, `mkv` | `video` |
| `mp3`, `wav`, `aiff`, `m4a` | `audio` |
| `json`, `csv`, `ts`, `js`, `swift`, `py` | `code` |
| `txt`, `md`, `rtf`, `doc`, `docx` | `document` |
| Image UTType | Real thumbnail; fall back to `image` |
| Anything else | `file`; use `unknown` only when even broad classification fails |

Prefer real thumbnails for images and video. The symbolic image/video icons are fallbacks, not replacements for user content.

## Color

Icons are monochrome templates. Use these semantic tints only where they aid recognition; otherwise use the platform primary-label color.

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `icon.primary` | `#1C1C1E` at 88% | `#FFFFFF` at 92% | Default glyph |
| `icon.secondary` | `#3A3A3C` at 68% | `#EBEBF5` at 68% | Metadata/de-emphasized glyphs |
| `icon.folder` | `#007AFF` | `#0A84FF` | Folders |
| `icon.image` | `#FF2D55` | `#FF375F` | Images |
| `icon.video` | `#AF52DE` | `#BF5AF2` | Video |
| `icon.audio` | `#FF9500` | `#FF9F0A` | Audio |
| `icon.archive` | `#D67D00` | `#FFB340` | Archives |
| `icon.code` | `#248A3D` | `#30D158` | Code/config |
| `icon.document` | `#D70015` | `#FF453A` | Documents/PDF |
| `icon.unknown` | `#8E8E93` | `#98989F` | Unknown types |
| `icon.success` | `#248A3D` | `#30D158` | Success |
| `icon.failure` | `#D70015` | `#FF453A` | Failure/offline |
| `icon.device` | `#007AFF` | `#0A84FF` | Device/pairing states |

Failure must remain readable without relying on color alone: pair it with the warning glyph, motion, and text. Do not use red for destructive-looking decoration elsewhere.

## Dark and glass treatment

Sticky surfaces often sit over desktop content, so glass must stay subtle and legible.

### Dark glass

- Backdrop: platform vibrancy/material plus `rgba(18,18,20,0.58)`.
- Border: top-leading hairline at `rgba(255,255,255,0.16)`.
- Glyph: `icon.primary` dark value.
- Shadow: black at 28%, blur 18–24, y-offset 6–10, low opacity spread.
- Avoid pure black fills; they make the material look like a hole.

### Light glass

- Backdrop: platform material plus `rgba(255,255,255,0.62)`.
- Border: top-leading hairline at `rgba(255,255,255,0.48)`.
- Glyph: `icon.primary` light value.
- Shadow: black at 12%, blur 14–18, y-offset 4–8.
- Avoid saturated tint backgrounds behind small glyphs.

### Glass rules

1. Blur the content behind the surface before applying overlay color.
2. Keep icon contrast at least 4.5:1 against the final composited background when the icon carries meaning.
3. Never place a colored glyph directly over moving content without the glass layer.
4. Use one accent per compact row. A shelf item may have a category tint; its status should remain neutral unless success/failure is the primary message.
5. During motion, animate opacity, scale, or mask—not stroke width.

## State treatment

- **Idle/default:** regular stroke, primary label color, no badge.
- **Armed:** scale from `0.96 → 1.00` with a soft magnetic pull; no color change required.
- **Sending/receiving:** preserve the dominant glyph and add progress outside the safe area, not inside the glyph.
- **Success:** crossfade to `success`, then one restrained ripple. Return to idle after the product-defined timeout.
- **Failure:** crossfade to `failure`, then a short horizontal shake of no more than ±2 px at 16–20 px sizes.
- **Connecting:** dash offset may move slowly; do not rotate the whole device glyph.
- **Paired:** solid connector/check; optional brief blue emphasis on transition.
- **Offline:** broken-link glyph plus secondary/failure tint; keep the device shapes calm.

## SwiftUI usage

Import each SVG as a template vector asset named with the `sticky.icon.` prefix, for example `sticky.icon.file`. Enable “Preserve Vector Data” and use single-scale rendering.

```swift
struct StickyIcon: View {
    let name: String
    var size: CGFloat = 20
    var tint: Color = .primary

    var body: some View {
        Image(name)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(tint)
    }
}
```

Guidance:

- Use `Image(systemName:)` only for temporary prototypes; production should consume these sources so both platforms match.
- For decorative icons, use `.accessibilityHidden(true)`.
- For meaningful icons, provide text through `Label` or `.accessibilityLabel(_:)`.
- Keep hit targets at least 44 × 44 pt on iOS-style controls and at least 28 × 28 pt for compact macOS rows; expand the target without expanding the visual icon.
- Animate with `withAnimation(.snappy)` or spring curves. Avoid symbol-specific rendering APIs on custom vectors.

## WPF usage

Convert each SVG path into a XAML `StreamGeometry` resource. Preserve the 24×24 coordinate space and expose names such as `StickyIconFileGeometry`.

```xml
<Path
    Data="{StaticResource StickyIconFileGeometry}"
    Stroke="{DynamicResource StickyIconPrimaryBrush}"
    StrokeThickness="1.25"
    StrokeStartLineCap="Round"
    StrokeEndLineCap="Round"
    StrokeLineJoin="Round"
    Fill="Transparent"
    Stretch="Uniform"
    Width="20"
    Height="20" />
```

For a 20 px render, set `StrokeThickness="1.25"` because the source stroke is `1.5 × 20 / 24`. For other sizes, calculate thickness as `1.5 × renderedSize / 24`.

Guidance:

- Store brushes as `DynamicResource` values so light/dark/high-contrast themes update without recreating controls.
- Set `UseLayoutRounding="True"` on containers; avoid bitmap scaling.
- Use `Viewbox` only when the host cannot size the `Path` directly.
- For dashed connecting states, preserve `StrokeDashArray` after conversion or implement it as a XAML `StrokeDashArray` on the connector subpath.
- Provide `AutomationProperties.Name` when the icon is the only control content.

## QA checklist

- [ ] All sources remain valid XML and use `currentColor`.
- [ ] No glyph crosses the 20 × 20 safe area.
- [ ] 16 px renders remain recognizable and do not produce muddy joins.
- [ ] Light, dark, high-contrast, and glass variants pass contrast checks.
- [ ] Success/failure are distinguishable by shape, text, and motion—not color alone.
- [ ] Device states are distinguishable without animation.
- [ ] Platform previews use the same geometry and semantic mapping.
