//
//  FaceTexture.swift — Paradise Audio shared faceplate texture (leather).
//
//  The bundled `leather.jpg` is loaded once from the extension bundle and
//  drawn at the START of each ParameterView's draw(_:) so the rest of the UI
//  renders on top. Aspect-fill, so it never distorts regardless of window size.
//
//  Per-view integration (one line at the top of draw()):
//     FaceTexture.draw(in: bounds, ctx: ctx)
//

import AppKit

enum FaceTexture {
    /// Decoded once, shared across all instances of this plug-in's view.
    static let cg: CGImage? = {
        let bundle = Bundle(for: FaceTextureToken.self)
        if let u = bundle.url(forResource: "leather", withExtension: "jpg"),
           let img = NSImage(contentsOf: u),
           let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return cg
        }
        return nil
    }()

    /// Fill `rect` with the texture (aspect-fill). Call first thing in draw().
    static func draw(in rect: NSRect, ctx: CGContext) {
        guard let cg = cg, rect.width > 0, rect.height > 0 else { return }
        let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
        let scale = max(rect.width / iw, rect.height / ih)
        let dw = iw * scale, dh = ih * scale
        let dx = rect.minX + (rect.width - dw) * 0.5
        let dy = rect.minY + (rect.height - dh) * 0.5
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.draw(cg, in: CGRect(x: dx, y: dy, width: dw, height: dh))
        ctx.restoreGState()
    }
}

private final class FaceTextureToken {}
