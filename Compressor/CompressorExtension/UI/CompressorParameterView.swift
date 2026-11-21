//
//  CompressorParameterView.swift
//
//  Cream OP-1 surface. Live compression curve fills the upper portion,
//  six big knobs across the bottom, GR meter on the right.
//  Duck section (right of curve): duck icon toggle, rate readout (1-4 keys
//  set whole/half/quarter/eighth), and a small depth knob.
//

import AppKit
import AudioToolbox

final class CompressorParameterView: NSView {

    var audioUnit: CompressorAudioUnit? { didSet { rebind() } }

    // Dark faceplate, matching SynthThing (NOT the cream OP-1 scheme). The
    // light-on-dark inversion is the single biggest reason the two finally
    // read as the same instrument.
    private let cream     = Palette.cream                              // light accents / active text
    private let inkDark   = Palette.inkLight // light "ink" (inverted)
    private let inkMid    = Palette.inkMidL
    private let accentRed = Palette.accentRed
    private let faceBg    = Palette.faceBg // dark faceplate
    private let panelDark = Palette.panelDark // dark inset panels

    private var knobs: [KnobView] = []
    private let meter = GainReductionDisplay(frame: .zero)   // Meter | Graph widget
    private let curve = CompressionCurveView(frame: .zero)
    private let duckPanel = DuckPanel(frame: .zero)
    private var meterTimer: Timer?
    private let undoCtl = ParamUndo()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = faceBg.cgColor
        // GPU-accelerated CG rendering — see EZAudio benchmark.
        layer?.drawsAsynchronously = true
        addSubview(curve)
        addSubview(meter)
        addSubview(duckPanel)
        startMeterTimer()
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    deinit { meterTimer?.invalidate() }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func layout() {
        super.layout()
        // Faceplate convention (DESIGN.md §7): visualizers up top → controls
        // below → brand footer. Reworked from the old cramped 3-column grid
        // (stacked viz | dense duck | 2×3 knobs) into clean horizontal bands:
        //   1. Two matched line-graph panels side by side (curve | GR history)
        //   2. A single evenly-spaced knob bank (mirrors the synth)
        //   3. One full-width DUCK module
        //   4. Brand footer (drawn in draw())
        let pad: CGFloat     = 18
        let footerH: CGFloat = 34
        let topGap: CGFloat  = 50      // room for the dark top bar (42) + gap

        let contentX   = pad
        let contentW   = bounds.width - pad * 2
        let contentBot = footerH + 6
        let contentTop = bounds.height - topGap
        let contentH   = contentTop - contentBot

        let bandGap: CGFloat = 14
        let vizH:  CGFloat   = 196
        let knobH: CGFloat   = 96
        let duckH            = contentH - vizH - knobH - bandGap * 2   // taller duck strip → taller depth fader + rate buttons

        // ── Band 1 (top): matched visualizers, side by side, equal size ──
        let vizY   = contentTop - vizH
        let vizGap: CGFloat = 12
        let vizW   = (contentW - vizGap) * 0.5
        curve.frame = NSRect(x: contentX,                 y: vizY, width: vizW, height: vizH)
        meter.frame = NSRect(x: contentX + vizW + vizGap, y: vizY, width: vizW, height: vizH)

        // ── Band 2 (middle): single row of equal-size knobs ──
        let knobY = vizY - bandGap - knobH
        let n = max(1, knobs.count)
        let cellW = contentW / CGFloat(n)
        for (i, k) in knobs.enumerated() {
            let cx = contentX + cellW * (CGFloat(i) + 0.5)
            k.frame = NSRect(x: cx - cellW * 0.5, y: knobY, width: cellW, height: knobH)
        }

        // ── Band 3 (bottom): one full-width DUCK module ──
        let duckY = knobY - bandGap - duckH
        duckPanel.frame = NSRect(x: contentX, y: duckY, width: contentW, height: max(60, duckH))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Subtle brushed-aluminium faceplate (keeps panel colour, adds analogue grain).
        FaceTexture.draw(in: bounds, ctx: ctx)
        let b = bounds
        // (film-grain noise removed — 150k random fills per frame were clogging the UI)

        // ── Top transport-style bar (dark + red underline stripe) ────────
        // Ported from SynthThing's drawTopBar so the two share a silhouette.
        let topBarH: CGFloat = 42
        let bar = NSRect(x: 0, y: b.height - topBarH, width: b.width, height: topBarH)
        ctx.setFillColor(Palette.wellBg.cgColor); ctx.fill(bar)
        let cyT = bar.midY
        // brand: red square + PARADISE AUDIO
        ctx.setFillColor(accentRed.cgColor); BrandLogo.draw(in: NSRect(x: 13, y: cyT - 15, width: 30, height: 30), ctx: ctx)
        let brand: [NSAttributedString.Key: Any] = [.font: Palette.printFontCondensed(14), .foregroundColor: inkDark, .kern: 1.4]
        let brandS = NSString(string: "PARADISE AUDIO"); let brandZ = brandS.size(withAttributes: brand)
        brandS.draw(at: NSPoint(x: 48, y: cyT - brandZ.height * 0.5), withAttributes: brand)
        let code: [NSAttributedString.Key: Any] = [.font: Palette.printFont(9.5), .foregroundColor: inkMid, .kern: 0.6]
        let codeS = NSString(string: "COMPRESSOR · CMP-1"); let codeZ = codeS.size(withAttributes: code)
        codeS.draw(at: NSPoint(x: 48 + brandZ.width + 14, y: cyT - codeZ.height * 0.5), withAttributes: code)
        // live GR readout (right)
        let grv = max(0, audioUnit?.currentGainReductionDB ?? 0)
        let grStr = NSString(string: String(format: "GR  -%.1f dB", Double(grv)))
        let grAttr: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .heavy), .foregroundColor: accentRed]
        let grz = grStr.size(withAttributes: grAttr)
        grStr.draw(at: NSPoint(x: b.width - grz.width - 18, y: cyT - 7), withAttributes: grAttr)

        // Undo / redo buttons — in the top bar, left of the GR readout.
        undoCtl.draw(in: b, ctx: ctx, ink: inkDark, mid: inkMid, pad: grz.width + 32, y: cyT - 8)
        // SAVE / LOAD named presets — footer, clear of the brand block (left) and tag (right).

        // ── Footer (bottom-left brand block, light ink on dark) ──────────
        ctx.setFillColor(accentRed.cgColor); BrandLogo.draw(in: NSRect(x: 13, y: 2, width: 30, height: 30), ctx: ctx)
        let fBrand: [NSAttributedString.Key: Any] = [.font: Palette.printFontCondensed(11), .foregroundColor: inkDark, .kern: 1.2]
        NSString(string: "PARADISE AUDIO").draw(at: NSPoint(x: 47, y: 15), withAttributes: fBrand)
        let sub: [NSAttributedString.Key: Any] = [.font: Palette.printFont(7.5), .foregroundColor: inkMid, .kern: 0.6]
        NSString(string: "COMPRESSOR — CMP-1").draw(at: NSPoint(x: 47, y: 4), withAttributes: sub)
        let tag: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .regular), .foregroundColor: inkMid, .kern: 0.5]
        let tagStr = NSString(string: "AU v3 · STEREO · DUCK 1-4")
        let tw = tagStr.size(withAttributes: tag)
        tagStr.draw(at: NSPoint(x: b.width - tw.width - 18, y: 14), withAttributes: tag)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if undoCtl.handleClick(p) { needsDisplay = true; return }
        super.mouseDown(with: event)
    }

    private func rebind() {
        knobs.forEach { $0.removeFromSuperview() }
        knobs.removeAll()
        guard let au = audioUnit, let tree = au.parameterTree else { return }
        curve.audioUnit = au
        duckPanel.audioUnit = au
        undoCtl.attach(au)
        undoCtl.onChange = { [weak self] in self?.needsDisplay = true }
        for param in tree.allParameters {
            // Duck parameters are surfaced through DuckPanel, not the main knob row.
            if param.identifier == "duckOn" || param.identifier == "duckRate" || param.identifier == "duckDepth" || param.identifier == "duckAttack" { continue }
            let k = KnobView(frame: .zero)
            k.bind(parameter: param)
            switch param.identifier {
            case "threshold": k.displayFormatter = { String(format: "%.0f dB", $0) }
            case "ratio":     k.displayFormatter = { String(format: "%.1f:1", $0) }
            case "attack":    k.displayFormatter = { $0 < 10 ? String(format: "%.1fms", $0) : String(format: "%.0fms", $0) }
            case "release":   k.displayFormatter = { String(format: "%.0fms", $0) }
            case "knee":      k.displayFormatter = { String(format: "%.0f dB", $0) }
            case "mix":       k.displayFormatter = { String(format: "%.0f%%", $0 * 100) }
            default: break
            }
            addSubview(k)
            knobs.append(k)
        }
        // Bring knobs + duckPanel to front
        for k in knobs { k.removeFromSuperview(); addSubview(k) }
        duckPanel.removeFromSuperview(); addSubview(duckPanel)
        needsLayout = true
        needsDisplay = true
    }

    // ── Built-in drum factory presets ───────────────────────────────────
    // Parameter addresses (see CompressorAudioUnit.mm):
    //   0 threshold(dB) · 1 ratio(:1) · 2 attack(ms) · 3 release(ms)
    //   4 knee(dB) · 5 mix(0..1) · 6 duckOn(0/1)
    // The Duck (tempo-synced gimmick) is forced OFF in every preset so they're
    // pure compression starting points. Makeup is automatic (driven by
    // threshold + ratio in the DSP), so there's no makeup param to set.
    private static let drumPresets: [(name: String, values: [AUParameterAddress: Float])] = [
        // Gentle whole-kit bus glue: low ratio, slow-ish attack keeps transients,
        // medium release breathes with the groove, ~3–4 dB GR, soft knee.
        ("Drum Bus Glue",      [0: -20, 1: 2.0,  2: 30,  3: 180, 4: 10, 5: 1.0, 6: 0]),
        // Punchy kick/snare: medium attack lets the click through, fast release
        // for snap, 4:1 with a firmer knee for control.
        ("Punchy Kick/Snare",  [0: -24, 1: 4.0,  2: 18,  3: 60,  4: 4,  5: 1.0, 6: 0]),
        // Parallel smash: slam it (12:1, 1 ms attack, fast release, hard knee,
        // deep threshold) but blend ~40% under the dry kit for thickness.
        ("Parallel Smash",     [0: -40, 1: 12.0, 2: 1.0, 3: 40,  4: 2,  5: 0.4, 6: 0]),
        // Room crush: aggressive room-mic pump — instant attack, medium release,
        // 8:1, deep threshold for heavy GR, nearly full-wet.
        ("Room Crush",         [0: -32, 1: 8.0,  2: 0.5, 3: 120, 4: 3,  5: 0.9, 6: 0]),
        // Snare snap: slower attack preserves the crack, fast release, 5:1 for
        // an accentuated, lively snare.
        ("Snare Snap",         [0: -28, 1: 5.0,  2: 28,  3: 50,  4: 6,  5: 1.0, 6: 0]),
    ]

    private func startMeterTimer() {
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, let au = self.audioUnit else { return }
            self.meter.valueDB = au.currentGainReductionDB
        }
    }

    // ---- Keyboard shortcuts ----
    // 1-9: subdivisions + first set of grooves (1/1 ... TRAP)
    // 0, -, =: last three grooves (DUB, RAGGA, REGGAE)
    // D toggles duck on/off; T fires a manual hit.
    override func keyDown(with event: NSEvent) {
        guard let au = audioUnit else { super.keyDown(with: event); return }
        let chars = event.charactersIgnoringModifiers ?? ""
        if let n = Int(chars), n >= 1, n <= 9 {
            au.setDuckRate(Int32(n)); duckPanel.needsDisplay = true; return
        }
        switch chars {
        case "0": au.setDuckRate(10); duckPanel.needsDisplay = true; return
        case "-": au.setDuckRate(11); duckPanel.needsDisplay = true; return
        case "=": au.setDuckRate(12); duckPanel.needsDisplay = true; return
        case "d", "D":
            au.setDuckEnabled(!au.duckEnabled); duckPanel.needsDisplay = true; return
        case "t", "T":
            au.triggerDuck(); duckPanel.needsDisplay = true; return
        default: break
        }
        super.keyDown(with: event)
    }
}

