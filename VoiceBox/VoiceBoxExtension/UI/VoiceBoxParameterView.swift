//
//  VoiceBoxParameterView.swift
//  VoiceBox faceplate — redesign 2026-11-21 ("way too much empty space").
//
//  960 × 460 pt, top to bottom, no dead bands:
//    • header bar (42)  — Sunwave logo, VOICE BOX title block, PRESET row of
//      ten rubber keys, undo / redo
//    • voice strip (128) — singing head on the left (lip-synced to the output
//      level), live spectrum fanning out of its mouth with breath arcs, and the
//      AUTOTUNE pitch readout (input note → target note, cents meter)
//    • 4 × 2 module cards (2 × 112) in the DSP's real signal order
//      1 AUTOTUNE → 2 LOW TUNER → 3 VOCODER → 4 HARMONIZER →
//      5 PITCH-SKIP → 6 DELAY → 7 CHOP → 8 REVERB
//      Every card is three 66-pt columns: three knobs, or a small param-driven
//      picture well + two knobs. Header: chain number, name, mode keys, power.
//    • BrandStrip footer (44)
//  Parameter addresses are unchanged; old sessions load as before.
//

import AppKit
import AudioToolbox

// MARK: - Singing head (5 rendered frames, or a procedural placeholder)

/// Head artwork: `voicebox_head_f0_KJ_v002.png` … `f4` (square, alpha,
/// facing right, mouth closed → fully open; Tools/voicebox_head/head_blender.py) plus the mouth centre per
/// frame. The anchor comes from `voicebox_head_mouth.json` when bundled —
///   {"image_size": [1200, 1200], "frames": [[x, y], …]}   (pixels, top-left origin)
/// ( `{"f0": {"x":…, "y":…}, …}` and `{"frames": [{"x":…, "y":…}, …]}` work too ) —
/// otherwise from `fallbackMouth` below. Missing PNGs → the vector head.
enum VBHeadArt {
    static let frameCount = 5
    /// Mouth centre in image pixels (top-left origin) per frame. Placeholder
    /// numbers — update when the renders land, or ship the JSON instead.
    static let fallbackMouth: [CGPoint] = [
        CGPoint(x: 905, y: 700), CGPoint(x: 905, y: 712), CGPoint(x: 903, y: 724),
        CGPoint(x: 900, y: 738), CGPoint(x: 897, y: 752),
    ]
    static let frames: [CGImage]? = {
        let bundle = Bundle(for: VBVoiceStrip.self)
        var out: [CGImage] = []
        for i in 0..<frameCount {
            guard let u = bundle.url(forResource: "voicebox_head_f\(i)_KJ_v002", withExtension: "png"),
                  let img = NSImage(contentsOf: u),
                  let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            out.append(cg)
        }
        return out
    }()
    static let imageSize: CGSize = {
        if let j = json, let s = j["image_size"] as? [Double], s.count == 2 { return CGSize(width: s[0], height: s[1]) }
        if let f = frames?.first { return CGSize(width: f.width, height: f.height) }
        return CGSize(width: 1200, height: 1200)
    }()
    private static let json: [String: Any]? = {
        guard let u = Bundle(for: VBVoiceStrip.self).url(forResource: "voicebox_head_mouth", withExtension: "json"),
              let d = try? Data(contentsOf: u),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return o
    }()
    static let mouth: [CGPoint] = {
        func pt(_ v: Any?) -> CGPoint? {
            if let a = v as? [Double], a.count >= 2 { return CGPoint(x: a[0], y: a[1]) }
            if let d = v as? [String: Any], let x = (d["x"] as? NSNumber)?.doubleValue, let y = (d["y"] as? NSNumber)?.doubleValue { return CGPoint(x: x, y: y) }
            return nil
        }
        guard let j = json else { return fallbackMouth }
        var pts: [CGPoint] = []
        if let arr = j["frames"] as? [Any] ?? j["mouth"] as? [Any] { pts = arr.compactMap(pt) }
        else { pts = (0..<frameCount).compactMap { pt(j["f\($0)"]) } }
        return pts.count == frameCount ? pts : fallbackMouth
    }()
}

