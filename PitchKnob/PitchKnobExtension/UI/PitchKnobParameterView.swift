//
//  PitchKnobParameterView.swift
//
//  Single dominant knob filling most of the surface. 12 o'clock = bypass.
//  Counter-clockwise = LOW-PASS sweep down. Clockwise = HIGH-PASS sweep up.
//

import AppKit
import AudioToolbox

final class PitchKnobParameterView: NSView {
    var audioUnit: PitchKnobAudioUnit? { didSet { rebind() } }

    private let cream = Palette.cream
    private let inkDark = Palette.inkLight
    private let inkMid  = Palette.inkMidL
    private let red     = Palette.red
    private let faceBg  = Palette.faceBg

    private let bigKnob = GiantKnob(frame: .zero)
    private var observerToken: AUParameterObserverToken?
    private weak var knobParam: AUParameter?
    private var distToken: AUParameterObserverToken?
    deinit {
        if let t = observerToken { knobParam?.removeParameterObserver(t) }
        if let t = distToken { distParam?.removeParameterObserver(t) }
    }
    private weak var distParam: AUParameter?
    private let undoCtl = ParamUndo()

    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.backgroundColor = faceBg.cgColor
        addSubview(bigKnob)
        bigKnob.onChange = { [weak self] v in
            guard let self else { return }
            self.knobParam?.setValue(AUValue(v), originator: nil)
            self.needsDisplay = true
        }
        bigKnob.onCenterChange = { [weak self] v in
            guard let self else { return }
            self.distParam?.setValue(AUValue(v), originator: nil)
            self.needsDisplay = true
        }
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func layout() {
        super.layout()
        let pad: CGFloat = 30
        let footer: CGFloat = 60
        let header: CGFloat = 50
        let usableH = bounds.height - footer - header
        let usableW = bounds.width - pad * 2
        let dia = min(usableH, usableW)
        let x = (bounds.width - dia) * 0.5
        let y = footer + (usableH - dia) * 0.5
        bigKnob.frame = NSRect(x: x, y: y, width: dia, height: dia)
    }

    override func draw(_ r: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Subtle brushed-aluminium faceplate (keeps panel colour, adds analogue grain).
        FaceTexture.draw(in: bounds, ctx: ctx)
        let b = bounds
        // Paper noise
        // Brand
        // Standard suite footer (DESIGN.md §2) — shared BrandStrip helper.
        BrandStrip.drawFooter(ctx: ctx, bounds: b, plugin: "PITCH KNOB", code: "PTK-1",
                              spec: "AU v3 · STEREO · PITCH", pad: 16, specAtTop: true)

        // PITCH readout (big knob) + a small FILTER readout (centre knob).
        let mode: String
        let modeColor: NSColor
        var filtStr = "FILTER OPEN"
        if let tree = audioUnit?.parameterTree {
            let pv = tree.parameter(withAddress: 0)?.value ?? 0.5
            let semi = (pv - 0.5) * 24.0
            if abs(semi) < 0.05 { mode = "UNISON"; modeColor = inkMid }
            else { mode = String(format: "%+.1f st", semi); modeColor = red }
            let fv = tree.parameter(withAddress: 1)?.value ?? 0.5
            if abs(fv - 0.5) < 0.005 { filtStr = "FILTER OPEN" }
            else if fv < 0.5 { filtStr = String(format: "FILTER · LP %.0f Hz", lpCutoff(fv)) }
            else             { filtStr = String(format: "FILTER · HP %.0f Hz", hpCutoff(fv)) }
        } else { mode = "—"; modeColor = inkMid }
        let mAttr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .heavy), .foregroundColor: modeColor, .kern: 1.6]
        let mStr = NSString(string: mode); let mSz = mStr.size(withAttributes: mAttr)
        mStr.draw(at: NSPoint(x: b.midX - mSz.width * 0.5, y: 54), withAttributes: mAttr)
        let fAttr: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 8, weight: .regular), .foregroundColor: inkMid, .kern: 0.6]
        let fStr = NSString(string: filtStr); let fSz = fStr.size(withAttributes: fAttr)
        fStr.draw(at: NSPoint(x: b.midX - fSz.width * 0.5, y: 42), withAttributes: fAttr)

        // Bottom-of-knob marks: pitch DOWN ◀ · UNISON · ▶ UP
        let leg: [NSAttributedString.Key: Any] = [.font: Palette.printFont(10), .foregroundColor: inkDark, .kern: 0.8]
        // Side marks sit above the footer hairline (y 36) so they never collide with the brand block.
        NSString(string: "◀ DOWN").draw(at: NSPoint(x: 28, y: 44), withAttributes: leg)
        let hpStr = NSString(string: "UP ▶"); let hpsz = hpStr.size(withAttributes: leg)
        hpStr.draw(at: NSPoint(x: b.width - hpsz.width - 28, y: 44), withAttributes: leg)

        // Undo / redo — top-right, just under the spec tag.
        undoCtl.draw(in: b, ctx: ctx, ink: inkDark, mid: inkMid, pad: 16, y: b.height - 30)
        // SAVE / LOAD named presets — top-LEFT corner, clear of the centered giant knob.
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if undoCtl.handleClick(p) { needsDisplay = true; return }
        super.mouseDown(with: event)
    }

    private func lpCutoff(_ v: Float) -> Float {
        let t = (0.5 - v) * 2.0
        return 18000.0 * pow(80.0 / 18000.0, t)
    }
    private func hpCutoff(_ v: Float) -> Float {
        let t = (v - 0.5) * 2.0
        return 20.0 * pow(8000.0 / 20.0, t)
    }

    private func rebind() {
        if let t = observerToken { knobParam?.removeParameterObserver(t) }
        guard let au = audioUnit, let tree = au.parameterTree,
              let p = tree.children.compactMap({ $0 as? AUParameter }).first else { return }
        knobParam = p
        undoCtl.attach(au)
        undoCtl.onChange = { [weak self] in self?.needsDisplay = true }
        bigKnob.value = Float(p.value)
        observerToken = p.token(byAddingParameterObserver: { [weak self] _, v in
            DispatchQueue.main.async {
                self?.bigKnob.value = Float(v)
                self?.needsDisplay = true
            }
        })
        // Centre distortion param (address 1).
        if let t = distToken { distParam?.removeParameterObserver(t) }
        if let dp = tree.parameter(withAddress: 1) {
            distParam = dp
            bigKnob.centerValue = Float(dp.value)
            distToken = dp.token(byAddingParameterObserver: { [weak self] _, v in
                DispatchQueue.main.async {
                    self?.bigKnob.centerValue = Float(v)
                    self?.needsDisplay = true
                }
            })
        }
        needsLayout = true; needsDisplay = true
    }
}