// MARK: - DuckPanel

/// Full-width DUCK strip: duck-icon toggle, BPM readout, a tidy 6×2 rate grid,
/// a depth fader on the right, and an envelope meter along the bottom. Click
/// the duck to toggle, click a rate cell to set it, drag DEPTH, click BPM to
/// type. Keyboard 1-9/0/-/= on the main view also set the rate.
final class DuckPanel: NSView {
    weak var audioUnit: CompressorAudioUnit?

    // Dark-faceplate scheme (matches SynthThing): light ink on dark panels.
    private let cream   = Palette.cream
    private let inkDark = Palette.inkLight
    private let inkMid  = Palette.inkMidL
    private let red     = Palette.red
    private let panelBg = Palette.panelDark

    private var timer: Timer?
    private var depthDragY: CGFloat = 0
    private var depthDragV: Float = 0
    private var dragging = false
    // Duck ATTACK control (replaces the old BPM box).
    private var attackDragY: CGFloat = 0
    private var attackDragV: Float = 3
    private var draggingAttack = false
    private func attackParam() -> AUParameter? {
        audioUnit?.parameterTree?.allParameters.first { $0.identifier == "duckAttack" }
    }

    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        // GPU-accelerated CG rendering — see EZAudio benchmark.
        layer?.drawsAsynchronously = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in self?.needsDisplay = true }
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    deinit { timer?.invalidate() }

    // ── Layout regions (clean columns, no overlap) ──────────────────────
    // Left → right: duck icon · BPM + ON/OFF column · 6×2 rate grid · depth
    // fader. A thin envelope meter runs along the bottom. The previous version
    // stacked BPM directly over the grid's top row, which overlapped badly —
    // now BPM has its own column so nothing collides.
    private static let depthColW: CGFloat = 92
    private static let titleH:    CGFloat = 16
    private static let envH:      CGFloat = 20
    private static let envGap:    CGFloat = 8
    private static let bpmColW:   CGFloat = 124
    private static let iconMax:   CGFloat = 108

    /// Padded work area inside the rounded module plate.
    private func contentRect() -> NSRect { bounds.insetBy(dx: 2, dy: 2).insetBy(dx: 14, dy: 10) }

    private func titleRect() -> NSRect {
        let c = contentRect()
        return NSRect(x: c.minX, y: c.maxY - DuckPanel.titleH, width: c.width, height: DuckPanel.titleH)
    }
    /// Vertical extent of the central control band (between title and meter).
    private func mainBand() -> (top: CGFloat, bottom: CGFloat) {
        let c = contentRect()
        return (c.maxY - DuckPanel.titleH - 8, c.minY + DuckPanel.envH + DuckPanel.envGap)
    }
    private func depthRect() -> NSRect {
        // The depth column lives on the far right, where the title band is empty,
        // so the fader can run the FULL content height (title row included) — far
        // taller travel than the old mainBand-limited slot.
        let c = contentRect()
        let bottom = c.minY + DuckPanel.envH + DuckPanel.envGap
        let top    = c.maxY
        return NSRect(x: c.maxX - DuckPanel.depthColW, y: bottom,
                      width: DuckPanel.depthColW, height: top - bottom)
    }
    private func envMeterRect() -> NSRect {
        let c = contentRect()
        return NSRect(x: c.minX, y: c.minY, width: depthRect().minX - 14 - c.minX, height: DuckPanel.envH)
    }
    private func duckIconRect() -> NSRect {
        let c = contentRect()
        let m = mainBand()
        let h = m.top - m.bottom
        let s = min(DuckPanel.iconMax, h)
        return NSRect(x: c.minX, y: m.bottom + (h - s) * 0.5, width: s, height: s)
    }
    /// BPM readout — top of its own column, right of the icon.
    private func bpmRect() -> NSRect {
        let icon = duckIconRect()
        let m = mainBand()
        return NSRect(x: icon.maxX + 16, y: m.top - 28, width: DuckPanel.bpmColW, height: 28)
    }
    /// ON / OFF pill — bottom of the BPM column. Enlarged per feedback.
    private func duckToggleRect() -> NSRect {
        let icon = duckIconRect()
        let m = mainBand()
        return NSRect(x: icon.maxX + 16, y: m.bottom, width: DuckPanel.bpmColW, height: 40)
    }
    private func rateRects() -> [NSRect] {
        let m = mainBand()
        let left  = duckIconRect().maxX + 16 + DuckPanel.bpmColW + 18
        let right = depthRect().minX - 16
        let top    = m.top
        let bottom = m.bottom
        let cols = 6, rows = 2
        let gap: CGFloat = 5
        let gw = (right - left - CGFloat(cols - 1) * gap) / CGFloat(cols)
        let gh = (top - bottom - CGFloat(rows - 1) * gap) / CGFloat(rows)
        var rs: [NSRect] = []
        for row in 0..<rows {
            for col in 0..<cols {
                let x = left + CGFloat(col) * (gw + gap)
                let y = top - gh - CGFloat(row) * (gh + gap)   // row 0 on top
                rs.append(NSRect(x: x, y: y, width: gw, height: gh))
            }
        }
        return rs
    }
    // Shared depth-fader track — used by both draw and the drag handlers so
    // they can never drift (flat fader, room for label top + readout bottom).
    private func depthSlotRect() -> NSRect {
        let dr = depthRect()
        return NSRect(x: dr.midX - 11, y: dr.minY + 16, width: 22, height: dr.height - 30)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds.insetBy(dx: 2, dy: 2)

        // Two-tone panel — slight gradient so the duck section reads as a
        // separate "module" within the compressor. Looks lab-equipment-ish.
        // Sit the duck module in the same grey (panelBg ≈ 0.84) material family
        // as the left-hand visualizer panels, so it reads as one cohesive
        // surface instead of a brighter white block (color-balance pass).
        // Analog scheme: a flat recessed inset in the teal family (no gradient),
        // same material as the visualizer wells.
        ctx.saveGState()
        let panelPath = CGPath(roundedRect: b, cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.addPath(panelPath); ctx.clip()
        ctx.setFillColor(Palette.panelDark.cgColor); ctx.fill(b)
        PanelTex.draw(in: b, ctx: ctx, alpha: 0.25)
        ctx.restoreGState()
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.6).cgColor); ctx.setLineWidth(0.6)
        ctx.addPath(panelPath); ctx.strokePath()

        // ── Title strip ───────────────────────────────────────────────
        let title: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .heavy),
            .foregroundColor: inkDark, .kern: 1.6
        ]
        let tr = titleRect()
        NSString(string: "DUCK").draw(at: NSPoint(x: tr.minX, y: tr.midY - 5), withAttributes: title)
        // Indicator dot, just to the right of the title text
        ctx.setFillColor((audioUnit?.duckEnabled == true ? red : inkMid).cgColor)
        ctx.fill(NSRect(x: tr.minX + 34, y: tr.midY - 2, width: 5, height: 5))

        // ── Duck icon + status ───────────────────────────────────────
        let on = audioUnit?.duckEnabled ?? false
        drawDuck(ctx, in: duckIconRect(), filled: on)

        // ── ATTACK control (replaces the old BPM box) ────────────────
        // The duck is always locked to the host tempo, so a BPM field was
        // redundant. This box now sets the duck's de-click ATTACK (drag ↕).
        // Flat recessed readout (NOT a raised 3D button) so it no longer reads
        // as a stray button stuck above DUCK OFF — it's a labelled drag field.
        let br = bpmRect()
        let bp = CGPath(roundedRect: br, cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.18).cgColor)
        ctx.addPath(bp); ctx.fillPath()
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.22).cgColor); ctx.setLineWidth(0.5); ctx.addPath(bp); ctx.strokePath()
        let atkMs = attackParam()?.value ?? 3.0
        let capAttr: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .heavy), .foregroundColor: inkDark, .kern: 0.8]
        NSString(string: "ATTACK").draw(at: NSPoint(x: br.minX + 9, y: br.midY - 5), withAttributes: capAttr)
        let valAttr: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .heavy), .foregroundColor: red, .kern: 0.4]
        let vs = NSString(string: String(format: "%.1f ms", Double(atkMs)))
        let vsz = vs.size(withAttributes: valAttr)
        vs.draw(at: NSPoint(x: br.maxX - vsz.width - 9, y: br.midY - 6), withAttributes: valAttr)

        // ── DUCK ON / OFF pill (under the BPM readout) ───────────────
        let tgl = duckToggleRect()
        if !ButtonTex.draw(ctx, rect: tgl, active: on, corner: 4) {
            let tglPath = CGPath(roundedRect: tgl, cornerWidth: 4, cornerHeight: 4, transform: nil)
            if on {
                ctx.setFillColor(red.cgColor); ctx.addPath(tglPath); ctx.fillPath()
            } else {
                ctx.setStrokeColor(inkDark.withAlphaComponent(0.5).cgColor); ctx.setLineWidth(0.8)
                ctx.addPath(tglPath); ctx.strokePath()
            }
        }
        let tglAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: on ? .heavy : .bold),
            .foregroundColor: on ? cream : inkDark, .kern: 1.0
        ]
        let tglStr = NSString(string: on ? "DUCK ON" : "DUCK OFF")
        let tglz = tglStr.size(withAttributes: tglAttr)
        tglStr.draw(at: NSPoint(x: tgl.midX - tglz.width * 0.5, y: tgl.midY - tglz.height * 0.5 - 1), withAttributes: tglAttr)

        // ── 12-pattern grid ──────────────────────────────────────────
        // Subdivisions on top row (1/1 1/2 1/4 1/8), then a row of straight
        // grooves (1/16 DotQ SWING HOUSE), then genre grooves (TRAP DUB
        // RAGGA REGGAE). Selected pattern is solid red.
        let rate = Int(audioUnit?.duckRate ?? 3)
        let labels = [
            "1/1", "1/2", "1/4", "1/8",
            "1/16", "DOT Q", "SWING", "HOUSE",
            "TRAP", "DUB", "RAGGA", "REGGAE"
        ]
        for (i, r) in rateRects().enumerated() {
            let isSel = (i + 1) == rate
            if !ButtonTex.draw(ctx, rect: r, active: isSel, corner: 4) {
                let cellPath = CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil)
                ctx.setFillColor((isSel ? red : NSColor.white.withAlphaComponent(0.10)).cgColor)
                ctx.addPath(cellPath); ctx.fillPath()
                ctx.setStrokeColor((isSel ? red : inkDark.withAlphaComponent(0.30)).cgColor)
                ctx.setLineWidth(isSel ? 1.0 : 0.6)
                ctx.addPath(cellPath); ctx.strokePath()
            }
            let sa: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .heavy),
                .foregroundColor: isSel ? Palette.cream : inkDark,
                .kern: 0.5
            ]
            let s = NSString(string: labels[i])
            let sz = s.size(withAttributes: sa)
            s.draw(at: NSPoint(x: r.midX - sz.width * 0.5, y: r.midY - sz.height * 0.5), withAttributes: sa)
        }

        // ── Envelope / phase meter (under the grid) — flat light track ──
        let er = envMeterRect()
        let erPath = CGPath(roundedRect: er, cornerWidth: 2, cornerHeight: 2, transform: nil)
        ctx.setFillColor(inkDark.withAlphaComponent(0.10).cgColor); ctx.addPath(erPath); ctx.fillPath()
        let env = audioUnit?.currentDuckDB ?? 0
        let frac = min(36.0, env) / 36.0
        ctx.setFillColor(red.withAlphaComponent(0.85).cgColor)
        ctx.fill(NSRect(x: er.minX, y: er.minY, width: er.width * CGFloat(frac), height: er.height))
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.25).cgColor); ctx.setLineWidth(0.5); ctx.addPath(erPath); ctx.strokePath()
        // Phase tick across the meter
        let phase = audioUnit?.duckPhase ?? 0
        let px = er.minX + er.width * CGFloat(phase)
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.7).cgColor); ctx.setLineWidth(1.0)
        ctx.move(to: NSPoint(x: px, y: er.minY)); ctx.addLine(to: NSPoint(x: px, y: er.maxY)); ctx.strokePath()

        // ── DEPTH fader (right column) — flat OP-1, not a black chrome slab ─
        let dr = depthRect()
        let slot = depthSlotRect()
        let depth = audioUnit?.duckDepthDB ?? 9.0
        let depthFrac = CGFloat(min(36.0, max(0.0, depth)) / 36.0)
        let fillH = slot.height * depthFrac

        // "DEPTH" label (ink) at the top of the column.
        let lblTop: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .heavy),
            .foregroundColor: inkMid, .kern: 0.8
        ]
        let lt = NSString(string: "DEPTH"); let ltsz = lt.size(withAttributes: lblTop)
        lt.draw(at: NSPoint(x: dr.midX - ltsz.width * 0.5, y: dr.maxY - 14), withAttributes: lblTop)

        // Recessed flat track.
        let slotPath = CGPath(roundedRect: slot, cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.setFillColor(inkDark.withAlphaComponent(0.14).cgColor); ctx.addPath(slotPath); ctx.fillPath()
        // Subtle ticks.
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.25).cgColor); ctx.setLineWidth(0.5)
        for i in 0...6 {
            let y = slot.minY + CGFloat(i) / 6 * slot.height
            let tl: CGFloat = (i % 3 == 0) ? 4 : 2
            ctx.move(to: NSPoint(x: slot.minX - tl - 2, y: y)); ctx.addLine(to: NSPoint(x: slot.minX - 2, y: y))
            ctx.move(to: NSPoint(x: slot.maxX + 2, y: y)); ctx.addLine(to: NSPoint(x: slot.maxX + tl + 2, y: y))
        }
        ctx.strokePath()
        // Red fill from bottom to value.
        ctx.saveGState(); ctx.addPath(slotPath); ctx.clip()
        ctx.setFillColor(red.cgColor)
        ctx.fill(NSRect(x: slot.minX, y: slot.minY, width: slot.width, height: max(0, fillH)))
        ctx.restoreGState()
        // Flat thumb — clean ink bar with a red centre line.
        let thumbY = slot.minY + fillH
        let thumb = NSRect(x: dr.midX - 28, y: thumbY - 12, width: 56, height: 24)
        if !ButtonTex.draw(ctx, rect: thumb, active: false, corner: 4) {
            let thumbPath = CGPath(roundedRect: thumb, cornerWidth: 4, cornerHeight: 4, transform: nil)
            ctx.setFillColor(inkDark.cgColor); ctx.addPath(thumbPath); ctx.fillPath()
        }
        ctx.setStrokeColor(red.cgColor); ctx.setLineWidth(1.5)
        ctx.move(to: NSPoint(x: thumb.minX + 4, y: thumb.midY)); ctx.addLine(to: NSPoint(x: thumb.maxX - 4, y: thumb.midY)); ctx.strokePath()
        // dB readout (red) at the bottom.
        let lblBot: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .heavy),
            .foregroundColor: red, .kern: 0.3
        ]
        let lb = NSString(string: String(format: "%.0f dB", Double(depth)))
        let lbsz = lb.size(withAttributes: lblBot)
        lb.draw(at: NSPoint(x: dr.midX - lbsz.width * 0.5, y: dr.minY + 2), withAttributes: lblBot)

        // ── Hint (right of the title, on the title row) ───────────────
        let hint: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .regular), .foregroundColor: inkMid, .kern: 0.4]
        let hintStr = NSString(string: "CLICK DUCK · DRAG ATTACK · DRAG DEPTH")
        let hsz = hintStr.size(withAttributes: hint)
        // Left-aligned after the DUCK title so it never runs into the DEPTH column.
        _ = hsz
        hintStr.draw(at: NSPoint(x: tr.minX + 90, y: tr.midY - 4), withAttributes: hint)
    }

    /// The DUCK mascot — Nicky's "cool duck" artwork (cap + sunglasses),
    /// embedded via `DuckArt` and drawn on a near-black rounded plate so the
    /// PNG's black field is seamless on the dark faceplate. Plate gains a red
    /// border + glow when the duck is ON; pump rings ripple from the base on
    /// every trigger.
    private func drawDuck(_ ctx: CGContext, in rect: NSRect, filled: Bool) {
        let plate = rect.insetBy(dx: 2, dy: 2)
        let path = CGPath(roundedRect: plate, cornerWidth: 8, cornerHeight: 8, transform: nil)

        // Plate — near-black so the artwork's black background disappears.
        ctx.setFillColor(NSColor(calibratedWhite: 0.04, alpha: 1.0).cgColor)
        ctx.addPath(path); ctx.fillPath()

        // The duck artwork, clipped to the rounded plate, aspect-fit + centred.
        if let img = DuckArt.image {
            ctx.saveGState()
            ctx.addPath(path); ctx.clip()
            let inset = plate.insetBy(dx: 4, dy: 4)
            let s = min(inset.width, inset.height)
            let dst = NSRect(x: inset.midX - s * 0.5, y: inset.midY - s * 0.5, width: s, height: s)
            img.draw(in: dst, from: .zero, operation: .sourceOver, fraction: 1.0)
            ctx.restoreGState()
        }

        // Border / glow signals the ON state (the raster itself doesn't recolour).
        if filled {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 9, color: red.withAlphaComponent(0.7).cgColor)
            ctx.setStrokeColor(red.cgColor); ctx.setLineWidth(2.0)
            ctx.addPath(path); ctx.strokePath()
            ctx.restoreGState()
        } else {
            ctx.setStrokeColor(inkDark.withAlphaComponent(0.45).cgColor); ctx.setLineWidth(1.0)
            ctx.addPath(path); ctx.strokePath()
        }

        // Live pump rings from the base on every duck trigger.
        let envDB = audioUnit?.currentDuckDB ?? 0
        let pumpAmt = min(1.0, max(0.0, Double(envDB) / 12.0))
        if pumpAmt > 0.05 {
            ctx.saveGState()
            ctx.addPath(path); ctx.clip()
            let cxR = plate.midX
            let cyR = plate.minY + plate.height * 0.22
            for i in 0..<3 {
                let phase = max(0.0, pumpAmt - CGFloat(i) * 0.18)
                if phase <= 0 { continue }
                let radius: CGFloat = 8 + CGFloat(i) * 5 + phase * 5
                ctx.setStrokeColor(red.withAlphaComponent(phase * 0.6).cgColor)
                ctx.setLineWidth(1.2)
                ctx.strokeEllipse(in: NSRect(x: cxR - radius, y: cyR - radius * 0.35, width: radius * 2, height: radius * 0.7))
            }
            ctx.restoreGState()
        }
    }

    // MARK: - Mouse
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let au = audioUnit else { return }

        // Duck icon toggle (and the ON/OFF pill)
        if duckIconRect().contains(p) || duckToggleRect().contains(p) {
            au.setDuckEnabled(!au.duckEnabled); needsDisplay = true; return
        }
        // ATTACK box — vertical drag to set the duck de-click attack (ms).
        if bpmRect().contains(p) {
            attackDragY = p.y; attackDragV = attackParam()?.value ?? 3.0; draggingAttack = true
            return
        }
        // Rate cells (12 patterns)
        for (i, r) in rateRects().enumerated() where r.contains(p) {
            au.setDuckRate(Int32(i + 1)); needsDisplay = true; return
        }
        // DEPTH slider — vertical drag along the right column.
        // Click sets the value at the y-position; drag continues from there.
        if depthRect().contains(p) {
            depthDragY = p.y; depthDragV = au.duckDepthDB; dragging = true
            let slot = depthSlotRect()
            let frac = max(0.0, min(1.0, (p.y - slot.minY) / slot.height))
            au.setDuckDepthDB(Float(frac) * Float(36))
            needsDisplay = true
            return
        }
        window?.makeFirstResponder(superview)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if draggingAttack {
            let nv = max(0.1, min(50.0, attackDragV + Float(p.y - attackDragY) * 0.3))
            attackParam()?.setValue(nv, originator: nil); needsDisplay = true; return
        }
        guard dragging, let au = audioUnit else { return }
        let slot = depthSlotRect()
        let frac = max(0.0, min(1.0, (p.y - slot.minY) / slot.height))
        au.setDuckDepthDB(Float(frac) * Float(36))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { dragging = false; draggingAttack = false }

    private func presentBPMTypeInput() {
        guard let au = audioUnit else { return }
        let alert = NSAlert()
        alert.messageText = "Set Duck BPM"
        alert.informativeText = "Tempo the duck pumps at (20..300)."
        alert.alertStyle = .informational
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.stringValue = String(format: "%.0f", au.duckBPM)
        field.alignment = .center
        alert.accessoryView = field
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            if let v = Float(field.stringValue.replacingOccurrences(of: ",", with: ".")) {
                au.setDuckBPM(max(20, min(300, v)))
                needsDisplay = true
            }
        }
    }
}
