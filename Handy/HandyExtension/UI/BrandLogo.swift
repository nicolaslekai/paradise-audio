//
//  BrandLogo.swift — Paradise Audio shared brand mark ("Sunwave", 2026-11-20).
//
//  An 80s sun (solid top, horizon slices below) in Paradise red with the
//  Paradise wave running through it and out both sides in cream ink. Drawn
//  as pure vectors, so it is crisp at every size and on every backing scale.
//  Geometry is the master in Tools/logo/logo_concepts.swift (markSunwave);
//  below ~40 pt a simplified cut is drawn (fewer slices, fewer cycles,
//  stroke floors) so the mark still reads at the 14–18 pt footer size.
//
//  Cut-outs are knocked out to transparent inside a transparency layer, so
//  the faceplate texture shows through the slices and the wave channel.
//
import AppKit

enum BrandLogo {
    /// Sun colour — Paradise red (same hue as the rubber keys).
    static let sunColor  = NSColor(calibratedRed: 0.89, green: 0.20, blue: 0.16, alpha: 1.0)
    /// Wave colour — cream screen-print ink (Palette.inkLight).
    static let waveColor = NSColor(calibratedRed: 0.914, green: 0.875, blue: 0.788, alpha: 1.0)

    /// Draw the mark centred and aspect-fit (square) inside `rect`.
    static func draw(in rect: NSRect, ctx: CGContext) {
        let s = min(rect.width, rect.height)
        guard s > 0 else { return }
        let flipped = NSGraphicsContext.current?.isFlipped == true
        ctx.saveGState()
        // Work in an unflipped local space centred on the rect.
        ctx.translateBy(x: rect.midX, y: rect.midY)
        if flipped { ctx.scaleBy(x: 1, y: -1) }
        drawMark(ctx: ctx, size: s, sun: sunColor.cgColor, wave: waveColor.cgColor)
        ctx.restoreGState()
    }

    /// The mark around (0,0) in an unflipped space, `size` = bounding square.
    static func drawMark(ctx c: CGContext, size s: CGFloat, sun: CGColor, wave: CGColor) {
        let small = s < 40
        // wave tips (incl. round caps) stay inside the square — callers set text right after it
        let r = s * 0.37
        c.saveGState()
        c.setShouldAntialias(true)
        c.beginTransparencyLayer(auxiliaryInfo: nil)

        c.setFillColor(sun)
        c.fillEllipse(in: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r))

        // horizon slices — gaps grow towards the bottom
        c.setBlendMode(.clear)
        if small {
            let gap = max(1.0, r * 0.12)
            var y = -r * 0.22
            for i in 0..<3 {
                let g = gap * (1 + CGFloat(i) * 0.35)
                c.fill(CGRect(x: -r - 1, y: y - g, width: 2 * r + 2, height: g))
                y -= g + max(1.0, r * 0.22)
            }
        } else {
            var y = -r * 0.16
            var gap = r * 0.045
            for _ in 0..<5 {
                c.fill(CGRect(x: -r - 2, y: y - gap, width: 2 * r + 4, height: gap))
                y -= gap + r * 0.115 - gap * 0.35
                gap += r * 0.03
            }
        }

        // wave + its keep-out channel
        let stroke = small ? max(1.15, s * 0.065) : s * 0.034
        let channel = small ? stroke + max(1.3, s * 0.07) : s * 0.075
        let path = wavePath(halfW: s * 0.455 - stroke / 2,
                            cy: r * (small ? 0.22 : 0.20),
                            amp: r * (small ? 0.50 : 0.42),
                            cycles: small ? 2.5 : 3.5,
                            sigma: small ? 0.50 : 0.42, lead: 0.12)
        c.setLineCap(.round); c.setLineJoin(.round)
        c.addPath(path); c.setLineWidth(channel)
        c.setStrokeColor(CGColor(gray: 0, alpha: 1)); c.strokePath()
        c.setBlendMode(.normal)
        c.addPath(path); c.setLineWidth(stroke)
        c.setStrokeColor(wave); c.strokePath()

        c.endTransparencyLayer()
        c.restoreGState()
    }

    /// Gaussian-windowed sine with flat lead-in/out — the Paradise "breath".
    private static func wavePath(halfW: CGFloat, cy: CGFloat, amp: CGFloat,
                                 cycles: CGFloat, sigma: CGFloat, lead: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let n = 240
        for i in 0...n {
            let t = CGFloat(i) / CGFloat(n) * 2 - 1
            let core = max(0, abs(t) - lead) / (1 - lead)
            let env = exp(-pow(core / sigma, 2))
            let pt = CGPoint(x: t * halfW, y: cy + amp * env * sin(.pi * 2 * cycles * t))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}
