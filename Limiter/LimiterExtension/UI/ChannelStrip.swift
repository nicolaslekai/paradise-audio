//
//  ChannelStrip.swift — mixer-style fader + level meter for the Limiter (2026-11-21).
//
//  Both share one ruler: the parent hands every column the same dB → y mapping
//  (0 dB at the top), so the THRESHOLD cap lines up with the input meter and
//  the CEILING cap with the output meter.
//
//  FaderView: long recessed slot, screen-printed ticks, a silicone-key cap
//  (ButtonTex.drawRubber, no gradients) with a painted line across it.
//  Drag (⌥ = fine), click on the slot = jump, double-click = default, scroll.
//  Sends touch / release gestures so host automation latches cleanly.
//
//  MeterView: narrow well, flat segmented bar (input/output from the bottom,
//  gain reduction from the top), peak-hold line, optional marker line.
//

import AppKit
import AudioToolbox

/// Shared vertical dB ruler (flipped coordinates, 0 dB at `y0`).
struct DBRuler {
    var y0: CGFloat, y1: CGFloat, range: Float = 30
    var pxPerDB: CGFloat { (y1 - y0) / CGFloat(range) }
    func y(_ db: Float) -> CGFloat { y0 + CGFloat(-max(-range, min(0, db))) * pxPerDB }
}

final class FaderView: NSView {
    private weak var parameter: AUParameter?
    private var token: AUParameterObserverToken?
    var value: Float = 0 { didSet { if oldValue != value { needsDisplay = true; onChange?(value) } } }
    var minValue: Float = -30, maxValue: Float = 0, defaultValue: Float = 0
    /// 1 = red cap, 2 = ivory cap, 0 = dark cap.
    var capKind = 1
    /// Cap overhang above/below the travel.
    static let capH: CGFloat = 22, capW: CGFloat = 40, overhang: CGFloat = 13
    var onChange: ((Float) -> Void)?

    override var isFlipped: Bool { true }
    deinit { if let t = token { parameter?.removeParameterObserver(t) } }

    func bind(_ p: AUParameter, default d: Float) {
        if let t = token { parameter?.removeParameterObserver(t) }
        parameter = p
        minValue = p.minValue; maxValue = p.maxValue; defaultValue = d
        value = p.value
        token = p.token(byAddingParameterObserver: { [weak self] _, v in
            DispatchQueue.main.async { self?.value = v }
        })
    }

