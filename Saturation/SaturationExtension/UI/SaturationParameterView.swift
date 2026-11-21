import AppKit
import AudioToolbox

final class SaturationParameterView: NSView {
    var audioUnit: SaturationAudioUnit? { didSet { rebind() } }

    private let cream = Palette.cream
    private let inkDark = Palette.inkLight
    private let inkMid  = Palette.inkMidL
    private let red     = Palette.red
    private let faceBg  = Palette.faceBg
    private let undoCtl = ParamUndo()
    private let presetUI = PresetUI(plugin: "Saturation")

    private var knobs: [KnobView] = []
    private let curve = TransferCurveView(frame: .zero)

    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.backgroundColor = faceBg.cgColor
        addSubview(curve)
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

        // Curve fills upper area
        let curveBottom = knobY + kH + 18
        let curveTop = bounds.height - 30
        let curveH = max(140, curveTop - curveBottom)
        let curveW = min(bounds.width - pad * 2, curveH * 1.4)
        let curveX = (bounds.width - curveW) * 0.5
        curve.frame = NSRect(x: curveX, y: curveBottom, width: curveW, height: curveH)
    }

    override func draw(_ r: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Subtle brushed-aluminium faceplate (keeps panel colour, adds analogue grain).
        FaceTexture.draw(in: bounds, ctx: ctx)
        // Guitar-amp grille-cloth weave + tolex speckle, grey-on-grey, on top of
        // the faceplate so the saturator reads with a bit of amp character.
        AmpTexture.draw(in: bounds, ctx: ctx)
        let b = bounds
        // Standard suite footer (DESIGN.md §2) — shared BrandStrip helper.
        BrandStrip.drawFooter(ctx: ctx, bounds: b, plugin: "SATURATION", code: "SAT-1",
                              spec: "AU v3 · STEREO", pad: 16, specAtTop: true)

        // Undo / redo — top-right, just under the spec tag.
        undoCtl.draw(in: b, ctx: ctx, ink: inkDark, mid: inkMid, pad: 16, y: b.height - 30)
        // SAVE / LOAD named presets — footer right, clear of the brand block.
        presetUI.draw(in: b, ctx: ctx, ink: inkDark, mid: inkMid, x: b.width - 110, y: 10)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if undoCtl.handleClick(p) { needsDisplay = true; return }
        if presetUI.handleClick(p, in: self) { return }
        super.mouseDown(with: event)
    }

    private func rebind() {
        knobs.forEach { $0.removeFromSuperview() }; knobs.removeAll()
        guard let au = audioUnit, let tree = au.parameterTree else { return }
        curve.audioUnit = au
        undoCtl.attach(au)
        undoCtl.onChange = { [weak self] in self?.needsDisplay = true }

        // Named presets (factory + user). Param addresses: drive=0 bias=1 tone=2 mix=3 out=4.
        presetUI.bind(tree: { [weak self] in self?.audioUnit?.parameterTree },
                      onLoad: { [weak self] in self?.needsDisplay = true })
        presetUI.setFactory([
            // Classic console / desk colours — each evokes the desk's saturation voice.
            ("NEVE 1073",  [0: 10.0, 1: 0.30, 2: -0.35, 3: 1.00, 4: -2.0]),  // warm thick low-mids
            ("SSL 4000",   [0:  6.0, 1: 0.10, 2:  0.10, 3: 1.00, 4: -1.0]),  // tight, punchy, clean
            ("API 2500",   [0: 16.0, 1: 0.20, 2:  0.30, 3: 1.00, 4: -3.0]),  // aggressive, mid-forward
            ("STUDER A800",[0:  7.0, 1: 0.05, 2: -0.20, 3: 0.85, 4: -1.5]),  // tape-ish, soft, rounded
            ("TRIDENT 80", [0:  9.0, 1: 0.15, 2:  0.45, 3: 1.00, 4: -2.0]),  // bright, musical
        ])
        for node in tree.children {
            if let p = node as? AUParameter {
                let k = KnobView(frame: .zero); k.bind(parameter: p)
                switch p.identifier {
                case "drive", "out": k.displayFormatter = { String(format: "%+.1fdB", $0) }
                case "bias", "tone": k.displayFormatter = { String(format: "%+.2f", $0) }
                case "mix":          k.displayFormatter = { String(format: "%.0f%%", $0 * 100) }
                default: break
                }
                addSubview(k); knobs.append(k)
            }
        }
        for k in knobs { k.removeFromSuperview(); addSubview(k) }
        needsLayout = true; needsDisplay = true
    }
}
