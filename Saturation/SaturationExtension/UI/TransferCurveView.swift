//
//  TransferCurveView.swift
//  Small square showing the saturation transfer curve (input → output).
//

import AppKit

final class TransferCurveView: NSView {
    var audioUnit: SaturationAudioUnit?
    private var timer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        // GPU-accelerated CG rendering — see EZAudio benchmark.
        layer?.drawsAsynchronously = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.needsDisplay = true }
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    deinit { timer?.invalidate() }

    /// Map a transfer-curve point (x ∈ [-1.5,1.5], y ∈ [-1.5,1.5]) into the panel.
    private func pt(_ x: Float, _ y: Float, in b: NSRect) -> NSPoint {
        let px = b.minX + (CGFloat(x) + 1.5) / 3.0 * b.width
        let pY = b.midY + max(-1.5, min(1.5, CGFloat(y))) / 1.5 * (b.height * 0.5 - 2)
        return NSPoint(x: px, y: pY)
    }

    override func draw(_ r: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds.insetBy(dx: 2, dy: 2)
        // Recessed metal panel — base fill, then the shared inset texture so the
        // graph reads as a sunken screen like the other suite visualizers.
        ctx.setFillColor(Palette.panelDark.cgColor); ctx.fill(b)
        PanelTex.draw(in: b, ctx: ctx, alpha: 0.35)
        ctx.setStrokeColor(NSColor(calibratedWhite: 0.90, alpha: 0.6).cgColor); ctx.setLineWidth(0.5); ctx.stroke(b)

        let ink = Palette.inkLight
        let mid = Palette.inkMidL

        // Unity reference (input = output) — a thin dashed diagonal.
        ctx.saveGState()
        ctx.setStrokeColor(mid.withAlphaComponent(0.55).cgColor); ctx.setLineWidth(0.5)
        ctx.setLineDash(phase: 0, lengths: [2, 2])
        ctx.move(to: NSPoint(x: b.minX, y: b.minY)); ctx.addLine(to: NSPoint(x: b.maxX, y: b.maxY)); ctx.strokePath()
        ctx.restoreGState()

        // Center cross (zero in / zero out).
        ctx.setStrokeColor(mid.withAlphaComponent(0.45).cgColor); ctx.setLineWidth(0.5)
        ctx.move(to: NSPoint(x: b.minX, y: b.midY)); ctx.addLine(to: NSPoint(x: b.maxX, y: b.midY)); ctx.strokePath()
        ctx.move(to: NSPoint(x: b.midX, y: b.minY)); ctx.addLine(to: NSPoint(x: b.midX, y: b.maxY)); ctx.strokePath()

        // Curve — the actual waveshaper, swelling thicker + glowing as it's hit.
        guard let au = audioUnit else { return }
        let n = Int(b.width)
        let lvl = CGFloat(max(0, min(1, au.currentLevel)))   // 0..1 live output peak

        // Build the curve path once, reused for the glow passes.
        let path = CGMutablePath()
        var first = true
        for i in 0..<n {
            let t = CGFloat(i) / CGFloat(max(1, n - 1))
            let x = -1.5 + Float(t) * 3.0
            let y = au.transfer(at: x)
            let p = pt(x, y, in: b)
            if first { path.move(to: p); first = false } else { path.addLine(to: p) }
        }
        let red = Palette.accent
        // Outer glow — wider + more opaque with level.
        if lvl > 0.02 {
            ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.addPath(path)
            ctx.setStrokeColor(red.withAlphaComponent(0.10 + 0.45 * lvl).cgColor)
            ctx.setLineWidth(3.0 + 10.0 * lvl)
            ctx.strokePath()
        }
        // Core line — thicker + brighter (toward white-hot) as it's driven harder.
        let hot = red.blended(withFraction: 0.5 * lvl, of: .white) ?? red
        ctx.addPath(path)
        ctx.setStrokeColor(hot.cgColor)
        ctx.setLineWidth(1.5 + 2.5 * lvl)
        ctx.strokePath()

        // Operating-point dot — where the current signal level sits ON the curve.
        // The peak (0..1) is the output magnitude; project it onto the +x side so
        // the dot rides up the curve as the signal hits the saturator harder.
        if lvl > 0.01 {
            let opX = Float(lvl) * 1.5                 // input position for this level
            let opY = au.transfer(at: opX)
            let d = pt(opX, opY, in: b)
            // Soft halo.
            ctx.setFillColor(red.withAlphaComponent(0.25 + 0.35 * lvl).cgColor)
            let hr = 4.0 + 7.0 * lvl
            ctx.fillEllipse(in: NSRect(x: d.x - hr, y: d.y - hr, width: hr * 2, height: hr * 2))
            // Bright core dot.
            ctx.setFillColor(hot.blended(withFraction: 0.4, of: .white)?.cgColor ?? hot.cgColor)
            let cr: CGFloat = 2.5 + 1.5 * lvl
            ctx.fillEllipse(in: NSRect(x: d.x - cr, y: d.y - cr, width: cr * 2, height: cr * 2))
            // Mirror on the -x side (signals swing both ways).
            let d2 = pt(-opX, au.transfer(at: -opX), in: b)
            ctx.setFillColor(hot.withAlphaComponent(0.7).cgColor)
            ctx.fillEllipse(in: NSRect(x: d2.x - cr, y: d2.y - cr, width: cr * 2, height: cr * 2))
        }

        // Axis labels.
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 7, weight: .regular), .foregroundColor: mid]
        NSString(string: "IN").draw(at: NSPoint(x: b.maxX - 12, y: b.minY + 1), withAttributes: a)
        NSString(string: "OUT").draw(at: NSPoint(x: b.minX + 2, y: b.maxY - 9), withAttributes: a)
        let lbl: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .regular), .foregroundColor: ink.withAlphaComponent(0.6), .kern: 0.5]
        NSString(string: "TRANSFER CURVE").draw(at: NSPoint(x: b.minX + 4, y: b.minY + 3), withAttributes: lbl)
    }
}
