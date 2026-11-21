//
//  LimiterParameterView.swift
//
//  2026-11-21 redesign (Nicky: "limiter is too hard to understand… let's add a
//  limiter channel fader, a compressor threshold and a proper audio signal
//  preview"). Reads like a classic mastering limiter:
//
//   ┌ LIMITER · THRESHOLD · CEILING · RELEASE ────────────────────── ↶ ↷ ┐
//   │ ┌ SIGNAL  ▪IN ▪OUT ▪GR ─────── LIVE / EXAMPLE ┐ ┌ IN THRESHOLD GR CEILING OUT ┐
//   │ │ GR lane (red band from the top)             │ │ ▮  ═╪═      ▮   ═╪═      ▮  │
//   │ │ input (cream) · output (red)                │ │ ▮   │       ▮  RELEASE   ▮  │
//   │ │ – – threshold – –   —— ceiling ——           │ │ ▮   │       ▮   (knob)   ▮  │
//   │ └─────────────────────────────────────────────┘ │                              │
//   │ ┌ LOUDNESS  SHORT-TERM  INTEGRATED ↺  [BROADCAST][STREAM] ┐                   │
//   ├ footer ─────────────────────────────────────────────────────────────────────┤
//
//  THRESHOLD and CEILING are long faders on one shared dB ruler with the input,
//  gain-reduction and output meters. RELEASE stays a knob. LUFS readouts and the
//  BROADCAST / STREAM target keys are a small secondary row.
//

import AppKit
import AudioToolbox

final class LimiterParameterView: NSView {

    var audioUnit: LimiterAudioUnit? { didSet { rebind() } }

    static let size = NSSize(width: 800, height: 480)
    private let ink = Palette.inkLight
    private let mid = Palette.inkMidL
    private let red = Palette.red
    private let undoCtl = ParamUndo()

    // Geometry (flipped: y grows downward).
    private let pad: CGFloat = 18, gap: CGFloat = 8, barH: CGFloat = 42
    private let contentTop: CGFloat = 52
    private var contentBottom: CGFloat { bounds.height - 44 }
    private let stripW: CGFloat = 262

    private let waveform = WaveformView(frame: .zero)
    private let thrFader = FaderView(frame: .zero)
    private let ceilFader = FaderView(frame: .zero)
    private let inMeter = MeterView(frame: .zero)
    private let grMeter = MeterView(frame: .zero)
    private let outMeter = MeterView(frame: .zero)
    private let lufsView = LoudnessReadout(frame: .zero)
    private var releaseKnob: KnobView?
    private var treeToken: AUParameterObserverToken?

    // Tap reader state.
    private var timer: Timer?
    private var tapBuf = [Float](repeating: 0, count: 2048 * 5)
    private var lastWrite: UInt32 = 0
    private var lastAdvance = Date.distantPast
    private var lastTick = Date()
    private var inDB: Float = -120, outDB: Float = -120, grDB: Float = 0
    private var inHold: Float = -120, outHold: Float = -120, grHold: Float = 0
    private var inHoldAge = 0.0, outHoldAge = 0.0, grHoldAge = 0.0

    // Hit rects for the secondary row (set in draw, recomputed in mouseDown).
    private var broadcastRect = NSRect.zero, streamRect = NSRect.zero, resetRect = NSRect.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Palette.faceBg.cgColor
        thrFader.capKind = 1      // red: THE control that makes the effect
        ceilFader.capKind = 2     // ivory: output class
        inMeter.kind = .level; outMeter.kind = .level; grMeter.kind = .reduction
        for v in [waveform, thrFader, ceilFader, inMeter, grMeter, outMeter, lufsView] as [NSView] { addSubview(v) }
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    deinit {
        timer?.invalidate()
        if let t = treeToken { audioUnit?.parameterTree?.removeParameterObserver(t) }
    }

    override var isFlipped: Bool { true }

