//
//  StringThingParameterView.swift
//  Paradise Audio — String Thing (STR-1)
//
//  Three-panel layout:
//   • Top: big circular "harmonic orbit" visualization. 12 notes on the
//     dodecagon; the active arp note glows red; chord-held notes are red
//     dots; the step grid is drawn as a ring of 16 inner pips that highlight
//     as the step head sweeps around.
//   • Middle: 16-step note-offset grid (click toggles; vertical drag changes
//     the semitone offset for that step).
//   • Bottom: control rows — MODE, DIRECTION, RATE, SCALE, ROOT, OCTAVE,
//     SWING, GATE, DRONE, plus big knobs for OSC mix, FILTER, ENV.
//

import AppKit
import AudioToolbox

// INVERTED palette — StringThing is the DARK TWIN of the cream Drums machine.
// `inkDark`/`inkMid` are redefined LIGHT so the existing draw calls (text,
// hairlines, cell strokes) read correctly on the dark faceplate without
// rewriting every call site. `cream` stays light (active-pill text / fills).
private let faceBg    = Palette.faceBg   // dark faceplate
private let cream     = Palette.cream                                // light accents / active text
private let inkDark   = Palette.inkLight   // light "ink" (inverted)
private let inkMid    = Palette.inkMidL   // mid ink
private let red       = Palette.red
private let panelDark = Palette.panelDark   // dark inset panels

private let aLabel: [NSAttributedString.Key: Any] = [.font: Palette.printFont(10.5), .foregroundColor: inkDark, .kern: 0.8]
private let aTiny:  [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 8, weight: .regular), .foregroundColor: inkMid]
private let aVal:   [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: inkDark]
private let aBtnOn: [NSAttributedString.Key: Any] = [.font: Palette.printFont(10.5), .foregroundColor: cream, .kern: 0.6]
private let aBtnOff:[NSAttributedString.Key: Any] = [.font: Palette.printFont(10.5), .foregroundColor: inkDark, .kern: 0.6]
private let aBrand: [NSAttributedString.Key: Any] = [.font: Palette.printFontCondensed(19), .foregroundColor: inkDark, .kern: 2.0]

// Trimmed option lists for a neater UI. The engine still supports every
// internal enum; we just expose a sensible subset.
private let kNoteNames = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
// ARP removed — keep just SEQ + BERLIN. Voice list = 8 string characters.
private let kModeNames   = ["SEQ","BERLIN","DUBSTEP"]
// String voice characters — see VoiceMode in StringThingEngine.hpp.
private let kVoiceNames  = ["BOW","PLUCK","PIZZ","ENSEMB","TREMOLO","PONT","MARCATO","HARM"]
private let kDirNames    = ["UP","DOWN","RAND"]
private let kRateNames   = ["1","1/2","1/4","1/8","1/16","1/32","1/64"]
private let kScaleNames  = ["CHROM","MAJ","MIN","JOG","CHINA"]
private let kPhraseNames = ["GALLOP","STUTTER","ACID","EUCLID","GLITCH","BOUNCE","CHAOS","RAVE"]
private let kOctChoices  = [1, 2, 3]
// Engine direction indices for each visible button: Up=0, Down=1, Random=3.
private let kDirEngineIdx = [0, 1, 3]
// Engine scale indices for each visible button.
private let kScaleEngineIdx = [0, 1, 2, 3, 4]
// Engine rate slot for each visible button (rate enum: 0=1/1, 8=1/2, 1=1/4..4=1/32, 7=1/64).
private let kRateEngineIdx = [0, 8, 1, 2, 3, 4, 7]   // 1 (whole) … 1/64

// FX type/mode names (the little setting above each FX knob).
private let kDelayTypes  = ["1/8", "1/4", "DOT", "TRIP", "SLAP", "PING"]
private let kReverbTypes = ["ROOM", "HALL", "PLATE", "AMBI"]
private let kChopTypes   = ["1/16", "1/8", "TRIP", "SAW", "REV", "STUT", "RAND", "S&H", "SINE", "GLCH"]

// ── Melodic grid presets ─────────────────────────────────────────────
// Each preset sets scale + root + step count, then paints the 8 note rows.
// rows[0] = ROOT (bottom row) rising upward. A pattern string's length must
// equal `steps`; 'x'/'X' = note on, anything else = off. Inspired by world-
// percussion + electronic sequencer patterns (gamelan, kalimba, acid, etc.).
// ── Harmony config — the missing piece for "long tones with beautiful
// harmonies". A GridPreset paints the chord in the note grid (which rows ring
// = which scale degrees stack), but on its own it inherits whatever voice /
// rate / gate the user last left. A HarmonyConfig bolts the full sustained-
// chord state onto a preset so it actually SOUNDS like a string-ensemble pad:
// ENSEMBLE voice, whole/half-note rate, near-full gate, drone pedal, generous
// reverb. Percussion presets leave `harmony` nil and behave exactly as before.
private struct HarmonyConfig {
    var voice: Int          // engine VoiceMode (3 = ENSEMBLE string section)
    var rate: Int           // engine rate slot (0 = whole, 8 = 1/2 — long tones)
    var gate: Float         // 0.05..1.0 — near 1.0 = notes ring into each other
    var octaveRange: Int    // 1 keeps the chord clean (no octave stacking)
    var tone: Float         // 0 dark … 1 bright
    var cutoff: Float       // Hz
    var reso: Float
    var droneOn: Bool
    var droneLevel: Float   // 0..1.5
    var droneInterval: Int  // 0=root 1=+5th 2=+5+oct 3=octave double
    var droneOctave: Int    // -3..+1
    var reverb: Float       // 0..1 send
    var reverbType: Int     // 0 room 1 hall 2 plate 3 ambi
    var level: Float        // 0..2 master
    var ampA: Float; var ampD: Float; var ampS: Float; var ampR: Float
    var mod: Float          // 0..1 chorus widening
}

// Reusable lush string-pad defaults — most harmony presets tweak a few fields.
private func lush(voice: Int = 3, rate: Int = 0, gate: Float = 0.96,
                  tone: Float = 0.45, cutoff: Float = 2400, reso: Float = 0.18,
                  droneOn: Bool = true, droneLevel: Float = 0.55,
                  droneInterval: Int = 1, droneOctave: Int = -1,
                  reverb: Float = 0.55, reverbType: Int = 1, level: Float = 0.95,
                  ampA: Float = 0.35, ampD: Float = 0.4, ampS: Float = 0.95,
                  ampR: Float = 0.8, mod: Float = 0.25) -> HarmonyConfig {
    HarmonyConfig(voice: voice, rate: rate, gate: gate, octaveRange: 1,
                  tone: tone, cutoff: cutoff, reso: reso, droneOn: droneOn,
                  droneLevel: droneLevel, droneInterval: droneInterval,
                  droneOctave: droneOctave, reverb: reverb, reverbType: reverbType,
                  level: level, ampA: ampA, ampD: ampD, ampS: ampS, ampR: ampR, mod: mod)
}

private struct GridPreset {
    let name: String
    let scale: Int      // engine scale id
    let root: Int       // 0..11
    let steps: Int      // 16 / 32 / 64
    let rows: [String]  // up to 16 rows, [0]=root at bottom
    var harmony: HarmonyConfig? = nil   // non-nil = sustained-chord harmony preset
    var octave: Int = 0       // grid octave the phrase sits in (-2…+2)
    var key: [Int]? = nil     // chromatic presets: semitones of the key (diatonic variations)
}

// Helper: a grid where the named rows hold the chord (tied notes) and re-bow
// it every `hold` steps, for a continuous string pad. The pads use the
// chromatic scale, so `rows` are SEMITONES above ROOT (0…15): e.g. [0,4,7,11]
// = maj7. (Before 2026-11-20 they were pentatonic degrees, which gave other
// chords than the names said.)
private func chord(_ steps: Int, _ rows: [Int], hold: Int = 4) -> [String] {
    // 2026-11-21: the chord is HELD (tied) for `hold` steps, then re-bowed —
    // 'x' starts the note, '-' sustains it (was: re-struck on every step).
    let h = max(1, min(hold, steps))
    let on = String((0..<steps).map { $0 % h == 0 ? Character("x") : Character("-") })
    let off = String(repeating: ".", count: steps)
    let n = min(16, (rows.max() ?? 0) + 1)
    return (0..<n).map { rows.contains($0) ? on : off }
}

// Key masks for chromatic-row presets (rows = semitones above ROOT).
private let kMajor    = [0, 2, 4, 5, 7, 9, 11]
private let kMinor    = [0, 2, 3, 5, 7, 8, 10]
private let kHarmMin  = [0, 2, 3, 5, 7, 8, 11]
private let kDorianK  = [0, 2, 3, 5, 7, 9, 10]

/// Row `r` moved `by` scale steps. Degree-scale presets: rows ARE scale steps.
/// Chromatic presets with a key: walk the key's semitones, so a sequence stays
/// in key (a third up is major or minor as the key demands). Off the top of
/// the grid → drop an octave (12 semitones / one scale cycle).
private func diatonicRow(_ r: Int, by: Int, key: [Int]?, nRows: Int, degreesPerOctave: Int) -> Int? {
    var t: Int
    if let key = key {
        var inKey: [Int] = []
        var o = 0
        while inKey.count < 64 { for k in key { inKey.append(o * 12 + k) }; o += 1 }
        guard let i = inKey.firstIndex(of: r) else { return nil }
        t = inKey[min(inKey.count - 1, i + by)]
        if t >= nRows { t -= 12 }
    } else {
        t = r + by
        if t >= nRows { t -= max(1, degreesPerOctave) }
    }
    return (t >= 0 && t < nRows) ? t : nil
}

