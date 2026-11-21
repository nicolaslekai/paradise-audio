//
//  RoarBassParameterView.swift
//  RoarBassExtension
//
//  2026-11-21 redesign (Nicky: "give it some visualizer … let's have red knobs on it too").
//  Top bar · a row of three displays (live output scope, ladder filter curve, both envelopes)
//  · two knob rows justified to the full width · standard footer. GROWL and CUTOFF are the red
//  accent knobs: the two controls that make the roar.
//

import AppKit
import AudioToolbox

final class RoarBassParameterView: NSView {

    private var knobs: [KnobView] = []
    private weak var au: AUAudioUnit?
    private let undoCtl = ParamUndo()
    private let scope = RoarScopeView(frame: .zero)
    private var treeToken: AUParameterObserverToken?
    private let ink = Palette.inkLight
    private let mid = Palette.inkMidL

    // Geometry (flipped: y grows downward).
    static let size = NSSize(width: 1000, height: 500)
    private let pad: CGFloat = 18, gap: CGFloat = 8
    private let barH: CGFloat = 42
    private let vizY: CGFloat = 52, vizH: CGFloat = 138
    private let row1Y: CGFloat = 200, row2Y: CGFloat = 326
    private let knobW: CGFloat = 60, knobH: CGFloat = 86, secPad: CGFloat = 8, secTitleH: CGFloat = 24

    private struct Section { let title: String; let groupId: String; let paramIds: [String] }
    private let row1: [Section] = [
        Section(title: "OSCILLATORS", groupId: "osc",   paramIds: ["osc1Oct", "osc2Oct", "osc2Det", "oscMix", "sub"]),
        Section(title: "FM GROWL",    groupId: "fm",    paramIds: ["fmAmt", "fmRatio", "fmFb"]),
        Section(title: "NOISE",       groupId: "noise", paramIds: ["nz", "nzColor"]),
        Section(title: "FILTER",      groupId: "flt",   paramIds: ["cut", "res", "drv", "fEnv"]),
    ]
    private let row2: [Section] = [
        Section(title: "AMP ENV",     groupId: "ampe",  paramIds: ["aA", "aD", "aS", "aR"]),
        Section(title: "FILTER ENV",  groupId: "flte",  paramIds: ["fA", "fD", "fS", "fR"]),
        Section(title: "GLOBAL",      groupId: "glob",  paramIds: ["glide", "vmode", "mg", "dOut"]),
    ]
    private static let accentIds: Set<String> = ["fmAmt", "cut"]
    private var sectionRects: [(String, NSRect)] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Palette.faceBg.cgColor
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    deinit { if let t = treeToken { au?.parameterTree?.removeParameterObserver(t) } }

    override var isFlipped: Bool { true }

    func bind(to audioUnit: AUAudioUnit) {
        if let t = treeToken { au?.parameterTree?.removeParameterObserver(t); treeToken = nil }
        self.au = audioUnit
        subviews.forEach { $0.removeFromSuperview() }
        knobs.removeAll()
        guard let tree = audioUnit.parameterTree else { return }
        undoCtl.attach(audioUnit)
        undoCtl.onChange = { [weak self] in self?.needsDisplay = true }
        layoutSections(with: tree)
        scope.audioUnit = audioUnit as? RoarBassAudioUnit
        scope.paramValue = { [weak tree] id in tree?.allParameters.first { $0.identifier == id }.map { Float($0.value) } ?? 0 }
        scope.frame = displayRects().scope
        addSubview(scope)
        // Filter curve, envelopes and the idle scope picture follow every parameter move.
        treeToken = tree.token(byAddingParameterObserver: { [weak self] _, _ in
            DispatchQueue.main.async { self?.needsDisplay = true; self?.scope.needsDisplay = true }
        })
        needsDisplay = true
    }

    private func value(_ id: String) -> Float {
        Float(au?.parameterTree?.allParameters.first { $0.identifier == id }?.value ?? 0)
    }

    // MARK: Layout

    private func displayRects() -> (scope: NSRect, filter: NSRect, env: NSRect) {
        let w = bounds.width - pad * 2 - gap * 2
        let sw = (w * 0.48).rounded(), fw = (w * 0.27).rounded(), ew = w - sw - fw
        let s = NSRect(x: pad, y: vizY, width: sw, height: vizH)
        let f = NSRect(x: s.maxX + gap, y: vizY, width: fw, height: vizH)
        let e = NSRect(x: f.maxX + gap, y: vizY, width: ew, height: vizH)
        return (s, f, e)
    }