/// Procedural placeholder: cream profile facing right, the jaw hinges open
/// with `open` (0…1) and the mouth is red inside. Unit square, y up.
enum VBHeadVector {
    private static let pivot = CGPoint(x: 0.53, y: 0.47)
    private static func jaw(_ p: CGPoint, _ a: CGFloat) -> CGPoint {
        let dx = p.x - pivot.x, dy = p.y - pivot.y
        return CGPoint(x: pivot.x + dx * cos(a) + dy * sin(a), y: pivot.y - dx * sin(a) + dy * cos(a))
    }
    static let upperLip = CGPoint(x: 0.815, y: 0.432)
    static let corner   = CGPoint(x: 0.755, y: 0.410)
    static func lowerLip(_ open: CGFloat) -> CGPoint { jaw(CGPoint(x: 0.805, y: 0.395), open * 0.30) }
    /// Mouth centre (unit coordinates) for a given opening.
    static func mouth(_ open: CGFloat) -> CGPoint {
        let l = lowerLip(open)
        return CGPoint(x: (upperLip.x + l.x) * 0.5 + 0.01, y: (upperLip.y + l.y) * 0.5)
    }
    static func draw(_ ctx: CGContext, in sq: NSRect, open: CGFloat) {
        let a = max(0, min(1, open)) * 0.30          // jaw angle, ≈ 17° fully open
        func P(_ p: CGPoint) -> CGPoint { CGPoint(x: sq.minX + p.x * sq.width, y: sq.minY + p.y * sq.height) }
        func J(_ x: CGFloat, _ y: CGFloat) -> CGPoint { P(jaw(CGPoint(x: x, y: y), a)) }
        func U(_ x: CGFloat, _ y: CGFloat) -> CGPoint { P(CGPoint(x: x, y: y)) }
        let lo = lowerLip(open)
        // Mouth cavity first, so the silhouette's lips frame it.
        let cav = CGMutablePath()
        cav.move(to: P(corner)); cav.addLine(to: P(CGPoint(x: upperLip.x + 0.004, y: upperLip.y - 0.004)))
        cav.addLine(to: P(CGPoint(x: lo.x + 0.004, y: lo.y + 0.004))); cav.closeSubpath()
        ctx.addPath(cav); ctx.setFillColor(NSColor(calibratedRed: 0.42, green: 0.05, blue: 0.05, alpha: 1).cgColor); ctx.fillPath()
        // Tongue hint.
        let tg = CGMutablePath()
        tg.move(to: P(corner)); tg.addLine(to: P(CGPoint(x: (corner.x + lo.x) * 0.5 + 0.02, y: lo.y + 0.012 + a * 0.02)))
        tg.addLine(to: P(CGPoint(x: lo.x - 0.005, y: lo.y + 0.006))); tg.closeSubpath()
        ctx.addPath(tg); ctx.setFillColor(Palette.red.cgColor); ctx.fillPath()

        let s = CGMutablePath()
        s.move(to: U(0.31, -0.02))
        s.addLine(to: U(0.31, 0.16))
        s.addCurve(to: U(0.17, 0.50), control1: U(0.24, 0.24), control2: U(0.15, 0.36))
        s.addCurve(to: U(0.46, 0.90), control1: U(0.19, 0.74), control2: U(0.30, 0.89))
        s.addCurve(to: U(0.74, 0.74), control1: U(0.62, 0.91), control2: U(0.72, 0.85))
        s.addCurve(to: U(0.770, 0.615), control1: U(0.76, 0.68), control2: U(0.745, 0.64))  // brow
        s.addCurve(to: U(0.875, 0.500), control1: U(0.80, 0.58), control2: U(0.86, 0.53))   // nose ridge
        s.addCurve(to: U(0.795, 0.470), control1: U(0.88, 0.47), control2: U(0.83, 0.462))  // nose tip → base
        s.addCurve(to: P(upperLip), control1: U(0.80, 0.462), control2: U(0.818, 0.450))
        s.addLine(to: P(corner))
        s.addLine(to: P(lo))
        s.addCurve(to: J(0.785, 0.340), control1: J(0.800, 0.372), control2: J(0.778, 0.360))  // under-lip
        s.addCurve(to: J(0.745, 0.262), control1: J(0.805, 0.310), control2: J(0.790, 0.270))  // chin
        s.addCurve(to: J(0.610, 0.255), control1: J(0.700, 0.250), control2: J(0.650, 0.262))  // jaw underside
        s.addCurve(to: U(0.600, 0.120), control1: P(CGPoint(x: 0.585, y: 0.230 - a * 0.10)), control2: U(0.595, 0.16))
        s.addLine(to: U(0.620, -0.02))
        s.closeSubpath()
        ctx.addPath(s); ctx.setFillColor(Palette.inkLight.cgColor); ctx.fillPath()
        // Screen-print details: ear, eye, jaw line — flat ink, no gradients.
        let ink = Palette.panelDark.withAlphaComponent(0.55).cgColor
        ctx.setStrokeColor(ink); ctx.setLineWidth(max(1, sq.width * 0.012)); ctx.setLineCap(.round)
        let ear = CGMutablePath()
        ear.move(to: U(0.44, 0.58)); ear.addCurve(to: U(0.45, 0.44), control1: U(0.36, 0.58), control2: U(0.36, 0.44))
        ctx.addPath(ear); ctx.strokePath()
        let eye = CGMutablePath()
        eye.move(to: U(0.665, 0.625)); eye.addQuadCurve(to: U(0.725, 0.618), control: U(0.70, 0.645))
        ctx.addPath(eye); ctx.strokePath()
        ctx.setStrokeColor(Palette.panelDark.withAlphaComponent(0.25).cgColor)
        let jl = CGMutablePath(); jl.move(to: U(0.50, 0.42)); jl.addQuadCurve(to: J(0.62, 0.27), control: J(0.53, 0.30))
        ctx.addPath(jl); ctx.strokePath()
        // Slices across the neck, like the Sunwave horizon cuts.
        ctx.setFillColor(Palette.panelDark.cgColor)
        for (i, y) in [0.055, 0.10].enumerated() {
            ctx.fill(NSRect(x: sq.minX + 0.28 * sq.width, y: sq.minY + CGFloat(y) * sq.height, width: 0.36 * sq.width, height: CGFloat(1.2 + Double(i) * 0.8)))
        }
    }
}

// MARK: - Voice strip: head + live signal + autotune readout
final class VBVoiceStrip: NSView {
    weak var audioUnit: VoiceBoxAudioUnit?
    private let kN = 40
    private let minF: Float = 60, maxF: Float = 16000
    private lazy var raw: [Float] = Array(repeating: -90, count: kN)
    private lazy var sm:  [Float] = Array(repeating: -90, count: kN)
    private lazy var hold: [Float] = Array(repeating: -90, count: kN)
    private var timer: Timer?
    private var open: CGFloat = 0           // smoothed mouth opening 0…1
    private var frameIdx = 0                // lip-sync frame with hysteresis
    private struct Ring { var r: CGFloat; let amp: CGFloat }
    private var rings: [Ring] = []
    private var sinceSpawn: CGFloat = 0
    private var meter = VBVoiceMeter(level: 0, midi: 0, targetMidi: -1, corrCents: 0, voiced: 0)
    private var shownMidi: Float = 0, shownTarget: Float = -1, shownCorr: Float = 0
    private var unvoicedFor: CGFloat = 1
    private var scaled: [CGImage] = []; private var scaledPx: Int = 0

    static let headSide: CGFloat = 128
    static let readoutW: CGFloat = 188

    override init(frame f: NSRect) {
        super.init(frame: f); wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    deinit { timer?.invalidate() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // passive display
    override var isOpaque: Bool { true }

    // ≤ 30 fps, and only while the editor is actually in a window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate(); timer = nil
        guard window != nil else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common); timer = t
    }

    private var headRect: NSRect { NSRect(x: bounds.minX, y: bounds.minY, width: min(Self.headSide, bounds.height), height: min(Self.headSide, bounds.height)) }
    private var readoutRect: NSRect { NSRect(x: bounds.maxX - Self.readoutW, y: bounds.minY, width: Self.readoutW, height: bounds.height) }

    private func tick() {
        let dt: CGFloat = 1.0 / 30.0
        if let au = audioUnit {
            au.readVoiceMeter(&meter)
            raw.withUnsafeMutableBufferPointer { p in if let b = p.baseAddress { _ = au.readSpectrumBands(b, count: Int32(kN)) } }
        }
        for i in 0..<kN {
            let t = raw[i], c = sm[i]; sm[i] = c + (t - c) * (t > c ? 0.5 : 0.2)
            hold[i] = max(sm[i], hold[i] - 0.6)
        }
        // Lip sync: output RMS in dB → opening, fast attack / slower release.
        let db = 20 * log10(max(1e-5, CGFloat(meter.level)))
        let target = max(0, min(1, (db + 46) / 34))
        open += (target - open) * (target > open ? 0.55 : 0.16)
        let want = open * CGFloat(VBHeadArt.frameCount - 1)
        if abs(want - CGFloat(frameIdx)) > 0.65 { frameIdx = max(0, min(VBHeadArt.frameCount - 1, Int(want.rounded()))) }
        // Breath arcs leave the mouth while there is sound.
        let maxR = bounds.width
        for i in rings.indices { rings[i].r += maxR * dt / 1.6 }
        rings.removeAll { $0.r > maxR }
        sinceSpawn += dt
        if open > 0.06 && sinceSpawn > 0.12 && rings.count < 14 { rings.append(Ring(r: 4, amp: open)); sinceSpawn = 0 }
        // Pitch readout — hold the last voiced value briefly so it doesn't flicker.
        if meter.voiced != 0 {
            unvoicedFor = 0
            shownMidi = meter.midi; shownTarget = meter.targetMidi
            shownCorr += (meter.corrCents - shownCorr) * 0.5
        } else { unvoicedFor += dt; shownCorr *= 0.7 }
        needsDisplay = true
    }

