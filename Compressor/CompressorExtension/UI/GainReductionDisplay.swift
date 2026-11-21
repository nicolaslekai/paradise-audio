//
//  GainReductionDisplay.swift
//
//  Scrolling gain-reduction history graph. Deliberately drawn in the SAME
//  visual language as CompressionCurveView (light-grey inset panel, faint
//  ink gridlines, a single red line) so the two left-column visualizers read
//  as a matched pair instead of "a graph and a VU dial." GR is plotted 0 dB
//  at the top down to maxDB at the bottom; newest sample on the right.
//

import AppKit

final class GainReductionDisplay: NSView {

    /// Latest GR sample in dB (positive number, 0..maxDB). Pushed from the AU.
    var valueDB: Float = 0 { didSet { targetDB = max(0, valueDB) } }
    var maxDB: Float = 20.0

    // Dark-faceplate scheme (matches SynthThing): dark inset panel, light ink.
    private let panelBg = Palette.panelDark
    private let inkDark = Palette.inkLight
    private let inkMid  = Palette.inkMidL
    private let red     = Palette.red

    private var smoothedDB: Float = 0
    private var targetDB:   Float = 0
    private var history: [Float] = []
    private let maxHistory = 240
    private var tickTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.drawsAsynchronously = true
        history = Array(repeating: 0, count: maxHistory)
        startTick()
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    deinit { tickTimer?.invalidate() }

    override var intrinsicContentSize: NSSize { NSSize(width: 220, height: 96) }

    private func startTick() {
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.smoothedDB += (self.targetDB - self.smoothedDB) * 0.30
            self.history.append(self.smoothedDB)
            if self.history.count > self.maxHistory {
                self.history.removeFirst(self.history.count - self.maxHistory)
            }
            self.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clip(to: bounds)
        let b = bounds.insetBy(dx: 2, dy: 2)

        // Panel — identical treatment to CompressionCurveView.
        ctx.setFillColor(panelBg.cgColor); ctx.fill(b)
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.5).cgColor); ctx.setLineWidth(0.5); ctx.stroke(b)

        // GR dB → y (0 dB near top, maxDB near bottom), leaving header room.
        func y(_ db: Float) -> CGFloat {
            let f = CGFloat(min(maxDB, max(0, db)) / maxDB)
            return b.maxY - 0.09 * b.height - f * b.height * 0.82
        }

        // Faint horizontal gridlines + labels at −5/−10/−15 dB.
        let lab: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .regular), .foregroundColor: inkMid]
        ctx.setStrokeColor(inkMid.withAlphaComponent(0.25).cgColor); ctx.setLineWidth(0.5)
        for g in [5, 10, 15] as [Float] {
            let yy = y(g)
            ctx.move(to: NSPoint(x: b.minX, y: yy)); ctx.addLine(to: NSPoint(x: b.maxX, y: yy)); ctx.strokePath()
            NSString(string: "-\(Int(g))").draw(at: NSPoint(x: b.minX + 3, y: yy + 1), withAttributes: lab)
        }

        // Header label (left) + live readout (right).
        NSString(string: "GAIN REDUCTION").draw(at: NSPoint(x: b.minX + 6, y: b.maxY - 11), withAttributes: lab)
        let live = NSString(string: String(format: "-%.1f dB", Double(smoothedDB)))
        let lAttr: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .heavy), .foregroundColor: inkDark]
        let lsz = live.size(withAttributes: lAttr)
        live.draw(at: NSPoint(x: b.maxX - lsz.width - 6, y: b.maxY - lsz.height - 2), withAttributes: lAttr)

        // History line (newest on the right) — single red line + faint fill,
        // mirroring the transfer curve's red stroke.
        guard history.count > 1 else { return }
        let n = history.count
        let line = CGMutablePath()
        for i in 0..<n {
            let t = CGFloat(i) / CGFloat(n - 1)
            let pt = NSPoint(x: b.minX + t * b.width, y: y(history[i]))
            if i == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
        }
        let fill = line.mutableCopy()!
        fill.addLine(to: NSPoint(x: b.maxX, y: y(0)))
        fill.addLine(to: NSPoint(x: b.minX, y: y(0)))
        fill.closeSubpath()
        ctx.addPath(fill); ctx.setFillColor(red.withAlphaComponent(0.10).cgColor); ctx.fillPath()
        ctx.addPath(line); ctx.setStrokeColor(red.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(1.5); ctx.setLineJoin(.round); ctx.strokePath()
    }
}