    private func layoutSections(with tree: AUParameterTree) {
        var groups: [String: AUParameterGroup] = [:]
        for child in tree.children { if let g = child as? AUParameterGroup { groups[g.identifier] = g } }
        sectionRects.removeAll()
        for (rowY, row) in [(row1Y, row1), (row2Y, row2)] {
            // Natural widths, then the spare width shared out so every row runs edge to edge.
            let natural = row.map { CGFloat($0.paramIds.count) * knobW + CGFloat($0.paramIds.count - 1) * 4 + secPad * 2 }
            let avail = bounds.width - pad * 2 - gap * CGFloat(row.count - 1)
            let extra = max(0, avail - natural.reduce(0, +))
            let total = natural.reduce(0, +)
            var x = pad
            for (i, sec) in row.enumerated() {
                let w = (natural[i] + extra * natural[i] / total).rounded()
                let r = NSRect(x: x, y: rowY, width: i == row.count - 1 ? bounds.width - pad - x : w, height: secTitleH + knobH + secPad)
                sectionRects.append((sec.title, r))
                if let g = groups[sec.groupId] {
                    let pm = Dictionary(uniqueKeysWithValues: g.allParameters.map { ($0.identifier, $0) })
                    let cellW = (r.width - secPad * 2) / CGFloat(sec.paramIds.count)
                    for (j, pid) in sec.paramIds.enumerated() {
                        guard let p = pm[pid] else { continue }
                        let cx = r.minX + secPad + cellW * (CGFloat(j) + 0.5)
                        let k = KnobView(frame: NSRect(x: (cx - knobW * 0.5).rounded(), y: r.minY + secTitleH - 4, width: knobW, height: knobH))
                        k.bind(parameter: p)
                        if let short = Self.shortLabels[pid] { k.title = short }
                        if Self.accentIds.contains(pid) { k.isAccent = true; k.isOutput = false }
                        attachFormatter(knob: k, parameter: p)
                        addSubview(k); knobs.append(k)
                    }
                }
                x = r.maxX + gap
            }
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        FaceTexture.draw(in: bounds, ctx: ctx)
        drawTopBar(ctx)
        for (title, r) in sectionRects { drawSection(ctx, r, title) }
        let d = displayRects()
        drawFilter(ctx, d.filter)
        drawEnvelopes(ctx, d.env)
        drawFooter(ctx, bounds)
    }

    private func drawTopBar(_ ctx: CGContext) {
        let bar = NSRect(x: 0, y: 0, width: bounds.width, height: barH)
        ctx.setFillColor(Palette.wellBg.cgColor); ctx.fill(bar)
        ctx.setFillColor(Palette.red.cgColor); ctx.fill(NSRect(x: 0, y: barH - 2, width: bounds.width, height: 2))
        let t: [NSAttributedString.Key: Any] = [.font: Palette.printFontCondensed(20), .foregroundColor: ink, .kern: 1.6]
        let ts = NSString(string: "ROAR BASS"); let tz = ts.size(withAttributes: t)
        ts.draw(at: NSPoint(x: pad, y: (barH - 2 - tz.height) * 0.5 + 1), withAttributes: t)
        let s: [NSAttributedString.Key: Any] = [.font: Palette.printFont(9), .foregroundColor: mid, .kern: 0.8]
        let ss = NSString(string: "DEEP · FM GROWL · LADDER FILTER"); let sz = ss.size(withAttributes: s)
        ss.draw(at: NSPoint(x: pad + tz.width + 14, y: (barH - 2 - sz.height) * 0.5 + 1), withAttributes: s)
        undoCtl.draw(in: bounds, ctx: ctx, ink: ink, mid: mid, pad: pad, y: (barH - 2 - 16) * 0.5)
    }

    private func drawSection(_ ctx: CGContext, _ r: NSRect, _ title: String) {
        let path = CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.setFillColor(Palette.panelDark.cgColor); ctx.addPath(path); ctx.fillPath()
        ctx.setStrokeColor(ink.withAlphaComponent(0.22).cgColor); ctx.setLineWidth(0.5); ctx.addPath(path); ctx.strokePath()
        let a: [NSAttributedString.Key: Any] = [.font: Palette.printFontCondensed(12), .foregroundColor: mid, .kern: 0.8]
        NSString(string: title).draw(at: NSPoint(x: r.minX + secPad, y: r.minY + 5), withAttributes: a)
    }

    /// Recessed display well with a header line, shared by the three displays.
    static func drawWell(_ ctx: CGContext, _ r: NSRect, title: String, readout: String?) {
        let path = CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.setFillColor(Palette.wellBg.cgColor); ctx.addPath(path); ctx.fillPath()
        ctx.setStrokeColor(Palette.inkLight.withAlphaComponent(0.28).cgColor); ctx.setLineWidth(0.5); ctx.addPath(path); ctx.strokePath()
        let h: [NSAttributedString.Key: Any] = [.font: Palette.printFont(8), .foregroundColor: Palette.inkMidL, .kern: 0.8]
        NSString(string: title).draw(at: NSPoint(x: r.minX + 9, y: r.minY + 6), withAttributes: h)
        if let ro = readout {
            let v: [NSAttributedString.Key: Any] = [.font: Palette.printFont(9.5), .foregroundColor: Palette.inkLight, .kern: 0.4]
            let s = NSString(string: ro); let z = s.size(withAttributes: v)
            s.draw(at: NSPoint(x: r.maxX - 9 - z.width, y: r.minY + 5), withAttributes: v)
        }
    }

    /// Graph area inside a well (below the header line).
    static func plotRect(_ r: NSRect) -> NSRect { NSRect(x: r.minX + 9, y: r.minY + 24, width: r.width - 18, height: r.height - 34) }

    // Ladder low-pass magnitude (4 poles, resonance feedback), gain-compensated so the
    // passband sits at 0 dB at every resonance setting.
    private func drawFilter(_ ctx: CGContext, _ r: NSRect) {
        let fc = max(20, value("cut")), res = value("res"), envAmt = value("fEnv")
        let hz = fc >= 1000 ? String(format: "%.1f kHz", fc / 1000) : String(format: "%.0f Hz", fc)
        Self.drawWell(ctx, r, title: "FILTER · LADDER LP", readout: hz)
        let g = Self.plotRect(r)
        let fMin: Float = 20, fMax: Float = 18000, dbTop: Float = 18, dbBot: Float = -42
        func xOf(_ f: Float) -> CGFloat { g.minX + g.width * CGFloat(log(f / fMin) / log(fMax / fMin)) }
        func yOf(_ db: Float) -> CGFloat { g.minY + g.height * CGFloat((dbTop - max(dbBot, min(dbTop, db))) / (dbTop - dbBot)) }
        // Grid.
        ctx.setStrokeColor(ink.withAlphaComponent(0.10).cgColor); ctx.setLineWidth(0.5)
        for f: Float in [100, 1000, 10000] { ctx.move(to: NSPoint(x: xOf(f), y: g.minY)); ctx.addLine(to: NSPoint(x: xOf(f), y: g.maxY)) }
        for db: Float in [0, -24] { ctx.move(to: NSPoint(x: g.minX, y: yOf(db))); ctx.addLine(to: NSPoint(x: g.maxX, y: yOf(db))) }
        ctx.strokePath()
        let lab: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 6.5, weight: .regular), .foregroundColor: mid.withAlphaComponent(0.8)]
        for (f, s) in [(Float(100), "100"), (1000, "1K"), (10000, "10K")] {
            NSString(string: s).draw(at: NSPoint(x: xOf(f) + 2, y: g.maxY - 9), withAttributes: lab)
        }
        func curve(_ cutoff: Float) -> CGMutablePath {
            let k = 4.0 * min(0.97, res)
            let p = CGMutablePath()
            for i in 0...140 {
                let f = fMin * pow(fMax / fMin, Float(i) / 140)
                let w = f / cutoff
                // (1 + jw)^4 + k
                var re: Float = 1, im: Float = 0
                for _ in 0..<4 { let nr = re - w * im, ni = im + w * re; re = nr; im = ni }
                re += k
                let mag = (1 + k) / sqrt(re * re + im * im)
                let pt = NSPoint(x: xOf(f), y: yOf(20 * log10(max(mag, 1e-6))))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            return p
        }
        // Where the filter envelope sweeps it (peak of the envelope), dashed.
        if abs(envAmt) > 0.02 {
            let swept = min(fMax, max(fMin, fc * pow(2, envAmt * 7)))
            ctx.saveGState()
            ctx.setStrokeColor(ink.withAlphaComponent(0.45).cgColor); ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [3, 3])
            ctx.addPath(curve(swept)); ctx.strokePath()
            ctx.restoreGState()
            // Arrow along the floor from the cutoff to the envelope peak.
            let y = g.maxY - 14, x0 = xOf(fc), x1 = xOf(swept)
            if abs(x1 - x0) > 8 {
                ctx.setStrokeColor(ink.withAlphaComponent(0.7).cgColor); ctx.setLineWidth(1)
                ctx.move(to: NSPoint(x: x0, y: y)); ctx.addLine(to: NSPoint(x: x1, y: y))
                let dir: CGFloat = x1 > x0 ? 1 : -1
                ctx.move(to: NSPoint(x: x1 - 4 * dir, y: y - 3)); ctx.addLine(to: NSPoint(x: x1, y: y)); ctx.addLine(to: NSPoint(x: x1 - 4 * dir, y: y + 3))
                ctx.strokePath()
                let ez = NSString(string: "ENV").size(withAttributes: lab)
                let ex = dir > 0 ? (x1 + 4 + ez.width < g.maxX ? x1 + 4 : x0 - 4 - ez.width) : (x1 - 4 - ez.width > g.minX ? x1 - 4 - ez.width : x0 + 4)
                NSString(string: "ENV").draw(at: NSPoint(x: ex, y: y - ez.height * 0.5), withAttributes: lab)
            }
        }
        // The curve itself: the one red line, a faint fill under it.
        let main = curve(fc)
        let fill = main.mutableCopy()!
        fill.addLine(to: NSPoint(x: g.maxX, y: g.maxY)); fill.addLine(to: NSPoint(x: g.minX, y: g.maxY)); fill.closeSubpath()
        ctx.saveGState(); ctx.addRect(g); ctx.clip()
        ctx.setFillColor(Palette.red.withAlphaComponent(0.12).cgColor); ctx.addPath(fill); ctx.fillPath()
        ctx.setStrokeColor(Palette.red.cgColor); ctx.setLineWidth(1.8); ctx.setLineJoin(.round)
        ctx.addPath(main); ctx.strokePath()
        ctx.restoreGState()
    }

    // Amp and filter envelope on one time axis: amp in cream, filter in red.
    private func drawEnvelopes(_ ctx: CGContext, _ r: NSRect) {
        Self.drawWell(ctx, r, title: "ENVELOPES", readout: nil)
        // Legend top-right.
        let lg: [NSAttributedString.Key: Any] = [.font: Palette.printFont(8), .foregroundColor: mid, .kern: 0.6]
        let fl = NSString(string: "FILTER"), am = NSString(string: "AMP")
        let fz = fl.size(withAttributes: lg), az = am.size(withAttributes: lg)
        var lx = r.maxX - 9 - fz.width
        fl.draw(at: NSPoint(x: lx, y: r.minY + 6), withAttributes: lg)
        ctx.setFillColor(Palette.red.cgColor); ctx.fill(NSRect(x: lx - 13, y: r.minY + 10, width: 9, height: 2))
        lx -= 13 + 12 + az.width
        am.draw(at: NSPoint(x: lx, y: r.minY + 6), withAttributes: lg)
        ctx.setFillColor(ink.cgColor); ctx.fill(NSRect(x: lx - 13, y: r.minY + 10, width: 9, height: 2))

        let g = Self.plotRect(r)
        ctx.setStrokeColor(ink.withAlphaComponent(0.10).cgColor); ctx.setLineWidth(0.5)
        ctx.move(to: NSPoint(x: g.minX, y: g.maxY)); ctx.addLine(to: NSPoint(x: g.maxX, y: g.maxY)); ctx.strokePath()
        // Times shown on a square-root scale so a 5 ms attack and a 4 s release both read.
        func t(_ s: Float) -> Float { sqrt(max(0.001, s)) }
        let a1 = t(value("aA")), d1 = t(value("aD")), r1 = t(value("aR")), s1 = value("aS")
        let a2 = t(value("fA")), d2 = t(value("fD")), r2 = t(value("fR")), s2 = value("fS")
        let hold: Float = 0.55
        let span = max(a1 + d1 + hold + r1, a2 + d2 + hold + r2)
        func path(_ a: Float, _ d: Float, _ s: Float, _ rel: Float) -> CGMutablePath {
            let p = CGMutablePath()
            func pt(_ tm: Float, _ lv: Float) -> NSPoint { NSPoint(x: g.minX + g.width * CGFloat(tm / span), y: g.maxY - g.height * CGFloat(lv)) }
            p.move(to: pt(0, 0))
            p.addLine(to: pt(a, 1))
            // Decay as a curve toward the sustain level.
            for i in 1...16 { let u = Float(i) / 16; p.addLine(to: pt(a + d * u, s + (1 - s) * pow(1 - u, 2.2))) }
            p.addLine(to: pt(a + d + hold, s))
            for i in 1...16 { let u = Float(i) / 16; p.addLine(to: pt(a + d + hold + rel * u, s * pow(1 - u, 2.2))) }
            return p
        }
        ctx.saveGState(); ctx.setLineJoin(.round)
        let amp = path(a1, d1, s1, r1)
        let ampFill = amp.mutableCopy()!; ampFill.addLine(to: NSPoint(x: g.minX, y: g.maxY)); ampFill.closeSubpath()
        ctx.setFillColor(ink.withAlphaComponent(0.06).cgColor); ctx.addPath(ampFill); ctx.fillPath()
        ctx.setStrokeColor(ink.withAlphaComponent(0.85).cgColor); ctx.setLineWidth(1.4); ctx.addPath(amp); ctx.strokePath()
        ctx.setStrokeColor(Palette.red.cgColor); ctx.setLineWidth(1.8); ctx.addPath(path(a2, d2, s2, r2)); ctx.strokePath()
        ctx.restoreGState()
    }

    // Standard Paradise footer (flipped coords): hairline, logo, brand, spec tag.
    private func drawFooter(_ ctx: CGContext, _ b: NSRect) {
        let y = b.height - 36
        ctx.setStrokeColor(Palette.inkLight.withAlphaComponent(0.25).cgColor)
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: 16, y: y)); ctx.addLine(to: CGPoint(x: b.width - 16, y: y)); ctx.strokePath()
        BrandLogo.draw(in: NSRect(x: 14, y: y + 3, width: 30, height: 30), ctx: ctx)   // vector mark is flip-safe
        let aBrand: [NSAttributedString.Key: Any] = [.font: Palette.printFontCondensed(11), .foregroundColor: Palette.inkLight, .kern: 1.2]
        NSString(string: "PARADISE AUDIO").draw(at: NSPoint(x: 50, y: y + 5), withAttributes: aBrand)
        let aSub: [NSAttributedString.Key: Any] = [.font: Palette.printFont(7.5), .foregroundColor: Palette.inkMidL, .kern: 0.6]
        NSString(string: "ROAR BASS — RBS-1").draw(at: NSPoint(x: 50, y: y + 19), withAttributes: aSub)
        let aSpec: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .regular), .foregroundColor: Palette.inkMidL, .kern: 0.5]
        let spec = NSString(string: "AU v3 · INSTRUMENT · BASS")
        let sz = spec.size(withAttributes: aSpec)
        spec.draw(at: NSPoint(x: b.width - 16 - sz.width, y: y + 13), withAttributes: aSpec)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if undoCtl.handleClick(p) { needsDisplay = true; return }
        super.mouseDown(with: event)
    }

    private static let shortLabels: [String: String] = [
        "osc1Oct": "OSC1 OCT", "osc2Oct": "OSC2 OCT", "osc2Det": "DETUNE", "oscMix": "MIX", "sub": "SUB",
        "fmAmt": "GROWL", "fmRatio": "RATIO", "fmFb": "FEEDBACK",
        "nz": "LEVEL", "nzColor": "COLOUR",
        "cut": "CUTOFF", "res": "RESO", "drv": "DRIVE", "fEnv": "ENV AMT",
        "aA": "A", "aD": "D", "aS": "S", "aR": "R",
        "fA": "A", "fD": "D", "fS": "S", "fR": "R",
        "glide": "GLIDE", "vmode": "VOICE", "mg": "MASTER", "dOut": "DRIVE",
    ]

    private func attachFormatter(knob: KnobView, parameter: AUParameter) {
        switch parameter.address {
        case 6: // FM Ratio
            knob.displayFormatter = { String(format: "%.2fx", $0) }
        case 10: // Cutoff
            knob.displayFormatter = { v in
                if v >= 1000 { return String(format: "%.1fk", v / 1000.0) }
                return String(format: "%.0f", v)
            }
        case 14, 15, 17, 18, 19, 21, 22: // seconds
            knob.displayFormatter = { v in
                if v < 1.0 { return String(format: "%.0fms", v * 1000) }
                return String(format: "%.2fs", v)
            }
        case 0, 1: // octaves
            knob.displayFormatter = { String(format: "%+d", Int($0.rounded())) }
        case 2: // cents
            knob.displayFormatter = { String(format: "%+dc", Int($0.rounded())) }
        case 23: // voice mode (Indexed)
            knob.displayFormatter = { $0 < 0.5 ? "POLY" : "MONO" }
        default:
            break
        }
    }
}

