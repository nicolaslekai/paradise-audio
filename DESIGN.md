# Paradise Audio — Design System

> The single source of truth for every plug-in's UI. Distilled from the **Drums**
> machine (the reference standard). When a plug-in looks "off," it's almost always
> breaking one of these rules. Align to this doc; don't invent per-plugin styles.
>
> Shared tokens already live in `Palette.swift` (copied into each extension). This
> doc adds the **layout, component, typography, and color-role** rules that aren't
> yet shared.

---

## 0. Analog scheme — CURRENT STANDARD (2026-11-20, supersedes the dark-scheme values below)

Nicky's brief: 80s-Miami flavour, **textured, analog hardware, nothing too funky, as little
confusing as possible, no gradients on small parts.** The colour ROLES did not change.

| Element | Now | Where |
|---|---|---|
| Faceplate | Painted teal steel enamel bitmap (`faceplate_teal.jpg`), full opacity, `faceBg` #2B4446 as fallback | `FaceTexture.draw` |
| Ink | Cream screen print `inkLight` #E9DFC9, `inkMidL` #A9A898 | `Palette` |
| Insets / wells | Flat recessed teal-black `panelDark` #182324, `wellBg` #10191A, never a gradient | `Palette` |
| Knobs | Blender-rendered bodies, one static PNG per role, **no pointer baked in** (the pointer is a painted line drawn in code). Design `fluted` (whole body in role colour) is the suite default; `knurl` (silver + painted cap) is the one-line alternative (`KnobSkin.design`) | `KnobSkin`, `Tools/knob_bodies_blender.py` |
| Knob roles | **dark = default · ivory = volume/output (auto by name) · red = accent** (EQ HP/LP, 909 FLT). Pointer paint: cream on dark, charcoal on ivory, warm white on red | `KnobView`, `KnobSkin.pointerColor` |
| Hero knobs | BigKnob dark / PitchKnob red, 1024 px bodies: `fluted`, `knurl` or `grip` (rubber grip + chrome dish), `KnobSkin.heroDesign` | `KnobSkin` |
| Keys / pills / steps | Silicone rubber keys (`key_dark/red/ivory.png`), 9-sliced so any size works. Dark = off, red = on/active | `ButtonTex.draw`, `ButtonTex.drawRubber` |
| Type | DIN Alternate Bold (labels, values: `Palette.printFont`), DIN Condensed Bold (names, titles: `printFontCondensed`). Ship with macOS. Monospaced stays for axes/tags | `Palette` |
| Tick rings | Cream screen-printed ticks around every knob | `KnobView` |

**Pipeline / tools (no Xcode needed except for the final build):**
- `Tools/knob_bodies_blender.py` (+ `Tools/knob_alpha_fix.py`) — re-render knob bodies headless (Blender 5.2 on the Mac; GPU renders abort when Blender runs as a background task, so run it in the foreground).
- `./sync_shared_ui.sh` — now also copies `Shared/UI/Resources/*` into every extension's `Resources/`.
- `Tools/typecheck_all.sh` — type-checks every extension with the Command Line Tools.
- `Tools/au_offline/render.sh <Plugin> <out.png> [aufx|aumu]` — builds the extension as an executable and renders its real UI offscreen. Use it to check every UI change.
- `Tools/ui_harness/run.sh` — renders just the shared parts.
- Renders and comparisons: `Plugin_Renders/2026-11-20_redesign/`.

---

## 1. Color tokens (`Palette.swift` — do not redefine inline)

> **2026-11-20:** values below are the pre-analog dark scheme, kept for history; §0 is current.

> **2026-08 revision:** the whole suite now runs the **dark faceplate scheme**
> (SynthThing/Compressor were first; every plug-in followed). The dark tokens
> below are the standard; the cream tokens survive for knob caps and
> active-pill label text. All 17 `Palette.swift` copies are identical — when
> you touch one, re-copy it to all.

