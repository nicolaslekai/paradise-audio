//
//  FaceTexture.swift — Paradise Audio faceplate + knob textures.
//
//  Minimal/analogue texture pack (Nano Banana renders, suite palette):
//   • FaceTexture — the dark brushed-aluminium faceplate, drawn over the solid
//     faceBg at low alpha so the exact panel colour is preserved and the grain
//     only adds subtle life. Call first thing in draw():
//        FaceTexture.draw(in: bounds, ctx: ctx)
//   • KnobTex / KnobVector — knob bodies drawn in code (gunmetal / ivory /
//     anodised red / knurled hero / LED dome). No bitmaps: crisp at any zoom,
//     with a small contact halo instead of a baked shadow disc.
//

import AppKit

private func loadCG(_ name: String, _ ext: String) -> CGImage? {
    let bundle = Bundle(for: FaceTextureToken.self)
    guard let u = bundle.url(forResource: name, withExtension: ext),
          let img = NSImage(contentsOf: u),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    return cg
}

/// Draw `img` into `rect` upright in both flipped and unflipped views
/// (CGContext.draw paints images upside-down in a flipped NSView).
func drawUpright(_ img: CGImage, in rect: CGRect, ctx: CGContext) {
    if NSGraphicsContext.current?.isFlipped == true {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: rect.minY + rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: rect)
        ctx.restoreGState()
    } else {
        ctx.draw(img, in: rect)
    }
}

enum FaceTexture {
    /// Painted teal-steel faceplate (analog scheme, 2026-11-20). Decoded once.
    static let teal: CGImage? = loadCG("faceplate_teal", "jpg")
    /// Legacy dark brushed-aluminium grain — fallback only.
    static let cg: CGImage? = teal ?? loadCG("faceplate_dark", "png")

    /// Paint the faceplate across `rect` (aspect-fill). The teal enamel is a
    /// full paint layer, so it goes on at full opacity regardless of `alpha`;
    /// `alpha` only applies to the legacy grain overlay fallback.
    static func draw(in rect: NSRect, ctx: CGContext, alpha: CGFloat = 0.55) {
        guard let cg = cg, rect.width > 0, rect.height > 0 else { return }
        let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
        let scale = max(rect.width / iw, rect.height / ih)
        let dw = iw * scale, dh = ih * scale
        let dx = rect.minX + (rect.width - dw) * 0.5
        let dy = rect.minY + (rect.height - dh) * 0.5
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.setAlpha(teal != nil ? 1.0 : alpha)
        drawUpright(cg, in: CGRect(x: dx, y: dy, width: dw, height: dh), ctx: ctx)
        ctx.restoreGState()
    }
}

/// Blender-rendered knob bodies (Tools/knob_bodies_blender.py) — one static
/// image per colour role, no pointer (KnobView paints it). Light from the
/// top-left, contact shadow baked into the alpha.
enum KnobSkin {
    /// Which body design the suite uses: "fluted" (whole body in the role
    /// colour) or "knurl" (silver knurl, painted cap). One line to switch.
    static let design = "fluted"
    /// Outer knob radius as a fraction of the image's half-width (from the
    /// Blender framing: ortho 3.0, radius 1.12 fluted / 1.22 knurl).
    static var radiusFraction: CGFloat { design == "knurl" ? 0.813 : 0.747 }
    static let dark:  CGImage? = loadCG("knob_\(design)_dark", "png")
    static let ivory: CGImage? = loadCG("knob_\(design)_ivory", "png")
    static let red:   CGImage? = loadCG("knob_\(design)_red", "png")

    /// Hero knobs (BigKnob = dark, PitchKnob = red), 1024 px renders:
    /// "fluted", "knurl" or "grip" (rubber grip + chrome dish).
    static let heroDesign = "grip"
    static var heroRadiusFraction: CGFloat { heroDesign == "knurl" ? 0.813 : 0.747 }
    static let heroDark: CGImage? = loadCG("knob_\(heroDesign)_dark_hero", "png")
    static let heroRed:  CGImage? = loadCG("knob_\(heroDesign)_red_hero", "png")

