//
//  AmpTexture.swift — Saturation-only faceplate overlay (grille cloth + tolex).
//  Split out of FaceTexture.swift so that file can stay identical suite-wide.
//
import AppKit

/// Code-rendered guitar-amp aesthetic for the Saturation faceplate. A fine
/// diagonal grille-cloth weave plus a sparse tolex speckle, all grey-on-grey at
/// low alpha so it reads as physical texture over the panel, not noise. Drawn
/// AFTER FaceTexture (which lays down the brushed-metal grain) so it sits on top.
enum AmpTexture {
    /// Overlay the amp grille + tolex over `rect`.
    static func draw(in rect: NSRect, ctx: CGContext,
                     weaveAlpha: CGFloat = 0.05, speckleAlpha: CGFloat = 0.04) {
        guard rect.width > 1, rect.height > 1 else { return }
        ctx.saveGState()
        ctx.clip(to: rect)

        // ── Grille-cloth weave: two crossing sets of thin diagonal lines so the
        // surface reads as woven cloth. One set lightens, the other darkens, for
        // a subtle in/out thread relief. Tight spacing keeps it as texture.
        let spacing: CGFloat = 5
        let diag = rect.width + rect.height
        ctx.setLineWidth(0.6)
        // Down-right threads (light).
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(weaveAlpha).cgColor)
        var d: CGFloat = -rect.height
        while d < rect.width {
            ctx.move(to: CGPoint(x: rect.minX + d, y: rect.minY))
            ctx.addLine(to: CGPoint(x: rect.minX + d + rect.height, y: rect.maxY))
            d += spacing
        }
        ctx.strokePath()
        // Down-left threads (dark) — offset so the two sets interleave into a weave.
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(weaveAlpha * 1.2).cgColor)
        d = -rect.height + spacing * 0.5
        while d < diag {
            ctx.move(to: CGPoint(x: rect.minX + d, y: rect.minY))
            ctx.addLine(to: CGPoint(x: rect.minX + d - rect.height, y: rect.maxY))
            d += spacing
        }
        ctx.strokePath()

        // ── Tolex speckle: sparse deterministic grey flecks for the vinyl-covering
        // grain. A fixed LCG keeps it stable frame-to-frame (no shimmer on redraw).
        var seed: UInt32 = 0x5A7C
        func rnd() -> CGFloat {
            seed = seed &* 1664525 &+ 1013904223
            return CGFloat((seed >> 8) & 0xFFFF) / 65535.0
        }
        let count = Int(rect.width * rect.height / 90.0)
        for _ in 0..<count {
            let x = rect.minX + rnd() * rect.width
            let y = rect.minY + rnd() * rect.height
            let s = 0.5 + rnd() * 0.9
            let light = rnd() > 0.5
            let a = speckleAlpha * (0.5 + rnd() * 0.5)
            ctx.setFillColor((light ? NSColor.white : NSColor.black).withAlphaComponent(a).cgColor)
            ctx.fillEllipse(in: CGRect(x: x, y: y, width: s, height: s))
        }

        ctx.restoreGState()
    }
}

private final class FaceTextureToken {}
