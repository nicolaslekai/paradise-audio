import AppKit
import AudioToolbox

// Parameter addresses (UltraReverseAudioUnit.mm). 0-8 original, 9-18 reverse engine.
private enum A {
    static let reverse: AUParameterAddress = 0, size: AUParameterAddress = 1, decay: AUParameterAddress = 2
    static let shimmer: AUParameterAddress = 3, diffusion: AUParameterAddress = 4, texture: AUParameterAddress = 5
    static let predelay: AUParameterAddress = 6, tone: AUParameterAddress = 7, mix: AUParameterAddress = 8
    static let mode: AUParameterAddress = 9, sync: AUParameterAddress = 10, division: AUParameterAddress = 11
    static let smooth: AUParameterAddress = 12, cut: AUParameterAddress = 13, feedback: AUParameterAddress = 14
    static let fbtone: AUParameterAddress = 15, lookahead: AUParameterAddress = 16, length: AUParameterAddress = 17
    static let gap: AUParameterAddress = 18
}
private enum ModeID: Int { case bloom = 0, echo = 1, reverb = 2, preverb = 3 }

final class UltraReverseParameterView: NSView {
    var audioUnit: UltraReverseAudioUnit? { didSet { rebind() } }
    private let inkDark = Palette.inkLight
    private let inkMid  = Palette.inkMidL
    private let red     = Palette.red
    private let faceBg  = Palette.faceBg
    private var knobs: [String: KnobView] = [:]
    private let bloom = ReverseBloomView(frame: .zero)
    private let undoCtl = ParamUndo()
    private var paramToken: AUParameterObserverToken?
    private var keyHits: [(NSRect, () -> Void)] = []

    // Knob sets per mode (identifiers, left → right).
    private let knobsFor: [ModeID: [String]] = [
        .echo:    ["reverse", "feedback", "fbtone", "smooth", "cut", "mix"],
        .reverb:  ["size", "decay", "diffusion", "tone", "shimmer", "smooth", "cut", "mix"],
        .preverb: ["size", "decay", "diffusion", "tone", "length", "gap", "mix"],
        .bloom:   ["reverse", "size", "decay", "shimmer", "diffusion", "texture", "predelay", "tone", "mix"],
    ]
    private let knobTitles: [String: String] = [
        "reverse": "REVERSE", "fbtone": "REPEAT TONE", "feedback": "REPEATS", "length": "SWELL",
    ]

    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; layer?.backgroundColor = faceBg.cgColor
        layer?.drawsAsynchronously = true
        addSubview(bloom)
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    deinit { if let t = paramToken { audioUnit?.parameterTree?.removeParameterObserver(t) } }

    private func value(_ a: AUParameterAddress, _ fallback: Float = 0) -> Float {
        audioUnit?.parameterTree?.parameter(withAddress: a)?.value ?? fallback
    }
    private func set(_ a: AUParameterAddress, _ v: Float) {
        audioUnit?.parameterTree?.parameter(withAddress: a)?.setValue(v, originator: nil)
        needsLayout = true; needsDisplay = true; bloom.needsDisplay = true
    }
    private var mode: ModeID { ModeID(rawValue: Int(value(A.mode, 1).rounded())) ?? .echo }

    // ── Layout ───────────────────────────────────────────────────────────
    private let pad: CGFloat = 18, footer: CGFloat = 44
    private let kW: CGFloat = 78, kH: CGFloat = 104, ksp: CGFloat = 10
    private var stripY: CGFloat { footer + 6 + kH + 10 }          // control strip (mode keys etc.)
    private let stripH: CGFloat = 30

    override func layout() {
        super.layout()
        let shown = knobsFor[mode] ?? []
        for (id, k) in knobs { k.isHidden = !shown.contains(id) }
        let cnt = CGFloat(shown.count); let total = cnt * kW + max(0, cnt - 1) * ksp
        var x = (bounds.width - total) * 0.5
        for id in shown { knobs[id]?.frame = NSRect(x: x, y: footer + 6, width: kW, height: kH); x += kW + ksp }
        let top = stripY + stripH + 10, upperTop = bounds.height - 30
        bloom.frame = NSRect(x: pad, y: top, width: bounds.width - pad * 2, height: max(140, upperTop - top))
        // Indexed controls drive knob enablement: free length only matters with SYNC off.
        knobs["reverse"]?.alphaValue = (mode == .echo && value(A.sync, 1) > 0.5) ? 0.35 : 1.0
    }

