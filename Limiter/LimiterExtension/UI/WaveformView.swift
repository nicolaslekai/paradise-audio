//
//  WaveformView.swift
//
//  Live frequency-spectrum analyzer for the Limiter — rendered EXACTLY like
//  the EQ's spectrum (FrequencyResponseView): a 1024-point FFT in the AU is
//  binned into 48 log-spaced bands (20 Hz–20 kHz), temporally smoothed, and
//  drawn as a single smooth Catmull-Rom curve with a dark-ink fill over a
//  log-frequency grid. (Class name kept as `WaveformView` so the parameter
//  view's wiring is unchanged; it no longer draws an oscilloscope.)
//

import AppKit

final class WaveformView: NSView {
    weak var audioUnit: LimiterAudioUnit?

    private let panelBg = Palette.panelDark
    private let inkDark = Palette.inkLight
    private let inkMid  = Palette.inkMidL
    private let red     = Palette.red

    // Spectrum probe — number of log-spaced bands (matches the EQ).
    private let kNumBands = 48
    private let minF: Float = 20
    private let maxF: Float = 20000
    private lazy var spectrumDB: [Float] = Array(repeating: -90, count: kNumBands)
    private lazy var smoothedDB: [Float] = Array(repeating: -90, count: kNumBands)
    private var cachedBandXs:    [CGFloat] = []
    private var cachedBandsRect: NSRect = .zero

    // Gain-reduction history — a scrolling trace so you can SEE the limiter
    // working: how much and how often it's clamping. Updated at 30 Hz.
    private let kGRHistory = 180
    private lazy var grHistory: [Float] = Array(repeating: 0, count: kGRHistory)
    private var grWrite = 0
    private let kGRFullScale: Float = 12.0   // dB of reduction = full panel height

    private var timer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.drawsAsynchronously = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.needsDisplay = true
        }
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    deinit { timer?.invalidate() }

    override var intrinsicContentSize: NSSize { NSSize(width: 600, height: 140) }

    // Passive display — never intercept mouse events so the parent view's
    // preset/meter clicks always get through.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Log-frequency → x within rect (same mapping the EQ uses).
    private func freqToX(_ hz: Float, in b: NSRect) -> CGFloat {
        let t = (log(hz) - log(minF)) / (log(maxF) - log(minF))
        return b.minX + CGFloat(t) * b.width
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds

        // ── Panel background + frame ───────────────────────────────────
        ctx.setFillColor(panelBg.cgColor); ctx.fill(b)
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.5).cgColor)
        ctx.setLineWidth(0.5); ctx.stroke(b)

        // ── Log-frequency gridlines + labels (decade markers) ──────────
        let marks: [(Float, String)] = [(100, "100"), (1000, "1k"), (10000, "10k")]
        let lab: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 7, weight: .regular),
            .foregroundColor: inkMid
        ]
        ctx.setStrokeColor(inkMid.withAlphaComponent(0.18).cgColor)
        ctx.setLineWidth(0.5)
        for hz in [50, 100, 200, 500, 1000, 2000, 5000, 10000] as [Float] {
            let x = freqToX(hz, in: b)
            ctx.move(to: NSPoint(x: x, y: b.minY)); ctx.addLine(to: NSPoint(x: x, y: b.maxY))
        }
        ctx.strokePath()
        for (hz, s) in marks {
            let x = freqToX(hz, in: b)
            NSString(string: s).draw(at: NSPoint(x: x + 2, y: b.minY + 2), withAttributes: lab)
        }

        // ── Live spectrum (identical pipeline to the EQ) ───────────────
        guard let au = audioUnit else { return }
        spectrumDB.withUnsafeMutableBufferPointer { ptr in
            if let base = ptr.baseAddress {
                _ = au.readSpectrumBands(base, count: Int32(kNumBands))
            }
        }
        // Temporal smoothing per band — fast attack, slow release.
        for i in 0..<kNumBands {
            let target = spectrumDB[i]
            let cur    = smoothedDB[i]
            let a: Float = target > cur ? 0.45 : 0.18
            smoothedDB[i] = cur + (target - cur) * a
        }
        // Cache X positions per band.
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
        // Y per band (dB −90..+6 mapped into 0..92% height).
        var ys = [CGFloat](); ys.reserveCapacity(kNumBands)
        for i in 0..<kNumBands {
            let dB = max(-90.0, min(6.0, smoothedDB[i]))
            let frac = CGFloat((dB + 90.0) / 96.0)
            ys.append(b.minY + frac * b.height * 0.92)
        }
        // Smooth Catmull-Rom → cubic Bezier path.
        let path = CGMutablePath()
        path.move(to: NSPoint(x: b.minX, y: b.minY))
        path.addLine(to: NSPoint(x: cachedBandXs[0], y: ys[0]))
        for i in 0..<(kNumBands - 1) {
            let p0 = NSPoint(x: cachedBandXs[max(0, i - 1)], y: ys[max(0, i - 1)])
            let p1 = NSPoint(x: cachedBandXs[i],             y: ys[i])
            let p2 = NSPoint(x: cachedBandXs[i + 1],         y: ys[i + 1])
            let p3 = NSPoint(x: cachedBandXs[min(kNumBands - 1, i + 2)],
                              y: ys[min(kNumBands - 1, i + 2)])
            let c1 = NSPoint(x: p1.x + (p2.x - p0.x) / 6.0, y: p1.y + (p2.y - p0.y) / 6.0)
            let c2 = NSPoint(x: p2.x - (p3.x - p1.x) / 6.0, y: p2.y - (p3.y - p1.y) / 6.0)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        path.addLine(to: NSPoint(x: b.maxX, y: b.minY))
        path.closeSubpath()

        ctx.addPath(path)
        ctx.setFillColor(inkDark.withAlphaComponent(0.12).cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(0.9); ctx.setLineJoin(.round)
        ctx.strokePath()

        // ── Gain-reduction overlay — the actual limiting feedback ──────
        // A red area hanging from the TOP edge: the deeper it dips, the harder
        // the limiter is clamping right now. The scroll history shows the last
        // few seconds so transients you're catching are visible as spikes.
        let gr = abs(au.currentGainReductionDB)
        grHistory[grWrite % kGRHistory] = gr
        grWrite += 1

        let grPath = CGMutablePath()
        grPath.move(to: NSPoint(x: b.minX, y: b.maxY))
        for i in 0..<kGRHistory {
            let v = grHistory[(grWrite + i) % kGRHistory]
            let frac = CGFloat(min(kGRFullScale, v) / kGRFullScale)
            let x = b.minX + b.width * CGFloat(i) / CGFloat(kGRHistory - 1)
            grPath.addLine(to: NSPoint(x: x, y: b.maxY - frac * b.height * 0.85))
        }
        grPath.addLine(to: NSPoint(x: b.maxX, y: b.maxY))
        grPath.closeSubpath()
        ctx.addPath(grPath)
        ctx.setFillColor(red.withAlphaComponent(0.22).cgColor); ctx.fillPath()
        ctx.addPath(grPath)
        ctx.setStrokeColor(red.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(1.0); ctx.setLineJoin(.round); ctx.strokePath()

        // Numeric GR readout, top-right.
        let grAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .heavy),
            .foregroundColor: gr > 0.1 ? red : inkMid
        ]
        let grStr = NSString(string: String(format: "GR  −%.1f dB", Double(gr)))
        let gz = grStr.size(withAttributes: grAttr)
        grStr.draw(at: NSPoint(x: b.maxX - gz.width - 8, y: b.maxY - gz.height - 5), withAttributes: grAttr)
    }
}
