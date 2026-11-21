//
//  KnobView.swift — Paradise Audio shared rotary knob (DESIGN.md §3).
//
//  CANONICAL COPY lives in  <root>/Shared/UI/KnobView.swift.  Every
//  *Extension/UI/ folder carries an identical copy; run
//  `./sync_shared_ui.sh` after editing the canonical file. (Drums keeps its
//  own compact 28 px per-voice variant on purpose.)
//
//  Bound to one AUParameter. Screen-printed tick ring, Blender-rendered
//  knob body (KnobSkin: dark by default, ivory for output-class knobs, red
//  for `isAccent` boundary knobs such as the EQ's HP/LP), painted pointer
//  line, DIN label + value below.
//  Vertical drag (⌥ = fine), scroll wheel, double-click = default.
//
import AppKit
import AudioToolbox

final class KnobView: NSControl {
    private weak var parameter: AUParameter?
    private var observerToken: AUParameterObserverToken?
    var title: String = "" { didSet { needsDisplay = true } }
    var displayFormatter: ((Float) -> String)? = nil
    /// Identifier of the bound parameter — lets a parent view find a knob
    /// by name (e.g. to place chrome above it).
    var parameterIdentifier: String? { parameter?.identifier }
    /// Paradise convention: any output/level/volume/mix/master/gain
    /// knob renders with a white body. Auto-set in `bind`.
    var isOutput: Bool = false { didSet { needsDisplay = true } }
    /// Accent knobs (EQ HP/LP boundaries) render with a red body + white
    /// cap and pointer so they stand out from the regular bank.
    var isAccent: Bool = false { didSet { needsDisplay = true } }

    private(set) var value: Float = 0 { didSet { needsDisplay = true } }
    var minValue: Float = 0, maxValue: Float = 1, defaultValue: Float = 0
    var isLogarithmic = false

    override init(frame f: NSRect) { super.init(frame: f); wantsLayer = true }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    deinit { if let t = observerToken { parameter?.removeParameterObserver(t) } }

    func bind(parameter p: AUParameter) {
        self.parameter = p; self.title = p.displayName.uppercased()
        minValue = Float(p.minValue); maxValue = Float(p.maxValue)
        defaultValue = Float(p.value); value = Float(p.value)
        if p.unit == .hertz && p.maxValue > 100 { isLogarithmic = true }
        if p.unit == .milliseconds && p.maxValue > 100 { isLogarithmic = true }
        let _id = p.identifier.lowercased()
        let _nm = p.displayName.lowercased()
        let _outKW = ["mix","level","output","out","volume","vol","master","gain","trim"]
        if _outKW.contains(where: { _id == $0 || _nm == $0 || _nm.contains($0) }) {
            self.isOutput = true
        }
        observerToken = p.token(byAddingParameterObserver: { [weak self] _, v in DispatchQueue.main.async { self?.value = Float(v) } })
        needsDisplay = true
    }
    override var intrinsicContentSize: NSSize { NSSize(width: 60, height: 96) }

    override func draw(_ r: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds
        let inkLight = Palette.inkLight
        let inkMidL  = Palette.inkMidL
        let d: CGFloat = min(b.width - 8, b.height - 34)
        let rad = d * 0.5
        let c = NSPoint(x: b.midX, y: b.height - 10 - rad)
        let n = CGFloat(normalized())
        // Colour ROLE (unchanged rule): red = accent, white = output, dark = rest.
        let style: KnobStyle = isAccent ? .anodizedRed : (isOutput ? .ivory : .gunmetal)
        let s: CGFloat = .pi * 1.25, e: CGFloat = -.pi * 0.25

        // Screen-printed tick ring on the faceplate, just outside the knob.
        ctx.setStrokeColor(inkLight.withAlphaComponent(0.70).cgColor); ctx.setLineWidth(0.8)
        for i in 0..<14 {
            let f = CGFloat(i) / 13.0; let a = s - f * (s - e)
            ctx.move(to: NSPoint(x: c.x + cos(a) * (rad + 1.5), y: c.y + sin(a) * (rad + 1.5)))
            ctx.addLine(to: NSPoint(x: c.x + cos(a) * (rad + 4.5), y: c.y + sin(a) * (rad + 4.5)))
        }
        ctx.strokePath()

        // Body: Blender-rendered knob (KnobSkin); vector fallback via KnobVector.
        let bodyR = NSRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2)
        if !KnobTex.draw(ctx, center: c, radius: rad, image: style) {
            ctx.setFillColor(Palette.knobBody.cgColor); ctx.fillEllipse(in: bodyR)
        }
        // Painted pointer line (no separate cap — the knob is one moulded part).
        let ang = s - n * (s - e)
        ctx.setStrokeColor(KnobSkin.pointerColor(for: style).cgColor)
        ctx.setLineWidth(max(2.0, rad * 0.11)); ctx.setLineCap(.round)
        ctx.move(to: NSPoint(x: c.x + cos(ang) * (rad * 0.30), y: c.y + sin(ang) * (rad * 0.30)))
        ctx.addLine(to: NSPoint(x: c.x + cos(ang) * (rad * 0.80), y: c.y + sin(ang) * (rad * 0.80))); ctx.strokePath()