    // ── Drawing ──────────────────────────────────────────────────────────
    override func draw(_ r: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        FaceTexture.draw(in: bounds, ctx: ctx)
        let b = bounds
        keyHits.removeAll()

        // MODE keys (left).
        let modes: [(ModeID, String)] = [(.echo, "ECHO"), (.reverb, "REVERB"), (.preverb, "PRE-VERB"), (.bloom, "BLOOM")]
        var x = pad
        let y = stripY
        sectionLabel(ctx, "MODE", at: NSPoint(x: x, y: y + stripH + 1))
        for (m, label) in modes {
            let w: CGFloat = label.count > 6 ? 84 : 64
            let rect = NSRect(x: x, y: y, width: w, height: stripH)
            key(ctx, rect, label, active: mode == m) { [weak self] in
                guard let self = self else { return }
                self.set(A.mode, Float(m.rawValue))
                // PRE-VERB needs lookahead to land the swell before the hit: turn it on (1 s)
                // the first time; the user can still pick Off / 0.5 / 2 s.
                if m == .preverb && Int(self.value(A.lookahead, 0).rounded()) == 0 { self.set(A.lookahead, 2) }
            }
            x += w + 6
        }
        x += 18

        switch mode {
        case .echo, .reverb:
            sectionLabel(ctx, "SEGMENT", at: NSPoint(x: x, y: y + stripH + 1))
            let syncOn = value(A.sync, 1) > 0.5
            key(ctx, NSRect(x: x, y: y, width: 56, height: stripH), syncOn ? "SYNC" : "FREE", active: syncOn) { [weak self] in
                self?.set(A.sync, syncOn ? 0 : 1)
            }
            x += 62
            let div = Int(value(A.division, 3).rounded())
            let names = ["1/16", "1/8", "1/8.", "1/4", "1/4.", "1/2", "1 BAR", "2 BAR"]
            for (i, n) in names.enumerated() {
                let w: CGFloat = n.count > 4 ? 50 : 40
                let rect = NSRect(x: x, y: y, width: w, height: stripH)
                if syncOn {
                    key(ctx, rect, n, active: div == i) { [weak self] in self?.set(A.division, Float(i)) }
                } else {
                    ctx.saveGState(); ctx.setAlpha(0.35); _ = ButtonTex.draw(ctx, rect: rect, active: false)
                    centered(n, in: rect, font: Palette.printFont(10), color: inkDark); ctx.restoreGState()
                }
                x += w + 4
            }
        case .preverb:
            sectionLabel(ctx, "LOOKAHEAD", at: NSPoint(x: x, y: y + stripH + 1))
            let la = Int(value(A.lookahead, 0).rounded())
            for (i, n) in ["OFF", "0.5 s", "1 s", "2 s"].enumerated() {
                let rect = NSRect(x: x, y: y, width: 52, height: stripH)
                key(ctx, rect, n, active: la == i) { [weak self] in self?.set(A.lookahead, Float(i)) }
                x += 56
            }
            let hint = la == 0 ? "OFF: the swell follows the note" : "mix only · Logic compensates the delay"
            NSString(string: hint).draw(at: NSPoint(x: x + 6, y: y + 9),
                                        withAttributes: [.font: Palette.printFont(10), .foregroundColor: inkMid])
        case .bloom:
            NSString(string: "legacy texture · reversed grains into the wash").draw(at: NSPoint(x: x, y: y + 9),
                withAttributes: [.font: Palette.printFont(10), .foregroundColor: inkMid])
        }

        BrandStrip.drawFooter(ctx: ctx, bounds: b, plugin: "ULTRA REVERSE", code: "URV-1",
                              spec: "AU v3 · STEREO · REVERSE", pad: 16, specAtTop: true)
        undoCtl.draw(in: b, ctx: ctx, ink: inkDark, mid: inkMid, pad: 16, y: b.height - 30)
    }

    private func sectionLabel(_ ctx: CGContext, _ s: String, at p: NSPoint) {
        NSString(string: s).draw(at: p, withAttributes: [.font: Palette.printFontCondensed(11), .foregroundColor: inkMid, .kern: 1.0])
    }
    private func key(_ ctx: CGContext, _ rect: NSRect, _ label: String, active: Bool, _ action: @escaping () -> Void) {
        _ = ButtonTex.draw(ctx, rect: rect, active: active)
        centered(label, in: rect, font: Palette.printFontCondensed(13), color: Palette.inkLight)
        keyHits.append((rect, action))
    }
    private func centered(_ s: String, in r: NSRect, font: NSFont, color: NSColor) {
        let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: 0.8]
        let str = NSString(string: s); let z = str.size(withAttributes: a)
        str.draw(at: NSPoint(x: r.midX - z.width / 2, y: r.midY - z.height / 2 + 1), withAttributes: a)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if undoCtl.handleClick(p) { needsDisplay = true; return }
        for (r, act) in keyHits where r.contains(p) { act(); return }
        super.mouseDown(with: event)
    }

    private func rebind() {
        knobs.values.forEach { $0.removeFromSuperview() }; knobs.removeAll()
        guard let au = audioUnit, let tree = au.parameterTree else { return }
        bloom.audioUnit = au
        undoCtl.attach(au)
        undoCtl.onChange = { [weak self] in self?.needsDisplay = true; self?.needsLayout = true }
        let knobIds: Set<String> = ["reverse", "size", "decay", "shimmer", "diffusion", "texture", "predelay", "tone", "mix",
                                    "smooth", "cut", "feedback", "fbtone", "length", "gap"]
        for node in tree.children {
            guard let p = node as? AUParameter, knobIds.contains(p.identifier) else { continue }
            let k = KnobView(frame: .zero); k.bind(parameter: p)
            if let t = knobTitles[p.identifier] { k.title = t }
            switch p.identifier {
            case "reverse", "length": k.displayFormatter = { String(format: "%.2fs", $0) }
            case "decay":    k.displayFormatter = { String(format: "%.1fs", $0) }
            case "predelay", "gap", "smooth": k.displayFormatter = { String(format: "%.0fms", $0) }
            case "cut":      k.displayFormatter = { String(format: "%.1fms", $0) }
            case "fbtone":   k.displayFormatter = { $0 >= 1000 ? String(format: "%.1fk", $0 / 1000) : String(format: "%.0f", $0) }
            case "size", "shimmer", "diffusion", "texture", "tone", "mix", "feedback":
                k.displayFormatter = { String(format: "%.0f%%", $0 * 100) }
            default: break
            }
            addSubview(k); knobs[p.identifier] = k
        }
        // Host automation / undo / preset loads of the indexed controls.
        if let t = paramToken { tree.removeParameterObserver(t) }
        paramToken = tree.token(byAddingParameterObserver: { [weak self] addr, _ in
            guard addr == A.mode || addr == A.sync || addr == A.division || addr == A.lookahead else { return }
            DispatchQueue.main.async { self?.needsLayout = true; self?.needsDisplay = true; self?.bloom.needsDisplay = true }
        })
        needsLayout = true; needsDisplay = true
    }
}


