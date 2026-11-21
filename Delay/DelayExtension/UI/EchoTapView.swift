//
//  EchoTapView.swift — Delay visualizer, DESIGN.md §4 language.
//
//  A panelDark inset with a time axis. Every repeat the delay will produce
//  is drawn as a red tap: LEFT taps rise from the centre line, RIGHT taps
//  hang below it. Tap height = repeat level (mix × feedback^n), so FEEDBACK
//  visibly lengthens the tail, MIX scales it, PING-PONG makes the taps
//  alternate sides and TIME L/R move them. A faint red decay envelope sits
//  under each side. Gridlines follow beats when SYNC is on, 250 ms otherwise.
//  Redraws only when something changed (or while WOBBLE is animating).
//

import AppKit
import AudioToolbox

final class EchoTapView: NSView {
    var audioUnit: DelayAudioUnit?
    private var timer: Timer?
    private var phase: CGFloat = 0
    private var lastSig: String = ""

    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.drawsAsynchronously = true
        // 12 Hz heartbeat: repaint on parameter / tempo change, or while the
        // tape wobble is animating the taps.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let wob = self.readParam(7, 0)
            let sig = self.signature()
            if wob > 0.001 { self.phase += 0.02 * CGFloat(0.5 + self.readParam(8, 1)); if self.phase > 1 { self.phase -= 1 } }
            if sig != self.lastSig || wob > 0.001 { self.lastSig = sig; self.needsDisplay = true }
        }
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    deinit { timer?.invalidate() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // passive display

    private func readParam(_ addr: AUParameterAddress, _ fallback: Float) -> Float {
        guard let p = audioUnit?.parameterTree?.parameter(withAddress: addr) else { return fallback }
        return p.value
    }
    private func signature() -> String {
        guard let au = audioUnit else { return "" }
        return String(format: "%.1f|%.1f|%.3f|%.0f|%.3f|%.0f|%.0f|%.0f|%.1f|%.0f",
                      au.effectiveTimeL, au.effectiveTimeR, readParam(2, 0), readParam(3, 0), readParam(4, 0),
                      readParam(5, 0), readParam(10, 0), au.hostBPM, readParam(7, 0), readParam(6, 0))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let ink = Palette.inkLight, mid = Palette.inkMidL, red = Palette.red
        let b = bounds.insetBy(dx: 2, dy: 2)

        // Panel + optional grain.
        ctx.setFillColor(Palette.panelDark.cgColor); ctx.fill(b)
        PanelTex.draw(in: b, ctx: ctx, alpha: 0.35)
        ctx.setStrokeColor(ink.withAlphaComponent(0.6).cgColor); ctx.setLineWidth(0.5); ctx.stroke(b)

        let tL = CGFloat(audioUnit?.effectiveTimeL ?? 250)
        let tR = CGFloat(audioUnit?.effectiveTimeR ?? 375)
        let fb = CGFloat(readParam(2, 0.42))
        let mix = CGFloat(readParam(4, 0.28))
        let pp = readParam(5, 1) > 0.5
        let sync = readParam(10, 0) > 0.5
        let wob = CGFloat(readParam(7, 0))
        let hiHz = CGFloat(readParam(3, 3200))
        let bpm = CGFloat(audioUnit?.hostBPM ?? 120)

        // Plot area — leave a header strip for the label / readout.
        let plot = NSRect(x: b.minX + 12, y: b.minY + 18, width: b.width - 24, height: b.height - 44)
        let midY = plot.midY
        let halfH = plot.height * 0.5 - 4
        // Window: 2 bars when synced (beat gridlines), else 8× the longer
        // time, snapped to 500 ms steps so the axis labels stay readable.
        let msPerBeat = 60000.0 / max(20, bpm)
        let windowMs: CGFloat = sync ? msPerBeat * 8 : min(4000, max(1000, ceil(max(tL, tR) * 8 / 500) * 500))
        func xFor(_ ms: CGFloat) -> CGFloat { plot.minX + plot.width * (ms / windowMs) }

        // Gridlines.
        let axis: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .regular), .foregroundColor: mid, .kern: 0.5]
        ctx.setLineWidth(0.5)
        let stepMs: CGFloat = sync ? msPerBeat : (windowMs <= 2000 ? 250 : 500)
        var g: CGFloat = 0; var gi = 0
        while g <= windowMs + 0.5 {
            let x = xFor(g)
            let strong = sync ? (gi % 4 == 0) : (gi % 4 == 0)
            ctx.setStrokeColor(mid.withAlphaComponent(strong ? 0.32 : 0.18).cgColor)
            ctx.move(to: NSPoint(x: x, y: plot.minY)); ctx.addLine(to: NSPoint(x: x, y: plot.maxY)); ctx.strokePath()
            let label = sync ? (gi % 4 == 0 ? "BAR \(gi / 4 + 1)" : "\(gi % 4 + 1)")
                             : (g >= 1000 ? String(format: "%.1fs", g / 1000) : String(format: "%.0fms", g))
            if gi < 40 { NSString(string: label).draw(at: NSPoint(x: x + 2, y: plot.minY - 12), withAttributes: axis) }
            g += stepMs; gi += 1
        }
        // Centre line.
        ctx.setStrokeColor(mid.withAlphaComponent(0.5).cgColor); ctx.setLineWidth(0.5)
        ctx.move(to: NSPoint(x: plot.minX, y: midY)); ctx.addLine(to: NSPoint(x: plot.maxX, y: midY)); ctx.strokePath()

        // Decay envelopes (faint red fill) — one per side, a continuous
        // exponential through the tap tops so the eye reads the tail length.
        func envelope(period: CGFloat, up: Bool) {
            guard period > 0, fb > 0.001 else { return }
            let path = CGMutablePath()
            path.move(to: CGPoint(x: xFor(0), y: midY))
            var t: CGFloat = 0
            var first = true
            while t <= windowMs {
                let nRep = t / period
                let a = mix * pow(fb, max(0, nRep - 1))
                let h = min(halfH, a * halfH * 1.6)
                let y = up ? midY + h : midY - h
                if first { path.addLine(to: CGPoint(x: xFor(t), y: y)); first = false }
                path.addLine(to: CGPoint(x: xFor(t), y: y))
                t += windowMs / 120
            }
            path.addLine(to: CGPoint(x: plot.maxX, y: midY)); path.closeSubpath()
            ctx.setFillColor(red.withAlphaComponent(0.10).cgColor)
            ctx.addPath(path); ctx.fillPath()
        }
        // Repeat taps.
        var lTaps: [(ms: CGFloat, a: CGFloat)] = []
        var rTaps: [(ms: CGFloat, a: CGFloat)] = []
        if pp {
            // Cross-feed: L fires, feeds R after tR, which feeds L after tL…
            var t: CGFloat = 0; var a = mix; var toLeft = true; var i = 0
            while i < 64 {
                t += toLeft ? tL : tR
                if t > windowMs || a < 0.01 { break }
                if toLeft { lTaps.append((t, a)) } else { rTaps.append((t, a)) }
                a *= fb; toLeft.toggle(); i += 1
            }
            envelope(period: (tL + tR) * 0.5, up: true); envelope(period: (tL + tR) * 0.5, up: false)
        } else {
            for (period, isL) in [(tL, true), (tR, false)] {
                var t: CGFloat = 0; var a = mix; var i = 0
                while i < 64 { t += period; if t > windowMs || a < 0.01 { break }
                    if isL { lTaps.append((t, a)) } else { rTaps.append((t, a)) }
                    a *= fb; i += 1 }
            }
            envelope(period: tL, up: true); envelope(period: tR, up: false)
        }
        // HIGH (feedback lowpass) darkens later repeats: fade bar alpha with
        // how closed the filter is. WOBBLE jitters the tap positions.
        let darken = CGFloat(max(0, min(1, (log2(18000 / max(200, hiHz)) / log2(90)))))   // 0 open … 1 closed
        let barW: CGFloat = max(2.5, min(5, plot.width / 160))
        func drawTaps(_ taps: [(ms: CGFloat, a: CGFloat)], up: Bool) {
            for (i, tap) in taps.enumerated() {
                let jitter = wob * 6 * sin(phase * 2 * .pi + CGFloat(i) * 0.9)
                let x = xFor(tap.ms) + jitter
                let h = min(halfH, tap.a * halfH * 1.6)
                let alpha = max(0.15, (0.45 + 0.55 * tap.a)) * (1 - 0.55 * darken * CGFloat(i) / CGFloat(max(1, taps.count)))
                ctx.setFillColor(red.withAlphaComponent(alpha).cgColor)
                let r = up ? NSRect(x: x - barW * 0.5, y: midY, width: barW, height: h)
                           : NSRect(x: x - barW * 0.5, y: midY - h, width: barW, height: h)
                ctx.fill(r)
            }
        }
        drawTaps(lTaps, up: true); drawTaps(rTaps, up: false)
        // Dry signal at t=0 — cream tick both sides.
        ctx.setFillColor(Palette.cream.cgColor)
        ctx.fill(NSRect(x: xFor(0) - 1, y: midY - halfH * 0.6, width: 2, height: halfH * 1.2))

        // Side labels.
        NSString(string: "L").draw(at: NSPoint(x: plot.maxX - 8, y: midY + 4), withAttributes: axis)
        NSString(string: "R").draw(at: NSPoint(x: plot.maxX - 8, y: midY - 12), withAttributes: axis)

        // Header: label top-left, live readout top-right.
        NSString(string: "ECHO TAPS").draw(at: NSPoint(x: b.minX + 8, y: b.maxY - 14), withAttributes: axis)
        let repeats = lTaps.count + rTaps.count
        let readout: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .heavy), .foregroundColor: ink, .kern: 0.4]
        let rs = NSString(string: String(format: "L %.0f ms · R %.0f ms · FB %.0f%% · %d REPEATS%@",
                                         tL, tR, fb * 100, repeats, sync ? String(format: " · %.0f BPM", bpm) : ""))
        let rz = rs.size(withAttributes: readout)
        rs.draw(at: NSPoint(x: b.maxX - 8 - rz.width, y: b.maxY - 16), withAttributes: readout)
    }
}