    static func image(for style: KnobStyle) -> CGImage? {
        switch style {
        case .gunmetal:    return dark
        case .ivory:       return ivory
        case .anodizedRed: return red
        case .plainSilver: return heroDark
        case .plainRed:    return heroRed
        default:           return nil
        }
    }

    static func fraction(for style: KnobStyle) -> CGFloat {
        (style == .plainSilver || style == .plainRed) ? heroRadiusFraction : radiusFraction
    }

    /// Pointer paint per body: cream on dark, charcoal on ivory, warm white on red.
    static func pointerColor(for style: KnobStyle) -> NSColor {
        switch style {
        case .ivory:       return NSColor(calibratedRed: 0.17, green: 0.16, blue: 0.15, alpha: 1)
        case .anodizedRed: return NSColor(calibratedRed: 0.97, green: 0.94, blue: 0.88, alpha: 1)
        default:           return Palette.inkLight
        }
    }

    /// Draw the body for `style` so its rim lands on radius `r`. False if no bitmap.
    @discardableResult
    static func draw(_ ctx: CGContext, center c: NSPoint, radius r: CGFloat, style: KnobStyle) -> Bool {
        guard let img = image(for: style), r > 2 else { return false }
        let half = r / fraction(for: style)
        ctx.saveGState()
        ctx.interpolationQuality = .high
        drawUpright(img, in: CGRect(x: c.x - half, y: c.y - half, width: half * 2, height: half * 2), ctx: ctx)
        ctx.restoreGState()
        return true
    }
}

/// Knob bodies — drawn in CODE (no bitmaps). Resolution-independent, so they
/// stay crisp at any Logic zoom, and the shadow is a small contact halo
/// instead of a baked-in dark disc. Light comes from the top-left.
enum KnobStyle {
    case gunmetal        // default dark body
    case ivory           // output-class knobs (mix / level / gain …)
    case anodizedRed     // accent knobs (EQ HP/LP)
    case knurledSilver   // machined ring + brushed dish (kept, unused)
    case knurledRed      // same machining, red anodised (kept, unused)
    case plainSilver     // BigKnob hero — one clean brushed disc
    case plainRed        // PitchKnob hero — one clean red disc
    case ledRed          // glossy red dome
}

enum KnobTex {
    // Style aliases so the single-knob plug-ins keep reading naturally
    // (`image: KnobTex.silver`).
    static let dark   = KnobStyle.gunmetal
    static let cream  = KnobStyle.ivory
    static let red    = KnobStyle.anodizedRed
    static let pitch  = KnobStyle.plainRed
    static let led    = KnobStyle.ledRed
    static let silver = KnobStyle.plainSilver
    static let black  = KnobStyle.gunmetal
    static let redInd = KnobStyle.plainRed

    /// Draw a knob body of an explicit style, centred on `c` with radius `r`.
    @discardableResult
    static func draw(_ ctx: CGContext, center c: NSPoint, radius r: CGFloat, image: KnobStyle?, zoom: CGFloat = 1.32) -> Bool {
        guard let style = image, r > 2 else { return false }
        KnobVector.draw(ctx, center: c, radius: r, style: style)
        return true
    }

    /// Pick the style from the body colour: red-ish → anodised red, light →
    /// ivory, everything else gunmetal.
    @discardableResult
    static func draw(_ ctx: CGContext, center c: NSPoint, radius r: CGFloat,
                     body: NSColor, zoom: CGFloat = 1.32) -> Bool {
        guard r > 2 else { return false }
        let rgb = body.usingColorSpace(.deviceRGB)
        let rr = rgb?.redComponent ?? 0, gg = rgb?.greenComponent ?? 0, bb = rgb?.blueComponent ?? 0
        let style: KnobStyle
        if rr > 0.5 && gg < 0.45 && bb < 0.45 { style = .anodizedRed }
        else if (rgb?.brightnessComponent ?? 0) > 0.5 { style = .ivory }
        else { style = .gunmetal }
        KnobVector.draw(ctx, center: c, radius: r, style: style)
        return true
    }
}

