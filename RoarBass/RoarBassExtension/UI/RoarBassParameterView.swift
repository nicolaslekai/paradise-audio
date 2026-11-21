//
//  RoarBassParameterView.swift
//  RoarBassExtension
//
//  Dark themed panel layout. Sections: OSC | FM GROWL | NOISE | FILTER | ENVELOPES | GLOBAL.
//

import AppKit
import AudioToolbox

final class RoarBassParameterView: NSView {

    private var knobs: [KnobView] = []
    private weak var au: AUAudioUnit?
    private let undoCtl = ParamUndo()
    private let inkDark = Palette.inkLight
    private let inkMid  = Palette.inkMidL

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Palette.faceBg.cgColor
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    override var isFlipped: Bool { true }

    func bind(to audioUnit: AUAudioUnit) {
        self.au = audioUnit
        subviews.forEach { $0.removeFromSuperview() }
        knobs.removeAll()
        guard let tree = audioUnit.parameterTree else { return }
        undoCtl.attach(audioUnit)
        undoCtl.onChange = { [weak self] in self?.needsDisplay = true }
        layoutSections(with: tree)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        FaceTexture.draw(in: bounds, ctx: ctx)
        // Flipped view (y grows downward): place buttons at the visual top-right.
        undoCtl.draw(in: bounds, ctx: ctx, ink: inkDark, mid: inkMid, pad: 16, y: 12)
        drawFooter(ctx, bounds)
    }