        // Label + value — cream screen print in DIN.
        let lAttr: [NSAttributedString.Key: Any] = [.font: Palette.printFont(9.5), .foregroundColor: inkLight, .kern: 0.6]
        let t = NSString(string: title); let sz = t.size(withAttributes: lAttr)
        t.draw(at: NSPoint(x: b.midX - sz.width * 0.5, y: 12), withAttributes: lAttr)
        let vs = displayFormatter?(value) ?? defaultFormat(value)
        let vAttr: [NSAttributedString.Key: Any] = [.font: Palette.printFont(9), .foregroundColor: inkMidL]
        let vstr = NSString(string: vs); let vsz = vstr.size(withAttributes: vAttr)
        vstr.draw(at: NSPoint(x: b.midX - vsz.width * 0.5, y: 2), withAttributes: vAttr)
    }
    private func defaultFormat(_ v: Float) -> String {
        if abs(maxValue) >= 100 { return String(format: "%.0f", v) }
        return String(format: "%.2f", v)
    }
    private func normalized() -> Float {
        let span = max(0.0001, maxValue - minValue)
        if isLogarithmic && minValue > 0 {
            let lmin = log(minValue), lmax = log(maxValue), lv = log(max(minValue, value))
            return Float((lv - lmin) / (lmax - lmin))
        }
        return (value - minValue) / span
    }
    private func setNorm(_ n: Float) {
        let cl = max(0, min(1, n)); var nv: Float
        if isLogarithmic && minValue > 0 {
            let lmin = log(minValue), lmax = log(maxValue)
            nv = Float(exp(Double(lmin) + Double(cl) * (Double(lmax) - Double(lmin))))
        } else { nv = minValue + cl * (maxValue - minValue) }
        value = nv; parameter?.setValue(AUValue(nv), originator: nil)
    }
    private var dY: CGFloat = 0, dV: Float = 0, fine = false
    override func mouseDown(with e: NSEvent) {
        dY = e.locationInWindow.y; dV = value; fine = e.modifierFlags.contains(.option)
        if e.clickCount == 2 { value = defaultValue; parameter?.setValue(AUValue(defaultValue), originator: nil) }
    }
    override func mouseDragged(with e: NSEvent) {
        let dy = e.locationInWindow.y - dY; let ppf: CGFloat = fine ? 1200 : 200
        let dn = Float(dy / ppf); let on: Float
        if isLogarithmic && minValue > 0 {
            on = Float((log(max(minValue, dV)) - log(minValue)) / (log(maxValue) - log(minValue)))
        } else { on = (dV - minValue) / (maxValue - minValue) }
        setNorm(on + dn)
    }
    override func scrollWheel(with e: NSEvent) {
        let st: Float = e.modifierFlags.contains(.option) ? 0.002 : 0.02
        let dir: Float = e.deltaY > 0 ? 1 : -1
        let n: Float
        if isLogarithmic && minValue > 0 { n = Float((log(max(minValue, value)) - log(minValue)) / (log(maxValue) - log(minValue))) }
        else { n = (value - minValue) / (maxValue - minValue) }
        setNorm(n + st * dir)
    }
}