enum KnobVector {
    private static let cs = CGColorSpaceCreateDeviceRGB()
    private static func g(_ w: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(gray: w, alpha: a) }
    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }
    private static func radial(_ ctx: CGContext, colors: [CGColor], locs: [CGFloat], center: CGPoint, r0: CGFloat, r1: CGFloat, focus: CGPoint? = nil) {
        guard let grad = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs) else { return }
        ctx.drawRadialGradient(grad, startCenter: focus ?? center, startRadius: r0, endCenter: center, endRadius: r1, options: [.drawsAfterEndLocation])
    }

    static func draw(_ ctx: CGContext, center c: NSPoint, radius r: CGFloat, style: KnobStyle) {
        // Analog scheme: role knobs are the Blender bodies; vector code below
        // stays as the fallback and for the hero / LED styles.
        if KnobSkin.draw(ctx, center: c, radius: r, style: style) { return }
        let cp = CGPoint(x: c.x, y: c.y)
        let hi = CGPoint(x: c.x - r * 0.35, y: c.y + r * 0.40)   // light source, top-left
        let disc = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)

        // ── Contact shadow: a soft halo hugging the rim, nothing more ──
        ctx.saveGState()
        radial(ctx, colors: [g(0, 0.55), g(0, 0.28), g(0, 0)], locs: [0, 0.6, 1], center: cp, r0: r * 0.96, r1: r * 1.12)
        ctx.restoreGState()

        switch style {
        case .gunmetal, .ivory, .anodizedRed, .plainSilver, .plainRed:
            let top: CGColor, bot: CGColor, edge: CGColor
            switch style {
            case .ivory:       top = rgb(0.99, 0.97, 0.93); bot = rgb(0.80, 0.77, 0.71); edge = rgb(0.62, 0.59, 0.54)
            case .anodizedRed: top = rgb(0.97, 0.30, 0.25); bot = rgb(0.62, 0.09, 0.08); edge = rgb(0.40, 0.05, 0.05)
            case .plainSilver: top = g(0.60);               bot = g(0.36);               edge = g(0.22)   // hero: quiet brushed disc
            case .plainRed:    top = rgb(0.90, 0.26, 0.22); bot = rgb(0.60, 0.10, 0.09); edge = rgb(0.38, 0.05, 0.05)
            default:           top = g(0.34);               bot = g(0.11);               edge = g(0.05)
            }
            ctx.saveGState(); ctx.addEllipse(in: disc); ctx.clip()
            radial(ctx, colors: [top, bot, edge], locs: [0, 0.82, 1], center: cp, r0: 0, r1: r, focus: hi)
            // Brushed grain: faint concentric rings.
            ctx.setLineWidth(0.5)
            var k: CGFloat = 0.30
            while k < 0.95 {
                ctx.setStrokeColor(g(style == .ivory ? 0 : 1, 0.05))
                ctx.strokeEllipse(in: CGRect(x: c.x - r * k, y: c.y - r * k, width: r * k * 2, height: r * k * 2))
                k += 0.09
            }
            ctx.restoreGState()
            // Hero discs get a slimmer bevel so they stay calm at 400 px.
            let heroW = (style == .plainSilver || style == .plainRed) ? max(1.0, r * 0.012) : max(1.0, r * 0.05)
            bevel(ctx, center: cp, r: r, width: heroW, light: style == .ivory ? 0.9 : 0.55)

        case .knurledSilver, .knurledRed:
            let red = (style == .knurledRed)
            // Machined ring: alternating ridge facets between 0.72 r and the rim.
            let inner = r * 0.72
            ctx.saveGState(); ctx.addEllipse(in: disc); ctx.clip()
            // Ring base.
            if red { radial(ctx, colors: [rgb(0.80, 0.18, 0.15), rgb(0.48, 0.07, 0.06)], locs: [0, 1], center: cp, r0: inner, r1: r, focus: hi) }
            else   { radial(ctx, colors: [g(0.78), g(0.42)], locs: [0, 1], center: cp, r0: inner, r1: r, focus: hi) }
            let n = max(48, Int(r * 0.75)) & ~1
            let step = (2 * CGFloat.pi) / CGFloat(n)
            for i in 0..<n {
                let a0 = CGFloat(i) * step, a1 = a0 + step
                // Facet brightness follows the light direction so the ring reads as
                // three-dimensional ridges, not a flat stripe pattern.
                let mid = a0 + step * 0.5
                let lit = 0.5 + 0.5 * cos(mid - (.pi * 0.75))          // 1 towards top-left
                let even = (i % 2 == 0)
                let alpha = even ? 0.10 + 0.28 * lit : 0.42 - 0.30 * lit
                ctx.setFillColor(even ? g(1, alpha) : g(0, alpha))
                ctx.move(to: CGPoint(x: c.x + cos(a0) * inner, y: c.y + sin(a0) * inner))
                ctx.addArc(center: cp, radius: r + 1, startAngle: a0, endAngle: a1, clockwise: false)
                ctx.addArc(center: cp, radius: inner, startAngle: a1, endAngle: a0, clockwise: true)
                ctx.closePath(); ctx.fillPath()
            }
            ctx.restoreGState()
            bevel(ctx, center: cp, r: r, width: max(1.2, r * 0.035), light: 0.7)
            // Groove between ring and dish.
            ctx.setStrokeColor(g(0, 0.55)); ctx.setLineWidth(max(1.5, r * 0.03))
            ctx.strokeEllipse(in: CGRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2))
            // Brushed dish (slightly recessed).
            let dish = inner - max(1.5, r * 0.03)
            ctx.saveGState()
            ctx.addEllipse(in: CGRect(x: c.x - dish, y: c.y - dish, width: dish * 2, height: dish * 2)); ctx.clip()
            if red { radial(ctx, colors: [rgb(0.93, 0.30, 0.25), rgb(0.70, 0.13, 0.11), rgb(0.50, 0.08, 0.07)], locs: [0, 0.8, 1], center: cp, r0: 0, r1: dish, focus: hi) }
            else   { radial(ctx, colors: [g(0.86), g(0.66), g(0.50)], locs: [0, 0.8, 1], center: cp, r0: 0, r1: dish, focus: hi) }
            ctx.setLineWidth(0.5)
            var k: CGFloat = 0.12
            while k < 0.98 {
                ctx.setStrokeColor(g(0, 0.06))
                ctx.strokeEllipse(in: CGRect(x: c.x - dish * k, y: c.y - dish * k, width: dish * k * 2, height: dish * k * 2))
                k += 0.05
            }
            ctx.restoreGState()
            // Dish rim catch-light.
            bevel(ctx, center: cp, r: dish, width: max(1.0, r * 0.02), light: 0.8)

        case .ledRed:
            ctx.saveGState(); ctx.addEllipse(in: disc); ctx.clip()
            radial(ctx, colors: [rgb(1.0, 0.42, 0.34), rgb(0.88, 0.14, 0.12), rgb(0.50, 0.05, 0.05)], locs: [0, 0.65, 1],
                   center: cp, r0: 0, r1: r, focus: CGPoint(x: c.x - r * 0.25, y: c.y + r * 0.30))
            // Specular highlight on the dome.
            let hl = CGRect(x: c.x - r * 0.55, y: c.y + r * 0.15, width: r * 0.7, height: r * 0.45)
            radial(ctx, colors: [g(1, 0.45), g(1, 0)], locs: [0, 1], center: CGPoint(x: hl.midX, y: hl.midY), r0: 0, r1: hl.width * 0.5)
            ctx.restoreGState()
            bevel(ctx, center: cp, r: r, width: max(1.0, r * 0.04), light: 0.5)
        }
    }

    /// Rim bevel: light catch on the top-left arc, dark on the bottom-right.
    private static func bevel(_ ctx: CGContext, center c: CGPoint, r: CGFloat, width: CGFloat, light: CGFloat) {
        let rr = r - width * 0.5
        ctx.setLineWidth(width); ctx.setLineCap(.round)
        ctx.setStrokeColor(g(1, 0.55 * light))
        ctx.addArc(center: c, radius: rr, startAngle: .pi * 0.35, endAngle: .pi * 1.15, clockwise: false); ctx.strokePath()
        ctx.setStrokeColor(g(0, 0.55))
        ctx.addArc(center: c, radius: rr, startAngle: .pi * 1.35, endAngle: .pi * 2.15, clockwise: false); ctx.strokePath()
        // Hairline outline.
        ctx.setStrokeColor(g(0, 0.6)); ctx.setLineWidth(0.8)
        ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }
}

