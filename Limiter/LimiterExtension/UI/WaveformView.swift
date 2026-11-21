//
//  WaveformView.swift — Limiter signal preview (2026-11-21 redesign).
//
//  Scrolling picture of the last ~3 s, one tap bucket (~6 ms) per pixel column:
//    · input (trimmed, the level THRESHOLD acts on) — muted cream ribbon
//    · output — red ribbon on top, pinned under the CEILING line
//    · THRESHOLD as a dashed line and CEILING as a solid line, both polarities
//    · gain reduction as a red band hanging from the GR lane at the top
//  Amplitude is drawn on a square-root scale (between linear and dB): drum
//  transients still look like a waveform, and a −14 dB threshold sits at
//  ~45 % of the height instead of hugging the centre line.
//
//  The parent view feeds it (LimiterParameterView.tick, ≤ 30 fps, only while
//  the editor is in a window). With no signal it shows a synthetic drum loop
//  run through the same threshold / ceiling / release maths, labelled
//  "NO SIGNAL · EXAMPLE", and switches to live as soon as audio arrives.
//

import AppKit

final class WaveformView: NSView {

    // Parameters the lines and the example follow (set by the parent).
    var thresholdDB: Float = -2 { didSet { if oldValue != thresholdDB { exampleDirty = true; needsDisplay = true } } }
    var ceilingDB:   Float = -1 { didSet { if oldValue != ceilingDB { exampleDirty = true; needsDisplay = true } } }
    var releaseMs:   Float = 80 { didSet { if oldValue != releaseMs { exampleDirty = true; needsDisplay = true } } }
    var trimDB:      Float = 0  { didSet { if oldValue != trimDB { exampleDirty = true; needsDisplay = true } } }
    var bucketSeconds: Double = 0.006

    private(set) var live = false
    private var cols: [Bucket] = []          // live columns, oldest first
    private var example: [Bucket] = []
    private var exampleDirty = true
    private var exampleWidth = 0

    struct Bucket { var inHi: Float = 0, inLo: Float = 0, outHi: Float = 0, outLo: Float = 0, gr: Float = 0 }

    // Square-root amplitude scale; full height = +2 dBFS (room above a 0 dB ceiling).
    private let topLin: Float = powf(10, 2.0 / 20)
    private let grFullDB: Float = 12

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // passive display

    /// Plot area inside the well (below the header line).
    var plotRect: NSRect { NSRect(x: 10, y: 26, width: bounds.width - 20 - 26, height: bounds.height - 34) }
    var columnCount: Int { max(1, Int(plotRect.width)) }

    /// Live data from the tap, oldest first (5 floats per bucket).
    func setLive(_ isLive: Bool, data: UnsafePointer<Float>?, count: Int) {
        let was = live
        live = isLive
        if isLive, let d = data {
            let n = min(count, columnCount)
            let start = count - n
            if cols.count != n { cols = Array(repeating: Bucket(), count: n) }
            for i in 0..<n {
                let p = d + (start + i) * 5
                cols[i] = Bucket(inHi: p[0], inLo: p[1], outHi: p[2], outLo: p[3], gr: p[4])
            }
            needsDisplay = true
        } else if was != isLive {
            needsDisplay = true
        }
    }

    // MARK: Mapping

    private func frac(_ a: Float) -> CGFloat { CGFloat(min(1, sqrtf(min(abs(a), 10) / topLin))) }
    private func fracDB(_ db: Float) -> CGFloat { frac(powf(10, db / 20)) }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds
        let ink = Palette.inkLight, mid = Palette.inkMidL, red = Palette.red

