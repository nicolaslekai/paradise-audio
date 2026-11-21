//
//  FrequencyResponseView.swift
//  Live magnitude response curve + four DRAGGABLE handles (HP, Low Shelf,
//  High Shelf, LP). Drag horizontally to move freq, drag vertically (for
//  shelves) to move gain. Double-click a handle to reset gain to 0.
//

import AppKit
import AudioToolbox

final class FrequencyResponseView: NSView {

    var audioUnit: EQAudioUnit?
    private let panelBg = Palette.panelDark
    private let inkDark = Palette.inkLight
    private let inkMid  = Palette.inkMidL
    private let red     = Palette.red

    // Frequency axis
    private let minF: Float = 20.0
    private let maxF: Float = 20000.0
    private let dbRange: CGFloat = 18.0

    // Spectrum probe — number of log-spaced bands the FFT is binned into.
    // 96 reads smoothly at any window width and isn't expensive.
    // Reduced from 96 → 48 — visually plenty across the panel and halves the
    // per-frame draw work. The AU still computes a 512-bin FFT internally
    // and bins down to the requested count.
    private let kNumBands: Int = 48
    private lazy var spectrumDB: [Float] = Array(repeating: -90, count: kNumBands)
    /// Temporally-smoothed copy of spectrumDB. Each band tweens toward the
    /// fresh FFT read with an exponential follower, so visuals stay fluid
    /// at 30 Hz even though the underlying FFT updates in chunks.
    private lazy var smoothedDB: [Float] = Array(repeating: -90, count: kNumBands)
    /// Peak-hold "ghost" trace — each band latches the highest level seen and
    /// then sags very slowly, so you can read where the spectrum has been
    /// peaking. Drawn as a faint line floating above the live spectrum.
    private lazy var peakHoldDB: [Float] = Array(repeating: -90, count: kNumBands)
    // Cached X positions per band — only recomputed when bounds change.
    private var cachedBandXs:    [CGFloat] = []
    private var cachedBandsRect: NSRect = .zero

    // Parameter addresses (must match EQAudioUnit.mm)
    private let kHP = AUParameterAddress(0)
    private let kLoFreq = AUParameterAddress(1)
    private let kLoGain = AUParameterAddress(2)
    private let kHiFreq = AUParameterAddress(3)
    private let kHiGain = AUParameterAddress(4)
    private let kLP = AUParameterAddress(5)

    private var timer: Timer?

    // Drag state
    private enum HandleKind { case hp, lowShelf, lowMid, highMid, highShelf, lp }
    private var draggedHandle: HandleKind? = nil
    private let kLMFreq = AUParameterAddress(6)
    private let kLMGain = AUParameterAddress(7)
    private let kHMFreq = AUParameterAddress(8)
    private let kHMGain = AUParameterAddress(9)
    // Per-band Q (bell width) + HP/LP slope selectors.
    private let kLoQ = AUParameterAddress(10)
    private let kLMQ = AUParameterAddress(11)
    private let kHMQ = AUParameterAddress(12)
    private let kHiQ = AUParameterAddress(13)
    private let kHPSlope = AUParameterAddress(14)
    private let kLPSlope = AUParameterAddress(15)

    // ── Live readout overlay ──
    // A small HUD that appears next to the handle you're dragging or
    // scrolling, showing its exact freq / gain / Q / slope. Drag shows it for
    // as long as you hold; scroll shows it briefly via `readoutUntil`.
    private var readoutText: String? = nil
    private var readoutPoint: NSPoint = .zero
    private var readoutUntil: Date = .distantPast