// Visualiser — the "reverse tape scope" (2026-11-20 v2).
// A recessed glass display with a dot graticule and a bar ruler. The sound is
// drawn as mirrored waveform bars: the dry hit in cream, and the SAME bars
// played backwards in red, rising into a glowing hard cut. ECHO adds its
// repeats as fading contours; REVERB a smoother wash. PRE-VERB shows the swell
// climbing across the lookahead into the hit. BLOOM pours reversed grains into
// a long wash. A live lane underneath shows the real input (cream) and output
// (red) as the same kind of bars.
final class ReverseBloomView: NSView {
    var audioUnit: UltraReverseAudioUnit?
    private var timer: Timer?
    private let red = Palette.red
    private let ink = Palette.inkLight
    private let inkMid = Palette.inkMidL
    private let hot = NSColor(calibratedRed: 1.0, green: 0.42, blue: 0.32, alpha: 1.0)   // glow core on the cut

    // bar geometry (points)
    private let step: CGFloat = 3.5, barW: CGFloat = 2.0
    private let headH: CGFloat = 34, footH: CGFloat = 16, liveH: CGFloat = 40

    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.drawsAsynchronously = true
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    deinit { timer?.invalidate() }

    // Only tick while the editor window is open.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate(); timer = nil
        guard window != nil else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.needsDisplay = true }
        RunLoop.main.add(t, forMode: .common); timer = t
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); cacheKey = "" }

    // Static layers (glass, ruler, bars, glow, labels) are rendered once per parameter/size change
    // into bitmaps; each frame only blits them and draws the playhead + the live lane.
    private var cacheKey = ""
    private var cacheLit: CGImage?, cacheDim: CGImage?

    private func param(_ a: AUParameterAddress, _ fb: Float) -> Float { audioUnit?.parameterTree?.parameter(withAddress: a)?.value ?? fb }
    private var lab: [NSAttributedString.Key: Any] { [.font: Palette.printFont(10), .foregroundColor: inkMid, .kern: 0.6] }

    private var mainRect: NSRect {
        let b = bounds.insetBy(dx: 4, dy: 4)
        return NSRect(x: b.minX, y: b.minY + footH + liveH + 6, width: b.width, height: b.height - headH - footH - liveH - 6)
    }
    /// Playhead x in ECHO / REVERB (last of the four segments).
    private var playheadX: CGFloat {
        let m = mainRect, segW = m.width / 4
        return m.minX + segW * (3 + CGFloat(min(1, max(0, audioUnit?.segmentPhase ?? 0))))
    }

    override func draw(_ r: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds.insetBy(dx: 4, dy: 4)
        let mode = Int(param(A.mode, 1).rounded())
        let m = mainRect
        rebuildCacheIfNeeded(mode: mode)
        if let lit = cacheLit { ctx.draw(lit, in: bounds) }
        if mode == 1 || mode == 2 {
            // the not-yet-played part of the current segment comes from the dim bitmap
            let px = playheadX
            if let dim = cacheDim, px < m.maxX {
                ctx.saveGState(); ctx.clip(to: NSRect(x: px, y: m.minY, width: m.maxX - px, height: m.height))
                ctx.draw(dim, in: bounds); ctx.restoreGState()
            }
            glowLine(ctx, x: px, y0: m.minY + 2, y1: m.maxY + 8, color: ink, width: 1.2, glow: 6)
            triangle(ctx, x: px, y: m.maxY + 9, size: 4, down: true, color: ink)
        }
        drawLiveBars(ctx, NSRect(x: b.minX, y: b.minY + footH, width: b.width, height: liveH))
    }

    private func rebuildCacheIfNeeded(mode: Int) {
        let scale = window?.backingScaleFactor ?? layer?.contentsScale ?? 2
        var key = "\(mode)|\(Int(bounds.width))x\(Int(bounds.height))@\(scale)|"
        for a: AUParameterAddress in 0...18 { key += String(format: "%.4g,", param(a, 0)) }
        key += String(format: "%.2f", audioUnit?.segmentSeconds ?? 0)
        guard key != cacheKey else { return }
        cacheKey = key
        cacheLit = renderStatic(mode: mode, scale: scale, dimNow: false)
        cacheDim = (mode == 1 || mode == 2) ? renderStatic(mode: mode, scale: scale, dimNow: true) : nil
    }

    private func renderStatic(mode: Int, scale: CGFloat, dimNow: Bool) -> CGImage? {
        let w = Int(ceil(bounds.width * scale)), h = Int(ceil(bounds.height * scale))
        guard w > 0, h > 0, let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
        drawStatic(c, mode: mode, dimNow: dimNow)
        NSGraphicsContext.restoreGraphicsState()
        return c.makeImage()
    }

    private func drawStatic(_ ctx: CGContext, mode: Int, dimNow: Bool) {
        let b = bounds.insetBy(dx: 4, dy: 4)
        drawGlass(ctx, b)
        let main = mainRect
        switch mode {
        case 1, 2: drawSegments(ctx, b, main, reverb: mode == 2, dimNow: dimNow)
        case 3:    drawPreverb(ctx, b, main)
        default:   drawBloom(ctx, b, main)
        }
        drawLiveFrame(ctx, NSRect(x: b.minX, y: b.minY + footH, width: b.width, height: liveH))

        let la = [0.0, 0.5, 1.0, 2.0][max(0, min(3, Int(param(A.lookahead, 0).rounded())))]
        if mode != 3 && la > 0 {
            let tag = NSString(string: String(format: "+%.1f s LOOKAHEAD (set in PRE-VERB)", la))
            let z = tag.size(withAttributes: lab)
            tag.draw(at: NSPoint(x: b.maxX - z.width - 8, y: b.maxY - 16), withAttributes: lab)
        }
        // glass edge on top of everything
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.55).cgColor); ctx.setLineWidth(1); ctx.stroke(b.insetBy(dx: 0.5, dy: 0.5))
        ctx.setStrokeColor(ink.withAlphaComponent(0.16).cgColor); ctx.setLineWidth(0.5)
        ctx.move(to: NSPoint(x: b.minX + 1, y: b.minY + 0.5)); ctx.addLine(to: NSPoint(x: b.maxX - 1, y: b.minY + 0.5)); ctx.strokePath()
    }

    // ── Glass: recessed panel, inner shadow, dot graticule ───────────────
    private func drawGlass(_ ctx: CGContext, _ b: NSRect) {
        ctx.setFillColor(Palette.wellBg.cgColor); ctx.fill(b)
        PanelTex.draw(in: b, ctx: ctx, alpha: 0.22)
        // soft inner shadow along the top and left edge (the glass sits below the face)
        let cs = CGColorSpaceCreateDeviceRGB()
        if let g = CGGradient(colorsSpace: cs, colors: [NSColor.black.withAlphaComponent(0.55).cgColor,
                                                         NSColor.black.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1]) {
            ctx.saveGState(); ctx.clip(to: b)
            ctx.drawLinearGradient(g, start: NSPoint(x: b.minX, y: b.maxY), end: NSPoint(x: b.minX, y: b.maxY - 14), options: [])
            ctx.drawLinearGradient(g, start: NSPoint(x: b.minX, y: b.minY), end: NSPoint(x: b.minX + 10, y: b.minY), options: [])
            ctx.restoreGState()
        }
        // dot graticule
        ctx.setFillColor(ink.withAlphaComponent(0.075).cgColor)
        let g: CGFloat = 16
        var y = b.minY + footH + 4
        while y < b.maxY - 8 {
            var x = b.minX + 8
            while x < b.maxX - 4 { ctx.fill(CGRect(x: x, y: y, width: 1, height: 1)); x += g }
            y += g
        }
    }

    // ── Bars ─────────────────────────────────────────────────────────────
    private func hash(_ i: Int) -> CGFloat {
        var x = UInt32(truncatingIfNeeded: i &* 374_761_393 &+ 668_265_263)
        x = (x ^ (x >> 13)) &* 1_274_126_177; x ^= x >> 16
        return CGFloat(x & 0xffff) / 65535
    }

    /// Mirrored waveform bars over [x0, x0+w] around midY. `env(t)` 0…1 across the span.
    /// A reversed copy reads the same noise backwards, so it is literally the dry bars mirrored.
    /// Bars right of `split` go into the dim path (not played yet).
    private func bars(x0: CGFloat, w: CGFloat, midY: CGFloat, halfH: CGFloat, seed: Int, rough: CGFloat,
                      reversed: Bool, split: CGFloat = .greatestFiniteMagnitude,
                      env: (CGFloat) -> CGFloat) -> (lit: CGMutablePath, dim: CGMutablePath, contour: [CGPoint]) {
        let lit = CGMutablePath(), dim = CGMutablePath(); var contour: [CGPoint] = []
        let n = max(1, Int(w / step))
        for k in 0..<n {
            let t = (CGFloat(k) + 0.5) / CGFloat(n)
            let src = reversed ? n - 1 - k : k
            let e = max(0, env(t))
            let a = e * (1 - rough + rough * hash(seed &* 7919 &+ src))
            let h = max(0.5, a * halfH)
            let x = x0 + CGFloat(k) * step
            let rect = CGRect(x: x, y: midY - h, width: barW, height: h * 2)
            if x > split { dim.addRect(rect) } else { lit.addRect(rect) }
            contour.append(CGPoint(x: x + barW / 2, y: e * halfH))
        }
        return (lit, dim, contour)
    }

    /// Stroke the envelope contour mirrored above and below midY.
    private func strokeContour(_ ctx: CGContext, _ pts: [CGPoint], midY: CGFloat, color: NSColor, width: CGFloat, glow: CGFloat) {
        guard pts.count > 1 else { return }
        ctx.saveGState()
        if glow > 0 { ctx.setShadow(offset: .zero, blur: glow, color: color.withAlphaComponent(0.85).cgColor) }
        ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(width); ctx.setLineJoin(.round)
        for sgn in [CGFloat(1), -1] {
            ctx.move(to: NSPoint(x: pts[0].x, y: midY + sgn * pts[0].y))
            for p in pts.dropFirst() { ctx.addLine(to: NSPoint(x: p.x, y: midY + sgn * p.y)) }
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private func fill(_ ctx: CGContext, _ p: CGPath, _ c: NSColor, glow: CGFloat = 0) {
        ctx.saveGState()
        if glow > 0 { ctx.setShadow(offset: .zero, blur: glow, color: c.withAlphaComponent(0.6).cgColor) }
        ctx.addPath(p); ctx.setFillColor(c.cgColor); ctx.fillPath()
        ctx.restoreGState()
    }

    /// Glowing vertical line (cut edge, playhead, hit).
    private func glowLine(_ ctx: CGContext, x: CGFloat, y0: CGFloat, y1: CGFloat, color: NSColor, width: CGFloat, glow: CGFloat) {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: glow, color: color.withAlphaComponent(0.9).cgColor)
        ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(width); ctx.setLineCap(.round)
        ctx.move(to: NSPoint(x: x, y: y0)); ctx.addLine(to: NSPoint(x: x, y: y1)); ctx.strokePath()
        ctx.restoreGState()
    }

    private func triangle(_ ctx: CGContext, x: CGFloat, y: CGFloat, size s: CGFloat, down: Bool, color: NSColor) {
        let p = CGMutablePath()
        if down { p.move(to: CGPoint(x: x - s, y: y + s)); p.addLine(to: CGPoint(x: x + s, y: y + s)); p.addLine(to: CGPoint(x: x, y: y)) }
        else    { p.move(to: CGPoint(x: x - s, y: y)); p.addLine(to: CGPoint(x: x + s, y: y)); p.addLine(to: CGPoint(x: x, y: y + s)) }
        p.closeSubpath(); ctx.addPath(p); ctx.setFillColor(color.cgColor); ctx.fillPath()
    }

    /// Bar ruler along the top of the main lane: a major tick per segment, 4 minor ticks inside,
    /// with reverse chevrons between the majors.
    private func ruler(_ ctx: CGContext, _ m: NSRect, segs: Int) {
        let y = m.maxY + 2, segW = m.width / CGFloat(segs)
        ctx.setStrokeColor(ink.withAlphaComponent(0.30).cgColor); ctx.setLineWidth(0.5)
        ctx.move(to: NSPoint(x: m.minX, y: y)); ctx.addLine(to: NSPoint(x: m.maxX, y: y)); ctx.strokePath()
        for s in 0...segs {
            let x0 = m.minX + CGFloat(s) * segW
            ctx.setStrokeColor(ink.withAlphaComponent(0.55).cgColor); ctx.setLineWidth(1)
            ctx.move(to: NSPoint(x: x0, y: y)); ctx.addLine(to: NSPoint(x: x0, y: y + 6)); ctx.strokePath()
            guard s < segs else { break }
            ctx.setStrokeColor(ink.withAlphaComponent(0.28).cgColor); ctx.setLineWidth(0.5)
            for q in 1..<4 {
                let x = x0 + segW * CGFloat(q) / 4
                ctx.move(to: NSPoint(x: x, y: y)); ctx.addLine(to: NSPoint(x: x, y: y + 3)); ctx.strokePath()
            }
            NSString(string: "\(s + 1)").draw(at: NSPoint(x: x0 + 3, y: y + 1),
                withAttributes: [.font: Palette.printFont(8), .foregroundColor: inkMid.withAlphaComponent(0.8)])
        }
    }

    // ── ECHO / REVERB ────────────────────────────────────────────────────
    private func drawSegments(_ ctx: CGContext, _ b: NSRect, _ m: NSRect, reverb: Bool, dimNow: Bool) {
        let segs = 4, segW = m.width / CGFloat(segs)
        let midY = m.midY - 2, halfH = m.height * 0.44
        let fb = CGFloat(param(A.feedback, 0.3))
        let smooth = CGFloat(param(A.smooth, 15)) / 80, cut = CGFloat(param(A.cut, 3)) / 20
        let fadeIn = max(0.02, smooth * 0.25), fadeOut = max(0.004, cut * 0.04)

        ruler(ctx, m, segs: segs)
        // centre line
        ctx.setStrokeColor(ink.withAlphaComponent(0.12).cgColor); ctx.setLineWidth(0.5)
        ctx.move(to: NSPoint(x: m.minX, y: midY)); ctx.addLine(to: NSPoint(x: m.maxX, y: midY)); ctx.strokePath()

        // the dry hit (forward)
        let dryEnv: (CGFloat) -> CGFloat = { t in t < 0.015 ? t / 0.015 : exp(-(reverb ? 3.2 : 5.0) * (t - 0.015)) }
        // the reversed copy: the dry played backwards, with the SMOOTH fade-in at its quiet start
        let revEnv: (CGFloat) -> CGFloat = { t in
            var e = reverb ? pow(t, 2.2) : dryEnv(1 - t)
            if t < fadeIn { e *= sin(.pi / 2 * t / fadeIn) }
            if t > 1 - fadeOut { e *= max(0, (1 - t) / fadeOut) }
            return e
        }
        let rough: CGFloat = reverb ? 0.30 : 0.55
        for s in 0..<segs {
            let x0 = m.minX + CGFloat(s) * segW + 2
            let w = segW - 4
            let isNow = s == segs - 1
            // segment separator
            ctx.setStrokeColor(ink.withAlphaComponent(s == 0 ? 0 : 0.16).cgColor); ctx.setLineWidth(0.5)
            ctx.move(to: NSPoint(x: x0 - 2, y: m.minY)); ctx.addLine(to: NSPoint(x: x0 - 2, y: m.maxY)); ctx.strokePath()

            // dry source (cream ghost) — every segment has its own hit
            let dry = bars(x0: x0, w: w, midY: midY, halfH: halfH * 0.62, seed: 11 + s, rough: 0.55, reversed: false, env: dryEnv)
            fill(ctx, dry.lit, ink.withAlphaComponent(0.20))

            guard s >= 1 else {
                NSString(string: "DRY ▸").draw(at: NSPoint(x: x0 + 4, y: m.minY + 2), withAttributes: lab)
                continue
            }
            // repeats (ECHO only): older reversed copies, fading contours behind
            if !reverb && fb > 0.02 {
                for c in 1...2 where s - c >= 1 {
                    let amp = 0.88 * pow(fb, CGFloat(c))
                    let rep = bars(x0: x0, w: w, midY: midY, halfH: halfH * amp, seed: 10 + s - 1 - c, rough: rough, reversed: true, env: revEnv)
                    fill(ctx, rep.lit, red.withAlphaComponent(c == 1 ? 0.22 : 0.12))
                    strokeContour(ctx, rep.contour, midY: midY, color: red.withAlphaComponent(c == 1 ? 0.55 : 0.32), width: 0.8, glow: 0)
                }
            }
            // the reversed copy of the previous segment's hit — same bars, backwards
            let split: CGFloat = (isNow && dimNow) ? -.greatestFiniteMagnitude : .greatestFiniteMagnitude
            let rev = bars(x0: x0, w: w, midY: midY, halfH: halfH * 0.88, seed: 10 + s, rough: rough, reversed: true, split: split, env: revEnv)
            fill(ctx, rev.lit, red.withAlphaComponent(0.92), glow: 5)
            fill(ctx, rev.dim, red.withAlphaComponent(0.30))
            strokeContour(ctx, rev.contour, midY: midY, color: hot.withAlphaComponent(0.85), width: 1.0, glow: 7)

            // the hard cut on its own (reversed) attack
            let cutX = x0 + w - 1
            let peak = halfH * 0.88 * revEnv(0.985)
            glowLine(ctx, x: cutX, y0: midY - peak - 6, y1: midY + peak + 6, color: hot, width: 1.6, glow: 10)
            triangle(ctx, x: cutX, y: midY + peak + 9, size: 3.5, down: true, color: hot)
        }

        let sync = param(A.sync, 1) > 0.5
        let names = ["1/16", "1/8", "1/8.", "1/4", "1/4.", "1/2", "1 BAR", "2 BAR"]
        let segTxt = sync ? names[max(0, min(7, Int(param(A.division, 3).rounded())))] : String(format: "%.2f s", param(A.reverse, 0.6))
        let secs = audioUnit?.segmentSeconds ?? 0
        let title = reverb ? "REVERSE REVERB · each segment's reverb swells and cuts on the next line"
                           : "REVERSE ECHO · each segment plays backwards, cut on its own attack"
        title.paint(at: NSPoint(x: b.minX + 8, y: b.maxY - 16), withAttributes: lab)
        footer(b, left: "◀ " + segTxt + (secs > 0 ? String(format: "  ·  %.2f s", secs) : ""))
    }

    // ── PRE-VERB ─────────────────────────────────────────────────────────
    private func drawPreverb(_ ctx: CGContext, _ b: NSRect, _ m: NSRect) {
        let la = [0.0, 0.5, 1.0, 2.0][max(0, min(3, Int(param(A.lookahead, 0).rounded())))]
        let len = Double(param(A.length, 0.8)), gapMs = Double(param(A.gap, 0))
        let midY = m.midY - 2, halfH = m.height * 0.44
        let scale = m.width * 0.62 / CGFloat(max(0.5, la > 0 ? la : 2.0))   // points per second
        let hitX = la > 0 ? m.minX + m.width * 0.72 : m.minX + m.width * 0.18
        let span = min(m.width * 0.62, CGFloat(len) * scale)
        let gapW = CGFloat(gapMs / 1000.0) * scale
        let endX = la > 0 ? hitX - gapW : hitX + span
        let startX = endX - span

        // the lookahead window on the ruler
        if la > 0 {
            let lx = hitX - CGFloat(la) * scale, y = m.maxY + 4
            ctx.setFillColor(red.withAlphaComponent(0.045).cgColor); ctx.fill(CGRect(x: lx, y: m.minY, width: hitX - lx, height: m.height))
            ctx.setStrokeColor(red.withAlphaComponent(0.35).cgColor); ctx.setLineWidth(0.5); ctx.setLineDash(phase: 0, lengths: [2, 3])
            ctx.move(to: NSPoint(x: lx, y: m.minY)); ctx.addLine(to: NSPoint(x: lx, y: m.maxY)); ctx.strokePath(); ctx.setLineDash(phase: 0, lengths: [])
            ctx.setStrokeColor(red.withAlphaComponent(0.7).cgColor); ctx.setLineWidth(1)
            ctx.move(to: NSPoint(x: lx, y: y + 4)); ctx.addLine(to: NSPoint(x: lx, y: y))
            ctx.addLine(to: NSPoint(x: hitX, y: y)); ctx.addLine(to: NSPoint(x: hitX, y: y + 4)); ctx.strokePath()
            let t = NSString(string: String(format: "LOOKAHEAD %.1f s", la))
            let a: [NSAttributedString.Key: Any] = [.font: Palette.printFont(8), .foregroundColor: red.withAlphaComponent(0.9), .kern: 0.6]
            let z = t.size(withAttributes: a)
            t.draw(at: NSPoint(x: (lx + hitX) / 2 - z.width / 2, y: y + 2), withAttributes: a)
        }
        ctx.setStrokeColor(ink.withAlphaComponent(0.12).cgColor); ctx.setLineWidth(0.5)
        ctx.move(to: NSPoint(x: m.minX, y: midY)); ctx.addLine(to: NSPoint(x: m.maxX, y: midY)); ctx.strokePath()

        // the dry note (forward)
        let dryW = min(m.maxX - hitX - 4, m.width * 0.24)
        let dry = bars(x0: hitX, w: dryW, midY: midY, halfH: halfH * 0.92, seed: 41, rough: 0.5, reversed: false) { t in
            t < 0.02 ? t / 0.02 : exp(-4.5 * (t - 0.02))
        }
        fill(ctx, dry.lit, ink.withAlphaComponent(0.55))
        // the reversed swell rising into it
        let sw = bars(x0: startX, w: span, midY: midY, halfH: halfH * 0.86, seed: 42, rough: 0.35, reversed: true) { t in
            pow(10, -1.5 * (1 - t)) * (t < 0.35 ? 0.5 - 0.5 * cos(.pi * t / 0.35) : 1)
        }
        fill(ctx, sw.lit, red.withAlphaComponent(0.92), glow: 5)
        strokeContour(ctx, sw.contour, midY: midY, color: hot.withAlphaComponent(0.85), width: 1.0, glow: 7)
        let crest = halfH * 0.86
        glowLine(ctx, x: endX, y0: midY - crest - 4, y1: midY + crest + 4, color: hot, width: 1.4, glow: 9)
        // the hit
        glowLine(ctx, x: hitX, y0: m.minY + 2, y1: m.maxY + 6, color: ink, width: 1.6, glow: 6)
        triangle(ctx, x: hitX, y: m.maxY + 7, size: 4, down: true, color: ink)
        "HIT".paint(at: NSPoint(x: hitX + 6, y: m.maxY - 12), withAttributes: lab)

        let title = la > 0 ? String(format: "PRE-VERB · the swell rises %.2f s INTO the note", len)
                           : "PRE-VERB · lookahead OFF: the reversed swell follows the note"
        title.paint(at: NSPoint(x: b.minX + 8, y: b.maxY - 16), withAttributes: lab)
        footer(b, left: String(format: "SWELL %.2f s  ·  GAP %.0f ms", len, gapMs))
    }

    // ── BLOOM ────────────────────────────────────────────────────────────
    private func drawBloom(_ ctx: CGContext, _ b: NSRect, _ m: NSRect) {
        let reverse = CGFloat(min(1, (param(A.reverse, 0.6) - 0.1) / 3.9))
        let decay = CGFloat(min(1, (param(A.decay, 4) - 0.3) / 29.7))
        let texture = CGFloat(param(A.texture, 0.7)), pre = CGFloat(param(A.predelay, 20) / 300)
        let shimmer = CGFloat(param(A.shimmer, 0.3))
        let midY = m.midY - 2, halfH = m.height * 0.44
        let preX = m.minX + 6 + pre * m.width * 0.10, bloomW = (0.16 + reverse * 0.34) * m.width
        let peakX = preX + bloomW, peakAmp = 0.45 + texture * 0.5, dec = 0.16 + sqrt(decay) * 0.95
        ctx.setStrokeColor(ink.withAlphaComponent(0.12).cgColor); ctx.setLineWidth(0.5)
        ctx.move(to: NSPoint(x: m.minX, y: midY)); ctx.addLine(to: NSPoint(x: m.maxX, y: midY)); ctx.strokePath()

        // the source hit
        let dry = bars(x0: m.minX + 2, w: m.width * 0.12, midY: midY, halfH: halfH * 0.7, seed: 61, rough: 0.5, reversed: false) { t in
            t < 0.03 ? t / 0.03 : exp(-6 * (t - 0.03))
        }
        fill(ctx, dry.lit, ink.withAlphaComponent(0.30))
        // reversed grains rising into the bloom, then the wash
        let rise = bars(x0: preX, w: bloomW, midY: midY, halfH: halfH * peakAmp, seed: 62, rough: 0.3 + texture * 0.5, reversed: true) { t in pow(t, 1.7) }
        fill(ctx, rise.lit, red.withAlphaComponent(0.92), glow: 5)
        strokeContour(ctx, rise.contour, midY: midY, color: hot.withAlphaComponent(0.85), width: 1.0, glow: 7)
        let wash = bars(x0: peakX + step, w: m.maxX - peakX - step - 2, midY: midY, halfH: halfH * peakAmp, seed: 63,
                        rough: 0.25 + texture * 0.3, reversed: false) { t in exp(-3 * t / dec) }
        fill(ctx, wash.lit, red.withAlphaComponent(0.45))
        strokeContour(ctx, wash.contour, midY: midY, color: red.withAlphaComponent(0.6), width: 0.8, glow: 0)
        // shimmer sparks above the wash
        if shimmer > 0.02 {
            let n = Int(10 + shimmer * 60)
            for i in 0..<n {
                let t = hash(900 + i), x = peakX + t * (m.maxX - peakX - 4)
                let e = exp(-3 * t / dec) * peakAmp
                let y = midY + (e * halfH) * (0.55 + 0.6 * hash(1900 + i)) * (hash(2900 + i) > 0.5 ? 1 : -1)
                ctx.setFillColor(ink.withAlphaComponent(0.25 + 0.5 * hash(3900 + i)).cgColor)
                ctx.fill(CGRect(x: x, y: y, width: 1.5, height: 1.5))
            }
        }
        glowLine(ctx, x: peakX, y0: midY - halfH * peakAmp - 4, y1: midY + halfH * peakAmp + 4, color: hot, width: 1.4, glow: 9)
        "BLOOM · reversed grains poured into a long wash".paint(at: NSPoint(x: b.minX + 8, y: b.maxY - 16), withAttributes: lab)
        footer(b, left: String(format: "REVERSE %.2f s  ·  DECAY %.1f s", param(A.reverse, 0.6), param(A.decay, 4)))
    }

    // ── Live lane: real input (cream) and output (red) as bars ───────────
    private func drawLiveFrame(_ ctx: CGContext, _ l: NSRect) {
        ctx.setStrokeColor(ink.withAlphaComponent(0.18).cgColor); ctx.setLineWidth(0.5)
        ctx.move(to: NSPoint(x: l.minX + 6, y: l.maxY + 2)); ctx.addLine(to: NSPoint(x: l.maxX - 6, y: l.maxY + 2)); ctx.strokePath()
        let midY = l.midY, halfH = l.height * 0.42
        ctx.setStrokeColor(ink.withAlphaComponent(0.10).cgColor)
        ctx.move(to: NSPoint(x: l.minX + 36, y: midY)); ctx.addLine(to: NSPoint(x: l.maxX - 6, y: midY)); ctx.strokePath()
        "LIVE".paint(at: NSPoint(x: l.minX + 8, y: midY - 6),
                    withAttributes: [.font: Palette.printFontCondensed(11), .foregroundColor: inkMid, .kern: 1.0])
    }

    private func drawLiveBars(_ ctx: CGContext, _ l: NSRect) {
        let midY = l.midY, halfH = l.height * 0.42
        guard let au = audioUnit else { return }
        let x0 = l.minX + 38, w = l.maxX - 6 - x0
        let n = max(2, Int(w / step))
        let want = Int(au.probeSize); guard want > 4 else { return }
        var dry = [Float](repeating: 0, count: want), wet = [Float](repeating: 0, count: want)
        let got = dry.withUnsafeMutableBufferPointer { dp -> Int in
            wet.withUnsafeMutableBufferPointer { wp in Int(au.readProbeDry(dp.baseAddress!, wet: wp.baseAddress!, count: want)) }
        }
        guard got > 1 else { return }
        let dp = CGMutablePath(), wp = CGMutablePath()
        for k in 0..<n {
            let i0 = k * got / n, i1 = max(i0 + 1, (k + 1) * got / n)
            var d: Float = 0, v: Float = 0
            for i in i0..<min(i1, got) { d = max(d, dry[i]); v = max(v, wet[i]) }
            let x = x0 + CGFloat(k) * step
            let hd = max(0.5, CGFloat(min(1.2, d)) * halfH), hw = max(0.5, CGFloat(min(1.2, v)) * halfH)
            dp.addRect(CGRect(x: x, y: midY - hd, width: barW, height: hd * 2))
            wp.addRect(CGRect(x: x + 0.4, y: midY - hw, width: barW - 0.8, height: hw * 2))
        }
        fill(ctx, dp, ink.withAlphaComponent(0.30))
        fill(ctx, wp, red.withAlphaComponent(0.95), glow: 4)
    }

    /// Readout row along the bottom edge: segment info left, IN/OUT legend right.
    private func footer(_ b: NSRect, left: String) {
        left.paint(at: NSPoint(x: b.minX + 8, y: b.minY + 3), withAttributes: lab)
        let a: [NSAttributedString.Key: Any] = [.font: Palette.printFont(9), .foregroundColor: inkMid, .kern: 0.6]
        var x = b.maxX - 8
        for (txt, col) in [("OUT", red), ("IN", ink.withAlphaComponent(0.45))] {
            let z = NSString(string: txt).size(withAttributes: a)
            x -= z.width; NSString(string: txt).draw(at: NSPoint(x: x, y: b.minY + 3), withAttributes: a)
            x -= 10; col.setFill(); NSRect(x: x, y: b.minY + 6, width: 6, height: 6).fill()
            x -= 12
        }
    }
}

private extension String {
    func paint(at p: NSPoint, withAttributes a: [NSAttributedString.Key: Any]) { NSString(string: self).draw(at: p, withAttributes: a) }
}
