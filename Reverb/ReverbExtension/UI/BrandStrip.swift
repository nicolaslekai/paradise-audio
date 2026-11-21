//
//  BrandStrip.swift — Paradise Audio shared brand chrome (DESIGN.md §2).
//
//  CANONICAL COPY lives in  <root>/Shared/UI/BrandStrip.swift.  Every
//  *Extension/UI/ folder carries an identical copy; run
//  `./sync_shared_ui.sh` after editing the canonical file.
//
//  Two helpers so no plug-in hand-rolls its own footer / top bar again:
//
//    BrandStrip.drawFooter(ctx: ctx, bounds: bounds,
//                          plugin: "DELAY", code: "DLY-1", spec: "AU v3 · STEREO")
//        → logo at x=16, "PARADISE AUDIO" 9pt semibold, "<PLUGIN> — <CODE>"
//          caption, the 0.5px hairline at y=36, spec tag bottom-right.
//
//    BrandStrip.drawTopBar(ctx: ctx, bounds: bounds, title: "DUB DELAY", code: "DLY-1")
//        → the dark wellBg band with the 2px red stripe used by the
//          SynthThing / Compressor / Delay family. Returns the bar rect so
//          the caller can place undo / sync chrome inside it.
//
//  Typography snaps to the 7 / 9 / 11 / 13 / 16 scale.
//
import AppKit

enum BrandStrip {
    static let brandText = "PARADISE AUDIO"
    static let footerHeight: CGFloat = 44
    static let hairlineY: CGFloat = 36

    /// Standard footer brand block + hairline + spec tag.
    /// - Parameters:
    ///   - specAtTop: put the spec tag top-right (some plug-ins keep the
    ///     bottom-right corner for other chrome). Default: bottom-right.
    static func drawFooter(ctx: CGContext, bounds b: NSRect,
                           plugin: String, code: String, spec: String,
                           pad: CGFloat = 16, specAtTop: Bool = false) {
        let ink = Palette.inkLight, mid = Palette.inkMidL
        // Logo (aspect-fit, 16px) — replaces the old red brand square.
        ctx.setFillColor(Palette.red.cgColor)
        BrandLogo.draw(in: NSRect(x: pad - 4, y: 2, width: 30, height: 30), ctx: ctx)
        let brand: [NSAttributedString.Key: Any] = [.font: Palette.printFontCondensed(11), .foregroundColor: ink, .kern: 1.2]
        NSString(string: brandText).draw(at: NSPoint(x: pad + 30, y: 15), withAttributes: brand)
        let sub: [NSAttributedString.Key: Any] = [.font: Palette.printFont(7.5), .foregroundColor: mid, .kern: 0.6]
        NSString(string: "\(plugin) — \(code)").draw(at: NSPoint(x: pad + 30, y: 4), withAttributes: sub)
        // Hairline divider.
        ctx.setStrokeColor(ink.withAlphaComponent(0.25).cgColor); ctx.setLineWidth(0.5)
        ctx.move(to: NSPoint(x: pad, y: hairlineY)); ctx.addLine(to: NSPoint(x: b.width - pad, y: hairlineY)); ctx.strokePath()
        // Spec tag.
        let tag: [NSAttributedString.Key: Any] = [.font: Palette.printFont(7.5), .foregroundColor: mid, .kern: 0.5]
        let ts = NSString(string: spec); let tw = ts.size(withAttributes: tag)
        let ty: CGFloat = specAtTop ? (b.height - 14) : 14
        ts.draw(at: NSPoint(x: b.width - tw.width - pad, y: ty), withAttributes: tag)
    }

    /// Dark top bar with the red stripe (SynthThing / Compressor / Delay family).
    @discardableResult
    static func drawTopBar(ctx: CGContext, bounds b: NSRect, title: String, code: String,
                           height: CGFloat = 42, pad: CGFloat = 16) -> NSRect {
        let bar = NSRect(x: 0, y: b.height - height, width: b.width, height: height)
        ctx.setFillColor(Palette.wellBg.cgColor); ctx.fill(bar)
        ctx.setFillColor(Palette.red.cgColor); ctx.fill(NSRect(x: 0, y: bar.minY, width: bar.width, height: 2))
        let cy = bar.midY
        BrandLogo.draw(in: NSRect(x: pad - 3, y: cy - 15, width: 30, height: 30), ctx: ctx)
        let brand: [NSAttributedString.Key: Any] = [.font: Palette.printFontCondensed(14), .foregroundColor: Palette.inkLight, .kern: 1.4]
        let bs = NSString(string: brandText); let bz = bs.size(withAttributes: brand)
        bs.draw(at: NSPoint(x: pad + 32, y: cy - bz.height * 0.5), withAttributes: brand)
        let tag: [NSAttributedString.Key: Any] = [.font: Palette.printFont(9.5), .foregroundColor: Palette.inkMidL, .kern: 0.6]
        let ts = NSString(string: "\(title) · \(code)"); let tz = ts.size(withAttributes: tag)
        ts.draw(at: NSPoint(x: pad + 32 + bz.width + 14, y: cy - tz.height * 0.5), withAttributes: tag)
        return bar
    }
}
