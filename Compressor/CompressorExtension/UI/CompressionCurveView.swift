//
//  CompressionCurveView.swift
//  Live SPECTRUM analyzer — the left visualiser. Instead of a fast scrolling
//  waveform, this draws an EQ-style live frequency spectrum: the INPUT spectrum
//  as a faint ghost and the COMPRESSED OUTPUT spectrum filled in red on top.
//  Where the compressor pulls energy down, the red output curve sits below the
//  input ghost — you watch the spectrum being smashed in real time. Bands come
//  from the DSP FFT probe (CompressorAudioUnit.readSpectrumIn:out:count:),
//  log-spaced 20 Hz–20 kHz and temporally smoothed so it reads smoothly.
//

import AppKit
import AudioToolbox

final class CompressionCurveView: NSView {
    var audioUnit: CompressorAudioUnit? { didSet { needsDisplay = true } }
    private var timer: Timer?

    private let panelBg = Palette.panelDark
    private let red     = Palette.red
    private let inkMid  = Palette.inkMidL
    private let inkDark = Palette.inkLight

    // Number of log-spaced bands the FFT is binned into.
    private let kBands = 64
    private lazy var inDB:  [Float] = Array(repeating: -90, count: kBands)
    private lazy var outDB: [Float] = Array(repeating: -90, count: kBands)

    private let minF: Float = 20, maxF: Float = 20000

    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.drawsAsynchronously = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.needsDisplay = true }
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    deinit { timer?.invalidate() }

    private func freqToX(_ hz: Float, in b: NSRect) -> CGFloat {
        let lo = log(minF), hi = log(maxF)
        let t = (log(max(minF, min(maxF, hz))) - lo) / (hi - lo)
        return b.minX + CGFloat(t) * b.width
    }
    private func dbToY(_ db: Float, in b: NSRect) -> CGFloat {
        let frac = CGFloat(max(-90, min(6, db)) + 90) / 96.0
        return b.minY + frac * b.height * 0.92
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds.insetBy(dx: 2, dy: 2)
        ctx.setFillColor(panelBg.cgColor); ctx.fill(b)
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.5).cgColor); ctx.setLineWidth(0.5); ctx.stroke(b)

        // Decade gridlines + labels (100 / 1k / 10k).
        ctx.setStrokeColor(inkMid.withAlphaComponent(0.30).cgColor); ctx.setLineWidth(0.5)
        let axis: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 7, weight: .regular), .foregroundColor: inkMid]
        for (hz, label) in [(Float(100), "100"), (1000, "1k"), (10000, "10k")] {
            let x = freqToX(hz, in: b)
            ctx.move(to: NSPoint(x: x, y: b.minY)); ctx.addLine(to: NSPoint(x: x, y: b.maxY)); ctx.strokePath()
            NSString(string: label).draw(at: NSPoint(x: x + 2, y: b.minY + 2), withAttributes: axis)
        }

        // Pull the live spectra.
        var drew = false
        if let au = audioUnit {
            let ok = inDB.withUnsafeMutableBufferPointer { ip -> Bool in
                outDB.withUnsafeMutableBufferPointer { op in
                    au.readSpectrum(in: ip.baseAddress!, out: op.baseAddress!, count: kBands)
                }
            }
            if ok {
                // Band index → X (bands are already log-spaced across 20 Hz–20 kHz).
                func bandX(_ i: Int) -> CGFloat { b.minX + CGFloat(i) / CGFloat(max(1, kBands - 1)) * b.width }

                // INPUT ghost — filled from the baseline.
                let inPath = CGMutablePath()
                inPath.move(to: NSPoint(x: b.minX, y: b.minY))
                for i in 0..<kBands { inPath.addLine(to: NSPoint(x: bandX(i), y: dbToY(inDB[i], in: b))) }
                inPath.addLine(to: NSPoint(x: b.maxX, y: b.minY)); inPath.closeSubpath()
                ctx.addPath(inPath); ctx.setFillColor(NSColor(calibratedWhite: 1.0, alpha: 0.10).cgColor); ctx.fillPath()
                ctx.addPath(inPath); ctx.setStrokeColor(inkDark.withAlphaComponent(0.5).cgColor); ctx.setLineWidth(0.8); ctx.strokePath()

                // COMPRESSED OUTPUT — red filled on top.
                let outPath = CGMutablePath()
                outPath.move(to: NSPoint(x: b.minX, y: b.minY))
                for i in 0..<kBands { outPath.addLine(to: NSPoint(x: bandX(i), y: dbToY(outDB[i], in: b))) }
                outPath.addLine(to: NSPoint(x: b.maxX, y: b.minY)); outPath.closeSubpath()
                ctx.addPath(outPath); ctx.setFillColor(red.withAlphaComponent(0.45).cgColor); ctx.fillPath()
                ctx.addPath(outPath); ctx.setStrokeColor(red.cgColor); ctx.setLineWidth(1.1); ctx.setLineJoin(.round); ctx.strokePath()
                drew = true
            }
        }
        if !drew {
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular), .foregroundColor: inkMid]
            let s = NSString(string: "— FEED AUDIO TO SEE THE SPECTRUM —")
            let sz = s.size(withAttributes: a)
            s.draw(at: NSPoint(x: b.midX - sz.width * 0.5, y: b.midY - 5), withAttributes: a)
        }

        // Header label + live GR readout.
        let lab: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 8, weight: .regular), .foregroundColor: inkMid]
        NSString(string: "SPECTRUM").draw(at: NSPoint(x: b.minX + 6, y: b.maxY - 12), withAttributes: lab)
        let gr = audioUnit?.currentGainReductionDB ?? 0
        let spec = NSString(string: String(format: "−%.1f dB GR", Double(gr)))
        let specAttr: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .heavy), .foregroundColor: gr > 0.1 ? red : inkDark]
        let sz = spec.size(withAttributes: specAttr)
        spec.draw(at: NSPoint(x: b.maxX - sz.width - 6, y: b.maxY - 13), withAttributes: specAttr)

        // Legend.
        let leg: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .heavy), .foregroundColor: NSColor.white.withAlphaComponent(0.55), .kern: 0.6]
        NSString(string: "INPUT ░  COMPRESSED ▰  ·  LIVE").draw(at: NSPoint(x: b.minX + 6, y: b.minY + 3), withAttributes: leg)
    }
}