    // MARK: Geometry

    private var stripRect: NSRect { NSRect(x: bounds.width - pad - stripW, y: contentTop, width: stripW, height: contentBottom - contentTop) }
    private var loudRect: NSRect { NSRect(x: pad, y: contentBottom - 80, width: stripRect.minX - gap - pad, height: 80) }
    private var waveRect: NSRect { NSRect(x: pad, y: contentTop, width: stripRect.minX - gap - pad, height: loudRect.minY - gap - contentTop) }
    /// Shared ruler in this view's coordinates: 0 dB … −30 dB.
    private var ruler: DBRuler { DBRuler(y0: stripRect.minY + 62, y1: stripRect.maxY - 30) }
    // Column centres inside the strip.
    private var xIn: CGFloat   { stripRect.minX + 19 }
    private var xThr: CGFloat  { stripRect.minX + 75 }
    private var xGR: CGFloat   { stripRect.minX + 131 }
    private var xCeil: CGFloat { stripRect.minX + 187 }
    private var xOut: CGFloat  { stripRect.minX + 243 }
    private let meterW: CGFloat = 14, faderW: CGFloat = 50

    override func layout() {
        super.layout()
        waveform.frame = waveRect
        let r = ruler
        let oh = FaderView.overhang
        thrFader.frame = NSRect(x: xThr - faderW / 2, y: r.y(0) - oh, width: faderW, height: r.y(-30) - r.y(0) + oh * 2)
        ceilFader.frame = NSRect(x: xCeil - faderW / 2, y: r.y(0) - oh, width: faderW, height: r.y(-12) - r.y(0) + oh * 2)
        for (m, x) in [(inMeter, xIn), (grMeter, xGR), (outMeter, xOut)] {
            m.frame = NSRect(x: x - meterW / 2, y: r.y0 - 4, width: meterW, height: r.y1 - r.y0 + 8)
            m.ruler = DBRuler(y0: 4, y1: 4 + r.y1 - r.y0)
        }
        if let k = releaseKnob {
            k.frame = NSRect(x: xCeil - 32, y: ceilFader.frame.maxY + 34, width: 64, height: 90)
        }
        let lr = loudRect
        lufsView.frame = NSRect(x: lr.minX + 10, y: lr.minY + 24, width: 250, height: lr.height - 30)
    }

    // MARK: Binding

    private func param(_ id: String) -> AUParameter? {
        audioUnit?.parameterTree?.allParameters.first { $0.identifier == id }
    }
    private func value(_ id: String) -> Float { param(id)?.value ?? 0 }

    private func rebind() {
        releaseKnob?.removeFromSuperview(); releaseKnob = nil
        if let t = treeToken { audioUnit?.parameterTree?.removeParameterObserver(t); treeToken = nil }
        guard let au = audioUnit, let tree = au.parameterTree else { return }
        undoCtl.attach(au)
        undoCtl.onChange = { [weak self] in self?.needsDisplay = true }
        if let p = param("threshold") { thrFader.bind(p, default: -2) }
        if let p = param("ceiling") { ceilFader.bind(p, default: -1) }
        if let p = param("release") {
            let k = KnobView(frame: .zero)
            k.bind(parameter: p)
            k.title = "RELEASE"
            k.displayFormatter = { String(format: "%.0f ms", $0) }
            addSubview(k); releaseKnob = k
        }
        waveform.bucketSeconds = au.tapBucketSeconds
        treeToken = tree.token(byAddingParameterObserver: { [weak self] _, _ in
            DispatchQueue.main.async { self?.syncParams() }
        })
        syncParams()
        needsLayout = true
    }

    /// Parameter-driven state: lines in the signal view, meter markers, keys, readouts.
    private func syncParams() {
        let t = value("threshold"), c = value("ceiling")
        waveform.thresholdDB = t; waveform.ceilingDB = c
        waveform.releaseMs = value("release"); waveform.trimDB = value("inputGain")
        inMeter.hotAboveDB = t
        needsDisplay = true
    }

