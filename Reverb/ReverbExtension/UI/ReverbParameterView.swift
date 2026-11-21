import AppKit
import AudioToolbox

final class ReverbParameterView: NSView {
    var audioUnit: ReverbAudioUnit? { didSet { rebind() } }
    // Dark faceplate (SynthThing/Compressor family): light ink on dark.
    private let cream  = Palette.cream
    private let inkDark = Palette.inkLight
    private let inkMid  = Palette.inkMidL
    private let red     = Palette.red
    private let faceBg  = Palette.faceBg
    private var knobs: [KnobView] = []
    // Space preview: Metal when the machine has a GPU device (always, on any
    // supported Mac), the CoreGraphics impulse view as the fallback.
    private let space: ReverbSpaceView? = ReverbSpaceView.isSupported ? ReverbSpaceView(frame: .zero, device: nil) : nil
    private let decay = ReverbDecayView(frame: .zero)
    private let undoCtl = ParamUndo()

    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; layer?.backgroundColor = faceBg.cgColor
        // GPU-accelerated CG rendering — see EZAudio benchmark.
        layer?.drawsAsynchronously = true
        if let sp = space { addSubview(sp) } else { addSubview(decay) }
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func layout() {
        super.layout()
        let pad: CGFloat = 18, footer: CGFloat = 44
        let kW: CGFloat = 78, kH: CGFloat = 116, sp: CGFloat = 10
        let cnt = CGFloat(knobs.count); let total = cnt * kW + max(0, cnt - 1) * sp
        let knobY = footer + 6
        var x = (bounds.width - total) * 0.5
        for k in knobs { k.frame = NSRect(x: x, y: knobY, width: kW, height: kH); x += kW + sp }

        let upperBottom = knobY + kH + 18
        let upperTop = bounds.height - 30
        let upperH = max(150, upperTop - upperBottom)
        let vizFrame = NSRect(x: pad, y: upperBottom, width: bounds.width - pad * 2, height: upperH)
        if let sp = space { sp.frame = vizFrame } else { decay.frame = vizFrame }
    }

    override func draw(_ r: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Subtle brushed-aluminium faceplate (keeps panel colour, adds analogue grain).
        FaceTexture.draw(in: bounds, ctx: ctx)
        let b = bounds
        // Standard suite footer (DESIGN.md §2) — shared BrandStrip helper.
        BrandStrip.drawFooter(ctx: ctx, bounds: b, plugin: "REVERB", code: "RVB-1",
                              spec: "AU v3 · STEREO", pad: 16, specAtTop: true)

        // Undo / redo — top-right, just under the spec tag.
        undoCtl.draw(in: b, ctx: ctx, ink: inkDark, mid: inkMid, pad: 16, y: b.height - 30)
        // SAVE / LOAD named presets — footer center-left, clear of brand + spec tag.
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if undoCtl.handleClick(p) { needsDisplay = true; return }
        super.mouseDown(with: event)
    }

    private func rebind() {
        knobs.forEach { $0.removeFromSuperview() }; knobs.removeAll()
        guard let au = audioUnit, let tree = au.parameterTree else { return }
        decay.audioUnit = au
        space?.audioUnit = au
        undoCtl.attach(au)
        undoCtl.onChange = { [weak self] in self?.needsDisplay = true }
        for node in tree.children {
            if let p = node as? AUParameter {
                let k = KnobView(frame: .zero); k.bind(parameter: p)
                switch p.identifier {
                case "size", "damping": k.displayFormatter = { String(format: "%.2f", $0) }
                case "decay":           k.displayFormatter = { String(format: "%.1fs", $0) }
                case "predelay":        k.displayFormatter = { String(format: "%.0fms", $0) }
                case "loCut", "hiCut":  k.displayFormatter = { v in v >= 1000 ? String(format: "%.1fk", v/1000) : String(format: "%.0fHz", v) }
                case "mix":             k.displayFormatter = { String(format: "%.0f%%", $0 * 100) }
                default: break
                }
                addSubview(k); knobs.append(k)
            }
        }
        for k in knobs { k.removeFromSuperview(); addSubview(k) }
        needsLayout = true; needsDisplay = true
    }
}

