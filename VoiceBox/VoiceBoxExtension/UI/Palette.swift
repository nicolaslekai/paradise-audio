//
//  Palette.swift  —  Paradise Audio shared visual tokens.
//
//  Single source of truth for the palette across every plug-in's UI.
//  All values use the calibrated APIs so the same constant resolves to
//  the same on-screen colour regardless of the user's display profile.
//
//  The suite runs the ANALOG TEAL scheme (2026-11-20): painted teal steel
//  face, cream screen-print ink, recessed dark inset panels, Paradise red
//  as the single accent. The OP-1 cream tokens survive below.
//

import AppKit

enum Palette {
    // ── Analog teal scheme (suite standard since 2026-11-20) ─────────
    // Painted-steel faceplate (FaceTexture: teal enamel bitmap), cream
    // screen-print ink, rubber keys, Blender-rendered knob bodies. Colour
    // ROLES are unchanged: white = volume/output, red = accent/active,
    // dark = everything else. The pre-analog dark values live in
    // Shared/UI/Palette.swift.pre-analog.
    /// Solid faceplate base (teal enamel) — FaceTexture.draw paints the
    /// textured bitmap over it; this is the fallback / gap colour.
    static let faceBg    = NSColor(calibratedRed: 0.169, green: 0.267, blue: 0.275, alpha: 1.0)
    /// Recessed inset panel behind visualizers, meters and readouts.
    static let panelDark = NSColor(calibratedRed: 0.094, green: 0.137, blue: 0.141, alpha: 1.0)
    /// Primary screen-print ink — titles, strokes, tick marks.
    static let inkLight  = NSColor(calibratedRed: 0.914, green: 0.875, blue: 0.788, alpha: 1.0)
    /// Secondary screen-print ink — captions, axes, value readouts.
    static let inkMidL   = NSColor(calibratedRed: 0.663, green: 0.659, blue: 0.596, alpha: 1.0)
    /// Default (non-output) knob body fill when the knob bitmap is missing.
    static let knobBody  = NSColor(calibratedWhite: 0.17, alpha: 1.0)
    /// Deep recessed well behind waveform strips and transport bars.
    static let wellBg    = NSColor(calibratedRed: 0.063, green: 0.098, blue: 0.102, alpha: 1.0)

    // ── Screen-print typography (DIN ships with macOS) ───────────────
    /// Labels, values, pills — DIN Alternate Bold.
    static func printFont(_ size: CGFloat) -> NSFont {
        NSFont(name: "DINAlternate-Bold", size: size) ?? .systemFont(ofSize: size, weight: .semibold)
    }
    /// Names, titles, brand — DIN Condensed Bold.
    static func printFontCondensed(_ size: CGFloat) -> NSFont {
        NSFont(name: "DINCondensed-Bold", size: size) ?? .systemFont(ofSize: size, weight: .bold)
    }

    // Raised 3D key gradients (ButtonTex.draw code-rendered fallback).
    /// Active (red) key — gradient top.
    static let keyRedTop  = NSColor(calibratedRed: 0.93, green: 0.22, blue: 0.18, alpha: 1.0)
    /// Active (red) key — gradient bottom.
    static let keyRedBot  = NSColor(calibratedRed: 0.66, green: 0.10, blue: 0.09, alpha: 1.0)
    /// Inactive (dark) key — gradient top.
    static let keyDarkTop = NSColor(calibratedWhite: 0.27, alpha: 1.0)
    /// Inactive (dark) key — gradient bottom.
    static let keyDarkBot = NSColor(calibratedWhite: 0.145, alpha: 1.0)

    // ── OP-1 cream heritage tokens ───────────────────────────────────
    /// OP-1 cream — knob caps, active-pill label text.
    static let cream     = NSColor(calibratedRed: 0.82, green: 0.79, blue: 0.74, alpha: 1.0)
    /// Light-grey inset panel (legacy light scheme; unused on dark faces).
    static let panelBg   = NSColor(calibratedWhite: 0.84, alpha: 1.0)
    /// Near-black ink (legacy light scheme).
    static let ink900    = NSColor(calibratedWhite: 0.12, alpha: 1.0)
    /// Mid-grey ink (legacy light scheme).
    static let ink500    = NSColor(calibratedWhite: 0.45, alpha: 1.0)
    /// Paradise red — active states, pointers, data lines, brand marker.
    static let accent    = NSColor(calibratedRed: 0.88, green: 0.14, blue: 0.12, alpha: 1.0)

    // ── Legacy names kept for ergonomic call sites. ──────────────────
    static let inkDark   = ink900
    static let inkMid    = ink500
    static let red       = accent
    static let accentRed = accent
}