    /// Mouth centre in view coordinates.
    private func mouthPoint() -> NSPoint {
        let sq = headRect
        if VBHeadArt.frames != nil {
            let m = VBHeadArt.mouth[frameIdx], s = VBHeadArt.imageSize
            return NSPoint(x: sq.minX + m.x / s.width * sq.width, y: sq.maxY - m.y / s.height * sq.height)
        }
        let m = VBHeadVector.mouth(open)
        return NSPoint(x: sq.minX + m.x * sq.width, y: sq.minY + m.y * sq.height)
    }

    /// Head frames pre-scaled once to the on-screen pixel size (cheap blits).
    private func headImage() -> CGImage? {
        guard let fr = VBHeadArt.frames else { return nil }
        let px = Int(headRect.width * (window?.backingScaleFactor ?? 2))
        if px != scaledPx || scaled.count != fr.count {
            scaled = fr.compactMap { img in
                guard let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                c.interpolationQuality = .high
                c.draw(img, in: CGRect(x: 0, y: 0, width: px, height: px))
                return c.makeImage()
            }
            scaledPx = px
        }
        return frameIdx < scaled.count ? scaled[frameIdx] : nil
    }

    override func draw(_ r: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds
        ctx.setFillColor(Palette.panelDark.cgColor); ctx.fill(b)
        let ro = readoutRect
        let mouth = mouthPoint()
        let fieldX0 = mouth.x + 8, fieldX1 = ro.minX - 10
        let lab: [NSAttributedString.Key: Any] = [.font: Palette.printFont(7), .foregroundColor: Palette.inkMidL, .kern: 0.5]

        // ── Signal field ───────────────────────────────────────────────
        ctx.saveGState(); ctx.clip(to: NSRect(x: headRect.midX, y: b.minY, width: fieldX1 - headRect.midX + 4, height: b.height))
        // Breath arcs: wavefronts centred on the mouth, fading with distance.
        ctx.setLineCap(.round)
        let span = fieldX1 - mouth.x
        for ring in rings {
            let fade = max(0, 1 - ring.r / span)
            ctx.setStrokeColor(Palette.inkLight.withAlphaComponent(0.55 * fade * (0.35 + 0.65 * ring.amp)).cgColor)
            ctx.setLineWidth(0.8 + 1.4 * ring.amp * fade)
            ctx.addArc(center: mouth, radius: ring.r, startAngle: -0.55, endAngle: 0.55, clockwise: false)
            ctx.strokePath()
        }
        // Spectrum fanning out of the mouth: log-frequency along x, mirrored
        // bars around a centre line that drifts from the mouth to mid-strip,
        // inside a cone that widens with distance.
        let fx: (Float) -> CGFloat = { hz in fieldX0 + CGFloat((log(hz) - log(self.minF)) / (log(self.maxF) - log(self.minF))) * (fieldX1 - fieldX0) }
        let barW = max(2, (fieldX1 - fieldX0) / CGFloat(kN) * 0.52)
        func centre(_ x: CGFloat) -> (cy: CGFloat, cone: CGFloat) {
            let t = (x - mouth.x) / max(1, span)
            let cy = mouth.y + (b.midY - mouth.y) * min(1, t * 1.6)
            return (cy, 3 + t * (min(cy - b.minY, b.maxY - cy) - 12))
        }
        // Screen-printed guides, so the field reads even in silence: the cone
        // edges (dotted) and the 100 / 1k / 10k decade lines inside it.
        let top = CGMutablePath(), bot = CGMutablePath()
        for s in 0...32 {
            let x = fieldX0 + CGFloat(s) / 32 * (fieldX1 - fieldX0), c = centre(x)
            let pt = NSPoint(x: x, y: c.cy + c.cone + 2), pb = NSPoint(x: x, y: c.cy - c.cone - 2)
            if s == 0 { top.move(to: pt); bot.move(to: pb) } else { top.addLine(to: pt); bot.addLine(to: pb) }
        }
        ctx.setStrokeColor(Palette.inkMidL.withAlphaComponent(0.28).cgColor); ctx.setLineWidth(0.6)
        ctx.setLineDash(phase: 0, lengths: [1.5, 3])
        ctx.addPath(top); ctx.addPath(bot); ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setStrokeColor(Palette.inkMidL.withAlphaComponent(0.16).cgColor); ctx.setLineWidth(0.5)
        for hz in [100, 1000, 10000] as [Float] {
            let x = fx(hz), c = centre(x)
            ctx.move(to: NSPoint(x: x, y: c.cy - c.cone)); ctx.addLine(to: NSPoint(x: x, y: c.cy + c.cone))
        }
        ctx.strokePath()
        for i in 0..<kN {
            let hz = exp(log(minF) + Float(i) / Float(kN - 1) * (log(maxF) - log(minF)))
            let x = fx(hz)
            let t = (x - mouth.x) / max(1, span)
            let cy = mouth.y + (b.midY - mouth.y) * min(1, t * 1.6)
            let cone = 3 + t * (min(cy - b.minY, b.maxY - cy) - 12)
            let n = CGFloat(max(0, min(1, (sm[i] + 84) / 72)))
            if n < 0.02 {
                ctx.setFillColor(Palette.inkMidL.withAlphaComponent(0.35).cgColor)
                ctx.fill(NSRect(x: x - 0.5, y: cy - 0.5, width: 1, height: 1)); continue
            }
            let hh = max(1, cone * n)
            let bar = NSRect(x: x - barW * 0.5, y: cy - hh, width: barW, height: hh * 2)
            ctx.setFillColor(Palette.red.withAlphaComponent(0.55 + 0.4 * n).cgColor)
            ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barW * 0.5, cornerHeight: barW * 0.5, transform: nil)); ctx.fillPath()
            // Peak-hold ticks above and below.
            let hn = CGFloat(max(0, min(1, (hold[i] + 84) / 72))) * cone
            if hn > hh + 2 {
                ctx.setFillColor(Palette.cream.withAlphaComponent(0.55).cgColor)
                ctx.fill(NSRect(x: x - barW * 0.5, y: cy + hn, width: barW, height: 1))
                ctx.fill(NSRect(x: x - barW * 0.5, y: cy - hn - 1, width: barW, height: 1))
            }
        }
        ctx.restoreGState()
        // Axis + caption.
        NSString(string: "VOICE OUT · SPECTRUM").draw(at: NSPoint(x: headRect.maxX + 4, y: b.maxY - 13), withAttributes: lab)
        for (hz, t) in [(100, "100"), (1000, "1K"), (10000, "10K")] as [(Float, String)] {
            let s = NSString(string: t); let z = s.size(withAttributes: lab)
            s.draw(at: NSPoint(x: fx(hz) - z.width * 0.5, y: b.minY + 3), withAttributes: lab)
        }

        // ── Head (on top, so the signal leaves the lips) ───────────────
        if let img = headImage() { drawUpright(img, in: headRect, ctx: ctx) }
        else { VBHeadVector.draw(ctx, in: headRect.insetBy(dx: 4, dy: 2), open: open) }

        drawReadout(ctx, ro)
        ctx.setStrokeColor(Palette.inkLight.withAlphaComponent(0.5).cgColor); ctx.setLineWidth(0.5)
        ctx.stroke(b.insetBy(dx: 0.25, dy: 0.25))
    }

    private static let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    private func noteName(_ m: Int) -> String { Self.names[((m % 12) + 12) % 12] + "\(m / 12 - 1)" }

    private func drawReadout(_ ctx: CGContext, _ R: NSRect) {
        ctx.setFillColor(Palette.wellBg.cgColor); ctx.fill(R)
        ctx.setStrokeColor(Palette.inkLight.withAlphaComponent(0.25).cgColor); ctx.setLineWidth(0.5)
        ctx.move(to: NSPoint(x: R.minX, y: R.minY)); ctx.addLine(to: NSPoint(x: R.minX, y: R.maxY)); ctx.strokePath()
        let cap: [NSAttributedString.Key: Any] = [.font: Palette.printFont(7), .foregroundColor: Palette.inkMidL, .kern: 0.5]
        let tree = audioUnit?.parameterTree
        let tuneOn = (tree?.parameter(withAddress: 0)?.value ?? 0) > 0.5
        let scale = Int((tree?.parameter(withAddress: 22)?.value ?? 0).rounded())
        let key = Int((tree?.parameter(withAddress: 26)?.value ?? 0).rounded())
        let live = unvoicedFor < 0.35 && shownMidi > 1
        let x0 = R.minX + 12, x1 = R.maxX - 12
        NSString(string: "AUTOTUNE · PITCH").draw(at: NSPoint(x: x0, y: R.maxY - 13), withAttributes: cap)
        let mode = scale == 1 ? "\(Self.names[key]) MAJ" : scale == 2 ? "\(Self.names[key]) MIN" : "CHROM"
        let ms = NSString(string: tuneOn ? mode : "TUNE OFF"); let mz = ms.size(withAttributes: cap)
        ms.draw(at: NSPoint(x: x1 - mz.width, y: R.maxY - 13), withAttributes: cap)

        // IN note → OUT (target) note.
        let big = Palette.printFont(16)
        let inStr = live ? noteName(Int(shownMidi.rounded())) : "—"
        let tgt = Int(shownTarget)
        let outStr = (live && tgt >= 0) ? noteName(tgt) : "—"
        let ny = R.maxY - 56
        NSString(string: "IN").draw(at: NSPoint(x: x0, y: ny + 22), withAttributes: cap)
        NSString(string: inStr).draw(at: NSPoint(x: x0, y: ny), withAttributes: [.font: big, .foregroundColor: Palette.inkLight])
        let oc = (tuneOn && live) ? Palette.red : Palette.inkMidL
        let ox = R.midX + 14
        NSString(string: "OUT").draw(at: NSPoint(x: ox, y: ny + 22), withAttributes: cap)
        NSString(string: outStr).draw(at: NSPoint(x: ox, y: ny), withAttributes: [.font: big, .foregroundColor: oc])
        let arrow: [NSAttributedString.Key: Any] = [.font: Palette.printFont(11), .foregroundColor: Palette.inkMidL]
        NSString(string: "→").draw(at: NSPoint(x: R.midX - 10, y: ny + 2), withAttributes: arrow)
        let hz = live ? String(format: "%.1f HZ", 440 * pow(2, (shownMidi - 69) / 12)) : "NO VOICE"
        NSString(string: hz).draw(at: NSPoint(x: x0, y: ny - 12), withAttributes: cap)

        // Cents meter: needle = input vs target (±100 c), red = correction applied.
        let bar = NSRect(x: x0, y: R.minY + 22, width: x1 - x0, height: 9)
        ctx.setFillColor(Palette.panelDark.cgColor); ctx.fill(bar)
        ctx.setStrokeColor(Palette.inkLight.withAlphaComponent(0.6).cgColor); ctx.setLineWidth(0.8)
        for (i, c) in [-100, -50, 0, 50, 100].enumerated() {
            let x = bar.minX + CGFloat(c + 100) / 200 * bar.width
            let h: CGFloat = i == 2 ? 5 : 3
            ctx.move(to: NSPoint(x: x, y: bar.maxY)); ctx.addLine(to: NSPoint(x: x, y: bar.maxY + h))
        }
        ctx.strokePath()
        func cx(_ c: Float) -> CGFloat { bar.minX + CGFloat((max(-100, min(100, c)) + 100) / 200) * bar.width }
        var devText = "± 0 C"
        if live {
            let ref = tgt >= 0 ? Float(tgt) : shownMidi.rounded()
            let dev = (shownMidi - ref) * 100
            devText = String(format: "%+.0f C", dev)
            if tuneOn && abs(shownCorr) > 0.5 {
                let a = cx(dev), e = cx(dev + shownCorr)
                ctx.setFillColor(Palette.red.cgColor)
                ctx.fill(NSRect(x: min(a, e), y: bar.minY + 2, width: max(1, abs(e - a)), height: bar.height - 4))
            }
            ctx.setFillColor(Palette.inkLight.cgColor)
            ctx.fill(NSRect(x: cx(dev) - 1, y: bar.minY - 2, width: 2, height: bar.height + 4))
        }
        for (t, c) in [("−100", -100), ("0", 0), ("+100", 100)] as [(String, Int)] {
            let s = NSString(string: t); let z = s.size(withAttributes: cap)
            let x = min(max(bar.minX, bar.minX + CGFloat(c + 100) / 200 * bar.width - z.width * 0.5), bar.maxX - z.width)
            s.draw(at: NSPoint(x: x, y: R.minY + 8), withAttributes: cap)
        }
        let corrStr = (live && tuneOn) ? String(format: "IN %@ · CORR %+.0f C", devText, shownCorr) : (live ? "IN \(devText)" : "CENTS")
        NSString(string: corrStr).draw(at: NSPoint(x: x0, y: bar.maxY + 6), withAttributes: cap)
    }
}

