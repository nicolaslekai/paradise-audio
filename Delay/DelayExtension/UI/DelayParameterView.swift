//
//  DelayParameterView.swift — Paradise Audio DUB DELAY (DLY-1)
//
//  2026-09 redesign (DESIGN.md §7 order: visualizer → controls → footer):
//   • ECHO TAPS panel on top — every repeat as a red tap on a time axis.
//   • Preset grid (2×4) matched to the knob cluster width.
//   • Knob bank in four labelled sections: TIME · FEEDBACK · MOD · OUT.
//   • SYNC pill: TIME knobs give way to note-division cells (1/32 … 1/2,
//     T = triplet, D = dotted) locked to Logic's tempo.
//   • PING-PONG pill next to the FEEDBACK section.
//

import AppKit
import AudioToolbox

final class DelayParameterView: NSView {
    var audioUnit: DelayAudioUnit? { didSet { rebind() } }
    private let inkDark = Palette.inkLight
    private let inkMid  = Palette.inkMidL
    private let red     = Palette.red
    private let cream   = Palette.cream
    private let faceBg  = Palette.faceBg

    private var knobs: [KnobView] = []
    private var knobByID: [String: KnobView] = [:]
    private let taps = EchoTapView(frame: .zero)
    private let undoCtl = ParamUndo()
    private var refreshTimer: Timer?
    private var lastSig = ""

    // Parameter addresses (DelayAudioUnit.mm).
    private enum Addr: AUParameterAddress { case timeL = 0, timeR, feedback, filter, mix, pingpong, bass, wobble, wobrate, warmth, sync, divL, divR }

    // Knob sections, left → right.
    private let sections: [(name: String, ids: [String])] = [
        ("TIME",     ["timeL", "timeR"]),
        ("FEEDBACK", ["feedback", "bass", "filter", "warmth"]),
        ("MOD",      ["wobble", "wobrate"]),
        ("OUT",      ["mix"]),
    ]

    // Geometry.
    private let pad: CGFloat = 18, topBarH: CGFloat = 42, footerH: CGFloat = 44
    private let kW: CGFloat = 78, kH: CGFloat = 116, kGap: CGFloat = 8, groupGap: CGFloat = 26
    private let captionH: CGFloat = 22
    private let presetRowH: CGFloat = 34, presetVGap: CGFloat = 5
    private var knobY: CGFloat { footerH + 6 }
    private var clusterW: CGFloat {
        let n = CGFloat(sections.reduce(0) { $0 + $1.ids.count })
        let inner = CGFloat(sections.reduce(0) { $0 + max(0, $1.ids.count - 1) })
        return n * kW + inner * kGap + CGFloat(sections.count - 1) * groupGap
    }
    private var clusterX: CGFloat { (bounds.width - clusterW) * 0.5 }
    private func knobFrames() -> [String: NSRect] {
        var out: [String: NSRect] = [:]
        var x = clusterX
        for sec in sections {
            for id in sec.ids { out[id] = NSRect(x: x, y: knobY, width: kW, height: kH); x += kW + kGap }
            x += groupGap - kGap
        }
        return out
    }
    private func groupFrames() -> [(name: String, rect: NSRect)] {
        var out: [(String, NSRect)] = []
        var x = clusterX
        for sec in sections {
            let w = CGFloat(sec.ids.count) * kW + CGFloat(sec.ids.count - 1) * kGap
            out.append((sec.name, NSRect(x: x, y: knobY, width: w, height: kH)))
            x += w + groupGap
        }
        return out
    }
    private func presetGridFrame() -> NSRect {
        let y = knobY + kH + captionH + 6
        return NSRect(x: clusterX, y: y, width: clusterW, height: presetRowH * 2 + presetVGap)
    }

    // Hit rects (refreshed every draw).
    private var presetRects: [NSRect] = []
    private var syncRect: NSRect = .zero
    private var ppRect: NSRect = .zero
    private var divRects: [(id: String, rect: NSRect, addr: AUParameterAddress)] = []