// Reverb tail / impulse-response decay visualization. Renders a swarm of red
// "reflection" lines decaying over a time window proportional to the DECAY
// parameter, with predelay gap before the first reflection.
final class ReverbDecayView: NSView {
    var audioUnit: ReverbAudioUnit?
    private var timer: Timer?
    private var phase: CGFloat = 0
    // Dark inset panel to match the dark faceplate.
    private let panelBg = Palette.panelDark
    private let red = Palette.red
    private let inkDark = Palette.inkLight
    private let inkMid = Palette.inkMidL

    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        // GPU-accelerated CG rendering — see EZAudio benchmark.
        layer?.drawsAsynchronously = true
        // Slow heartbeat redraw — once a second — so the view stays in sync
        // with parameter changes but doesn't shimmer when nothing moved.
        // (Previous version repainted 90 random sticks at 24 Hz; user called
        // it "too hectic and blippy".)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.needsDisplay = true
        }
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    deinit { timer?.invalidate() }

    override func draw(_ r: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds.insetBy(dx: 4, dy: 4)
        ctx.setFillColor(panelBg.cgColor); ctx.fill(b)
        PanelTex.draw(in: b, ctx: ctx)
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.6).cgColor); ctx.setLineWidth(0.5); ctx.stroke(b)

        // Parameter snapshot (Reverb addresses: 0=size 1=decay 2=damp 3=pre 4=loCut 5=hiCut 6=mix)
        let pre   = readParam(addr: 3, fallback: 12.0) / 200.0    // 0..200ms -> 0..1
        let decay = (readParam(addr: 1, fallback: 2.1) - 0.5) / 7.5 // 0.5..8s -> 0..1
        let damp  = readParam(addr: 2, fallback: 0.4)
        let size  = readParam(addr: 0, fallback: 0.65)

        // Baseline (acts as the time axis)
        ctx.setStrokeColor(inkMid.withAlphaComponent(0.45).cgColor); ctx.setLineWidth(0.5)
        ctx.move(to: NSPoint(x: b.minX, y: b.minY + 14))
        ctx.addLine(to: NSPoint(x: b.maxX, y: b.minY + 14)); ctx.strokePath()

        // Pre-delay gap — empty space before reflections start
        let preX = b.minX + CGFloat(pre) * b.width * 0.12

        // ── Discrete early reflections (3–5 sticks just after the predelay)
        // Their spacing depends on SIZE; their height depends on DECAY.
        let baselineY = b.minY + 14
        let envHeight = b.height - 22
        let sizeFactor = 0.6 + CGFloat(size) * 0.4
        let earlyTaps: [CGFloat] = [0.02, 0.05, 0.085, 0.13, 0.18]
        ctx.setLineCap(.round)
        for tap in earlyTaps {
            let t = tap * sizeFactor
            let x = preX + t * b.width
            if x > b.maxX - 4 { break }
            let amp = pow(1.0 - t * 2.0, 1.4)
            if amp <= 0 { continue }
            let h = max(2.0, amp * envHeight * 0.65)
            ctx.setStrokeColor(red.withAlphaComponent(0.85).cgColor)
            ctx.setLineWidth(1.4)
            ctx.move(to: NSPoint(x: x, y: baselineY))
            ctx.addLine(to: NSPoint(x: x, y: baselineY + h))
            ctx.strokePath()
        }

        // ── Late-tail decay envelope as a smooth filled curve.
        // amplitude(t) = peak * exp(-3t / decay) — textbook impulse-response
        // envelope. Damping pulls the curve down faster as t grows.
        let tailStartX = preX + 0.18 * sizeFactor * b.width
        let tailW = b.maxX - tailStartX
        let dec = CGFloat(decay) * 0.95 + 0.08
        // Build a CGMutablePath directly — NSBezierPath.cgPath is macOS 14+
        // and the project deploys to 11.0, so we can't use it.
        let tailPath = CGMutablePath()
        tailPath.move(to: NSPoint(x: tailStartX, y: baselineY))
        let steps = 64
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let x = tailStartX + t * tailW
            let damping = 1.0 - CGFloat(damp) * 0.55 * t
            let amp = exp(-3.0 * t / dec) * damping
            let h = max(0.0, amp) * envHeight * 0.55
            tailPath.addLine(to: NSPoint(x: x, y: baselineY + h))
        }
        tailPath.addLine(to: NSPoint(x: b.maxX, y: baselineY))
        tailPath.closeSubpath()
        ctx.saveGState()
        ctx.addPath(tailPath)
        ctx.setFillColor(red.withAlphaComponent(0.18).cgColor)
        ctx.fillPath()
        ctx.addPath(tailPath)
        ctx.setStrokeColor(red.withAlphaComponent(0.75).cgColor)
        ctx.setLineWidth(1.0)
        ctx.strokePath()
        ctx.restoreGState()

        // Pre-delay marker line
        ctx.setStrokeColor(inkMid.withAlphaComponent(0.6).cgColor); ctx.setLineWidth(0.5)
        ctx.setLineDash(phase: 0, lengths: [2, 2])
        ctx.move(to: NSPoint(x: preX, y: b.minY)); ctx.addLine(to: NSPoint(x: preX, y: b.maxY))
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])

        let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .regular), .foregroundColor: inkMid]
        NSString(string: "IMPULSE RESPONSE").draw(at: NSPoint(x: b.minX + 4, y: b.minY + 2), withAttributes: a)
        let decayS = 0.5 + Double(decay) * 7.5
        NSString(string: String(format: "DECAY %.2fs · DAMP %.0f%%", decayS, Double(damp * 100))).draw(at: NSPoint(x: b.minX + 4, y: b.maxY - 11), withAttributes: a)
    }

    private func readParam(addr: AUParameterAddress, fallback: Float) -> Float {
        guard let p = audioUnit?.parameterTree?.parameter(withAddress: addr) else { return fallback }
        return p.value
    }
}