// MARK: - Main view
final class VoiceBoxParameterView: NSView {
    var audioUnit: VoiceBoxAudioUnit? { didSet { rebind() } }
    private let cream = Palette.cream
    private let ink = Palette.inkLight
    private let mid = Palette.inkMidL
    private let red = Palette.red
    private let strip = VBVoiceStrip(frame: .zero)
    private let undoCtl = ParamUndo()
    private var knobs: [[KnobView]] = []      // per module, in `modules` order
    private var paramToken: AUParameterObserverToken?
    private var addrToModule: [AUParameterAddress: Int] = [:]
    private var lastPreset: Int = -1

    private enum Well { case none, low, vocoder, harmony, skip, delay, chop, reverb }
    private struct Mod {
        let name: String; let onAddr: AUParameterAddress
        let knobs: [(id: String, title: String)]
        var well: Well = .none
        var autoAddr: AUParameterAddress? = nil; var scaleAddr: AUParameterAddress? = nil; var keyAddr: AUParameterAddress? = nil
    }
    /// The DSP's real per-sample order (VoiceBoxEngine::processFrame).
    private let modules: [Mod] = [
        Mod(name: "AUTOTUNE",   onAddr: 0,  knobs: [("atSpeed", "RETUNE"), ("atHuman", "HUMANIZE"), ("atAmt", "AMOUNT")], scaleAddr: 22, keyAddr: 26),
        Mod(name: "LOW TUNER",  onAddr: 23, knobs: [("lwSemi", "SEMIS"), ("lwMix", "MIX")], well: .low),
        Mod(name: "VOCODER",    onAddr: 15, knobs: [("vcTone", "TONE"), ("vcMix", "MIX")], well: .vocoder),
        Mod(name: "HARMONIZER", onAddr: 3,  knobs: [("hmSemi", "SEMIS"), ("hmMix", "MIX")], well: .harmony, autoAddr: 21),
        Mod(name: "PITCH-SKIP", onAddr: 6,  knobs: [("skRate", "RATE"), ("skAmt", "AMOUNT")], well: .skip),
        Mod(name: "DELAY",      onAddr: 9,  knobs: [("dlTime", "TIME"), ("dlFb", "FEEDBACK")], well: .delay),
        Mod(name: "CHOP",       onAddr: 12, knobs: [("chRate", "RATE"), ("chDepth", "DEPTH")], well: .chop),
        Mod(name: "REVERB",     onAddr: 18, knobs: [("rvSize", "SIZE"), ("rvMix", "MIX")], well: .reverb),
    ]
    private static let keyNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    // Hit rects (filled by draw()).
    private var powerRects: [(NSRect, Int)] = []
    private var autoToggles: [(NSRect, AUParameterAddress)] = []
    private var scaleToggles: [(NSRect, AUParameterAddress)] = []
    private var keyToggles: [(NSRect, AUParameterAddress)] = []
    private var presetRects: [NSRect] = []

