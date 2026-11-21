//
//  SynthThingParameterView.swift
//  Paradise Audio — Synth Thing (SNT-1)
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

// INVERTED palette — SynthThing is the DARK TWIN of the cream Drums machine.
// `inkDark`/`inkMid` are redefined LIGHT so the existing draw calls (text,
// hairlines, cell strokes) read correctly on the dark faceplate without
// rewriting every call site. `cream` stays light (active-pill text / fills).
private let faceBg    = NSColor(calibratedWhite: 0.132, alpha: 1.0)   // dark faceplate
private let cream     = Palette.cream                                // light accents / active text
private let inkDark   = NSColor(calibratedWhite: 0.90, alpha: 1.0)   // light "ink" (inverted)
private let inkMid    = NSColor(calibratedWhite: 0.55, alpha: 1.0)   // mid ink
private let red       = Palette.red
private let panelDark = NSColor(calibratedWhite: 0.17, alpha: 1.0)   // dark inset panels

private let aLabel: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: inkDark, .kern: 0.8]
private let aTiny:  [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 8, weight: .regular), .foregroundColor: inkMid]
private let aVal:   [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: inkDark]
private let aBtnOn: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .heavy), .foregroundColor: cream, .kern: 0.6]
private let aBtnOff:[NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: inkDark, .kern: 0.6]
private let aBrand: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16, weight: .bold), .foregroundColor: inkDark, .kern: 2.0]

// Trimmed option lists for a neater UI. The engine still supports every
// internal enum; we just expose a sensible subset.
private let kNoteNames = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
// ARP removed — keep just SEQ + BERLIN. Voice list grew from 3 → 6.
private let kModeNames   = ["SEQ","BERLIN","DUBSTEP"]
private let kVoiceNames  = ["SYNTH","PLUCK","BASS","BELL","SUPER","REESE","PWM","DIGI"]
private let kDirNames    = ["UP","DOWN","RAND"]
private let kRateNames   = ["1/4","1/8","1/16","1/32","1/64"]
private let kScaleNames  = ["CHROM","MAJ","MIN","JOG","CHINA"]
private let kPhraseNames = ["GALLOP","STUTTER","ACID","EUCLID","GLITCH","BOUNCE","CHAOS","RAVE"]
private let kOctChoices  = [1, 2, 3]
// Engine direction indices for each visible button: Up=0, Down=1, Random=3.
private let kDirEngineIdx = [0, 1, 3]
// Engine scale indices for each visible button.
private let kScaleEngineIdx = [0, 1, 2, 3, 4]
// Engine rate slot for each visible button (rate enum: 1=1/4..4=1/32).
private let kRateEngineIdx = [1, 2, 3, 4, 7]   // …, 7 = 1/64

// FX type/mode names (the little setting above each FX knob).
private let kDelayTypes  = ["1/8", "1/4", "DOT", "TRIP", "SLAP", "PING"]
private let kReverbTypes = ["ROOM", "HALL", "PLATE", "AMBI"]
private let kChopTypes   = ["1/16", "1/8", "TRIP", "SAW", "REV", "STUT", "RAND", "S&H", "SINE", "GLCH"]

// ── Melodic grid presets ─────────────────────────────────────────────
// Each preset sets scale + root + step count, then paints the 8 note rows.
// rows[0] = ROOT (bottom row) rising upward. A pattern string's length must
// equal `steps`; 'x'/'X' = note on, anything else = off. Inspired by world-
// percussion + electronic sequencer patterns (gamelan, kalimba, acid, etc.).
private struct GridPreset {
    let name: String
    let scale: Int      // engine scale id
    let root: Int       // 0..11
    let steps: Int      // 16 / 32 / 64
    let rows: [String]  // 8 rows, [0]=root at bottom
}