    // Presets — ms for FREE, note divisions for SYNC (both applied).
    private struct Preset {
        let name: String
        let timeMs: Float; let divL: Int; let divR: Int
        let feedback: Float; let mix: Float
        var wobble: Float = 0; var wobRate: Float = 1.0; var warmth: Float = 0.30; var filter: Float = 3200
    }
    private let presets: [Preset] = [
        Preset(name: "SLAP",    timeMs: 110, divL: 0, divR: 0, feedback: 0.05, mix: 0.35),
        Preset(name: "1/4",     timeMs: 500, divL: 7, divR: 7, feedback: 0.35, mix: 0.30),
        Preset(name: "DOT 8",   timeMs: 375, divL: 6, divR: 6, feedback: 0.50, mix: 0.40),
        Preset(name: "1/8",     timeMs: 250, divL: 4, divR: 4, feedback: 0.30, mix: 0.30),
        Preset(name: "1/16",    timeMs: 125, divL: 1, divR: 1, feedback: 0.25, mix: 0.25),
        Preset(name: "AMBIENT", timeMs: 600, divL: 9, divR: 7, feedback: 0.78, mix: 0.55, warmth: 0.45, filter: 4200),
        Preset(name: "TAPE",    timeMs: 320, divL: 6, divR: 7, feedback: 0.58, mix: 0.42, wobble: 0.55, wobRate: 0.6, warmth: 0.75, filter: 2600),
        Preset(name: "1/8T",    timeMs: 167, divL: 5, divR: 5, feedback: 0.42, mix: 0.33, wobble: 0.10, wobRate: 1.2, warmth: 0.40, filter: 3600),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.backgroundColor = faceBg.cgColor
        addSubview(taps)
        // 5 Hz: reflect SYNC / tempo changes coming from the host or automation.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, let au = self.audioUnit else { return }
            let sig = "\(self.isSynced)|\(au.bpmSynced)|\(Int(au.hostBPM))|\(Int(au.effectiveTimeL))|\(Int(au.effectiveTimeR))|\(Int(self.param(.divL)))|\(Int(self.param(.divR)))|\(self.param(.pingpong))"
            if sig != self.lastSig { self.lastSig = sig; self.syncKnobVisibility(); self.needsDisplay = true }
        }
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    deinit { refreshTimer?.invalidate() }

    // MARK: - Parameter helpers
    private func param(_ a: Addr) -> Float { audioUnit?.parameterTree?.parameter(withAddress: a.rawValue)?.value ?? 0 }
    private func setParam(_ a: Addr, _ v: Float) { audioUnit?.parameterTree?.parameter(withAddress: a.rawValue)?.setValue(v, originator: nil) }
    private var isSynced: Bool { param(.sync) > 0.5 }
    private var divCount: Int { Int(DelayAudioUnit.divisionCount()) }
    private func divName(_ i: Int) -> String { DelayAudioUnit.divisionName(Int32(i)) }
    private func syncKnobVisibility() {
        let hide = isSynced
        knobByID["timeL"]?.isHidden = hide
        knobByID["timeR"]?.isHidden = hide
    }

    // MARK: - Layout
    override func layout() {
        super.layout()
        let frames = knobFrames()
        for k in knobs { if let id = k.parameterIdentifier, let f = frames[id] { k.frame = f } }
        let grid = presetGridFrame()
        let top = bounds.height - topBarH - 10
        let bottom = grid.maxY + 10
        taps.frame = NSRect(x: clusterX, y: bottom, width: clusterW, height: max(120, top - bottom))
    }

