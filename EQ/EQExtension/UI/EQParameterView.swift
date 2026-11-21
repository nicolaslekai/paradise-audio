//
//  EQParameterView.swift
//  Cream Paradise OP-1 faceplate: response curve in the upper portion,
//  6 big knobs in the lower portion, brand mark in the footer.
//

import AppKit
import AudioToolbox

final class EQParameterView: NSView {

    var audioUnit: EQAudioUnit? { didSet { rebind() } }

    private let cream     = Palette.cream
    private let inkDark   = Palette.inkLight
    private let inkMid    = Palette.inkMidL
    private let accentRed = Palette.accentRed
    private let faceBg    = Palette.faceBg
    private let undoCtl   = ParamUndo()

    private var knobs: [KnobView] = []
    // Q (bell-width) knobs — a smaller second row above each band's F/G pair.
    private var qKnobs: [KnobView] = []
    // Indices into `knobs` for the F/G pair each Q knob centers over:
    // loQ→(loFreq,loGain), lmQ→(lmFreq,lmGain), hmQ→(hmFreq,hmGain), hiQ→(hiFreq,hiGain)
    private let qPairs: [(Int, Int)] = [(1, 2), (3, 4), (5, 6), (7, 8)]
    private let response = FrequencyResponseView(frame: .zero)
    // The bell/shelf SHAPE pills now live inside the response view itself
    // (FrequencyResponseView) at top-left and top-right, with bell-curve /
    // shelf-step glyphs. See FrequencyResponseView.drawShapePill.

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = faceBg.cgColor
        addSubview(response)
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func layout() {
        super.layout()
        let pad: CGFloat = 18
        let footerH: CGFloat = 44

        // Tightened from 78px → 60px because we now have 10 knobs in this
        // row (was 6 before LM/HM were added); 10×78 overflows the panel.
        let knobH: CGFloat = 128, knobW: CGFloat = 72, sp: CGFloat = 8
        let count = max(1, knobs.count)
        let total = CGFloat(count) * knobW + CGFloat(count - 1) * sp
        let knobY: CGFloat = footerH + 8
        var x = (bounds.width - total) * 0.5
        for k in knobs { k.frame = NSRect(x: x, y: knobY, width: knobW, height: knobH); x += knobW + sp }

        // Q knobs — a smaller row sitting ABOVE each band's F/G pair, centered
        // between the two knobs of that band.
        let qW: CGFloat = 54, qH: CGFloat = 80
        let qY = knobY + knobH + 8
        for (i, k) in qKnobs.enumerated() where i < qPairs.count {
            let (a, bIdx) = qPairs[i]
            guard a < knobs.count, bIdx < knobs.count else { continue }
            let cx = (knobs[a].frame.midX + knobs[bIdx].frame.midX) * 0.5
            k.frame = NSRect(x: cx - qW * 0.5, y: qY, width: qW, height: qH)
        }

        // Curve fills everything above the (Q) knob row
        let qTop = qKnobs.isEmpty ? (knobY + knobH) : (qY + qH)
        let curveBottom = qTop + 16
        let curveTop = bounds.height - 30
        response.frame = NSRect(x: pad, y: curveBottom, width: bounds.width - pad * 2, height: max(140, curveTop - curveBottom))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Subtle brushed-aluminium faceplate (keeps panel colour, adds analogue grain).
        FaceTexture.draw(in: bounds, ctx: ctx)
        let b = bounds
        ctx.setFillColor(accentRed.cgColor); BrandLogo.draw(in: NSRect(x: 12, y: 2, width: 30, height: 30), ctx: ctx)
        let brand: [NSAttributedString.Key: Any] = [.font: Palette.printFontCondensed(11), .foregroundColor: inkDark, .kern: 1.2]
        NSString(string: "PARADISE AUDIO").draw(at: NSPoint(x: 46, y: 15), withAttributes: brand)
        let sub: [NSAttributedString.Key: Any] = [.font: Palette.printFont(7.5), .foregroundColor: inkMid, .kern: 0.6]
        NSString(string: "EQ — EQ-1").draw(at: NSPoint(x: 46, y: 4), withAttributes: sub)
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.25).cgColor); ctx.setLineWidth(0.5)
        ctx.move(to: NSPoint(x: 16, y: 36)); ctx.addLine(to: NSPoint(x: b.width - 16, y: 36)); ctx.strokePath()
        let tag: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .regular), .foregroundColor: inkMid, .kern: 0.5]
        let tagStr = NSString(string: "AU v3 · STEREO"); let tw = tagStr.size(withAttributes: tag)
        tagStr.draw(at: NSPoint(x: b.width - tw.width - 16, y: b.height - 14), withAttributes: tag)

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
        response.audioUnit = au
        undoCtl.attach(au)
        undoCtl.onChange = { [weak self] in self?.needsDisplay = true }
        // Visual order across the bottom: HP | LO F/G | LM F/G | HM F/G | HI F/G | LP
        // HP on the left edge, LP on the right edge — both rendered as
        // RED accent knobs so the boundary filters stand out from the
        // shelves and mid bells.
        let orderedIds = ["hp", "loFreq", "loGain", "lmFreq", "lmGain",
                          "hmFreq", "hmGain", "hiFreq", "hiGain", "lp"]
        let byId: [String: AUParameter] = Dictionary(uniqueKeysWithValues:
            tree.children.compactMap { ($0 as? AUParameter).map { ($0.identifier, $0) } })
        for id in orderedIds {
            guard let p = byId[id] else { continue }
            let k = KnobView(frame: .zero); k.bind(parameter: p)
            switch id {
            case "hp", "loFreq", "hiFreq", "lp", "lmFreq", "hmFreq":
                k.displayFormatter = { v in v >= 1000 ? String(format: "%.1fk", v / 1000) : String(format: "%.0fHz", v) }
            case "loGain", "hiGain", "lmGain", "hmGain":
                k.displayFormatter = { v in String(format: "%+.1fdB", v) }
            default: break
            }
            if id == "hp" || id == "lp" { k.isAccent = true }
            addSubview(k); knobs.append(k)
        }
        // Second row: bell-width (Q) knobs for the four tone bands.
        qKnobs.forEach { $0.removeFromSuperview() }; qKnobs.removeAll()
        for id in ["loQ", "lmQ", "hmQ", "hiQ"] {
            guard let p = byId[id] else { continue }
            let k = KnobView(frame: .zero); k.bind(parameter: p)
            k.displayFormatter = { v in String(format: "Q %.2f", v) }
            addSubview(k); qKnobs.append(k)
        }
        needsLayout = true; needsDisplay = true
    }
}