    // ── Grid (pt). Width: 4 cards × 226 + 3 × 8 + 2 × 16 = 960.
    //    Height: 42 bar + 8 + 128 strip + 8 + 2 × 112 cards + 8 + 42 footer zone = 460.
    static let preferredSize = NSSize(width: 960, height: 460)
    private let pad: CGFloat = 16, topBarH: CGFloat = 42, stripH: CGFloat = 128, gap: CGFloat = 8
    private let gridBottomY: CGFloat = 42          // footer hairline sits at 36
    private let cardW: CGFloat = 226, cardH: CGFloat = 112, cardGap: CGFloat = 8, cardPad: CGFloat = 8
    private let headerH: CGFloat = 24
    private let knobW: CGFloat = 66, knobH: CGFloat = 84, knobGap: CGFloat = 6

    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.backgroundColor = Palette.faceBg.cgColor
        addSubview(strip)
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    deinit { if let t = paramToken { audioUnit?.parameterTree?.removeParameterObserver(t) } }

    private var gridX0: CGFloat { floor((bounds.width - (cardW * 4 + cardGap * 3)) * 0.5) }
    private func cardRect(_ i: Int) -> NSRect {
        let row = i / 4, col = i % 4
        return NSRect(x: gridX0 + CGFloat(col) * (cardW + cardGap),
                      y: gridBottomY + CGFloat(1 - row) * (cardH + cardGap), width: cardW, height: cardH)
    }
    private func slotRect(_ card: NSRect, _ s: Int) -> NSRect {
        NSRect(x: card.minX + cardPad + CGFloat(s) * (knobW + knobGap), y: card.minY + 4, width: knobW, height: knobH)
    }
    private func value(_ a: AUParameterAddress) -> Float { audioUnit?.parameterTree?.parameter(withAddress: a)?.value ?? 0 }
    private func value(_ id: String) -> Float {
        audioUnit?.parameterTree?.allParameters.first(where: { $0.identifier == id })?.value ?? 0
    }
    private func isOn(_ i: Int) -> Bool { value(modules[i].onAddr) > 0.5 }

    override func layout() {
        super.layout()
        let b = bounds
        for i in modules.indices where i < knobs.count {
            let c = cardRect(i)
            let first = 3 - knobs[i].count
            for (k, kv) in knobs[i].enumerated() { kv.frame = slotRect(c, first + k) }
        }
        let gridTop = cardRect(0).maxY
        let w = cardW * 4 + cardGap * 3
        strip.frame = NSRect(x: gridX0, y: gridTop + gap, width: w, height: min(stripH, max(80, b.height - topBarH - gap - gridTop - gap)))
        updateDimming()
    }

    private func updateDimming() {
        for i in modules.indices where i < knobs.count {
            let a: CGFloat = isOn(i) ? 1.0 : 0.5
            knobs[i].forEach { $0.alphaValue = a }
        }
    }