| Token | Value (calibrated) | Role |
|---|---|---|
| `faceBg` | white 0.132 | **Faceplate base.** Solid fill first, then `FaceTexture.draw` (brushed grain) on top. |
| `panelDark` | white 0.17 | Inset modules: visualizers, readouts, meters. |
| `inkLight` | white 0.90 | Primary text, strokes, tick marks on the dark face. |
| `inkMidL` | white 0.55 | Secondary text, axis labels, gridlines, captions. |
| `knobBody` | white 0.20 | Non-output knob body fill (fallback when `KnobTex` is missing). |
| `wellBg` | white 0.085 | Deep recessed wells: waveform strips, transport bars. |
| `keyRedTop/Bot` | 0.93,0.22,0.18 / 0.66,0.10,0.09 | Active 3D-key gradient (`ButtonTex.draw`). |
| `keyDarkTop/Bot` | white 0.27 / 0.145 | Inactive 3D-key gradient. |
| `cream` | RGB 0.82, 0.79, 0.74 | Knob caps, active-pill label text (OP-1 heritage). |
| `accent` (`red`) | RGB 0.88, 0.14, 0.12 | Active state, the single data line, brand mark, focal accents. |
| `panelBg`, `ink900` (`inkDark`), `ink500` (`inkMid`) | 0.84 / 0.12 / 0.45 | Legacy light scheme — unused on dark faces; kept for compatibility. |

### Color roles (the part that's being violated)
- **faceBg is the faceplate, nothing else** — draw the solid fill, then `FaceTexture.draw(in:ctx:)` for the brushed-aluminium grain.
- **panelDark is for inset modules** (any graph/meter/readout sits on a panelDark rect with a 0.5px `inkLight@0.6` frame; optionally `PanelTex` grain).
- **Red is a spotlight, not a wash.** One red focal element per module: the data line, OR the active toggle, OR the brand dot — not all at once. Large red fills are reserved for **active toggles** and the **duck plate**. If two reds compete in a module, demote one to ink. No other hues — RoarBass's orange identity was retired for exactly this reason.
- **Knob bodies:** `KnobTex` gunmetal by default; **ivory/cream body only for output-class knobs** (mix/level/output/volume/gain/master/trim) — auto-detected by name in `KnobView`. Local shading (alpha-derived highlights, one-off dark wells) may stay inline; any opaque colour used twice gets a token.

---

## 2. Faceplate frame (every plug-in, identical)

**Footer brand block** (bottom-left):
- `BrandLogo.draw` (the **Sunwave** mark since 2026-11-20: red sun with horizon slices, cream Paradise wave through it — drawn as vectors, simplified cut below 40 pt, flip-safe; ~16–22px) at `x=16`. Master geometry: `Tools/logo/logo_concepts.swift` (concept A); boards + Blender badge in `Plugin_Renders/2026-11-20_redesign/logo/v002/`. `logo_new_.png` now holds the Sunwave PNG (old circle-wave kept as `logo_old_circlewave_backup.png`).
- `PARADISE AUDIO` (optionally `· <PLUGIN>`) right of the logo — system 9pt semibold, kern 1.2, `inkLight`.
- `<PLUGIN> — <CODE>` subtitle below — system 7.5pt, kern 0.6, `inkMidL` (e.g. `DRUMS — DRM-1`).

**Hairline divider:** `inkLight@0.25`, 0.5px, from `x=16` to `width-16`, at `y=36`.

**Spec tag** (top- or bottom-right): `AU v3 · STEREO[ · …]` / `AU v3 · INSTRUMENT[ · …]` — monospaced 7pt, kern 0.5, `inkMidL`.

**Outer padding:** 16–18px. **Footer band:** 34–44px tall.

**Use the shared helper, don't hand-roll it (2026-09):** `BrandStrip.drawFooter(ctx:bounds:plugin:code:spec:pad:specAtTop:)`
draws exactly the block above, and `BrandStrip.drawTopBar(ctx:bounds:title:code:)` draws the dark
red-striped top bar of the SynthThing / Compressor / Delay family. Canonical copy in `Shared/UI/`,
mirrored into every extension by `./sync_shared_ui.sh`. Adopted so far: Delay, SynthThing, Reverb,
Saturation, Deesser, BigKnob, PitchKnob, UltraReverse. The rest still draw their own (identical
geometry, custom extras) — migrate when you touch them.

---

## 3. Knobs (`KnobView`)

**Knob bodies are drawn in code (2026-09-04):** `KnobVector` in `Shared/UI/FaceTexture.swift` — gunmetal / ivory / anodised red for `KnobView`, plain brushed silver (BigKnob) and plain red (PitchKnob) discs for the hero knobs (Nicky: "make it simpler" — the knurled variants stay in code, unused), light from the top-left, a small contact halo, no bitmaps. The knob PNGs in Resources are unused.