private let kGridPresets: [GridPreset] = [
    GridPreset(name: "Gamelan Bonang", scale: 4, root: 7, steps: 16, rows: [
        "x...x...x...x...",
        "..x...x...x...x.",
        "....x.......x...",
        "x.......x.......",
        "..x...x...x...x.",
        "....x.......x...",
        "x...............",
        "........x......."]),
    GridPreset(name: "Saron Interlock", scale: 4, root: 7, steps: 16, rows: [
        "x.x.x.x.x.x.x.x.",
        ".x.x.x.x.x.x.x.x",
        "x...x...x...x...",
        "..x...x...x...x.",
        "x.x.x.x.x.x.x.x.",
        "....x.......x...",
        "x.......x.......",
        ".....x.......x.."]),
    GridPreset(name: "Kalimba Hypno", scale: 2, root: 0, steps: 16, rows: [
        "x..x..x..x..x..x",
        "..x..x..x..x..x.",
        ".x..x..x..x..x..",
        "x.....x.....x...",
        "..x..x..x..x..x.",
        ".....x.....x....",
        "x.......x.......",
        "...x.......x...."]),
    GridPreset(name: "Mbira Cycle", scale: 1, root: 5, steps: 16, rows: [
        "x..x..x..x..x...",
        "..x..x..x..x..x.",
        "....x.....x.....",
        "x.....x.....x...",
        "..x..x..x..x..x.",
        ".x.....x.....x..",
        "x...............",
        "......x.......x."]),
    GridPreset(name: "Balafon Big Beat", scale: 1, root: 0, steps: 16, rows: [
        "x...x...x...x...",
        "..x...x...x...x.",
        "x...x...x...x...",
        "....x.......x...",
        "..x...x...x...x.",
        "x.......x.......",
        ".....x.......x..",
        "x..............."]),
    GridPreset(name: "Koto Asagao", scale: 4, root: 2, steps: 16, rows: [
        "x.....x.....x...",
        "..x.....x.....x.",
        "....x.....x.....",
        "x.......x.......",
        "..x...x...x...x.",
        "....x.......x...",
        "x...............",
        "..........x....."]),
    GridPreset(name: "Acid Line", scale: 2, root: 0, steps: 16, rows: [
        "x.x..x.xx.x..x.x",
        "....x.......x...",
        "..x...x...x...x.",
        "x.......x.......",
        ".....x.......x..",
        "...x.......x....",
        "x......x......x.",
        ".........x......"]),
    GridPreset(name: "Berlin Run", scale: 2, root: 0, steps: 32, rows: [
        "x...x...x...x...x...x...x...x...",
        "..x...x...x...x...x...x...x...x.",
        "....x.......x.......x.......x...",
        "x.......x.......x.......x.......",
        "..x...x...x...x...x...x...x...x.",
        "......x.......x.......x.......x.",
        "x...............x...............",
        "........x...............x......."]),
    GridPreset(name: "Trance Gate", scale: 1, root: 9, steps: 16, rows: [
        "x.x.x.x.x.x.x.x.",
        "x.x.x.x.x.x.x.x.",
        "x.x.x.x.x.x.x.x.",
        "x...x...x...x...",
        "x.x.x.x.x.x.x.x.",
        "..x...x...x...x.",
        "x.x.x.x.x.x.x.x.",
        "....x.......x..."]),
    GridPreset(name: "Pluck Arp Up", scale: 1, root: 0, steps: 16, rows: [
        "x.......x.......",
        ".x.......x......",
        "..x.......x.....",
        "...x.......x....",
        "....x.......x...",
        ".....x.......x..",
        "......x.......x.",
        ".......x.......x"]),
    GridPreset(name: "Bounce Octaves", scale: 2, root: 0, steps: 16, rows: [
        "x...x...x...x...",
        "................",
        "................",
        "................",
        "................",
        "................",
        "................",
        "..x...x...x...x."]),
    GridPreset(name: "Hypno Phrygian", scale: 5, root: 4, steps: 32, rows: [
        "x...x...x...x...x...x...x...x...",
        ".x....x....x....x....x....x....x",
        "..x.....x.....x.....x.....x.....",
        "x.......x.......x.......x.......",
        "....x.......x.......x.......x...",
        "..x...x...x...x...x...x...x...x.",
        "x...............x...............",
        ".....x.......x.......x.......x.."]),
    GridPreset(name: "Dorian Skip", scale: 7, root: 2, steps: 16, rows: [
        "x..x..x..x..x...",
        "..x..x..x..x..x.",
        "....x.....x.....",
        "x.....x.....x...",
        "..x..x..x..x..x.",
        ".....x.....x....",
        "x.......x.......",
        "...x.......x...."]),
    GridPreset(name: "Glass Bells", scale: 1, root: 7, steps: 16, rows: [
        "x.......x.......",
        "....x.......x...",
        "..x...x...x...x.",
        "x.......x.......",
        "......x.......x.",
        "...x.......x....",
        "x...............",
        ".........x......"]),
    GridPreset(name: "Angklung Shimmer", scale: 1, root: 0, steps: 32, rows: [
        "x.x.x.x.x.x.x.x.x.x.x.x.x.x.x.x.",
        ".x.x.x.x.x.x.x.x.x.x.x.x.x.x.x.x",
        "x...x...x...x...x...x...x...x...",
        "..x...x...x...x...x...x...x...x.",
        "x.x.x.x.x.x.x.x.x.x.x.x.x.x.x.x.",
        "....x.......x.......x.......x...",
        "x.......x.......x.......x.......",
        ".....x.......x.......x.......x.."]),
    GridPreset(name: "Minimal Dub", scale: 2, root: 9, steps: 16, rows: [
        "x.......x.......",
        "................",
        "....x.......x...",
        "................",
        "..x.......x.....",
        "................",
        "x.............x.",
        "................"]),
]

