# Compressor — Gemini render prompt

Model: `gemini-3-pro-image-preview` (Nano Banana Pro)
Aspect: 16:9
Resolution: 2K
Mode: IMAGE

## System prompt

```
You are a product UI designer in the Teenage Engineering OP-1 / OP-Z school —
rough, clean, utilitarian, Japanese design sensibility. You render flat 2D
mockups of audio plug-in interfaces as they would appear inside a DAW. The
mockup must look like a real UI surface, not a 3D product shot. No
photographic perspective, no reflections, no rounded "device" framing — flat
faceplate seen straight on, filling the canvas.

PALETTE:
- Surface: warm off-white cream (#EFEAE0), with very subtle paper-grain noise
- Ink: near-black (#1F1F1F) for labels and tick marks
- Accent: one single vivid red (#E12422) used SPARINGLY — only for knob
  indicator lines, the gain-reduction meter fill, and a single small square
  brand mark. Never as a fill of a knob body or large panel.
- Secondary gray: medium gray (#6D6D6D) for inactive labels, value readouts,
  hairline separators

TYPOGRAPHY:
- All labels are TINY, ALL CAPS, sans-serif, slightly tracked out
- Screen-printed look — not vector-perfect, very subtle imperfection
- Two type sizes only: tiny label (~8pt) and tinier value readout (~7pt)

LAYOUT:
- Flat faceplate seen straight on, filling 16:9 canvas with generous margins
- All controls aligned on a strict horizontal baseline grid
- Generous negative space — uncluttered, almost monastic
- Hairline separators where needed, no boxes or panels around controls

KNOBS:
- Small dark gray circular encoder bodies (~40-50px diameter relative to a
  ~1920px wide canvas)
- Thin red indicator line from center to edge showing current value
- Tick marks at min/max angles outside the knob
- ALL CAPS label directly below the knob
- Tiny value readout below the label
```

## Per-shot prompt

```
SHOT: Compressor plug-in UI mockup, flat 2D faceplate

A 16:9 flat faceplate of an audio compressor plug-in, cream off-white
background filling the entire canvas. Six identical small dark encoder knobs
in a single perfectly aligned horizontal row across the upper portion of the
faceplate, with generous equal spacing between them. Each knob has a thin
vivid red indicator line and tiny ALL CAPS label beneath:

  THRESHOLD     RATIO     ATTACK     RELEASE     KNEE     MIX

Each label has a tinier value readout below it in medium gray monospaced
type ("-18 dB", "4.0:1", "5 ms", "80 ms", "6 dB", "100%").

To the right of the knob row sits a small vertical gain-reduction meter:
a thin gray track with a red fill from the top, small tick marks at -6/-12/
-18 dB on its left side, tiny "GR" label beneath.

Bottom-left corner: a single tiny vivid red square (8x8 px) followed by the
ALL CAPS wordmark "ANTHROPIC AUDIO" in semibold, and underneath in medium
gray smaller type: "COMPRESSOR — CMP-1".

Bottom-right corner: a small monospaced tag in medium gray: "AU v3 · STEREO".

A subtle paper-grain noise overlays the cream surface. A single hairline
separator runs horizontally near the bottom dividing the controls from the
footer text.

Style: Teenage Engineering OP-1 industrial / Japanese utilitarian. Rough,
clean, restrained. Front-facing flat composition, no perspective, no 3D, no
reflections, no shadows behind the panel. The faceplate fills the frame.
```

## ComfyUI nodes

- 1 × LoadImage if you have an OP-1 face-on reference photo handy (helps lock
  the cream tone and proportion). Otherwise generate from scratch.
- 1 × GeminiImage2Node (gemini-3-pro-image-preview, 16:9, 2K, IMAGE)
- 1 × PreviewImage
- 1 × SaveImage → `Compressor_UI_v1.png` to `/AUDIO SYNTH/Compressor/renders/`

If using a reference photo: BatchImagesNode with the OP-1 face shot as
`image0`, then prompt opening with `IMAGE INPUTS: Image 0 = OP-1 cream
faceplate reference for surface tone and proportion.`