        // Well.
        let well = CGPath(roundedRect: b.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.setFillColor(Palette.wellBg.cgColor); ctx.addPath(well); ctx.fillPath()
        ctx.setStrokeColor(ink.withAlphaComponent(0.28).cgColor); ctx.setLineWidth(0.5); ctx.addPath(well); ctx.strokePath()

        // Header: title + legend left, state right.
        let hA: [NSAttributedString.Key: Any] = [.font: Palette.printFont(8), .foregroundColor: mid, .kern: 0.8]
        let title = NSString(string: "SIGNAL")
        title.draw(at: NSPoint(x: 10, y: 7), withAttributes: hA)
        var lx = 10 + title.size(withAttributes: hA).width + 16
        for (label, col, outline) in [("IN", ink.withAlphaComponent(0.45), false), ("OUT", red, false), ("GR", red.withAlphaComponent(0.55), true)] {
            let sw = NSRect(x: lx, y: 9, width: 12, height: 7)
            ctx.setFillColor(col.cgColor); ctx.fill(sw)
            if outline { ctx.setFillColor(red.cgColor); ctx.fill(NSRect(x: sw.minX, y: sw.minY, width: sw.width, height: 1.5)) }
            let s = NSString(string: label); s.draw(at: NSPoint(x: sw.maxX + 4, y: 7), withAttributes: hA)
            lx = sw.maxX + 4 + s.size(withAttributes: hA).width + 12
        }
        var data: [Bucket]
        if live {
            data = Self.peakWindow(cols, radius: 3)
            let gr = cols.suffix(8).map { $0.gr }.max() ?? 0
            let rA: [NSAttributedString.Key: Any] = [.font: Palette.printFont(9.5), .foregroundColor: gr > 0.05 ? red : ink, .kern: 0.4]
            let s = NSString(string: String(format: "LIVE · GR −%.1f dB", Double(gr)))
            let z = s.size(withAttributes: rA)
            s.draw(at: NSPoint(x: b.width - 10 - z.width, y: 6), withAttributes: rA)
            ctx.setFillColor(red.cgColor)
            ctx.fillEllipse(in: NSRect(x: b.width - 10 - z.width - 10, y: 10, width: 5, height: 5))
        } else {
            if exampleDirty || exampleWidth != columnCount { rebuildExample() }
            data = example
            let rA: [NSAttributedString.Key: Any] = [.font: Palette.printFont(9.5), .foregroundColor: mid, .kern: 0.6]
            let s = NSString(string: "NO SIGNAL · EXAMPLE")
            let z = s.size(withAttributes: rA)
            s.draw(at: NSPoint(x: b.width - 10 - z.width, y: 6), withAttributes: rA)
        }

        let p = plotRect
        let laneH: CGFloat = 26
        let lane = NSRect(x: p.minX, y: p.minY, width: p.width, height: laneH)
        let wave = NSRect(x: p.minX, y: lane.maxY + 6, width: p.width, height: p.maxY - lane.maxY - 6)
        let cy = wave.midY, half = wave.height * 0.5 - 2

        // dB grid + right-hand scale.
        let gA: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .regular), .foregroundColor: mid.withAlphaComponent(0.85)]
        ctx.setStrokeColor(ink.withAlphaComponent(0.07).cgColor); ctx.setLineWidth(0.5)
        for db: Float in [0, -6, -12, -24] {
            let f = fracDB(db) * half
            for y in [cy - f, cy + f] { ctx.move(to: NSPoint(x: wave.minX, y: y)); ctx.addLine(to: NSPoint(x: wave.maxX, y: y)) }
        }
        ctx.strokePath()
        ctx.setStrokeColor(ink.withAlphaComponent(0.16).cgColor)
        ctx.move(to: NSPoint(x: wave.minX, y: cy)); ctx.addLine(to: NSPoint(x: wave.maxX, y: cy)); ctx.strokePath()
        for db: Float in [0, -6, -12, -24] {
            let f = fracDB(db) * half
            let s = NSString(string: db == 0 ? "0" : String(format: "−%.0f", -db))
            s.draw(at: NSPoint(x: wave.maxX + 5, y: cy - f - 5), withAttributes: gA)
        }
        NSString(string: "dB").draw(at: NSPoint(x: wave.maxX + 5, y: cy - 5), withAttributes: gA)

        // GR lane frame + scale.
        ctx.setStrokeColor(ink.withAlphaComponent(0.10).cgColor); ctx.setLineWidth(0.5)
        for g: Float in [3, 6, 9] {
            let y = lane.minY + lane.height * CGFloat(g / grFullDB)
            ctx.move(to: NSPoint(x: lane.minX, y: y)); ctx.addLine(to: NSPoint(x: lane.maxX, y: y))
        }
        ctx.strokePath()
        ctx.setStrokeColor(ink.withAlphaComponent(0.22).cgColor)
        ctx.move(to: NSPoint(x: lane.minX, y: lane.maxY + 0.5)); ctx.addLine(to: NSPoint(x: lane.maxX, y: lane.maxY + 0.5)); ctx.strokePath()
        NSString(string: "GR").draw(at: NSPoint(x: lane.maxX + 5, y: lane.midY - 5), withAttributes: gA)

        let n = data.count
        if n > 1 {
            let x0 = wave.maxX - CGFloat(n)            // newest column at the right edge
            func ribbon(_ hi: (Bucket) -> Float, _ lo: (Bucket) -> Float) -> CGMutablePath {
                let path = CGMutablePath()
                for i in 0..<n {
                    let pt = NSPoint(x: x0 + CGFloat(i) + 0.5, y: cy - frac(max(0, hi(data[i]))) * half)
                    if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
                for i in stride(from: n - 1, through: 0, by: -1) {
                    path.addLine(to: NSPoint(x: x0 + CGFloat(i) + 0.5, y: cy + frac(min(0, lo(data[i]))) * half))
                }
                path.closeSubpath()
                return path
            }
            ctx.saveGState(); ctx.clip(to: wave)
            // Input — muted cream ribbon.
            let inPath = ribbon({ $0.inHi }, { $0.inLo })
            ctx.addPath(inPath); ctx.setFillColor(ink.withAlphaComponent(0.26).cgColor); ctx.fillPath()
            // Output — red on top: a faint fill and the red data line (DESIGN §4).
            let outPath = ribbon({ $0.outHi }, { $0.outLo })
            ctx.addPath(outPath); ctx.setFillColor(red.withAlphaComponent(0.30).cgColor); ctx.fillPath()
            ctx.addPath(outPath); ctx.setStrokeColor(red.cgColor)
            ctx.setLineWidth(1.3); ctx.setLineJoin(.round); ctx.strokePath()
            ctx.restoreGState()

            // Gain reduction — red band hanging from the top of the lane.
            let grPath = CGMutablePath()
            grPath.move(to: NSPoint(x: x0 + 0.5, y: lane.minY))
            for i in 0..<n {
                let f = CGFloat(min(grFullDB, max(0, data[i].gr)) / grFullDB)
                grPath.addLine(to: NSPoint(x: x0 + CGFloat(i) + 0.5, y: lane.minY + f * lane.height))
            }
            grPath.addLine(to: NSPoint(x: x0 + CGFloat(n - 1) + 0.5, y: lane.minY))
            grPath.closeSubpath()
            ctx.saveGState(); ctx.clip(to: lane)
            ctx.addPath(grPath); ctx.setFillColor(red.withAlphaComponent(0.45).cgColor); ctx.fillPath()
            ctx.addPath(grPath); ctx.setStrokeColor(red.cgColor); ctx.setLineWidth(1); ctx.strokePath()
            ctx.restoreGState()
        }

        // Threshold (dashed) and ceiling (solid) lines, both polarities.
        let tA: [NSAttributedString.Key: Any] = [.font: Palette.printFont(8), .foregroundColor: ink, .kern: 0.5]
        let ft = fracDB(thresholdDB) * half, fc = fracDB(ceilingDB) * half
        ctx.setStrokeColor(ink.withAlphaComponent(0.9).cgColor); ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [5, 3])
        for y in [cy - ft, cy + ft] { ctx.move(to: NSPoint(x: wave.minX, y: y)); ctx.addLine(to: NSPoint(x: wave.maxX, y: y)) }
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setStrokeColor(ink.cgColor); ctx.setLineWidth(1.2)
        for y in [cy - fc, cy + fc] { ctx.move(to: NSPoint(x: wave.minX, y: y)); ctx.addLine(to: NSPoint(x: wave.maxX, y: y)) }
        ctx.strokePath()
        // Tags on the lower (negative) half, where they never meet the GR lane:
        // threshold at the left, ceiling at the right.
        drawTag(ctx, String(format: "THRESHOLD %.1f", Double(thresholdDB)), at: NSPoint(x: wave.minX + 4, y: cy + ft), above: true, alignRight: false, attrs: tA)
        drawTag(ctx, String(format: "CEILING %.1f", Double(ceilingDB)), at: NSPoint(x: wave.maxX - 4, y: cy + fc), above: true, alignRight: true, attrs: tA)
    }

    /// Small tag sitting on a line, on a well-coloured backing so it stays legible over the ribbons.
    private func drawTag(_ ctx: CGContext, _ text: String, at p: NSPoint, above: Bool, alignRight: Bool,
                         attrs: [NSAttributedString.Key: Any]) {
        let s = NSString(string: text.replacingOccurrences(of: "-", with: "−"))
        let z = s.size(withAttributes: attrs)
        let x = alignRight ? p.x - z.width - 6 : p.x
        let y = above ? p.y - z.height - 2 : p.y + 2
        let r = NSRect(x: x, y: y, width: z.width + 6, height: z.height)
        ctx.setFillColor(Palette.wellBg.withAlphaComponent(0.85).cgColor); ctx.fill(r)
        s.draw(at: NSPoint(x: x + 3, y: y), withAttributes: attrs)
    }

    /// Display-only peak window (±radius columns, ≈ 40 ms): bass cycles longer
    /// than one 6 ms bucket would otherwise make the min/max outline jagged.
    private static func peakWindow(_ src: [Bucket], radius: Int) -> [Bucket] {
        let n = src.count
        guard n > 2 else { return src }
        var out = src
        for i in 0..<n {
            var b = src[i]
            for j in max(0, i - radius)...min(n - 1, i + radius) {
                let s = src[j]
                b.inHi = max(b.inHi, s.inHi); b.inLo = min(b.inLo, s.inLo)
                b.outHi = max(b.outHi, s.outHi); b.outLo = min(b.outLo, s.outLo)
            }
            out[i] = b
        }
        return out
    }

    // MARK: Example (no signal)

    /// A hot drum loop (kick on every beat, snare on 2 and 4, eighth hats, a bass bed)
    /// as per-column peak envelopes, run through the same threshold / ceiling /
    /// release maths as the DSP (instant attack via the lookahead, exponential release).
    private func rebuildExample() {
        let shown = columnCount
        exampleWidth = shown; exampleDirty = false
        let pre = 200                       // pre-roll so the release state has settled at the left edge
        let n = shown + pre
        let dt = max(0.001, bucketSeconds)
        let beat = 60.0 / 118.0
        var seed: UInt32 = 0x5EED1
        func rnd() -> Float { seed = seed &* 1664525 &+ 1013904223; return Float(seed >> 8) / 16777216.0 }
        let trim = powf(10, trimDB / 20)
        var inHi = [Float](repeating: 0, count: n), inLo = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) * dt + 0.35
            let bi = Int(floor(t / beat)), bt = t - Double(bi) * beat
            var env = 0.11 * (0.85 + 0.15 * sin(2 * .pi * t / (beat * 2)))        // bass / pad bed
            env += 0.95 * exp(-bt / 0.075)                                        // kick, every beat
            if bi % 2 == 1 { env += 0.62 * exp(-bt / 0.12) }                      // snare on 2 and 4
            let et = t.truncatingRemainder(dividingBy: beat * 0.5)
            env += 0.10 * exp(-et / 0.022)                                        // eighth hats
            let e = Float(env) * trim
            inHi[i] =  e * (0.86 + 0.14 * rnd())
            inLo[i] = -e * (0.80 + 0.20 * rnd())
        }
        let makeup = ceilingDB - thresholdDB
        let rel = expf(-Float(dt) * 1000 / max(1, releaseMs))
        var req = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let pk = max(inHi[i], -inLo[i])
            req[i] = max(0, 20 * log10(max(pk, 1e-7)) - thresholdDB)
        }
        var out = [Bucket](repeating: Bucket(), count: n)
        var gr: Float = 0
        for i in 0..<n {
            let ahead = i + 1 < n ? max(req[i], req[i + 1]) : req[i]   // 5 ms lookahead ≈ one column
            gr = max(ahead, gr * rel)
            let g = powf(10, (makeup - gr) / 20)
            let ceil = powf(10, ceilingDB / 20)
            out[i] = Bucket(inHi: inHi[i], inLo: inLo[i],
                            outHi: min(ceil, inHi[i] * g), outLo: max(-ceil, inLo[i] * g), gr: gr)
        }
        example = Array(out.suffix(shown))
    }
}
