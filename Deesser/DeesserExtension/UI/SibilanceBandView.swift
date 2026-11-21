//
//  SibilanceBandView.swift
//  Spectrum-style visual feedback for the De-esser. A light gray graph with:
//   - frequency labels along the bottom (1k / 3k / 6k / 10k)
//   - a red rectangle highlighting the band centered on the FREQUENCY knob
//     (about ±1 octave wide, like the BP sidechain Q)
//   - a dashed horizontal threshold line at THRESHOLD dB
//   - a small red gain-reduction pulse on the right that grows when the
//     compressor is actually reducing gain (driven by currentGainReductionDB)
//

import AppKit
import AudioToolbox

final class SibilanceBandView: NSView {
    var audioUnit: DeesserAudioUnit?
    private var timer: Timer?

    private let panelBg = Palette.panelDark
    private let inkDark = Palette.inkLight
    private let inkMid  = Palette.inkMidL
    private let red     = Palette.red

    // Frequency axis: 200 Hz – 20 kHz, log-scaled
    private let minF: Float = 200.0
    private let maxF: Float = 20000.0

    // Live FFT spectrum bands (log-spaced)
    private let kNumBands: Int = 96
    private lazy var spectrumDB: [Float] = Array(repeating: -90, count: kNumBands)

    // Parameter addresses (match DeesserAudioUnit.mm)
    private let kFreq = AUParameterAddress(0)
    private let kThr  = AUParameterAddress(1)

    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        // GPU-accelerated CG rendering — see EZAudio benchmark.
        layer?.drawsAsynchronously = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.needsDisplay = true }
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    deinit { timer?.invalidate() }

    private func freqToX(_ f: Float, in b: NSRect) -> CGFloat {
        let logMin = log(minF), logMax = log(maxF)
        let lf = log(max(minF, min(maxF, f)))
        return b.minX + b.width * CGFloat((lf - logMin) / (logMax - logMin))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds.insetBy(dx: 4, dy: 4)

        // Background
        ctx.setFillColor(panelBg.cgColor); ctx.fill(b)
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.55).cgColor); ctx.setLineWidth(0.5); ctx.stroke(b)

        // Live spectrum — filled grey area under the curve
        if let au = audioUnit {
            spectrumDB.withUnsafeMutableBufferPointer { ptr in
                if let base = ptr.baseAddress {
                    _ = au.readSpectrumBands(base, count: Int32(kNumBands))
                }
            }
            // Map spectrum frequency to x. The view covers 200 Hz – 20 kHz so
            // we map FFT band frequency (20 Hz – 20 kHz) to this view's range.
            let logSpecMin = log(Float(20)), logSpecMax = log(Float(20000))
            ctx.saveGState()
            ctx.setFillColor(inkDark.withAlphaComponent(0.20).cgColor)
            let fill = CGMutablePath()
            fill.move(to: NSPoint(x: b.minX, y: b.minY))
            for i in 0..<kNumBands {
                let t = Float(i) / Float(max(1, kNumBands - 1))
                let hz = exp(logSpecMin + t * (logSpecMax - logSpecMin))
                if hz < minF { continue }
                let x = freqToX(hz, in: b)
                let dB = max(-90, min(6, spectrumDB[i]))
                let frac = CGFloat((dB + 90) / 96)
                let y = b.minY + frac * b.height * 0.92
                fill.addLine(to: NSPoint(x: x, y: y))
            }
            fill.addLine(to: NSPoint(x: b.maxX, y: b.minY))
            fill.closeSubpath()
            ctx.addPath(fill); ctx.fillPath()
            ctx.restoreGState()
        }

        // Decade gridlines
        ctx.setStrokeColor(inkMid.withAlphaComponent(0.3).cgColor); ctx.setLineWidth(0.5)
        for f in [Float(1000), 3000, 6000, 10000] {
            let x = freqToX(f, in: b)
            ctx.move(to: NSPoint(x: x, y: b.minY + 14)); ctx.addLine(to: NSPoint(x: x, y: b.maxY))
        }
        ctx.strokePath()

        // Sibilance band (red rectangle, ±1 octave around current freq)
        let freq = audioUnit?.parameterTree?.parameter(withAddress: kFreq)?.value ?? 6500
        let bandLo = freq * 0.5    // 1 octave down
        let bandHi = freq * 2.0    // 1 octave up
        let xLo = freqToX(bandLo, in: b)
        let xHi = freqToX(bandHi, in: b)
        let bandRect = NSRect(x: xLo, y: b.minY + 14, width: xHi - xLo, height: b.height - 14)
        ctx.setFillColor(red.withAlphaComponent(0.26).cgColor); ctx.fill(bandRect)
        ctx.setStrokeColor(red.withAlphaComponent(0.8).cgColor); ctx.setLineWidth(0.8); ctx.stroke(bandRect)
        // Say what the red area IS — the band that gets turned down.
        let bandLab: [NSAttributedString.Key: Any] = [.font: Palette.printFont(10), .foregroundColor: inkDark, .kern: 0.8]
        let fTxt = freq >= 1000 ? String(format: "%.1fk", freq / 1000) : String(format: "%.0f Hz", freq)
        let bl = NSString(string: "S BAND · \(fTxt)"); let blz = bl.size(withAttributes: bandLab)
        bl.draw(at: NSPoint(x: max(bandRect.minX + 4, min(bandRect.maxX - blz.width - 4, bandRect.midX - blz.width / 2)),
                            y: b.maxY - blz.height - 4), withAttributes: bandLab)

        // Center freq tick + label
        let xCenter = freqToX(freq, in: b)
        ctx.setStrokeColor(red.cgColor); ctx.setLineWidth(1.2)
        ctx.move(to: NSPoint(x: xCenter, y: b.minY + 14)); ctx.addLine(to: NSPoint(x: xCenter, y: b.maxY)); ctx.strokePath()

        // Threshold dashed line
        let thr = audioUnit?.parameterTree?.parameter(withAddress: kThr)?.value ?? -32.0
        // Map threshold (-60..0, the parameter's real range) to vertical position
        let thrFrac = CGFloat(max(0.0, min(1.0, (thr + 60.0) / 60.0)))   // 0..1
        let thrY = b.minY + 14 + (b.height - 14) * (1.0 - thrFrac)
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.65).cgColor); ctx.setLineWidth(0.7)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.move(to: NSPoint(x: b.minX, y: thrY)); ctx.addLine(to: NSPoint(x: b.maxX, y: thrY)); ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        let thrLab: [NSAttributedString.Key: Any] = [.font: Palette.printFont(9), .foregroundColor: inkDark.withAlphaComponent(0.85), .kern: 0.6]
        NSString(string: String(format: "THRESHOLD %.0f dB — louder S gets turned down", thr))
            .draw(at: NSPoint(x: b.minX + 6, y: thrY + 3), withAttributes: thrLab)

        // Tiny axis labels
        let attr: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 7, weight: .regular), .foregroundColor: inkMid]
        for (f, label) in [(1000, "1k"), (3000, "3k"), (6000, "6k"), (10000, "10k")] {
            let x = freqToX(Float(f), in: b)
            NSString(string: label).draw(at: NSPoint(x: x - 5, y: b.minY + 2), withAttributes: attr)
        }
    }
}
