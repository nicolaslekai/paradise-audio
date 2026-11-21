//
//  Palette.swift  —  Paradise Audio shared visual tokens.
//
//  Single source of truth for the palette across every plug-in's UI.
//  Was previously re-declared inline in every parameter view file; small
//  drift had crept in (one plug-in had a rogue cream value, ~half the
//  files used uncalibrated `NSColor(white:)` which resolves slightly
//  differently per display profile).
//
//  All values use the calibrated APIs so the same constant resolves to
//  the same on-screen colour regardless of the user's display profile.
//

import AppKit

enum Palette {
    /// OP-1 cream — main panel background.
    static let cream     = NSColor(calibratedRed: 0.82, green: 0.79, blue: 0.74, alpha: 1.0)
    /// Light-grey inset panel background (curves, meters, sub-modules).
    static let panelBg   = NSColor(calibratedWhite: 0.84, alpha: 1.0)
    /// Primary text / strokes — near-black ink.
    static let ink900    = NSColor(calibratedWhite: 0.12, alpha: 1.0)
    /// Secondary text — mid grey for labels, captions, axis ticks.
    static let ink500    = NSColor(calibratedWhite: 0.45, alpha: 1.0)
    /// Paradise red — active states, accent fills, brand marker.
    static let accent    = NSColor(calibratedRed: 0.88, green: 0.14, blue: 0.12, alpha: 1.0)

    // ── Legacy names kept for ergonomic call sites. ──────────────────
    //  Per-view code historically used `cream`, `inkDark`, `inkMid`,
    //  `red`/`accentRed`. Keep these so existing files only need to
    //  swap their `private let X = NSColor(...)` line for
    //  `private let X = Palette.X` without renaming every reference.
    static let inkDark   = ink900
    static let inkMid    = ink500
    static let red       = accent
    static let accentRed = accent
}
