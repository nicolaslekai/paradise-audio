//
//  DrumsParameterView.swift
//  Paradise Audio — ENGINE 909 (DR-1)
//
//  Performance-tuned redraw. The previous version regenerated 150k+ random
//  fills per frame inside drawNoise() — that was the primary reason this AU
//  felt sluggish inside Logic. Now:
//   • Film-grain noise is rendered once into a static CGImage at first draw,
//     then blitted in O(1).
//   • Attribute dictionaries are cached at module scope.
//   • The 15 fps animation timer only invalidates the voice-rows band (not
//     the whole view) and only fires while the sequencer is playing AND the
//     playhead column actually changed since the last tick.
//   • Genre presets dropdown (20 patterns) added next to BARS.
//   • Paint-swipe (drag across cells) is preserved.
//

import AppKit
import AudioToolbox
import UniformTypeIdentifiers

private let kNumVoices = 12
// Master clock subdivisions per bar. Per-voice resolution (8/16/32/64) is a
// subset of these slots; cells line up against the same bar boundaries.
private let kSubdiv    = 64
private let kInternalSteps = 512  // 8 bars × 64
private let kVoiceNames = ["KICK","SNARE","CLAP","JNG SN","TOM 1","TOM 2","HAT M","HAT C","HAT O","CRASH","SUB","LONG SUB"]

// Character labels are no longer hard-coded here — every voice now exposes 5
// reference-modelled variants and the names come straight from the engine via
// `characterName(forVoice:character:)` / `characterCount(forVoice:)`. For
// reference the current sets are: KICK 808/909/LINN/DMX/ACOUS · SNARE STD/
// TIGHT/CLAP/LINN/AMEN · CLAP 808/909/LINN/STUDIO/WASH · RIM STD/HI/WOOD/AMEN/
// THINK · TOM STD/DEEP/ROTO/LINN/909 · HAT WHT/MET/PED/LINN/808 · CRASH STD/
// CHINA/SPLSH/RIDE/808 · SUB DEEP/TIGHT/WARM/DROP/REESE · LONG SUB 808/PURE/
// HOLLOW/GROWL/SLIDE (2–3 s sustained sub notes).

// MARK: - Color palette
// Dark scheme — matches SynthThing / Compressor: light ink on a dark faceplate.
// (Cream is kept only as the light accent used for knob caps + active-toggle text.)
private let cream     = Palette.cream
private let inkDark   = Palette.inkLight   // primary text / strokes (light)
private let inkMid    = Palette.inkMidL   // secondary text
private let red       = Palette.red
private let faceBg    = Palette.faceBg   // dark faceplate
private let panelDark = Palette.panelDark   // dark inset panels
private let cellOff   = Palette.knobBody   // empty step cell on dark

// MARK: - Cached attribute dictionaries (allocating these per frame was hot)
private let aTag: [NSAttributedString.Key: Any]      = [.font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular), .foregroundColor: inkMid, .kern: 0.5]
private let aPlayOn: [NSAttributedString.Key: Any]   = [.font: Palette.printFont(11),      .foregroundColor: red, .kern: 0.8]
private let aPlayOff: [NSAttributedString.Key: Any]  = [.font: Palette.printFont(11),      .foregroundColor: inkDark, .kern: 0.8]
private let aBtn: [NSAttributedString.Key: Any]      = [.font: Palette.printFont(11),  .foregroundColor: inkDark, .kern: 0.8]
private let aLabBold: [NSAttributedString.Key: Any]  = [.font: Palette.printFont(10),      .foregroundColor: inkDark, .kern: 0.8]
private let aVal: [NSAttributedString.Key: Any]      = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: inkDark]
private let aSlotOn: [NSAttributedString.Key: Any]   = [.font: Palette.printFont(10),     .foregroundColor: cream]
private let aSlotOff: [NSAttributedString.Key: Any]  = [.font: Palette.printFont(10),  .foregroundColor: inkDark]
private let aDiv: [NSAttributedString.Key: Any]      = [.font: Palette.printFont(9),   .foregroundColor: inkMid]
private let aVoice: [NSAttributedString.Key: Any]    = [.font: Palette.printFontCondensed(14),  .foregroundColor: inkDark, .kern: 0.6]
private let aRead: [NSAttributedString.Key: Any]     = [.font: Palette.printFont(9),  .foregroundColor: inkDark, .kern: 0.4]
private let aReadDim: [NSAttributedString.Key: Any]  = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular), .foregroundColor: inkMid]
private let aCLR: [NSAttributedString.Key: Any]      = [.font: NSFont.monospacedSystemFont(ofSize: 8, weight: .heavy), .foregroundColor: inkDark, .kern: 0.6]
private let aTogOn: [NSAttributedString.Key: Any]    = [.font: Palette.printFont(9),      .foregroundColor: cream]
private let aTogOff: [NSAttributedString.Key: Any]   = [.font: Palette.printFont(9),  .foregroundColor: inkDark]
private let aFLT: [NSAttributedString.Key: Any]      = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .heavy), .foregroundColor: inkDark, .kern: 0.6]
private let aBrand: [NSAttributedString.Key: Any]    = [.font: Palette.printFont(15),      .foregroundColor: inkDark, .kern: 1.2]
private let aGenre: [NSAttributedString.Key: Any]    = [.font: Palette.printFont(10),      .foregroundColor: cream, .kern: 0.8]

// MARK: - Genre presets

/// 20 genres × 3 variations × per-voice resolution. Picking a variation:
///   • Sets the engine BPM to the genre's canonical tempo.
///   • Sets each voice's resolution to whatever that variation requires
///     (e.g. DnB hats at 32 for fast rolls, kick still at 16).
///   • Tiles the 1-bar pattern across all 8 bars of the current slot.
///
/// Pattern string length matches the row's resolution:
///   • r8  → 8 chars per bar
///   • r16 → 16 chars per bar
///   • r32 → 32 chars per bar
///
/// Voice order matches kVoiceNames:
/// 0 KICK · 1 SNARE · 2 CLAP · 3 RIM · 4 TOM1 · 5 TOM2 · 6 TOM3 · 7 HATC · 8 HATO · 9 CRASH
private struct VoiceRow { let res: Int; let pattern: String }
private struct DrumVariation { let name: String; let rows: [VoiceRow] }
private struct DrumPreset { let name: String; let bpm: Float; let variations: [DrumVariation] }

// Compact constructors and an empty row for unused voices.
private func r8(_ p: String)  -> VoiceRow { VoiceRow(res: 8,  pattern: p) }
private func r16(_ p: String) -> VoiceRow { VoiceRow(res: 16, pattern: p) }
private func r32(_ p: String) -> VoiceRow { VoiceRow(res: 32, pattern: p) }
private func r64(_ p: String) -> VoiceRow { VoiceRow(res: 64, pattern: p) }
private let E16 = VoiceRow(res: 16, pattern: "................")
private let E32 = VoiceRow(res: 32, pattern: "................................")
private let E64 = VoiceRow(res: 64, pattern: "................................................................")

