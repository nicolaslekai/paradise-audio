import AppKit
import AudioToolbox

/// De-esser — laid out as three numbered steps so it reads like a recipe:
///   1 FIND THE S   (FREQUENCY + LISTEN: hear only the band that gets cut)
///   2 WHEN         (THRESHOLD: how loud an S must be before it's tamed)
///   3 HOW MUCH     (RANGE: deepest cut · RELEASE: how fast it lets go)
/// plus a big live "S REDUCTION" readout, so you always see what it's doing.
final class DeesserParameterView: NSView {
    var audioUnit: DeesserAudioUnit? { didSet { rebind() } }
    private let inkDark = Palette.inkLight
    private let inkMid  = Palette.inkMidL
    private let red     = Palette.red
    private let faceBg  = Palette.faceBg
    private var knobs: [KnobView] = []
    private var listenOn = false
    private var listenRect = NSRect.zero
    private var listenToken: AUParameterObserverToken?
    private var grTimer: Timer?
    private var grValue: Float = 0
    private var grPeak: Float = 0
    private let spectrum = SibilanceBandView(frame: .zero)
    private let undoCtl = ParamUndo()
    // Step groups: knob identifiers per numbered step.
    private let steps: [(title: String, hint: String, ids: [String])] = [
        ("1  FIND THE S", "where the hiss lives", ["freq"]),
        ("2  WHEN", "how loud before it acts", ["threshold"]),
        ("3  HOW MUCH", "deepest cut · let-go speed", ["range", "release"]),
    ]
    private var stepFrames: [NSRect] = []
    private var rightCol = NSRect.zero

    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.backgroundColor = faceBg.cgColor
        addSubview(spectrum)
        grTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let v = self.audioUnit?.currentGainReductionDB ?? 0
            self.grValue = v
            self.grPeak = max(v, self.grPeak * 0.97)      // slow-falling peak hold
            self.needsDisplay = true
            self.spectrum.needsDisplay = true
        }
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    deinit {
        grTimer?.invalidate()
        if let t = listenToken { audioUnit?.parameterTree?.removeParameterObserver(t) }
    }

    private func setListen(_ on: Bool) {
        listenOn = on
        audioUnit?.parameterTree?.parameter(withAddress: 4)?.setValue(on ? 1 : 0, originator: nil)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 18, footer: CGFloat = 44
        let kW: CGFloat = 78, kH: CGFloat = 104, sp: CGFloat = 8, groupGap: CGFloat = 70
        let knobY = footer + 8
        // Step groups centred under the spectrum, with clear gaps between steps.
        let byId = Dictionary(uniqueKeysWithValues: knobs.compactMap { k in k.parameterIdentifier.map { ($0, k) } })
        let groupW = steps.map { CGFloat($0.ids.count) * kW + CGFloat(max(0, $0.ids.count - 1)) * sp }
        let total = groupW.reduce(0, +) + groupGap * CGFloat(steps.count - 1)
        let rightW: CGFloat = 176
        let leftW = bounds.width - pad * 2 - rightW - 16
        var x = pad + (leftW - total) * 0.5
        stepFrames = []
        for (i, st) in steps.enumerated() {
            let gx = x
            for id in st.ids {
                byId[id]?.frame = NSRect(x: x, y: knobY, width: kW, height: kH)
                x += kW + sp
            }
            x = gx + groupW[i] + groupGap
            stepFrames.append(NSRect(x: gx, y: knobY + kH + 2, width: groupW[i], height: 30))
        }
        // Spectrum fills the upper-left; the right column holds the readout + LISTEN.
        let upperBottom = knobY + kH + 40
        let upperTop = bounds.height - 58
        spectrum.frame = NSRect(x: pad, y: upperBottom, width: leftW, height: max(120, upperTop - upperBottom))
        rightCol = NSRect(x: bounds.width - pad - rightW, y: knobY, width: rightW, height: upperTop - knobY)
    }

    override func draw(_ r: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        FaceTexture.draw(in: bounds, ctx: ctx)
        let b = bounds

        // Headline: what this plug-in does, in one line.
        let h1: [NSAttributedString.Key: Any] = [.font: Palette.printFontCondensed(22), .foregroundColor: inkDark, .kern: 1.2]
        let h2: [NSAttributedString.Key: Any] = [.font: Palette.printFont(11), .foregroundColor: inkMid, .kern: 0.6]
        let t1 = NSString(string: "DE-ESSER"); let t1z = t1.size(withAttributes: h1)
        t1.draw(at: NSPoint(x: 18, y: b.height - 44), withAttributes: h1)
        NSString(string: "tames harsh  S · SH · T  sounds in vocals — only when they're too loud")
            .draw(at: NSPoint(x: 18 + t1z.width + 14, y: b.height - 38), withAttributes: h2)

        // Numbered step headings above each knob group.
        let sh: [NSAttributedString.Key: Any] = [.font: Palette.printFontCondensed(15), .foregroundColor: inkDark, .kern: 0.8]
        let sm: [NSAttributedString.Key: Any] = [.font: Palette.printFont(9), .foregroundColor: inkMid, .kern: 0.4]
        for (i, f) in stepFrames.enumerated() where i < steps.count {
            let hz0 = NSString(string: steps[i].hint).size(withAttributes: sm).width
            let w = max(f.width, hz0) + 10
            let fx = f.midX - w / 2
            ctx.setStrokeColor(inkDark.withAlphaComponent(0.35).cgColor); ctx.setLineWidth(0.6)
            ctx.move(to: NSPoint(x: fx, y: f.minY + 2)); ctx.addLine(to: NSPoint(x: fx + w, y: f.minY + 2)); ctx.strokePath()
            let t = NSString(string: steps[i].title); let tz = t.size(withAttributes: sh)
            t.draw(at: NSPoint(x: f.midX - tz.width / 2, y: f.minY + 15), withAttributes: sh)
            let hnt = NSString(string: steps[i].hint); let hz = hnt.size(withAttributes: sm)
            hnt.draw(at: NSPoint(x: f.midX - hz.width / 2, y: f.minY + 4), withAttributes: sm)
        }

        // Right column: big live reduction readout + meter + LISTEN key.
        let rc = rightCol
        let lab: [NSAttributedString.Key: Any] = [.font: Palette.printFontCondensed(15), .foregroundColor: inkDark, .kern: 1.0]
        NSString(string: "S REDUCTION").draw(at: NSPoint(x: rc.minX, y: rc.maxY - 20), withAttributes: lab)
        let big: [NSAttributedString.Key: Any] = [.font: Palette.printFontCondensed(44), .foregroundColor: grValue > 0.3 ? red : inkDark]
        NSString(string: grValue > 0.05 ? String(format: "−%.1f", grValue) : "0.0")
            .draw(at: NSPoint(x: rc.minX, y: rc.maxY - 72), withAttributes: big)
        NSString(string: "dB").draw(at: NSPoint(x: rc.maxX - 24, y: rc.maxY - 62), withAttributes: lab)
        // Horizontal meter well (0…20 dB), live bar + peak tick.
        let mw = NSRect(x: rc.minX, y: rc.maxY - 92, width: rc.width, height: 12)
        ctx.setFillColor(Palette.wellBg.cgColor); ctx.fill(mw)
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.4).cgColor); ctx.setLineWidth(0.5); ctx.stroke(mw)
        let fr = CGFloat(min(20, max(0, grValue)) / 20)
        ctx.setFillColor(red.cgColor); ctx.fill(NSRect(x: mw.minX + 1, y: mw.minY + 1, width: (mw.width - 2) * fr, height: mw.height - 2))
        let pk = CGFloat(min(20, max(0, grPeak)) / 20)
        if pk > 0.01 {
            ctx.setFillColor(inkDark.cgColor)
            ctx.fill(NSRect(x: mw.minX + 1 + (mw.width - 2) * pk - 1, y: mw.minY + 1, width: 2, height: mw.height - 2))
        }
        let tick: [NSAttributedString.Key: Any] = [.font: Palette.printFont(8), .foregroundColor: inkMid]
        for (i, t) in ["0", "5", "10", "15", "20"].enumerated() {
            let s = NSString(string: t); let z = s.size(withAttributes: tick)
            s.draw(at: NSPoint(x: mw.minX + mw.width * CGFloat(i) / 4 - z.width / 2, y: mw.minY - 12), withAttributes: tick)
        }
        // LISTEN rubber key — hear only what gets cut.
        listenRect = NSRect(x: rc.minX, y: mw.minY - 74, width: rc.width, height: 34)
        ButtonTex.draw(ctx, rect: listenRect, active: listenOn)
        let lk: [NSAttributedString.Key: Any] = [.font: Palette.printFontCondensed(16), .foregroundColor: Palette.inkLight, .kern: 1.2]
        let ls = NSString(string: "LISTEN"); let lz = ls.size(withAttributes: lk)
        ls.draw(at: NSPoint(x: listenRect.midX - lz.width / 2, y: listenRect.midY - lz.height / 2 + 1), withAttributes: lk)
        NSString(string: listenOn ? "you hear only the S band" : "solo the S band to find it")
            .draw(at: NSPoint(x: rc.minX, y: listenRect.minY - 16), withAttributes: sm)

        BrandStrip.drawFooter(ctx: ctx, bounds: b, plugin: "DE-ESSER", code: "DSR-1",
                              spec: "AU v3 · STEREO", pad: 16, specAtTop: true)
        undoCtl.draw(in: b, ctx: ctx, ink: inkDark, mid: inkMid, pad: 16, y: b.height - 30)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if undoCtl.handleClick(p) { needsDisplay = true; return }
        if listenRect.contains(p) { setListen(!listenOn); return }
        super.mouseDown(with: event)
    }

    private func rebind() {
        knobs.forEach { $0.removeFromSuperview() }; knobs.removeAll()
        guard let au = audioUnit, let tree = au.parameterTree else { return }
        spectrum.audioUnit = au
        undoCtl.attach(au)
        undoCtl.onChange = { [weak self] in self?.needsDisplay = true }
        for node in tree.children {
            if let p = node as? AUParameter, p.identifier != "listen" {
                let k = KnobView(frame: .zero); k.bind(parameter: p)
                switch p.identifier {
                case "freq":      k.displayFormatter = { v in v >= 1000 ? String(format: "%.1fk", v/1000) : String(format: "%.0fHz", v) }
                case "threshold", "range": k.displayFormatter = { String(format: "%.0fdB", $0) }
                case "release":   k.displayFormatter = { String(format: "%.0fms", $0) }
                default: break
                }
                addSubview(k); knobs.append(k)
            }
        }
        if let lp = tree.parameter(withAddress: 4) { listenOn = lp.value > 0.5 }
        // Keep LISTEN in step with undo / host automation.
        if let t = listenToken { tree.removeParameterObserver(t) }
        listenToken = tree.token(byAddingParameterObserver: { [weak self] addr, val in
            guard addr == 4 else { return }
            DispatchQueue.main.async { self?.listenOn = val > 0.5; self?.needsDisplay = true }
        })
        needsLayout = true; needsDisplay = true
    }
}
