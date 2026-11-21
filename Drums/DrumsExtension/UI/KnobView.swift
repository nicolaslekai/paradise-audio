// Compact Paradise OP-1 knob (smaller variant for drums per-voice strips).
import AppKit
import AudioToolbox

final class KnobView: NSControl {
    private weak var parameter: AUParameter?
    private var observerToken: AUParameterObserverToken?
    var title: String = "" { didSet { needsDisplay = true } }
    var displayFormatter: ((Float) -> String)? = nil
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
        observerToken = p.token(byAddingParameterObserver: { [weak self] _, v in DispatchQueue.main.async { self?.value = Float(v) } })
        needsDisplay = true
    }
    override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 28) }

    override func draw(_ r: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds.insetBy(dx: 2, dy: 2)
        let c = NSPoint(x: b.midX, y: b.midY); let rad = min(b.width, b.height) * 0.5
        let s: CGFloat = .pi * 1.25, e: CGFloat = -.pi * 0.25
        ctx.setStrokeColor(NSColor(calibratedWhite: 0.45, alpha: 0.3).cgColor); ctx.setLineWidth(0.5)
        ctx.addArc(center: c, radius: rad + 1, startAngle: s, endAngle: e, clockwise: true); ctx.strokePath()
        let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [NSColor(calibratedWhite: 0.18, alpha: 1).cgColor, NSColor(calibratedWhite: 0.08, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
        ctx.saveGState(); ctx.addEllipse(in: b); ctx.clip()
        ctx.drawLinearGradient(grad, start: CGPoint(x: b.minX, y: b.maxY), end: CGPoint(x: b.maxX, y: b.minY), options: []); ctx.restoreGState()
        ctx.setStrokeColor(NSColor(calibratedWhite: 0, alpha: 0.85).cgColor); ctx.setLineWidth(0.5); ctx.strokeEllipse(in: b)
        let frac = CGFloat((value - minValue) / max(0.0001, maxValue - minValue))
        let ang = s - (s - e) * frac
        let p1 = NSPoint(x: c.x + cos(ang) * rad * 0.3, y: c.y + sin(ang) * rad * 0.3)
        let p2 = NSPoint(x: c.x + cos(ang) * rad * 0.85, y: c.y + sin(ang) * rad * 0.85)
        ctx.setStrokeColor(Palette.accent.cgColor); ctx.setLineWidth(1.25); ctx.setLineCap(.round)
        ctx.move(to: p1); ctx.addLine(to: p2); ctx.strokePath()
    }
    private var dY: CGFloat = 0, dV: Float = 0
    override func mouseDown(with e: NSEvent) {
        dY = e.locationInWindow.y; dV = value
        if e.clickCount == 2 { value = defaultValue; parameter?.setValue(AUValue(defaultValue), originator: nil) }
    }
    override func mouseDragged(with e: NSEvent) {
        let dy = e.locationInWindow.y - dY
        let cl = max(0, min(1, (dV - minValue) / (maxValue - minValue) + Float(dy / 150)))
        let nv = minValue + cl * (maxValue - minValue)
        value = nv; parameter?.setValue(AUValue(nv), originator: nil)
    }
}