    // MARK: Tap reader (≤ 30 fps, only while the editor is in a window)

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate(); timer = nil
        guard window != nil else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common); timer = t
    }

    private func tick() {
        guard let au = audioUnit, window != nil, !isHiddenOrHasHiddenAncestor else { return }
        let now = Date()
        let dt = min(0.2, now.timeIntervalSince(lastTick)); lastTick = now
        var w: UInt32 = 0
        let cap = min(2048, waveform.columnCount + 8)
        let n = Int(tapBuf.withUnsafeMutableBufferPointer { au.readTap(into: $0.baseAddress!, maxBuckets: Int32(cap), writeCount: &w) })
        let fresh = Int(min(UInt32(n), w &- lastWrite))
        if w != lastWrite { lastAdvance = now }
        lastWrite = w

        // Meters: peak of the buckets that arrived since the last tick.
        var iPk: Float = 0, oPk: Float = 0, gPk: Float = 0
        for i in (n - fresh)..<n where i >= 0 {
            let p = i * 5
            iPk = max(iPk, max(tapBuf[p], -tapBuf[p + 1]))
            oPk = max(oPk, max(tapBuf[p + 2], -tapBuf[p + 3]))
            gPk = max(gPk, tapBuf[p + 4])
        }
        let fall = Float(dt) * 26            // dB per second of meter fall-back
        func ballistic(_ cur: inout Float, _ hold: inout Float, _ age: inout Double, _ new: Float) {
            cur = max(new, cur - fall)
            if new >= hold { hold = new; age = 0 } else { age += dt; if age > 1.5 { hold -= fall } }
        }
        ballistic(&inDB, &inHold, &inHoldAge, iPk > 1e-6 ? 20 * log10(iPk) : -120)
        ballistic(&outDB, &outHold, &outHoldAge, oPk > 1e-6 ? 20 * log10(oPk) : -120)
        // Gain reduction falls back towards 0 (it lives on the other side of the scale).
        grDB = max(gPk, grDB - fall); if gPk >= grHold { grHold = gPk; grHoldAge = 0 } else { grHoldAge += dt; if grHoldAge > 1.5 { grHold = max(0, grHold - fall) } }
        inMeter.db = inDB; inMeter.holdDB = inHold
        outMeter.db = outDB; outMeter.holdDB = outHold
        grMeter.db = grDB; grMeter.holdDB = grHold

        // Signal view: live while there is any audio in the visible window and
        // the host keeps rendering; otherwise the labelled example.
        var any = false
        for i in 0..<n where max(tapBuf[i * 5], -tapBuf[i * 5 + 1], tapBuf[i * 5 + 2], -tapBuf[i * 5 + 3]) > 1e-4 { any = true; break }
        let live = any && now.timeIntervalSince(lastAdvance) < 1.0
        tapBuf.withUnsafeBufferPointer { waveform.setLive(live, data: $0.baseAddress, count: n) }

        lufsView.update(short: au.shortTermLUFS, integrated: au.integratedLUFS)
        setNeedsDisplay(stripReadoutRect)
    }

    /// The meter peak numbers under the strip are drawn by this view.
    private var stripReadoutRect: NSRect { NSRect(x: stripRect.minX, y: ruler.y1 + 4, width: stripW, height: stripRect.maxY - ruler.y1 - 4) }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        FaceTexture.draw(in: bounds, ctx: ctx)
        drawTopBar(ctx)
        drawStrip(ctx)
        drawLoudness(ctx)
        drawFooter(ctx)
    }

    private func drawTopBar(_ ctx: CGContext) {
        let bar = NSRect(x: 0, y: 0, width: bounds.width, height: barH)
        ctx.setFillColor(Palette.wellBg.cgColor); ctx.fill(bar)
        ctx.setFillColor(red.cgColor); ctx.fill(NSRect(x: 0, y: barH - 2, width: bounds.width, height: 2))
        let t: [NSAttributedString.Key: Any] = [.font: Palette.printFontCondensed(20), .foregroundColor: ink, .kern: 1.6]
        let ts = NSString(string: "LIMITER"); let tz = ts.size(withAttributes: t)
        ts.draw(at: NSPoint(x: pad, y: (barH - 2 - tz.height) * 0.5 + 1), withAttributes: t)
        let s: [NSAttributedString.Key: Any] = [.font: Palette.printFont(9), .foregroundColor: mid, .kern: 0.8]
        let ss = NSString(string: "PULL THE THRESHOLD DOWN = MORE LIMITING, LOUDER · OUTPUT NEVER PASSES THE CEILING")
        let sz = ss.size(withAttributes: s)
        ss.draw(at: NSPoint(x: pad + tz.width + 14, y: (barH - 2 - sz.height) * 0.5 + 1), withAttributes: s)
        undoCtl.draw(in: bounds, ctx: ctx, ink: ink, mid: mid, pad: pad, y: (barH - 2 - 16) * 0.5)
    }

    private func section(_ ctx: CGContext, _ r: NSRect) {
        let path = CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.setFillColor(Palette.panelDark.cgColor); ctx.addPath(path); ctx.fillPath()
        ctx.setStrokeColor(ink.withAlphaComponent(0.22).cgColor); ctx.setLineWidth(0.5); ctx.addPath(path); ctx.strokePath()
    }

    private func centred(_ s: String, _ x: CGFloat, _ y: CGFloat, _ a: [NSAttributedString.Key: Any]) {
        let ns = NSString(string: s); let z = ns.size(withAttributes: a)
        ns.draw(at: NSPoint(x: (x - z.width * 0.5).rounded(), y: y), withAttributes: a)
    }

    private func dbText(_ v: Float) -> String {
        abs(v) < 0.05 ? "0.0 dB" : String(format: "−%.1f dB", Double(-v)).replacingOccurrences(of: "−-", with: "+")
    }

    private func drawStrip(_ ctx: CGContext) {
        let s = stripRect
        section(ctx, s)
        let r = ruler
        let label: [NSAttributedString.Key: Any] = [.font: Palette.printFontCondensed(13), .foregroundColor: ink, .kern: 0.8]
        let small: [NSAttributedString.Key: Any] = [.font: Palette.printFontCondensed(11), .foregroundColor: mid, .kern: 0.8]
        let valA: [NSAttributedString.Key: Any] = [.font: Palette.printFont(11), .foregroundColor: ink, .kern: 0.3]
        centred("IN", xIn, s.minY + 10, small)
        centred("GR", xGR, s.minY + 10, small)
        centred("OUT", xOut, s.minY + 10, small)
        centred("THRESHOLD", xThr, s.minY + 9, label)
        centred("CEILING", xCeil, s.minY + 9, label)
        let t = value("threshold"), c = value("ceiling"), trim = value("inputGain")
        centred(dbText(t), xThr, s.minY + 27, valA)
        centred(dbText(c), xCeil, s.minY + 27, valA)
        if abs(trim) >= 0.05 {
            // Input trim (old sessions / automation) — shown under IN only when it is in use.
            let a: [NSAttributedString.Key: Any] = [.font: Palette.printFont(7.5), .foregroundColor: mid, .kern: 0.4]
            centred("TRIM", xIn, s.minY + 28, a)
            centred(String(format: "%+.1f", Double(trim)).replacingOccurrences(of: "-", with: "−"), xIn, s.minY + 38, a)
        }

        // Shared dB scale: numbers between IN and THRESHOLD, and right of OUT.
        let num: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 7.5, weight: .medium), .foregroundColor: mid]
        for db in stride(from: 0, through: -30, by: -3) {
            let y = r.y(Float(db)) - 5
            let str = NSString(string: db == 0 ? "0" : "\(-db)")
            let z = str.size(withAttributes: num)
            str.draw(at: NSPoint(x: xThr - faderW / 2 - z.width + 2, y: y), withAttributes: num)
            str.draw(at: NSPoint(x: xOut + meterW / 2 + 4, y: y), withAttributes: num)
        }

        // Meter peak readouts under the meters.
        let pk: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .semibold), .foregroundColor: ink]
        func peakText(_ v: Float) -> String { v <= -60 ? "−∞" : String(format: v > 0.05 ? "%+.1f" : "%.1f", Double(v)).replacingOccurrences(of: "-", with: "−") }
        let y = r.y1 + 10
        centred(peakText(inHold), xIn, y, pk)
        centred(grHold < 0.05 ? "0.0" : String(format: "−%.1f", Double(grHold)), xGR, y, grHold > 0.05 ? pk.merging([.foregroundColor: red]) { $1 } : pk)
        centred(peakText(outHold), xOut, y, pk)

        // Reference notches: threshold beside the input meter, ceiling beside the output meter.
        func notch(_ x: CGFloat, _ db: Float, pointingRight: Bool) {
            let yy = r.y(db), d: CGFloat = pointingRight ? 1 : -1
            ctx.setFillColor(ink.cgColor)
            ctx.move(to: NSPoint(x: x, y: yy)); ctx.addLine(to: NSPoint(x: x - d * 5, y: yy - 3.5))
            ctx.addLine(to: NSPoint(x: x - d * 5, y: yy + 3.5)); ctx.closePath(); ctx.fillPath()
        }
        notch(xIn - meterW / 2 - 1, t, pointingRight: true)
        notch(xOut - meterW / 2 - 1, c, pointingRight: true)
    }

    private func drawLoudness(_ ctx: CGContext) {
        let r = loudRect
        section(ctx, r)
        let h: [NSAttributedString.Key: Any] = [.font: Palette.printFontCondensed(12), .foregroundColor: mid, .kern: 0.8]
        NSString(string: "LOUDNESS · BS.1770").draw(at: NSPoint(x: r.minX + 10, y: r.minY + 6), withAttributes: h)

        // ↺ reset for the integrated value, next to the readouts.
        let ra: [NSAttributedString.Key: Any] = [.font: Palette.printFont(8), .foregroundColor: ink, .kern: 0.5]
        resetRect = NSRect(x: r.minX + 10 + 124 + 66, y: r.minY + 27, width: 56, height: 17)
        ButtonTex.draw(ctx, rect: resetRect, active: false)
        centred("↺ RESET", resetRect.midX, resetRect.minY + 4, ra)

        // Target keys — secondary: small, at the right of the row.
        let kw: CGFloat = 78, kh: CGFloat = 36
        streamRect = NSRect(x: r.maxX - 10 - kw, y: r.minY + 34, width: kw, height: kh)
        broadcastRect = NSRect(x: streamRect.minX - 6 - kw, y: streamRect.minY, width: kw, height: kh)
        NSString(string: "TARGET").draw(at: NSPoint(x: broadcastRect.minX, y: r.minY + 9),
                                         withAttributes: [.font: Palette.printFont(7.5), .foregroundColor: mid, .kern: 0.8])
        let t = value("threshold"), c = value("ceiling"), rel = value("release"), g = value("inputGain")
        func near(_ a: Float, _ b: Float) -> Bool { abs(a - b) < 0.05 }
        let bcOn = near(t, -12) && near(c, -3) && near(rel, 100) && near(g, 0)
        let stOn = near(t, -14) && near(c, -1) && near(rel, 60) && near(g, 0)
        for (rect, title, sub, on) in [(broadcastRect, "BROADCAST", "−23 LUFS", bcOn), (streamRect, "STREAM", "−14 LUFS", stOn)] {
            ButtonTex.draw(ctx, rect: rect, active: on)
            let ta: [NSAttributedString.Key: Any] = [.font: Palette.printFontCondensed(11), .foregroundColor: ink, .kern: 0.8]
            let sa: [NSAttributedString.Key: Any] = [.font: Palette.printFont(7.5), .foregroundColor: on ? ink : mid, .kern: 0.4]
            centred(title, rect.midX, rect.minY + 7, ta)
            centred(sub, rect.midX, rect.minY + 20, sa)
        }
    }

    private func drawFooter(_ ctx: CGContext) {
        let b = bounds
        let y = b.height - 36
        ctx.setStrokeColor(ink.withAlphaComponent(0.25).cgColor); ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: 16, y: y)); ctx.addLine(to: CGPoint(x: b.width - 16, y: y)); ctx.strokePath()
        BrandLogo.draw(in: NSRect(x: 14, y: y + 3, width: 30, height: 30), ctx: ctx)
        let aBrand: [NSAttributedString.Key: Any] = [.font: Palette.printFontCondensed(11), .foregroundColor: ink, .kern: 1.2]
        NSString(string: "PARADISE AUDIO").draw(at: NSPoint(x: 50, y: y + 5), withAttributes: aBrand)
        let aSub: [NSAttributedString.Key: Any] = [.font: Palette.printFont(7.5), .foregroundColor: mid, .kern: 0.6]
        NSString(string: "LIMITER — LIM-1").draw(at: NSPoint(x: 50, y: y + 19), withAttributes: aSub)
        let aSpec: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .regular), .foregroundColor: mid, .kern: 0.5]
        let spec = NSString(string: "AU v3 · STEREO · LOOKAHEAD 5 ms · BS.1770")
        let sz = spec.size(withAttributes: aSpec)
        spec.draw(at: NSPoint(x: b.width - 16 - sz.width, y: y + 13), withAttributes: aSpec)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if undoCtl.handleClick(p) { needsDisplay = true; return }
        if broadcastRect.contains(p) { audioUnit?.applyLoudnessPreset(0); needsDisplay = true; return }
        if streamRect.contains(p)    { audioUnit?.applyLoudnessPreset(1); needsDisplay = true; return }
        if resetRect.contains(p)     { audioUnit?.resetIntegrated(); return }
        super.mouseDown(with: event)
    }
}