    // ── Bell/Shelf toggle hit-rects (drawn at the top of the curve view) ──
    // Living inside the response view itself so the user can't miss them —
    // last round they were squeezed into a 16-px gap between the knobs and
    // the curve and were effectively invisible.
    private var loShapeRect: NSRect = .zero
    private var hiShapeRect: NSRect = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        // Push CG rendering off the main thread onto the GPU-accelerated
        // async layer pipeline. Per Apple docs + EZAudio's measured drop
        // from ~25% CPU → 2-3% CPU at 60 Hz, this is the single biggest
        // performance win for live audio visualizers built with CG paths.
        wantsLayer = true
        layer?.drawsAsynchronously = true
        // 30 Hz redraw — back to fluid framerate now that:
        //   • drawsAsynchronously pushes CG to the GPU compositor
        //   • bands are halved (96 → 48)
        //   • per-band temporal smoothing means the visual interpolates
        //     between FFT updates, so even slow FFT data still looks
        //     buttery (no strobing).
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.needsDisplay = true }
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    deinit { timer?.invalidate() }

    // MARK: - Axis math

    private func graphRect() -> NSRect { return bounds.insetBy(dx: 4, dy: 4) }

    private func freqToX(_ f: Float, in b: NSRect) -> CGFloat {
        let logMin = log(minF), logMax = log(maxF)
        let lf = log(max(minF, min(maxF, f)))
        return b.minX + b.width * CGFloat((lf - logMin) / (logMax - logMin))
    }

    private func xToFreq(_ x: CGFloat, in b: NSRect) -> Float {
        let logMin = log(minF), logMax = log(maxF)
        let t = max(0, min(1, (x - b.minX) / b.width))
        return exp(logMin + Float(t) * (logMax - logMin))
    }

    private func dbToY(_ db: Float, in b: NSRect) -> CGFloat {
        let clamped = max(-Float(dbRange), min(Float(dbRange), db))
        return b.midY + CGFloat(clamped) / dbRange * (b.height * 0.5 - 6)
    }

    private func yToDB(_ y: CGFloat, in b: NSRect) -> Float {
        let frac = (y - b.midY) / (b.height * 0.5 - 6)
        return Float(max(-dbRange, min(dbRange, frac * dbRange)))
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = graphRect()

        // Background
        ctx.setFillColor(panelBg.cgColor); ctx.fill(b)
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.6).cgColor); ctx.setLineWidth(0.5); ctx.stroke(b)

        // ── Live spectrum behind the curve ──
        // Smooth Catmull-Rom-style curve through 48 temporally-smoothed
        // band values. Cheap (cached X positions, one path), looks
        // buttery (per-band exponential follower + cubic interpolation
        // between samples). Monochrome — no red flashing.
        if let au = audioUnit {
            // 1. Pull fresh FFT bins
            spectrumDB.withUnsafeMutableBufferPointer { ptr in
                if let base = ptr.baseAddress {
                    _ = au.readSpectrumBands(base, count: Int32(kNumBands))
                }
            }
            // 2. Temporal smoothing per band — exponential follower.
            //    Faster attack (a=0.45) than release (a=0.18) so peaks
            //    visibly rise but tails fall smoothly. Decouples visual
            //    smoothness from the FFT block rate.
            for i in 0..<kNumBands {
                let target = spectrumDB[i]
                let cur    = smoothedDB[i]
                let a: Float = target > cur ? 0.45 : 0.18
                smoothedDB[i] = cur + (target - cur) * a
                // Peak-hold: snap up instantly, sag ~0.35 dB/frame.
                if smoothedDB[i] > peakHoldDB[i] { peakHoldDB[i] = smoothedDB[i] }
                else { peakHoldDB[i] = max(smoothedDB[i], peakHoldDB[i] - 0.35) }
            }
            // 3. (Re)build the cached X-positions if bounds changed.
            if cachedBandXs.count != kNumBands || cachedBandsRect != b {
                var xs = [CGFloat](); xs.reserveCapacity(kNumBands)
                for i in 0..<kNumBands {
                    let t = Float(i) / Float(max(1, kNumBands - 1))
                    let hz = exp(log(minF) + t * (log(maxF) - log(minF)))
                    xs.append(freqToX(hz, in: b))
                }
                cachedBandXs = xs
                cachedBandsRect = b
            }
            // 4. Compute Y per band from the smoothed dB values
            var ys = [CGFloat](); ys.reserveCapacity(kNumBands)
            for i in 0..<kNumBands {
                let dB = max(-90.0, min(6.0, smoothedDB[i]))
                let frac = CGFloat((dB + 90.0) / 96.0)
                ys.append(b.minY + frac * b.height * 0.92)
            }
            // 5. Build a smooth path: cubic Bezier through each sample
            //    using slopes derived from neighbors (Catmull-Rom → Bezier).
            let path = CGMutablePath()
            path.move(to: NSPoint(x: b.minX, y: b.minY))
            path.addLine(to: NSPoint(x: cachedBandXs[0], y: ys[0]))
            for i in 0..<(kNumBands - 1) {
                let p0 = NSPoint(x: cachedBandXs[max(0, i - 1)], y: ys[max(0, i - 1)])
                let p1 = NSPoint(x: cachedBandXs[i],             y: ys[i])
                let p2 = NSPoint(x: cachedBandXs[i + 1],         y: ys[i + 1])
                let p3 = NSPoint(x: cachedBandXs[min(kNumBands - 1, i + 2)],
                                  y: ys[min(kNumBands - 1, i + 2)])
                // Catmull-Rom → cubic Bezier control points (tension 0.5)
                let c1 = NSPoint(x: p1.x + (p2.x - p0.x) / 6.0,
                                  y: p1.y + (p2.y - p0.y) / 6.0)
                let c2 = NSPoint(x: p2.x - (p3.x - p1.x) / 6.0,
                                  y: p2.y - (p3.y - p1.y) / 6.0)
                path.addCurve(to: p2, control1: c1, control2: c2)
            }
            path.addLine(to: NSPoint(x: b.maxX, y: b.minY))
            path.closeSubpath()
            // Fill + stroke in one go.
            ctx.addPath(path)
            ctx.setFillColor(inkDark.withAlphaComponent(0.12).cgColor)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(inkDark.withAlphaComponent(0.55).cgColor)
            ctx.setLineWidth(0.9); ctx.setLineJoin(.round)
            ctx.strokePath()

            // ── Peak-hold "ghost" trace (open line, no fill) ──
            var pys = [CGFloat](); pys.reserveCapacity(kNumBands)
            for i in 0..<kNumBands {
                let dB = max(-90.0, min(6.0, peakHoldDB[i]))
                pys.append(b.minY + CGFloat((dB + 90.0) / 96.0) * b.height * 0.92)
            }
            let ghost = CGMutablePath()
            ghost.move(to: NSPoint(x: cachedBandXs[0], y: pys[0]))
            for i in 0..<(kNumBands - 1) {
                let p0 = NSPoint(x: cachedBandXs[max(0, i - 1)], y: pys[max(0, i - 1)])
                let p1 = NSPoint(x: cachedBandXs[i],             y: pys[i])
                let p2 = NSPoint(x: cachedBandXs[i + 1],         y: pys[i + 1])
                let p3 = NSPoint(x: cachedBandXs[min(kNumBands - 1, i + 2)],
                                  y: pys[min(kNumBands - 1, i + 2)])
                let c1 = NSPoint(x: p1.x + (p2.x - p0.x) / 6.0, y: p1.y + (p2.y - p0.y) / 6.0)
                let c2 = NSPoint(x: p2.x - (p3.x - p1.x) / 6.0, y: p2.y - (p3.y - p1.y) / 6.0)
                ghost.addCurve(to: p2, control1: c1, control2: c2)
            }
            ctx.addPath(ghost)
            ctx.setStrokeColor(inkDark.withAlphaComponent(0.28).cgColor)
            ctx.setLineWidth(0.8); ctx.setLineJoin(.round)
            ctx.setLineDash(phase: 0, lengths: [2.5, 2.5])
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }

        // Decade gridlines
        ctx.setStrokeColor(inkMid.withAlphaComponent(0.35).cgColor); ctx.setLineWidth(0.5)
        for f in [Float(100), 1000, 10000] {
            let x = freqToX(f, in: b)
            ctx.move(to: NSPoint(x: x, y: b.minY)); ctx.addLine(to: NSPoint(x: x, y: b.maxY))
        }
        ctx.strokePath()

        // Half-scale dB gridlines (±9 dB) — faint dotted guides so the curve's
        // boost/cut depth reads at a glance. Purely visual; sits behind the curve.
        ctx.setStrokeColor(inkMid.withAlphaComponent(0.22).cgColor); ctx.setLineWidth(0.5)
        ctx.setLineDash(phase: 0, lengths: [2, 3])
        for g in [Float(dbRange) * 0.5, -Float(dbRange) * 0.5] {
            let y = dbToY(g, in: b)
            ctx.move(to: NSPoint(x: b.minX, y: y)); ctx.addLine(to: NSPoint(x: b.maxX, y: y))
        }
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])

        // 0 dB midline
        ctx.setStrokeColor(inkMid.withAlphaComponent(0.5).cgColor); ctx.setLineWidth(0.5)
        ctx.move(to: NSPoint(x: b.minX, y: b.midY)); ctx.addLine(to: NSPoint(x: b.maxX, y: b.midY)); ctx.strokePath()

        // Curve — sampled once, then drawn twice: a soft fill between the
        // curve and 0 dB (boost above, cut below) and the 2 px line on top.
        guard let au = audioUnit else { return }
        let nPoints = Int(b.width)
        var pts = [NSPoint](); pts.reserveCapacity(nPoints)
        for i in 0..<nPoints {
            let t = CGFloat(i) / CGFloat(max(1, nPoints - 1))
            let f = exp(log(minF) + Float(t) * (log(maxF) - log(minF)))
            pts.append(NSPoint(x: b.minX + CGFloat(i), y: dbToY(au.magnitude(dBAtFrequency: f), in: b)))
        }
        if let f0 = pts.first, let fN = pts.last {
            let area = CGMutablePath()
            area.move(to: NSPoint(x: f0.x, y: b.midY))
            for p in pts { area.addLine(to: p) }
            area.addLine(to: NSPoint(x: fN.x, y: b.midY)); area.closeSubpath()
            ctx.addPath(area); ctx.setFillColor(red.withAlphaComponent(0.16).cgColor); ctx.fillPath()
            let line = CGMutablePath(); line.move(to: f0)
            for p in pts.dropFirst() { line.addLine(to: p) }
            ctx.addPath(line); ctx.setStrokeColor(red.cgColor); ctx.setLineWidth(2.0); ctx.setLineJoin(.round); ctx.strokePath()
        }

        // Draggable handles. HP/LP carry a slope suffix (12 / 24 dB/oct);
        // the LO/HI bells show no suffix but flip shape on Option-click.
        let hpIs24 = (au.parameterTree?.parameter(withAddress: kHPSlope)?.value ?? 0) >= 0.5
        let lpIs24 = (au.parameterTree?.parameter(withAddress: kLPSlope)?.value ?? 0) >= 0.5
        drawHandle(ctx, at: handlePosition(.hp, in: b),        label: hpIs24 ? "HP·24" : "HP·12")
        drawHandle(ctx, at: handlePosition(.lowShelf, in: b),  label: (audioUnit?.lowIsBell ?? false) ? "LO•" : "LO")
        drawHandle(ctx, at: handlePosition(.lowMid, in: b),    label: "LM")
        drawHandle(ctx, at: handlePosition(.highMid, in: b),   label: "HM")
        drawHandle(ctx, at: handlePosition(.highShelf, in: b), label: (audioUnit?.highIsBell ?? false) ? "HI•" : "HI")
        drawHandle(ctx, at: handlePosition(.lp, in: b),        label: lpIs24 ? "LP·24" : "LP·12")

        // (Top-left/right SHAPE pills removed per user request — the LO/HI
        // bands still toggle bell vs shelf programmatically via the AU
        // properties, just no longer cluttering the response view.)
        loShapeRect = .zero
        hiShapeRect = .zero

        // Axis labels — frequency along the bottom.
        let attr: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 7, weight: .regular), .foregroundColor: inkMid]
        for (f, label) in [(100, "100"), (1000, "1k"), (10000, "10k")] {
            let x = freqToX(Float(f), in: b)
            NSString(string: label).draw(at: NSPoint(x: x - 6, y: b.minY + 3), withAttributes: attr)
        }
        // dB scale — three small ticks up the left edge (+rail / 0 / −rail) so
        // the boost/cut depth has a reference. Same muted style as the freq axis.
        let dbAttr: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 7, weight: .regular), .foregroundColor: inkMid.withAlphaComponent(0.8)]
        let rail = Int(dbRange)
        for (db, label) in [(Float(dbRange), "+\(rail)"), (0, "0"), (-Float(dbRange), "−\(rail)")] {
            let y = dbToY(db, in: b)
            let ny = max(b.minY + 2, min(b.maxY - 9, y - 4))   // keep inside the panel
            NSString(string: label).draw(at: NSPoint(x: b.minX + 3, y: ny), withAttributes: dbAttr)
        }

        // ── Live readout HUD ──
        // Visible while dragging a handle, or for ~0.8 s after a scroll-Q
        // tweak. Drawn last so it floats above everything.
        if let text = readoutText, (draggedHandle != nil || Date() < readoutUntil) {
            drawReadout(ctx, text: text, near: readoutPoint, in: b)
        }
    }

    /// Small dark rounded HUD with the active handle's exact values.
    private func drawReadout(_ ctx: CGContext, text: String, near p: NSPoint, in b: NSRect) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        let pad: CGFloat = 5
        let s = NSString(string: text)
        let tsz = s.size(withAttributes: [.font: font])
        var box = NSRect(x: p.x + 12, y: p.y + 12, width: tsz.width + pad * 2, height: tsz.height + pad * 1.4)
        // Keep the HUD inside the graph bounds.
        if box.maxX > b.maxX { box.origin.x = p.x - 12 - box.width }
        if box.maxY > b.maxY { box.origin.y = p.y - 12 - box.height }
        if box.minX < b.minX { box.origin.x = b.minX + 2 }
        if box.minY < b.minY { box.origin.y = b.minY + 2 }
        let path = CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.setFillColor(NSColor(calibratedWhite: 0.06, alpha: 0.92).cgColor); ctx.addPath(path); ctx.fillPath()
        ctx.setStrokeColor(red.withAlphaComponent(0.8).cgColor); ctx.setLineWidth(0.8); ctx.addPath(path); ctx.strokePath()
        s.draw(at: NSPoint(x: box.minX + pad, y: box.midY - tsz.height * 0.5),
               withAttributes: [.font: font, .foregroundColor: NSColor(calibratedWhite: 0.96, alpha: 1.0)])
    }

    /// Human-readable freq string.
    private func fmtHz(_ f: Float) -> String {
        f >= 1000 ? String(format: "%.2f kHz", f / 1000) : String(format: "%.0f Hz", f)
    }

    /// Build the HUD text for a handle from the current parameter values.
    private func readoutString(for kind: HandleKind) -> String {
        guard let tree = audioUnit?.parameterTree else { return "" }
        func v(_ a: AUParameterAddress) -> Float { tree.parameter(withAddress: a)?.value ?? 0 }
        switch kind {
        case .hp:
            let s = v(kHPSlope) >= 0.5 ? "24" : "12"
            return "HP  \(fmtHz(v(kHP)))  ·  \(s) dB/oct"
        case .lp:
            let s = v(kLPSlope) >= 0.5 ? "24" : "12"
            return "LP  \(fmtHz(v(kLP)))  ·  \(s) dB/oct"
        case .lowShelf:
            let shape = (audioUnit?.lowIsBell ?? false) ? "Q \(String(format: "%.2f", v(kLoQ)))" : "shelf"
            return "LO  \(fmtHz(v(kLoFreq)))  \(String(format: "%+.1f dB", v(kLoGain)))  \(shape)"
        case .highShelf:
            let shape = (audioUnit?.highIsBell ?? false) ? "Q \(String(format: "%.2f", v(kHiQ)))" : "shelf"
            return "HI  \(fmtHz(v(kHiFreq)))  \(String(format: "%+.1f dB", v(kHiGain)))  \(shape)"
        case .lowMid:
            return "LM  \(fmtHz(v(kLMFreq)))  \(String(format: "%+.1f dB", v(kLMGain)))  Q \(String(format: "%.2f", v(kLMQ)))"
        case .highMid:
            return "HM  \(fmtHz(v(kHMFreq)))  \(String(format: "%+.1f dB", v(kHMGain)))  Q \(String(format: "%.2f", v(kHMQ)))"
        }
    }

    /// Q parameter address for the bands that have one (nil for HP/LP).
    private func qAddress(for kind: HandleKind) -> AUParameterAddress? {
        switch kind {
        case .lowShelf: return kLoQ
        case .lowMid:   return kLMQ
        case .highMid:  return kHMQ
        case .highShelf: return kHiQ
        case .hp, .lp:  return nil
        }
    }

    /// Latch the HUD to a handle for `hold` seconds (drag passes a long hold;
    /// scroll passes a short one so it fades after the gesture).
    private func showReadout(for kind: HandleKind, at p: NSPoint, hold: TimeInterval = 0.8) {
        readoutText = readoutString(for: kind)
        readoutPoint = p
        readoutUntil = Date().addingTimeInterval(hold)
        needsDisplay = true
    }

    private func drawShapePill(_ ctx: CGContext, rect r: NSRect, prefix: String, isBell: Bool) {
        let path = CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil)
        if isBell {
            ctx.setFillColor(red.cgColor); ctx.addPath(path); ctx.fillPath()
            // Soft glow
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 6, color: red.withAlphaComponent(0.4).cgColor)
            ctx.setFillColor(red.cgColor)
            ctx.addPath(path); ctx.fillPath()
            ctx.restoreGState()
        } else {
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.78).cgColor)
            ctx.addPath(path); ctx.fillPath()
            ctx.setStrokeColor(inkDark.withAlphaComponent(0.7).cgColor); ctx.setLineWidth(0.8)
            ctx.addPath(path); ctx.strokePath()
        }
        // Inner shape icon — a small bell curve or shelf step glyph on the
        // left side of the pill so the user reads it at a glance.
        ctx.saveGState()
        let g = NSRect(x: r.minX + 6, y: r.midY - 5, width: 18, height: 10)
        ctx.setStrokeColor((isBell ? NSColor.white : inkDark).cgColor); ctx.setLineWidth(1.2)
        if isBell {
            // Bell: a centered hump
            ctx.move(to: NSPoint(x: g.minX, y: g.midY))
            ctx.addQuadCurve(to: NSPoint(x: g.maxX, y: g.midY), control: NSPoint(x: g.midX, y: g.minY - 4))
        } else {
            // Shelf: step shape
            ctx.move(to: NSPoint(x: g.minX, y: g.midY + 3))
            ctx.addLine(to: NSPoint(x: g.midX, y: g.midY + 3))
            ctx.addLine(to: NSPoint(x: g.midX, y: g.midY - 3))
            ctx.addLine(to: NSPoint(x: g.maxX, y: g.midY - 3))
        }
        ctx.strokePath()
        ctx.restoreGState()
        // Label — "LO: BELL" / "HI: SHELF"
        let label = NSString(string: "\(prefix): \(isBell ? "BELL" : "SHELF")")
        let attr: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .heavy),
            .foregroundColor: isBell ? NSColor.white : inkDark,
            .kern: 0.5
        ]
        let sz = label.size(withAttributes: attr)
        label.draw(at: NSPoint(x: r.maxX - sz.width - 8, y: r.midY - sz.height * 0.5 - 1), withAttributes: attr)
    }

    private func drawHandle(_ ctx: CGContext, at p: NSPoint, label: String) {
        let r: CGFloat = 6
        ctx.setFillColor(red.cgColor)
        ctx.fillEllipse(in: NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        ctx.setStrokeColor(NSColor(calibratedWhite: 0.95, alpha: 0.9).cgColor); ctx.setLineWidth(1.2)
        ctx.strokeEllipse(in: NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        let attr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8, weight: .bold), .foregroundColor: red, .kern: 0.5]
        let sz = NSString(string: label).size(withAttributes: attr)
        NSString(string: label).draw(at: NSPoint(x: p.x - sz.width * 0.5, y: p.y + r + 1), withAttributes: attr)
    }

    private func handlePosition(_ kind: HandleKind, in b: NSRect) -> NSPoint {
        guard let au = audioUnit else { return .zero }
        switch kind {
        case .hp:
            let f = au.parameterTree?.parameter(withAddress: kHP)?.value ?? 40
            let x = freqToX(f, in: b)
            // For HP, the y is determined by the curve magnitude at f (snaps to curve)
            let db = au.magnitude(dBAtFrequency: f)
            return NSPoint(x: x, y: dbToY(db, in: b))
        case .lowShelf:
            let f = au.parameterTree?.parameter(withAddress: kLoFreq)?.value ?? 120
            let g = au.parameterTree?.parameter(withAddress: kLoGain)?.value ?? 0
            return NSPoint(x: freqToX(f, in: b), y: dbToY(g, in: b))
        case .highShelf:
            let f = au.parameterTree?.parameter(withAddress: kHiFreq)?.value ?? 6000
            let g = au.parameterTree?.parameter(withAddress: kHiGain)?.value ?? 0
            return NSPoint(x: freqToX(f, in: b), y: dbToY(g, in: b))
        case .lp:
            let f = au.parameterTree?.parameter(withAddress: kLP)?.value ?? 18000
            let x = freqToX(f, in: b)
            let db = au.magnitude(dBAtFrequency: f)
            return NSPoint(x: x, y: dbToY(db, in: b))
        case .lowMid:
            let f = au.parameterTree?.parameter(withAddress: kLMFreq)?.value ?? 500
            let g = au.parameterTree?.parameter(withAddress: kLMGain)?.value ?? 0
            return NSPoint(x: freqToX(f, in: b), y: dbToY(g, in: b))
        case .highMid:
            let f = au.parameterTree?.parameter(withAddress: kHMFreq)?.value ?? 2500
            let g = au.parameterTree?.parameter(withAddress: kHMGain)?.value ?? 0
            return NSPoint(x: freqToX(f, in: b), y: dbToY(g, in: b))
        }
    }

    // MARK: - Hit testing / dragging

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let b = graphRect()
        // SHAPE pills first — they sit at the top of the curve and need to
        // win the click over any handle that happens to be nearby.
        if loShapeRect.contains(p) {
            audioUnit?.lowIsBell.toggle(); needsDisplay = true; return
        }
        if hiShapeRect.contains(p) {
            audioUnit?.highIsBell.toggle(); needsDisplay = true; return
        }
        // Hit each handle (14px hit radius) — closest wins
        let kinds: [HandleKind] = [.hp, .lowShelf, .lowMid, .highMid, .highShelf, .lp]
        var best: (HandleKind, CGFloat)?
        for k in kinds {
            let hp = handlePosition(k, in: b)
            let dx = p.x - hp.x, dy = p.y - hp.y
            let d = sqrt(dx * dx + dy * dy)
            if d < 14 {
                if best == nil || d < best!.1 { best = (k, d) }
            }
        }
        draggedHandle = best?.0

        // Option-click on the LO / HI handle flips that band between shelf and
        // bell (the toggle that used to live in the now-removed top pills),
        // rather than starting a drag.
        if let k = draggedHandle, event.modifierFlags.contains(.option) {
            switch k {
            case .lowShelf:  audioUnit?.lowIsBell.toggle()
            case .highShelf: audioUnit?.highIsBell.toggle()
            default: break
            }
            showReadout(for: k, at: handlePosition(k, in: b))
            draggedHandle = nil
            needsDisplay = true
            return
        }

        if event.clickCount == 2, let k = draggedHandle {
            switch k {
            // Gain-bearing bands: double-click resets gain to 0.
            case .lowShelf: audioUnit?.parameterTree?.parameter(withAddress: kLoGain)?.setValue(0, originator: nil)
            case .highShelf: audioUnit?.parameterTree?.parameter(withAddress: kHiGain)?.setValue(0, originator: nil)
            case .lowMid:   audioUnit?.parameterTree?.parameter(withAddress: kLMGain)?.setValue(0, originator: nil)
            case .highMid:  audioUnit?.parameterTree?.parameter(withAddress: kHMGain)?.setValue(0, originator: nil)
            // HP / LP have no gain — double-click toggles their slope (12↔24).
            case .hp:
                let cur = audioUnit?.parameterTree?.parameter(withAddress: kHPSlope)?.value ?? 0
                audioUnit?.parameterTree?.parameter(withAddress: kHPSlope)?.setValue(cur >= 0.5 ? 0 : 1, originator: nil)
            case .lp:
                let cur = audioUnit?.parameterTree?.parameter(withAddress: kLPSlope)?.value ?? 0
                audioUnit?.parameterTree?.parameter(withAddress: kLPSlope)?.setValue(cur >= 0.5 ? 0 : 1, originator: nil)
            }
            showReadout(for: k, at: handlePosition(k, in: b))
            needsDisplay = true
        } else if let k = draggedHandle {
            // Single click that grabbed a handle — show its values immediately.
            showReadout(for: k, at: handlePosition(k, in: b), hold: 2.0)
        }
    }

    /// Scroll over (or near) a handle to adjust that band's Q. HP/LP have no
    /// Q; scrolling near them does nothing. FabFilter-style: wheel up = higher
    /// Q (narrower bell), wheel down = lower Q (wider). The HUD shows the live
    /// Q while you scroll.
    override func scrollWheel(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let b = graphRect()
        let kinds: [HandleKind] = [.lowShelf, .lowMid, .highMid, .highShelf]
        var best: (HandleKind, CGFloat)?
        for k in kinds {
            let hp = handlePosition(k, in: b)
            let d = hypot(p.x - hp.x, p.y - hp.y)
            if d < 28, best == nil || d < best!.1 { best = (k, d) }
        }
        guard let k = best?.0, let qa = qAddress(for: k),
              let param = audioUnit?.parameterTree?.parameter(withAddress: qa) else {
            super.scrollWheel(with: event)
            return
        }
        // Multiplicative step so the feel is even across the 0.2–8 range.
        let step: Float = event.deltaY >= 0 ? 1.06 : (1.0 / 1.06)
        let newQ = max(0.2, min(8.0, param.value * step))
        param.setValue(newQ, originator: nil)
        showReadout(for: k, at: handlePosition(k, in: b))
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let k = draggedHandle, let tree = audioUnit?.parameterTree else { return }
        let p = convert(event.locationInWindow, from: nil)
        let b = graphRect()
        let newFreq = xToFreq(p.x, in: b)
        switch k {
        case .hp:
            // HP cutoff range from parameter: 20..1000
            let f = max(20.0, min(1000.0, newFreq))
            tree.parameter(withAddress: kHP)?.setValue(f, originator: nil)
        case .lowShelf:
            let f = max(40.0, min(800.0, newFreq))
            let g = max(-18.0, min(18.0, yToDB(p.y, in: b)))
            tree.parameter(withAddress: kLoFreq)?.setValue(f, originator: nil)
            tree.parameter(withAddress: kLoGain)?.setValue(g, originator: nil)
        case .highShelf:
            let f = max(1000.0, min(16000.0, newFreq))
            let g = max(-18.0, min(18.0, yToDB(p.y, in: b)))
            tree.parameter(withAddress: kHiFreq)?.setValue(f, originator: nil)
            tree.parameter(withAddress: kHiGain)?.setValue(g, originator: nil)
        case .lp:
            let f = max(2000.0, min(20000.0, newFreq))
            tree.parameter(withAddress: kLP)?.setValue(f, originator: nil)
        case .lowMid:
            let f = max(200.0, min(2000.0, newFreq))
            let g = max(-18.0, min(18.0, yToDB(p.y, in: b)))
            tree.parameter(withAddress: kLMFreq)?.setValue(f, originator: nil)
            tree.parameter(withAddress: kLMGain)?.setValue(g, originator: nil)
        case .highMid:
            let f = max(1000.0, min(8000.0, newFreq))
            let g = max(-18.0, min(18.0, yToDB(p.y, in: b)))
            tree.parameter(withAddress: kHMFreq)?.setValue(f, originator: nil)
            tree.parameter(withAddress: kHMGain)?.setValue(g, originator: nil)
        }
        // Keep the HUD pinned to the handle as it moves.
        showReadout(for: k, at: handlePosition(k, in: b), hold: 2.0)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        draggedHandle = nil
        // Let the HUD linger briefly, then fade.
        readoutUntil = Date().addingTimeInterval(0.6)
    }
}

// Bridge — Objective-C `magnitudeDBAtFrequency:` is renamed `magnitude(dBAtFrequency:)` in Swift.
private extension EQAudioUnit {
    func magnitude(dBAtFrequency f: Float) -> Float {
        return self.magnitudeDB(atFrequency: f)
    }
}