    // MARK: Drawing
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds
        FaceTexture.draw(in: b, ctx: ctx)
        drawHeader(ctx, b)
        BrandStrip.drawFooter(ctx: ctx, bounds: b, plugin: "VOICE BOX", code: "VBX-1",
                              spec: "AU v3 · STEREO · 8 FX IN SERIES", pad: pad)
        drawModules(ctx)
    }

    private func key(_ ctx: CGContext, _ r: NSRect, _ label: String, lit: Bool, size: CGFloat = 9) {
        if !ButtonTex.draw(ctx, rect: r, active: lit, corner: 4) {
            ctx.setStrokeColor(ink.withAlphaComponent(0.6).cgColor); ctx.setLineWidth(0.8); ctx.stroke(r)
        }
        let a: [NSAttributedString.Key: Any] = [.font: Palette.printFont(size), .foregroundColor: lit ? cream : ink, .kern: 0.6]
        let s = NSString(string: label); let z = s.size(withAttributes: a)
        s.draw(at: NSPoint(x: r.midX - z.width * 0.5, y: r.midY - z.height * 0.5 + 0.5), withAttributes: a)
    }

    private func drawHeader(_ ctx: CGContext, _ b: NSRect) {
        let bar = NSRect(x: 0, y: b.height - topBarH, width: b.width, height: topBarH)
        ctx.setFillColor(Palette.wellBg.cgColor); ctx.fill(bar)
        ctx.setFillColor(red.cgColor); ctx.fill(NSRect(x: 0, y: bar.minY, width: bar.width, height: 2))
        let cy = bar.midY + 1
        // Title block: VOICE BOX (16) over PARADISE AUDIO · VBX-1 (7); logo centred on it.
        let tA: [NSAttributedString.Key: Any] = [.font: Palette.printFontCondensed(16), .foregroundColor: ink, .kern: 1.4]
        let sA: [NSAttributedString.Key: Any] = [.font: Palette.printFont(7), .foregroundColor: mid, .kern: 0.8]
        let title = NSString(string: "VOICE BOX"), sub = NSString(string: "PARADISE AUDIO · VBX-1")
        let tz = title.size(withAttributes: tA), sz = sub.size(withAttributes: sA)
        let blockH: CGFloat = 13 + 2 + 8
        BrandLogo.draw(in: NSRect(x: gridX0, y: cy - 15, width: 30, height: 30), ctx: ctx)
        let tx = gridX0 + 36
        title.draw(at: NSPoint(x: tx, y: cy + blockH * 0.5 - tz.height + 2), withAttributes: tA)
        sub.draw(at: NSPoint(x: tx, y: cy - blockH * 0.5 - 1), withAttributes: sA)
        let titleEnd = tx + max(tz.width, sz.width)

        // Undo / redo at the right edge of the grid.
        let rightPad = b.width - (gridX0 + cardW * 4 + cardGap * 3)
        undoCtl.draw(in: b, ctx: ctx, ink: ink, mid: mid, pad: rightPad, y: cy - 8)
        let undoX = b.width - rightPad - 58

        // PRESET caption + one row of ten rubber keys between title and undo.
        presetRects.removeAll()
        guard let au = audioUnit else { return }
        let cap: [NSAttributedString.Key: Any] = [.font: Palette.printFont(7), .foregroundColor: mid, .kern: 0.8]
        let pc = NSString(string: "PRESET"); let pz = pc.size(withAttributes: cap)
        let px0 = titleEnd + 26
        pc.draw(at: NSPoint(x: px0, y: cy - pz.height * 0.5), withAttributes: cap)
        let kx0 = px0 + pz.width + 8, kx1 = undoX - 18
        let n = Int(au.presetCount), kg: CGFloat = 4
        let kw = floor((kx1 - kx0 - kg * CGFloat(n - 1)) / CGFloat(max(1, n)))
        for i in 0..<n {
            let r = NSRect(x: kx0 + CGFloat(i) * (kw + kg), y: cy - 10, width: kw, height: 20)
            presetRects.append(r)
            key(ctx, r, au.presetName(Int32(i)), lit: i == lastPreset)
        }
    }

    private func drawModules(_ ctx: CGContext) {
        powerRects.removeAll(); autoToggles.removeAll(); scaleToggles.removeAll(); keyToggles.removeAll()
        let numA: [NSAttributedString.Key: Any] = [.font: Palette.printFont(9), .foregroundColor: Palette.wellBg]
        for (i, m) in modules.enumerated() {
            let c = cardRect(i)
            let on = isOn(i)
            // Card: flat recessed plate, hairline frame (no gradients).
            let card = CGPath(roundedRect: c, cornerWidth: 4, cornerHeight: 4, transform: nil)
            ctx.setFillColor(NSColor.black.withAlphaComponent(on ? 0.20 : 0.13).cgColor); ctx.addPath(card); ctx.fillPath()
            ctx.setStrokeColor(ink.withAlphaComponent(on ? 0.40 : 0.18).cgColor); ctx.setLineWidth(0.8); ctx.addPath(card); ctx.strokePath()

            // Header: chain number · name … mode keys · power key.
            let hy = c.maxY - headerH * 0.5
            let badge = NSRect(x: c.minX + cardPad, y: hy - 7, width: 14, height: 14)
            ctx.setFillColor((on ? ink : mid.withAlphaComponent(0.6)).cgColor); ctx.fillEllipse(in: badge)
            let ns = NSString(string: "\(i + 1)"); let nz = ns.size(withAttributes: numA)
            ns.draw(at: NSPoint(x: badge.midX - nz.width * 0.5, y: badge.midY - nz.height * 0.5 + 0.5), withAttributes: numA)
            let nameA: [NSAttributedString.Key: Any] = [.font: Palette.printFontCondensed(13), .foregroundColor: on ? ink : mid, .kern: 0.8]
            let nm = NSString(string: m.name); let nmz = nm.size(withAttributes: nameA)
            nm.draw(at: NSPoint(x: badge.maxX + 6, y: hy - nmz.height * 0.5 + 2), withAttributes: nameA)

            let pR = NSRect(x: c.maxX - cardPad - 34, y: hy - 8, width: 34, height: 16)
            key(ctx, pR, on ? "ON" : "OFF", lit: on, size: 7)
            // Whole header (name included) toggles power; mode keys are tested first.
            powerRects.append((NSRect(x: c.minX, y: c.maxY - headerH, width: c.width, height: headerH), i))
            var mx = pR.minX - 4
            if let kAddr = m.keyAddr {
                let k = Int(value(kAddr).rounded()), scl = Int(value(m.scaleAddr ?? 22).rounded())
                let r = NSRect(x: mx - 40, y: hy - 8, width: 40, height: 16)
                key(ctx, r, "KEY " + Self.keyNames[max(0, min(11, k))], lit: scl != 0, size: 7)
                keyToggles.append((r, kAddr)); mx = r.minX - 4
            }
            if let sAddr = m.scaleAddr {
                let scl = Int(value(sAddr).rounded())
                let r = NSRect(x: mx - 40, y: hy - 8, width: 40, height: 16)
                key(ctx, r, scl == 1 ? "MAJ" : scl == 2 ? "MIN" : "CHROM", lit: scl != 0, size: 7)
                scaleToggles.append((r, sAddr)); mx = r.minX - 4
            }
            if let aAddr = m.autoAddr {
                let r = NSRect(x: mx - 40, y: hy - 8, width: 40, height: 16)
                key(ctx, r, "AUTO", lit: value(aAddr) > 0.5, size: 7)
                autoToggles.append((r, aAddr)); mx = r.minX - 4
            }
            // Hairline under the header.
            ctx.setStrokeColor(ink.withAlphaComponent(0.12).cgColor); ctx.setLineWidth(0.5)
            ctx.move(to: NSPoint(x: c.minX + cardPad, y: c.maxY - headerH)); ctx.addLine(to: NSPoint(x: c.maxX - cardPad, y: c.maxY - headerH)); ctx.strokePath()

            // Picture well in the first column of two-knob cards.
            if m.well != .none {
                let s = slotRect(c, 0)
                let wr = NSRect(x: s.minX, y: s.minY - 2, width: s.width, height: s.height - 4)
                ctx.saveGState(); ctx.setAlpha(on ? 1 : 0.5)
                drawWell(ctx, m.well, wr)
                ctx.restoreGState()
            }
            // Chain arrow into the next card on the same row.
            if i % 4 != 3 {
                let ax = c.maxX + cardGap * 0.5
                ctx.setFillColor(mid.withAlphaComponent(0.8).cgColor)
                ctx.move(to: NSPoint(x: ax - 2, y: hy + 4)); ctx.addLine(to: NSPoint(x: ax + 2.5, y: hy)); ctx.addLine(to: NSPoint(x: ax - 2, y: hy - 4))
                ctx.closePath(); ctx.fillPath()
            }
        }
    }

    /// Musical name of an interval in semitones (caption text, not a duplicate of the knob value).
    private static func intervalName(_ st: Float) -> String {
        let n = Int(abs(st).rounded())
        let names = ["UNISON", "MIN 2ND", "MAJ 2ND", "MIN 3RD", "MAJ 3RD", "4TH", "TRITONE", "5TH", "MIN 6TH", "MAJ 6TH", "MIN 7TH", "MAJ 7TH", "OCTAVE"]
        let dir = st > 0.5 ? " ↑" : st < -0.5 ? " ↓" : ""
        if n <= 12 { return names[n] + dir }
        if n == 24 { return "2 OCT" + dir }
        return "OCT+" + names[n - 12] .replacingOccurrences(of: "MAJ ", with: "").replacingOccurrences(of: "MIN ", with: "") + dir
    }

    // Small param-driven pictures: what the module does to the voice.
    private func drawWell(_ ctx: CGContext, _ kind: Well, _ r: NSRect) {
        ctx.setFillColor(Palette.wellBg.cgColor); ctx.fill(r)
        ctx.setStrokeColor(ink.withAlphaComponent(0.35).cgColor); ctx.setLineWidth(0.5); ctx.stroke(r.insetBy(dx: 0.25, dy: 0.25))
        let cap: [NSAttributedString.Key: Any] = [.font: Palette.printFont(7), .foregroundColor: mid, .kern: 0.4]
        let g = NSRect(x: r.minX + 5, y: r.minY + 15, width: r.width - 10, height: r.height - 21)   // graph area
        func caption(_ s: String) {
            let t = NSString(string: s); let z = t.size(withAttributes: cap)
            t.draw(at: NSPoint(x: r.midX - z.width * 0.5, y: r.minY + 3), withAttributes: cap)
        }
        let redC = red.cgColor, inkC = ink.withAlphaComponent(0.7).cgColor
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        switch kind {
        case .low:
            let semi = CGFloat(value("lwSemi")), mix = CGFloat(value("lwMix"))
            ctx.setStrokeColor(ink.withAlphaComponent(0.25).cgColor); ctx.setLineWidth(0.5)
            for st in [0, -12, -24] as [CGFloat] { let y = g.maxY + st / 24 * g.height; ctx.move(to: NSPoint(x: g.minX, y: y)); ctx.addLine(to: NSPoint(x: g.maxX, y: y)) }
            ctx.strokePath()
            let y = g.maxY + semi / 24 * g.height
            ctx.setStrokeColor(inkC); ctx.setLineWidth(1.2); ctx.setLineDash(phase: 0, lengths: [2, 2])
            ctx.move(to: NSPoint(x: g.minX, y: g.maxY)); ctx.addLine(to: NSPoint(x: g.maxX, y: g.maxY)); ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.setStrokeColor(redC); ctx.setLineWidth(1.0 + 2.0 * mix)
            ctx.move(to: NSPoint(x: g.minX, y: y)); ctx.addLine(to: NSPoint(x: g.maxX, y: y)); ctx.strokePath()
            ctx.setStrokeColor(inkC); ctx.setLineWidth(1)
            ctx.move(to: NSPoint(x: g.midX, y: g.maxY - 2)); ctx.addLine(to: NSPoint(x: g.midX, y: y + 3))
            ctx.move(to: NSPoint(x: g.midX - 3, y: y + 6)); ctx.addLine(to: NSPoint(x: g.midX, y: y + 3)); ctx.addLine(to: NSPoint(x: g.midX + 3, y: y + 6))
            ctx.strokePath()
            caption(Self.intervalName(Float(semi)))
        case .vocoder:
            let tone = CGFloat(value("vcTone")), mix = CGFloat(value("vcMix"))
            let n = 16, bw = g.width / CGFloat(n)
            ctx.setFillColor(red.withAlphaComponent(0.45 + 0.55 * mix).cgColor)
            for i in 0..<n {
                let t = CGFloat(i) / CGFloat(n - 1)
                let formant = 0.35 + 0.65 * abs(sin(t * 5.6 + 0.7))
                let tilt = max(0.12, min(1, 0.75 + (tone - 0.5) * 1.3 * (t - 0.3)))
                let h = g.height * formant * tilt
                ctx.fill(NSRect(x: g.minX + CGFloat(i) * bw + 0.6, y: g.minY, width: bw - 1.2, height: h))
            }
            caption("16 BANDS")
        case .harmony:
            let semi = CGFloat(value("hmSemi")), auto = value("hmAuto") > 0.5, mix = CGFloat(value("hmMix"))
            let cy = g.midY
            ctx.setStrokeColor(ink.withAlphaComponent(0.25).cgColor); ctx.setLineWidth(0.5)
            for st in [-24, -12, 12, 24] as [CGFloat] { let y = cy + st / 24 * g.height * 0.5; ctx.move(to: NSPoint(x: g.minX, y: y)); ctx.addLine(to: NSPoint(x: g.maxX, y: y)) }
            ctx.strokePath()
            ctx.setStrokeColor(inkC); ctx.setLineWidth(1.2)
            ctx.move(to: NSPoint(x: g.minX, y: cy)); ctx.addLine(to: NSPoint(x: g.maxX, y: cy)); ctx.strokePath()
            ctx.setFillColor(ink.cgColor); ctx.fillEllipse(in: NSRect(x: g.minX + 8, y: cy - 3.5, width: 7, height: 7))
            let sts: [CGFloat] = auto ? [3, 4] : [semi]
            ctx.setFillColor(red.withAlphaComponent(0.5 + 0.5 * mix).cgColor)
            for st in sts {
                let y = cy + st / 24 * g.height * 0.5
                ctx.fillEllipse(in: NSRect(x: g.maxX - 16 - (st == 3 ? 10 : 0), y: y - 3.5, width: 7, height: 7))
            }
            caption(auto ? "IN-KEY 3RD" : Self.intervalName(Float(semi)))
        case .skip:
            let rate = CGFloat(value("skRate")), amt = CGFloat(value("skAmt"))
            let steps: [CGFloat] = [-12, -7, -5, 0, 5, 7, 12]
            let pattern = [5, 1, 6, 2, 4, 0, 3, 6, 1, 5, 2, 4, 0, 6, 3, 1]   // fixed, so the picture doesn't jump
            let n = max(1, Int(rate.rounded(.up)))
            let p = CGMutablePath()
            for k in 0..<n {
                let st = steps[pattern[k % pattern.count]] * amt
                let x0 = g.minX + CGFloat(k) / rate * g.width, x1 = min(g.maxX, g.minX + CGFloat(k + 1) / rate * g.width)
                let y = g.midY + st / 12 * g.height * 0.5
                if k == 0 { p.move(to: NSPoint(x: x0, y: y)) } else { p.addLine(to: NSPoint(x: x0, y: y)) }
                p.addLine(to: NSPoint(x: x1, y: y))
            }
            ctx.addPath(p); ctx.setStrokeColor(redC); ctx.setLineWidth(1.4); ctx.strokePath()
            caption(String(format: "JUMPS ±%.0f ST", 12 * amt))
        case .delay:
            let ms = CGFloat(value("dlTime")), fb = CGFloat(value("dlFb"))
            ctx.setStrokeColor(inkC); ctx.setLineWidth(1.4)
            ctx.move(to: NSPoint(x: g.minX + 1, y: g.minY)); ctx.addLine(to: NSPoint(x: g.minX + 1, y: g.maxY)); ctx.strokePath()
            ctx.setStrokeColor(redC)
            var a: CGFloat = 0.7, k: CGFloat = 1, echoes = 0
            while k * ms <= 1000 && a > 0.03 && k < 60 {
                let x = g.minX + 1 + k * ms / 1000 * (g.width - 2)
                ctx.move(to: NSPoint(x: x, y: g.minY)); ctx.addLine(to: NSPoint(x: x, y: g.minY + g.height * a))
                a *= fb; k += 1; echoes += 1
            }
            ctx.strokePath()
            caption(echoes == 1 ? "1 ECHO / S" : "\(echoes) ECHOES / S")
        case .chop:
            let rate = CGFloat(value("chRate")), depth = CGFloat(value("chDepth"))
            let lo = g.minY + g.height * (1 - depth) * 0.9, hi = g.minY + g.height * 0.9
            let p = CGMutablePath(); p.move(to: NSPoint(x: g.minX, y: hi))
            let cyc = max(0.1, rate)
            var t: CGFloat = 0
            while t < 1 {
                let xMid = g.minX + min(1, t + 0.5 / cyc) * g.width, xEnd = g.minX + min(1, t + 1 / cyc) * g.width
                p.addLine(to: NSPoint(x: xMid, y: hi)); if xMid < g.maxX { p.addLine(to: NSPoint(x: xMid, y: lo)) }
                p.addLine(to: NSPoint(x: xEnd, y: lo)); if xEnd < g.maxX { p.addLine(to: NSPoint(x: xEnd, y: hi)) }
                t += 1 / cyc
            }
            ctx.addPath(p); ctx.setStrokeColor(redC); ctx.setLineWidth(1.2); ctx.strokePath()
            caption(depth >= 0.995 ? "GATE −∞ DB" : String(format: "GATE %.0f DB", 20 * log10(1 - depth)))
        case .reverb:
            let size = CGFloat(value("rvSize")), mix = CGFloat(value("rvMix"))
            let fbk = 0.70 + size * 0.275
            let rt = -3 * 0.025 / log10(fbk)               // ≈ RT60 of the comb bank, seconds
            ctx.setStrokeColor(inkC); ctx.setLineWidth(1.4)
            ctx.move(to: NSPoint(x: g.minX + 1, y: g.minY)); ctx.addLine(to: NSPoint(x: g.minX + 1, y: g.maxY)); ctx.strokePath()
            let p = CGMutablePath(); p.move(to: NSPoint(x: g.minX + 3, y: g.minY))
            let window: CGFloat = 3.0
            for s in 0...24 {
                let t = CGFloat(s) / 24 * window
                let env = pow(10, -3 * t / rt)
                p.addLine(to: NSPoint(x: g.minX + 3 + CGFloat(s) / 24 * (g.width - 3), y: g.minY + g.height * (0.15 + 0.85 * mix) * env))
            }
            p.addLine(to: NSPoint(x: g.maxX, y: g.minY)); p.closeSubpath()
            ctx.addPath(p); ctx.setFillColor(red.withAlphaComponent(0.30).cgColor); ctx.fillPath()
            ctx.addPath(p); ctx.setStrokeColor(redC); ctx.setLineWidth(1.0); ctx.strokePath()
            caption(String(format: "RT %.1f S", rt))
        case .none: break
        }
    }

    // MARK: Mouse
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if undoCtl.handleClick(p) { lastPreset = -1; needsDisplay = true; return }
        for (i, r) in presetRects.enumerated() where r.contains(p) {
            audioUnit?.applyPreset(Int32(i)); lastPreset = i; needsDisplay = true; updateDimming(); return
        }
        for (r, addr) in autoToggles where r.contains(p) {
            if let prm = audioUnit?.parameterTree?.parameter(withAddress: addr) { prm.setValue(prm.value > 0.5 ? 0 : 1, originator: nil); needsDisplay = true }
            return
        }
        for (r, addr) in scaleToggles where r.contains(p) {
            if let prm = audioUnit?.parameterTree?.parameter(withAddress: addr) {
                prm.setValue(AUValue((Int(prm.value.rounded()) + 1) % 3), originator: nil); needsDisplay = true
            }
            return
        }
        // KEY: click = up a semitone, ⌥-click = down.
        for (r, addr) in keyToggles where r.contains(p) {
            if let prm = audioUnit?.parameterTree?.parameter(withAddress: addr) {
                let step = event.modifierFlags.contains(.option) ? 11 : 1
                prm.setValue(AUValue((Int(prm.value.rounded()) + step) % 12), originator: nil); needsDisplay = true
            }
            return
        }
        for (r, i) in powerRects where r.contains(p) {
            if let prm = audioUnit?.parameterTree?.parameter(withAddress: modules[i].onAddr) {
                prm.setValue(prm.value > 0.5 ? 0 : 1, originator: nil); updateDimming(); needsDisplay = true
            }
            return
        }
        super.mouseDown(with: event)
    }

    // MARK: Binding
    private func rebind() {
        knobs.joined().forEach { $0.removeFromSuperview() }; knobs.removeAll()
        addrToModule.removeAll()
        guard let au = audioUnit, let tree = au.parameterTree else { return }
        strip.audioUnit = au
        undoCtl.attach(au)
        undoCtl.onChange = { [weak self] in self?.updateDimming(); self?.needsDisplay = true }
        let byId: [String: AUParameter] = Dictionary(uniqueKeysWithValues: tree.allParameters.map { ($0.identifier, $0) })
        for (mi, m) in modules.enumerated() {
            addrToModule[m.onAddr] = mi
            for a in [m.autoAddr, m.scaleAddr, m.keyAddr].compactMap({ $0 }) { addrToModule[a] = mi }
            var row: [KnobView] = []
            for (id, title) in m.knobs {
                guard let prm = byId[id] else { continue }
                addrToModule[prm.address] = mi
                let k = KnobView(frame: .zero); k.bind(parameter: prm)
                k.title = title
                k.setAccessibilityLabel("\(m.name.capitalized) \(title.lowercased())")
                switch id {
                case "hmSemi", "lwSemi": k.displayFormatter = { String(format: "%+.0f st", $0) }
                case "dlTime": k.displayFormatter = { String(format: "%.0f ms", $0) }
                case "skRate", "chRate": k.displayFormatter = { String(format: "%.1f Hz", $0) }
                case "atSpeed":
                    // Retune time τ = 400^v − 1 ms (the DSP's mapping). Hero knob → red.
                    k.isAccent = true
                    k.displayFormatter = { v in
                        let ms = pow(400.0, Double(v)) - 1.0
                        return ms < 0.5 ? "HARD" : (ms < 10 ? String(format: "%.1f ms", ms) : String(format: "%.0f ms", ms))
                    }
                default: k.displayFormatter = { String(format: "%.0f%%", $0 * 100) }
                }
                addSubview(k); row.append(k)
            }
            knobs.append(row)
        }
        // Redraw just the affected card when any of its parameters moves
        // (automation, presets, undo) — pictures, power state and dimming follow.
        if let t = paramToken { tree.removeParameterObserver(t) }
        paramToken = tree.token(byAddingParameterObserver: { [weak self] addr, _ in
            DispatchQueue.main.async {
                guard let self = self, let mi = self.addrToModule[addr] else { return }
                if addr == self.modules[mi].onAddr { self.updateDimming() }
                self.setNeedsDisplay(self.cardRect(mi).insetBy(dx: -2, dy: -2))
            }
        })
        needsLayout = true; needsDisplay = true
    }
}
