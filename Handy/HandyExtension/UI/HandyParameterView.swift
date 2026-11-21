//
//  HandyParameterView.swift
//  Paradise Audio — Handy (HBY-1) · MP3/AAC sampler instrument.
//
//  Layout (dark faceplate, top→bottom):
//   • Top bar  — wordmark + brand square, undo/redo, spec tag, with the 2px red
//                stripe (matches SynthThing / Compressor).
//   • Live OUTPUT scope band.
//   • SAMPLE ZONES section — labelled header + LOAD/CLEAR toolbar that act on
//                the highlighted zone, then TWO large horizontal sample boxes
//                stacked vertically (zone 1 = keys 1–16, zone 2 = keys 17–32).
//                Each box is a drop target + waveform with a RANGE selector.
//   • RESTORATION CHAIN section — inset panel holding the 6-knob bank, grouped
//                TONE · CLEAN-UP · OUTPUT, plus the global PITCH knob.
//   • Footer  — Paradise brand block + hairline + supported-format strip.
//

import AppKit
import AudioToolbox
import AVFoundation
import UniformTypeIdentifiers

final class HandyParameterView: NSView, ZoneBoxViewDelegate {
    var audioUnit: HandyAudioUnit? { didSet { rebind() } }

    // Dark-faceplate palette (the SynthThing / Compressor twin scheme).
    private let faceBg  = Palette.faceBg
    private let barBg   = Palette.wellBg
    private let panelBg = Palette.panelDark
    private let inkDark = Palette.inkLight
    private let inkMid  = Palette.inkMidL
    private let red     = Palette.red

    private var zones: [ZoneBoxView] = []
    private var knobs: [KnobView] = []
    private var pitchKnob: KnobView?        // global transpose knob (param "pt")
    private var loadButton: NSButton!
    private var clearButton: NSButton!
    private var scopeTimer: Timer?
    private var selectedZone: Int = 0
    private let undoCtl = ParamUndo()

    // Knob bank display order + grouping: TONE, CLEAN-UP, OUTPUT.
    private let knobOrder = ["hf", "wa", "nr", "tr", "lv", "mx"]
    private let groupCaptions = ["TONE", "CLEAN-UP", "OUTPUT"]

    // MARK: - Geometry (shared by layout() and draw() so they never drift)

    private let margin: CGFloat = 18
    private let topBarH: CGFloat = 46
    private let footerH: CGFloat = 34
    private let scopeH: CGFloat = 34

    private func topBarRect() -> NSRect {
        NSRect(x: 0, y: bounds.height - topBarH, width: bounds.width, height: topBarH)
    }
    private func scopeBandRect() -> NSRect {
        NSRect(x: margin, y: bounds.height - topBarH - scopeH,
               width: bounds.width - 2 * margin, height: scopeH - 6)
    }
    private func scopeWaveRect() -> NSRect {
        let b = scopeBandRect()
        return NSRect(x: b.minX, y: b.minY, width: b.width, height: b.height)
    }
    private func knobPanelRect() -> NSRect {
        NSRect(x: margin, y: 44, width: bounds.width - 2 * margin, height: 156)
    }
    private func zoneHeaderRowY() -> CGFloat { bounds.height - topBarH - scopeH - 24 }
    /// Region holding the two stacked sample boxes.
    private func zonesRect() -> NSRect {
        let top    = zoneHeaderRowY() - 18
        let bottom = knobPanelRect().maxY + 10
        return NSRect(x: margin, y: bottom, width: bounds.width - 2 * margin, height: max(120, top - bottom))
    }

    // Knob bank metrics.
    private let kW: CGFloat = 72, kH: CGFloat = 96
    private let kIntra: CGFloat = 8
    private let kInter: CGFloat = 40
    // Reserve room on the right of the knob panel for the global PITCH knob.
    private let pitchKnobW: CGFloat = 78
    private func knobBankStartX() -> CGFloat {
        let total = 6 * kW + 3 * kIntra + 2 * kInter
        // Bias slightly left so the PITCH knob has its own space on the right.
        return max(margin + 8, (bounds.width - total - pitchKnobW - 24) * 0.5)
    }
    private func knobFrame(_ i: Int) -> NSRect {
        let group = i / 2, within = CGFloat(i % 2)
        let groupBlock = 2 * kW + kIntra + kInter
        let x = knobBankStartX() + CGFloat(group) * groupBlock + within * (kW + kIntra)
        let y = knobPanelRect().minY + 12
        return NSRect(x: x, y: y, width: kW, height: kH)
    }
    private func pitchKnobFrame() -> NSRect {
        let panel = knobPanelRect()
        return NSRect(x: panel.maxX - pitchKnobW - 12, y: panel.minY + 12, width: pitchKnobW, height: kH)
    }
    private func groupCenterX(_ g: Int) -> CGFloat {
        let groupBlock = 2 * kW + kIntra + kInter
        return knobBankStartX() + CGFloat(g) * groupBlock + (2 * kW + kIntra) * 0.5
    }

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = faceBg.cgColor