// MARK: - GiantKnob — the dominant red filter knob, sized as a steering wheel.

final class GiantKnob: NSView {
    var value: Float = 0.5 { didSet { needsDisplay = true } }
    var onChange: ((Float) -> Void)?
    // Secondary knob in the centre cap — DISTORTION (0..1).
    var centerValue: Float = 0 { didSet { needsDisplay = true } }
    var onCenterChange: ((Float) -> Void)?
    private var draggingCenter = false
    private let red = Palette.red
    private let inkDark = Palette.inkLight
    private let inkMid  = Palette.inkMidL
    private let panel   = Palette.cream

    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func draw(_ r: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds.insetBy(dx: 4, dy: 4)
        let cx = b.midX, cy = b.midY
        let rad = min(b.width, b.height) * 0.5
        // Outer ring track (segmented hash marks)
        let hashCount = 60
        for i in 0..<hashCount {
            let frac = CGFloat(i) / CGFloat(hashCount - 1)
            let ang = (.pi * 1.25) - frac * (.pi * 1.5)
            let r1 = rad - 2, r2 = rad - 10
            let inner = (frac > 0.495 && frac < 0.505) ? r2 - 6 : r2
            let p1 = NSPoint(x: cx + cos(ang) * r1, y: cy + sin(ang) * r1)
            let p2 = NSPoint(x: cx + cos(ang) * inner, y: cy + sin(ang) * inner)
            ctx.setStrokeColor((frac > 0.495 && frac < 0.505 ? red : inkDark.withAlphaComponent(0.6)).cgColor)
            ctx.setLineWidth(frac > 0.495 && frac < 0.505 ? 1.4 : 0.6)
            ctx.move(to: p1); ctx.addLine(to: p2); ctx.strokePath()
        }
        // Main knob body — glowing red LED dome (distinct from BigKnob's silver).
        // The dome itself ROTATES with the value so the knob visibly turns.
        let bodyR = rad - 18
        let knobRot = (CGFloat(value) - 0.5) * (1.5 * .pi)   // ±135°
        ctx.saveGState()
        ctx.translateBy(x: cx, y: cy); ctx.rotate(by: -knobRot); ctx.translateBy(x: -cx, y: -cy)
        if !KnobTex.draw(ctx, center: NSPoint(x: cx, y: cy), radius: bodyR, image: KnobTex.pitch) {   // machined red twin of BigKnob, drawn in code
            ctx.setFillColor(red.cgColor)
            ctx.fillEllipse(in: NSRect(x: cx - bodyR, y: cy - bodyR, width: bodyR * 2, height: bodyR * 2))
        }
        ctx.restoreGState()
        // Subtle inner shadow ring
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.35).cgColor); ctx.setLineWidth(2)
        ctx.strokeEllipse(in: NSRect(x: cx - bodyR + 1, y: cy - bodyR + 1, width: bodyR * 2 - 2, height: bodyR * 2 - 2))
        // Centre sub-knob (2026-11-21, Nicky: "come up with something else for the knob in the
        // middle … reuse a blender one"): the suite's Blender-rendered fluted knob sits in the dish,
        // with a cream screen-printed tick ring and the same painted pointer as every other knob.
        let capR = bodyR * 0.30
        let s0: CGFloat = .pi * 1.25, e0: CGFloat = -.pi * 0.25
        ctx.setStrokeColor(Palette.inkLight.withAlphaComponent(0.75).cgColor); ctx.setLineWidth(1.0)
        for i in 0..<11 {
            let a = s0 - CGFloat(i) / 10 * (s0 - e0)
            let r0 = capR + 4, r1 = capR + (i == 0 || i == 5 || i == 10 ? 10 : 7)
            ctx.move(to: NSPoint(x: cx + cos(a) * r0, y: cy + sin(a) * r0)); ctx.addLine(to: NSPoint(x: cx + cos(a) * r1, y: cy + sin(a) * r1))
        }
        ctx.strokePath()
        let subStyle: KnobStyle = .anodizedRed
        if !KnobTex.draw(ctx, center: NSPoint(x: cx, y: cy), radius: capR, image: subStyle) {
            ctx.setFillColor(NSColor(calibratedWhite: 0.16, alpha: 1).cgColor)
            ctx.fillEllipse(in: NSRect(x: cx - capR, y: cy - capR, width: capR * 2, height: capR * 2))
        }
        let cAng = s0 - CGFloat(centerValue) * (s0 - e0)
        ctx.setStrokeColor(KnobSkin.pointerColor(for: subStyle).cgColor)
        ctx.setLineWidth(max(2.5, capR * 0.11)); ctx.setLineCap(.round)
        ctx.move(to: NSPoint(x: cx + cos(cAng) * (capR * 0.30), y: cy + sin(cAng) * (capR * 0.30)))
        ctx.addLine(to: NSPoint(x: cx + cos(cAng) * (capR * 0.80), y: cy + sin(cAng) * (capR * 0.80))); ctx.strokePath()
        // Indicator DIVOT on the dome (no more pointer line). A small bright
        // notch near the rim that orbits with the value, reading as the dome
        // physically turning.
        let ang = (.pi * 1.25) - CGFloat(value) * (.pi * 1.5)
        let dotC = NSPoint(x: cx + cos(ang) * (bodyR - 12), y: cy + sin(ang) * (bodyR - 12))
        let dotR: CGFloat = 5
        ctx.setFillColor(NSColor(calibratedWhite: 1.0, alpha: 0.9).cgColor)
        ctx.fillEllipse(in: NSRect(x: dotC.x - dotR, y: dotC.y - dotR, width: dotR * 2, height: dotR * 2))
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.4).cgColor); ctx.setLineWidth(1)
        ctx.strokeEllipse(in: NSRect(x: dotC.x - dotR, y: dotC.y - dotR, width: dotR * 2, height: dotR * 2))
    }

    // MARK: Mouse — drag vertically, double-click to recenter to bypass

    private var dragStartY: CGFloat = 0
    private var dragStartV: Float = 0
    private var fine = false

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let b = bounds.insetBy(dx: 4, dy: 4)
        let rad = min(b.width, b.height) * 0.5
        let capR = (rad - 18) * 0.30          // same radius the sub-knob is DRAWN with
        let dx = p.x - b.midX, dy = p.y - b.midY
        draggingCenter = (dx * dx + dy * dy) <= (capR * 1.3) * (capR * 1.3)
        dragStartY = e.locationInWindow.y
        fine = e.modifierFlags.contains(.option)
        if draggingCenter {
            dragStartV = centerValue
            if e.clickCount == 2 { centerValue = 0.5; onCenterChange?(0.5) }   // FILTER default = OPEN
        } else {
            dragStartV = value
            if e.clickCount == 2 { value = 0.5; onChange?(0.5) }
        }
    }
    override func mouseDragged(with e: NSEvent) {
        let dy = e.locationInWindow.y - dragStartY
        let ppf: CGFloat = fine ? 600 : 220
        var nv = dragStartV + Float(dy / ppf)
        if nv < 0 { nv = 0 } else if nv > 1 { nv = 1 }
        if draggingCenter {
            centerValue = nv
            onCenterChange?(nv)
        } else {
            if abs(nv - 0.5) < 0.012 { nv = 0.5 }   // detent at bypass
            value = nv
            onChange?(nv)
        }
    }
    override func scrollWheel(with e: NSEvent) {
        let step: Float = e.modifierFlags.contains(.option) ? 0.002 : 0.01
        var nv = value + step * (e.deltaY > 0 ? 1 : -1)
        if nv < 0 { nv = 0 } else if nv > 1 { nv = 1 }
        if abs(nv - 0.5) < 0.012 { nv = 0.5 }
        value = nv
        onChange?(nv)
    }
}