    // Standard Paradise footer (flipped coords): hairline, logo, brand, spec tag.
    private func drawFooter(_ ctx: CGContext, _ b: NSRect) {
        let y = b.height - 36
        ctx.setStrokeColor(Palette.inkLight.withAlphaComponent(0.25).cgColor)
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: 16, y: y)); ctx.addLine(to: CGPoint(x: b.width - 16, y: y)); ctx.strokePath()
        let logoR = NSRect(x: 14, y: y + 3, width: 30, height: 30)
        BrandLogo.draw(in: logoR, ctx: ctx)   // vector mark is flip-safe: no manual mirror
        let aBrand: [NSAttributedString.Key: Any] = [.font: Palette.printFontCondensed(11), .foregroundColor: Palette.inkLight, .kern: 1.2]
        NSString(string: "PARADISE AUDIO").draw(at: NSPoint(x: 50, y: y + 5), withAttributes: aBrand)
        let aSub: [NSAttributedString.Key: Any] = [.font: Palette.printFont(7.5), .foregroundColor: Palette.inkMidL, .kern: 0.6]
        NSString(string: "ROAR BASS — RBS-1").draw(at: NSPoint(x: 50, y: y + 19), withAttributes: aSub)
        let aSpec: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .regular), .foregroundColor: Palette.inkMidL, .kern: 0.5]
        let spec = NSString(string: "AU v3 · INSTRUMENT · BASS")
        let sz = spec.size(withAttributes: aSpec)
        spec.draw(at: NSPoint(x: b.width - 16 - sz.width, y: y + 13), withAttributes: aSpec)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if undoCtl.handleClick(p) { needsDisplay = true; return }
        super.mouseDown(with: event)
    }

    private func layoutSections(with tree: AUParameterTree) {
        // Build a flat dictionary keyed by group identifier so we can lay out predictably.
        var groups: [String: AUParameterGroup] = [:]
        for child in tree.children {
            if let g = child as? AUParameterGroup { groups[g.identifier] = g }
        }

        // Header: plugin name in suite style (brand block lives in the footer).
        let title = NSTextField(labelWithString: "ROAR BASS")
        title.font = NSFont.systemFont(ofSize: 13, weight: .heavy)
        title.textColor = Palette.inkLight
        title.frame = NSRect(x: 16, y: 8, width: 280, height: 18)
        addSubview(title)

        let sub = NSTextField(labelWithString: "DEEP · FM GROWL · LADDER FILTER")
        sub.font = NSFont.monospacedSystemFont(ofSize: 7, weight: .regular)
        sub.textColor = Palette.inkMidL
        sub.frame = NSRect(x: 16, y: 28, width: 320, height: 12)
        addSubview(sub)

        // Section layout: 6 columns
        struct Section {
            let title: String
            let groupId: String
            let paramIds: [String]
        }
        let sections: [Section] = [
            Section(title: "OSCILLATORS",   groupId: "osc",  paramIds: ["osc1Oct","osc2Oct","osc2Det","oscMix","sub"]),
            Section(title: "FM GROWL",      groupId: "fm",   paramIds: ["fmAmt","fmRatio","fmFb"]),
            Section(title: "NOISE",         groupId: "noise",paramIds: ["nz","nzColor"]),
            Section(title: "FILTER",        groupId: "flt",  paramIds: ["cut","res","drv","fEnv"]),
            Section(title: "AMP ENV",       groupId: "ampe", paramIds: ["aA","aD","aS","aR"]),
            Section(title: "FILTER ENV",    groupId: "flte", paramIds: ["fA","fD","fS","fR"]),
            Section(title: "GLOBAL",        groupId: "glob", paramIds: ["glide","vmode","mg","dOut"])
        ]

        // Flow layout: every section is one row of knobs; sections wrap onto a
        // second line when they would run past the right edge (they used to
        // overflow off-screen in a single row).
        var topY: CGFloat = 56
        var x: CGFloat = 18
        var rowH: CGFloat = 0
        let colSpacing: CGFloat = 4
        let sectionPad: CGFloat = 8
        let knobW: CGFloat = 60
        let knobH: CGFloat = 86
        let perRow: Int = 8

        for sec in sections {
            guard let g = groups[sec.groupId] else { continue }
            let paramMap = Dictionary(uniqueKeysWithValues: g.allParameters.map { ($0.identifier, $0) })

            let count = sec.paramIds.count
            let cols = min(perRow, count)
            let rows = (count + cols - 1) / cols
            let sectionW = CGFloat(cols) * knobW + CGFloat(cols - 1) * colSpacing + sectionPad * 2
            let sectionH = CGFloat(rows) * knobH + 24 + sectionPad
            if x > 18 && x + sectionW > bounds.width - 18 {
                x = 18; topY += rowH + 8; rowH = 0
            }
            rowH = max(rowH, sectionH)

            // section frame (panel)
            let panel = NSBox(frame: NSRect(x: x, y: topY, width: sectionW, height: sectionH))
            panel.boxType = .custom
            panel.borderType = .lineBorder
            panel.borderColor = Palette.inkLight.withAlphaComponent(0.25)
            panel.cornerRadius = 4
            panel.fillColor = Palette.panelDark
            panel.titlePosition = .noTitle
            panel.contentViewMargins = NSSize(width: 0, height: 0)
            addSubview(panel)

            let titleLbl = NSTextField(labelWithString: sec.title)
            titleLbl.font = Palette.printFontCondensed(12)
            titleLbl.textColor = Palette.inkMidL
            titleLbl.frame = NSRect(x: x + sectionPad, y: topY + 4, width: sectionW - 12, height: 15)
            addSubview(titleLbl)

            for (i, pid) in sec.paramIds.enumerated() {
                guard let param = paramMap[pid] else { continue }
                let r = i / cols
                let c = i % cols
                let kx = x + sectionPad + CGFloat(c) * (knobW + colSpacing)
                let ky = topY + 20 + CGFloat(r) * knobH
                let knob = KnobView(frame: NSRect(x: kx, y: ky, width: knobW, height: knobH))
                knob.bind(parameter: param)
                // Short labels: the section heading already gives the context.
                if let short = Self.shortLabels[pid] { knob.title = short }
                attachFormatter(knob: knob, parameter: param)
                addSubview(knob)
                knobs.append(knob)
            }

            x += sectionW + 6
        }
    }

    private static let shortLabels: [String: String] = [
        "osc1Oct": "OSC1 OCT", "osc2Oct": "OSC2 OCT", "osc2Det": "DETUNE", "oscMix": "MIX", "sub": "SUB",
        "fmAmt": "GROWL", "fmRatio": "RATIO", "fmFb": "FEEDBACK",
        "nz": "LEVEL", "nzColor": "COLOUR",
        "cut": "CUTOFF", "res": "RESO", "drv": "DRIVE", "fEnv": "ENV AMT",
        "aA": "A", "aD": "D", "aS": "S", "aR": "R",
        "fA": "A", "fD": "D", "fS": "S", "fR": "R",
        "glide": "GLIDE", "vmode": "VOICE", "mg": "MASTER", "dOut": "DRIVE",
    ]

    private func attachFormatter(knob: KnobView, parameter: AUParameter) {
        switch parameter.address {
        case 6: // FM Ratio
            knob.displayFormatter = { String(format: "%.2fx", $0) }
        case 10: // Cutoff
            knob.displayFormatter = { v in
                if v >= 1000 { return String(format: "%.1fk", v / 1000.0) }
                return String(format: "%.0f", v)
            }
        case 14, 15, 17, 18, 19, 21, 22: // seconds
            knob.displayFormatter = { v in
                if v < 0.1 { return String(format: "%.0fms", v * 1000) }
                if v < 1.0 { return String(format: "%.0fms", v * 1000) }
                return String(format: "%.2fs", v)
            }
        case 0, 1: // octaves
            knob.displayFormatter = { String(format: "%+d", Int($0.rounded())) }
        case 2: // cents
            knob.displayFormatter = { String(format: "%+dc", Int($0.rounded())) }
        case 23: // voice mode (Indexed)
            knob.displayFormatter = { $0 < 0.5 ? "POLY" : "MONO" }
        default:
            break
        }
    }
}