// MARK: - Output scope

/// Live oscilloscope of the plug-in's output, triggered on a rising zero crossing so a held
/// note stands still. While nothing plays it draws the waveform the current settings make
/// (computed from the knobs), so the display is never empty and turning a knob shows its effect.
final class RoarScopeView: NSView {
    weak var audioUnit: RoarBassAudioUnit?
    var paramValue: ((String) -> Float)?
    private var timer: Timer?
    private var buf = [Float](repeating: 0, count: 4096)
    private var shown: [Float] = []
    private var live = false
    private var quietFor: Double = 1
    private var gain: Float = 1

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    deinit { timer?.invalidate() }

    // ≤ 30 fps, and only while the editor is in a window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate(); timer = nil
        guard window != nil else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common); timer = t
    }

    private func tick() {
        guard let au = audioUnit else { return }
        let n = buf.withUnsafeMutableBufferPointer { p -> Int in p.baseAddress.map { au.readScope($0, count: 4096) } ?? 0 }
        guard n == 4096 else { return }
        var peak: Float = 0
        for v in buf[(4096 - 2048)...] { peak = max(peak, abs(v)) }
        if peak > 1e-4 { quietFor = 0 } else { quietFor += 1.0 / 30.0 }
        let wasLive = live
        live = quietFor < 0.25
        if live {
            // Window: 25 ms at the host rate, started on the newest rising zero crossing that leaves room for it.
            let win = max(256, min(2048, Int(au.scopeSampleRate * 0.025)))
            var start = 4096 - win
            let lo = max(1, 4096 - win - 1800)
            var armed = false
            var found = -1
            var i = 4096 - win
            // Walk backwards: arm on a clearly negative sample, fire on the crossing just after it.
            while i > lo {
                if buf[i - 1] < 0 && buf[i] >= 0 && armed { found = i; break }
                if buf[i] > 0.1 * peak { armed = true }
                i -= 1
            }
            if found > 0 { start = found }
            shown = Array(buf[start..<(start + win)])
            let target: Float = 0.9 / max(peak, 0.02)
            gain += (target - gain) * 0.25
            needsDisplay = true
        } else if wasLive {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds
        RoarBassParameterView.drawWell(ctx, r, title: live ? "OUTPUT · LIVE" : "OUTPUT · SHAPE",
                                       readout: live ? nil : "PLAY A NOTE")
        let g = RoarBassParameterView.plotRect(r)
        // Graticule.
        ctx.setStrokeColor(Palette.inkLight.withAlphaComponent(0.08).cgColor); ctx.setLineWidth(0.5)
        for i in 1..<8 { let x = g.minX + g.width * CGFloat(i) / 8; ctx.move(to: NSPoint(x: x, y: g.minY)); ctx.addLine(to: NSPoint(x: x, y: g.maxY)) }
        for i in [1, 3] { let y = g.minY + g.height * CGFloat(i) / 4; ctx.move(to: NSPoint(x: g.minX, y: y)); ctx.addLine(to: NSPoint(x: g.maxX, y: y)) }
        ctx.strokePath()
        ctx.setStrokeColor(Palette.inkLight.withAlphaComponent(0.18).cgColor)
        ctx.move(to: NSPoint(x: g.minX, y: g.midY)); ctx.addLine(to: NSPoint(x: g.maxX, y: g.midY)); ctx.strokePath()

        let pts = live ? shown.map { $0 * gain } : previewShape()
        guard pts.count > 1 else { return }
        let p = CGMutablePath()
        for (i, v) in pts.enumerated() {
            let pt = NSPoint(x: g.minX + g.width * CGFloat(i) / CGFloat(pts.count - 1),
                             y: g.midY - g.height * 0.5 * CGFloat(max(-1, min(1, v))))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        ctx.saveGState(); ctx.addRect(g); ctx.clip()
        ctx.setLineJoin(.round)
        // Soft glow under the trace, then the trace.
        ctx.setStrokeColor(Palette.red.withAlphaComponent(0.22).cgColor); ctx.setLineWidth(5); ctx.addPath(p); ctx.strokePath()
        ctx.setStrokeColor(Palette.red.withAlphaComponent(live ? 1 : 0.85).cgColor); ctx.setLineWidth(1.8); ctx.addPath(p); ctx.strokePath()
        ctx.restoreGState()
    }

    /// Three cycles of the patch at a low note, built from the knob values: the two saws (octave,
    /// detune, mix), the sub, the FM growl, noise, then a 4-pole ladder at the cutoff (moved by
    /// the filter envelope's sustain) with resonance, and the drive stages.
    private func previewShape() -> [Float] {
        let v = paramValue ?? { _ in 0 }
        let n = 256, cycles = 7, keep = 3
        let f0: Float = 55                                  // A1
        let sr = f0 * Float(n)                              // n samples per cycle
        let r1 = pow(2, v("osc1Oct").rounded())
        let r2 = pow(2, v("osc2Oct").rounded()) * pow(2, v("osc2Det") / 1200)
        let mix = v("oscMix"), sub = v("sub"), fm = v("fmAmt"), ratio = max(0.25, v("fmRatio")), fb = v("fmFb")
        let nz = v("nz"), col = v("nzColor")
        let fc = min(0.45 * sr, max(20, v("cut") * pow(2, v("fEnv") * v("fS") * 7)))
        let k = 4 * min(0.95, v("res")), drv = v("drv"), dOut = v("dOut")
        let gcoef = 1 - exp(-2 * Float.pi * fc / sr)
        var s1: Float = 0, s2: Float = 0, s3: Float = 0, s4: Float = 0, lastFm: Float = 0, nState: Float = 0
        var seed: UInt32 = 0x9E3779B9
        var out: [Float] = []; out.reserveCapacity(n * keep)
        for i in 0..<(n * cycles) {
            let ph = Float(i) / Float(n)
            func saw(_ x: Float) -> Float { let f = x - floor(x); return 2 * f - 1 }
            let osc = (1 - mix) * saw(ph * r1) + mix * saw(ph * r2)
            let subv = sub * sin(2 * Float.pi * ph * r1 * 0.5)
            let mod = sin(2 * Float.pi * ph * ratio + fb * 2.5 * lastFm)
            let fmv = fm * sin(2 * Float.pi * ph * r1 + 3.0 * fm * mod)
            lastFm = fmv
            seed = seed &* 1664525 &+ 1013904223
            let white = Float(Int32(bitPattern: seed)) / Float(Int32.max)
            nState += (0.15 + 0.85 * col) * (white - nState)
            let x = osc * (1 - 0.4 * fm) * 0.6 + subv * 0.6 + fmv * 0.6 + nz * 0.4 * nState
            // Ladder: four one-poles with resonance feedback.
            let inp = tanh((x - k * s4) * (1 + 2 * drv))
            s1 += gcoef * (inp - s1); s2 += gcoef * (s1 - s2); s3 += gcoef * (s2 - s3); s4 += gcoef * (s3 - s4)
            let y = tanh(s4 * (1 + k * 0.5) * (1 + 3 * dOut))
            if i >= n * (cycles - keep) { out.append(y) }
        }
        let pk = out.reduce(0) { max($0, abs($1)) }
        return pk > 1e-4 ? out.map { $0 * 0.85 / pk } : out
    }
}