private let kGridPresets: [GridPreset] = [
    // ── Long-tone harmony presets — sustained chordal voicings. Each paints a
    // chord across all steps (continuous re-swell) AND carries a HarmonyConfig
    // so loading it switches the engine into lush-string-pad mode. Rows are
    // semitones above ROOT (chromatic scale), see chord().
    GridPreset(name: "Cathedral Maj7", scale: 0, root: 0, steps: 16,
        rows: chord(16, [0, 4, 7, 11]),                 // semitones above root
        harmony: lush(reverb: 0.62, reverbType: 1)),   // HALL
    GridPreset(name: "Velvet Minor 9", scale: 0, root: 9, steps: 16,
        rows: chord(16, [0, 3, 7, 10, 14]),                 // semitones above root
        harmony: lush(tone: 0.36, droneInterval: 1, reverb: 0.58, reverbType: 1)),
    GridPreset(name: "Open Fifths", scale: 0, root: 0, steps: 16,
        rows: chord(16, [0, 7, 12]),                 // semitones above root
        harmony: lush(tone: 0.5, droneLevel: 0.7, droneInterval: 1, reverb: 0.5)),
    GridPreset(name: "Octave Halo", scale: 0, root: 0, steps: 16,
        rows: chord(16, [0, 12]),                 // semitones above root
        harmony: lush(tone: 0.42, droneInterval: 3, reverb: 0.6, reverbType: 3)),
    GridPreset(name: "Sus4 Air", scale: 0, root: 2, steps: 16,
        rows: chord(16, [0, 5, 7]),                 // semitones above root
        harmony: lush(tone: 0.5, reverb: 0.55, reverbType: 2)),
    GridPreset(name: "Sus2 Glass", scale: 0, root: 7, steps: 16,
        rows: chord(16, [0, 2, 7]),                 // semitones above root
        harmony: lush(tone: 0.58, cutoff: 2800, reverb: 0.6, reverbType: 2)),
    GridPreset(name: "Add9 Shimmer", scale: 0, root: 5, steps: 16,
        rows: chord(16, [0, 2, 4, 7]),                 // semitones above root
        harmony: lush(tone: 0.55, cutoff: 2700, reverb: 0.6, reverbType: 2, mod: 0.35)),
    GridPreset(name: "Lush String Swell", scale: 0, root: 0, steps: 16,
        rows: chord(16, [0, 4, 7]),                 // semitones above root
        harmony: lush(rate: 8, gate: 0.98, droneLevel: 0.7, reverb: 0.65, reverbType: 1,
                      ampA: 0.45, ampR: 1.0, mod: 0.3)),
    GridPreset(name: "Minor Triad Pad", scale: 0, root: 4, steps: 16,
        rows: chord(16, [0, 3, 7]),                 // semitones above root
        harmony: lush(tone: 0.38, reverb: 0.58, reverbType: 1)),
    GridPreset(name: "Major 6/9 Glow", scale: 0, root: 0, steps: 16,
        rows: chord(16, [0, 2, 4, 7, 9]),                 // semitones above root
        harmony: lush(tone: 0.52, cutoff: 2600, droneLevel: 0.6, droneInterval: 2,
                      reverb: 0.6, reverbType: 2)),
    GridPreset(name: "Solo Cello Drone", scale: 0, root: 0, steps: 16,
        rows: chord(16, [0, 7]),                 // semitones above root
        harmony: lush(voice: 0, rate: 0, gate: 0.97, tone: 0.34, cutoff: 1900,
                      droneLevel: 0.6, reverb: 0.5, reverbType: 1,
                      ampA: 0.18, ampD: 0.5, ampS: 0.92, ampR: 0.9, mod: 0.15)),
    // long legato notes: D → F → E, then A falling to E
    GridPreset(name: "Adagio Line", scale: 0, root: 2, steps: 32, rows: [
        "x-------........................",
        "................................",
        "............x---............x---",
        "........x---............x---....",
        "................................",
        "......................x-........",
        "................................",
        "................x-----.........."], key: kMinor),
    // plucked G-major walk up the triad and home
    GridPreset(name: "Pizzicato Walk", scale: 0, root: 7, steps: 32, rows: [
        "x.............................x.",
        "................................",
        "........x...................x...",
        "................................",
        "..x...x.........x...............",
        "..........x.....................",
        "................................",
        "....x.........x...x.......x.....",
        "................................",
        "............x...........x.......",
        "................................",
        "......................x.........",
        "....................x..........."], key: kMajor),
    // C – Am – F – G broken chords flowing in 16ths
    GridPreset(name: "Arpeggio Cascade", scale: 0, root: 0, steps: 32, rows: [
        "x.....x.........................",
        "................................",
        "................................",
        "................................",
        ".x...x.x..x...x.................",
        "................x...x...........",
        "................................",
        "..x.x...................x...x...",
        "................................",
        "........x..x.x...x.x.x.x........",
        "................................",
        ".........................x.x.x.x",
        "...x.....x..x..x..x...x.........",
        "................................",
        "..........................x...x."], key: kMajor),
    // falling-thirds sequence, Vivaldi style
    GridPreset(name: "Baroque Sequence", scale: 0, root: 9, steps: 32, rows: [
        "......................x-....x---",
        "................................",
        "..................x-......x-....",
        "..............x-....x-..........",
        "................................",
        "..........x-....x-..............",
        "................................",
        "......x-....x-..........x-......",
        "..x-....x-......................",
        "................................",
        "....x-..........................",
        "................................",
        "x-.............................."], key: kMinor),
    // inner-voice 16th ostinato around the open 5th
    GridPreset(name: "Viola Ostinato", scale: 0, root: 4, steps: 16, rows: [
        "x...x...........",
        "................",
        "........x...x...",
        "..x...x...x....x",
        "................",
        "..............x.",
        "................",
        ".x.x.x.x.x.x.x.."], key: kMinor),
    // lyrical F-major theme: sighing call, soaring answer
    GridPreset(name: "Romance Theme", scale: 0, root: 5, steps: 32, rows: [
        "................................",
        "................................",
        "............x--.................",
        "................................",
        "......x-........x--.............",
        "........x---.......x............",
        "................................",
        "x---.x..............x-......x---",
        "................................",
        "....x.....................x-....",
        "................................",
        "........................x-......",
        "......................x-........"], key: kMajor),
    // measured tremolo: Cm – Fm – Bb – Eb
    GridPreset(name: "Tremolo Chords", scale: 0, root: 0, steps: 32, rows: [
        "xxxxxxxxxxxxxxxx................",
        "................................",
        "................xxxxxxxx........",
        "xxxxxxxx................xxxxxxxx",
        "................................",
        "........xxxxxxxxxxxxxxxx........",
        "................................",
        "xxxxxxxx................xxxxxxxx",
        "........xxxxxxxx................",
        "................................",
        "................xxxxxxxxxxxxxxxx"], key: kMinor),
    // D-dorian air with a lifting 6th and a gentle turn home
    GridPreset(name: "Celtic Air", scale: 7, root: 2, steps: 32, rows: [
        "x-....................x-....x---",
        "........................x-......",
        "..x.....x-...........x....x-....",
        "......x-...........x-...........",
        "...x-x....x-......x.............",
        "................................",
        "................x-..............",
        "............x---................"]),
    // koto-style phrase, high call answered low
    GridPreset(name: "Kyoto Koto", scale: 4, root: 9, steps: 32, rows: [
        "............................x---",
        "................................",
        "....................x--...x.....",
        "............x--...x.....x.......",
        "................x...............",
        "x.........x.....................",
        "..x.....x.......................",
        "....x--........................."]),
    // slow bowed raga line rising to the 5th degree and settling
    GridPreset(name: "Raga Bowed", scale: 3, root: 2, steps: 32, rows: [
        "x---........................x---",
        "..........................x-....",
        "....x-........x-........x-......",
        "......x-....x-......x---........",
        "........x---......x-............",
        "................x-.............."]),
    // bonang-style neighbour pairs on bowed strings
    GridPreset(name: "Gamelan Strings", scale: 4, root: 7, steps: 16, rows: [
        "x...............",
        "..x...........x-",
        ".x..x.......x-..",
        "...x..x...x-....",
        ".....x..x-......",
        ".......x........"]),
    // Reich-like repeating figure, one note changes each half-bar
    GridPreset(name: "Minimal Pulse", scale: 0, root: 1, steps: 16, rows: [
        "x...x...x.......",
        "................",
        "............x...",
        "................",
        ".x.x.x.x.x.x.x.x",
        "................",
        "................",
        "..x.......x.....",
        "................",
        "......x.......x."], key: kMajor),
    // brass-like Bb fanfare: leap up, step down, answer lands on the root
    GridPreset(name: "Heroic Fanfare", scale: 0, root: 10, steps: 32, rows: [
        "x--.........................x---",
        "................................",
        "..........................x-....",
        "................................",
        "........................x-......",
        "...................x............",
        "................................",
        "...x........x--.....x---........",
        "................................",
        "..........x-....x--.............",
        "................................",
        "........x-......................",
        "....x---........................"], key: kMajor),
    // the lament bass: A – G – F – E, then D – C – B – E
    GridPreset(name: "Lament Descent", scale: 0, root: 9, steps: 32, rows: [
        "................................",
        "................................",
        "........................x---....",
        "....................x---........",
        "................................",
        "................x---............",
        "................................",
        "............x---............x---",
        "........x---....................",
        "................................",
        "....x---........................",
        "................................",
        "x---............................"], key: kMinor),
    // bouncing-bow 16ths, C minor drive with a lift to G
    GridPreset(name: "Spiccato Drive", scale: 0, root: 0, steps: 16, rows: [
        "xx.xx.xx........",
        "................",
        "................",
        "........xx.xx...",
        "................",
        "..............x.",
        "................",
        "..x..x.........x",
        "..........x..x.."], key: kMinor),
    // G-major-pent cradle song, falling pairs
    GridPreset(name: "Lullaby", scale: 1, root: 7, steps: 32, rows: [
        ".....................x--....x---",
        "...................x-...x-......",
        ".....x--........x--.......x-....",
        "...x-...x-......................",
        "x--.......x----................."])
]

final class StringThingParameterView: NSView {
    var audioUnit: StringThingAudioUnit? { didSet { needsDisplay = true } }

