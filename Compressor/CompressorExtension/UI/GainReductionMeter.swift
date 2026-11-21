//
//  GainReductionMeter.swift
//
//  Vertical bar meter with red fill on a gray track. Top = 0 dB GR,
//  bottom = -20 dB GR. Polled at ~30 Hz from the view controller.
//

import AppKit

final class GainReductionMeter: NSView {

    /// Current gain reduction in dB (positive number, 0..20).
    var valueDB: Float = 0 { didSet { needsDisplay = true } }

    /// Visible range — anything beyond this clamps to the bottom.
    var maxDB: Float = 20.0

    private let trackColor = NSColor(calibratedWhite: 0.78, alpha: 1.0)
    private let trackBg    = NSColor(calibratedWhite: 0.86, alpha: 1.0)
    private let fillColor  = Palette.accent
    private let inkDark    = Palette.inkDark

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 96) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds

        // Track
        let trackRect = NSRect(x: b.midX - 5, y: 14, width: 10, height: b.height - 28)
        ctx.setFillColor(trackBg.cgColor)
        ctx.fill(trackRect)
        ctx.setStrokeColor(trackColor.cgColor)
        ctx.setLineWidth(0.75)
        ctx.stroke(trackRect)

        // Red fill, growing downward from the top of the track
        let frac = CGFloat(min(maxDB, max(0, valueDB)) / maxDB)
        let fillHeight = trackRect.height * frac
        let fillRect = NSRect(x: trackRect.minX,
                              y: trackRect.maxY - fillHeight,
                              width: trackRect.width,
                              height: fillHeight)
        ctx.setFillColor(fillColor.cgColor)
        ctx.fill(fillRect)

        // Tick marks at 0, -6, -12, -18 dB
        let inset: CGFloat = 6
        for (db, major) in [(0.0 as Float, true), (6, false), (12, true), (18, false)] {
            let tFrac = CGFloat(db / maxDB)
            let y = trackRect.maxY - trackRect.height * tFrac
            ctx.setStrokeColor(inkDark.withAlphaComponent(0.55).cgColor)
            ctx.setLineWidth(0.5)
            ctx.move(to: NSPoint(x: trackRect.minX - inset, y: y))
            ctx.addLine(to: NSPoint(x: trackRect.minX - 2, y: y))
            ctx.strokePath()
            if major {
                let dbStr = NSString(string: db == 0 ? "0" : "-\(Int(db))")
                let a: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 7, weight: .regular),
                    .foregroundColor: inkDark
                ]
                dbStr.draw(at: NSPoint(x: 0, y: y - 4), withAttributes: a)
            }
        }

        // Label
        let titleAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 7, weight: .medium),
            .foregroundColor: inkDark, .kern: 0.4
        ]
        let title = NSString(string: "GR")
        let size = title.size(withAttributes: titleAttr)
        title.draw(at: NSPoint(x: (b.width - size.width) * 0.5, y: 2), withAttributes: titleAttr)
    }
}