**One canonical `KnobView` (2026-09):** `Shared/UI/KnobView.swift` is the source of truth; 12
plug-ins carry a byte-identical copy (`./sync_shared_ui.sh` re-mirrors after edits). It has
`isOutput` (auto, white body), `isAccent` (red body + white cap/pointer — EQ's HP/LP) and
`parameterIdentifier`. Drums keeps its own compact 28 px per-voice knob by design.

- 270° sweep: start `1.25π`, end `-0.25π`. Pointer: `accent`, 1.75px, round cap, from 0.35→0.86 of radius.
- Body: radial-ish gradient. Default dark `white 0.18 → 0.08`. **Output-class white** `0.98 → 0.86`.
- Ring tick: `white0.45@0.25`, 1px, just outside the body.
- **Label** below knob: system 8.5pt medium, `inkDark`, kern 0.6, centered.
- **Value** readout under label: monospaced-digit 8pt, `inkMid`, centered, unit-formatted (`%`, `dB`, `Hz`/`kHz`, `ms`, `st`).
- Interaction: vertical drag (⌥ = fine), scroll wheel, double-click = default.
- **Sizing:** group knobs in a centered or right-aligned **bank**, equal size, 6–8px gaps. Don't mix knob sizes within a row. Bigger is better when space allows — cramped tiny knobs read as "lacking."

---

## 4. Visualizers & meters — ONE language

**This is the #1 consistency rule.** Every graph/meter is a **line graph or bar meter inside a panelBg inset** — never a VU dial, never a bespoke widget.

- Panel: `panelBg` fill + `inkDark@0.5` 0.5px frame (use `insetBy(dx:2,dy:2)`).
- Gridlines: `inkMid@0.18–0.25`, 0.5px; labels monospaced 7pt `inkMid`.
- Data: a single `accent` line 1.5–2px (round join), optional faint fill `accent@0.10–0.12` underneath.
- Header label top-left (monospaced 7pt `inkMid`); live value readout top-right (monospaced-digit 9pt heavy `inkDark`).
- **Stacked visualizers must match** (e.g. Compressor's transfer curve + GR history are now both red-line panels). If two visualizers in one plug-in look like different *kinds of object*, that's the bug.

---

## 5. Toggles, pills, buttons

**Pill toggle** (ON / AUTO / mode):
- Active: filled `accent`, label `cream`, heavy 8.5pt.
- Inactive: `inkDark@0.6` stroke 0.8px, label `inkDark`.
- Corner radius **4** (radius scale is 0 / 4 / 8 only — snapped suite-wide 2026-09).

**Preset plate:**
- Fill `white@0.6`, `accent` stroke 1.2–1.4px, corner radius 4.
- Title heavy 9–11pt `inkDark` centered; optional sub-line monospaced 7pt `inkMid`.
- Optional tiny `accent` corner dot (4×4) top-left.
- Lay presets in a **tidy grid matched in width to the control bank below/above them** (Delay's 2×3, VoiceBox's 2×5) — never one stretched full-width row.

---

## 6. Typography scale
| Use | Font |
|---|---|
| Brand | system 9pt semibold, kern 1.2 |
| Section / row name | system 11–12pt heavy, kern 0.6–0.8 |
| Knob label | system 8.5pt medium, kern 0.6 |
| Value / readout | **monospaced-digit**, 8–9pt |
| Axis / caption / tag | **monospaced** 7pt, `inkMid`, kern 0.5 |

Monospaced for anything numeric or "machine" (tags, values, axes); proportional system for names/brand.

**Size scale: 7 / 9 / 11 / 13 / 16.** Fractional sizes (6.5 / 7.5 / 8.5 / 9.5) were snapped
suite-wide in 2026-09 (knob label + value are now 9pt). Sizes 8 / 10 / 12 are still in use in
older files (≈85 call sites) — snap to the nearest scale step when you are already editing a file.

---

## 7. Layout grid
- Align everything to a shared margin (16–18px) and a small set of gaps (6/8px).
- Group controls into **banks** and visualizers into **inset panels**; align bank width to its related panel.
- Vertical order convention: **visualizer(s) up top → controls below → brand footer.** (Drums varies for its sequencer, but FX plug-ins should follow this.)
- Don't let subviews overlap hit regions of buttons (caused the Limiter preset bug; passive displays should `hitTest → nil`).

---

## 8. Per-plugin audit checklist
For each plug-in, verify: footer brand block ✓ · hairline divider ✓ · spec tag ✓ · all colors from `Palette` (no inline `NSColor(white:)`) ✓ · knobs equal-size in banks, output knobs white ✓ · every visualizer is a panelBg line/bar (no dials) ✓ · stacked visualizers match ✓ · pills/presets follow §5 ✓ · margins/gaps from §7 ✓ · red used as a spotlight not a wash ✓.

### Status (2026-09-04, third pass)
- **BigKnob / PitchKnob** — code-drawn plain discs (silver / red twins), thin bevel, contact halo; both with a dark recessed centre hub (Nicky rejected the cream cap on BigKnob). ✓
- **EQ** — curve follows the handles; area fill to 0 dB; 2 px line. ✓
- **Reverb** — Metal "SPACE" preview (rings by SIZE / DECAY / DAMPING, live level). ✓
- **VoiceBox** — 8th card LOW TUNER; spectrum with grid, axes, gradient, peak-hold. ✓

### Status (2026-09-04, second pass)
- **Drums** — 12 rows: LONG SUB (808 / PURE / HOLLOW / GROWL / SLIDE) under SUB; spec tag `12 VOICES`; name column widened to 66 px. ✓
- **SynthThing** — RESET in the top bar next to PRESET / RANDOM; grid defaults to 32 steps; RANDOM writes chords + a two-bar motif. ✓
- **BassMitStimme** — KEYS header: RESET · PLAY · MUTATE · RANDOM, LEN 8/16/32/64 (default 32), the generator writes chord-outlining bass lines. ✓
- **Handy** — behaviour fixes (REV chop, 1-SHOT stutter, waveform after reload); the Handy Dude sticker moved to the left end of the RESTORATION CHAIN panel (it sat under the PITCH knob). ✓
- **BassMitStimme** footer — three zero-frame KnobViews (stmHP/stmLP/stmFilt) no longer draw over the brand block; scope label moved to the top-left of the scope. ✓

### Status (2026-09-04 pass)
- **Delay** — redesigned to §7 order: ECHO TAPS panel (every repeat as a red tap on a beat/ms axis, L up / R down, decay envelope, HIGH darkens the tail, WOBBLE jitters it) replaces the ring visualizer; 2×4 preset grid; knob bank in TIME · FEEDBACK · MOD · OUT sections; **SYNC** pill swaps the TIME knobs for note-division cells (1/32 … 1/2, T/D) locked to Logic's tempo; PING-PONG pill. Uses `BrandStrip` for both bars. ✓
- **SynthThing** — DUBSTEP is back on the panel: DUBSTEP toggle in the bottom row, WOB strip (8 beat cells incl. the new **1/16 CHOP / 1/32 CHOP** gates, playhead underline) + **NOTE** length 1× / 2× / 4× / HOLD for the long slowed-down notes. Footer via `BrandStrip`. ✓
- **Shared UI infra** — `Shared/UI/` (Palette, KnobView, BrandStrip, BrandLogo, FaceTexture) + `sync_shared_ui.sh`; radius + fractional-font snap suite-wide. ✓

### Status (2026-08-31 alignment pass)
- **Every plug-in** now runs the dark scheme; §1's dark tokens went into all 17 `Palette.swift` copies and ~280 inline colour declarations were re-routed through `Palette.*` (only alpha-derived shading and one-off wells remain inline, by design).
- **Drums** — REFERENCE STANDARD ✓ (spec tag added).
- **Compressor** — dark-scheme pioneer, aligned ✓. Duck mascot = backwards-cap + shades vector.
- **SynthThing** — aligned ✓ (spec tag added). Visualizer CPU caching still open.
- **RoarBass** — re-skinned from its rogue orange identity: suite `KnobView` (KnobTex + cream cap + red pointer), `faceBg` + `FaceTexture`, `panelDark` section boxes, standard footer (BrandLogo + PARADISE AUDIO + RBS-1 + spec tag). Texture PNGs copied into its Resources. ✓
- **BassMitStimme / StringThing** — spec tags added ✓.
- **Reverb / Saturation / Deesser / Delay / Handy / BigKnob / PitchKnob / UltraReverse** — token pass ✓, frame elements verified (footer, hairline, spec tag) ✓.
- **Limiter / EQ** — token pass ✓; recent reworks already follow §3/§4.
- **VoiceBox** — token pass ✓ (0.15 panel drift → `panelDark`); adopted the suite `KnobView` at 78×86 and got the autotune (YIN + PSOLA) module, so task #11 is closed. ✓