    private var animTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = faceBg.cgColor
        // GPU-accelerated CG rendering — see EZAudio benchmark.
        layer?.drawsAsynchronously = true
        // Slow heartbeat (~2.5 Hz) — fast enough that the comet visualizer
        // still moves and the playhead doesn't feel frozen, but slow enough
        // that the UI stops "blinking" the way the old 20 Hz redraw did.
        // User explicitly complained the constant repaint felt hectic.
        animTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.needsDisplay = true
        }
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    deinit { animTimer?.invalidate() }

    // MARK: - Layout

    private let pad: CGFloat = 18
    private let brandH: CGFloat = 34     // bottom brand bar
    private let topBarH: CGFloat = 46    // top transport bar (909-style)
    private let linkStripH: CGFloat = 24 // LINK / song-chain row under PATTERN
    private let bottomH: CGFloat = 132   // bottom control + knob strip

    private func topBarRect() -> NSRect {
        return NSRect(x: 0, y: bounds.height - topBarH, width: bounds.width, height: topBarH)
    }
    // LINK / song-chain strip, just under the top bar (under the PATTERN buttons).
    private func linkStripRect() -> NSRect {
        let topY = bounds.height - topBarH
        return NSRect(x: 0, y: topY - linkStripH, width: bounds.width, height: linkStripH)
    }
    // The melodic step-grid is the full-width centerpiece between the transport
    // bar and the bottom control strip (mirroring the Engine 909 layout).
    private func gridRect() -> NSRect {
        let top    = bounds.height - topBarH - linkStripH
        let bottom = brandH + bottomH
        return NSRect(x: pad, y: bottom + 8, width: bounds.width - pad * 2, height: max(150, top - bottom - 16))
    }
    private func bottomBarRect() -> NSRect {
        return NSRect(x: pad, y: brandH + 6, width: bounds.width - pad * 2, height: bottomH)
    }
    private func footerRect() -> NSRect {
        return NSRect(x: 0, y: 0, width: bounds.width, height: brandH)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Subtle brushed-aluminium faceplate over the solid faceBg (keeps the
        // panel colour, adds analogue grain). Sub-panels draw on top.
        FaceTexture.draw(in: bounds, ctx: ctx)
        drawTopBar(ctx, topBarRect())
        drawLinkStrip(ctx, linkStripRect())
        drawKeyGrid(ctx, gridRect())
        drawBottomBar(ctx, bottomBarRect())
        drawFooter(ctx, footerRect())
    }

    /// Comet-field pitch visualizer. Right edge = now; comets drift left over
    /// ~5s. Y = pitch. Held chord notes glow on the right margin as targets;
    /// the background film pulses with the master amplitude. Replaces the
    /// old static orbit dodecagon.
    private func drawOrbit(_ ctx: CGContext, _ r: NSRect) {
        // ── Dark inset panel (inverted twin) ────────────────────────────
        ctx.setFillColor(panelDark.cgColor)
        ctx.fill(r)
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.45).cgColor); ctx.setLineWidth(0.5)
        ctx.stroke(r)

        // ── Pitch range covered by the Y axis ──────────────────────────
        // C2 (36) at the bottom up to C6 (84) — 4 octaves of headroom for
        // arp/sequence content. Pitches outside this range get clamped.
        let pitchMin: Int = 36
        let pitchMax: Int = 84
        func yForPitch(_ midi: Int) -> CGFloat {
            let m = max(pitchMin, min(pitchMax, midi))
            let t = CGFloat(m - pitchMin) / CGFloat(pitchMax - pitchMin)
            return r.minY + 8 + t * (r.height - 16)
        }

        // ── Amplitude-driven background tint ───────────────────────────
        // The whole field pulses subtly red when notes are firing.
        let amp = CGFloat(audioUnit?.amplitudeEnv ?? 0)
        if amp > 0.001 {
            ctx.setFillColor(red.withAlphaComponent(min(0.18, amp * 0.4)).cgColor)
            ctx.fill(r)
        }

        // ── Octave guide lines (faint horizontal) — only these, for context.
        // The per-scale-degree hairlines were removed (de-clutter pass).
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.10).cgColor)
        ctx.setLineWidth(0.5)
        for oct in stride(from: pitchMin, through: pitchMax, by: 12) {
            let y = yForPitch(oct)
            ctx.move(to: NSPoint(x: r.minX + 2, y: y))
            ctx.addLine(to: NSPoint(x: r.maxX - 2, y: y))
        }
        ctx.strokePath()

        // ── Beat-tick markers — vertical lines that scroll left ────────
        // Synced to the BPM so the user gets a visible pulse on every beat.
        let bpm = Double(audioUnit?.bpm ?? 120)
        let secPerBeat = 60.0 / max(20.0, bpm)
        let windowSec = 5.0
        let now = CACurrentMediaTime()
        let beatOffset = now.truncatingRemainder(dividingBy: secPerBeat)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
        ctx.setLineWidth(0.5)
        var beatT = beatOffset
        while beatT < windowSec {
            let x = r.maxX - 8 - CGFloat(beatT / windowSec) * (r.width - 16)
            ctx.move(to: NSPoint(x: x, y: r.minY + 4))
            ctx.addLine(to: NSPoint(x: x, y: r.maxY - 4))
            beatT += secPerBeat
        }
        ctx.strokePath()

        // ── Held chord targets — bright dots on the right margin ───────
        let chordCount = Int(audioUnit?.chordCount ?? 0)
        for i in 0..<chordCount {
            let midi = Int(audioUnit?.chordNote(at: Int32(i)) ?? -1)
            if midi < 0 { continue }
            let y = yForPitch(midi)
            let pulse = 1.0 + 0.3 * CGFloat(sin(now * 4 + Double(i)))
            let dotR: CGFloat = 4 * pulse
            ctx.setFillColor(red.withAlphaComponent(0.85).cgColor)
            ctx.fillEllipse(in: NSRect(x: r.maxX - 6 - dotR, y: y - dotR, width: dotR * 2, height: dotR * 2))
            // Soft outer glow
            ctx.setFillColor(red.withAlphaComponent(0.20).cgColor)
            ctx.fillEllipse(in: NSRect(x: r.maxX - 6 - dotR * 2, y: y - dotR * 2, width: dotR * 4, height: dotR * 4))
        }

        // ── Comets — each recent note is a fading streak ───────────────
        var midis = [Int32](repeating: 0, count: 64)
        var ages  = [Double](repeating: 0, count: 64)
        let count = midis.withUnsafeMutableBufferPointer { mp -> Int in
            ages.withUnsafeMutableBufferPointer { ap in
                Int(audioUnit?.readNoteHistory(mp.baseAddress!, age: ap.baseAddress!, capacity: 64) ?? 0)
            }
        }
        for i in 0..<count {
            let age = ages[i]
            if age > windowSec { break }
            let midi = Int(midis[i])
            let y = yForPitch(midi)
            // X drifts left over the window
            let xRight = r.maxX - 8
            let xLeft  = r.minX + 8
            let xNow = xRight - CGFloat(age / windowSec) * (xRight - xLeft)
            // Tail trails behind the head (older sample positions)
            let tailLen: CGFloat = 50
            let xTail = max(xLeft, xNow - tailLen)
            let fade = 1.0 - min(1.0, age / windowSec)
            let headAlpha = max(0.0, fade) * 0.95
            let tailAlpha = max(0.0, fade) * 0.18

            // Glow halo
            if fade > 0.5 {
                ctx.setFillColor(red.withAlphaComponent(CGFloat(fade) * 0.35).cgColor)
                ctx.fillEllipse(in: NSRect(x: xNow - 9, y: y - 9, width: 18, height: 18))
            }
            // Tail
            let tailGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [red.withAlphaComponent(CGFloat(tailAlpha)).cgColor,
                         red.withAlphaComponent(0.0).cgColor] as CFArray,
                locations: [0, 1])!
            ctx.saveGState()
            let tailRect = NSRect(x: xTail, y: y - 2, width: xNow - xTail, height: 4)
            ctx.clip(to: tailRect)
            ctx.drawLinearGradient(tailGrad,
                                   start: CGPoint(x: xNow, y: y),
                                   end: CGPoint(x: xTail, y: y),
                                   options: [])
            ctx.restoreGState()
            // Head — solid red dot
            ctx.setFillColor(red.withAlphaComponent(CGFloat(headAlpha)).cgColor)
            let hr: CGFloat = 3.5
            ctx.fillEllipse(in: NSRect(x: xNow - hr, y: y - hr, width: hr * 2, height: hr * 2))
        }

        // ── Now-line on the right edge ─────────────────────────────────
        ctx.setStrokeColor(red.withAlphaComponent(0.4).cgColor)
        ctx.setLineWidth(0.8)
        ctx.move(to: NSPoint(x: r.maxX - 4, y: r.minY + 2))
        ctx.addLine(to: NSPoint(x: r.maxX - 4, y: r.maxY - 2))
        ctx.strokePath()

        // ── Header labels: sync indicator + chord count ───────────────
        let synced = audioUnit?.bpmSynced ?? false
        let syncStr = NSString(string: synced ? "● SYNC" : "○ FREE")
        let syncAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 8, weight: .heavy),
            .foregroundColor: synced ? red : NSColor.white.withAlphaComponent(0.45),
            .kern: 0.8
        ]
        syncStr.draw(at: NSPoint(x: r.minX + 8, y: r.maxY - 14), withAttributes: syncAttr)

        let cc = Int(audioUnit?.chordCount ?? 0)
        let ccStr = NSString(string: cc > 0 ? "\(cc) NOTES HELD" : "—")
        let ccAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 8, weight: .heavy),
            .foregroundColor: NSColor.white.withAlphaComponent(0.5),
            .kern: 0.6
        ]
        let ccSz = ccStr.size(withAttributes: ccAttr)
        ccStr.draw(at: NSPoint(x: r.maxX - 8 - ccSz.width, y: r.maxY - 14), withAttributes: ccAttr)
    }

    /// Map a String Thing scale id to a set of pitch-class degrees (0..11)
    /// for the comet-field's in-scale row highlighting.
    private func scaleDegrees(forScaleId id: Int) -> Set<Int> {
        switch id {
        case 0: return Set(0..<12)                  // Chromatic
        case 1: return [0, 2, 4, 7, 9]              // Major pent
        case 2: return [0, 3, 5, 7, 10]             // Minor pent
        case 3: return [0, 3, 5, 6, 7, 10]          // Raga Jog (approx)
        case 4: return [0, 2, 4, 7, 9]              // China pent (approx)
        default: return Set(0..<12)
        }
    }

    /// Big BPM display in the top header bar.
    /// Click + drag to scrub when not synced; click to type a value when synced.
    // ── Top transport bar (Engine-909 style, dark twin) ─────────────────
    private func drawTopBar(_ ctx: CGContext, _ tr: NSRect) {
        guard let au = audioUnit else { return }
        // Bar background + red underline stripe.
        ctx.setFillColor(Palette.wellBg.cgColor); ctx.fill(tr)
        ctx.setFillColor(red.cgColor); ctx.fill(NSRect(x: 0, y: tr.minY, width: tr.width, height: 2))

        let lab: [NSAttributedString.Key: Any]  = [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: inkDark, .kern: 0.8]
        let val: [NSAttributedString.Key: Any]  = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular), .foregroundColor: inkDark]
        let on:  [NSAttributedString.Key: Any]  = [.font: NSFont.systemFont(ofSize: 10, weight: .heavy), .foregroundColor: cream, .kern: 0.6]
        let off: [NSAttributedString.Key: Any]  = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: inkDark, .kern: 0.6]
        let cy = tr.midY
        var x: CGFloat = pad

        func divider() {
            ctx.setStrokeColor(inkMid.withAlphaComponent(0.4).cgColor); ctx.setLineWidth(0.5)
            ctx.move(to: NSPoint(x: x, y: cy - 11)); ctx.addLine(to: NSPoint(x: x, y: cy + 11)); ctx.strokePath()
            x += 14
        }

        // PLAY / STOP / REC removed — playback follows the host transport
        // (Logic's play state drives the sequencer). Rects zeroed so the old
        // hit-tests can never fire.
        playRect = .zero; stopRect = .zero; recRect = .zero

        // BPM
        NSString(string: "BPM").draw(at: NSPoint(x: x, y: cy - 6), withAttributes: lab)
        NSString(string: String(format: "%.0f", au.bpm)).draw(at: NSPoint(x: x + 30, y: cy - 6), withAttributes: val)
        bpmHitRect = NSRect(x: x, y: cy - 11, width: 70, height: 22)
        x += 76
        divider()

        // PATTERN A B C D
        NSString(string: "PATTERN").draw(at: NSPoint(x: x, y: cy - 6), withAttributes: lab)
        x += 56
        slotBtns.removeAll()
        let curSlot = Int(au.currentSlot)
        for (i, L) in ["A","B","C","D"].enumerated() {
            let sq = NSRect(x: x, y: cy - 9, width: 18, height: 18)
            if i == curSlot {
                ctx.setFillColor(red.cgColor); ctx.fill(sq)
                let z = NSString(string: L).size(withAttributes: on)
                NSString(string: L).draw(at: NSPoint(x: sq.midX - z.width/2, y: sq.midY - z.height/2 - 1), withAttributes: on)
            } else {
                ctx.setStrokeColor(inkDark.withAlphaComponent(0.45).cgColor); ctx.setLineWidth(0.7); ctx.stroke(sq)
                let z = NSString(string: L).size(withAttributes: off)
                NSString(string: L).draw(at: NSPoint(x: sq.midX - z.width/2, y: sq.midY - z.height/2 - 1), withAttributes: off)
            }
            slotBtns.append(ButtonRect(rect: sq, tag: i))
            x += 22
        }
        x += 6
        // ISOLATE — loop the pattern on the grid alone; the LINK chain is kept (909).
        isolateRect = NSRect(x: x, y: cy - 10, width: 60, height: 20)
        drawIsolateKey(ctx, isolateRect, on: au.isolate)
        x += 60 + 10
        divider()

        // SWING (drag)
        NSString(string: "SWING").draw(at: NSPoint(x: x, y: cy - 6), withAttributes: lab)
        NSString(string: String(format: "%.0f%%", (au.swing) * 100)).draw(at: NSPoint(x: x + 42, y: cy - 6), withAttributes: val)
        swingHitRect = NSRect(x: x, y: cy - 11, width: 86, height: 22)
        x += 90
        divider()

        // STEPS 16/32/64
        NSString(string: "STEPS").draw(at: NSPoint(x: x, y: cy - 6), withAttributes: lab)
        x += 42
        stepCountBtns.removeAll()
        let curSteps = Int(au.gridSteps)
        for n in [16, 32, 64] {
            let pr = NSRect(x: x, y: cy - 9, width: 30, height: 18)
            if n == curSteps {
                ctx.setFillColor(red.cgColor); ctx.fill(pr)
                let z = NSString(string: "\(n)").size(withAttributes: on)
                NSString(string: "\(n)").draw(at: NSPoint(x: pr.midX - z.width/2, y: pr.midY - z.height/2 - 1), withAttributes: on)
            } else {
                ctx.setStrokeColor(inkDark.withAlphaComponent(0.45).cgColor); ctx.setLineWidth(0.7); ctx.stroke(pr)
                let z = NSString(string: "\(n)").size(withAttributes: off)
                NSString(string: "\(n)").draw(at: NSPoint(x: pr.midX - z.width/2, y: pr.midY - z.height/2 - 1), withAttributes: off)
            }
            stepCountBtns.append(ButtonRect(rect: pr, tag: n))
            x += 33
        }
        x += 6
        divider()

        // RATE (playhead speed) — click to cycle.
        NSString(string: "RATE").draw(at: NSPoint(x: x, y: cy - 6), withAttributes: lab)
        let curRateEng = Int(au.rate)
        let curRateVis = kRateEngineIdx.firstIndex(of: curRateEng) ?? 2
        NSString(string: kRateNames[curRateVis]).draw(at: NSPoint(x: x + 34, y: cy - 6), withAttributes: val)
        rateHitRect = NSRect(x: x, y: cy - 11, width: 72, height: 22)
        x += 78
        divider()

        // PRESET ▾ — red pill, pops the pattern menu.
        let pw: CGFloat = 96
        presetMenuRect = NSRect(x: x, y: cy - 10, width: pw, height: 20)
        ctx.setFillColor(red.cgColor); ctx.fill(presetMenuRect)
        let g = NSString(string: "PRESET ▾")
        let gz = g.size(withAttributes: on)
        g.draw(at: NSPoint(x: presetMenuRect.midX - gz.width*0.5, y: presetMenuRect.midY - gz.height*0.5 - 1), withAttributes: on)
        x += pw + 8

        // RANDOM ✦ — generative pattern button. Outlined (vs filled PRESET) so
        // the two read as siblings but distinct. Builds a fresh Euclidean-rooted
        // groove on every click; stays in the current scale + root.
        let rw: CGFloat = 92
        randomMenuRect = NSRect(x: x, y: cy - 10, width: rw, height: 20)
        ctx.setStrokeColor(red.cgColor); ctx.setLineWidth(1.2); ctx.stroke(randomMenuRect)
        let rOn: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .heavy), .foregroundColor: red, .kern: 0.5]
        let rstr = NSString(string: "RANDOM ✦")
        let rz = rstr.size(withAttributes: rOn)
        rstr.draw(at: NSPoint(x: randomMenuRect.midX - rz.width*0.5, y: randomMenuRect.midY - rz.height*0.5 - 1), withAttributes: rOn)

        // SYNC indicator (far right).
        let synced = au.bpmSynced
        let syncStr = NSString(string: synced ? "● SYNC" : "○ FREE")
        let syncAttr: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 9, weight: .heavy), .foregroundColor: synced ? red : inkMid, .kern: 0.6]
        let sz = syncStr.size(withAttributes: syncAttr)
        syncStr.draw(at: NSPoint(x: tr.maxX - pad - sz.width, y: cy - 6), withAttributes: syncAttr)

        // Undo / redo — to the left of the SYNC indicator.
        let bw: CGFloat = 26, bh: CGFloat = 16, gap: CGFloat = 6
        let rightEdge = tr.maxX - pad - sz.width - 16
        redoBtnRect = NSRect(x: rightEdge - bw, y: cy - bh * 0.5, width: bw, height: bh)
        undoBtnRect = NSRect(x: redoBtnRect.minX - gap - bw, y: cy - bh * 0.5, width: bw, height: bh)
        drawUndoButton(ctx, undoBtnRect, "↶", stUndo.isEmpty)
        drawUndoButton(ctx, redoBtnRect, "↷", stRedo.isEmpty)
        // SAVE / LOAD removed — Logic's built-in plug-in preset bar covers it.
    }

    /// LINK / song-chain strip under the PATTERN buttons. Tap A/B/C/D to append
    /// to the chain; it plays left→right and loops, live entry highlighted.
    private func drawLinkStrip(_ ctx: CGContext, _ strip: NSRect) {
        let cy = strip.midY
        let letters = ["A", "B", "C", "D"]
        // Re-mirror the engine's chain every paint (as SynthThing does): a project
        // reload or host state restore sets it behind the view's back.
        if let au = audioUnit { chainSlotsLocal = au.chainSlots().map { $0.intValue } }
        let chainOn = !chainSlotsLocal.isEmpty
        let pos = Int(audioUnit?.chainPosition ?? 0)
        let isolated = audioUnit?.isolate ?? false
        let playing = (audioUnit?.playing ?? false) && !isolated

        let lab: [NSAttributedString.Key: Any]  = [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: inkDark, .kern: 0.8]
        let onA: [NSAttributedString.Key: Any]  = [.font: NSFont.systemFont(ofSize: 10, weight: .heavy), .foregroundColor: cream]
        let offA: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: inkDark]
        let dim: [NSAttributedString.Key: Any]  = [.font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular), .foregroundColor: inkMid]
        let liveA: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .heavy), .foregroundColor: red]
        let rdA: [NSAttributedString.Key: Any]  = [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold), .foregroundColor: inkDark]

        NSString(string: "LINK").draw(at: NSPoint(x: pad, y: cy - 6), withAttributes: lab)

        linkBtnRects = []
        for i in 0..<4 {
            let w: CGFloat = 18
            let bx: CGFloat = (i < slotBtns.count) ? slotBtns[i].rect.midX - w * 0.5 : pad + 60 + CGFloat(i) * 22
            let r = NSRect(x: bx, y: cy - 8, width: w, height: 16)
            linkBtnRects.append(r)
            let inChain = chainSlotsLocal.contains(i)
            if inChain { ctx.setFillColor(red.withAlphaComponent(0.85).cgColor); ctx.fill(r) }
            else { ctx.setStrokeColor(inkDark.withAlphaComponent(0.5).cgColor); ctx.setLineWidth(0.8); ctx.stroke(r) }
            let a = inChain ? onA : offA
            let s = NSString(string: letters[i]); let sz = s.size(withAttributes: a)
            s.draw(at: NSPoint(x: r.midX - sz.width * 0.5, y: r.midY - sz.height * 0.5 - 1), withAttributes: a)
        }

        var rx = (slotBtns.last?.rect.maxX ?? (pad + 220)) + 22
        if chainOn {
            for (idx, slot) in chainSlotsLocal.enumerated() {
                let isLive = playing && idx == pos
                NSString(string: letters[slot]).draw(at: NSPoint(x: rx, y: cy - 6), withAttributes: isLive ? liveA : rdA)
                rx += 12
                if idx < chainSlotsLocal.count - 1 { NSString(string: "→").draw(at: NSPoint(x: rx - 2, y: cy - 6), withAttributes: dim); rx += 12 }
            }
            rx += 12
            linkClrRect = NSRect(x: rx, y: cy - 8, width: 34, height: 16)
            ctx.setStrokeColor(inkDark.withAlphaComponent(0.55).cgColor); ctx.setLineWidth(0.7); ctx.stroke(linkClrRect)
            let cs = NSString(string: "CLR"); let csz = cs.size(withAttributes: dim)
            cs.draw(at: NSPoint(x: linkClrRect.midX - csz.width * 0.5, y: linkClrRect.midY - 5), withAttributes: dim)
            if isolated {
                NSString(string: "ISOLATE ON · chain paused, kept").draw(at: NSPoint(x: linkClrRect.maxX + 12, y: cy - 6), withAttributes: liveA)
            }
        } else {
            linkClrRect = .zero
            NSString(string: "tap A · B · C · D to chain patterns into a song").draw(at: NSPoint(x: rx, y: cy - 6), withAttributes: dim)
        }
    }

    // MIDI → "C4" style note name (MIDI 60 = C4).
    private func noteName(_ midi: Int) -> String {
        let n = ((midi % 12) + 12) % 12
        let oct = midi / 12 - 1
        return "\(kNoteNames[n])\(oct)"
    }

    // Cached grid geometry so draw + hit-test agree exactly.
    private struct GridGeo {
        let inner: NSRect; let labelW: CGFloat
        let rows: Int; let steps: Int; let cellW: CGFloat; let cellH: CGFloat
        let rowGap: CGFloat; let beatGap: CGFloat; let cellGap: CGFloat
        let swingH: CGFloat
        // x of column c's left edge (with beat-group gaps).
        func cellX(_ c: Int) -> CGFloat {
            var x = inner.minX + labelW
            for i in 0..<c { x += cellW + cellGap; if i % 4 == 3 { x += beatGap - cellGap } }
            return x
        }
        // y of row r's bottom edge — cells sit ABOVE the swing-tick strip.
        func cellY(_ r: Int) -> CGFloat { inner.minY + swingH + CGFloat(r) * (cellH + rowGap) }
        // The per-column swing-tick box (bottom strip).
        func swingRect(_ c: Int) -> NSRect { NSRect(x: cellX(c), y: inner.minY, width: cellW, height: swingH - 3) }
        var cellsTop: CGFloat { cellY(rows - 1) + cellH }
    }
    private func gridGeo(_ r: NSRect) -> GridGeo {
        let inset: CGFloat = 10
        let labelW: CGFloat = 58      // crosshair (drag row) + note name
        let inner = NSRect(x: r.minX + inset, y: r.minY + 12,
                           width: r.width - inset * 2, height: r.height - 30)
        let rows = max(1, Int(audioUnit?.numGridRows ?? 8))
        let steps = max(1, Int(audioUnit?.gridSteps ?? 16))
        // Rubber keys need a bezel gap; it tightens as the grid gets denser.
        let beatGap: CGFloat = steps >= 64 ? 4 : 7
        let cellGap: CGFloat = steps >= 64 ? 1 : (steps >= 32 ? 1.5 : 2.5)
        let rowGap: CGFloat = steps >= 64 ? 1.5 : 2.5
        let swingH: CGFloat = 18
        let numBeatGaps = CGFloat(max(0, steps / 4 - 1))
        let fixedGaps = CGFloat(steps - 1) * cellGap + numBeatGaps * (beatGap - cellGap)
        let cellW = max(5.0, (inner.width - labelW - fixedGaps) / CGFloat(steps))
        let cellH = max(8.0, (inner.height - swingH - rowGap * CGFloat(rows - 1)) / CGFloat(rows))
        return GridGeo(inner: inner, labelW: labelW, rows: rows, steps: steps, cellW: cellW, cellH: cellH,
                       rowGap: rowGap, beatGap: beatGap, cellGap: cellGap, swingH: swingH)
    }

    /// Melodic step-grid — the "Drums machine for keys". 8 note rows × 16 step
    /// columns; lit cells are red (a chord-per-column), playhead column glows,
    /// row labels show the in-scale note name. Inverted dark palette.
    private func drawKeyGrid(_ ctx: CGContext, _ r: NSRect) {
        // Card background + title strip.
        ctx.setFillColor(NSColor(calibratedWhite: 1.0, alpha: 0.06).cgColor); ctx.fill(r)
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.18).cgColor); ctx.setLineWidth(0.5); ctx.stroke(r)
        let slot = Int(audioUnit?.currentSlot ?? 0)
        let slotName = ["A", "B", "C", "D"][max(0, min(3, slot))]
        let half = (audioUnit?.halfTone ?? false) ? " · ♯" : ""
        NSString(string: "KEYS · PATTERN \(slotName)\(half)").draw(at: NSPoint(x: r.minX + 8, y: r.maxY - 14), withAttributes: aTiny)

        guard let au = audioUnit else { return }
        let g = gridGeo(r)
        let curStep = Int(au.currentStep)

        // Playhead column — translucent red band behind the whole column.
        if curStep >= 0 && curStep < g.steps {
            let cx = g.cellX(curStep)
            let bandH = CGFloat(g.rows) * (g.cellH + g.rowGap)
            ctx.setFillColor(red.withAlphaComponent(0.16).cgColor)
            ctx.fill(NSRect(x: cx - 1, y: g.cellY(0) - 1, width: g.cellW + 2, height: bandH))
        }

        let lblAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .bold),
            .foregroundColor: inkDark.withAlphaComponent(0.85)
        ]

        for row in 0..<g.rows {
            let y = g.cellY(row)
            // Row label (note name) — root row gets a brighter tint.
            let midi = Int(au.gridRowMidi(Int32(row)))
            let isRoot = (row % max(1, gridScaleDegreeCount())) == 0
            let nm = NSString(string: noteName(midi))
            let rowLblAttr: [NSAttributedString.Key: Any] = [
                .font: isRoot ? Palette.printFont(10) : Palette.printFont(9.5),
                .foregroundColor: isRoot ? red : inkDark.withAlphaComponent(0.7)
            ]
            let nz = nm.size(withAttributes: rowLblAttr)
            nm.draw(at: NSPoint(x: g.inner.minX + g.labelW - 8 - nz.width, y: y + g.cellH * 0.5 - nz.height * 0.5), withAttributes: rowLblAttr)
            _ = lblAttr
            drawRowCrosshair(ctx, g, row: row, hasNotes: (0..<g.steps).contains { au.cell(atRow: Int32(row), step: Int32($0)) })

            // Notes in this row: start column → length (a long note is ONE key
            // spanning its steps; the covered tail cells are not drawn empty).
            var covered = [Bool](repeating: false, count: g.steps)
            var notes: [(Int, Int)] = []
            for col in 0..<g.steps where au.cell(atRow: Int32(row), step: Int32(col)) {
                let len = max(1, min(Int(au.length(atRow: Int32(row), step: Int32(col))), g.steps - col))
                notes.append((col, len))
                for k in 0..<len { covered[col + k] = true }
            }
            for col in 0..<g.steps where !covered[col] {
                let cell = NSRect(x: g.cellX(col), y: y, width: g.cellW, height: g.cellH)
                if !ButtonTex.drawRubber(ctx, rect: cell, kind: 0) {
                    ctx.setFillColor(NSColor(calibratedWhite: 0.2, alpha: 1).cgColor); ctx.fill(cell)
                }
            }
            for (start, len) in notes {
                let x0 = g.cellX(start), x1 = g.cellX(start + len - 1) + g.cellW
                let key = NSRect(x: x0, y: y, width: x1 - x0, height: g.cellH)
                // Ivory = this plug-in's note colour.
                if !ButtonTex.drawRubber(ctx, rect: key, kind: 2) { ctx.setFillColor(cream.cgColor); ctx.fill(key) }
                // Long notes: a small grip line on the right end (drag to change).
                if len > 1 {
                    ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
                    let gx = key.maxX - max(3, g.cellW * 0.22)
                    ctx.fill(NSRect(x: gx, y: key.minY + g.cellH * 0.3, width: 1.2, height: g.cellH * 0.4))
                }
            }
            for col in 0..<g.steps {
                let x = g.cellX(col)
                let cell = NSRect(x: x, y: y, width: g.cellW, height: g.cellH)
                let on = covered[col]
                // Active-step cells get a red outline.
                if col == curStep {
                    ctx.setStrokeColor(red.withAlphaComponent(on ? 1.0 : 0.7).cgColor); ctx.setLineWidth(1.4); ctx.stroke(cell)
                }
            }
            // Drop target while a row's crosshair is being dragged.
            if rowDropTarget == row {
                let x0 = g.cellX(0) - 3, x1 = g.cellX(g.steps - 1) + g.cellW + 3
                let hr = NSRect(x: x0, y: y - 1.5, width: x1 - x0, height: g.cellH + 3)
                ctx.setFillColor(inkDark.withAlphaComponent(0.10).cgColor); ctx.fill(hr)
                ctx.setStrokeColor(inkDark.withAlphaComponent(0.9).cgColor); ctx.setLineWidth(1.5); ctx.stroke(hr)
            }
        }

        // ── Swing-tick strip — the "4 lateness dots" line, mirroring the
        // Drums machine. One box per column; click to add up to 4 ticks of
        // late-swing (0→4), tinting redder/pinker the later it pushes.
        // 0=on-grid, 1..4 ≈ 54/58/62/66% MPC swing.
        for col in 0..<g.steps {
            let sr = g.swingRect(col)
            let lvl = max(0, min(4, Int(au.colSwing(Int32(col)))))
            // Box background.
            ctx.setFillColor(NSColor(calibratedWhite: 0.16, alpha: 1.0).cgColor); ctx.fill(sr)
            ctx.setStrokeColor(inkDark.withAlphaComponent(0.14).cgColor); ctx.setLineWidth(0.5); ctx.stroke(sr)
            // 4 dots if there's room, else a single proportional fill bar.
            if g.cellW >= 26 {
                let dotR: CGFloat = 2.0
                let slotW = sr.width / 4.0
                for d in 0..<4 {
                    let cxx = sr.minX + slotW * (CGFloat(d) + 0.5)
                    let cyy = sr.midY
                    let lit = d < lvl
                    // Later ticks read pinker/brighter.
                    let dotCol = lit ? red.withAlphaComponent(0.55 + 0.45 * CGFloat(d) / 3.0)
                                     : inkDark.withAlphaComponent(0.22)
                    ctx.setFillColor(dotCol.cgColor)
                    ctx.fillEllipse(in: NSRect(x: cxx - dotR, y: cyy - dotR, width: dotR * 2, height: dotR * 2))
                }
            } else {
                // Narrow (32/64 steps): proportional red fill = swing amount.
                if lvl > 0 {
                    let f = CGFloat(lvl) / 4.0
                    ctx.setFillColor(red.withAlphaComponent(0.30 + 0.55 * f).cgColor)
                    ctx.fill(NSRect(x: sr.minX + 1, y: sr.minY + 1, width: (sr.width - 2) * f, height: sr.height - 2))
                }
            }
        }
    }

    // Number of scale degrees in the current scale (for root-row striping).
    private func gridScaleDegreeCount() -> Int {
        switch Int(audioUnit?.scaleId ?? 0) {
        case 1, 2, 4: return 5       // pentatonics
        case 3:       return 5
        case 5, 6, 7: return 7       // diatonic modes
        default:      return 12      // chromatic
        }
    }

    // ── Per-row drag crosshair (Engine 909 "drag-crosshair per row") ──────
    // Sits in the label column left of the note name. Drag it onto another
    // row = copy this row's notes + lengths there; ⌥ on release = swap.
    private func crosshairRect(_ g: GridGeo, row: Int) -> NSRect {
        NSRect(x: g.inner.minX, y: g.cellY(row), width: 18, height: g.cellH)
    }
    private func drawRowCrosshair(_ ctx: CGContext, _ g: GridGeo, row: Int, hasNotes: Bool) {
        let hr = crosshairRect(g, row: row)
        let hc = NSPoint(x: hr.midX, y: hr.midY)
        let dragging = rowDragSrc == row
        let col = dragging ? red : inkDark.withAlphaComponent(hasNotes ? 0.85 : 0.35)
        ctx.saveGState()
        ctx.setStrokeColor(col.cgColor); ctx.setLineWidth(1.2); ctx.setLineCap(.round)
        let arm: CGFloat = min(6, g.cellH * 0.5 - 1), ring: CGFloat = min(3.2, arm * 0.55)
        ctx.strokeEllipse(in: NSRect(x: hc.x - ring, y: hc.y - ring, width: ring * 2, height: ring * 2))
        ctx.move(to: NSPoint(x: hc.x - arm, y: hc.y)); ctx.addLine(to: NSPoint(x: hc.x - ring - 1, y: hc.y))
        ctx.move(to: NSPoint(x: hc.x + ring + 1, y: hc.y)); ctx.addLine(to: NSPoint(x: hc.x + arm, y: hc.y))
        ctx.move(to: NSPoint(x: hc.x, y: hc.y - arm)); ctx.addLine(to: NSPoint(x: hc.x, y: hc.y - ring - 1))
        ctx.move(to: NSPoint(x: hc.x, y: hc.y + ring + 1)); ctx.addLine(to: NSPoint(x: hc.x, y: hc.y + arm))
        ctx.strokePath()
        ctx.restoreGState()
    }
    /// Grid row under a y position (nil outside the note rows).
    private func gridRowAt(_ y: CGFloat, _ g: GridGeo) -> Int? {
        for r in 0..<g.rows where y >= g.cellY(r) - g.rowGap * 0.5 && y < g.cellY(r) + g.cellH + g.rowGap * 0.5 { return r }
        return nil
    }
    private func drawIsolateKey(_ ctx: CGContext, _ rect: NSRect, on: Bool) {
        if !ButtonTex.draw(ctx, rect: rect, active: on, corner: 4) {
            if on { ctx.setFillColor(red.cgColor); ctx.fill(rect) }
            else  { ctx.setStrokeColor(inkDark.withAlphaComponent(0.7).cgColor); ctx.setLineWidth(0.8); ctx.stroke(rect) }
        }
        let a: [NSAttributedString.Key: Any] = [.font: Palette.printFont(9), .foregroundColor: on ? cream : inkDark, .kern: 0.6]
        let t = NSString(string: "ISOLATE"); let z = t.size(withAttributes: a)
        t.draw(at: NSPoint(x: rect.midX - z.width * 0.5, y: rect.midY - z.height * 0.5), withAttributes: a)
    }

    private struct ButtonRect { let rect: NSRect; let tag: Int }
    private var voiceBtns: [ButtonRect] = []
    private var modeBtns: [ButtonRect] = []
    private var dubBtns:  [ButtonRect] = []   // DUBSTEP wobble pattern cells
    private var dirBtns: [ButtonRect] = []
    private var rateBtns: [ButtonRect] = []
    private var scaleBtns: [ButtonRect] = []
    private var rootBtns: [ButtonRect] = []
    private var octBtns: [ButtonRect] = []
    private var slotBtns: [ButtonRect] = []         // pattern slot A/B/C/D
    private var chainSlotsLocal: [Int] = []         // song chain (mirror of engine)
    private var linkBtnRects: [NSRect] = []         // LINK row A/B/C/D add buttons
    private var linkClrRect: NSRect = .zero
    private var isolateRect: NSRect = .zero          // ISOLATE key on the PATTERN line
    private var rowDragSrc: Int? = nil               // row whose crosshair is being dragged
    private var rowDropTarget: Int? = nil            // row under the pointer while dragging
    private var stepCountBtns: [ButtonRect] = []    // 16 / 32 / 64
    // Transport + dropdown hit rects (new chrome).
    private var playRect: NSRect = .zero
    private var stopRect: NSRect = .zero
    private var recRect: NSRect = .zero
    private var rateHitRect: NSRect = .zero
    private var swingHitRect: NSRect = .zero
    private var presetMenuRect: NSRect = .zero
    private var randomMenuRect: NSRect = .zero       // RANDOM ✦ generative button
    private var voiceMenuRect: NSRect = .zero
    private var scaleMenuRect: NSRect = .zero
    private var rootMenuRect: NSRect = .zero
    private var octaveCycleRect: NSRect = .zero      // grid octave shift
    private var halfToggleRect: NSRect = .zero       // ♯ half-tone switch
    private var clearGridRect: NSRect = .zero        // CLR current slot
    private var droneRect: NSRect = .zero
    private var droneIntervalRect: NSRect = .zero
    private var droneOctaveRect: NSRect = .zero
    private var droneLvlRect: NSRect = .zero
    private var phraseRect: NSRect = .zero
    private var bpmHitRect: NSRect = .zero

    /// Cycles through the 5 preset phrases as user clicks the PHRASE button.
    private var phraseIdx: Int = 0

    private var lvlKnob: NSRect = .zero
    private var toneKnob: NSRect = .zero
    private var cutoffKnob: NSRect = .zero
    private var resoKnob: NSRect = .zero
    private var swingKnob: NSRect = .zero
    private var gateKnob: NSRect = .zero
    // Universal output FX — work for every voice character.
    private var modKnob: NSRect = .zero
    private var dirtKnob: NSRect = .zero
    private var noiseKnob: NSRect = .zero
    private var delayKnob: NSRect = .zero
    private var reverbKnob: NSRect = .zero
    private var chopKnob: NSRect = .zero
    private var delayTypeRect: NSRect = .zero
    private var reverbTypeRect: NSRect = .zero
    private var chopTypeRect: NSRect = .zero


    // Full scale names (engine has 8 scales; the old pill list only had 5).
    private let kScaleFull = ["CHROM","MAJ PENT","MIN PENT","RAGA JOG","CHINA","PHRYG","LOCRIAN","DORIAN"]

    // ── Bottom control strip: dropdowns + toggles + knob bank ────────────
    private func drawBottomBar(_ ctx: CGContext, _ r: NSRect) {
        guard let au = audioUnit else { return }
        ctx.setFillColor(NSColor(calibratedWhite: 1.0, alpha: 0.05).cgColor); ctx.fill(r)
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.16).cgColor); ctx.setLineWidth(0.5); ctx.stroke(r)

        let cap: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 8, weight: .heavy), .foregroundColor: inkMid, .kern: 0.6]
        let valA: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: inkDark, .kern: 0.4]
        let onA: [NSAttributedString.Key: Any]  = [.font: NSFont.systemFont(ofSize: 12, weight: .heavy), .foregroundColor: cream, .kern: 0.4]
        let offA: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: inkDark, .kern: 0.4]

        // Dropdown box helper (caption above, value + ▾ inside).
        func menuBox(_ rect: NSRect, caption: String, value: String) {
            if !ButtonTex.draw(ctx, rect: rect, active: false, corner: 4) {
                ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.10).cgColor); ctx.fill(rect)
                ctx.setStrokeColor(inkDark.withAlphaComponent(0.40).cgColor); ctx.setLineWidth(0.8); ctx.stroke(rect)
            }
            NSString(string: caption).draw(at: NSPoint(x: rect.minX + 1, y: rect.maxY + 4), withAttributes: cap)
            let s = NSString(string: "\(value)  ▾"); let z = s.size(withAttributes: valA)
            s.draw(at: NSPoint(x: rect.minX + 9, y: rect.midY - z.height * 0.5 - 1), withAttributes: valA)
        }
        func toggleBox(_ rect: NSRect, caption: String, text: String, active: Bool) {
            if !ButtonTex.draw(ctx, rect: rect, active: active, corner: 4) {
                if active { ctx.setFillColor(red.cgColor); ctx.fill(rect) }
                else { ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.10).cgColor); ctx.fill(rect)
                       ctx.setStrokeColor(inkDark.withAlphaComponent(0.40).cgColor); ctx.setLineWidth(0.8); ctx.stroke(rect) }
            }
            NSString(string: caption).draw(at: NSPoint(x: rect.minX + 1, y: rect.maxY + 4), withAttributes: cap)
            let s = NSString(string: text); let z = s.size(withAttributes: active ? onA : offA)
            s.draw(at: NSPoint(x: rect.midX - z.width * 0.5, y: rect.midY - z.height * 0.5 - 1), withAttributes: active ? onA : offA)
        }

        // ── Row of dropdowns + toggles (top of panel) ──
        let rowY = r.maxY - 38
        let boxH: CGFloat = 26
        var x = r.minX + 12
        voiceMenuRect = NSRect(x: x, y: rowY, width: 116, height: boxH)
        menuBox(voiceMenuRect, caption: "VOICE", value: kVoiceNames[max(0, min(kVoiceNames.count - 1, Int(au.voiceMode)))])
        x += 116 + 14
        scaleMenuRect = NSRect(x: x, y: rowY, width: 116, height: boxH)
        menuBox(scaleMenuRect, caption: "SCALE", value: kScaleFull[max(0, min(kScaleFull.count - 1, Int(au.scaleId)))])
        x += 116 + 14
        rootMenuRect = NSRect(x: x, y: rowY, width: 64, height: boxH)
        menuBox(rootMenuRect, caption: "ROOT", value: kNoteNames[max(0, min(11, Int(au.rootKey)))])
        x += 64 + 14
        octaveCycleRect = NSRect(x: x, y: rowY, width: 64, height: boxH)
        let go = Int(au.gridOctave)
        toggleBox(octaveCycleRect, caption: "OCTAVE", text: go == 0 ? "0" : String(format: "%+d", go), active: false)
        x += 64 + 10
        halfToggleRect = NSRect(x: x, y: rowY, width: 40, height: boxH)
        toggleBox(halfToggleRect, caption: "HALF", text: "♯", active: au.halfTone)
        x += 40 + 10
        droneRect = NSRect(x: x, y: rowY, width: 64, height: boxH)
        toggleBox(droneRect, caption: "DRONE", text: au.droneOn ? "ON" : "OFF", active: au.droneOn)
        x += 64 + 10
        clearGridRect = NSRect(x: x, y: rowY, width: 48, height: boxH)
        toggleBox(clearGridRect, caption: "GRID", text: "CLR", active: false)

        // ── Knob bank — 11 evenly-spaced knobs across the panel bottom ──
        // Knobs raised a touch and scaled +15% per feedback.
        let knobR: CGFloat = 24
        let ky = r.minY + 46
        let n = 11
        let span = r.width - 24
        func kc(_ i: Int) -> NSPoint { NSPoint(x: r.minX + 12 + span * (CGFloat(i) + 0.5) / CGFloat(n), y: ky) }
        func box(_ c: NSPoint) -> NSRect { NSRect(x: c.x - knobR - 3, y: c.y - knobR - 1, width: knobR * 2 + 6, height: knobR * 2 + 2) }

        let c0 = kc(0); lvlKnob = box(c0)
        let lvlNorm = CGFloat(min(2.0, max(0.0, Double(au.level))) / 2.0)
        drawBigKnob(ctx, center: c0, radius: knobR, normalized: lvlNorm, body: NSColor.white, pointer: red, label: "LVL")
        let c1 = kc(1); toneKnob = box(c1)
        drawBigKnob(ctx, center: c1, radius: knobR, normalized: CGFloat(au.tone), body: Palette.knobBody, pointer: red, label: "TONE")
        let c2 = kc(2); cutoffKnob = box(c2)
        let cutNorm = CGFloat(log2(max(20.0, Double(au.cutoffHz)) / 20.0) / log2(20000.0 / 20.0))
        drawBigKnob(ctx, center: c2, radius: knobR, normalized: cutNorm, body: red, pointer: NSColor.white, label: "CUT")
        let c3 = kc(3); resoKnob = box(c3)
        drawBigKnob(ctx, center: c3, radius: knobR, normalized: CGFloat(au.resonance) / 4.0, body: Palette.knobBody, pointer: red, label: "RES")
        let c4 = kc(4); modKnob = box(c4)
        drawBigKnob(ctx, center: c4, radius: knobR, normalized: CGFloat(au.mod), body: Palette.knobBody, pointer: red, label: "MOD")
        let c5 = kc(5); dirtKnob = box(c5)
        drawBigKnob(ctx, center: c5, radius: knobR, normalized: CGFloat(au.dirt), body: Palette.knobBody, pointer: red, label: "DIRT")
        let c6 = kc(6); noiseKnob = box(c6)
        drawBigKnob(ctx, center: c6, radius: knobR, normalized: CGFloat(au.noise), body: Palette.knobBody, pointer: red, label: "NOISE")
        let c7 = kc(7); gateKnob = box(c7)
        drawBigKnob(ctx, center: c7, radius: knobR, normalized: CGFloat(au.gate), body: Palette.knobBody, pointer: red, label: "GATE")
        let c8 = kc(8); delayKnob = box(c8)
        drawBigKnob(ctx, center: c8, radius: knobR, normalized: CGFloat(au.delayFx), body: Palette.knobBody, pointer: red, label: "DELAY")
        let c9 = kc(9); reverbKnob = box(c9)
        drawBigKnob(ctx, center: c9, radius: knobR, normalized: CGFloat(au.reverbFx), body: Palette.knobBody, pointer: red, label: "REVERB")
        let c10 = kc(10); chopKnob = box(c10)
        drawBigKnob(ctx, center: c10, radius: knobR, normalized: CGFloat(au.chop), body: Palette.knobBody, pointer: red, label: "CHOP")

        // ── Type selectors above the 3 FX knobs (click to cycle) ──
        func typeSel(_ centerX: CGFloat, _ value: String) -> NSRect {
            let w: CGFloat = 50, h: CGFloat = 16
            let rect = NSRect(x: centerX - w * 0.5, y: ky + knobR + 9, width: w, height: h)
            ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.10).cgColor); ctx.fill(rect)
            ctx.setStrokeColor(inkDark.withAlphaComponent(0.4).cgColor); ctx.setLineWidth(0.7); ctx.stroke(rect)
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 9, weight: .heavy), .foregroundColor: red, .kern: 0.4]
            let s = NSString(string: value); let z = s.size(withAttributes: a)
            s.draw(at: NSPoint(x: rect.midX - z.width * 0.5, y: rect.midY - z.height * 0.5 - 1), withAttributes: a)
            return rect
        }
        delayTypeRect  = typeSel(c8.x,  kDelayTypes[max(0, min(kDelayTypes.count - 1, Int(au.delayType)))])
        reverbTypeRect = typeSel(c9.x,  kReverbTypes[max(0, min(kReverbTypes.count - 1, Int(au.reverbType)))])
        chopTypeRect   = typeSel(c10.x, kChopTypes[max(0, min(kChopTypes.count - 1, Int(au.chopType)))])
    }

    private func drawFooter(_ ctx: CGContext, _ r: NSRect) {
        // Suite-standard footer (DESIGN.md §2) via the shared BrandStrip helper:
        // 30 pt logo centred on "PARADISE AUDIO" / "STRING THING — STR-1".
        BrandStrip.drawFooter(ctx: ctx, bounds: bounds, plugin: "STRING THING", code: "STR-1",
                              spec: "AU v3 · INSTRUMENT · STRINGS", pad: 16)
    }

    private func drawBigKnob(_ ctx: CGContext, center c: NSPoint, radius r: CGFloat, normalized n: CGFloat,
                             body: NSColor, pointer: NSColor, label: String) {
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.65).cgColor); ctx.setLineWidth(0.7)
        let s: CGFloat = .pi * 1.25, e: CGFloat = -.pi * 0.25
        let hashCount = 14
        for i in 0..<hashCount {
            let f = CGFloat(i) / CGFloat(hashCount - 1)
            let a = s - f * (s - e)
            let p1 = NSPoint(x: c.x + cos(a) * (r + 1), y: c.y + sin(a) * (r + 1))
            let p2 = NSPoint(x: c.x + cos(a) * (r + 4), y: c.y + sin(a) * (r + 4))
            ctx.move(to: p1); ctx.addLine(to: p2)
        }
        ctx.strokePath()
        let bodyR = NSRect(x: c.x - r, y: c.y - r, width: r*2, height: r*2)
        // Blender knob body by colour ROLE (red → accent, white → output, rest dark),
        // painted pointer line — one moulded knob, no separate cap (analog scheme).
        let rgb = body.usingColorSpace(.deviceRGB)
        let style: KnobStyle = ((rgb?.redComponent ?? 0) > 0.5 && (rgb?.greenComponent ?? 0) < 0.45) ? .anodizedRed
                             : ((rgb?.brightnessComponent ?? 0) > 0.5 ? .ivory : .gunmetal)
        if !KnobTex.draw(ctx, center: c, radius: r, image: style) {
            ctx.setFillColor(body.cgColor); ctx.fillEllipse(in: bodyR)
        }
        _ = pointer
        let ang = s - n * (s - e)
        let p1 = NSPoint(x: c.x + cos(ang) * (r * 0.30), y: c.y + sin(ang) * (r * 0.30))
        let p2 = NSPoint(x: c.x + cos(ang) * (r * 0.80), y: c.y + sin(ang) * (r * 0.80))
        ctx.setStrokeColor(KnobSkin.pointerColor(for: style).cgColor); ctx.setLineWidth(max(2.0, r * 0.12)); ctx.setLineCap(.round)
        ctx.move(to: p1); ctx.addLine(to: p2); ctx.strokePath()
        let ls = NSString(string: label)
        let lsz = ls.size(withAttributes: aTiny)
        ls.draw(at: NSPoint(x: c.x - lsz.width * 0.5, y: c.y - r - 10), withAttributes: aTiny)
    }

    // MARK: - Interaction

    private enum Drag { case none, cutoff, reso, tone, swing, gate, bpm, step(Int), paint(Bool), noteLen(Int, Int), rowDrag(Int), lvl, droneLvl, mod, dirt, noise, delay, reverb, chop }
    // Note-length drag: did this gesture create the note / move off its first column?
    private var noteDragCreated = false
    private var noteDragMoved = false
    private var noteDragDownCol = 0
    // FUSE: the row as it was when the length drag began (start flag + length
    // per step). Every drag update rebuilds the row from it, so notes the
    // dragged note passes over vanish, and come back when you shrink again.
    private var noteDragRowSnap: [(Bool, Int)] = []
    private var drag: Drag = .none
    private var dragStartY: CGFloat = 0
    private var dragStartV: Float = 0

    // MARK: - Undo / Redo (10-step full-state snapshot)
    //
    // StringThing drives the DSP through direct properties + the step grid (its
    // AUParameterTree is empty), so undo is a full-state snapshot of the synth
    // params + the current slot's grid, captured before each edit gesture and
    // restored on undo — same model as the Drums machine.
    private struct STSnapshot: Equatable {
        var grid: [Bool]; var lens: [Int16]; var colSwing: [Int16]
        var gridSteps: Int32; var slot: Int32; var gridOctave: Int32; var halfTone: Bool
        var bpm: Float; var mode: Int32; var direction: Int32; var rate: Int32; var octaveRange: Int32
        var gate: Float; var swing: Float; var scaleId: Int32; var rootKey: Int32
        var droneOn: Bool; var droneLevel: Float; var droneOctave: Int32; var droneInterval: Int32
        var level: Float; var mod: Float; var dirt: Float; var noise: Float
        var delayFx: Float; var reverbFx: Float; var chop: Float
        var delayType: Int32; var reverbType: Int32; var chopType: Int32
        var mixSaw: Float; var mixSquare: Float; var mixSub: Float
        var tone: Float; var cutoffHz: Float; var resonance: Float; var filterEnvAmount: Float
        var ampA: Float; var ampD: Float; var ampS: Float; var ampR: Float
        var fltA: Float; var fltD: Float; var fltS: Float; var fltR: Float
        var voiceMode: Int32
    }
    private var stUndo: [STSnapshot] = []
    private var stRedo: [STSnapshot] = []
    private var stPending: STSnapshot? = nil
    private let stLimit = 10
    private var undoBtnRect: NSRect = .zero
    private var redoBtnRect: NSRect = .zero
    private var saveBtnRect: NSRect = .zero
    private var loadBtnRect: NSRect = .zero

    private func stCapture() -> STSnapshot? {
        guard let au = audioUnit else { return nil }
        let rows = Int(au.numGridRows), steps = Int(au.gridSteps)
        var grid = [Bool](); grid.reserveCapacity(rows * steps)
        var cs = [Int16](); cs.reserveCapacity(steps)
        var lens = [Int16](); lens.reserveCapacity(rows * steps)
        for r in 0..<rows { for s in 0..<steps {
            grid.append(au.cell(atRow: Int32(r), step: Int32(s)))
            lens.append(Int16(au.length(atRow: Int32(r), step: Int32(s))))
        } }
        for s in 0..<steps { cs.append(Int16(au.colSwing(Int32(s)))) }
        return STSnapshot(grid: grid, lens: lens, colSwing: cs,
            gridSteps: au.gridSteps, slot: au.currentSlot, gridOctave: au.gridOctave, halfTone: au.halfTone,
            bpm: au.bpm, mode: au.mode, direction: au.direction, rate: au.rate, octaveRange: au.octaveRange,
            gate: au.gate, swing: au.swing, scaleId: au.scaleId, rootKey: au.rootKey,
            droneOn: au.droneOn, droneLevel: au.droneLevel, droneOctave: au.droneOctave, droneInterval: au.droneInterval,
            level: au.level, mod: au.mod, dirt: au.dirt, noise: au.noise,
            delayFx: au.delayFx, reverbFx: au.reverbFx, chop: au.chop,
            delayType: au.delayType, reverbType: au.reverbType, chopType: au.chopType,
            mixSaw: au.mixSaw, mixSquare: au.mixSquare, mixSub: au.mixSub,
            tone: au.tone, cutoffHz: au.cutoffHz, resonance: au.resonance, filterEnvAmount: au.filterEnvAmount,
            ampA: au.ampA, ampD: au.ampD, ampS: au.ampS, ampR: au.ampR,
            fltA: au.fltA, fltD: au.fltD, fltS: au.fltS, fltR: au.fltR, voiceMode: au.voiceMode)
    }

    private func stApply(_ s: STSnapshot) {
        guard let au = audioUnit else { return }
        au.gridSteps = s.gridSteps; au.currentSlot = s.slot; au.gridOctave = s.gridOctave; au.halfTone = s.halfTone
        au.bpm = s.bpm; au.mode = s.mode; au.direction = s.direction; au.rate = s.rate; au.octaveRange = s.octaveRange
        au.gate = s.gate; au.swing = s.swing; au.scaleId = s.scaleId; au.rootKey = s.rootKey
        au.droneOn = s.droneOn; au.droneLevel = s.droneLevel; au.droneOctave = s.droneOctave; au.droneInterval = s.droneInterval
        au.level = s.level; au.mod = s.mod; au.dirt = s.dirt; au.noise = s.noise
        au.delayFx = s.delayFx; au.reverbFx = s.reverbFx; au.chop = s.chop
        au.delayType = s.delayType; au.reverbType = s.reverbType; au.chopType = s.chopType
        au.mixSaw = s.mixSaw; au.mixSquare = s.mixSquare; au.mixSub = s.mixSub
        au.tone = s.tone; au.cutoffHz = s.cutoffHz; au.resonance = s.resonance; au.filterEnvAmount = s.filterEnvAmount
        au.ampA = s.ampA; au.ampD = s.ampD; au.ampS = s.ampS; au.ampR = s.ampR
        au.fltA = s.fltA; au.fltD = s.fltD; au.fltS = s.fltS; au.fltR = s.fltR
        au.voiceMode = s.voiceMode
        let rows = Int(au.numGridRows), steps = Int(s.gridSteps)
        for r in 0..<rows { for c in 0..<steps {
            let idx = r * steps + c
            if idx < s.grid.count { au.setCellAtRow(Int32(r), step: Int32(c), on: s.grid[idx]) }
            if idx < s.lens.count && idx < s.grid.count && s.grid[idx] { au.setLength(Int32(s.lens[idx]), atRow: Int32(r), step: Int32(c)) }
        } }
        for c in 0..<steps where c < s.colSwing.count { au.setColSwing(Int32(c), level: Int32(s.colSwing[c])) }
        needsDisplay = true
    }

    private func stBegin() { if stPending == nil { stPending = stCapture() } }
    private func stCommit() {
        guard let pre = stPending else { return }
        stPending = nil
        guard let now = stCapture() else { return }
        if now != pre {
            stUndo.append(pre); if stUndo.count > stLimit { stUndo.removeFirst() }
            stRedo.removeAll(); needsDisplay = true
        }
    }
    private func stPerformUndo() { guard let pre = stUndo.popLast(), let now = stCapture() else { return }; stRedo.append(now); stApply(pre) }
    private func stPerformRedo() { guard let nx = stRedo.popLast(), let now = stCapture() else { return }; stUndo.append(now); stApply(nx) }

    // MARK: - Named SAVE / LOAD presets (on disk, reusable in any project)

    private func presentSavePreset() {
        guard let au = audioUnit else { return }
        let alert = NSAlert()
        alert.messageText = "Save Preset"
        alert.informativeText = "Name this patch + pattern. It'll be available in any project."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = "My Patch"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            PresetStore.save("StringThing", name: field.stringValue, data: au.stateData())
        }
    }

    private func presentLoadPreset() {
        let names = PresetStore.list("StringThing")
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
        menu.popUp(positioning: nil, at: NSPoint(x: loadBtnRect.minX, y: loadBtnRect.minY), in: self)
    }

    @objc private func loadPresetPicked(_ sender: NSMenuItem) {
        guard let au = audioUnit, let data = PresetStore.load("StringThing", name: sender.title) else { return }
        au.loadStateData(data)
        chainSlotsLocal = au.chainSlots().map { $0.intValue }
        stUndo.removeAll(); stRedo.removeAll(); stPending = nil
        needsDisplay = true
    }

    private func drawUndoButton(_ ctx: CGContext, _ r: NSRect, _ label: String, _ disabled: Bool) {
        let col = disabled ? inkMid.withAlphaComponent(0.4) : inkDark
        ctx.setStrokeColor(col.withAlphaComponent(0.7).cgColor); ctx.setLineWidth(0.8); ctx.stroke(r)
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: col]
        let s = NSString(string: label); let sz = s.size(withAttributes: a)
        s.draw(at: NSPoint(x: r.midX - sz.width * 0.5, y: r.midY - sz.height * 0.5 - 0.5), withAttributes: a)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let au = audioUnit else { return }

        // ── UNDO / REDO (not undoable themselves) ──
        if undoBtnRect.contains(p) { stPerformUndo(); needsDisplay = true; return }
        if redoBtnRect.contains(p) { stPerformRedo(); needsDisplay = true; return }
        stBegin()

        // ── Top transport bar (PLAY / STOP / REC removed — host-driven) ──
        if bpmHitRect.contains(p) {
            if event.clickCount == 2 { presentBPMTypeInput(); return }
            dragStartY = p.y; dragStartV = au.bpm; drag = .bpm; return
        }
        // LINK strip — build / clear the song chain.
        for (i, r) in linkBtnRects.enumerated() where r.contains(p) {
            if chainSlotsLocal.count < 32 { chainSlotsLocal.append(i) }
            au.setChainSlots(chainSlotsLocal.map { NSNumber(value: $0) })
            needsDisplay = true; return
        }
        if !chainSlotsLocal.isEmpty && linkClrRect.contains(p) {
            chainSlotsLocal.removeAll(); au.clearChain(); needsDisplay = true; return
        }
        if isolateRect.contains(p) { au.isolate = !au.isolate; needsDisplay = true; return }
        for b in slotBtns where b.rect.contains(p) {
            // ⇧-click stamps the CURRENT pattern into the target slot before
            // switching to it ("save current pattern to A/B/C/D"); plain click
            // just switches.
            if event.modifierFlags.contains(.shift) { au.copyPattern(toSlot: Int32(b.tag)) }
            au.currentSlot = Int32(b.tag); needsDisplay = true; return
        }
        if swingHitRect.contains(p) { dragStartY = p.y; dragStartV = au.swing; drag = .swing; return }
        for b in stepCountBtns where b.rect.contains(p) { au.gridSteps = Int32(b.tag); needsDisplay = true; return }
        if rateHitRect.contains(p) {
            let cur = Int(au.rate)
            let vis = kRateEngineIdx.firstIndex(of: cur) ?? 2
            au.rate = Int32(kRateEngineIdx[(vis + 1) % kRateEngineIdx.count]); needsDisplay = true; return
        }
        if presetMenuRect.contains(p) { presentPresetMenu(anchor: NSPoint(x: presetMenuRect.minX, y: presetMenuRect.minY)); return }
        if randomMenuRect.contains(p) { randomizePattern(); needsDisplay = true; return }

        // ── Bottom strip: dropdowns + toggles ──
        if voiceMenuRect.contains(p) { presentVoiceMenu(anchor: NSPoint(x: voiceMenuRect.minX, y: voiceMenuRect.minY)); return }
        if scaleMenuRect.contains(p) { presentScaleMenu(anchor: NSPoint(x: scaleMenuRect.minX, y: scaleMenuRect.minY)); return }
        if rootMenuRect.contains(p)  { presentRootMenu(anchor: NSPoint(x: rootMenuRect.minX, y: rootMenuRect.minY)); return }
        if octaveCycleRect.contains(p) {
            let cur = Int(au.gridOctave)
            au.gridOctave = Int32(cur >= 2 ? -2 : cur + 1); needsDisplay = true; return
        }
        if halfToggleRect.contains(p) { au.halfTone = !au.halfTone; needsDisplay = true; return }
        if droneRect.contains(p)      { au.droneOn = !au.droneOn; needsDisplay = true; return }
        if clearGridRect.contains(p)  { au.clearGrid(); needsDisplay = true; return }

        // ── FX type selectors (cycle) ──
        if delayTypeRect.contains(p)  { au.delayType  = Int32((Int(au.delayType)  + 1) % kDelayTypes.count);  needsDisplay = true; return }
        if reverbTypeRect.contains(p) { au.reverbType = Int32((Int(au.reverbType) + 1) % kReverbTypes.count); needsDisplay = true; return }
        if chopTypeRect.contains(p)   { au.chopType   = Int32((Int(au.chopType)   + 1) % kChopTypes.count);   needsDisplay = true; return }

        // ── Knob bank ──
        if lvlKnob.contains(p) {
            if event.clickCount == 2 { au.level = 1.0; needsDisplay = true; return }
            drag = .lvl; dragStartY = p.y; dragStartV = au.level; return
        }
        if cutoffKnob.contains(p) { drag = .cutoff; dragStartY = p.y; dragStartV = au.cutoffHz; return }
        if resoKnob.contains(p)   { drag = .reso;   dragStartY = p.y; dragStartV = au.resonance; return }
        if toneKnob.contains(p)   { drag = .tone;   dragStartY = p.y; dragStartV = au.tone; return }
        if gateKnob.contains(p)   { drag = .gate;   dragStartY = p.y; dragStartV = au.gate; return }
        if modKnob.contains(p)    { drag = .mod;    dragStartY = p.y; dragStartV = au.mod; return }
        if dirtKnob.contains(p)   { drag = .dirt;   dragStartY = p.y; dragStartV = au.dirt; return }
        if noiseKnob.contains(p)  { drag = .noise;  dragStartY = p.y; dragStartV = au.noise; return }
        if delayKnob.contains(p)  { drag = .delay;  dragStartY = p.y; dragStartV = au.delayFx; return }
        if reverbKnob.contains(p) { drag = .reverb; dragStartY = p.y; dragStartV = au.reverbFx; return }
        if chopKnob.contains(p)   { drag = .chop;   dragStartY = p.y; dragStartV = au.chop; return }

        let g = gridGeo(gridRect())
        // Row crosshair — start a row drag (drop = copy, ⌥ = swap).
        for row in 0..<g.rows where crosshairRect(g, row: row).insetBy(dx: -2, dy: 0).contains(p) {
            drag = .rowDrag(row); rowDragSrc = row; rowDropTarget = nil
            NSCursor.closedHand.push()
            needsDisplay = true; return
        }
        // Swing-tick strip — click a column's box to cycle its late-swing 0→4.
        for col in 0..<g.steps {
            if g.swingRect(col).contains(p) {
                let cur = Int(au.colSwing(Int32(col)))
                au.setColSwing(Int32(col), level: Int32((cur + 1) % 5))
                needsDisplay = true; return
            }
        }
        // Keyboard step-grid. Click an empty cell = new note; DRAG RIGHT = make it
        // longer (one tied note). Click a note without dragging = delete it;
        // drag on a note = change its length. ⌥-drag = the old paint/erase swipe.
        if let (row, col) = gridCellAt(p, g) {
            if event.modifierFlags.contains(.option) {
                let newOn = !(noteCovering(row, col) != nil)
                if newOn { placeNote(row, col, 1) } else if let n = noteCovering(row, col) { au.setCellAtRow(Int32(row), step: Int32(n.0), on: false) }
                drag = .paint(newOn)
            } else if let n = noteCovering(row, col) {
                drag = .noteLen(row, n.0); noteDragCreated = false
            } else {
                placeNote(row, col, 1)
                drag = .noteLen(row, col); noteDragCreated = true
            }
            noteDragMoved = false; noteDragDownCol = col
            if case .noteLen = drag {
                noteDragRowSnap = (0..<64).map { c in
                    let on = au.cell(atRow: Int32(row), step: Int32(c))
                    return (on, on ? Int(au.length(atRow: Int32(row), step: Int32(c))) : 0)
                }
            }
            needsDisplay = true
            return
        }
    }

    // ── Note-length helpers ──────────────────────────────────────────
    /// The note (start, length) whose span covers row/col, if any.
    private func noteCovering(_ row: Int, _ col: Int) -> (Int, Int)? {
        guard let au = audioUnit else { return nil }
        var s = col
        while s >= 0 {
            if au.cell(atRow: Int32(row), step: Int32(s)) {
                let len = max(1, Int(au.length(atRow: Int32(row), step: Int32(s))))
                return (s + len - 1 >= col) ? (s, len) : nil
            }
            s -= 1
        }
        return nil
    }
    /// Longest length a note at `start` may have before it hits the next note
    /// in the row or the end of the grid.
    private func maxLength(_ row: Int, _ start: Int) -> Int {
        guard let au = audioUnit else { return 1 }
        let steps = Int(au.gridSteps)
        var k = 1
        while start + k < steps && !au.cell(atRow: Int32(row), step: Int32(start + k)) { k += 1 }
        return k
    }
    /// Put a note at row/start; an earlier note that ran over this cell is cut short.
    private func placeNote(_ row: Int, _ start: Int, _ len: Int) {
        guard let au = audioUnit else { return }
        if let prev = noteCovering(row, start), prev.0 < start {
            au.setLength(Int32(start - prev.0), atRow: Int32(row), step: Int32(prev.0))
        }
        au.setCellAtRow(Int32(row), step: Int32(start), on: true)
        au.setLength(Int32(max(1, min(len, maxLength(row, start)))), atRow: Int32(row), step: Int32(start))
    }
    /// FUSE on drag: rebuild the row right of `start` from the drag-start
    /// snapshot, minus every note that starts inside the dragged span
    /// (start+1 … start+len-1) — those are consumed by the dragged note. Only
    /// cells that actually change are written, so nothing re-triggers.
    private func fuseRow(_ row: Int, start: Int, len: Int) {
        guard let au = audioUnit, noteDragRowSnap.count == 64 else {
            audioUnit?.setLength(Int32(len), atRow: Int32(row), step: Int32(start)); return
        }
        let end = start + len            // first step after the dragged note
        for c in (start + 1)..<64 {
            var (on, l) = noteDragRowSnap[c]
            if c < end { on = false }    // swallowed
            let cur = au.cell(atRow: Int32(row), step: Int32(c))
            if cur != on { au.setCellAtRow(Int32(row), step: Int32(c), on: on) }
            if on && Int(au.length(atRow: Int32(row), step: Int32(c))) != l { au.setLength(Int32(max(1, l)), atRow: Int32(row), step: Int32(c)) }
        }
        au.setLength(Int32(len), atRow: Int32(row), step: Int32(start))
    }
    /// Column under an x position (nearest column, clamped) — for length drags
    /// that wander off the row vertically.
    private func gridColAt(_ x: CGFloat, _ g: GridGeo) -> Int {
        var best = 0
        for c in 0..<g.steps where x >= g.cellX(c) { best = c }
        return best
    }

    // Hit-test a point against the grid; returns (row, col) or nil.
    private func gridCellAt(_ p: NSPoint, _ g: GridGeo) -> (Int, Int)? {
        // Row from y (row 0 at bottom, above the swing strip).
        guard p.y >= g.cellY(0) && p.y <= g.cellsTop else { return nil }
        var row = -1
        for r in 0..<g.rows {
            let y = g.cellY(r)
            if p.y >= y && p.y < y + g.cellH { row = r; break }
        }
        if row < 0 { return nil }
        // Column from x (account for beat-group gaps).
        var col = -1
        for c in 0..<g.steps {
            let x = g.cellX(c)
            if p.x >= x && p.x < x + g.cellW { col = c; break }
        }
        if col < 0 { return nil }
        return (row, col)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let au = audioUnit else { return }
        let p = convert(event.locationInWindow, from: nil)
        let dy = Float(p.y - dragStartY)
        let fine = event.modifierFlags.contains(.option)
        switch drag {
        case .none: return
        case .cutoff:
            // Exponential drag — fast through the range
            let mult = exp(Double(dy) * (fine ? 0.005 : 0.02))
            au.cutoffHz = Float(min(20000.0, max(20.0, Double(dragStartV) * mult)))
        case .reso:
            au.resonance = max(0, min(4.0, dragStartV + dy * (fine ? 0.002 : 0.012)))
        case .tone:
            au.tone = max(0, min(1, dragStartV + dy * (fine ? 0.001 : 0.005)))
        case .swing:
            au.swing = max(0, min(0.5, dragStartV + dy * (fine ? 0.0005 : 0.002)))
        case .gate:
            au.gate = max(0.05, min(1.0, dragStartV + dy * (fine ? 0.001 : 0.005)))
        case .bpm:
            au.bpm = max(40.0, min(220.0, dragStartV + dy * (fine ? 0.1 : 0.5)))
        case .step(let i):
            let newSemi = Int(max(-12, min(12, dragStartV + dy * (fine ? 0.05 : 0.2))))
            au.setStep(Int32(i), on: true, semi: Int32(newSemi), oct: Int32(au.stepOct(Int32(i))))
        case .paint(let on):
            // ⌥-drag: paint/erase single-step notes as the cursor moves.
            let g = gridGeo(gridRect())
            if let (row, col) = gridCellAt(p, g) {
                if on { if noteCovering(row, col) == nil { placeNote(row, col, 1) } }
                else if let n = noteCovering(row, col) { au.setCellAtRow(Int32(row), step: Int32(n.0), on: false) }
            }
        case .noteLen(let row, let start):
            // Drag right = longer, left = shorter (min one step), up to the end
            // of the grid. FUSE: notes the drag passes over are swallowed by
            // the dragged note; shrinking back in the same drag restores them.
            let g = gridGeo(gridRect())
            let col = gridColAt(p.x, g)
            if col != noteDragDownCol { noteDragMoved = true }
            let len = max(1, min(col - start + 1, g.steps - start))
            fuseRow(row, start: start, len: len)
        case .rowDrag(let src):
            let g = gridGeo(gridRect())
            var target: Int? = nil
            if let r = gridRowAt(p.y, g), r != src { target = r }
            if target != rowDropTarget { rowDropTarget = target }
        case .lvl:
            // Master output level (0..2). Unity = 1.0.
            au.level = max(0, min(2.0, dragStartV + dy * (fine ? 0.002 : 0.008)))
        case .droneLvl:
            // Drone mix (0..1.5)
            au.droneLevel = max(0, min(1.5, dragStartV + dy * (fine ? 0.002 : 0.008)))
        case .mod:
            au.mod = max(0, min(1, dragStartV + dy * (fine ? 0.001 : 0.005)))
        case .dirt:
            au.dirt = max(0, min(1, dragStartV + dy * (fine ? 0.001 : 0.005)))
        case .noise:
            au.noise = max(0, min(1, dragStartV + dy * (fine ? 0.001 : 0.005)))
        case .delay:
            au.delayFx = max(0, min(1, dragStartV + dy * (fine ? 0.001 : 0.005)))
        case .reverb:
            au.reverbFx = max(0, min(1, dragStartV + dy * (fine ? 0.001 : 0.005)))
        case .chop:
            au.chop = max(0, min(1, dragStartV + dy * (fine ? 0.001 : 0.005)))
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if case .rowDrag(let src) = drag {
            NSCursor.pop()
            if let dst = rowDropTarget, let au = audioUnit {
                if event.modifierFlags.contains(.option) { au.swapGridRow(Int32(src), withRow: Int32(dst)) }
                else { au.copyGridRow(Int32(src), toRow: Int32(dst)) }
            }
            rowDragSrc = nil; rowDropTarget = nil
            needsDisplay = true
        }
        noteDragRowSnap = []
        if case .noteLen(let row, let start) = drag, !noteDragCreated, !noteDragMoved {
            audioUnit?.setCellAtRow(Int32(row), step: Int32(start), on: false)   // plain click on a note = delete
            needsDisplay = true
        }
        drag = .none; stCommit()
    }

    // MARK: - Dropdown menus

    private func popMenu(_ titles: [String], selected: Int, anchor: NSPoint, action: Selector) {
        let menu = NSMenu()
        for (i, t) in titles.enumerated() {
            let it = NSMenuItem(title: t, action: action, keyEquivalent: "")
            it.target = self; it.tag = i
            it.state = (i == selected) ? .on : .off
            menu.addItem(it)
        }
        menu.popUp(positioning: nil, at: anchor, in: self)
    }
    private func presentVoiceMenu(anchor: NSPoint) {
        popMenu(kVoiceNames, selected: Int(audioUnit?.voiceMode ?? 0), anchor: anchor, action: #selector(voicePicked(_:)))
    }
    @objc private func voicePicked(_ s: NSMenuItem) { audioUnit?.voiceMode = Int32(s.tag); needsDisplay = true }
    private func presentScaleMenu(anchor: NSPoint) {
        popMenu(kScaleFull, selected: Int(audioUnit?.scaleId ?? 0), anchor: anchor, action: #selector(scalePicked(_:)))
    }
    @objc private func scalePicked(_ s: NSMenuItem) { audioUnit?.scaleId = Int32(s.tag); needsDisplay = true }
    private func presentRootMenu(anchor: NSPoint) {
        popMenu(kNoteNames, selected: Int(audioUnit?.rootKey ?? 0), anchor: anchor, action: #selector(rootPicked(_:)))
    }
    @objc private func rootPicked(_ s: NSMenuItem) { audioUnit?.rootKey = Int32(s.tag); needsDisplay = true }

    private func presentPresetMenu(anchor: NSPoint) {
        let menu = NSMenu()
        for (i, pre) in kGridPresets.enumerated() {
            let it = NSMenuItem(title: pre.name, action: #selector(presetPicked(_:)), keyEquivalent: "")
            it.target = self; it.tag = i
            menu.addItem(it)
        }
        menu.popUp(positioning: nil, at: anchor, in: self)
    }
    @objc private func presetPicked(_ s: NSMenuItem) {
        guard let au = audioUnit, s.tag >= 0 && s.tag < kGridPresets.count else { return }
        let pre = kGridPresets[s.tag]
        au.scaleId   = Int32(pre.scale)
        au.rootKey   = Int32(pre.root)
        au.gridSteps = Int32(pre.steps)
        au.gridOctave = Int32(pre.octave)
        let maxSteps = 64
        let nRows = Int(au.numGridRows)

        // Build the base notes (row, start, length), tiled across all 64 steps.
        // Row strings: 'x' = note start, '-' = the note is held (tied) through
        // this step, '.' = rest. Lengths never cross the preset's loop end.
        let period = max(1, pre.steps)
        let base = presetNotes(pre.rows, nRows: nRows, maxSteps: maxSteps)

        let isHarmony = (pre.harmony != nil)
        // Fill all four PATTERN slots. Melodic presets get A=theme + three
        // musical variations (B=syncopated · C=diatonic-third answer · D=fill),
        // ready to LINK into a song. Harmony presets fill all four slots
        // IDENTICALLY — a sustained chord shouldn't get transposed into a
        // different chord by the auto-variation.
        let degPerOct = max(1, Int(gridScaleDegreeCount()))
        let shifted = base.map { ($0.0, ($0.1 + 4) % maxSteps, $0.2) }
        let third = base.compactMap { n -> (Int, Int, Int)? in
            guard let t = diatonicRow(n.0, by: 2, key: pre.key, nRows: nRows, degreesPerOctave: degPerOct) else { return nil }
            return (t, n.1, n.2)
        }
        let fill = base + base.map { ($0.0, ($0.1 + 2) % maxSteps, $0.2) }
        for slot in 0..<4 {
            au.currentSlot = Int32(slot)
            au.clearGrid()
            switch isHarmony ? 0 : slot {
            case 1:  writePresetNotes(shifted, period: period, nRows: nRows)
            case 2:  writePresetNotes(third, period: period, nRows: nRows)
            case 3:  writePresetNotes(fill, period: period, nRows: nRows)
            default: writePresetNotes(base, period: period, nRows: nRows)
            }
        }
        au.currentSlot = 0

        // Sustained-chord harmony presets: switch the engine into lush string-
        // pad mode so the painted chord actually rings as a long tone. These all
        // pass straight through the AU's Obj-C setters → engine, so loading is
        // confirmed through the exact same path the live controls use.
        if let h = pre.harmony {
            au.voiceMode      = Int32(h.voice)
            au.rate           = Int32(h.rate)
            au.gate           = h.gate
            au.octaveRange    = Int32(h.octaveRange)
            au.tone           = h.tone
            au.cutoffHz       = h.cutoff
            au.resonance      = h.reso
            au.droneOn        = h.droneOn
            au.droneLevel     = h.droneLevel
            au.droneInterval  = Int32(h.droneInterval)
            au.droneOctave    = Int32(h.droneOctave)
            au.reverbFx       = h.reverb
            au.reverbType     = Int32(h.reverbType)
            au.level          = h.level
            au.ampA = h.ampA; au.ampD = h.ampD; au.ampS = h.ampS; au.ampR = h.ampR
            au.mod            = h.mod
            au.mode           = 0   // SEQ — step the chord grid (not BERLIN/DUBSTEP)
        }
        // Fresh chain + undo baseline after a genre load.
        chainSlotsLocal.removeAll(); au.clearChain()
        stUndo.removeAll(); stRedo.removeAll(); stPending = nil
        needsDisplay = true
    }

    /// Preset row strings → notes (row, start, length), tiled over `maxSteps`.
    private func presetNotes(_ rows: [String], nRows: Int, maxSteps: Int) -> [(Int, Int, Int)] {
        var out: [(Int, Int, Int)] = []
        for r in 0..<min(nRows, rows.count) {
            let chars = Array(rows[r]); let n = chars.count
            if n == 0 { continue }
            var c = 0
            while c < n {
                if chars[c] == "x" || chars[c] == "X" {
                    var len = 1
                    while c + len < n && chars[c + len] == "-" { len += 1 }
                    for t in stride(from: 0, to: maxSteps, by: n) { out.append((r, t + c, len)) }
                    c += len
                } else { c += 1 }
            }
        }
        return out
    }
    /// Writes notes into the CURRENT slot without overlaps: a note whose start
    /// is already covered is dropped, one that runs into a later note is cut
    /// short, and no note rings across the preset's loop end (`period`).
    private func writePresetNotes(_ notes: [(Int, Int, Int)], period: Int, nRows: Int) {
        guard let au = audioUnit else { return }
        var used = Array(repeating: Array(repeating: false, count: 64), count: nRows)
        for (r, start, l) in notes where r >= 0 && r < nRows && start >= 0 && start < 64 {
            if used[r][start] { continue }
            var len = min(l, period - start % period)
            var k = 1
            while k < len && !used[r][start + k] { k += 1 }
            len = k
            for i in 0..<len { used[r][start + i] = true }
            // An earlier note written later in the list may cover cells before
            // this start; it was placed first, so `used` already blocks it.
            au.setCellAtRow(Int32(r), step: Int32(start), on: true)
            au.setLength(Int32(len), atRow: Int32(r), step: Int32(start))
        }
    }

    // MARK: - Generative randomizer (Euclidean-rooted)
    //
    // "Give us thousands of cool patterns rooted in rhythm principles."
    // The trick is to not roll dice on every cell — random noise sounds like
    // noise. Instead we build the groove from the same maths that underlies
    // most of the world's rhythms:
    //
    //   1. EUCLIDEAN (Bjorklund) distribution — spread N onsets as evenly as
    //      possible over the bar. This single rule produces the tresillo,
    //      son/rumba clave, cumbia, Ewe bell, etc. depending on N.
    //   2. DOWNBEAT ANCHORING — the bass layer's first onset lands on beat 1
    //      so the pattern always has a floor.
    //   3. CONTOUR MELODY — onsets are walked along the note rows following a
    //      musical shape (ascend / descend / pendulum / arpeggio / random walk
    //      / call-&-response) rather than scattered, so the line "goes
    //      somewhere".
    //   4. LAYERING — an independent sparse bass, a denser melody, and an
    //      optional high sparkle, each its own Euclidean figure, interlock the
    //      way real sequencer parts do.
    //
    // Scale + root are left exactly as the user set them, so every roll stays
    // in their key. The number of combinations (pulse counts × rotations ×
    // contour modes × layer toggles × swing) runs into the many thousands.

    /// Bjorklund's algorithm: distribute `pulses` onsets as evenly as possible
    /// across `steps` slots. Returns a bool array (true = onset).
    private func euclid(_ pulses: Int, _ steps: Int) -> [Bool] {
        if steps <= 0 { return [] }
        let k = max(0, min(pulses, steps))
        if k == 0 { return Array(repeating: false, count: steps) }
        if k == steps { return Array(repeating: true, count: steps) }

        var counts: [Int] = []
        var remainders: [Int] = [k]
        var divisor = steps - k
        var level = 0
        while true {
            counts.append(divisor / remainders[level])
            remainders.append(divisor % remainders[level])
            divisor = remainders[level]
            level += 1
            if remainders[level] <= 1 { break }
        }
        counts.append(divisor)

        var pattern: [Bool] = []
        func build(_ lvl: Int) {
            if lvl == -1 { pattern.append(false) }
            else if lvl == -2 { pattern.append(true) }
            else {
                for _ in 0..<counts[lvl] { build(lvl - 1) }
                if remainders[lvl] != 0 { build(lvl - 2) }
            }
        }
        build(level)

        // Normalise to exactly `steps`, rotated so index 0 is an onset.
        if pattern.count > steps { pattern = Array(pattern.prefix(steps)) }
        while pattern.count < steps { pattern.append(false) }
        if let first = pattern.firstIndex(of: true), first != 0 {
            pattern = Array(pattern[first...] + pattern[..<first])
        }
        return pattern
    }

    /// Rotate an array left by `by` (negative = right). Used to syncopate a
    /// Euclidean figure off the grid without losing its even spacing.
    private func rotated<T>(_ a: [T], _ by: Int) -> [T] {
        if a.isEmpty { return a }
        let n = ((by % a.count) + a.count) % a.count
        return Array(a[n...] + a[..<n])
    }

    // MARK: - Melodic motif library
    //
    // The randomizer is a *melody* generator, not a dice roll. It draws from a
    // bank of hand-written motifs — short contours in SCALE DEGREES (0 = root,
    // 7 = octave; -1 = rest), 8 notes (eighth-notes across the bar). Built from
    // the building blocks of melody: scalar runs, arpeggios, neighbour tones,
    // call-&-response, pop hooks and pentatonic riffs. Because the rows ARE the
    // user's scale, every degree stays in key.
    //
    // Each press: pick TWO motifs and combine them (AB phrase / AABB / ABAB),
    // transpose the whole line by a scale step, then mutate a couple of notes.
    // bank(40) × bank(40) × forms(3) × cut(3) × transpose(6) × mutations ≈ tens
    // of thousands of distinct-but-musical lines — the "1000-preset library that
    // iterates slightly randomly".
    private static let motifs: [[Int]] = [
        [0,1,2,3,4,5,6,7], [7,6,5,4,3,2,1,0], [0,2,4,7,4,2,0,-1], [0,2,4,2,0,2,4,2],
        [0,2,4,2,0,2,4,7], [0,1,0,-1,2,1,2,-1], [4,4,2,0,2,4,-1,-1], [7,4,7,4,5,4,2,-1],
        [0,-1,4,2,-1,5,4,-1], [0,-1,-1,2,-1,4,-1,2], [0,2,4,-1,0,2,4,-1], [7,5,4,-1,4,2,0,-1],
        [0,2,1,3,2,4,3,5], [5,3,4,2,3,1,2,0], [0,2,4,5,7,5,4,2], [4,2,0,2,4,7,4,-1],
        [0,7,2,5,4,-1,0,-1], [0,-1,2,-1,4,-1,7,-1], [4,4,5,7,7,5,4,2], [2,1,0,-1,4,3,2,-1],
        [0,2,3,4,-1,-1,-1,-1], [4,3,2,1,0,-1,-1,-1], [0,4,0,4,2,5,2,5], [7,6,4,5,2,3,0,-1],
        [2,4,5,4,2,0,-1,0], [5,7,5,4,2,4,-1,-1], [0,0,2,0,0,4,0,-1], [0,2,2,4,4,5,5,7],
        [3,4,3,2,3,-1,0,-1], [0,3,5,7,-1,5,3,-1], [0,3,1,4,2,5,3,-1], [0,-1,2,2,-1,4,4,-1],
        [0,7,0,7,4,7,4,-1], [0,2,3,5,3,2,0,-1], [4,4,4,2,0,2,4,-1], [0,1,3,2,4,3,5,4],
        [2,2,4,4,7,7,4,2], [7,7,5,5,4,4,2,0], [0,-1,4,-1,2,-1,5,-1], [0,2,4,5,7,4,2,0],
    ]

    private func randomizePattern() {
        guard let au = audioUnit else { return }
        let steps = max(1, Int(au.gridSteps))
        let rows  = max(1, Int(au.numGridRows))   // 8; row 0 = root at bottom
        let hiRow = rows - 1
        let beat  = max(1, steps / 4)
        au.clearGrid()
        for c in 0..<steps { au.setColSwing(Int32(c), level: 0) }

        // ── Fill the WHOLE grid with a developing melodic line ───────────
        // One motif (8 notes) per 8-step block, tiled across all `steps` so the
        // note count grows with the STEPS setting — a full melody, not a sparse
        // sprinkle. Each block picks a motif + its own transpose so the line
        // develops; blocks often reuse the previous motif for an AABA feel.
        let bank = Self.motifs
        let mlen = 8
        let blocks = (steps + mlen - 1) / mlen
        var line = [Int](repeating: -1, count: steps)
        var prevMotif = bank.randomElement()!
        for blk in 0..<blocks {
            let motif = (blk > 0 && Int.random(in: 0..<3) == 0) ? prevMotif : bank.randomElement()!
            prevMotif = motif
            // Includes octave reaches (7 / 8) so the line roams the full
            // two-octave grid instead of hugging the bottom rows.
            let transpose = [0, 0, 2, -2, 3, 4, 7, 8].randomElement()!
            for i in 0..<mlen {
                let col = blk * mlen + i
                if col >= steps { break }
                var d = motif[i]
                if d >= 0 {
                    d += transpose
                    if Int.random(in: 0..<7) == 0 { d += [-1, 1].randomElement()! }  // slight mutation
                } else if Int.random(in: 0..<3) == 0 {
                    // fill some rests with passing tones for a denser line
                    d = transpose + [0, 2, 4].randomElement()!
                }
                line[col] = d
            }
        }

        // ── Write the melody — one note per filled step (wrapped in-key) ──
        let rowsMod = max(1, rows)
        for col in 0..<steps where line[col] >= 0 {
            let row = ((line[col] % rowsMod) + rowsMod) % rowsMod   // keep within the octave
            au.setCellAtRow(Int32(min(hiRow, row)), step: Int32(col), on: true)
        }

        // ── Root bass anchor on the downbeats for grounding ──────────────
        for b in Swift.stride(from: 0, to: steps, by: max(1, beat * 2)) {
            au.setCellAtRow(0, step: Int32(b), on: true)
        }

        // ── Tasteful swing to finish ─────────────────────────────────────
        au.swing = [0.0, 0.0, 0.08, 0.12].randomElement()!
        needsDisplay = true
    }

    private func presentBPMTypeInput() {
        guard let au = audioUnit else { return }
        let alert = NSAlert()
        alert.messageText = "Set BPM"
        alert.informativeText = au.bpmSynced
            ? "Synced to host — your value will be overwritten by Logic next render."
            : "Internal BPM. Enter a tempo between 40 and 220."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.stringValue = String(format: "%.1f", au.bpm)
        field.alignment = .center
        alert.accessoryView = field
        alert.addButton(withTitle: "Set"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            if let v = Float(field.stringValue.replacingOccurrences(of: ",", with: ".")) {
                au.bpm = max(40, min(220, v))
                needsDisplay = true
            }
        }
    }
}