/// SHORT-TERM + INTEGRATED LUFS numbers (redrawn only when they change by 0.1).
final class LoudnessReadout: NSView {
    private var st: Float = -120, il: Float = -120
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(short: Float, integrated: Float) {
        let a = (short * 10).rounded() / 10, b = (integrated * 10).rounded() / 10
        if a != st || b != il { st = a; il = b; needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let cap: [NSAttributedString.Key: Any] = [.font: Palette.printFont(7.5), .foregroundColor: Palette.inkMidL, .kern: 0.8]
        let num: [NSAttributedString.Key: Any] = [.font: Palette.printFont(20), .foregroundColor: Palette.inkLight, .kern: 0.4]
        let unit: [NSAttributedString.Key: Any] = [.font: Palette.printFont(8), .foregroundColor: Palette.inkMidL, .kern: 0.6]
        for (i, (title, v)) in [("SHORT-TERM 3 s", st), ("INTEGRATED", il)].enumerated() {
            let x = CGFloat(i) * 124
            NSString(string: title).draw(at: NSPoint(x: x, y: 0), withAttributes: cap)
            let s = NSString(string: v <= -119 ? "—" : String(format: "%.1f", Double(v)).replacingOccurrences(of: "-", with: "−"))
            s.draw(at: NSPoint(x: x, y: 13), withAttributes: num)
            NSString(string: "LUFS").draw(at: NSPoint(x: x + s.size(withAttributes: num).width + 5, y: 22), withAttributes: unit)
        }
    }
}