        loadButton = makeToolbarButton("LOAD", #selector(loadSelected))
        clearButton = makeToolbarButton("CLEAR", #selector(clearSelected))
        addSubview(loadButton); addSubview(clearButton)

        for i in 0..<2 {
            let z = ZoneBoxView(index: i); z.delegate = self
            addSubview(z); zones.append(z)
        }
        scopeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let s = self else { return }
            s.setNeedsDisplay(s.scopeBandRect())      // only the scope band, not the whole faceplate
        }
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    deinit { scopeTimer?.invalidate(); NotificationCenter.default.removeObserver(self) }

    @objc private func handleStateRestored() { refreshZones() }

    private func makeToolbarButton(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .roundRect
        b.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        return b
    }

    // MARK: - Sample load / clear

    @objc private func loadSelected() {
        guard let au = audioUnit else { return }
        SampleStore.openAndLoad(into: au, pad: selectedZone)
        refreshZones()
    }
    @objc private func clearSelected() {
        guard let au = audioUnit else { return }
        au.clearPad(selectedZone)
        SampleStore.clearPeaks(for: selectedZone)
        refreshZones()
    }

    private func refreshZones() {
        guard let au = audioUnit else { return }
        for (i, z) in zones.enumerated() {
            let name = au.name(forPad: i)
            z.sampleName = name
            z.isLoaded = (name != "— EMPTY —")
            z.isSelected = (i == selectedZone)
            // Peaks are cached per process by SampleStore when a file is
            // dropped. After a project reload (or reopening the editor) the
            // sample lives only in the AU, so pull it back and rebuild them —
            // otherwise a loaded zone shows a flat line.
            if z.isLoaded && SampleStore.peaks(for: i).isEmpty {
                let n = Int(au.sampleLength(forPad: i))
                if n > 1 {
                    var buf = [Float](repeating: 0, count: n)
                    let got = buf.withUnsafeMutableBufferPointer { p -> Int in
                        Int(au.copySample(forPad: i, into: p.baseAddress!, maxFrames: n))
                    }
                    if got > 1 { SampleStore.setPeaks(SampleStore.computePeaks(Array(buf.prefix(got))), for: i) }
                }
            }
            z.peaks = SampleStore.peaks(for: i)
        }
        needsDisplay = true
    }

    /// MIDI key-span label for a zone, e.g. "C2–D#3". Zone roots come straight
    /// from the AU; the span is 16 semitones.
    private func keySpanString(for index: Int) -> String {
        let root = Int(audioUnit?.rootNote(forPad: index) ?? Int32(36 + index * 16))
        return "\(midiName(root))–\(midiName(root + 15))"
    }
    private func midiName(_ note: Int) -> String {
        let names = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
        let octave = note / 12 - 1
        return "\(names[note % 12])\(octave)"
    }

    // MARK: - ZoneBoxViewDelegate

    func zone(_ box: ZoneBoxView, didTriggerAt index: Int) {
        selectedZone = index; refreshZones()
        audioUnit?.triggerPad(index, velocity: 100)
    }
    func zone(_ box: ZoneBoxView, didRequestLoadAt index: Int) {
        selectedZone = index; refreshZones(); loadSelected()
    }
    func zone(_ box: ZoneBoxView, didRequestClearAt index: Int) {
        selectedZone = index; refreshZones(); clearSelected()
    }
    func zone(_ box: ZoneBoxView, didDropFileAt index: Int, url: URL) {
        guard let au = audioUnit else { return }
        selectedZone = index
        _ = SampleStore.loadFile(url: url, into: au, pad: index)
        refreshZones()
    }
    func zone(_ box: ZoneBoxView, didRequestRecentAt index: Int) -> [URL] {
        return SampleStore.recents
    }
    func zone(_ box: ZoneBoxView, didPickRecentURL url: URL, at index: Int) {
        guard let au = audioUnit else { return }
        selectedZone = index
        _ = SampleStore.loadFile(url: url, into: au, pad: index)
        refreshZones()
    }

    func zoneRange(for index: Int) -> (start: Float, end: Float) {
        guard let au = audioUnit else { return (0, 1) }
        return (au.rangeStart(forPad: index), au.rangeEnd(forPad: index))
    }
    func zoneSetRange(_ start: Float, _ end: Float, for index: Int) {
        audioUnit?.setRangeForPad(index, start: start, end: end)
    }
    func zoneChop(for index: Int) -> Float          { audioUnit?.chop(forPad: index) ?? 0 }
    func zoneSetChop(_ knob: Float, for index: Int) { audioUnit?.setChopForPad(index, knob: knob) }
    func zoneKeyTrigger(for index: Int) -> Bool        { audioUnit?.keyTrigger(forPad: index) ?? false }
    func zoneSetKeyTrigger(_ on: Bool, for index: Int) { audioUnit?.setKeyTriggerForPad(index, on: on) }
    func zoneKeySpan(for index: Int) -> String      { keySpanString(for: index) }

    // MARK: - Layout

    override func layout() {
        super.layout()

        loadButton.sizeToFit(); clearButton.sizeToFit()
        let btnW: CGFloat = 58, btnH: CGFloat = 20
        let rowY = zoneHeaderRowY() - 3
        clearButton.frame = NSRect(x: bounds.width - margin - btnW, y: rowY, width: btnW, height: btnH)
        loadButton.frame  = NSRect(x: clearButton.frame.minX - 8 - btnW, y: rowY, width: btnW, height: btnH)

        // Two large horizontal boxes stacked vertically.
        let area = zonesRect()
        let gap: CGFloat = 12
        let boxH = (area.height - gap) / 2
        for (i, z) in zones.enumerated() {
            // i=0 on top (zone 1 / lower keys), i=1 beneath it.
            let y = area.maxY - CGFloat(i + 1) * boxH - CGFloat(i) * gap
            z.frame = NSRect(x: area.minX, y: y, width: area.width, height: boxH)
        }

        for (i, k) in knobs.enumerated() { k.frame = knobFrame(i) }
        pitchKnob?.frame = pitchKnobFrame()
    }

    // MARK: - Drawing

    override func draw(_ r: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        FaceTexture.draw(in: bounds, ctx: ctx)
        drawTopBar(ctx)
        drawScope(ctx)
        drawZoneSection(ctx)
        drawKnobPanel(ctx)
        drawMascot(ctx)
        drawFooter(ctx)
    }

    /// "Handy Dude" — the sticker mascot leaning into the bottom-right.
    private static let mascotCG: CGImage? = {
        let b = Bundle(for: HandyParameterView.self)
        if let u = b.url(forResource: "handy_dude", withExtension: "png"),
           let img = NSImage(contentsOf: u),
           let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) { return cg }
        return nil
    }()
    private func drawMascot(_ ctx: CGContext) {
        guard let cg = HandyParameterView.mascotCG else { return }
        let h: CGFloat = 116
        let w = h * CGFloat(cg.width) / CGFloat(cg.height)
        // Left end of the RESTORATION CHAIN panel — the bank starts ~280 px in,
        // so the sticker has room there instead of sitting under the PITCH knob.
        let rect = CGRect(x: margin + 16, y: knobPanelRect().minY + 8, width: w, height: h)
        ctx.saveGState(); ctx.setAlpha(0.96); ctx.draw(cg, in: rect); ctx.restoreGState()
    }