/// Raised 3D button / pill textures (dark = inactive, red = active). Filled into
/// a rounded-rect button so the suite's toggles read as physical keys.
enum ButtonTex {
    static let dark: CGImage? = loadCG("button_dark", "png")
    static let red:  CGImage? = loadCG("button_red", "png")
    /// Silicone rubber keys (analog scheme) — sliced into 9 so the rounded
    /// corners and bezel survive any button size / aspect.
    static let rubberDark:  [CGImage]? = slice9(loadCG("key_dark", "png"))
    static let rubberRed:   [CGImage]? = slice9(loadCG("key_red", "png"))
    static let rubberIvory: [CGImage]? = slice9(loadCG("key_ivory", "png"))

    private static func slice9(_ img: CGImage?) -> [CGImage]? {
        guard let img = img else { return nil }
        let w = img.width, h = img.height
        let c = Int(Double(min(w, h)) * 0.24)
        let xs = [0, c, w - c, w], ys = [0, c, h - c, h]
        var out: [CGImage] = []
        for j in 0..<3 { for i in 0..<3 {      // row-major from the image's TOP row
            guard let s = img.cropping(to: CGRect(x: xs[i], y: ys[j], width: xs[i + 1] - xs[i], height: ys[j + 1] - ys[j])) else { return nil }
            out.append(s)
        } }
        return out
    }