final class SynthThingParameterView: NSView {
    var audioUnit: SynthThingAudioUnit? { didSet { needsDisplay = true } }

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

    /// Map a Synth Thing scale id to a set of pitch-class degrees (0..11)
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
        ctx.setFillColor(NSColor(calibratedWhite: 0.085, alpha: 1.0).cgColor); ctx.fill(tr)
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

        // SAVE / LOAD named presets — left of the undo buttons.
        let sbw: CGFloat = 40, sbh: CGFloat = 16
        loadBtnRect = NSRect(x: undoBtnRect.minX - 14 - sbw, y: cy - sbh * 0.5, width: sbw, height: sbh)
        saveBtnRect = NSRect(x: loadBtnRect.minX - 6 - sbw, y: cy - sbh * 0.5, width: sbw, height: sbh)
        drawUndoButton(ctx, saveBtnRect, "SAVE", false)
        drawUndoButton(ctx, loadBtnRect, "LOAD", false)
    }

    /// LINK / song-chain strip under the PATTERN buttons. Tap A/B/C/D to append
    /// to the chain; it plays left→right and loops, live entry highlighted.
    private func drawLinkStrip(_ ctx: CGContext, _ strip: NSRect) {
        let cy = strip.midY
        let letters = ["A", "B", "C", "D"]
        let chainOn = !chainSlotsLocal.isEmpty
        let pos = Int(audioUnit?.chainPosition ?? 0)
        let playing = audioUnit?.playing ?? false

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
        let labelW: CGFloat = 44
        let inner = NSRect(x: r.minX + inset, y: r.minY + 12,
                           width: r.width - inset * 2, height: r.height - 30)
        let rows = max(1, Int(audioUnit?.numGridRows ?? 8))
        let steps = max(1, Int(audioUnit?.gridSteps ?? 16))
        let beatGap: CGFloat = 6, cellGap: CGFloat = 2, rowGap: CGFloat = 2
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
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: isRoot ? .heavy : .regular),
                .foregroundColor: isRoot ? red : inkDark.withAlphaComponent(0.7)
            ]
            let nz = nm.size(withAttributes: rowLblAttr)
            nm.draw(at: NSPoint(x: g.inner.minX + g.labelW - 8 - nz.width, y: y + g.cellH * 0.5 - nz.height * 0.5), withAttributes: rowLblAttr)
            _ = lblAttr

            for col in 0..<g.steps {
                let x = g.cellX(col)
                let cell = NSRect(x: x, y: y, width: g.cellW, height: g.cellH)
                let on = au.cell(atRow: Int32(row), step: Int32(col))
                if on {
                    ctx.setFillColor(red.cgColor); ctx.fill(cell)
                } else {
                    // Inverted twin: dark cell + faint light hairline. Root-row
                    // and beat-1 columns get a slightly lighter base for legibility.
                    let base: CGFloat = (col % 4 == 0) ? 0.255 : 0.205
                    ctx.setFillColor(NSColor(calibratedWhite: base, alpha: 1.0).cgColor); ctx.fill(cell)
                    ctx.setStrokeColor(inkDark.withAlphaComponent(0.16).cgColor); ctx.setLineWidth(0.5); ctx.stroke(cell)
                }
                // Active-step cells get a red outline.
                if col == curStep {
                    ctx.setStrokeColor(red.withAlphaComponent(on ? 1.0 : 0.7).cgColor); ctx.setLineWidth(1.4); ctx.stroke(cell)
                }
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
            ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.10).cgColor); ctx.fill(rect)
            ctx.setStrokeColor(inkDark.withAlphaComponent(0.40).cgColor); ctx.setLineWidth(0.8); ctx.stroke(rect)
            NSString(string: caption).draw(at: NSPoint(x: rect.minX + 1, y: rect.maxY + 4), withAttributes: cap)
            let s = NSString(string: "\(value)  ▾"); let z = s.size(withAttributes: valA)
            s.draw(at: NSPoint(x: rect.minX + 9, y: rect.midY - z.height * 0.5 - 1), withAttributes: valA)
        }
        func toggleBox(_ rect: NSRect, caption: String, text: String, active: Bool) {
            if active { ctx.setFillColor(red.cgColor); ctx.fill(rect) }
            else { ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.10).cgColor); ctx.fill(rect)
                   ctx.setStrokeColor(inkDark.withAlphaComponent(0.40).cgColor); ctx.setLineWidth(0.8); ctx.stroke(rect) }
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
        let knobR: CGFloat = 18
        let ky = r.minY + 34
        let n = 11
        let span = r.width - 24
        func kc(_ i: Int) -> NSPoint { NSPoint(x: r.minX + 12 + span * (CGFloat(i) + 0.5) / CGFloat(n), y: ky) }
        func box(_ c: NSPoint) -> NSRect { NSRect(x: c.x - 24, y: c.y - 22, width: 48, height: 44) }

        let c0 = kc(0); lvlKnob = box(c0)
        let lvlNorm = CGFloat(min(2.0, max(0.0, Double(au.level))) / 2.0)
        drawBigKnob(ctx, center: c0, radius: knobR, normalized: lvlNorm, body: NSColor.white, pointer: red, label: "LVL")
        let c1 = kc(1); toneKnob = box(c1)
        drawBigKnob(ctx, center: c1, radius: knobR, normalized: CGFloat(au.tone), body: NSColor(calibratedWhite: 0.20, alpha: 1), pointer: red, label: "TONE")
        let c2 = kc(2); cutoffKnob = box(c2)
        let cutNorm = CGFloat(log2(max(20.0, Double(au.cutoffHz)) / 20.0) / log2(20000.0 / 20.0))
        drawBigKnob(ctx, center: c2, radius: knobR, normalized: cutNorm, body: red, pointer: NSColor.white, label: "CUT")
        let c3 = kc(3); resoKnob = box(c3)
        drawBigKnob(ctx, center: c3, radius: knobR, normalized: CGFloat(au.resonance) / 4.0, body: NSColor(calibratedWhite: 0.20, alpha: 1), pointer: red, label: "RES")
        let c4 = kc(4); modKnob = box(c4)
        drawBigKnob(ctx, center: c4, radius: knobR, normalized: CGFloat(au.mod), body: NSColor(calibratedWhite: 0.20, alpha: 1), pointer: red, label: "MOD")
        let c5 = kc(5); dirtKnob = box(c5)
        drawBigKnob(ctx, center: c5, radius: knobR, normalized: CGFloat(au.dirt), body: NSColor(calibratedWhite: 0.20, alpha: 1), pointer: red, label: "DIRT")
        let c6 = kc(6); noiseKnob = box(c6)
        drawBigKnob(ctx, center: c6, radius: knobR, normalized: CGFloat(au.noise), body: NSColor(calibratedWhite: 0.20, alpha: 1), pointer: red, label: "NOISE")
        let c7 = kc(7); gateKnob = box(c7)
        drawBigKnob(ctx, center: c7, radius: knobR, normalized: CGFloat(au.gate), body: NSColor(calibratedWhite: 0.20, alpha: 1), pointer: red, label: "GATE")
        let c8 = kc(8); delayKnob = box(c8)
        drawBigKnob(ctx, center: c8, radius: knobR, normalized: CGFloat(au.delayFx), body: NSColor(calibratedWhite: 0.20, alpha: 1), pointer: red, label: "DELAY")
        let c9 = kc(9); reverbKnob = box(c9)
        drawBigKnob(ctx, center: c9, radius: knobR, normalized: CGFloat(au.reverbFx), body: NSColor(calibratedWhite: 0.20, alpha: 1), pointer: red, label: "REVERB")
        let c10 = kc(10); chopKnob = box(c10)
        drawBigKnob(ctx, center: c10, radius: knobR, normalized: CGFloat(au.chop), body: NSColor(calibratedWhite: 0.20, alpha: 1), pointer: red, label: "CHOP")

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
        ctx.setFillColor(red.cgColor); ctx.fill(NSRect(x: 16, y: r.midY - 8, width: 16, height: 16))
        NSString(string: "PARADISE AUDIO · SYNTH THING").draw(at: NSPoint(x: 40, y: r.midY - 10), withAttributes: aBrand)
    }

    private func drawBigKnob(_ ctx: CGContext, center c: NSPoint, radius r: CGFloat, normalized n: CGFloat,
                             body: NSColor, pointer: NSColor, label: String) {
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.45).cgColor); ctx.setLineWidth(0.6)
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
        ctx.setFillColor(body.cgColor); ctx.fillEllipse(in: bodyR)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.35).cgColor); ctx.setLineWidth(1.0); ctx.strokeEllipse(in: bodyR)
        let capR = r * 0.30
        ctx.setFillColor(cream.cgColor); ctx.fillEllipse(in: NSRect(x: c.x - capR, y: c.y - capR, width: capR*2, height: capR*2))
        let ang = s - n * (s - e)
        let p1 = NSPoint(x: c.x + cos(ang) * (capR + 2), y: c.y + sin(ang) * (capR + 2))
        let p2 = NSPoint(x: c.x + cos(ang) * (r - 3), y: c.y + sin(ang) * (r - 3))
        ctx.setStrokeColor(pointer.cgColor); ctx.setLineWidth(3.0); ctx.setLineCap(.round)
        ctx.move(to: p1); ctx.addLine(to: p2); ctx.strokePath()
        let ls = NSString(string: label)
        let lsz = ls.size(withAttributes: aTiny)
        ls.draw(at: NSPoint(x: c.x - lsz.width * 0.5, y: c.y - r - 10), withAttributes: aTiny)
    }

    // MARK: - Interaction

    private enum Drag { case none, cutoff, reso, tone, swing, gate, bpm, step(Int), paint(Bool), lvl, droneLvl, mod, dirt, noise, delay, reverb, chop }
    private var drag: Drag = .none
    private var dragStartY: CGFloat = 0
    private var dragStartV: Float = 0

    // MARK: - Undo / Redo (10-step full-state snapshot)
    //
    // SynthThing drives the DSP through direct properties + the step grid (its
    // AUParameterTree is empty), so undo is a full-state snapshot of the synth
    // params + the current slot's grid, captured before each edit gesture and
    // restored on undo — same model as the Drums machine.
    private struct STSnapshot: Equatable {
        var grid: [Bool]; var colSwing: [Int16]
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
        for r in 0..<rows { for s in 0..<steps { grid.append(au.cell(atRow: Int32(r), step: Int32(s))) } }
        for s in 0..<steps { cs.append(Int16(au.colSwing(Int32(s)))) }
        return STSnapshot(grid: grid, colSwing: cs,
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
            PresetStore.save("SynthThing", name: field.stringValue, data: au.stateData())
        }
    }

    private func presentLoadPreset() {
        let names = PresetStore.list("SynthThing")
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
        guard let au = audioUnit, let data = PresetStore.load("SynthThing", name: sender.title) else { return }
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
        if saveBtnRect.contains(p) { presentSavePreset(); return }
        if loadBtnRect.contains(p) { presentLoadPreset(); return }
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
        for b in slotBtns where b.rect.contains(p) { au.currentSlot = Int32(b.tag); needsDisplay = true; return }
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
        // Swing-tick strip — click a column's box to cycle its late-swing 0→4.
        for col in 0..<g.steps {
            if g.swingRect(col).contains(p) {
                let cur = Int(au.colSwing(Int32(col)))
                au.setColSwing(Int32(col), level: Int32((cur + 1) % 5))
                needsDisplay = true; return
            }
        }
        // Keyboard step-grid: click a cell (row,col) to toggle the note.
        // Drag across cells paints/erases (Drums-style) using the first cell's
        // new state as the paint value.
        if let (row, col) = gridCellAt(p, g) {
            let newOn = !au.cell(atRow: Int32(row), step: Int32(col))
            au.setCellAtRow(Int32(row), step: Int32(col), on: newOn)
            drag = .paint(newOn)
            needsDisplay = true
            return
        }
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
            // Paint/erase cells as the cursor moves across the grid.
            let g = gridGeo(gridRect())
            if let (row, col) = gridCellAt(p, g) {
                au.setCellAtRow(Int32(row), step: Int32(col), on: on)
            }
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

    override func mouseUp(with event: NSEvent) { drag = .none; stCommit() }

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
        let maxSteps = 64
        let nRows = Int(au.numGridRows)

        // Build the base grid (tile each row across all 64 steps).
        var base = Array(repeating: Array(repeating: false, count: maxSteps), count: nRows)
        for r in 0..<min(nRows, pre.rows.count) {
            let chars = Array(pre.rows[r]); let baseLen = chars.count
            if baseLen == 0 { continue }
            for c in 0..<maxSteps where (chars[c % baseLen] == "x" || chars[c % baseLen] == "X") {
                base[r][c] = true
            }
        }

        // Fill all four PATTERN slots with A=base + three musical variations,
        // so the preset behaves like a Drums "genre" — A/B/C/D ready to LINK
        // into a song. A=theme · B=syncopated · C=octave-up answer · D=fill.
        for slot in 0..<4 {
            au.currentSlot = Int32(slot)
            au.clearGrid()
            for r in 0..<nRows {
                for c in 0..<maxSteps {
                    var on: Bool
                    switch slot {
                    case 1: on = base[r][(c + maxSteps - 4) % maxSteps]           // shift = new phrasing
                    case 2: on = (r - 2 >= 0) ? base[r - 2][c] : false            // transpose up 2 rows
                    case 3: on = base[r][c] || base[r][(c + maxSteps - 2) % maxSteps] // busier fill
                    default: on = base[r][c]                                      // A — the theme
                    }
                    if on { au.setCellAtRow(Int32(r), step: Int32(c), on: true) }
                }
            }
        }
        au.currentSlot = 0
        // Fresh chain + undo baseline after a genre load.
        chainSlotsLocal.removeAll(); au.clearChain()
        stUndo.removeAll(); stRedo.removeAll(); stPending = nil
        needsDisplay = true
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
