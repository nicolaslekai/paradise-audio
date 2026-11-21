//
//  ReverbSpaceView.swift — GPU (Metal) preview of the reverb space.
//
//  A single full-screen fragment shader draws the "room": rings radiating from
//  the source, spaced by SIZE, dying away over DECAY, losing their fine detail
//  with DAMPING, and breathing with the live output level. 30 fps, one
//  triangle, no textures — cheap enough to leave running, and it pauses the
//  moment the view leaves its window. If Metal is unavailable the old
//  CoreGraphics impulse-response view is shown instead (see ReverbParameterView).
//

import AppKit
import MetalKit

final class ReverbSpaceView: MTKView, MTKViewDelegate {
    var audioUnit: ReverbAudioUnit?

    private var pipeline: MTLRenderPipelineState?
    private var queue: MTLCommandQueue?
    private var start = CACurrentMediaTime()
    private var inLvl: Float = 0, outLvl: Float = 0
    private let overlay = ReverbSpaceOverlay(frame: .zero)

    /// Matches `Uniforms` in the shader source (16-byte aligned).
    private struct Uniforms {
        var time: Float, size: Float, decay: Float, damp: Float
        var pre: Float, mix: Float, inLevel: Float, outLevel: Float
        var resW: Float, resH: Float, pad0: Float, pad1: Float
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct Uniforms { float time, size, decay, damp, pre, mix, inLevel, outLevel, resW, resH, pad0, pad1; };
    struct VOut { float4 pos [[position]]; float2 uv; };
    vertex VOut vmain(uint vid [[vertex_id]]) {
        // One oversized triangle covering the viewport.
        float2 p = float2((vid == 1) ? 3.0 : -1.0, (vid == 2) ? 3.0 : -1.0);
        VOut o; o.pos = float4(p, 0, 1); o.uv = p; return o;
    }
    float hash21(float2 p) { p = fract(p * float2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }
    fragment float4 fmain(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float aspect = u.resW / max(1.0, u.resH);
        float2 uv = float2(in.uv.x * aspect, in.uv.y);           // centre = source
        float d = length(uv);
        // Room geometry: SIZE spreads the reflections, DECAY lets them travel further.
        float spacing = mix(0.10, 0.34, u.size);                  // ring pitch
        float reach   = mix(0.9, 4.5, u.decay);                   // how far the tail carries
        float speed   = mix(0.35, 0.12, u.size);                  // big rooms move slowly
        float phase   = d / spacing - u.time * speed;
        // Primary reflections: soft rings. Secondary: finer texture, killed by DAMPING.
        float ring  = 0.5 + 0.5 * cos(phase * 6.2831853);
        ring = pow(ring, 3.0);
        float fine  = 0.5 + 0.5 * cos(phase * 6.2831853 * 3.0 + 1.7);
        fine = pow(fine, 4.0) * (1.0 - u.damp) * 0.6;
        float env   = exp(-d * (3.0 / reach));                    // impulse-response envelope
        // Pre-delay: a quiet gap right around the source before the first ring.
        float gap   = smoothstep(0.02, 0.04 + u.pre * 0.12, d);
        float level = 0.35 + 0.65 * u.outLevel;
        float glow  = (ring + fine) * env * gap * level;
        // Source: a small pulse that follows the input.
        float src   = exp(-d * d * 900.0) * (0.35 + 0.65 * u.inLevel);
        // Faceplate grain so it does not look like a flat render.
        float grain = (hash21(floor(uv * 400.0) + floor(u.time * 7.0)) - 0.5) * 0.035;
        float3 panel = float3(0.17) + grain;
        float3 red   = float3(0.88, 0.14, 0.12);
        float3 cream = float3(0.82, 0.79, 0.74);
        float3 col = panel;
        col = mix(col, red, clamp(glow * u.mix * 1.6 + glow * 0.4, 0.0, 1.0));
        col += cream * pow(glow, 3.0) * 0.35 * u.mix;             // crest highlight
        col = mix(col, cream, clamp(src, 0.0, 1.0));
        // Vignette to keep the edges calm.
        col *= 1.0 - smoothstep(0.9, 1.6, d) * 0.35;
        return float4(col, 1.0);
    }
    """

    static var isSupported: Bool { MTLCreateSystemDefaultDevice() != nil }

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device ?? MTLCreateSystemDefaultDevice())
        colorPixelFormat = .bgra8Unorm
        preferredFramesPerSecond = 30
        isPaused = false
        enableSetNeedsDisplay = false
        framebufferOnly = true
        clearColor = MTLClearColor(red: 0.17, green: 0.17, blue: 0.17, alpha: 1)
        delegate = self
        buildPipeline()
        addSubview(overlay)
    }
    required init(coder: NSCoder) { fatalError("no") }

    private func buildPipeline() {
        guard let dev = device else { return }
        queue = dev.makeCommandQueue()
        do {
            let lib = try dev.makeLibrary(source: Self.shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: "vmain")
            desc.fragmentFunction = lib.makeFunction(name: "fmain")
            desc.colorAttachments[0].pixelFormat = colorPixelFormat
            pipeline = try dev.makeRenderPipelineState(descriptor: desc)
        } catch {
            pipeline = nil
        }
    }

    override func layout() { super.layout(); overlay.frame = bounds }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isPaused = (window == nil)            // never burn GPU with the editor closed
    }

    private func param(_ addr: AUParameterAddress, _ fallback: Float) -> Float {
        audioUnit?.parameterTree?.parameter(withAddress: addr)?.value ?? fallback
    }

    // MARK: MTKViewDelegate
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard let pipeline = pipeline, let queue = queue,
              let drawable = currentDrawable, let rpd = currentRenderPassDescriptor else { return }
        // Smooth the live levels so the picture breathes instead of flickering.
        let tIn = audioUnit?.inputLevel ?? 0, tOut = audioUnit?.outputLevel ?? 0
        inLvl  += (min(1, tIn  * 2.5) - inLvl)  * (tIn  > inLvl  ? 0.5 : 0.08)
        outLvl += (min(1, tOut * 2.5) - outLvl) * (tOut > outLvl ? 0.5 : 0.06)
        var u = Uniforms(time: Float(CACurrentMediaTime() - start),
                         size: param(0, 0.65),
                         decay: (param(1, 2.1) - 0.5) / 7.5,
                         damp: param(2, 0.4),
                         pre: param(3, 12) / 200,
                         mix: max(0.25, param(6, 0.35)),
                         inLevel: inLvl, outLevel: outLvl,
                         resW: Float(drawableSize.width), resH: Float(drawableSize.height), pad0: 0, pad1: 0)
        guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
        overlay.audioUnit = audioUnit
        overlay.needsDisplay = true
    }
}

/// Transparent CoreGraphics overlay: frame, caption and the live readout on
/// top of the Metal picture.
final class ReverbSpaceOverlay: NSView {
    var audioUnit: ReverbAudioUnit?
    private let inkDark = Palette.inkLight
    private let inkMid  = Palette.inkMidL
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer?.backgroundColor = NSColor.clear.cgColor }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ r: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds.insetBy(dx: 0.5, dy: 0.5)
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.6).cgColor); ctx.setLineWidth(0.5); ctx.stroke(b)
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .regular), .foregroundColor: inkMid, .kern: 0.5]
        NSString(string: "SPACE").draw(at: NSPoint(x: b.minX + 5, y: b.minY + 3), withAttributes: a)
        let decay = audioUnit?.parameterTree?.parameter(withAddress: 1)?.value ?? 2.1
        let damp  = audioUnit?.parameterTree?.parameter(withAddress: 2)?.value ?? 0.4
        let size  = audioUnit?.parameterTree?.parameter(withAddress: 0)?.value ?? 0.65
        NSString(string: String(format: "SIZE %.2f · DECAY %.2fs · DAMP %.0f%%", size, decay, damp * 100))
            .draw(at: NSPoint(x: b.minX + 5, y: b.maxY - 12), withAttributes: a)
    }
}