    /// Draw a rubber key filling `rect`. `kind`: 0 dark, 1 red, 2 ivory.
    @discardableResult
    static func drawRubber(_ ctx: CGContext, rect: NSRect, kind: Int) -> Bool {
        let slices: [CGImage]?
        switch kind { case 1: slices = rubberRed; case 2: slices = rubberIvory; default: slices = rubberDark }
        guard let s = slices, rect.width >= 2, rect.height >= 2 else { return false }
        let t = max(1.0, min(rect.width, rect.height) * 0.24)
        let flipped = NSGraphicsContext.current?.isFlipped == true
        // Destination columns left→right; rows top→bottom in VIEW terms.
        let xs = [rect.minX, rect.minX + t, rect.maxX - t, rect.maxX]
        let top = flipped ? rect.minY : rect.maxY
        let dir: CGFloat = flipped ? 1 : -1
        let ys = [top, top + dir * t, top + dir * (rect.height - t), top + dir * rect.height]
        ctx.saveGState()
        ctx.interpolationQuality = .high
        // Inner edges overlap by half a point so the slices never leave a
        // hairline seam at fractional pixel positions.
        let ov: CGFloat = 0.5
        for j in 0..<3 { for i in 0..<3 {
            let y0 = min(ys[j], ys[j + 1]), y1 = max(ys[j], ys[j + 1])
            let r = CGRect(x: xs[i], y: y0, width: xs[i + 1] - xs[i], height: y1 - y0)
            guard r.width > 0 && r.height > 0 else { continue }
            // grow every slice, then clip back to the key so outer edges stay exact
            drawUpright(s[j * 3 + i], in: r.insetBy(dx: -ov, dy: -ov).intersection(rect), ctx: ctx)
        } }
        ctx.restoreGState()
        return true
    }