    private var travelTop: CGFloat { Self.overhang }
    private var travelBottom: CGFloat { bounds.height - Self.overhang }
    private func yFor(_ v: Float) -> CGFloat {
        let n = CGFloat((maxValue - max(minValue, min(maxValue, v))) / max(0.001, maxValue - minValue))
        return travelTop + n * (travelBottom - travelTop)
    }
    private func valueFor(_ y: CGFloat) -> Float {
        let n = Float((y - travelTop) / max(1, travelBottom - travelTop))
        return maxValue - max(0, min(1, n)) * (maxValue - minValue)
    }
    private var capRect: NSRect {
        let y = yFor(value)
        return NSRect(x: (bounds.midX - Self.capW * 0.5).rounded(), y: (y - Self.capH * 0.5).rounded(),
                      width: Self.capW, height: Self.capH)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let ink = Palette.inkLight
        let cx = bounds.midX

        // Ticks every 1 dB (long every 3 dB) on both sides of the slot.
        ctx.setStrokeColor(ink.withAlphaComponent(0.55).cgColor); ctx.setLineWidth(0.7)
        var db = maxValue.rounded(.down)
        while db >= minValue - 0.001 {
            let y = yFor(db).rounded() + 0.5
            let long = Int(db.rounded()) % 3 == 0
            let len: CGFloat = long ? 7 : 4
            ctx.move(to: NSPoint(x: cx - 6 - len, y: y)); ctx.addLine(to: NSPoint(x: cx - 6, y: y))
            ctx.move(to: NSPoint(x: cx + 6, y: y)); ctx.addLine(to: NSPoint(x: cx + 6 + len, y: y))
            db -= 1
        }
        ctx.strokePath()

        // Slot: a long dark recess with a hairline lip.
        let slot = NSRect(x: cx - 3, y: travelTop - 4, width: 6, height: travelBottom - travelTop + 8)
        let sp = CGPath(roundedRect: slot, cornerWidth: 3, cornerHeight: 3, transform: nil)
        ctx.setFillColor(NSColor(calibratedRed: 0.02, green: 0.035, blue: 0.035, alpha: 1).cgColor)
        ctx.addPath(sp); ctx.fillPath()
        ctx.setStrokeColor(ink.withAlphaComponent(0.18).cgColor); ctx.setLineWidth(0.5); ctx.addPath(sp); ctx.strokePath()

        // Cap: contact shadow, silicone key, painted line.
        let r = capRect
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 4, color: NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 2, dy: 2), cornerWidth: 3, cornerHeight: 3, transform: nil)); ctx.fillPath()
        ctx.restoreGState()
        if !ButtonTex.drawRubber(ctx, rect: r, kind: capKind) {
            let fill: NSColor = capKind == 1 ? Palette.red : (capKind == 2 ? Palette.cream : Palette.knobBody)
            ctx.setFillColor(fill.cgColor)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 3, cornerHeight: 3, transform: nil)); ctx.fillPath()
        }
        let lineCol: NSColor = capKind == 2 ? NSColor(calibratedRed: 0.17, green: 0.16, blue: 0.15, alpha: 1)
                                            : NSColor(calibratedRed: 0.97, green: 0.94, blue: 0.88, alpha: 1)
        ctx.setStrokeColor(lineCol.cgColor); ctx.setLineWidth(2); ctx.setLineCap(.butt)
        let ly = yFor(value).rounded()
        ctx.move(to: NSPoint(x: r.minX + 5, y: ly)); ctx.addLine(to: NSPoint(x: r.maxX - 5, y: ly)); ctx.strokePath()
    }

    // MARK: Interaction

    private var dragStartY: CGFloat = 0, dragStartV: Float = 0

    private func send(_ v: Float, _ type: AUParameterAutomationEventType) {
        let nv = max(minValue, min(maxValue, v))
        value = nv
        parameter?.setValue(nv, originator: token, atHostTime: 0, eventType: type)
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if e.clickCount == 2 { send(defaultValue, .touch); send(defaultValue, .release); return }
        send(value, .touch)
        if !capRect.insetBy(dx: -4, dy: -3).contains(p) {
            send(valueFor(p.y), .value)          // click on the slot: jump there
        }
        dragStartY = p.y; dragStartV = value
    }
    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let pxPerUnit = (travelBottom - travelTop) / CGFloat(max(0.001, maxValue - minValue))
        let fine: CGFloat = e.modifierFlags.contains(.option) ? 0.2 : 1
        let dv = Float(-(p.y - dragStartY) / pxPerUnit * fine)
        send(((dragStartV + dv) * 10).rounded() / 10, .value)
    }
    override func mouseUp(with e: NSEvent) { send(value, .release) }
    override func scrollWheel(with e: NSEvent) {
        guard e.scrollingDeltaY != 0 else { return }
        let step: Float = e.modifierFlags.contains(.option) ? 0.1 : 0.5
        send(((value + (e.scrollingDeltaY > 0 ? step : -step)) * 10).rounded() / 10, .value)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class MeterView: NSView {
    enum Kind { case level, reduction }
    var kind: Kind = .level
    var ruler = DBRuler(y0: 0, y1: 100)          // in this view's coordinates
    /// Displayed level in dBFS (level) or dB of reduction (reduction).
    var db: Float = -120 { didSet { if oldValue != db { needsDisplay = true } } }
    var holdDB: Float = -120 { didSet { if oldValue != holdDB { needsDisplay = true } } }
    /// Optional marker (threshold on IN, ceiling on OUT) in dBFS.
    var markerDB: Float? { didSet { if oldValue != markerDB { needsDisplay = true } } }
    /// Portion of a level bar above this dB is drawn red (IN: above the threshold).
    var hotAboveDB: Float? { didSet { if oldValue != hotAboveDB { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let ink = Palette.inkLight, red = Palette.red
        let well = NSRect(x: 0, y: ruler.y0 - 3, width: bounds.width, height: ruler.y1 - ruler.y0 + 6)
        ctx.setFillColor(Palette.wellBg.cgColor); ctx.fill(well)
        ctx.setStrokeColor(ink.withAlphaComponent(0.28).cgColor); ctx.setLineWidth(0.5); ctx.stroke(well.insetBy(dx: 0.25, dy: 0.25))

        let inner = well.insetBy(dx: 2.5, dy: 3)
        // Flat segmented bar: 3 px segments, 1 px gaps.
        func segments(from yA: CGFloat, to yB: CGFloat, color: NSColor) {
            guard yB > yA else { return }
            ctx.setFillColor(color.cgColor)
            var y = ruler.y0
            while y < ruler.y1 {
                let s0 = max(y, yA), s1 = min(y + 3, yB)
                if s1 > s0 { ctx.fill(NSRect(x: inner.minX, y: s0, width: inner.width, height: s1 - s0)) }
                y += 4
            }
        }
        // Unlit segments, faint.
        segments(from: ruler.y0, to: ruler.y1, color: ink.withAlphaComponent(0.05))
        switch kind {
        case .level:
            if db > -ruler.range {
                let top = ruler.y(db)
                if let hot = hotAboveDB, db > hot {
                    let hy = ruler.y(hot)
                    segments(from: hy, to: ruler.y1, color: ink.withAlphaComponent(0.85))
                    segments(from: top, to: hy, color: red)
                } else {
                    segments(from: top, to: ruler.y1, color: ink.withAlphaComponent(0.85))
                }
            }
            if holdDB > -ruler.range {
                let y = ruler.y(holdDB)
                ctx.setFillColor((hotAboveDB.map { holdDB > $0 } ?? false ? red : ink).cgColor)
                ctx.fill(NSRect(x: inner.minX, y: y - 1, width: inner.width, height: 2))
            }
        case .reduction:
            if db > 0.05 { segments(from: ruler.y0, to: ruler.y(-db), color: red) }
            if holdDB > 0.05 {
                ctx.setFillColor(red.cgColor)
                ctx.fill(NSRect(x: inner.minX, y: ruler.y(-holdDB) - 1, width: inner.width, height: 2))
            }
        }
        if let m = markerDB {
            let y = ruler.y(m).rounded() + 0.5
            ctx.setStrokeColor(ink.cgColor); ctx.setLineWidth(1)
            ctx.move(to: NSPoint(x: 0, y: y)); ctx.addLine(to: NSPoint(x: bounds.width, y: y)); ctx.strokePath()
        }
    }
}