    // MARK: - Live output scope

    private func drawScope(_ ctx: CGContext) {
        let band = scopeBandRect()
        ctx.setFillColor(NSColor(calibratedWhite: 0.07, alpha: 1).cgColor); ctx.fill(band)
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.30).cgColor); ctx.setLineWidth(0.5); ctx.stroke(band)

        let wave = scopeWaveRect()
        ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.12).cgColor); ctx.setLineWidth(0.5)
        ctx.move(to: NSPoint(x: wave.minX, y: wave.midY)); ctx.addLine(to: NSPoint(x: wave.maxX, y: wave.midY)); ctx.strokePath()

        if let au = audioUnit {
            let want = min(Int(wave.width), Int(au.probeSize))
            if want > 4 {
                var buf = [Float](repeating: 0, count: want)
                let got = buf.withUnsafeMutableBufferPointer { p -> Int in
                    Int(au.readProbe(p.baseAddress!, count: want))
                }
                if got > 1 {
                    let halfH = wave.height * 0.44
                    ctx.setStrokeColor(red.cgColor); ctx.setLineWidth(1.0)
                    for i in 0..<got {
                        let x = wave.minX + CGFloat(i) / CGFloat(max(1, got - 1)) * wave.width
                        let h = CGFloat(min(1.3, buf[i])) * halfH
                        ctx.move(to: NSPoint(x: x, y: wave.midY - h))
                        ctx.addLine(to: NSPoint(x: x, y: wave.midY + h))
                    }
                    ctx.strokePath()
                }
            }
        }
        let l: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .heavy), .foregroundColor: NSColor.white.withAlphaComponent(0.5), .kern: 0.6]
        NSString(string: "OUTPUT").draw(at: NSPoint(x: wave.minX + 4, y: band.minY + 2), withAttributes: l)
    }

    private func drawTopBar(_ ctx: CGContext) {
        let tr = topBarRect()
        ctx.setFillColor(barBg.cgColor); ctx.fill(tr)
        ctx.setFillColor(red.cgColor); ctx.fill(NSRect(x: 0, y: tr.minY, width: tr.width, height: 2))

        let cy = tr.midY
        ctx.setFillColor(red.cgColor); BrandLogo.draw(in: NSRect(x: margin - 2, y: cy - 18, width: 38, height: 38), ctx: ctx)
        let wm: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .bold), .foregroundColor: inkDark, .kern: 1.5]
        NSString(string: "HANDY BOY").draw(at: NSPoint(x: margin + 46, y: cy - 2), withAttributes: wm)
        let subAttr: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .regular), .foregroundColor: inkMid, .kern: 0.6]
        NSString(string: "MP3 · AAC · WAV SAMPLER").draw(at: NSPoint(x: margin + 46, y: cy - 14), withAttributes: subAttr)

        let tag: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .regular), .foregroundColor: inkMid, .kern: 0.5]
        let ts = NSString(string: "AU v3 · INSTRUMENT"); let tw = ts.size(withAttributes: tag)
        ts.draw(at: NSPoint(x: tr.maxX - margin - tw.width, y: cy - 4), withAttributes: tag)

        undoCtl.draw(in: bounds, ctx: ctx, ink: inkDark, mid: inkMid, pad: margin + tw.width + 16, y: cy - 8)
    }

    private func drawZoneSection(_ ctx: CGContext) {
        let hy = zoneHeaderRowY()
        let head: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .heavy), .foregroundColor: inkDark, .kern: 0.8]
        NSString(string: "SAMPLE ZONES").draw(at: NSPoint(x: margin, y: hy), withAttributes: head)
        let hint: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .regular), .foregroundColor: inkMid, .kern: 0.4]
        NSString(string: "DROP AUDIO ON A ZONE · DRAG THE RANGE HANDLES · CLICK TO AUDITION")
            .draw(at: NSPoint(x: margin, y: hy - 12), withAttributes: hint)

        let sel: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 8, weight: .heavy), .foregroundColor: red, .kern: 0.6]
        let ss = NSString(string: "SELECTED ▸ ZONE \(selectedZone + 1)")
        let sw = ss.size(withAttributes: sel)
        ss.draw(at: NSPoint(x: loadButton.frame.minX - 14 - sw.width, y: hy - 1), withAttributes: sel)
    }

    private func drawKnobPanel(_ ctx: CGContext) {
        let panel = knobPanelRect()
        ctx.setFillColor(panelBg.cgColor); ctx.fill(panel)
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.30).cgColor); ctx.setLineWidth(0.5); ctx.stroke(panel)

        let head: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .heavy), .foregroundColor: inkDark, .kern: 0.8]
        NSString(string: "RESTORATION CHAIN").draw(at: NSPoint(x: panel.minX + 10, y: panel.maxY - 18), withAttributes: head)
        let flow: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .regular), .foregroundColor: inkMid, .kern: 0.4]
        let fs = NSString(string: "HF → NOISE → TRANSIENT → WARMTH → LEVEL → MIX")
        let fw = fs.size(withAttributes: flow)
        fs.draw(at: NSPoint(x: panel.maxX - 10 - fw.width, y: panel.maxY - 16), withAttributes: flow)

        let cap: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 8, weight: .heavy), .foregroundColor: inkMid, .kern: 0.8]
        let capY = knobFrame(0).maxY + 6
        for g in 0..<3 {
            let s = NSString(string: groupCaptions[g]); let sz = s.size(withAttributes: cap)
            s.draw(at: NSPoint(x: groupCenterX(g) - sz.width * 0.5, y: capY), withAttributes: cap)
        }
        // PITCH group caption over the global knob.
        let pf = pitchKnobFrame()
        let ps = NSString(string: "PITCH"); let psz = ps.size(withAttributes: cap)
        ps.draw(at: NSPoint(x: pf.midX - psz.width * 0.5, y: capY), withAttributes: cap)

        ctx.setStrokeColor(inkDark.withAlphaComponent(0.20).cgColor); ctx.setLineWidth(0.5)
        let groupBlock = 2 * kW + kIntra + kInter
        for g in 0..<2 {
            let x = (knobBankStartX() + CGFloat(g) * groupBlock + 2 * kW + kIntra + kInter * 0.5).rounded()
            ctx.move(to: NSPoint(x: x, y: panel.minY + 12))
            ctx.addLine(to: NSPoint(x: x, y: panel.maxY - 26))
        }
        // Divider before the PITCH knob.
        let px = (pf.minX - 12).rounded()
        ctx.move(to: NSPoint(x: px, y: panel.minY + 12))
        ctx.addLine(to: NSPoint(x: px, y: panel.maxY - 26))
        ctx.strokePath()
    }

    private func drawFooter(_ ctx: CGContext) {
        let b = bounds
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.25).cgColor); ctx.setLineWidth(0.5)
        ctx.move(to: NSPoint(x: margin, y: 36)); ctx.addLine(to: NSPoint(x: b.width - margin, y: 36)); ctx.strokePath()

        ctx.setFillColor(red.cgColor); BrandLogo.draw(in: NSRect(x: margin - 2, y: 1, width: 31, height: 31), ctx: ctx)
        let brand: [NSAttributedString.Key: Any] = [.font: Palette.printFontCondensed(11), .foregroundColor: inkDark, .kern: 1.2]
        NSString(string: "PARADISE AUDIO").draw(at: NSPoint(x: margin + 35, y: 15), withAttributes: brand)
        let sub: [NSAttributedString.Key: Any] = [.font: Palette.printFont(7.5), .foregroundColor: inkMid, .kern: 0.6]
        NSString(string: "HANDY BOY — HBY-1").draw(at: NSPoint(x: margin + 35, y: 4), withAttributes: sub)

        let fmt: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .regular), .foregroundColor: inkMid, .kern: 0.5]
        let fs = NSString(string: "MP3 · M4A · AAC · WAV · AIFF · CAF")
        let fw = fs.size(withAttributes: fmt)
        fs.draw(at: NSPoint(x: b.width - margin - fw.width, y: 8), withAttributes: fmt)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if undoCtl.handleClick(p) { needsDisplay = true; return }
        super.mouseDown(with: event)
    }

    // MARK: - Bind

    private func rebind() {
        knobs.forEach { $0.removeFromSuperview() }; knobs.removeAll()
        pitchKnob?.removeFromSuperview(); pitchKnob = nil
        guard let au = audioUnit, let tree = au.parameterTree else { return }
        undoCtl.attach(au)
        undoCtl.onChange = { [weak self] in self?.needsDisplay = true }

        NotificationCenter.default.removeObserver(self, name: NSNotification.Name("HandyDidRestoreState"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleStateRestored),
                                               name: NSNotification.Name("HandyDidRestoreState"), object: au)

        var byId: [String: AUParameter] = [:]
        for node in tree.children { if let p = node as? AUParameter { byId[p.identifier] = p } }

        for id in knobOrder {
            guard let p = byId[id] else { continue }
            let k = KnobView(frame: .zero); k.bind(parameter: p)
            switch id {
            case "hf", "wa": k.displayFormatter = { String(format: "%.2f", $0) }
            case "nr", "lv": k.displayFormatter = { String(format: "%.0f dB", $0) }
            case "tr":       k.displayFormatter = { String(format: "%+.2f", $0) }
            case "mx":       k.displayFormatter = { String(format: "%.0f%%", $0 * 100) }
            default: break
            }
            addSubview(k); knobs.append(k)
        }
        // Global PITCH knob (param "pt"; ±24 semitones).
        if let p = byId["pt"] {
            let k = KnobView(frame: .zero); k.bind(parameter: p)
            k.displayFormatter = { String(format: "%+.0f st", $0) }
            addSubview(k); pitchKnob = k
        }
        refreshZones(); needsLayout = true; needsDisplay = true
    }
}