    /// Raised key: rubber silicone keys (analog scheme); flat fill fallback.
    /// `active` = red. `corner` only applies to the fallback.
    @discardableResult
    static func draw(_ ctx: CGContext, rect: NSRect, active: Bool, corner: CGFloat = 4) -> Bool {
        guard rect.width > 3, rect.height > 3 else { return false }
        if drawRubber(ctx, rect: rect, kind: active ? 1 : 0) { return true }
        let cr = min(corner, min(rect.width, rect.height) * 0.5)
        let path = CGPath(roundedRect: rect, cornerWidth: cr, cornerHeight: cr, transform: nil)
        let top: CGColor, bot: CGColor
        if active {
            top = Palette.keyRedTop.cgColor
            bot = Palette.keyRedBot.cgColor
        } else {
            top = Palette.keyDarkTop.cgColor
            bot = Palette.keyDarkBot.cgColor
        }
        let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [top, bot] as CFArray, locations: [0, 1])!
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        ctx.drawLinearGradient(grad, start: CGPoint(x: rect.midX, y: rect.maxY),
                               end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        // Raised catch of light along the top edge.
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(active ? 0.32 : 0.20).cgColor)
        ctx.setLineWidth(1.2)
        ctx.move(to: CGPoint(x: rect.minX + cr, y: rect.maxY - 0.9))
        ctx.addLine(to: CGPoint(x: rect.maxX - cr, y: rect.maxY - 0.9))
        ctx.strokePath()
        ctx.restoreGState()
        // Outer border.
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.55).cgColor); ctx.setLineWidth(0.8)
        ctx.strokePath()
        return true
    }
}

/// Brushed-metal inset texture for visualiser / meter panels (so they read as
/// recessed metal rather than a flat grey box). Draw it after the panel's base
/// fill, before the graph content.
enum PanelTex {
    static let cg: CGImage? = loadCG("panel_inset", "png")

    static func draw(in rect: NSRect, ctx: CGContext, alpha: CGFloat = 0.5) {
        guard let cg = cg, rect.width > 0, rect.height > 0 else { return }
        let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
        let s = max(rect.width / iw, rect.height / ih)
        let dw = iw * s, dh = ih * s
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.setAlpha(alpha)
        ctx.draw(cg, in: CGRect(x: rect.midX - dw * 0.5, y: rect.midY - dh * 0.5, width: dw, height: dh))
        ctx.restoreGState()
    }
}

/// Drum-voice icon sheet (a 3×4 grid of flat red icons on black). Cells are
/// drawn with a `.lighten` blend so the black background drops out and only the
/// red icon shows over the faceplate.
enum IconSheet {
    static let cg: CGImage? = loadCG("drum_icons_sheet", "png")
    static let cols = 3, rows = 4

    @discardableResult
    static func draw(_ ctx: CGContext, cell index: Int, in rect: NSRect) -> Bool {
        guard let sheet = cg, index >= 0, index < cols * rows else { return false }
        let col = index % cols, row = index / cols
        let cw = sheet.width / cols, ch = sheet.height / rows
        guard let cellImg = sheet.cropping(to: CGRect(x: col * cw, y: row * ch, width: cw, height: ch)) else { return false }
        let iw = CGFloat(cellImg.width), ih = CGFloat(cellImg.height)
        let s = min(rect.width / iw, rect.height / ih)
        let dw = iw * s, dh = ih * s
        // The sheet now has a keyed (transparent) background, so a normal draw
        // composites just the red icon cleanly over the faceplate.
        ctx.draw(cellImg, in: CGRect(x: rect.midX - dw * 0.5, y: rect.midY - dh * 0.5, width: dw, height: dh))
        return true
    }
}

private final class FaceTextureToken {}