private let kPresets: [DrumPreset] = [
    DrumPreset(name: "House 4/4", bpm: 124, variations: [
        DrumVariation(name: "A — Basic", rows: [r16("X...X...X...X..."), r16("........X......."), r16("....X.......X..."), E16, E16, E16, E16, r32("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("....X.......X.......X.......X..."), r16("X...............")]),
        DrumVariation(name: "B — Driving", rows: [r16("X...X...X...X..."), r16("....X.......X..."), r16("....X.......X..."), r16("..X...X...X...X."), E16, E16, E16, r32("XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"), r32("....X.......X.......X.......X..."), r16("X...............")]),
        DrumVariation(name: "C — Broken", rows: [r16("X.....X.X...X..."), r16("....X.......X.X."), r16("....X..........."), r16("..X.......X....."), E16, E16, E16, r32("X.X...X.X.X...X.X.X...X.X.X...X."), r32("....X.......X.......X.......X..."), r16("X...............")]),
        DrumVariation(name: "D — Fill", rows: [r16("X.......X......."), r16("....X.X.X.X.X.XX"), r16("....X..........."), E16, r16("............X..."), r16(".............X.."), E16, r32("X.X.X.X.X.X.X.X.X.X.X.X.XXXXXXXX"), r32("..............................XX"), r16("X..............X")]),
    ]),

    DrumPreset(name: "Deep House", bpm: 120, variations: [
        DrumVariation(name: "A — Basic", rows: [r16("X...X...X...X..."), E16, r16("....X.......X..."), E16, E16, E16, E16, r32("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("....X.......X.......X.......X..."), r16("X...............")]),
        DrumVariation(name: "B — Driving", rows: [r16("X...X...X...X..."), r16("........X......."), r16("....X.......X..."), r16("..X...X...X...X."), E16, E16, E16, r32("XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"), r32("....X.......X.......X.......X..."), r16("X...............")]),
        DrumVariation(name: "C — Broken", rows: [r16("X.....X.X.....X."), E16, r16("....X.......X..."), r16("..X.....X.X....."), E16, E16, E16, r32("..X...X...X...X...X...X...X...X."), r32("....X.......X.......X.......X..."), r16("X...............")]),
        DrumVariation(name: "D — Fill", rows: [r16("X...X...X......."), r16("....X.....X.X.XX"), r16("....X..........."), E16, r16("............X..."), r16(".............X.."), E16, r32("X.X.X.X.X.X.X.X.X.X.X.X.XXXXXXXX"), E32, r16("X..............X")]),
    ]),

    DrumPreset(name: "Tech House", bpm: 126, variations: [
        DrumVariation(name: "A — Basic", rows: [r16("X...X...X...X..."), r16("........X......."), r16("....X.......X..."), r16("..X...X...X...X."), E16, E16, E16, r32("..X...X...X...X...X...X...X...X."), r32("......X.......X.......X.......X."), r16("X...............")]),
        DrumVariation(name: "B — Driving", rows: [r16("X...X...X...X.X."), r16("....X.......X..."), r16("....X.......X..."), r16("X.X.X.X.X.X.X.X."), E16, E16, E16, r32("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("..X...X...X...X...X...X...X...X."), r16("X...............")]),
        DrumVariation(name: "C — Broken", rows: [r16("X.X.....X...X..."), r16("....X.......X.X."), r16("....X..........."), r16("..X...X.X...X.X."), E16, E16, E16, r32("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("..X...X.......X...X.....X...X..."), r16("X...............")]),
        DrumVariation(name: "D — Fill", rows: [r16("X...X..........."), r16("....X.X.X.XX.XXX"), r16("....X..........."), E16, r16("............X..."), r16(".............X.."), E16, r32("X.X.X.X.X.X.X.X.X.X.X.X.XXXXXXXX"), r32("..............................XX"), r16("X..............X")]),
    ]),

    DrumPreset(name: "Techno", bpm: 130, variations: [
        DrumVariation(name: "A — Basic", rows: [r16("X...X...X...X..."), E16, r16("....X.......X..."), r16("..X...X...X...X."), E16, E16, E16, r32("..X...X...X...X...X...X...X...X."), r32("......X.......X.......X.......X."), E16]),
        DrumVariation(name: "B — Driving", rows: [r16("X...X...X...X..."), r16("....X.......X..."), E16, r16("X.X.X.X.X.X.X.X."), E16, E16, E16, r32("XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"), r32("......X.......X.......X.......X."), r16("X...............")]),
        DrumVariation(name: "C — Broken", rows: [r16("X...X.X.X...X.X."), r16("....X.......X..."), r16("............X..."), r16("..X...X...X....."), E16, r16("..........X....."), E16, r32("X.......X.......X.......X......."), r32("..X...X...X...X...X...X...X...X."), r16("X...............")]),
        DrumVariation(name: "D — Fill", rows: [r16("X...X...X......."), r16("........X.X.X.XX"), r16("....X..........."), E16, r16("............X..."), r16(".............X.."), E16, r32("X.X.X.X.X.X.X.X.X.X.X.X.XXXXXXXX"), r32("..X...X...X...X.X.X.X.X.X.X.X.X."), r16("X..............X")]),
    ]),

    DrumPreset(name: "Minimal Techno", bpm: 125, variations: [
        DrumVariation(name: "A — Basic", rows: [r16("X...X...X...X..."), E16, r16("....X.......X..."), E16, E16, E16, E16, r32("X.......X.......X.......X......."), E32, E16]),
        DrumVariation(name: "B — Driving", rows: [r16("X...X...X...X..."), E16, r16("....X.......X..."), r16("..X.....X.X...X."), E16, E16, E16, r32("X.......X.......X.......X......."), E32, E16]),
        DrumVariation(name: "C — Broken", rows: [r16("X.....X...X....."), E16, r16("....X..........."), r16("..X...X.X...X.X."), E16, r16("............X..."), E16, r32("....X.........X.X.......X......."), r32("........X......................."), E16]),
        DrumVariation(name: "D — Fill", rows: [r16("X.......X......."), r16("........X...X.X."), r16("....X..........."), r16("............X.X."), r16("............X..."), r16(".............X.."), E16, r32("X.X.X.X.X.X.X.X.XXXXXXXXXXXXXXXX"), r32("..X.....X.X....................."), r16("X...............")]),
    ]),

    DrumPreset(name: "Trap", bpm: 140, variations: [
        // Trap hats reworked: 16ths broken by 32nd runs, triplet-feel 3-hit
        // clusters, and building 64th tears — the signature trap hat motion.
        DrumVariation(name: "A — Basic", rows: [r16("X.......X.X....."), r16("........X......."), r16("........X......."), E16, E16, E16, E16, r32("X.X.X.X.X.X.X.X.X.X.X.X.X.X.XXXX"), r32("............X...............X..."), r16("X...............")]),
        DrumVariation(name: "B — Driving", rows: [r16("X.....X.X.X....."), r16("........X......."), r16("........X......."), r16("............X..."), E16, E16, E16, r64("X...X...X...X...X...X...X...X...X.X.X.X.X.X.X.X.X...X...X...XXXX"), r32("....................X..........."), r16("X...............")]),
        DrumVariation(name: "C — Broken", rows: [r16("X.....X...X...X."), r16("........X......."), r16("........X......."), r16("....X.......X..."), E16, E16, E16, r32("X.X.X.X.XXX.X.X.X.X.X.X.XXX.XXXX"), r32("......X...............X........."), r16("X...............")]),
        DrumVariation(name: "D — Fill", rows: [r16("X.......X......."), r16("........X......."), r16("........X......."), E16, E16, E16, E16, r64("X...X...X...X...X...X...X...X...X.X.X.X.X.X.X.X.XXXXXXXXXXXXXXXX"), r32("............................X..."), r16("X...............")]),
    ]),

    DrumPreset(name: "Boom Bap", bpm: 92, variations: [
        DrumVariation(name: "A — Basic", rows: [r16("X.......X......."), r16("....X.......X..."), E16, E16, E16, E16, E16, r32("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("..............X................."), r16("X...............")]),
        DrumVariation(name: "B — Driving", rows: [r16("X.....X.X......."), r16("....X.......X..."), E16, E16, E16, E16, E16, r32("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("....................X..........."), r16("X...............")]),
        DrumVariation(name: "C — Broken", rows: [r16("X.....X.....X..."), r16("....X.X...X.X.X."), E16, E16, E16, E16, E16, r32("X..XX.X..XX.X.X.X..XX.X..XX.X.X."), r32("............X.................X."), r16("X...............")]),
        DrumVariation(name: "D — Fill", rows: [r16("X.......X......."), r16("....X.......X.XX"), E16, E16, r16("............X..."), r16(".............X.."), E16, r32("X.X.X.X.X.X.X.X.XXXXXXXXXXXXXXXX"), r32(".............................X.X"), r16("X..............X")]),
    ]),

    DrumPreset(name: "Lo-Fi Hip Hop", bpm: 80, variations: [
        DrumVariation(name: "A — Mellow", rows: [r16("X.......X......."), r16("....X.......X..."), E16, E16, E16, E16, E16, r32("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("..............X................."), E16]),
        DrumVariation(name: "B — Driving", rows: [r16("X.....X.X......."), r16("....X.......X..."), r16("....X..........."), r16("..............X."), E16, E16, E16, r32("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("....................X..........."), E16]),
        DrumVariation(name: "C — Broken", rows: [r16("X......XX...X..."), r16("....X......XX..."), E16, E16, E16, E16, E16, r32("X.X.XX..X.X.X.X.X.X.XX..X.X.X.X."), r32("............X..................."), E16]),
        DrumVariation(name: "D — Fill", rows: [r16("X.......X......."), r16("....X.....X.X.X."), E16, E16, r16("............X..."), r16(".............X.."), E16, r32("X.X.X.X.X.X.X.X.XXXXXXXXXXXXXXXX"), r32("...............................X"), E16]),
    ]),

    DrumPreset(name: "Drum & Bass", bpm: 174, variations: [
        // A — Amen Bar 1: kick on 1 + "kick-on-the-and" doublet at 10/11,
        //     main snare on 5 and 13, Jungle Snare ghosts on the and-of-2
        //     (step 7) and the pickup back to bar 1 (step 15).
        DrumVariation(name: "A — Amen", rows: [r16("X.........XX...."), r16("....X.......X..."), E16, r16(".......X.......X"), E16, E16, r16("X.X.X.X.X.X.X.X."), r32("XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"), E16, r16("X...............")]),
        // B — Amen Bar 2: kick on 1 and step 11, snare flam at the end
        //     (step 13 + 14). Jng Sn doubles on the snare and adds a ghost
        //     at step 2 — the bar that always gets chopped into ratchets.
        DrumVariation(name: "B — Amen B2", rows: [r16("X..........X...."), r16("....X.......X.X."), E16, r16("..X.X.......XXX."), E16, E16, r16("X.X.X.X.X.X.X.X."), r32("XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"), E16, E16]),
        // C — Time-Stretch: 32nd-grid chopped Amen with the offset "feel"
        //     of a stretched sample. Jng Sn lays ghosts between the main
        //     snares to fill the pulled-apart pattern. Photek/Source Direct.
        DrumVariation(name: "C — Stretched", rows: [r32("X.....................XX........"), r32("........X.......X.X.....X......."), E16, r32("....X.......X.X.....X.......X.X."), E16, E16, r32("..X...X...X...X.X.X.X.X...X...X."), r64("XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"), E16, r16("X...............")]),
        // D — Tear-Out: maximum 64th hat tear, Jng Sn carries a roll into
        //     the snare crack at the end of the bar. Bukem moment.
        DrumVariation(name: "D — Tear-Out", rows: [r16("X.........XX...."), r16("....X.......X..."), E16, r32("...........X.X.XX.X.X.X.X.XX.XXX"), E16, E16, r16("X.X.X.X.X.X.X.X."), r64("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"), r32("...............X..............X"), r16("X..............X")]),
    ]),

    DrumPreset(name: "Jungle", bpm: 170, variations: [
        DrumVariation(name: "A — Amen", rows: [r16("X.......X......."), r16("....X.......X..."), E16, E16, E16, E16, E16, r64("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("............X...............X..."), r16("X...............")]),
        DrumVariation(name: "B — Chopped", rows: [r16("X.......X......."), r32("........X.......X.X.....X......."), E16, E16, E16, E16, E16, r64("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("............X...............X..."), r16("X...............")]),
        DrumVariation(name: "C — Rolling", rows: [r32("X...............X...X..........."), r32("........X.X.....X...X.....X.X..."), E16, E16, E16, E16, E16, r64("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("............X...............X..."), r16("X...............")]),
        DrumVariation(name: "D — Fill", rows: [r64("X...............................X...............X..............."), r64("................X...X.......X...X.......X...X.......X.X........."), E16, E16, r16("............X..."), r16(".............X.."), E16, r64("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"), r32("...............................X"), r16("X..............X")]),
    ]),

    DrumPreset(name: "UK Garage", bpm: 135, variations: [
        DrumVariation(name: "A — Basic", rows: [r16("X.......X.X....."), r16("....X.......X..."), r16("....X.......X..."), E16, E16, E16, E16, r32("..X...X...X...X.X.X.X.X...X...X."), r32("....X.......X...............X..."), r16("X...............")]),
        DrumVariation(name: "B — Driving", rows: [r16("X.....X.X.X...X."), r16("....X.......X..."), r16("....X.......X..."), r16("..X...X...X...X."), E16, E16, E16, r32("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("....X...........X.......X......."), r16("X...............")]),
        DrumVariation(name: "C — Broken", rows: [r16("X.....X...X.X..."), r16("....X.....X.X..."), r16("....X..........."), r16("..X.......X....."), E16, E16, E16, r32("..X.X.X.X.X.X...X.X...X.X.X.X.X."), r32("....X.......X...............X..."), r16("X...............")]),
        DrumVariation(name: "D — Fill", rows: [r16("X.......X......."), r16("....X.X.X.X.X.XX"), r16("....X..........."), E16, r16("............X..."), r16(".............X.."), E16, r32("X.X.X.X.X.X.X.X.XXXXXXXXXXXXXXXX"), r32("..............................XX"), r16("X..............X")]),
    ]),

    DrumPreset(name: "2-Step", bpm: 132, variations: [
        DrumVariation(name: "A — Basic", rows: [r16("X.........X....."), r16("....X.......X..."), r16("....X.......X..."), E16, E16, E16, E16, r32("..X...X...X...X...X...X...X...X."), r32("....X.......X..................."), r16("X...............")]),
        DrumVariation(name: "B — Driving", rows: [r16("X.....X...X.X..."), r16("....X.......X..."), r16("....X.......X..."), r16("..X.......X...X."), E16, E16, E16, r32("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("....X.......X..........X........"), r16("X...............")]),
        DrumVariation(name: "C — Broken", rows: [r16("X.....X.....X.X."), r16("....X.X.....X..."), r16("....X..........."), r16("..X.......X.X..."), E16, E16, E16, r32("..X.X.X...X.X.X...X.X.X...X.X.X."), r32("........X.......X.......X.X....."), r16("X...............")]),
        DrumVariation(name: "D — Fill", rows: [r16("X.......X......."), r16("....X.X...X.X.XX"), r16("....X..........."), E16, r16("............X..."), r16(".............X.."), E16, r32("..X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("...............................X"), r16("X..............X")]),
    ]),

    DrumPreset(name: "Dubstep", bpm: 140, variations: [
        DrumVariation(name: "A — Basic", rows: [r16("X..............."), r16("........X......."), r16("........X......."), E16, E16, E16, E16, r32("..X...X...X...X...X...X...X...X."), r32("....X...........X..............."), r16("X...............")]),
        DrumVariation(name: "B — Driving", rows: [r16("X.....X.....X.X."), r16("........X......."), r16("........X......."), r16("..X...X...X...X."), E16, E16, E16, r32("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("..........X.X..............X.X.X"), r16("X...............")]),
        DrumVariation(name: "C — Broken", rows: [r16("X.....X...X....."), r16("........X...X..."), r16("........X......."), r16("....X.......X.X."), E16, r16("............X..."), E16, r32("..X.X.X...X.X.X...X.X.X...X.X.X."), r32("........X.......X.......X......."), r16("X...............")]),
        DrumVariation(name: "D — Fill", rows: [r16("X.......X......."), r16("........X.X.X.XX"), r16("........X......."), E16, r16("............X..."), r16(".............X.."), E16, r64("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"), r32("..............................X."), r16("X..............X")]),
    ]),

    DrumPreset(name: "Disco", bpm: 118, variations: [
        DrumVariation(name: "A — Basic", rows: [r16("X...X...X...X..."), r16("....X.......X..."), r16("....X.......X..."), E16, E16, E16, E16, r32("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("....X.......X.......X.......X..."), r16("X...............")]),
        DrumVariation(name: "B — Driving", rows: [r16("X...X...X...X..."), r16("....X.......X..."), r16("....X.......X..."), r16("X.X.X.X.X.X.X.X."), E16, E16, E16, r32("XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"), r32("....X.......X.......X.......X..."), r16("X...............")]),
        DrumVariation(name: "C — Broken", rows: [r16("X...X...X.X.X..."), r16("....X.X.....X..."), r16("....X.......X..."), r16("..X...X.X...X.X."), E16, E16, E16, r32("..X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("....X.......X.......X.X...X.X..."), r16("X...............")]),
        DrumVariation(name: "D — Fill", rows: [r16("X.......X......."), r16("....X.X.X.X.X.XX"), r16("....X..........."), E16, r16("........X.X....."), r16("............X.X."), E16, r32("XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"), r32("..............................XX"), r16("X..............X")]),
    ]),

    DrumPreset(name: "Funk", bpm: 110, variations: [
        DrumVariation(name: "A — Basic", rows: [r16("X.......X......."), r16("....X.......X..."), E16, E16, E16, E16, E16, r32("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("....................X..........."), r16("X...............")]),
        DrumVariation(name: "B — Driving", rows: [r16("X..X..X.X......."), r16("....X..X.X.XX.X."), E16, E16, E16, E16, E16, r32("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("....X.......X...X.......X......."), r16("X...............")]),
        DrumVariation(name: "C — Broken", rows: [r16("X.....X.X.X....."), r16("....X.X...X.X.X."), E16, E16, E16, E16, E16, r32("X.XXX.X.X.XXX.X.X.XXX.X.X.XXX.X."), r32("..............X................."), r16("X...............")]),
        DrumVariation(name: "D — Fill", rows: [r16("X.......X......."), r16("....X.X...X.XXXX"), E16, E16, r16("............X.X."), r16(".............X.."), E16, r32("X.X.X.X.X.X.X.X.XXXXXXXXXXXXXXXX"), r32("....X...X.X.....X.X.X.X........."), r16("X..............X")]),
    ]),

    DrumPreset(name: "Breakbeat", bpm: 138, variations: [
        DrumVariation(name: "A — Basic", rows: [r16("X.....X.X......."), r16("....X.......X..."), E16, E16, E16, E16, E16, r32("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("............X...........X......."), r16("X...............")]),
        DrumVariation(name: "B — Driving", rows: [r16("X.....X.X.X....."), r16("....X.......X.X."), r16("....X.......X..."), r16("..............X."), E16, E16, E16, r32("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("..........X...X..........X...X.X"), r16("X...............")]),
        DrumVariation(name: "C — Broken", rows: [r16("X...X.X.....X.X."), r16("....X.X.X...X.X."), E16, r16("..X.........X..."), E16, E16, E16, r32("XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"), r32("............X.................X."), r16("X...............")]),
        DrumVariation(name: "D — Fill", rows: [r16("X.......X......."), r16("....X.X.X.X.X.XX"), r16("....X..........."), E16, r16("............X..."), r16(".............X.."), E16, r64("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"), r32("...............X...............X"), r16("X..............X")]),
    ]),

    DrumPreset(name: "Rock", bpm: 120, variations: [
        DrumVariation(name: "A — Basic", rows: [r16("X.......X......."), r16("....X.......X..."), E16, E16, E16, E16, E16, r32("X...X...X...X...X...X...X...X..."), E32, r16("X...............")]),
        DrumVariation(name: "B — Driving", rows: [r16("X...X.X.X...X.X."), r16("....X.......X..."), E16, E16, E16, E16, E16, r32("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("..............X................."), r16("X...............")]),
        DrumVariation(name: "C — Broken", rows: [r16("X.X...X.X.X....."), r16("....X.......X..."), E16, E16, E16, E16, E16, r32("X...X...X...X...X...X...X...X..."), r32("....................X..........."), r16("X...............")]),
        DrumVariation(name: "D — Fill", rows: [r16("X.......X......."), r16("....X.X.X.X....."), E16, E16, r16("..........X.X..."), r16("............X.X."), E16, r32("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), E32, r16("X..............X")]),
    ]),

    DrumPreset(name: "Reggaeton (Dembow)", bpm: 95, variations: [
        DrumVariation(name: "A — Basic", rows: [r16("X.......X......."), r16("....X..X..X..X.."), r16("....X..X..X..X.."), E16, E16, E16, E16, r32("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("..............X................."), r16("X...............")]),
        DrumVariation(name: "B — Driving", rows: [r16("X.....X.X.....X."), r16("....X..X..X..X.."), r16("....X..X..X..X.."), r16("..X...X...X...X."), E16, E16, E16, r32("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("....X.......X..................."), r16("X...............")]),
        DrumVariation(name: "C — Broken", rows: [r16("X.X.....X.X....."), r16("....X..X..X..X.."), r16("....X..X........"), r16("X.....X.....X..."), E16, E16, E16, r32("..X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("....X.......X....X......X......."), r16("X...............")]),
        DrumVariation(name: "D — Fill", rows: [r16("X.......X......."), r16("....X.X.X.X.X.XX"), r16("....X..X........"), E16, r16("............X..."), r16(".............X.."), E16, r32("X.X.X.X.X.X.X.X.XXXXXXXXXXXXXXXX"), r32("...............X................"), r16("X..............X")]),
    ]),

    DrumPreset(name: "Afrobeats", bpm: 108, variations: [
        DrumVariation(name: "A — Basic", rows: [r16("X.....X...X....."), E16, r16("....X.......X..."), r16("X..X..X..X..X..X"), E16, E16, E16, r32("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("............X...............X..."), r16("X...............")]),
        DrumVariation(name: "B — Driving", rows: [r16("X.....X...X.X..."), r16("........X......."), r16("....X.......X..."), r16("X..X..X..X..X..X"), E16, E16, E16, r32("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("............X...............X..."), r16("X...............")]),
        DrumVariation(name: "C — Broken", rows: [r16("X.....X.X...X..."), r16("........X......."), r16("....X.......X..."), r16("X..X.X.X..X.X.X."), E16, r16("............X..."), E16, r32("..X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("............X.......X..........."), r16("X...............")]),
        DrumVariation(name: "D — Fill", rows: [r16("X.......X......."), r16("....X.X...X.X.XX"), r16("....X..........."), E16, r16("............X..."), r16(".............X.."), E16, r32("X.X.X.X.X.X.X.X.X.X.X.X.XXXXXXXX"), r32(".............................X.X"), r16("X..............X")]),
    ]),

    DrumPreset(name: "Pop", bpm: 116, variations: [
        DrumVariation(name: "A — Basic", rows: [r16("X.......X......."), r16("....X.......X..."), r16("....X.......X..."), E16, E16, E16, E16, r32("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("..............X................."), r16("X...............")]),
        DrumVariation(name: "B — Driving", rows: [r16("X.....X.X...X..."), r16("....X.......X..."), r16("....X.......X..."), r16("..X...X...X...X."), E16, E16, E16, r32("XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"), r32("....................X..........."), r16("X...............")]),
        DrumVariation(name: "C — Broken", rows: [r16("X.....X...X.X..."), r16("....X.......X..."), r16("....X.......X..."), r16("..X.....X.....X."), E16, E16, E16, r32("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("............X.................X."), r16("X...............")]),
        DrumVariation(name: "D — Fill", rows: [r16("X.......X......."), r16("....X.X.X.X.X.XX"), r16("....X..........."), E16, r16("............X..."), r16(".............X.."), E16, r32("X.X.X.X.X.X.X.X.XXXXXXXXXXXXXXXX"), r32("...............................X"), r16("X..............X")]),
    ]),


    DrumPreset(name: "Gamelan", bpm: 110, variations: [
        DrumVariation(name: "A — Basic", rows: [r16("X.......X......."), E16, E16, r16(".X.X.X.X.X.X.X.X"), r16("....X.......X..."), E16, r16("X.X.X.X.X.X.X.X."), r32("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("................X..............."), r16("X...............")]),
        DrumVariation(name: "B — Polyrhythm", rows: [r16("X.....X.....X..."), E16, E16, r16("X..X..X..X..X..X"), r16("....X.......X..."), E16, r16("X.X.X.X.X.X.X.X."), r32("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("................X..............."), E16]),
        DrumVariation(name: "C — Kotekan", rows: [r16("X...X.....X....."), E16, E16, r16("X.X.X.X.X.X.X.X."), r16("..X...X...X...X."), E16, r16(".X.X.X.X.X.X.X.X"), r32(".X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X"), r32("............X.................X."), E16]),
        DrumVariation(name: "D — Climax", rows: [r16("X.......X......."), E16, E16, r16("X.X.X.X.X.X.X.X."), r16("..X.X.X.X.X.X.X."), r16(".........X.X.X.."), r16("XXXXXXXXXXXXXXXX"), r32("XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"), r32("...............................X"), r16("X..............X")]),
    ]),

    DrumPreset(name: "Afro Poly", bpm: 104, variations: [
        DrumVariation(name: "A — Basic", rows: [r16("X.....X...X....."), r16("....X.......X..."), E16, r16("X..X..X..X..X..X"), E16, E16, r16("..X...X...X...X."), r32("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("............X...............X..."), r16("X...............")]),
        DrumVariation(name: "B — Talking Drum", rows: [r16("X.....X...X...X."), r16("........X......."), r16("....X.......X..."), r16("X..X..X..X..X..X"), r16("............X..."), E16, r16("X.X.X.X.X.X.X.X."), r32("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("............X...............X..."), r16("X...............")]),
        DrumVariation(name: "C — Cross-Rhythm", rows: [r16("X.X.....X.X....."), E16, E16, r16("X.X.X.X.X.X.X.X."), r16("..X...X...X...X."), E16, r16("..X.X.X.X.X.X.X."), r32("..X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("............X.......X..........."), r16("X...............")]),
        DrumVariation(name: "D — Fill", rows: [r16("X.......X......."), r16("....X.X.X.X.X.XX"), E16, E16, r16("..X.X.X.X.X.X.X."), r16(".........X.X.X.."), E16, r32("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("...............................X"), r16("X..............X")]),
    ]),

    // Afro House — transcribed from a Borivers FL Studio short (120 BPM,
    // 3-3-2 groove). Perc 1 → TOM 1 (tresillo + beats 3/4), Perc 2 → TOM 2
    // (bar-8 run), shaker → HAT C 16ths, bass line → SUB rhythm (the SUB
    // pitch is per voice, so the E/D/C movement is rhythm only).
    // 11th row = SUB.
    DrumPreset(name: "Afro House", bpm: 120, variations: [
        DrumVariation(name: "A — Groove", rows: [r16("X...X...X...X..."), E16, E16, E16, r16("X..X..X.X...X..."), E16, E16, r32("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("....X.......X.......X.......X..."), r16("X..............."), r16("X.......X.X.X..X")]),
        DrumVariation(name: "B — Perc Loop", rows: [r16("X...X...X...X..."), E16, r16("....X.......X..."), E16, r16("X..X..X.X...X..."), E16, r16("..X...X...X.X.X."), r32("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("....X.......X.......X.......X..."), r16("X..............."), r16("X.......X.X.X..X")]),
        DrumVariation(name: "C — Stripped", rows: [r16("X...X...X...X..."), E16, E16, E16, r16("X..X..X.X...X..."), E16, E16, r32("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), E32, E16, E16]),
        DrumVariation(name: "D — Fill", rows: [r16("X...X...X...X..."), E16, E16, E16, r16("...X..X.X...X..."), r16("........XXX.XXX."), E16, r32("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("....X.......X.......X.......X..."), r16("X..............."), r16("......X.X.X.X.X.")]),
    ]),

    DrumPreset(name: "Tropical", bpm: 118, variations: [
        DrumVariation(name: "A — Basic", rows: [r16("X...X...X...X..."), r16("....X.......X..."), r16("....X.......X..."), r16("..X...X...X...X."), r16("........X......."), E16, r16("X.X.X.X.X.X.X.X."), r32("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("............X...............X..."), r16("X...............")]),
        DrumVariation(name: "B — Kendang Driving", rows: [r16("X...X...X...X..."), r16("....X.......X..."), r16("....X.......X..."), r16("X.X.X.X.X.X.X.X."), r16("........X......."), E16, r16("XXXXXXXXXXXXXXXX"), r32("XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"), r32("....X.......X........X.........."), r16("X...............")]),
        DrumVariation(name: "C — Broken Bali", rows: [r16("X.....X...X.X..."), r16("....X.......X..."), E16, r16("..X.X.X.X.X.X.X."), r16("............X..."), E16, r16("X.X.X.X.X.X.X.X."), r32("X.X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("....X......X.................X.X"), r16("X...............")]),
        DrumVariation(name: "D — Fill", rows: [r16("X.......X......."), r16("....X.X.X.X.X.XX"), E16, r16("..X.X.X.X......."), r16("............X..."), r16(".............X.."), r16("X.X.X.X........."), r32("..X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("...............................X"), r16("X..............X")]),
    ]),

    DrumPreset(name: "Ritual", bpm: 88, variations: [
        DrumVariation(name: "A — Slow", rows: [r16("X..............X"), E16, E16, r16("X...X...X...X..."), r16("......X.....X..."), E16, r16("..X.....X.....X."), r32("..X.....X.....X.X.....X.....X.X."), E32, r16("X...............")]),
        DrumVariation(name: "B — Building", rows: [r16("X.......X......."), E16, E16, r16("X.X.X.X.X.X.X.X."), r16("......X.....X..."), r16("..........X....."), r16("..X.....X.....X."), r32("..X.....X.....X.X.....X.....X.X."), r32("............X...............X..."), r16("X...............")]),
        DrumVariation(name: "C — Broken", rows: [r16("X......XX......."), E16, E16, r16("..X.X.X.X.X.X.X."), r16("......X.....X..."), E16, r16("X.....X.X.....X."), r32("X.....X.X.....X.X.....X.X.....X."), r32("............X...............X..."), r16("X...............")]),
        DrumVariation(name: "D — Crescendo", rows: [r16("X.......X......."), E16, E16, r16("X.X.X.X.X.X.X.X."), r16("....X.X.X.X.X.XX"), r16("..........X.X.X."), r16("..X.X.X.X.X.X.X."), r32("..X.X.X.X.X.X.X.X.X.X.X.X.X.X.X."), r32("...............................X"), r16("X..............X")]),
    ]),

]

// MARK: - Cached film-grain noise

/// Pre-rendered noise texture, generated once per view-size. Re-rolling 150k
/// random fills on every frame was the single largest CPU sink.
private final class NoiseCache {
    static let shared = NoiseCache()
    private var image: CGImage?
    private var size: NSSize = .zero
    func image(forSize s: NSSize) -> CGImage? {
        if let img = image, abs(size.width - s.width) < 0.5, abs(size.height - s.height) < 0.5 { return img }
        let w = Int(max(1, s.width.rounded()))
        let h = Int(max(1, s.height.rounded()))
        let cs = CGColorSpaceCreateDeviceRGB()
        let bpr = w * 4
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                   bytesPerRow: bpr, space: cs,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(NSColor.clear.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        var rng = SystemRandomNumberGenerator()
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                let n = Int(rng.next() % 200) - 100   // -100..99
                let dark = n < 0
                let a = CGFloat(abs(n)) / 100.0 * 0.045
                if a > 0.001 {
                    ctx.setFillColor(NSColor(calibratedWhite: dark ? 0 : 1, alpha: a).cgColor)
                    ctx.fill(CGRect(x: x, y: y, width: 2, height: 2))
                }
                x += 2
            }
            y += 2
        }
        let img = ctx.makeImage()
        self.image = img
        self.size = s
        return img
    }
}

final class DrumsParameterView: NSView {
    var audioUnit: DrumsAudioUnit? {
        didSet {
            // Mirror the engine's chain (restored from the project / state blob),
            // so the LINK row shows it — also while ISOLATE pauses it.
            if let au = audioUnit { chainSlotsLocal = au.chainSlots().map { $0.intValue } }
            needsDisplay = true
        }
    }

    // Transport hit-test rects, repopulated on each draw.
    private var patternRects: [NSRect] = []
    private var swingHitRect: NSRect = .zero
    private var barsHitRect: NSRect = .zero
    private var genreHitRect: NSRect = .zero
    private var pitchHitRect: NSRect = .zero
    private var noiseHitRect: NSRect = .zero
    private var velHitRect: NSRect = .zero      // VEL preset pill — click to cycle
    private var decayHitRect: NSRect = .zero    // DECAY knob — vertical drag
    // 2026-11 features
    private var isolateRect: NSRect = .zero     // ISOLATE key on the PATTERN line
    private var midiModeRect: NSRect = .zero    // header: MIDI MODE toggle
    private var exportMidiRect: NSRect = .zero  // header: EXPORT MIDI
    private var exportAudioRect: NSRect = .zero // header: EXPORT AUDIO ▾ (MIX / STEMS)
    private var rowDragSrc: Int? = nil          // row whose crosshair is being dragged
    private var rowDropTarget: Int? = nil       // row under the pointer while dragging
    private var exporting: String? = nil        // "midi" / "audio" while a render runs
    // Drag-out exports (2026-11-21): press on DRAG MIDI / DRAG AUDIO renders
    // into ~/Music/Engine 909 Exports, a drag hands the file URL to the host.
    private var exportPress: ExportPress? = nil
    private var exportCache: [ExportKind: (key: Data, urls: [URL])] = [:]
    private var dragKind: ExportKind? = nil
    private var notice: ExportNotice? = nil
    private var noticeSerial = 0
    private var noticeActionRect: NSRect = .zero
    private var noticeCloseRect: NSRect = .zero
    private var toolTipRectsCache: [NSRect] = []

    private var phTimer: Timer?
    private var lastDrawnStep: Int = -1
    private var lastDrawnPlaying: Bool = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = faceBg.cgColor
        // GPU-accelerated CG rendering — see EZAudio benchmark.
        layer?.drawsAsynchronously = true
        // 15 fps is more than enough for a step playhead; we only invalidate
        // the voice-rows band, not the whole view, and only when something
        // visible changed.
        phTimer = Timer.scheduledTimer(withTimeInterval: 1.0/15.0, repeats: true) { [weak self] _ in
            guard let self, let au = self.audioUnit else { return }
            let playing = au.playing
            let step = Int(au.currentStep)
            if playing != self.lastDrawnPlaying || (playing && step != self.lastDrawnStep) {
                self.setNeedsDisplay(self.voiceRowsRect())
            }
        }
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    deinit { phTimer?.invalidate() }

    // MARK: - Layout constants
    private let headerH: CGFloat = 28        // brand + tag at top
    private let transportH: CGFloat = 38     // transport bar
    private let linkStripH: CGFloat = 26     // LINK / song-chain row under PATTERN
    private let footerH: CGFloat = 36        // brand line at bottom (big)
    private let voiceRowH: CGFloat = 36
    private let leftPad: CGFloat = 16
    private let rightPad: CGFloat = 16
    private let glyphW: CGFloat = 22
    private let nameW: CGFloat = 66   // fits "LONG SUB"
    private let msW: CGFloat = 16   // each
    private let knobW: CGFloat = 42 // small knob area
    private let readoutW: CGFloat = 50

    // Button widths. All four right-side knobs share the same big size.
    private let clrW: CGFloat = 24
    private let resW: CGFloat = 34                // "8/16/32/64" cycle button
    private let chrW: CGFloat = 50                // character cycle button
    private let velW: CGFloat = 46                // per-voice VEL preset cycle
    private let bigKnobW: CGFloat = 52            // LVL / PITCH / DLY / FLT (same size)
    private let handleW: CGFloat = 18             // drag-pattern crosshair column before step 1

    private func gridXRange() -> (CGFloat, CGFloat) {
        // L: glyph + name + M + S + CLR + RES — no knobs on the left.
        let leftBlock = leftPad + glyphW + 4 + nameW + 8 + msW + 4 + msW + 4
                       + clrW + 6 + resW + 6 + chrW + 6 + velW + 6 + handleW + 6
        // R: LVL + PITCH + DLY + RVB + FLT — five big knobs same size.
        let rightBlock = rightPad + bigKnobW * 5 + 8 * 4 + 12
        return (leftBlock, bounds.width - rightBlock)
    }

    // MARK: - Drawing
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Subtle brushed-aluminium faceplate (keeps panel colour, adds analogue grain).
        FaceTexture.draw(in: bounds, ctx: ctx)
        let b = bounds

        drawHeader(ctx, b)
        drawTransport(ctx, b)
        drawLinkStrip(ctx, b)
        // (dominant red disc removed per design)
        drawVoiceRows(ctx, b)
        drawMidiModeTag(ctx)
        drawFooter(ctx, b)

        if let au = audioUnit {
            lastDrawnStep = Int(au.currentStep)
            lastDrawnPlaying = au.playing
        }
    }

    /// Small red tag over the faded grid while MIDI MODE is on.
    private func drawMidiModeTag(_ ctx: CGContext) {
        guard audioUnit?.midiMode ?? false else { return }
        let (_, g1) = gridXRange()
        let strip = linkStripRect()       // sits in the LINK row, right-aligned over the grid
        let r = NSRect(x: g1 - 230, y: strip.midY - 9, width: 230, height: 18)
        drawSmallToggle(ctx, rect: r, label: "MIDI MODE · PLAYING FROM HOST MIDI", on: true)
    }

    private func drawNoise(_ ctx: CGContext, _ b: NSRect) {
        if let img = NoiseCache.shared.image(forSize: b.size) {
            ctx.draw(img, in: b)
        }
    }

    private func drawHeader(_ ctx: CGContext, _ b: NSRect) {
        let cy = b.height - headerH * 0.5

        // SAVE / LOAD removed — Logic's built-in plug-in preset bar covers it.

        // UNDO / REDO — top-right.
        let bw: CGFloat = 50, bh: CGFloat = 18, gap: CGFloat = 8
        let redoX = b.width - rightPad - bw
        let undoX = redoX - gap - bw
        undoHitRect = NSRect(x: undoX, y: cy - bh * 0.5, width: bw, height: bh)
        redoHitRect = NSRect(x: redoX, y: cy - bh * 0.5, width: bw, height: bh)
        drawHeaderButton(ctx, rect: undoHitRect, label: "↶ UNDO", enabled: !undoStack.isEmpty)
        drawHeaderButton(ctx, rect: redoHitRect, label: "↷ REDO", enabled: !redoStack.isEmpty)

        // MIDI MODE · DRAG MIDI · DRAG AUDIO ▾ — right-aligned, left of UNDO.
        // The two DRAG keys are drag sources: pull them onto a host track.
        let kh: CGFloat = 18
        let expAW: CGFloat = 112, expMW: CGFloat = 92, mmW: CGFloat = 80
        var hx = undoX - 18 - expAW
        exportAudioRect = NSRect(x: hx, y: cy - kh * 0.5, width: expAW, height: kh)
        hx -= 8 + expMW
        exportMidiRect = NSRect(x: hx, y: cy - kh * 0.5, width: expMW, height: kh)
        hx -= 14 + mmW
        midiModeRect = NSRect(x: hx, y: cy - kh * 0.5, width: mmW, height: kh)
        drawSmallToggle(ctx, rect: midiModeRect, label: "MIDI MODE", on: audioUnit?.midiMode ?? false)
        drawSmallToggle(ctx, rect: exportMidiRect, label: exporting == "midi" ? "EXPORTING…" : "DRAG MIDI ⇢",
                        on: dragKind == .midi)
        drawSmallToggle(ctx, rect: exportAudioRect, label: exporting == "audio" ? "RENDERING…" : "DRAG AUDIO ⇢ ▾",
                        on: dragKind == .mix || dragKind == .stems)
        drawExportNotice(ctx, b, cy: cy, rightLimit: midiModeRect.minX - 14)
        updateExportToolTips()
    }

    /// Short, non-blocking hint / MIDI MODE offer in the empty left half of
    /// the header (replaces the old modal alert after an export).
    private func drawExportNotice(_ ctx: CGContext, _ b: NSRect, cy: CGFloat, rightLimit: CGFloat) {
        noticeActionRect = .zero; noticeCloseRect = .zero
        guard let n = notice else { return }
        let h: CGFloat = 18
        var x = rightLimit
        noticeCloseRect = NSRect(x: x - 18, y: cy - h * 0.5, width: 18, height: h)
        drawSmallToggle(ctx, rect: noticeCloseRect, label: "×", on: false)
        x = noticeCloseRect.minX - 6
        if let act = n.action {
            let w = NSString(string: act).size(withAttributes: aTogOn).width + 16
            noticeActionRect = NSRect(x: x - w, y: cy - h * 0.5, width: w, height: h)
            drawSmallToggle(ctx, rect: noticeActionRect, label: act, on: true)
            x = noticeActionRect.minX - 8
        }
        let attr: [NSAttributedString.Key: Any] = [.font: Palette.printFont(9), .foregroundColor: inkDark]
        var text = n.text
        let minX = leftPad
        while text.count > 4 && NSString(string: text).size(withAttributes: attr).width > x - minX {
            text = String(text.dropLast(2)) + "…"
        }
        let sz = NSString(string: text).size(withAttributes: attr)
        NSString(string: text).draw(at: NSPoint(x: max(minX, x - sz.width), y: cy - 5), withAttributes: attr)
    }

    private func updateExportToolTips() {
        let rects = [exportMidiRect, exportAudioRect]
        guard rects != toolTipRectsCache else { return }
        toolTipRectsCache = rects
        removeAllToolTips()
        addToolTip(exportMidiRect, owner: self, userData: nil)
        addToolTip(exportAudioRect, owner: self, userData: nil)
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
                       userData data: UnsafeMutableRawPointer?) -> String {
        if exportMidiRect.contains(point) {
            return "Drag onto a track: drops the pattern as a MIDI region.\nClick: show the .mid in Finder. ⌥-click: Save As…"
        }
        if exportAudioRect.contains(point) {
            return "Drag onto a track: drops the mix as an audio region (⌥-drag: all stems).\nClick: menu (Show in Finder / Save As… / Stems)."
        }
        return ""
    }

    private func drawHeaderButton(_ ctx: CGContext, rect: NSRect, label: String, enabled: Bool) {
        let col = enabled ? inkDark : inkMid.withAlphaComponent(0.45)
        if !ButtonTex.draw(ctx, rect: rect, active: false, corner: 4) {
            ctx.setStrokeColor(col.withAlphaComponent(0.7).cgColor); ctx.setLineWidth(0.8); ctx.stroke(rect)
        }
        let attr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                                                    .foregroundColor: col, .kern: 0.4]
        let s = NSString(string: label); let sz = s.size(withAttributes: attr)
        s.draw(at: NSPoint(x: rect.midX - sz.width * 0.5, y: rect.midY - sz.height * 0.5 - 0.5), withAttributes: attr)
    }

    /// LINK / song-chain strip, drawn under the transport's PATTERN buttons.
    /// Tap A/B/C/D here to append that pattern to the chain. The chain plays
    /// left→right and loops; the live entry is highlighted while playing.
    private func drawLinkStrip(_ ctx: CGContext, _ b: NSRect) {
        let strip = linkStripRect()
        let cy = strip.midY
        let letters = ["A", "B", "C", "D"]
        let chainOn = !chainSlotsLocal.isEmpty
        let pos = Int(audioUnit?.chainPosition ?? 0)
        let playing = audioUnit?.playing ?? false

        // Row label.
        NSString(string: "LINK").draw(at: NSPoint(x: leftPad, y: cy - 6), withAttributes: aLabBold)

        // Four "add to chain" buttons, aligned under the PATTERN squares.
        linkBtnRects = []
        for i in 0..<4 {
            // Match the PATTERN squares' width (18) so each LINK box sits exactly
            // in its column with the same gap — no overlap.
            let w: CGFloat = 18
            let bx = (i < patternRects.count) ? patternRects[i].midX - w * 0.5
                                              : leftPad + 60 + CGFloat(i) * 22
            let r = NSRect(x: bx, y: cy - 9, width: w, height: 18)
            linkBtnRects.append(r)
            let inChain = chainSlotsLocal.contains(i)
            if inChain {
                ctx.setFillColor(red.withAlphaComponent(0.85).cgColor); ctx.fill(r)
            } else {
                ctx.setStrokeColor(inkDark.withAlphaComponent(0.5).cgColor); ctx.setLineWidth(0.8); ctx.stroke(r)
            }
            let attr = inChain ? aTogOn : aTogOff
            let s = NSString(string: letters[i]); let sz = s.size(withAttributes: attr)
            s.draw(at: NSPoint(x: r.midX - sz.width * 0.5, y: r.midY - sz.height * 0.5 - 1), withAttributes: attr)
        }

        // Chain read-out to the right: A→B→A→C (live entry red while playing).
        var rx = (patternRects.last?.maxX ?? (leftPad + 220)) + 22
        if chainOn {
            for (idx, slot) in chainSlotsLocal.enumerated() {
                let live = playing && idx == pos
                NSString(string: letters[slot]).draw(at: NSPoint(x: rx, y: cy - 6), withAttributes: live ? aPlayOn : aRead)
                rx += 12
                if idx < chainSlotsLocal.count - 1 {
                    NSString(string: "→").draw(at: NSPoint(x: rx - 2, y: cy - 6), withAttributes: aReadDim)
                    rx += 12
                }
            }
            rx += 12
            let clW: CGFloat = 34
            linkClrRect = NSRect(x: rx, y: cy - 8, width: clW, height: 16)
            ctx.setStrokeColor(inkDark.withAlphaComponent(0.55).cgColor); ctx.setLineWidth(0.7); ctx.stroke(linkClrRect)
            let cs = NSString(string: "CLR"); let csz = cs.size(withAttributes: aCLR)
            cs.draw(at: NSPoint(x: linkClrRect.midX - csz.width * 0.5, y: linkClrRect.midY - 4), withAttributes: aCLR)
            if audioUnit?.isolate ?? false {
                NSString(string: "ISOLATE ON · chain paused, kept").draw(at: NSPoint(x: linkClrRect.maxX + 12, y: cy - 6), withAttributes: aPlayOn)
            }
        } else {
            linkClrRect = .zero
            NSString(string: "tap A · B · C · D to chain patterns into a song").draw(at: NSPoint(x: rx, y: cy - 6), withAttributes: aReadDim)
        }
    }

    private func transportRect() -> NSRect {
        return NSRect(x: 0, y: bounds.height - headerH - transportH, width: bounds.width, height: transportH)
    }

    private func drawTransport(_ ctx: CGContext, _ b: NSRect) {
        let tr = transportRect()
        // (red stripe under transport removed per feedback)

        let cy = tr.midY
        // PLAY / STOP / REC transport buttons removed — the sequencer follows
        // Logic's host transport (transportStateBlock) directly, so manual
        // transport was redundant. The row now starts at BPM.
        var x: CGFloat = leftPad

        // BPM
        NSString(string: "BPM").draw(at: NSPoint(x: x, y: cy - 6), withAttributes: aLabBold)
        let bpmStr = NSString(string: String(format: "%.0f", audioUnit?.bpm ?? 120))
        bpmStr.draw(at: NSPoint(x: x + 28, y: cy - 6), withAttributes: aVal)
        x += 78

        // PATTERN A B C D — active slot rendered red, others outlined
        NSString(string: "PATTERN").draw(at: NSPoint(x: x, y: cy - 6), withAttributes: aLabBold)
        x += 56
        let letters = ["A", "B", "C", "D"]
        let activeSlot = Int(audioUnit?.patternSlot ?? 0)
        patternRects.removeAll()
        for (i, L) in letters.enumerated() {
            let sq = NSRect(x: x, y: cy - 9, width: 18, height: 18)
            patternRects.append(sq)
            // Chain-membership line under the button (song mode).
            if chainSlotsLocal.contains(i) {
                ctx.setFillColor(red.cgColor)
                ctx.fill(NSRect(x: sq.minX, y: sq.minY - 4, width: sq.width, height: 2))
            }
            if i == activeSlot {
                ctx.setFillColor(red.cgColor); ctx.fill(sq)
                let sw = NSString(string: L).size(withAttributes: aSlotOn)
                NSString(string: L).draw(at: NSPoint(x: sq.midX - sw.width/2, y: sq.midY - sw.height/2 - 1), withAttributes: aSlotOn)
            } else {
                ctx.setStrokeColor(inkDark.withAlphaComponent(0.4).cgColor); ctx.setLineWidth(0.6); ctx.stroke(sq)
                let sw = NSString(string: L).size(withAttributes: aSlotOff)
                NSString(string: L).draw(at: NSPoint(x: sq.midX - sw.width/2, y: sq.midY - sw.height/2 - 1), withAttributes: aSlotOff)
            }
            x += 22
            if i < letters.count - 1 {
                NSString(string: "|").draw(at: NSPoint(x: x - 6, y: cy - 6), withAttributes: aDiv)
            }
        }
        x += 6

        // ISOLATE — loop the selected pattern alone; the LINK chain is kept.
        isolateRect = NSRect(x: x, y: cy - 10, width: 60, height: 20)
        drawSmallToggle(ctx, rect: isolateRect, label: "ISOLATE", on: audioUnit?.isolate ?? false)
        x += 60 + 14

        // SWING
        NSString(string: "SWING").draw(at: NSPoint(x: x, y: cy - 6), withAttributes: aLabBold)
        let swingStr = NSString(string: String(format: "%.0f%%", (audioUnit?.swing ?? 0.12) * 100))
        swingStr.draw(at: NSPoint(x: x + 44, y: cy - 6), withAttributes: aVal)
        swingHitRect = NSRect(x: x, y: cy - 10, width: 90, height: 20)
        x += 90

        // BARS — click cycles 1→2→4→8, double-click types a value
        NSString(string: "BARS").draw(at: NSPoint(x: x, y: cy - 6), withAttributes: aLabBold)
        let barsVal = Int(audioUnit?.bars ?? 8)
        NSString(string: "\(barsVal)").draw(at: NSPoint(x: x + 36, y: cy - 6), withAttributes: aVal)
        barsHitRect = NSRect(x: x, y: cy - 10, width: 60, height: 20)
        x += 64

        // GENRE — solid red pill that pops a 20-preset menu
        let gW: CGFloat = 92
        genreHitRect = NSRect(x: x, y: cy - 10, width: gW, height: 20)
        ctx.setFillColor(red.cgColor); ctx.fill(genreHitRect)
        let g = NSString(string: "GENRE ▾")
        let gsz = g.size(withAttributes: aGenre)
        g.draw(at: NSPoint(x: genreHitRect.midX - gsz.width * 0.5, y: genreHitRect.midY - gsz.height * 0.5 - 1), withAttributes: aGenre)
        x += gW + 14

        // PITCH — global pitch in semitones (-12..+12). Drag vertical to set,
        // double-click to reset to 0. Shifts every voice's tuning together.
        NSString(string: "PITCH").draw(at: NSPoint(x: x, y: cy - 6), withAttributes: aLabBold)
        let gp = audioUnit?.globalPitchSemi ?? 0
        let pitchStr = NSString(string: gp == 0 ? "±0" : String(format: "%+.0f", Double(gp)))
        pitchStr.draw(at: NSPoint(x: x + 38, y: cy - 6), withAttributes: aVal)
        pitchHitRect = NSRect(x: x, y: cy - 10, width: 74, height: 20)
        x += 78

        // NOISE — global noise floor (0..1 → 0..100%). Analog grit slider.
        NSString(string: "NOISE").draw(at: NSPoint(x: x, y: cy - 6), withAttributes: aLabBold)
        let gn = audioUnit?.globalNoise ?? 0
        let noiseStr = NSString(string: String(format: "%.0f%%", Double(gn) * 100))
        noiseStr.draw(at: NSPoint(x: x + 38, y: cy - 6), withAttributes: aVal)
        noiseHitRect = NSRect(x: x, y: cy - 10, width: 74, height: 20)
        x += 78

        // (Per-voice VEL preset moved into each voice row, alongside CLR / 16 / 32.
        // Global VEL pill was removed in favor of per-track control.)
        velHitRect = .zero

        // DECAY — global sample-shortening / snappier knob. 100% = full natural
        // tails (default); 0% = aggressive 909-style choke. Vertical drag,
        // double-click resets to 100%.
        NSString(string: "DECAY").draw(at: NSPoint(x: x, y: cy - 6), withAttributes: aLabBold)
        let gd = audioUnit?.globalDecay ?? 1.0
        let decStr = NSString(string: String(format: "%.0f%%", Double(gd) * 100))
        decStr.draw(at: NSPoint(x: x + 42, y: cy - 6), withAttributes: aVal)
        decayHitRect = NSRect(x: x, y: cy - 10, width: 78, height: 20)
    }

    private func drawDominantDisc(_ ctx: CGContext, _ b: NSRect) {
        let r: CGFloat = 24
        let cx = b.width - rightPad - r - 4
        let cy = b.height - 14 - r * 0.4
        ctx.setFillColor(red.cgColor)
        ctx.fillEllipse(in: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
    }

    private func voiceRowsRect() -> NSRect {
        let y = footerH + 4
        let h = bounds.height - headerH - transportH - linkStripH - footerH - 8
        return NSRect(x: 0, y: y, width: bounds.width, height: h)
    }

    /// The LINK / song-chain strip — sits between the transport and the voice
    /// rows, directly under the PATTERN A/B/C/D buttons.
    private func linkStripRect() -> NSRect {
        let top = bounds.height - headerH - transportH      // transport bottom
        return NSRect(x: 0, y: top - linkStripH, width: bounds.width, height: linkStripH)
    }

    /// Per-row hit rects, captured on draw, consumed by mouseDown.
    private struct RowRects {
        var resBtn: NSRect = .zero
        var chrBtn: NSRect = .zero
        var velBtn: NSRect = .zero
        var lvlKnob: NSRect = .zero
        var pitchKnob: NSRect = .zero
        var dcyKnob: NSRect = .zero
        var dlyKnob: NSRect = .zero
        var rvbKnob: NSRect = .zero
        var fltKnob: NSRect = .zero
        var gridX0: CGFloat = 0
        var gridX1: CGFloat = 0
        var resolution: Int = 16  // visible cells per bar for this voice
    }
    private var rowRects: [RowRects] = Array(repeating: RowRects(), count: kNumVoices)

    private func drawVoiceRows(_ ctx: CGContext, _ b: NSRect) {
        let block = voiceRowsRect()
        let rowH = block.height / CGFloat(kNumVoices)
        let (gridX0, gridX1) = gridXRange()
        let gridW = gridX1 - gridX0
        let bars = max(1, Int(audioUnit?.bars ?? 2))

        let curStep = Int(audioUnit?.currentStep ?? 0)
        let totalInternalSteps = bars * kSubdiv

        for vi in 0..<kNumVoices {
            let y = block.maxY - CGFloat(vi + 1) * rowH
            let cy = y + rowH * 0.5
            let res = Int(audioUnit?.resolution(forVoice: Int32(vi)) ?? 16)
            rowRects[vi].gridX0 = gridX0
            rowRects[vi].gridX1 = gridX1
            rowRects[vi].resolution = res

            // Glyph
            drawVoiceGlyph(ctx, voice: vi, center: NSPoint(x: leftPad + glyphW * 0.5, y: cy))

            // Voice name
            NSString(string: kVoiceNames[vi]).draw(at: NSPoint(x: leftPad + glyphW + 4, y: cy - 7), withAttributes: aVoice)

            // M/S squares
            let msY = cy - 10
            let mX = leftPad + glyphW + 4 + nameW + 8
            let sX = mX + msW + 4
            let muted = audioUnit?.isMuted(forVoice: Int32(vi)) ?? false
            let soloed = audioUnit?.isSoloed(forVoice: Int32(vi)) ?? false
            drawSmallToggle(ctx, rect: NSRect(x: mX, y: msY, width: 18, height: 20), label: "M", on: muted)
            drawSmallToggle(ctx, rect: NSRect(x: sX, y: msY, width: 18, height: 20), label: "S", on: soloed)

            // CLR button
            let clrX = sX + msW + 4
            let clrR = NSRect(x: clrX, y: msY, width: clrW, height: 20)
            pillBG(ctx, clrR, active: false)
            let clrS = NSString(string: "CLR"); let clrSz = clrS.size(withAttributes: aCLR)
            clrS.draw(at: NSPoint(x: clrR.midX - clrSz.width * 0.5, y: clrR.midY - 4), withAttributes: aCLR)

            // RES cycle button — shows "8" / "16" / "32" / "64"
            let resX = clrX + clrW + 6
            let resR = NSRect(x: resX, y: msY, width: resW, height: 20)
            pillBG(ctx, resR, active: true)
            let rstr = NSString(string: "\(res)")
            let rsz = rstr.size(withAttributes: aGenre)
            rstr.draw(at: NSPoint(x: resR.midX - rsz.width * 0.5, y: resR.midY - rsz.height * 0.5 - 1), withAttributes: aGenre)
            rowRects[vi].resBtn = resR

            // CHR cycle button — voice character variant (SUB/PUNCH/ACOUS, etc.)
            let chrX = resX + resW + 6
            let chrR = NSRect(x: chrX, y: msY, width: chrW, height: 20)
            let chr = Int(audioUnit?.character(forVoice: Int32(vi)) ?? 0)
            // Name comes straight from the engine (5 variants/voice) so the
            // label can never drift from the DSP.
            let chrName = audioUnit?.characterName(forVoice: Int32(vi), character: Int32(chr)) ?? "STD"
            pillBG(ctx, chrR, active: false)
            let chrS = NSString(string: chrName)
            let chrSz = chrS.size(withAttributes: aCLR)
            chrS.draw(at: NSPoint(x: chrR.midX - chrSz.width * 0.5, y: chrR.midY - 4), withAttributes: aCLR)
            rowRects[vi].chrBtn = chrR

            // VEL preset cycle — per-voice velocity preset. Click cycles
            // FLAT → ALT 50 → ALT 25 → GHOST → BUILD → HUMAN.
            let velX = chrX + chrW + 6
            let velR = NSRect(x: velX, y: msY, width: velW, height: 20)
            let vp = Int(audioUnit?.velocityPreset(forVoice: Int32(vi)) ?? 0)
            let vName = audioUnit?.velocityPresetName(Int32(vp)) ?? "FLAT"
            pillBG(ctx, velR, active: vp != 0)
            let velS = NSString(string: vName)
            let velSz = velS.size(withAttributes: aCLR)
            velS.draw(at: NSPoint(x: velR.midX - velSz.width * 0.5, y: velR.midY - 4), withAttributes: aCLR)
            rowRects[vi].velBtn = velR

            // ----- Drag handle: crosshair just before step 1 -----
            // Drag onto another row = copy this row's pattern there (⌥ = swap).
            let hc = NSPoint(x: gridX0 - 6 - handleW * 0.5, y: cy)
            let dragging = rowDragSrc == vi
            ctx.setStrokeColor((dragging ? red : inkDark).withAlphaComponent(dragging ? 1.0 : 0.85).cgColor)
            ctx.setLineWidth(1.2); ctx.setLineCap(.round)
            let arm: CGFloat = 6, ring: CGFloat = 3.2
            ctx.strokeEllipse(in: NSRect(x: hc.x - ring, y: hc.y - ring, width: ring * 2, height: ring * 2))
            ctx.move(to: NSPoint(x: hc.x - arm, y: hc.y)); ctx.addLine(to: NSPoint(x: hc.x - ring - 1, y: hc.y))
            ctx.move(to: NSPoint(x: hc.x + ring + 1, y: hc.y)); ctx.addLine(to: NSPoint(x: hc.x + arm, y: hc.y))
            ctx.move(to: NSPoint(x: hc.x, y: hc.y - arm)); ctx.addLine(to: NSPoint(x: hc.x, y: hc.y - ring - 1))
            ctx.move(to: NSPoint(x: hc.x, y: hc.y + ring + 1)); ctx.addLine(to: NSPoint(x: hc.x, y: hc.y + arm))
            ctx.strokePath()

            // MIDI MODE: the grid is shown but faded — the host's MIDI plays.
            let midiMode = audioUnit?.midiMode ?? false
            ctx.saveGState()
            if midiMode { ctx.setAlpha(0.35) }

            // ----- Step cells (per-voice resolution) -----
            // Each cell renders as a hollow track with a red velocity bar
            // inside. Bar HEIGHT scales with the preview velocity for this
            // voice's preset at this hit's index in the loop. So soft hits
            // are visually shorter than loud ones, matching how they sound.
            //
            // Cell width is computed to fit inside the grid no matter the
            // resolution. The old `max(2.0, ...)` floor caused res=64 to
            // overflow into the LVL/PITCH knobs on the right — fixed by
            // collapsing the cell gap progressively as cells get tiny.
            let barGap: CGFloat = 6.0
            let barW = (gridW - barGap * CGFloat(bars - 1)) / CGFloat(bars)
            let cellGap: CGFloat = (res >= 64) ? 0.5 : ((res >= 32) ? 1.0 : 2.0)   // keys need a bezel gap
            let cellW = max(0.8, (barW - cellGap * CGFloat(res - 1)) / CGFloat(res))
            let cellH = rowH - 12
            let cellY = y + 6
            let preset = Int(audioUnit?.velocityPreset(forVoice: Int32(vi)) ?? 0)

            // Walk steps in playback order across all bars to assign hitIdx.
            var hitIdx: Int32 = 0
            for bar in 0..<bars {
                let barX = gridX0 + CGFloat(bar) * (barW + barGap)
                for c in 0..<res {
                    let internalStep = bar * kSubdiv + c * (kSubdiv / res)
                    let on = audioUnit?.step(forVoice: Int32(vi), step: Int32(internalStep)) ?? false
                    let sw = Int(audioUnit?.swingLevel(forVoice: Int32(vi), step: Int32(internalStep)) ?? 0)
                    let cx = barX + CGFloat(c) * (cellW + cellGap)
                    let r = NSRect(x: cx, y: cellY, width: cellW, height: cellH)
                    // Rubber step key (analog scheme): dark = empty, red = hit.
                    // Velocity reads as how strongly the red key is lit; swing
                    // tints the lit key toward pink (same rule as before).
                    if !ButtonTex.drawRubber(ctx, rect: r, kind: 0) {
                        ctx.setFillColor(cellOff.cgColor); ctx.fill(r)
                    }
                    if on {
                        let vel: CGFloat
                        if preset == 0 {
                            vel = 1.0   // FLAT — fully lit
                        } else {
                            vel = CGFloat(max(0.05, min(1.0, audioUnit?.previewVelocity(forVoice: Int32(vi), hit: hitIdx) ?? 1.0)))
                        }
                        ctx.saveGState()
                        ctx.setAlpha((0.35 + 0.65 * vel) * (midiMode ? 0.35 : 1.0))   // × MIDI MODE fade
                        if !ButtonTex.drawRubber(ctx, rect: r, kind: 1) {
                            ctx.setFillColor(red.cgColor); ctx.fill(r)
                        }
                        ctx.restoreGState()
                        if sw > 0 {
                            let inner = r.insetBy(dx: max(1, r.width * 0.18), dy: max(1, r.height * 0.12))
                            ctx.setFillColor(swingTint(sw).withAlphaComponent(0.45).cgColor)
                            ctx.fill(inner)
                        }
                        hitIdx += 1
                    }
                    // ---- Swing tick — 4-segment indicator in the strip under
                    // the cell (the "wrist"). Filled segments = swing level;
                    // filled in the same pink tint as the cell. Only drawn when
                    // cells are wide enough (skipped at 32/64 to avoid clutter).
                    if cellW >= 7 {
                        let segGap: CGFloat = 1.0
                        let segW = (cellW - segGap * 3) / 4
                        let tickY = y + 1.5
                        let tickH: CGFloat = 3.0
                        for seg in 0..<4 {
                            let sx = cx + CGFloat(seg) * (segW + segGap)
                            let sr = NSRect(x: sx, y: tickY, width: segW, height: tickH)
                            if seg < sw {
                                ctx.setFillColor(swingTint(seg + 1).cgColor)
                            } else {
                                ctx.setFillColor(inkDark.withAlphaComponent(0.14).cgColor)
                            }
                            ctx.fill(sr)
                        }
                    }
                }
            }

            ctx.restoreGState()   // end MIDI MODE fade
            // Drop target while dragging a row's crosshair.
            if rowDropTarget == vi {
                let hr = NSRect(x: gridX0 - 3, y: y + 2, width: gridW + 6, height: rowH - 4)
                ctx.setFillColor(inkDark.withAlphaComponent(0.10).cgColor); ctx.fill(hr)
                ctx.setStrokeColor(inkDark.withAlphaComponent(0.9).cgColor); ctx.setLineWidth(1.5); ctx.stroke(hr)
            }

            // ----- Right-side knob bank: LVL · PITCH · DCY · DLY · RVB · FLT -
            // LVL = white (output convention). PITCH/RVB/DCY dark grey, DLY
            // pure black, FLT red. Six knobs in the same footprint as the old
            // five (local 44pt width / 6pt gap), so the step grid isn't crowded.
            let knobR: CGFloat = 16
            let kY = cy
            let kw: CGFloat = 44, kgap: CGFloat = 6
            let fltX   = bounds.width - rightPad - kw
            let rvbX   = fltX   - kgap - kw
            let dlyX   = rvbX   - kgap - kw
            let dcyX   = dlyX   - kgap - kw
            let pitchX = dcyX   - kgap - kw
            let lvlX   = pitchX - kgap - kw

            // LVL — 0..2, mapped to 0..1 for display. White body.
            let lvl = audioUnit?.level(forVoice: Int32(vi)) ?? 1.0
            drawBigKnob(ctx, center: NSPoint(x: lvlX + kw * 0.5, y: kY),
                        radius: knobR,
                        normalized: CGFloat(min(1.0, max(0.0, lvl / 2.0))),
                        body: NSColor.white,
                        pointer: red, label: "LVL")
            rowRects[vi].lvlKnob = NSRect(x: lvlX, y: kY - 18, width: kw, height: 36)

            // PITCH — -24..+24
            let semi = CGFloat(audioUnit?.pitchSemi(forVoice: Int32(vi)) ?? 0)
            drawBigKnob(ctx, center: NSPoint(x: pitchX + kw * 0.5, y: kY),
                        radius: knobR,
                        normalized: max(0.0, min(1.0, (semi + 24) / 48)),
                        body: NSColor(calibratedWhite: 0.18, alpha: 1.0),
                        pointer: red, label: "PITCH")
            rowRects[vi].pitchKnob = NSRect(x: pitchX, y: kY - 18, width: kw, height: 36)

            // DCY — 0..1, per-voice decay (shortens the sound). Dark body.
            let dcy = CGFloat(audioUnit?.decay(forVoice: Int32(vi)) ?? 1.0)
            drawBigKnob(ctx, center: NSPoint(x: dcyX + kw * 0.5, y: kY),
                        radius: knobR,
                        normalized: dcy,
                        body: NSColor(calibratedWhite: 0.18, alpha: 1.0),
                        pointer: red, label: "DCY")
            rowRects[vi].dcyKnob = NSRect(x: dcyX, y: kY - 18, width: kw, height: 36)

            // DLY — 0..500 ms, big BLACK knob
            let dms = audioUnit?.delayMs(forVoice: Int32(vi)) ?? 0
            drawBigKnob(ctx, center: NSPoint(x: dlyX + kw * 0.5, y: kY),
                        radius: knobR,
                        normalized: CGFloat(min(1.0, max(0.0, dms / 500.0))),
                        body: NSColor.black,
                        pointer: red, label: "DLY")
            rowRects[vi].dlyKnob = NSRect(x: dlyX, y: kY - 18, width: kw, height: 36)

            // RVB — 0..1, dark body
            let rvb = CGFloat(audioUnit?.reverbSend(forVoice: Int32(vi)) ?? 0)
            drawBigKnob(ctx, center: NSPoint(x: rvbX + kw * 0.5, y: kY),
                        radius: knobR,
                        normalized: rvb,
                        body: NSColor(calibratedWhite: 0.18, alpha: 1.0),
                        pointer: red, label: "RVB")
            rowRects[vi].rvbKnob = NSRect(x: rvbX, y: kY - 18, width: kw, height: 36)

            // FLT — 0..1, big RED knob
            let fltNorm = CGFloat(audioUnit?.filterNorm(forVoice: Int32(vi)) ?? 1.0)
            drawBigKnob(ctx, center: NSPoint(x: fltX + kw * 0.5, y: kY),
                        radius: knobR,
                        normalized: fltNorm,
                        body: red,
                        pointer: NSColor.white, label: "FLT")
            rowRects[vi].fltKnob = NSRect(x: fltX, y: kY - 18, width: kw, height: 36)

            // Row separator
            ctx.setStrokeColor(inkDark.withAlphaComponent(0.12).cgColor); ctx.setLineWidth(0.5)
            ctx.move(to: NSPoint(x: leftPad, y: y)); ctx.addLine(to: NSPoint(x: bounds.width - rightPad, y: y)); ctx.strokePath()
        }

        // Playhead vertical red line — pixel position from internal step
        if curStep >= 0 && curStep < totalInternalSteps && totalInternalSteps > 0 {
            let frac = CGFloat(curStep) / CGFloat(totalInternalSteps)
            let px = gridX0 + frac * gridW
            ctx.setStrokeColor(red.cgColor); ctx.setLineWidth(2.0)
            ctx.move(to: NSPoint(x: px, y: block.minY)); ctx.addLine(to: NSPoint(x: px, y: block.maxY)); ctx.strokePath()
        }
    }

    /// Map a click in the cells area for voice `v` (with its current
    /// resolution and the global `bars`) to an internal step index, or nil.
    private func internalStepAt(point p: NSPoint, voice v: Int) -> Int? {
        let block = voiceRowsRect()
        let rowH = block.height / CGFloat(kNumVoices)
        let y = block.maxY - CGFloat(v + 1) * rowH
        let cellY = y + 6
        let cellH = rowH - 12
        if p.y < cellY || p.y > cellY + cellH { return nil }
        let (gridX0, gridX1) = gridXRange()
        if p.x < gridX0 || p.x > gridX1 { return nil }
        let gridW = gridX1 - gridX0
        let bars = max(1, Int(audioUnit?.bars ?? 2))
        let res = Int(audioUnit?.resolution(forVoice: Int32(v)) ?? 16)
        let barGap: CGFloat = 6.0
        let barW = (gridW - barGap * CGFloat(bars - 1)) / CGFloat(bars)
        // Same geometry the cells are DRAWN with (RES 32/64 use tighter gaps);
        // a fixed 1 px gap here sent clicks to the wrong step at 32/64.
        let cellGap: CGFloat = (res >= 64) ? 0.5 : ((res >= 32) ? 1.0 : 2.0)   // keys need a bezel gap
        let cellW = max(0.8, (barW - cellGap * CGFloat(res - 1)) / CGFloat(res))
        for bar in 0..<bars {
            let barX = gridX0 + CGFloat(bar) * (barW + barGap)
            if p.x < barX || p.x > barX + barW { continue }
            for c in 0..<res {
                let cx = barX + CGFloat(c) * (cellW + cellGap)
                if p.x >= cx && p.x < cx + cellW {
                    return bar * kSubdiv + c * (kSubdiv / res)
                }
            }
        }
        return nil
    }

    /// Cell colour for a given per-cell swing level: 0 = pure red, higher
    /// levels blend progressively toward pink (the visual "pinker" cue).
    private func swingTint(_ level: Int) -> NSColor {
        if level <= 0 { return red }
        let pink = NSColor(calibratedRed: 1.0, green: 0.42, blue: 0.72, alpha: 1.0)
        let t = min(1.0, CGFloat(level) / 4.0) * 0.72   // up to 72% toward pink at level 4
        return red.blended(withFraction: t, of: pink) ?? red
    }

    /// Map a point in the thin strip directly UNDER a cell to its step index —
    /// used for the swing tick. Returns nil outside the strip or when cells are
    /// too narrow (high resolutions) to show a tick.
    private func swingTickStepAt(point p: NSPoint, voice v: Int) -> Int? {
        let block = voiceRowsRect()
        let rowH = block.height / CGFloat(kNumVoices)
        let y = block.maxY - CGFloat(v + 1) * rowH
        let cellY = y + 6
        if p.y < y || p.y >= cellY { return nil }       // the 6px "wrist" strip
        let (gridX0, gridX1) = gridXRange()
        if p.x < gridX0 || p.x > gridX1 { return nil }
        let gridW = gridX1 - gridX0
        let bars = max(1, Int(audioUnit?.bars ?? 2))
        let res = Int(audioUnit?.resolution(forVoice: Int32(v)) ?? 16)
        let barGap: CGFloat = 6.0
        let barW = (gridW - barGap * CGFloat(bars - 1)) / CGFloat(bars)
        let cellGap: CGFloat = 1.0
        let cellW = max(2.0, (barW - cellGap * CGFloat(res - 1)) / CGFloat(res))
        if cellW < 7 { return nil }                      // too tight to tick at 32/64
        for bar in 0..<bars {
            let barX = gridX0 + CGFloat(bar) * (barW + barGap)
            if p.x < barX || p.x > barX + barW { continue }
            for c in 0..<res {
                let cx = barX + CGFloat(c) * (cellW + cellGap)
                if p.x >= cx && p.x < cx + cellW {
                    return bar * kSubdiv + c * (kSubdiv / res)
                }
            }
        }
        return nil
    }

    // Map each voice to a cell in the 3×4 drum-icon sheet (row-major):
    // 0 kick · 1 snare · 2 clap · 3 toms · 4 hh-closed · 5 hh-open ·
    // 6 rimshot · 7 hihat · 8 crash · 9 ride · 10 sub · 11 drum
    private static let voiceIcon = [0, 1, 2, 6, 3, 3, 4, 7, 5, 8, 10, 10]

    private func drawVoiceGlyph(_ ctx: CGContext, voice: Int, center c: NSPoint) {
        // Prefer the rendered icon sheet (lighten-blended); fall back to the
        // built-in geometric glyph if the image isn't bundled.
        if voice >= 0, voice < DrumsParameterView.voiceIcon.count,
           IconSheet.draw(ctx, cell: DrumsParameterView.voiceIcon[voice],
                          in: NSRect(x: c.x - 14, y: c.y - 14, width: 28, height: 28)) {
            return
        }
        ctx.setFillColor(red.cgColor)
        ctx.setStrokeColor(red.cgColor)
        ctx.setLineWidth(1.4)
        let s: CGFloat = 9
        switch voice {
        case 0: ctx.fillEllipse(in: NSRect(x: c.x - s, y: c.y - s, width: s*2, height: s*2))
        case 1:
            ctx.move(to: NSPoint(x: c.x - s, y: c.y - s))
            ctx.addLine(to: NSPoint(x: c.x + s, y: c.y - s))
            ctx.addLine(to: NSPoint(x: c.x, y: c.y + s))
            ctx.closePath(); ctx.fillPath()
        case 2:
            for dy in [CGFloat(2), CGFloat(-2)] {
                ctx.move(to: NSPoint(x: c.x - s * 0.7, y: c.y + dy - s * 0.4))
                ctx.addLine(to: NSPoint(x: c.x + s * 0.7, y: c.y + dy - s * 0.4))
                ctx.addLine(to: NSPoint(x: c.x, y: c.y + dy + s * 0.4))
                ctx.closePath(); ctx.fillPath()
            }
        case 3: ctx.stroke(NSRect(x: c.x - s + 1, y: c.y - s + 1, width: s*2 - 2, height: s*2 - 2))
        case 4: ctx.fillEllipse(in: NSRect(x: c.x - s, y: c.y - s, width: s*2, height: s*2))
        case 5:
            let s2: CGFloat = s * 0.78
            ctx.fillEllipse(in: NSRect(x: c.x - s2, y: c.y - s2, width: s2*2, height: s2*2))
        case 6:
            let s2: CGFloat = s * 0.55
            ctx.fillEllipse(in: NSRect(x: c.x - s2, y: c.y - s2, width: s2*2, height: s2*2))
        case 7:
            ctx.setLineWidth(2.0); ctx.setLineCap(.round)
            ctx.move(to: NSPoint(x: c.x - s, y: c.y - s)); ctx.addLine(to: NSPoint(x: c.x + s, y: c.y + s))
            ctx.move(to: NSPoint(x: c.x - s, y: c.y + s)); ctx.addLine(to: NSPoint(x: c.x + s, y: c.y - s))
            ctx.strokePath()
        case 8:
            ctx.setLineWidth(2.0); ctx.setLineCap(.round)
            ctx.move(to: NSPoint(x: c.x - s, y: c.y)); ctx.addLine(to: NSPoint(x: c.x + s, y: c.y))
            ctx.move(to: NSPoint(x: c.x, y: c.y - s)); ctx.addLine(to: NSPoint(x: c.x, y: c.y + s))
            ctx.strokePath()
        case 9:
            let pts = 5
            var first = true
            for i in 0..<(pts * 2) {
                let ang = CGFloat(i) * .pi / CGFloat(pts) - .pi / 2
                let r: CGFloat = (i % 2 == 0) ? s : s * 0.42
                let p = NSPoint(x: c.x + cos(ang) * r, y: c.y + sin(ang) * r)
                if first { ctx.move(to: p); first = false } else { ctx.addLine(to: p) }
            }
            ctx.closePath(); ctx.fillPath()
        case 10:
            // SUB — a thick horizontal bar (visual "deep low" — a sub line)
            let bar = NSRect(x: c.x - s, y: c.y - 2.5, width: s * 2, height: 5)
            ctx.fill(bar)
        case 11:
            // LONG SUB — the sub bar plus a thin tail line (held note)
            ctx.fill(NSRect(x: c.x - s, y: c.y - 2.5, width: s * 1.2, height: 5))
            ctx.fill(NSRect(x: c.x + s * 0.3, y: c.y - 0.75, width: s * 0.7, height: 1.5))
        default: break
        }
    }

    /// Raised 3D button background for the row pills (red when active); falls
    /// back to the old fill/stroke if the texture isn't available.
    private func pillBG(_ ctx: CGContext, _ rect: NSRect, active: Bool) {
        if !ButtonTex.draw(ctx, rect: rect, active: active, corner: 2) {
            if active { ctx.setFillColor(red.cgColor); ctx.fill(rect) }
            else      { ctx.setStrokeColor(inkDark.withAlphaComponent(0.7).cgColor); ctx.setLineWidth(0.7); ctx.stroke(rect) }
        }
    }

    private func drawSmallToggle(_ ctx: CGContext, rect: NSRect, label: String, on: Bool) {
        if !ButtonTex.draw(ctx, rect: rect, active: on, corner: 2) {
            if on { ctx.setFillColor(red.cgColor); ctx.fill(rect) }
            else  { ctx.setStrokeColor(inkDark.withAlphaComponent(0.7).cgColor); ctx.setLineWidth(0.8); ctx.stroke(rect) }
        }
        let attr = on ? aTogOn : aTogOff
        let sz = NSString(string: label).size(withAttributes: attr)
        NSString(string: label).draw(at: NSPoint(x: rect.midX - sz.width * 0.5, y: rect.midY - 5), withAttributes: attr)
    }

    private func drawBigRedKnob(_ ctx: CGContext, center c: NSPoint, radius r: CGFloat, normalized n: CGFloat) {
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.5).cgColor); ctx.setLineWidth(0.6)
        let s: CGFloat = .pi * 1.25, e: CGFloat = -.pi * 0.25
        let hashCount = 18
        for i in 0..<hashCount {
            let f = CGFloat(i) / CGFloat(hashCount - 1)
            let a = s - f * (s - e)
            let p1 = NSPoint(x: c.x + cos(a) * (r + 1), y: c.y + sin(a) * (r + 1))
            let p2 = NSPoint(x: c.x + cos(a) * (r + 4), y: c.y + sin(a) * (r + 4))
            ctx.move(to: p1); ctx.addLine(to: p2)
        }
        ctx.strokePath()
        let body = NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        ctx.setFillColor(red.cgColor); ctx.fillEllipse(in: body)
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.35).cgColor); ctx.setLineWidth(1.2); ctx.strokeEllipse(in: body)
        let capR = r * 0.32
        ctx.setFillColor(cream.cgColor); ctx.fillEllipse(in: NSRect(x: c.x - capR, y: c.y - capR, width: capR * 2, height: capR * 2))
        ctx.setStrokeColor(inkDark.cgColor); ctx.setLineWidth(0.6); ctx.strokeEllipse(in: NSRect(x: c.x - capR, y: c.y - capR, width: capR * 2, height: capR * 2))
        let ang = s - n * (s - e)
        let p1 = NSPoint(x: c.x + cos(ang) * (capR + 2), y: c.y + sin(ang) * (capR + 2))
        let p2 = NSPoint(x: c.x + cos(ang) * (r - 3), y: c.y + sin(ang) * (r - 3))
        ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(3.5); ctx.setLineCap(.round)
        ctx.move(to: p1); ctx.addLine(to: p2); ctx.strokePath()
        ctx.setStrokeColor(inkDark.cgColor); ctx.setLineWidth(1.2)
        ctx.move(to: p1); ctx.addLine(to: p2); ctx.strokePath()
        let s2 = NSString(string: "FLT")
        let sz = s2.size(withAttributes: aFLT)
        s2.draw(at: NSPoint(x: c.x - sz.width * 0.5, y: c.y - r - 11), withAttributes: aFLT)
    }

    /// Unified big-knob renderer. Body colour + pointer colour are passed in
    /// so the same routine draws LVL/PITCH (dark), DLY (black), and FLT (red).
    /// No numeric readout — only the small label beneath.
    private func drawBigKnob(_ ctx: CGContext, center c: NSPoint, radius r: CGFloat,
                             normalized n: CGFloat, body: NSColor, pointer: NSColor, label: String) {
        // Screen-printed tick ring
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.65).cgColor); ctx.setLineWidth(0.7)
        let s: CGFloat = .pi * 1.25, e: CGFloat = -.pi * 0.25
        let hashCount = 16
        for i in 0..<hashCount {
            let f = CGFloat(i) / CGFloat(hashCount - 1)
            let a = s - f * (s - e)
            let p1 = NSPoint(x: c.x + cos(a) * (r + 1), y: c.y + sin(a) * (r + 1))
            let p2 = NSPoint(x: c.x + cos(a) * (r + 4), y: c.y + sin(a) * (r + 4))
            ctx.move(to: p1); ctx.addLine(to: p2)
        }
        ctx.strokePath()
        // Body — brushed-metal texture picked by colour (red knobs → red,
        // LVL/white → ivory, the rest → gunmetal); falls back to a flat fill.
        let bodyR = NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        // Blender knob body by colour ROLE: red → accent, white → output, rest dark.
        let rgb = body.usingColorSpace(.deviceRGB)
        let style: KnobStyle = ((rgb?.redComponent ?? 0) > 0.5 && (rgb?.greenComponent ?? 0) < 0.45) ? .anodizedRed
                             : ((rgb?.brightnessComponent ?? 0) > 0.5 ? .ivory : .gunmetal)
        if !KnobTex.draw(ctx, center: c, radius: r, image: style) {
            ctx.setFillColor(body.cgColor); ctx.fillEllipse(in: bodyR)
        }
        // Painted pointer line (one moulded knob — no separate cap).
        let ang = s - n * (s - e)
        let p1 = NSPoint(x: c.x + cos(ang) * (r * 0.30), y: c.y + sin(ang) * (r * 0.30))
        let p2 = NSPoint(x: c.x + cos(ang) * (r * 0.80), y: c.y + sin(ang) * (r * 0.80))
        _ = pointer
        ctx.setStrokeColor(KnobSkin.pointerColor(for: style).cgColor); ctx.setLineWidth(max(2.0, r * 0.12)); ctx.setLineCap(.round)
        ctx.move(to: p1); ctx.addLine(to: p2); ctx.strokePath()
        // Label
        let ls = NSString(string: label)
        let lsz = ls.size(withAttributes: aFLT)
        ls.draw(at: NSPoint(x: c.x - lsz.width * 0.5, y: c.y - r - 11), withAttributes: aFLT)
    }

    /// Legacy — kept for compatibility but no longer used by the row drawing.
    private func drawBigPitchKnob(_ ctx: CGContext, center c: NSPoint, radius r: CGFloat, normalized n: CGFloat, semi: CGFloat) {
        // Hash track
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.5).cgColor); ctx.setLineWidth(0.6)
        let s: CGFloat = .pi * 1.25, e: CGFloat = -.pi * 0.25
        let hashCount = 18
        for i in 0..<hashCount {
            let f = CGFloat(i) / CGFloat(hashCount - 1)
            let a = s - f * (s - e)
            let p1 = NSPoint(x: c.x + cos(a) * (r + 1), y: c.y + sin(a) * (r + 1))
            let p2 = NSPoint(x: c.x + cos(a) * (r + 4), y: c.y + sin(a) * (r + 4))
            ctx.move(to: p1); ctx.addLine(to: p2)
        }
        ctx.strokePath()
        // Body — dark
        let body = NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        ctx.setFillColor(NSColor(calibratedWhite: 0.12, alpha: 1.0).cgColor); ctx.fillEllipse(in: body)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.4).cgColor); ctx.setLineWidth(1.0); ctx.strokeEllipse(in: body)
        // Center cap — small cream
        let capR = r * 0.30
        ctx.setFillColor(cream.cgColor); ctx.fillEllipse(in: NSRect(x: c.x - capR, y: c.y - capR, width: capR * 2, height: capR * 2))
        // Red pointer
        let ang = s - n * (s - e)
        let p1 = NSPoint(x: c.x + cos(ang) * (capR + 2), y: c.y + sin(ang) * (capR + 2))
        let p2 = NSPoint(x: c.x + cos(ang) * (r - 3), y: c.y + sin(ang) * (r - 3))
        ctx.setStrokeColor(red.cgColor); ctx.setLineWidth(3.2); ctx.setLineCap(.round)
        ctx.move(to: p1); ctx.addLine(to: p2); ctx.strokePath()
        // Label + readout
        let lab = NSString(string: "PITCH")
        let lsz = lab.size(withAttributes: aFLT)
        lab.draw(at: NSPoint(x: c.x - lsz.width * 0.5, y: c.y - r - 11), withAttributes: aFLT)
        let s2 = NSString(string: String(format: "%+.0f st", semi))
        let sz = s2.size(withAttributes: aReadDim)
        s2.draw(at: NSPoint(x: c.x - sz.width * 0.5, y: c.y + r + 2), withAttributes: aReadDim)
    }

    private func drawTinyKnob(_ ctx: CGContext, center c: NSPoint, radius r: CGFloat, normalized n: CGFloat) {
        let body = NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        ctx.setFillColor(NSColor(calibratedWhite: 0.12, alpha: 1.0).cgColor); ctx.fillEllipse(in: body)
        ctx.setStrokeColor(NSColor(calibratedWhite: 0.0, alpha: 0.8).cgColor); ctx.setLineWidth(0.7); ctx.strokeEllipse(in: body)
        let s: CGFloat = .pi * 1.25, e: CGFloat = -.pi * 0.25
        let ang = s - (s - e) * n
        let p1 = NSPoint(x: c.x + cos(ang) * r * 0.3, y: c.y + sin(ang) * r * 0.3)
        let p2 = NSPoint(x: c.x + cos(ang) * r * 0.88, y: c.y + sin(ang) * r * 0.88)
        ctx.setStrokeColor(red.cgColor); ctx.setLineWidth(1.6); ctx.setLineCap(.round)
        ctx.move(to: p1); ctx.addLine(to: p2); ctx.strokePath()
    }

    private func drawFooter(_ ctx: CGContext, _ b: NSRect) {
        // Suite-standard brand block (Shared/UI/BrandStrip.swift): 30 pt logo,
        // "PARADISE AUDIO" over "ENGINE 909 — DRM-1", hairline at y=36 (the
        // voice rows start at footerH + 4 = 40), spec tag on the right.
        BrandStrip.drawFooter(ctx: ctx, bounds: b, plugin: "ENGINE 909", code: "DRM-1",
                              spec: "AU v3 · INSTRUMENT · 12 VOICES", pad: leftPad)
    }

    // MARK: - Interaction

    private enum DragTarget { case none, lvl(Int), dly(Int), flt(Int), pitch(Int), rvb(Int), decay(Int), bpm, swing, paint(Int, Bool), globalPitch, globalNoise, globalDecay, rowDrag(Int) }
    private var dragTarget: DragTarget = .none
    private var dragStartY: CGFloat = 0
    private var dragStartValue: Float = 0

    // MARK: - Undo / Redo (10-step) + pattern-chain state

    /// Full editable instrument state for the active slot. Captured before a
    /// user gesture and restored on undo/redo. (Transport play state, the
    /// chain, and the selected slot are deliberately NOT part of this.)
    private struct Snapshot: Equatable {
        var steps: [Bool]; var swing: [Int16]; var vel: [Float]; var velSet: [Bool]
        var level: [Float]; var delay: [Float]; var decay: [Float]
        var filter: [Float]; var pitch: [Float]; var reverb: [Float]
        var character: [Int32]; var velPreset: [Int32]; var resolution: [Int32]
        var muted: [Bool]; var soloed: [Bool]
        var bpm: Float; var swingAmt: Float; var bars: Int32
        var gPitch: Float; var gNoise: Float; var gDecay: Float
    }
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var pendingPre: Snapshot? = nil
    private let undoLimit = 10

    // Pattern chain (song mode). Mirror of the engine's chain so the UI can
    // draw it without round-tripping every frame. Chain auto-engages whenever
    // it has ≥1 entry (built from the LINK row under the PATTERN buttons).
    private var chainSlotsLocal: [Int] = []

    // Header hit rects (undo/redo + save/load), repopulated on draw.
    private var undoHitRect: NSRect = .zero
    private var redoHitRect: NSRect = .zero
    private var saveHitRect: NSRect = .zero
    private var loadHitRect: NSRect = .zero
    // LINK strip hit rects.
    private var linkBtnRects: [NSRect] = []   // the four A/B/C/D "add to chain" buttons
    private var linkClrRect: NSRect = .zero

    private func captureSnapshot() -> Snapshot? {
        guard let au = audioUnit else { return nil }
        var steps = [Bool](); steps.reserveCapacity(kNumVoices * kInternalSteps)
        var swing = [Int16](); swing.reserveCapacity(kNumVoices * kInternalSteps)
        var vel = [Float](); vel.reserveCapacity(kNumVoices * kInternalSteps)
        var velSet = [Bool](); velSet.reserveCapacity(kNumVoices * kInternalSteps)
        var level = [Float](), delay = [Float](), decay = [Float]()
        var filter = [Float](), pitch = [Float](), reverb = [Float]()
        var character = [Int32](), velPreset = [Int32](), resolution = [Int32]()
        var muted = [Bool](), soloed = [Bool]()
        for v in 0..<kNumVoices {
            for s in 0..<kInternalSteps {
                steps.append(au.step(forVoice: Int32(v), step: Int32(s)))
                swing.append(Int16(au.swingLevel(forVoice: Int32(v), step: Int32(s))))
                vel.append(au.stepVelocity(forVoice: Int32(v), step: Int32(s)))
                velSet.append(au.stepVelocityIsSet(forVoice: Int32(v), step: Int32(s)))
            }
            level.append(au.level(forVoice: Int32(v)))
            delay.append(au.delayMs(forVoice: Int32(v)))
            decay.append(au.decay(forVoice: Int32(v)))
            filter.append(au.filterNorm(forVoice: Int32(v)))
            pitch.append(au.pitchSemi(forVoice: Int32(v)))
            reverb.append(au.reverbSend(forVoice: Int32(v)))
            character.append(au.character(forVoice: Int32(v)))
            velPreset.append(au.velocityPreset(forVoice: Int32(v)))
            resolution.append(au.resolution(forVoice: Int32(v)))
            muted.append(au.isMuted(forVoice: Int32(v)))
            soloed.append(au.isSoloed(forVoice: Int32(v)))
        }
        return Snapshot(steps: steps, swing: swing, vel: vel, velSet: velSet, level: level, delay: delay, decay: decay,
                        filter: filter, pitch: pitch, reverb: reverb, character: character,
                        velPreset: velPreset, resolution: resolution, muted: muted, soloed: soloed,
                        bpm: au.bpm, swingAmt: au.swing, bars: au.bars,
                        gPitch: au.globalPitchSemi, gNoise: au.globalNoise, gDecay: au.globalDecay)
    }

    private func applySnapshot(_ s: Snapshot) {
        guard let au = audioUnit else { return }
        for v in 0..<kNumVoices {
            let base = v * kInternalSteps
            for st in 0..<kInternalSteps {
                au.setStepForVoice(Int32(v), step: Int32(st), on: s.steps[base + st])
                au.setSwingLevelForVoice(Int32(v), step: Int32(st), level: Int32(s.swing[base + st]))
                au.setStepVelocityForVoice(Int32(v), step: Int32(st), velocity: s.vel[base + st], isSet: s.velSet[base + st])
            }
            au.setLevelForVoice(Int32(v), level: s.level[v])
            au.setDelayMsForVoice(Int32(v), ms: s.delay[v])
            au.setDecayForVoice(Int32(v), decay: s.decay[v])
            au.setFilterNormForVoice(Int32(v), norm: s.filter[v])
            au.setPitchSemiForVoice(Int32(v), semi: s.pitch[v])
            au.setReverbSendForVoice(Int32(v), send: s.reverb[v])
            au.setCharacterForVoice(Int32(v), character: s.character[v])
            au.setVelocityPresetForVoice(Int32(v), preset: s.velPreset[v])
            au.setResolutionForVoice(Int32(v), resolution: s.resolution[v])
            au.setMutedForVoice(Int32(v), muted: s.muted[v])
            au.setSoloedForVoice(Int32(v), soloed: s.soloed[v])
        }
        au.bpm = s.bpm
        au.swing = s.swingAmt
        au.bars = s.bars
        au.globalPitchSemi = s.gPitch
        au.globalNoise = s.gNoise
        au.globalDecay = s.gDecay
        needsDisplay = true
    }

    /// Capture the pre-edit state once per gesture (lazy; committed on change).
    private func beginEdit() {
        if pendingPre == nil { pendingPre = captureSnapshot() }
    }
    /// If anything actually changed since beginEdit(), push one undo entry.
    private func commitEditIfChanged() {
        guard let pre = pendingPre else { return }
        pendingPre = nil
        guard let now = captureSnapshot() else { return }
        if now != pre {
            undoStack.append(pre)
            if undoStack.count > undoLimit { undoStack.removeFirst() }
            redoStack.removeAll()
            needsDisplay = true   // refresh UNDO/REDO enabled state
        }
    }
    private func performUndo() {
        guard let pre = undoStack.popLast(), let now = captureSnapshot() else { return }
        redoStack.append(now)
        applySnapshot(pre)
    }

    // MARK: - Named SAVE / LOAD presets (on disk, reusable in any project)

    private func presentSavePreset() {
        guard let au = audioUnit else { return }
        let alert = NSAlert()
        alert.messageText = "Save Preset"
        alert.informativeText = "Name this kit + pattern. It'll be available in any project."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = "My Beat"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            PresetStore.save("Drums", name: field.stringValue, data: au.stateData())
        }
    }

    private func presentLoadPreset() {
        let names = PresetStore.list("Drums")
        let menu = NSMenu(title: "Load Preset")
        if names.isEmpty {
            let it = NSMenuItem(title: "No saved presets yet", action: nil, keyEquivalent: "")
            it.isEnabled = false; menu.addItem(it)
        } else {
            for n in names {
                let it = NSMenuItem(title: n, action: #selector(loadPresetPicked(_:)), keyEquivalent: "")
                it.target = self; menu.addItem(it)
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: loadHitRect.minX, y: loadHitRect.minY), in: self)
    }

    @objc private func loadPresetPicked(_ sender: NSMenuItem) {
        guard let au = audioUnit, let data = PresetStore.load("Drums", name: sender.title) else { return }
        au.loadStateData(data)
        chainSlotsLocal = au.chainSlots().map { $0.intValue }
        undoStack.removeAll(); redoStack.removeAll(); pendingPre = nil
        needsDisplay = true
    }
    private func performRedo() {
        guard let nxt = redoStack.popLast(), let now = captureSnapshot() else { return }
        undoStack.append(now)
        applySnapshot(nxt)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let tr = transportRect()

        // ----- Header UNDO / REDO + SAVE / LOAD (not undoable themselves) -----
        if undoHitRect.contains(p) { performUndo(); return }
        if redoHitRect.contains(p) { performRedo(); return }
        if midiModeRect.contains(p) { audioUnit?.midiMode.toggle(); needsDisplay = true; return }
        // Header notice (MIDI MODE offer / hint).
        if notice != nil && noticeActionRect.contains(p) { audioUnit?.midiMode = true; clearNotice(); return }
        if notice != nil && noticeCloseRect.contains(p) { clearNotice(); return }
        // DRAG MIDI / DRAG AUDIO: pre-render now, decide click vs drag later.
        if exportMidiRect.contains(p) {
            if event.modifierFlags.contains(.option) { exportMIDI(); return }   // ⌥-click: classic Save As
            beginExportPress(.midi, at: p); return
        }
        if exportAudioRect.contains(p) {
            beginExportPress(event.modifierFlags.contains(.option) ? .stems : .mix, at: p); return
        }
        if isolateRect.contains(p) { audioUnit?.isolate.toggle(); needsDisplay = true; return }

        // ----- LINK strip: build / clear the song chain -----
        for (i, r) in linkBtnRects.enumerated() where r.contains(p) {
            if chainSlotsLocal.count < 32 { chainSlotsLocal.append(i) }
            audioUnit?.setChainSlots(chainSlotsLocal.map { NSNumber(value: $0) })
            needsDisplay = true; return
        }
        if !chainSlotsLocal.isEmpty && linkClrRect.contains(p) {
            chainSlotsLocal.removeAll()
            audioUnit?.clearChain()
            needsDisplay = true; return
        }

        // ----- Transport row -----
        // (PLAY / STOP / REC removed — playback follows the host transport.)

        // Everything below mutates editable state — capture an undo checkpoint.
        beginEdit()

        // BPM area — now the left-most control on the transport row.
        let bpmRect = NSRect(x: leftPad, y: tr.midY - 10, width: 70, height: 20)
        if bpmRect.contains(p) {
            if event.clickCount == 2 { presentBPMTypeInput(); return }
            dragTarget = .bpm; dragStartY = p.y; dragStartValue = audioUnit?.bpm ?? 120
            return
        }

        // PATTERN A/B/C/D — select the slot to edit. (Chaining is built from
        // the LINK row below, handled above.)
        for (i, r) in patternRects.enumerated() where r.contains(p) {
            audioUnit?.patternSlot = Int32(i)
            needsDisplay = true
            return
        }

        // SWING area
        if swingHitRect.contains(p) {
            if event.clickCount == 2 { presentSwingTypeInput(); return }
            dragTarget = .swing; dragStartY = p.y; dragStartValue = audioUnit?.swing ?? 0.12
            return
        }

        // BARS
        if barsHitRect.contains(p) {
            if event.clickCount == 2 { presentBarsTypeInput(); return }
            let cur = Int(audioUnit?.bars ?? 8)
            let cycle = [1, 2, 4, 8]
            let next = cycle.first(where: { $0 > cur }) ?? cycle[0]
            audioUnit?.bars = Int32(next)
            needsDisplay = true
            return
        }

        // GENRE — pop the preset menu
        if genreHitRect.contains(p) {
            presentGenreMenu(anchor: NSPoint(x: genreHitRect.minX, y: genreHitRect.minY))
            return
        }

        // Global PITCH — vertical drag, double-click resets.
        if pitchHitRect.contains(p) {
            if event.clickCount == 2 {
                audioUnit?.globalPitchSemi = 0; needsDisplay = true; return
            }
            dragTarget = .globalPitch; dragStartY = p.y
            dragStartValue = audioUnit?.globalPitchSemi ?? 0
            return
        }
        // Global NOISE — vertical drag, double-click clears.
        if noiseHitRect.contains(p) {
            if event.clickCount == 2 {
                audioUnit?.globalNoise = 0; needsDisplay = true; return
            }
            dragTarget = .globalNoise; dragStartY = p.y
            dragStartValue = audioUnit?.globalNoise ?? 0
            return
        }
        // (Global VEL pill removed — per-voice VEL handled in row hit-tests below.)
        // Global DECAY — vertical drag, double-click resets to 100%.
        if decayHitRect.contains(p) {
            if event.clickCount == 2 {
                audioUnit?.globalDecay = 1.0; needsDisplay = true; return
            }
            dragTarget = .globalDecay; dragStartY = p.y
            dragStartValue = audioUnit?.globalDecay ?? 1.0
            return
        }

        // ----- Voice rows -----
        let block = voiceRowsRect()
        let rowH = block.height / CGFloat(kNumVoices)

        guard p.y >= block.minY && p.y <= block.maxY,
              p.x >= 0 && p.x <= bounds.width else { return }
        let vi = Int((block.maxY - p.y) / rowH)
        guard vi >= 0 && vi < kNumVoices else { return }
        let cy = block.maxY - CGFloat(vi + 1) * rowH + rowH * 0.5

        // Drag handle (crosshair before step 1) — start a pattern drag.
        let handleX0 = gridXRange().0 - 6 - handleW
        if NSRect(x: handleX0 - 2, y: cy - rowH * 0.5, width: handleW + 4, height: rowH).contains(p) {
            dragTarget = .rowDrag(vi); rowDragSrc = vi; rowDropTarget = nil
            NSCursor.closedHand.push()
            needsDisplay = true; return
        }

        // M / S toggles
        let mX = leftPad + glyphW + 4 + nameW + 8
        let sX = mX + msW + 4
        if NSRect(x: mX, y: cy - 10, width: 18, height: 20).contains(p) {
            audioUnit?.setMutedForVoice(Int32(vi), muted: !(audioUnit?.isMuted(forVoice: Int32(vi)) ?? false))
            needsDisplay = true; return
        }
        if NSRect(x: sX, y: cy - 10, width: 18, height: 20).contains(p) {
            audioUnit?.setSoloedForVoice(Int32(vi), soloed: !(audioUnit?.isSoloed(forVoice: Int32(vi)) ?? false))
            needsDisplay = true; return
        }
        // CLR
        let clrX = sX + msW + 4
        if NSRect(x: clrX, y: cy - 7, width: clrW, height: 14).contains(p) {
            audioUnit?.clearSteps(forVoice: Int32(vi))
            needsDisplay = true; return
        }
        // RES button — cycle 8 → 16 → 32 → 64 → 8
        if rowRects[vi].resBtn.contains(p) {
            let cur = Int(audioUnit?.resolution(forVoice: Int32(vi)) ?? 16)
            let next: Int32 = (cur == 8) ? 16 : (cur == 16) ? 32 : (cur == 32) ? 64 : 8
            audioUnit?.setResolutionForVoice(Int32(vi), resolution: next)
            needsDisplay = true; return
        }
        // CHR button — cycle through this voice's variants (now 5 each)
        if rowRects[vi].chrBtn.contains(p) {
            let cur = Int(audioUnit?.character(forVoice: Int32(vi)) ?? 0)
            let count = max(1, Int(audioUnit?.characterCount(forVoice: Int32(vi)) ?? 5))
            let next: Int32 = Int32((cur + 1) % count)
            audioUnit?.setCharacterForVoice(Int32(vi), character: next)
            needsDisplay = true; return
        }
        // VEL button — cycle through per-voice velocity presets.
        // Click forward, option-click backward.
        if rowRects[vi].velBtn.contains(p) {
            guard let au = audioUnit else { return }
            let count = Int(au.velocityPresetCount)
            let cur = Int(au.velocityPreset(forVoice: Int32(vi)))
            let step = event.modifierFlags.contains(.option) ? -1 : 1
            let next = Int32(((cur + step) % count + count) % count)
            au.setVelocityPresetForVoice(Int32(vi), preset: next)
            needsDisplay = true; return
        }
        // Voice name → audition
        let nameRect = NSRect(x: leftPad + glyphW + 4, y: cy - 7, width: nameW, height: 14)
        if nameRect.contains(p) { audioUnit?.triggerVoice(Int32(vi)); return }

        // Right-side big knob bank: LVL | PITCH | DLY | FLT
        if rowRects[vi].lvlKnob.contains(p) {
            dragTarget = .lvl(vi); dragStartY = p.y; dragStartValue = audioUnit?.level(forVoice: Int32(vi)) ?? 1.0
            if event.clickCount == 2 { audioUnit?.setLevelForVoice(Int32(vi), level: 1.0); needsDisplay = true; dragTarget = .none }
            return
        }
        if rowRects[vi].pitchKnob.contains(p) {
            dragTarget = .pitch(vi); dragStartY = p.y; dragStartValue = audioUnit?.pitchSemi(forVoice: Int32(vi)) ?? 0
            if event.clickCount == 2 { audioUnit?.setPitchSemiForVoice(Int32(vi), semi: 0); needsDisplay = true; dragTarget = .none }
            return
        }
        if rowRects[vi].dcyKnob.contains(p) {
            dragTarget = .decay(vi); dragStartY = p.y; dragStartValue = audioUnit?.decay(forVoice: Int32(vi)) ?? 1.0
            if event.clickCount == 2 { audioUnit?.setDecayForVoice(Int32(vi), decay: 1.0); needsDisplay = true; dragTarget = .none }
            return
        }
        if rowRects[vi].dlyKnob.contains(p) {
            dragTarget = .dly(vi); dragStartY = p.y; dragStartValue = audioUnit?.delayMs(forVoice: Int32(vi)) ?? 0
            if event.clickCount == 2 { audioUnit?.setDelayMsForVoice(Int32(vi), ms: 0); needsDisplay = true; dragTarget = .none }
            return
        }
        if rowRects[vi].rvbKnob.contains(p) {
            dragTarget = .rvb(vi); dragStartY = p.y; dragStartValue = audioUnit?.reverbSend(forVoice: Int32(vi)) ?? 0
            if event.clickCount == 2 { audioUnit?.setReverbSendForVoice(Int32(vi), send: 0); needsDisplay = true; dragTarget = .none }
            return
        }
        if rowRects[vi].fltKnob.contains(p) {
            dragTarget = .flt(vi); dragStartY = p.y; dragStartValue = audioUnit?.filterNorm(forVoice: Int32(vi)) ?? 1.0
            if event.clickCount == 2 { audioUnit?.setFilterNormForVoice(Int32(vi), norm: 1.0); needsDisplay = true; dragTarget = .none }
            return
        }

        // Swing tick — click the strip under a cell to cycle its swing
        // 0 → 1 → 2 → 3 → 4 → 0 (straight → 54/58/62/66%). Checked before the
        // cell paint since it lives just below the cell body.
        if let step = swingTickStepAt(point: p, voice: vi) {
            let cur = Int(audioUnit?.swingLevel(forVoice: Int32(vi), step: Int32(step)) ?? 0)
            audioUnit?.setSwingLevelForVoice(Int32(vi), step: Int32(step), level: Int32((cur + 1) % 5))
            needsDisplay = true
            return
        }

        // Step cells — paint-swipe (per-voice resolution & per-voice cell grid)
        if let step = internalStepAt(point: p, voice: vi) {
            let cur = audioUnit?.step(forVoice: Int32(vi), step: Int32(step)) ?? false
            let newState = !cur
            audioUnit?.setStepForVoice(Int32(vi), step: Int32(step), on: newState)
            dragTarget = .paint(vi, newState)
            needsDisplay = true
            return
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if exportPress != nil { exportPressDragged(event); return }
        guard let au = audioUnit else { return }
        let p = convert(event.locationInWindow, from: nil)
        let dy = Float(p.y - dragStartY)
        let fine = event.modifierFlags.contains(.option)

        switch dragTarget {
        case .none: return
        case .lvl(let v):
            let scale: Float = fine ? 0.001 : 0.005
            let newVal = max(0.0, min(2.0, dragStartValue + dy * scale))
            au.setLevelForVoice(Int32(v), level: newVal)
            needsDisplay = true
        case .dly(let v):
            let scale: Float = fine ? 0.3 : 1.2
            let newVal = max(0.0, min(500.0, dragStartValue + dy * scale))
            au.setDelayMsForVoice(Int32(v), ms: newVal)
            needsDisplay = true
        case .flt(let v):
            let scale: Float = fine ? 0.001 : 0.005
            let newVal = max(0.0, min(1.0, dragStartValue + dy * scale))
            au.setFilterNormForVoice(Int32(v), norm: newVal)
            needsDisplay = true
        case .pitch(let v):
            let scale: Float = fine ? 0.02 : 0.10
            let newVal = max(-24.0, min(24.0, dragStartValue + dy * scale))
            au.setPitchSemiForVoice(Int32(v), semi: newVal)
            needsDisplay = true
        case .rvb(let v):
            let scale: Float = fine ? 0.001 : 0.005
            let newVal = max(0.0, min(1.0, dragStartValue + dy * scale))
            au.setReverbSendForVoice(Int32(v), send: newVal)
            needsDisplay = true
        case .decay(let v):
            let scale: Float = fine ? 0.001 : 0.005
            let newVal = max(0.0, min(1.0, dragStartValue + dy * scale))
            au.setDecayForVoice(Int32(v), decay: newVal)
            needsDisplay = true
        case .bpm:
            let scale: Float = fine ? 0.1 : 0.5
            let newVal = max(40.0, min(220.0, dragStartValue + dy * scale))
            au.bpm = newVal
            needsDisplay = true
        case .swing:
            let scale: Float = fine ? 0.0005 : 0.002
            let newVal = max(0.0, min(0.5, dragStartValue + dy * scale))
            au.swing = newVal
            needsDisplay = true
        case .globalPitch:
            // ±12 semitones across the full drag range. Fine mode = 1/cent feel.
            let scale: Float = fine ? 0.02 : 0.08
            let newVal = max(-12.0, min(12.0, dragStartValue + dy * scale))
            au.globalPitchSemi = newVal
            needsDisplay = true
        case .globalNoise:
            let scale: Float = fine ? 0.001 : 0.005
            let newVal = max(0.0, min(1.0, dragStartValue + dy * scale))
            au.globalNoise = newVal
            needsDisplay = true
        case .globalDecay:
            let scale: Float = fine ? 0.001 : 0.005
            let newVal = max(0.0, min(1.0, dragStartValue + dy * scale))
            au.globalDecay = newVal
            needsDisplay = true
        case .rowDrag(let src):
            let block = voiceRowsRect()
            let rowH = block.height / CGFloat(kNumVoices)
            var target: Int? = nil
            if p.y >= block.minY && p.y <= block.maxY {
                let vi = Int((block.maxY - p.y) / rowH)
                if vi >= 0 && vi < kNumVoices && vi != src { target = vi }
            }
            if target != rowDropTarget { rowDropTarget = target; needsDisplay = true }
        case .paint(let v, let mark):
            if let s = internalStepAt(point: p, voice: v) {
                let cur = au.step(forVoice: Int32(v), step: Int32(s))
                if cur != mark {
                    au.setStepForVoice(Int32(v), step: Int32(s), on: mark)
                    needsDisplay = true
                }
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let press = exportPress {
            exportPress = nil
            if !press.dragStarted { exportClicked(press) }
            return
        }
        if case .rowDrag(let src) = dragTarget {
            NSCursor.pop()
            if let dst = rowDropTarget, let au = audioUnit {
                if event.modifierFlags.contains(.option) {
                    au.swapPattern(ofVoice: Int32(src), withVoice: Int32(dst))
                } else {
                    au.copyPattern(fromVoice: Int32(src), toVoice: Int32(dst))
                }
            }
            rowDragSrc = nil; rowDropTarget = nil
            needsDisplay = true
        }
        dragTarget = .none
        commitEditIfChanged()
    }

    // MARK: - Exports (MIDI / audio mix / stems)

    /// File stem for exports: what range is being exported, at what tempo.
    private func exportBaseName() -> String {
        guard let au = audioUnit else { return "Engine909" }
        let letters = ["A", "B", "C", "D"]
        let chainOn = !au.isolate && !chainSlotsLocal.isEmpty
        let range = chainOn ? "Chain" : "Pattern\(letters[max(0, min(3, Int(au.patternSlot)))])"
        return "Engine909_\(range)_\(Int(au.bpm.rounded()))bpm"
    }

    private func showExportError(_ what: String) {
        let a = NSAlert()
        a.messageText = "\(what) export failed"
        a.informativeText = "The file could not be written. Pick a folder you have write access to and try again."
        a.runModal()
    }

    private func exportMIDI() {
        guard let au = audioUnit, exporting == nil else { return }
        let panel = NSSavePanel()
        panel.title = "Export MIDI"
        panel.allowedContentTypes = [UTType(filenameExtension: "mid") ?? .data]
        panel.nameFieldStringValue = exportBaseName() + ".mid"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exporting = "midi"; needsDisplay = true
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = au.exportMIDI(toPath: url.path)
            DispatchQueue.main.async {
                self.exporting = nil; self.needsDisplay = true
                guard ok else { self.showExportError("MIDI"); return }
                self.offerMidiModeAfterMIDI(prefix: "SAVED \(url.lastPathComponent)")
            }
        }
    }

    private func presentExportAudioMenu() {
        guard exporting == nil else { return }
        let menu = NSMenu(title: "Export Audio")
        let hint = NSMenuItem(title: "Drag the button onto a track (⌥-drag = stems)", action: nil, keyEquivalent: "")
        hint.isEnabled = false; menu.addItem(hint)
        menu.addItem(.separator())
        let mixF = NSMenuItem(title: "Mix — Show in Finder", action: #selector(revealMixPicked(_:)), keyEquivalent: "")
        mixF.target = self; menu.addItem(mixF)
        let stemsF = NSMenuItem(title: "Stems — Show in Finder", action: #selector(revealStemsPicked(_:)), keyEquivalent: "")
        stemsF.target = self; menu.addItem(stemsF)
        menu.addItem(.separator())
        let mix = NSMenuItem(title: "Mix — Save As…", action: #selector(exportAudioMixPicked(_:)), keyEquivalent: "")
        mix.target = self; menu.addItem(mix)
        let stems = NSMenuItem(title: "Stems — Save to Folder…", action: #selector(exportAudioStemsPicked(_:)), keyEquivalent: "")
        stems.target = self; menu.addItem(stems)
        menu.popUp(positioning: nil, at: NSPoint(x: exportAudioRect.minX, y: exportAudioRect.minY), in: self)
    }

    @objc private func revealMixPicked(_ sender: NSMenuItem) { revealExport(.mix) }
    @objc private func revealStemsPicked(_ sender: NSMenuItem) { revealExport(.stems) }

    // MARK: - Drag-out exports (DRAG MIDI / DRAG AUDIO)
    //
    // Press on the key → the file is rendered right away (background) into
    // ~/Music/Engine 909 Exports. Drag past a few px → an NSDraggingSession
    // carrying the plain file URL starts, so the host (Logic) gets a normal
    // file drop: MIDI region / audio region on the track under the pointer.
    // Plain click → the file is shown in Finder (and its URL is on the
    // clipboard) — the fallback if a host doesn't accept drags out of an
    // out-of-process plug-in window. Identical state reuses the last file
    // instead of writing a new one; files are never deleted (hosts may
    // reference audio in place).

    /// Durable, host-readable folder. ~/Music/Engine 909 Exports via the
    /// sandbox temporary-exception entitlement; falls back to the extension
    /// container's Application Support if that is not writable.
    private static let exportsFolder: URL? = {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            candidates.append(URL(fileURLWithPath: String(cString: dir), isDirectory: true)
                .appendingPathComponent("Music/Engine 909 Exports", isDirectory: true))
        }
        if let app = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.append(app.appendingPathComponent("Engine909 Exports", isDirectory: true))
        }
        for c in candidates {
            do {
                try fm.createDirectory(at: c, withIntermediateDirectories: true)
                let probe = c.appendingPathComponent(".write-probe")
                try Data().write(to: probe)
                try? fm.removeItem(at: probe)
                return c
            } catch { continue }
        }
        return nil
    }()

    /// Everything the rendered file depends on — same key, same file.
    private func exportKey(_ kind: ExportKind, _ au: DrumsAudioUnit) -> Data {
        var d = au.stateData()
        var extras: [Float] = [Float(kind.rawValue), au.bpm, Float(au.exportDurationSeconds)]
        extras += au.parameterTree?.allParameters.map { $0.value } ?? []
        extras.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }

    /// Start (or reuse) the render for `kind`. Returns nil if there is no
    /// writable folder / no audio unit.
    private func startExportJob(_ kind: ExportKind) -> ExportJob? {
        guard let au = audioUnit, let folder = Self.exportsFolder else { return nil }
        let key = exportKey(kind, au)
        let job = ExportJob(kind: kind)
        if let c = exportCache[kind], c.key == key,
           !c.urls.isEmpty, c.urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
            job.urls = c.urls; job.done = true
            return job
        }
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyyMMdd-HHmmss"
        let base = exportBaseName() + "_" + df.string(from: Date())
        let isAudio = kind != .midi
        if isAudio { exporting = "audio"; needsDisplay = true }
        job.group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            var urls: [URL] = []
            switch kind {
            case .midi:
                let u = folder.appendingPathComponent(base + ".mid")
                if au.exportMIDI(toPath: u.path) { urls = [u] }
            case .mix:
                let u = folder.appendingPathComponent(base + ".wav")
                if au.exportAudioMix(toPath: u.path) { urls = [u] }
            case .stems:
                let dir = folder.appendingPathComponent(base + "_Stems", isDirectory: true)
                if (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil {
                    urls = au.exportAudioStems(toFolder: dir.path).map { URL(fileURLWithPath: $0) }
                }
            }
            job.urls = urls; job.done = true
            job.group.leave()
            DispatchQueue.main.async {
                if isAudio { self.exporting = nil; self.needsDisplay = true }
                if !urls.isEmpty { self.exportCache[kind] = (key, urls) }
            }
        }
        return job
    }

    private func beginExportPress(_ kind: ExportKind, at p: NSPoint) {
        guard exporting == nil else { return }
        // Audio: a plain click opens the menu, so only pre-render once the
        // pointer actually moves (see exportPressDragged). MIDI is instant.
        let job = kind == .midi ? startExportJob(kind) : nil
        exportPress = ExportPress(kind: kind, start: p, job: job)
        if kind == .midi && job == nil { showNotice("EXPORT FOLDER NOT WRITABLE · ⌥-CLICK FOR SAVE AS…") }
    }

    private func exportPressDragged(_ event: NSEvent) {
        guard var press = exportPress, !press.dragStarted else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - press.start.x, p.y - press.start.y) > 4 else { return }
        press.dragStarted = true; exportPress = press
        guard let job = press.job ?? startExportJob(press.kind) else {
            showNotice("EXPORT FOLDER NOT WRITABLE · USE SAVE AS…"); return
        }
        // MIDI is instant; an 8-bar audio mix renders in well under a second.
        if job.group.wait(timeout: .now() + 10) == .timedOut || job.urls.isEmpty {
            showNotice("EXPORT FAILED · TRY SAVE AS…"); return
        }
        startFileDrag(job.urls, kind: press.kind, event: event, at: p)
    }

    private func startFileDrag(_ urls: [URL], kind: ExportKind, event: NSEvent, at p: NSPoint) {
        let title: String
        switch kind {
        case .stems: title = "\(urls.count) STEMS · " + (urls.first?.deletingLastPathComponent().lastPathComponent ?? "")
        default:     title = urls.first?.lastPathComponent ?? "Engine 909"
        }
        let chip = Self.dragChip(title, midi: kind == .midi)
        let items: [NSDraggingItem] = urls.enumerated().map { i, url in
            // Plain file URL only (public.file-url) — what Logic accepts most
            // reliably; extra flavours have broken Logic's drop handling before.
            let it = NSDraggingItem(pasteboardWriter: url as NSURL)
            let o = CGFloat(min(i, 4)) * 3
            it.setDraggingFrame(NSRect(x: p.x - 14 + o, y: p.y - chip.size.height * 0.5 - o,
                                       width: chip.size.width, height: chip.size.height),
                                contents: i == 0 ? chip : nil)
            return it
        }
        dragKind = kind; needsDisplay = true
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }

    /// Small labelled chip shown under the pointer while dragging.
    private static func dragChip(_ title: String, midi: Bool) -> NSImage {
        let attr: [NSAttributedString.Key: Any] = [.font: Palette.printFont(10), .foregroundColor: cream]
        let tag = midi ? "MIDI" : "WAV"
        let tagAttr: [NSAttributedString.Key: Any] = [.font: Palette.printFont(8), .foregroundColor: red]
        let tw = NSString(string: title).size(withAttributes: attr).width
        let gw = NSString(string: tag).size(withAttributes: tagAttr).width
        let size = NSSize(width: ceil(min(360, tw) + gw + 30), height: 22)
        return NSImage(size: size, flipped: false) { r in
            let body = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            panelDark.withAlphaComponent(0.95).setFill(); body.fill()
            red.setStroke(); body.lineWidth = 1; body.stroke()
            let tagR = NSRect(x: 6, y: 5, width: gw + 8, height: 12)
            cream.setFill(); NSBezierPath(roundedRect: tagR, xRadius: 2, yRadius: 2).fill()
            NSString(string: tag).draw(at: NSPoint(x: tagR.minX + 4, y: tagR.minY + 1), withAttributes: tagAttr)
            NSString(string: title).draw(with: NSRect(x: tagR.maxX + 6, y: 6, width: r.width - tagR.maxX - 10, height: 14),
                                         options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attr)
            return true
        }
    }

    /// Click without drag: MIDI → show the file in Finder; audio → menu.
    private func exportClicked(_ press: ExportPress) {
        switch press.kind {
        case .midi:
            guard let job = press.job else { return }
            _ = job.group.wait(timeout: .now() + 10)
            guard !job.urls.isEmpty else { showNotice("EXPORT FAILED · ⌥-CLICK FOR SAVE AS…"); return }
            putOnClipboardAndReveal(job.urls)
            offerMidiModeAfterMIDI(prefix: "IN FINDER · DRAG IT ONTO A TRACK")
        case .mix, .stems:
            presentExportAudioMenu()
        }
    }

    private func revealExport(_ kind: ExportKind) {
        guard let job = startExportJob(kind) else { showNotice("EXPORT FOLDER NOT WRITABLE · USE SAVE AS…"); return }
        job.group.notify(queue: .main) {
            guard !job.urls.isEmpty else { self.showNotice("EXPORT FAILED · TRY SAVE AS…"); return }
            self.putOnClipboardAndReveal(job.urls)
            self.showNotice("IN FINDER · DRAG IT ONTO A TRACK")
        }
    }

    /// Fallback path: file URL(s) on the clipboard + Finder window with the
    /// file(s) selected, so they can be dragged in from there.
    private func putOnClipboardAndReveal(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls.map { $0 as NSURL })
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func offerMidiModeAfterMIDI(prefix: String) {
        if audioUnit?.midiMode ?? true { showNotice(prefix); return }
        showNotice(prefix + " · MIDI MODE ON SO IT DOESN'T PLAY TWICE?", action: "MIDI MODE ON")
    }

    private func showNotice(_ text: String, action: String? = nil, seconds: Double = 12) {
        noticeSerial += 1
        let serial = noticeSerial
        notice = ExportNotice(text: text, action: action)
        setNeedsDisplay(NSRect(x: 0, y: bounds.height - headerH, width: bounds.width, height: headerH))
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.noticeSerial == serial else { return }
            self.clearNotice()
        }
    }

    private func clearNotice() {
        notice = nil
        needsDisplay = true
    }

    @objc private func exportAudioMixPicked(_ sender: NSMenuItem) {
        guard let au = audioUnit, exporting == nil else { return }
        let panel = NSSavePanel()
        panel.title = "Export Audio — Mix"
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = exportBaseName() + ".wav"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exporting = "audio"; needsDisplay = true
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = au.exportAudioMix(toPath: url.path)
            DispatchQueue.main.async {
                self.exporting = nil; self.needsDisplay = true
                if !ok { self.showExportError("Audio") }
            }
        }
    }

    @objc private func exportAudioStemsPicked(_ sender: NSMenuItem) {
        guard let au = audioUnit, exporting == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Export Audio — Stems"
        panel.message = "Choose a folder: one WAV per voice (KICK.wav, SNARE.wav …)."
        panel.prompt = "Export Stems Here"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exporting = "audio"; needsDisplay = true
        DispatchQueue.global(qos: .userInitiated).async {
            let files = au.exportAudioStems(toFolder: url.path)
            DispatchQueue.main.async {
                self.exporting = nil; self.needsDisplay = true
                if files.isEmpty { self.showExportError("Stem") }
            }
        }
    }

    // MARK: - Genre presets menu

    private func presentGenreMenu(anchor: NSPoint) {
        let menu = NSMenu(title: "Genre Presets")
        for (gi, preset) in kPresets.enumerated() {
            let item = NSMenuItem(title: "\(preset.name)  ·  \(Int(preset.bpm)) BPM",
                                  action: #selector(genrePicked(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = gi
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: anchor, in: self)
    }

    @objc private func genrePicked(_ sender: NSMenuItem) {
        applyPreset(genreIndex: sender.tag)
    }

    /// Apply a genre preset — fills ALL FOUR pattern slots A/B/C/D with the
    /// genre's four variations (A=I, B=II, C=III, D=IV), sets the engine BPM
    /// to the genre's standard tempo, and switches the active slot to A.
    ///
    /// Per-voice resolution is taken from variation A and applied once (the
    /// engine stores resolution per voice, not per slot), so all four
    /// variations within a genre must share the same per-voice resolution
    /// layout — which is the case for the presets in kPresets.
    private func applyPreset(genreIndex: Int) {
        guard genreIndex >= 0 && genreIndex < kPresets.count,
              let au = audioUnit else { return }
        let preset = kPresets[genreIndex]
        guard preset.variations.count >= 1 else { return }

        au.bpm = preset.bpm

        // Set per-voice resolutions from variation A. All four variations
        // share the same per-voice resolutions by convention.
        let varA = preset.variations[0]
        for v in 0..<kNumVoices {
            let row = v < varA.rows.count ? varA.rows[v] : E16
            au.setResolutionForVoice(Int32(v), resolution: Int32(row.res))
        }

        // Write each of the 4 slots with the matching variation (clamp if
        // fewer than 4 are defined).
        let savedSlot = au.patternSlot
        for slot in 0..<4 {
            au.patternSlot = Int32(slot)
            let varIdx = min(slot, preset.variations.count - 1)
            let variation = preset.variations[varIdx]
            for v in 0..<kNumVoices {
                let row = v < variation.rows.count ? variation.rows[v] : E16
                let chars = Array(row.pattern)
                let mult = kSubdiv / row.res            // 4, 2, or 1 (for res 8/16/32)
                // Clear the voice's slot completely.
                for s in 0..<kInternalSteps {
                    au.setStepForVoice(Int32(v), step: Int32(s), on: false)
                }
                // Tile the 1-bar pattern across all 8 bars at the voice's
                // resolution. Cell c in bar b → internal step b*32 + c*mult.
                for bar in 0..<8 {
                    for c in 0..<row.res {
                        let idx = c % max(chars.count, 1)
                        let on = (chars.count > 0) && (chars[idx] == "X" || chars[idx] == "x")
                        let internalStep = bar * kSubdiv + c * mult
                        au.setStepForVoice(Int32(v), step: Int32(internalStep), on: on)
                    }
                }
            }
        }
        // Switch to A after loading so the user starts on the first variation.
        au.patternSlot = 0
        _ = savedSlot
        // A genre load rewrites all four slots — more than the single-slot undo
        // snapshot covers — so reset undo history to keep it consistent.
        pendingPre = nil
        undoStack.removeAll()
        redoStack.removeAll()
        needsDisplay = true
    }

    // MARK: - Type input dialogs

    private func presentBPMTypeInput() {
        guard let au = audioUnit else { return }
        let alert = NSAlert()
        alert.messageText = "Set BPM"
        alert.informativeText = "Enter a tempo between 40 and 220."
        alert.alertStyle = .informational
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.stringValue = String(format: "%.1f", au.bpm)
        field.alignment = .center
        alert.accessoryView = field
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            if let v = Float(field.stringValue.replacingOccurrences(of: ",", with: ".")) {
                let clamped = max(40.0, min(220.0, v))
                au.bpm = clamped
                needsDisplay = true
            }
        }
        commitEditIfChanged()
    }

    private func presentBarsTypeInput() {
        guard let au = audioUnit else { return }
        let alert = NSAlert()
        alert.messageText = "Set Bars"
        alert.informativeText = "Enter loop length in bars (1..8)."
        alert.alertStyle = .informational
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.stringValue = "\(au.bars)"
        field.alignment = .center
        alert.accessoryView = field
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            if let v = Int(field.stringValue.trimmingCharacters(in: .whitespaces)) {
                au.bars = Int32(max(1, min(8, v)))
                needsDisplay = true
            }
        }
        commitEditIfChanged()
    }

    private func presentSwingTypeInput() {
        guard let au = audioUnit else { return }
        let alert = NSAlert()
        alert.messageText = "Set Swing"
        alert.informativeText = "Enter a percentage between 0 and 50."
        alert.alertStyle = .informational
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.stringValue = String(format: "%.0f", au.swing * 100)
        field.alignment = .center
        alert.accessoryView = field
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let cleaned = field.stringValue.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: ",", with: ".")
            if let v = Float(cleaned) {
                let clamped = max(0.0, min(50.0, v)) / 100.0
                au.swing = clamped
                needsDisplay = true
            }
        }
        commitEditIfChanged()
    }
}

// MARK: - Drag-out export types + NSDraggingSource

private enum ExportKind: Int { case midi, mix, stems }

/// One render into the exports folder; `group` leaves when `urls` is set.
private final class ExportJob {
    let kind: ExportKind
    let group = DispatchGroup()
    var urls: [URL] = []
    var done = false
    init(kind: ExportKind) { self.kind = kind }
}

private struct ExportPress {
    let kind: ExportKind
    let start: NSPoint
    let job: ExportJob?
    var dragStarted = false
}

private struct ExportNotice {
    let text: String
    let action: String?
}

extension DrumsParameterView: NSDraggingSource, NSViewToolTipOwner {
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Hosts differ in which operation they pick for a file drop; offer the
        // usual Finder-like set (never .move / .delete — the file stays ours).
        return [.copy, .generic, .link]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        let kind = dragKind
        dragKind = nil
        needsDisplay = true
        guard let kind else { return }
        if operation.isEmpty {
            showNotice(kind == .midi ? "NOT DROPPED · CLICK DRAG MIDI TO GET THE FILE IN FINDER"
                                     : "NOT DROPPED · CLICK DRAG AUDIO ▾ → SHOW IN FINDER")
            return
        }
        switch kind {
        case .midi:  offerMidiModeAfterMIDI(prefix: "MIDI DROPPED")
        case .mix:   showNotice("AUDIO DROPPED · FILE KEPT IN ~/Music/Engine 909 Exports")
        case .stems: showNotice("STEMS DROPPED · FILES KEPT IN ~/Music/Engine 909 Exports")
        }
    }
}

// Convenience wrappers — Int-typed args that forward to the Int32 Obj-C methods.
private extension DrumsAudioUnit {
    func stepInt(_ v: Int, step s: Int) -> Bool { self.step(forVoice: Int32(v), step: Int32(s)) }
    func levelInt(_ v: Int) -> Float           { self.level(forVoice: Int32(v)) }
    func delayMsInt(_ v: Int) -> Float         { self.delayMs(forVoice: Int32(v)) }
    func isMutedInt(_ v: Int) -> Bool          { self.isMuted(forVoice: Int32(v)) }
    func isSoloedInt(_ v: Int) -> Bool         { self.isSoloed(forVoice: Int32(v)) }
}