    // MARK: - Drawing
    override func draw(_ r: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        FaceTexture.draw(in: bounds, ctx: ctx)
        let b = bounds

        // Top bar: brand, undo/redo, tempo readout.
        let bar = BrandStrip.drawTopBar(ctx: ctx, bounds: b, title: "DUB DELAY", code: "DLY-1", height: topBarH, pad: pad)
        undoCtl.draw(in: b, ctx: ctx, ink: inkDark, mid: inkMid, pad: pad, y: bar.midY - 8)
        if let au = audioUnit {
            let synced = au.bpmSynced
            let s = NSString(string: synced ? String(format: "● SYNC %.0f BPM", au.hostBPM) : "○ FREE · NO HOST TEMPO")
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 9, weight: .heavy), .foregroundColor: synced ? red : inkMid, .kern: 0.6]
            let z = s.size(withAttributes: a)
            s.draw(at: NSPoint(x: b.width - pad - 58 - 18 - z.width, y: bar.midY - z.height * 0.5), withAttributes: a)
        }

        // Footer.
        BrandStrip.drawFooter(ctx: ctx, bounds: b, plugin: "DELAY", code: "DLY-1", spec: "AU v3 · STEREO · DUB · SYNC", pad: pad)

        drawSectionCaptions(ctx)
        if isSynced { drawDivisionCells(ctx) }
        drawPresetGrid(ctx)
    }

    /// Section names above each knob group with a hairline, plus the SYNC
    /// and PING-PONG pills at the right end of the TIME / FEEDBACK groups.
    private func drawSectionCaptions(_ ctx: CGContext) {
        let cap: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .heavy), .foregroundColor: inkDark, .kern: 0.8]
        let y = knobY + kH + 4
        syncRect = .zero; ppRect = .zero
        for g in groupFrames() {
            let s = NSString(string: g.name); let z = s.size(withAttributes: cap)
            s.draw(at: NSPoint(x: g.rect.minX, y: y), withAttributes: cap)
            var lineEnd = g.rect.maxX
            if g.name == "TIME" {
                syncRect = NSRect(x: g.rect.maxX - 52, y: y + 1, width: 52, height: 15)
                drawPill(ctx, syncRect, "SYNC", active: isSynced); lineEnd = syncRect.minX - 6
            } else if g.name == "FEEDBACK" {
                ppRect = NSRect(x: g.rect.maxX - 76, y: y + 1, width: 76, height: 15)
                drawPill(ctx, ppRect, "PING-PONG", active: param(.pingpong) > 0.5); lineEnd = ppRect.minX - 6
            }
            ctx.setStrokeColor(inkMid.withAlphaComponent(0.35).cgColor); ctx.setLineWidth(0.5)
            ctx.move(to: NSPoint(x: g.rect.minX + z.width + 8, y: y + 8)); ctx.addLine(to: NSPoint(x: lineEnd, y: y + 8)); ctx.strokePath()
        }
    }

    private func drawPill(_ ctx: CGContext, _ r: NSRect, _ label: String, active: Bool) {
        let path = CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil)
        if active { ctx.setFillColor(red.cgColor); ctx.addPath(path); ctx.fillPath() }
        else { ctx.setStrokeColor(inkDark.withAlphaComponent(0.6).cgColor); ctx.setLineWidth(0.8); ctx.addPath(path); ctx.strokePath() }
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .heavy), .foregroundColor: active ? cream : inkDark, .kern: 0.6]
        let s = NSString(string: label); let z = s.size(withAttributes: a)
        s.draw(at: NSPoint(x: r.midX - z.width * 0.5, y: r.midY - z.height * 0.5), withAttributes: a)
    }

    /// SYNC on: the two TIME knobs are hidden and these note-division cells
    /// take their frames. Click = next division, ⌥-click = previous, scroll
    /// wheel steps too.
    private func drawDivisionCells(_ ctx: CGContext) {
        divRects.removeAll()
        let frames = knobFrames()
        let au = audioUnit
        for (id, addr, label, ms) in [("timeL", Addr.divL, "TIME L", au?.effectiveTimeL ?? 0),
                                      ("timeR", Addr.divR, "TIME R", au?.effectiveTimeR ?? 0)] {
            guard let f = frames[id] else { continue }
            let cell = NSRect(x: f.minX + 2, y: f.minY + 18, width: f.width - 4, height: f.height - 26)
            let path = CGPath(roundedRect: cell, cornerWidth: 4, cornerHeight: 4, transform: nil)
            ctx.setFillColor(Palette.panelDark.cgColor); ctx.addPath(path); ctx.fillPath()
            ctx.setStrokeColor(red.cgColor); ctx.setLineWidth(1.2); ctx.addPath(path); ctx.strokePath()
            let idx = Int(param(addr))
            let big: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 16, weight: .heavy), .foregroundColor: inkDark, .kern: 0.4]
            let s = NSString(string: divName(idx)); let z = s.size(withAttributes: big)
            s.draw(at: NSPoint(x: cell.midX - z.width * 0.5, y: cell.midY - z.height * 0.5 + 6), withAttributes: big)
            let sub: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular), .foregroundColor: inkMid]
            let ms = NSString(string: String(format: "%.0f ms", ms)); let mz = ms.size(withAttributes: sub)
            ms.draw(at: NSPoint(x: cell.midX - mz.width * 0.5, y: cell.minY + 8), withAttributes: sub)
            let arrows: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular), .foregroundColor: inkMid.withAlphaComponent(0.7)]
            NSString(string: "◂").draw(at: NSPoint(x: cell.minX + 5, y: cell.midY - 1), withAttributes: arrows)
            NSString(string: "▸").draw(at: NSPoint(x: cell.maxX - 11, y: cell.midY - 1), withAttributes: arrows)
            // Caption under the cell in the knob's label position.
            let lab: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 9, weight: .heavy), .foregroundColor: inkDark, .kern: 0.6]
            let ls = NSString(string: label); let lz = ls.size(withAttributes: lab)
            ls.draw(at: NSPoint(x: f.midX - lz.width * 0.5, y: f.minY + 4), withAttributes: lab)
            divRects.append((id, cell, addr.rawValue))
        }
    }

    private func drawPresetGrid(_ ctx: CGContext) {
        presetRects.removeAll()
        let grid = presetGridFrame()
        let cols = 4, rows = 2
        let hGap: CGFloat = 8
        let cellW = (grid.width - CGFloat(cols - 1) * hGap) / CGFloat(cols)
        let cellH = (grid.height - CGFloat(rows - 1) * presetVGap) / CGFloat(rows)
        let synced = isSynced
        for (i, p) in presets.enumerated() {
            let col = i % cols, row = i / cols
            let cx = grid.minX + CGFloat(col) * (cellW + hGap)
            let cy = grid.minY + CGFloat(rows - 1 - row) * (cellH + presetVGap)
            let r = NSRect(x: cx, y: cy, width: cellW, height: cellH)
            presetRects.append(r)
            let path = CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil)
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.08).cgColor); ctx.addPath(path); ctx.fillPath()
            ctx.setStrokeColor(red.cgColor); ctx.setLineWidth(1.2); ctx.addPath(path); ctx.strokePath()
            ctx.setFillColor(red.cgColor); ctx.fill(NSRect(x: r.minX + 5, y: r.maxY - 8, width: 4, height: 4))
            let nm: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .heavy), .foregroundColor: inkDark, .kern: 1.0]
            let s = NSString(string: p.name); let sz = s.size(withAttributes: nm)
            s.draw(at: NSPoint(x: r.midX - sz.width * 0.5, y: r.midY - 1), withAttributes: nm)
            let sub: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .regular), .foregroundColor: inkMid]
            let timeStr = synced ? (p.divL == p.divR ? divName(p.divL) : "\(divName(p.divL))·\(divName(p.divR))") : String(format: "%.0fms", p.timeMs)
            let info = NSString(string: String(format: "%@ · FB %.0f%% · MIX %.0f%%", timeStr, p.feedback * 100, p.mix * 100))
            let isz = info.size(withAttributes: sub)
            info.draw(at: NSPoint(x: r.midX - isz.width * 0.5, y: r.minY + 3), withAttributes: sub)
        }
    }

    // MARK: - Interaction
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if undoCtl.handleClick(p) { needsDisplay = true; return }
        if syncRect.contains(p) { setParam(.sync, isSynced ? 0 : 1); syncKnobVisibility(); needsDisplay = true; return }
        if ppRect.contains(p) { setParam(.pingpong, param(.pingpong) > 0.5 ? 0 : 1); needsDisplay = true; return }
        for d in divRects where d.rect.contains(p) {
            let back = event.modifierFlags.contains(.option) || p.x < d.rect.minX + 18
            stepDivision(d.addr, back ? -1 : 1); return
        }
        for (i, r) in presetRects.enumerated() where r.contains(p) { applyPreset(presets[i]); return }
        super.mouseDown(with: event)
    }
    override func scrollWheel(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for d in divRects where d.rect.contains(p) {
            if abs(event.deltaY) < 0.3 { return }
            stepDivision(d.addr, event.deltaY > 0 ? 1 : -1); return
        }
        super.scrollWheel(with: event)
    }
    private func stepDivision(_ addr: AUParameterAddress, _ delta: Int) {
        guard let prm = audioUnit?.parameterTree?.parameter(withAddress: addr) else { return }
        let n = divCount
        let next = ((Int(prm.value) + delta) % n + n) % n
        prm.setValue(AUValue(next), originator: nil)
        needsDisplay = true
    }

    private func applyPreset(_ pr: Preset) {
        guard let tree = audioUnit?.parameterTree else { return }
        func set(_ a: Addr, _ v: Float) { tree.parameter(withAddress: a.rawValue)?.setValue(v, originator: nil) }
        set(.timeL, pr.timeMs); set(.timeR, pr.timeMs)
        set(.divL, Float(pr.divL)); set(.divR, Float(pr.divR))
        set(.feedback, pr.feedback); set(.filter, pr.filter); set(.mix, pr.mix)
        set(.wobble, pr.wobble); set(.wobrate, pr.wobRate); set(.warmth, pr.warmth)
        needsDisplay = true
    }

    private func rebind() {
        knobs.forEach { $0.removeFromSuperview() }; knobs.removeAll(); knobByID.removeAll()
        guard let au = audioUnit, let tree = au.parameterTree else { return }
        taps.audioUnit = au
        undoCtl.attach(au)
        undoCtl.onChange = { [weak self] in self?.syncKnobVisibility(); self?.needsDisplay = true }
        let skip: Set<String> = ["pingpong", "sync", "divL", "divR"]
        for node in tree.children {
            guard let p = node as? AUParameter, !skip.contains(p.identifier) else { continue }
            let k = KnobView(frame: .zero); k.bind(parameter: p)
            switch p.identifier {
            case "timeL", "timeR": k.displayFormatter = { String(format: "%.0fms", $0) }
            case "feedback", "mix", "wobble", "warmth": k.displayFormatter = { String(format: "%.0f%%", $0 * 100) }
            case "filter", "bass": k.displayFormatter = { v in v >= 1000 ? String(format: "%.1fk", v/1000) : String(format: "%.0fHz", v) }
            case "wobrate": k.displayFormatter = { String(format: "%.2fHz", $0) }
            default: break
            }
            addSubview(k); knobs.append(k); knobByID[p.identifier] = k
        }
        syncKnobVisibility()
        needsLayout = true; needsDisplay = true
    }
}
