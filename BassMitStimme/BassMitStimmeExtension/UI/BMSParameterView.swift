import AppKit
import AudioToolbox
import UniformTypeIdentifiers
import AVFoundation

final class BMSParameterView: NSView {
    var audioUnit: BMSAudioUnit? { didSet { rebind() } }

    private let cream = Palette.cream
    private let inkDark = Palette.inkLight
    private let inkMid  = Palette.inkMidL
    private let red     = Palette.red
    private let faceBg  = Palette.faceBg
    private let undoCtl = ParamUndo()

    // Top-to-bottom sections. ENV row is amp-ADSR only (4 knobs, big).
    // STIMME panel is drawn by a dedicated subview, not a knob row.
    // `groupGaps` flags the index *before* which an extra gap is inserted, so a
    // single section row can read as two tidy sub-blocks. The FILTER·ENV row was
    // squished — 7 knobs jammed edge-to-edge with no visual break between the
    // amp ENVELOPE (attack/decay/sustain/release) and the FILTER (cut/res/env).
    // Now the ENV block sits to the LEFT, then a wide gap, then the filter knobs.
    // `subLabels` keys a sub-block caption by the index of its first knob, so a
    // gapped row can label each tidy sub-block ("ENV" over A/D/S/R, "FILTER"
    // over cut/res/env).
    private struct Section { let label: String; let ids: [String]; let groupGaps: Set<Int>; let subLabels: [Int: String] }
    private let sections: [Section] = [
        Section(label: "OSC",        ids: ["oct", "det", "sub", "fmA", "fmR", "noi"], groupGaps: [], subLabels: [:]),
        // ENV (aA/aD/aS/aR) first, then a gap, then FILTER (cut/res/env).
        Section(label: "ENV · FILTER", ids: ["aA", "aD", "aS", "aR", "cut", "res", "env"], groupGaps: [4], subLabels: [0: "ENV", 4: "FILTER"]),
        Section(label: "AMP",        ids: ["gain", "glide", "mode"], groupGaps: [], subLabels: [:]),
    ]
    // Extra horizontal padding inserted at every `groupGaps` boundary.
    private let groupGap: CGFloat = 34
    private var knobsById: [String: KnobView] = [:]
    private let stimmePanel = StimmePanel(frame: .zero)
    private let keysPanel = KeysPanel(frame: .zero)

    // Vintage analog CHARACTER selector. Each pill maps to an engine preset
    // (drift / drive / resonance boost / output sat / env shape).
    private let charNames = ["CLEAN", "MOOG", "303", "SH101", "JUNO"]
    private var charRects: [NSRect] = []

    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; layer?.backgroundColor = faceBg.cgColor
        addSubview(stimmePanel)
        addSubview(keysPanel)
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func layout() {
        super.layout()
        let pad: CGFloat = 18, footer: CGFloat = 42
        // Reserve the bottom strip for the STIMME panel — bigger now that it
        // contains the live bass+voice visualizer and the 9 stimme controls.
        let stimmeH: CGFloat = 212
        let stimmeY = footer + 6
        stimmePanel.frame = NSRect(x: pad, y: stimmeY, width: bounds.width - pad * 2, height: stimmeH)

        // KEYS strip — compact playable keyboard, sits just above STIMME.
        let keysGap: CGFloat = 10, keysH: CGFloat = 124
        let keysY = stimmeY + stimmeH + keysGap
        keysPanel.frame = NSRect(x: pad, y: keysY, width: bounds.width - pad * 2, height: keysH)

        let topY = bounds.height - 24
        let usableTop = topY - (keysY + keysH + 18)
        let sectionH = usableTop / CGFloat(sections.count)
        let labelW: CGFloat = 70
        let kW: CGFloat = 70, kH: CGFloat = 88, sp: CGFloat = 8
        for (idx, sec) in sections.enumerated() {
            let y = topY - CGFloat(idx + 1) * sectionH
            var x = pad + labelW
            for (ki, kid) in sec.ids.enumerated() {
                if sec.groupGaps.contains(ki) { x += groupGap }   // break into sub-blocks
                if let k = knobsById[kid] {
                    k.frame = NSRect(x: x, y: y + (sectionH - kH) * 0.5, width: kW, height: kH)
                    x += kW + sp
                }
            }
        }
    }

    override func draw(_ r: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Subtle brushed-aluminium faceplate (keeps panel colour, adds analogue grain).
        FaceTexture.draw(in: bounds, ctx: ctx)
        let b = bounds
        // Identity mark — a restrained "eclipse" ring, not a solid red disc.
        // DESIGN.md: red is a spotlight, not a wash; the old 80px red fill
        // dominated the whole faceplate. Now a thin red ring + centre dot +
        // hairline reads as a logo accent in the otherwise-empty top-right.
        let cx: CGFloat = b.width - 78, cy: CGFloat = b.height - 78, rr: CGFloat = 34
        ctx.setStrokeColor(red.withAlphaComponent(0.9).cgColor); ctx.setLineWidth(2.0)
        ctx.strokeEllipse(in: NSRect(x: cx - rr, y: cy - rr, width: rr * 2, height: rr * 2))
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.22).cgColor); ctx.setLineWidth(0.5)
        ctx.move(to: NSPoint(x: cx - rr - 8, y: cy)); ctx.addLine(to: NSPoint(x: cx + rr + 8, y: cy)); ctx.strokePath()
        ctx.setFillColor(red.cgColor); ctx.fillEllipse(in: NSRect(x: cx - 4, y: cy - 4, width: 8, height: 8))

        // Section labels + hairlines (sync with layout)
        let pad: CGFloat = 18, footer: CGFloat = 42
        let stimmeH: CGFloat = 212
        let stimmeY = footer + 6
        let keysGap: CGFloat = 10, keysH: CGFloat = 124
        let keysY = stimmeY + stimmeH + keysGap
        let topY = b.height - 24
        let usableTop = topY - (keysY + keysH + 18)
        let sectionH = usableTop / CGFloat(sections.count)
        let labelAttr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: inkDark, .kern: 0.8]
        // Sub-block caption (small caps, mid ink) sits just above its knob group.
        let subAttr: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .heavy), .foregroundColor: inkMid, .kern: 0.8]
        let labelW: CGFloat = 70, kW: CGFloat = 70, sp: CGFloat = 8
        for (idx, sec) in sections.enumerated() {
            let y = topY - CGFloat(idx + 1) * sectionH
            NSString(string: sec.label).draw(at: NSPoint(x: pad, y: y + sectionH * 0.5 - 5), withAttributes: labelAttr)
            ctx.setStrokeColor(inkDark.withAlphaComponent(0.18).cgColor); ctx.setLineWidth(0.5)
            ctx.move(to: NSPoint(x: pad, y: y)); ctx.addLine(to: NSPoint(x: b.width - pad, y: y)); ctx.strokePath()
            // Sub-block captions — walk the same x as layout() so they sit over
            // the right group. Caption baseline is just above the knob block.
            if !sec.subLabels.isEmpty {
                var x = pad + labelW
                let capY = y + (sectionH + 88) * 0.5 - 8   // top edge of the knob (kH = 88)
                for (ki, _) in sec.ids.enumerated() {
                    if sec.groupGaps.contains(ki) { x += groupGap }
                    if let cap = sec.subLabels[ki] {
                        NSString(string: cap).draw(at: NSPoint(x: x + 2, y: capY), withAttributes: subAttr)
                    }
                    x += kW + sp
                }
            }
        }

        // Brand
        ctx.setFillColor(red.cgColor); BrandLogo.draw(in: NSRect(x: 12, y: 2, width: 30, height: 30), ctx: ctx)
        let brand: [NSAttributedString.Key: Any] = [.font: Palette.printFontCondensed(11), .foregroundColor: inkDark, .kern: 1.2]
        NSString(string: "PARADISE AUDIO").draw(at: NSPoint(x: 46, y: 15), withAttributes: brand)
        let sub: [NSAttributedString.Key: Any] = [.font: Palette.printFont(7.5), .foregroundColor: inkMid, .kern: 0.6]
        NSString(string: "BASS MIT STIMME — BST-1").draw(at: NSPoint(x: 46, y: 4), withAttributes: sub)
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.25).cgColor); ctx.setLineWidth(0.5)
        ctx.move(to: NSPoint(x: 16, y: 36)); ctx.addLine(to: NSPoint(x: b.width - 16, y: 36)); ctx.strokePath()
        let aSpec: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .regular), .foregroundColor: Palette.inkMidL, .kern: 0.5]
        let specS = NSString(string: "AU v3 · STEREO · SUB BASS")
        let specZ = specS.size(withAttributes: aSpec)
        specS.draw(at: NSPoint(x: b.width - 16 - specZ.width, y: 8), withAttributes: aSpec)

        // CHARACTER selector — sits in the top-right where the AU tag used to be.
        // Tap a pill to apply a vintage analog preset (drift, drive, sat, env).
        let cur = Int(audioUnit?.analogCharacter ?? 0)
        let pillW: CGFloat = 50, pillH: CGFloat = 18, pillGap: CGFloat = 4
        let totalW = CGFloat(charNames.count) * pillW + CGFloat(charNames.count - 1) * pillGap
        let pillY = b.height - 30
        var px = b.width - 16 - totalW
        let labelAttrTop: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 7, weight: .heavy),
            .foregroundColor: inkMid, .kern: 0.6
        ]
        NSString(string: "ANALOG").draw(at: NSPoint(x: px - 46, y: pillY + 4), withAttributes: labelAttrTop)
        charRects.removeAll()
        let cornerR: CGFloat = pillH * 0.4
        for (i, name) in charNames.enumerated() {
            let pr = NSRect(x: px, y: pillY, width: pillW, height: pillH)
            charRects.append(pr)
            let path = CGPath(roundedRect: pr, cornerWidth: cornerR, cornerHeight: cornerR, transform: nil)
            let drewTex = ButtonTex.draw(ctx, rect: pr, active: i == cur, corner: cornerR)
            if i == cur {
                if !drewTex { ctx.setFillColor(red.cgColor); ctx.addPath(path); ctx.fillPath() }
                let attr: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10, weight: .heavy),
                    .foregroundColor: cream, .kern: 0.6
                ]
                let s = NSString(string: name)
                let sz = s.size(withAttributes: attr)
                s.draw(at: NSPoint(x: pr.midX - sz.width * 0.5, y: pr.midY - sz.height * 0.5 - 1), withAttributes: attr)
            } else {
                if !drewTex {
                    ctx.setFillColor(Palette.panelDark.cgColor); ctx.addPath(path); ctx.fillPath()
                    ctx.setStrokeColor(inkDark.withAlphaComponent(0.55).cgColor); ctx.setLineWidth(0.7)
                    ctx.addPath(path); ctx.strokePath()
                }
                let attr: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: inkDark, .kern: 0.5
                ]
                let s = NSString(string: name)
                let sz = s.size(withAttributes: attr)
                s.draw(at: NSPoint(x: pr.midX - sz.width * 0.5, y: pr.midY - sz.height * 0.5 - 1), withAttributes: attr)
            }
            px += pillW + pillGap
        }

        // Undo / redo — left of the ANALOG/CHARACTER pill block, on the pill row.
        undoCtl.draw(in: b, ctx: ctx, ink: inkDark, mid: inkMid, pad: 338, y: pillY)
        // SAVE / LOAD named presets — footer center, right of the brand block.
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if undoCtl.handleClick(p) { needsDisplay = true; return }
        for (i, rect) in charRects.enumerated() where rect.contains(p) {
            audioUnit?.analogCharacter = Int32(i)
            needsDisplay = true
            return
        }
        super.mouseDown(with: event)
    }

    private func rebind() {
        knobsById.values.forEach { $0.removeFromSuperview() }
        knobsById.removeAll()
        guard let au = audioUnit, let tree = au.parameterTree else { return }
        undoCtl.attach(au)
        undoCtl.onChange = { [weak self] in self?.needsDisplay = true }
        // Stimme knobs live inside StimmePanel, not the main grid.
        let stimmeIds: Set<String> = ["stmOn", "stmPitch", "stmMix", "stmFollow", "stmMode",
                                       "stmDrive", "stmTone", "stmAir", "stmShimmer", "stmReverb", "stmDist",
                                       "stmHP", "stmLP", "stmFilt",   // (were missing: three zero-frame knobs drew their labels over the footer logo)
                                       "fA", "fD", "fS", "fR",  // filter-env ADSR removed from view
                                       // Harmonizer + key/scale are driven from the KEYS bar (HARM · 3+5 · SUB · KEY · SCALE);
                                       // without this they became zero-frame knobs drawing over the footer.
                                       "harmOn", "harmMode", "harmSub", "harmKey", "harmScale",
                                       // STRETCH / WARP / FORMANT live in the STIMME top row.
                                       "stmStretch", "stmWarp", "stmFormant"]
        for node in tree.children {
            if let p = node as? AUParameter, !stimmeIds.contains(p.identifier) {
                let k = KnobView(frame: .zero); k.bind(parameter: p)
                switch p.identifier {
                case "cut":   k.displayFormatter = { v in v >= 1000 ? String(format: "%.1fk", v/1000) : String(format: "%.0fHz", v) }
                case "glide": k.displayFormatter = { String(format: "%.0fms", $0) }
                case "aA", "aD", "aR": k.displayFormatter = { String(format: "%.0fms", $0 * 1000) }
                case "aS":    k.displayFormatter = { String(format: "%.0f%%", $0 * 100) }
                case "gain":  k.displayFormatter = { String(format: "%+.1fdB", 20 * log10(max(0.001, $0))) }
                case "mode":  k.displayFormatter = { v in switch Int(v.rounded()) { case 0: return "POLY"; case 1: return "MONO"; default: return "LEGATO" } }
                default: break
                }
                addSubview(k); knobsById[p.identifier] = k
            }
        }
        // Force knobs to top, then panel
        for k in knobsById.values { k.removeFromSuperview(); addSubview(k) }
        stimmePanel.audioUnit = au
        stimmePanel.removeFromSuperview(); addSubview(stimmePanel)
        keysPanel.audioUnit = au
        keysPanel.removeFromSuperview(); addSubview(keysPanel)
        needsLayout = true; needsDisplay = true
    }
}

// MARK: - StimmePanel: drag/drop file area, waveform preview, knobs

final class StimmePanel: NSView {
    weak var audioUnit: BMSAudioUnit? { didSet { rebindStimmeKnobs() } }

    private let inkDark = Palette.inkLight
    private let inkMid  = Palette.inkMidL
    private let red     = Palette.red
    private let panel   = Palette.panelDark

    private var hovering = false { didSet { needsDisplay = true } }
    private var timer: Timer?
    private var knobs: [String: KnobView] = [:]
    // Drop acceptance. The old hand-written nine-extension list rejected
    // plenty of things AVAudioFile can actually open (mp4, aifc, w64, opus,
    // caf variants, anything the system has a codec for), so this asks the
    // type system instead: anything that conforms to .audio or carries an
    // audio track (.audiovisualContent) is fair game, with the extension list
    // kept only as a fallback for files that arrive without a usable type.
    private static let exts: Set<String> = [
        "mp3", "m4a", "m4b", "m4r", "mp4", "aac", "adts",
        "wav", "wave", "bwf", "rf64", "w64",
        "aif", "aiff", "aifc", "caf", "snd", "au",
        "ogg", "oga", "opus", "flac",
        "mp2", "ac3", "amr", "3gp", "3gpp", "sd2", "voc", "mov"
    ]
    static func isAudioURL(_ url: URL) -> Bool {
        if let t = UTType(filenameExtension: url.pathExtension.lowercased()),
           t.conforms(to: .audio) || t.conforms(to: .audiovisualContent) { return true }
        return exts.contains(url.pathExtension.lowercased())
    }

    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        registerForDraggedTypes([.fileURL])
        timer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.needsDisplay = true
            // STRETCH / WARP value lines depend on the host tempo and on each
            // other, not only on their own parameter — refresh them too.
            self.knobs["stmStretch"]?.needsDisplay = true
            self.knobs["stmWarp"]?.needsDisplay = true
        }
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    deinit { timer?.invalidate() }

    private func rebindStimmeKnobs() {
        knobs.values.forEach { $0.removeFromSuperview() }; knobs.removeAll()
        guard let au = audioUnit, let tree = au.parameterTree else { return }
        // Replaced the old envelope-style controls (start/len/rel — "they all
        // do the same") with real vocal FX that shape the voice underneath
        // the bass. PITCH leads, then MIX, then the FX cluster.
        let ids = ["stmPitch", "stmMix", "stmFollow", "stmMode", "stmFilt",
                   "stmStretch", "stmWarp", "stmFormant",
                   "stmHP", "stmLP",
                   "stmDrive", "stmTone", "stmAir", "stmShimmer", "stmReverb", "stmDist"]
        for id in ids {
            // Resolve by identifier. (The old `withAddress: addressFor(id) ?? 0`
            // fell back to address 0 — the OSC-OCT param — for every stimme id,
            // so all 8 knobs bound to the same param and showed "OSC OCT".)
            if let p = tree.allParameters.first(where: { $0.identifier == id }) {
                let k = KnobView(frame: .zero); k.bind(parameter: p)
                switch id {
                case "stmPitch":   k.displayFormatter = { String(format: "%+.0f st", $0) }
                case "stmMix":     k.displayFormatter = { String(format: "%.0f%%", $0 * 100) }
                case "stmFollow":  k.displayFormatter = { $0 >= 0.5 ? "FOLLOW" : "FIXED" }
                case "stmMode":    k.displayFormatter = { v in switch Int(v.rounded()) { case 0: return "ONE-SHOT"; case 1: return "LOOP"; default: return "HOLD" } }
                case "stmDrive":   k.displayFormatter = { String(format: "%.0f%%", $0 * 100) }
                case "stmTone":    k.displayFormatter = { v in v < 0.45 ? "DARK" : (v > 0.55 ? "BRIGHT" : "FLAT") }
                case "stmAir":     k.displayFormatter = { String(format: "%.0f%%", $0 * 100) }
                case "stmShimmer": k.displayFormatter = { String(format: "%.0f%%", $0 * 100) }
                case "stmReverb":  k.displayFormatter = { String(format: "%.0f%%", $0 * 100) }
                case "stmDist":    k.displayFormatter = { String(format: "%.0f%%", $0 * 100) }
                // Filter readouts show the actual corner frequency, not a
                // percentage — the same mapping the DSP uses.
                case "stmHP":      k.displayFormatter = { v in
                                        let hz = 20.0 * pow(100.0, Double(v))
                                        return hz < 1000 ? String(format: "%.0f Hz", hz) : String(format: "%.2f kHz", hz / 1000) }
                case "stmLP":      k.displayFormatter = { v in
                                        let hz = 200.0 * pow(90.0, Double(v))
                                        return hz < 1000 ? String(format: "%.0f Hz", hz) : String(format: "%.1f kHz", hz / 1000) }
                case "stmFilt":    k.displayFormatter = { $0 >= 0.5 ? "ON" : "BYPASS" }
                // STRETCH: log taper 0.25x..4x (1.00x dead centre). In a SYNC
                // warp mode the knob is overruled by the tempo — the value line
                // shows the factor actually applied.
                case "stmStretch":
                    k.isLogarithmic = true
                    k.displayFormatter = { [weak self] v in
                        guard let au = self?.audioUnit else { return String(format: "%.2f×", v) }
                        if self?.warpMode() ?? 0 >= 2 { return String(format: "%.2f×", au.stimmeStretchFactor) }
                        return String(format: "%.2f×", v)
                    }
                case "stmWarp":
                    k.displayFormatter = { [weak self] v in
                        let m = Int(v.rounded())
                        // STRETCH away from 1.00x engages the warp engine even
                        // with WARP OFF — show that it is running FREE.
                        if m == 0 { return (self?.audioUnit?.stimmeWarpEngaged ?? false) ? "FREE" : "OFF" }
                        return StimmePanel.warpNames[max(0, min(StimmePanel.warpNames.count - 1, m))]
                    }
                case "stmFormant": k.displayFormatter = { $0 >= 0.5 ? "KEEP" : "OFF" }
                default: break
                }
                addSubview(k); knobs[id] = k
            }
        }
        needsLayout = true
    }
    private func addressFor(_ id: String) -> AUParameterAddress? { nil }

    // WARP value names (AU param 40): OFF · FREE · SYNC lengths.
    static let warpNames = ["OFF", "FREE", "1/4 BT", "1/2 BT", "1 BEAT", "2 BEAT", "1 BAR", "2 BAR", "4 BAR"]
    private func warpMode() -> Int {
        Int((audioUnit?.parameterTree?.parameter(withAddress: 40)?.value ?? 0).rounded())
    }
    /// One-line description of the warp state for the waveform header.
    private func warpSummary(_ au: BMSAudioUnit) -> String? {
        guard au.stimmeWarpEngaged else { return nil }
        let m = warpMode()
        if m >= 2 { return String(format: "WARP %@ @ %.0f BPM", StimmePanel.warpNames[min(m, StimmePanel.warpNames.count - 1)], au.hostBPM) }
        return "WARP FREE"
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 8
        // Left third: waveform of the loaded sample. Middle third: live
        // bass+voice visualizer. Right side: the 8 stimme knobs (2 rows of 4).
        let topRow = ["stmPitch", "stmMix", "stmFollow", "stmMode", "stmFilt", "stmStretch", "stmWarp", "stmFormant"]
        let botRow = ["stmHP", "stmLP", "stmDrive", "stmTone", "stmAir", "stmShimmer", "stmReverb", "stmDist"]
        let maxCols = CGFloat(max(topRow.count, botRow.count))
        // Eight across needs slimmer knobs than six did, or the block runs
        // into the waveform display on the left.
        let kW: CGFloat = maxCols > 6 ? 52 : 60
        let kH: CGFloat = 78, sp: CGFloat = 6
        let kBlockW = maxCols * kW + (maxCols - 1) * sp
        let kBlockH = kH * 2 + 4
        let kX = bounds.width - pad - kBlockW
        let kY = (bounds.height - kBlockH) * 0.5
        func place(_ row: [String], _ rowY: CGFloat) {
            for (i, id) in row.enumerated() {
                let x = kX + CGFloat(i) * (kW + sp)
                if let k = knobs[id] { k.frame = NSRect(x: x, y: rowY, width: kW, height: kH) }
            }
        }
        place(topRow, kY + kH + 4)
        place(botRow, kY)
    }

    override func draw(_ r: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let outer = bounds.insetBy(dx: 2, dy: 2)
        ctx.setFillColor(panel.cgColor); ctx.fill(outer)
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.6).cgColor); ctx.setLineWidth(0.5); ctx.stroke(outer)

        // Title
        let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: inkDark, .kern: 1.2]
        NSString(string: "STIMME").draw(at: NSPoint(x: outer.minX + 8, y: outer.maxY - 14), withAttributes: title)
        ctx.setFillColor(red.cgColor); ctx.fill(NSRect(x: outer.minX + 56, y: outer.maxY - 10, width: 6, height: 6))

        // ── Layout: split the left half into a top waveform strip (loaded
        // sample) and a bottom MIX scope (live bass + voice). Right half is
        // knobs (handled in layout()).
        let pad: CGFloat = 8
        // Left block sits under the knobs area; spans from pad to ~58% of width.
        let leftW: CGFloat = bounds.width * 0.45
        let leftX = pad
        let topGap: CGFloat = 14
        let botPad: CGFloat = 14
        let region = NSRect(x: leftX, y: pad, width: leftW, height: outer.height - pad - topGap - botPad)
        let waveRect = NSRect(x: region.minX, y: region.midY + 2, width: region.width, height: region.height * 0.5 - 2)
        let scopeRect = NSRect(x: region.minX, y: region.minY, width: region.width, height: region.height * 0.5 - 2)

        // ── Sample waveform (top) ───────────────────────────────────────
        ctx.setFillColor(NSColor(calibratedWhite: 0.10, alpha: 1.0).cgColor); ctx.fill(waveRect)
        if hovering {
            ctx.setFillColor(red.withAlphaComponent(0.12).cgColor); ctx.fill(waveRect)
            ctx.setStrokeColor(red.cgColor); ctx.setLineWidth(2)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.stroke(waveRect)
            ctx.setLineDash(phase: 0, lengths: [])
        } else {
            ctx.setStrokeColor(inkDark.withAlphaComponent(0.6).cgColor); ctx.setLineWidth(0.5); ctx.stroke(waveRect)
        }
        if let au = audioUnit, let data = au.stimmeSampleData(), au.stimmeSampleLength > 1 {
            let len = Int(au.stimmeSampleLength)
            let srcSR = au.stimmeSampleRate > 0 ? au.stimmeSampleRate : 48000.0
            // STRETCH / WARP: the strip spans max(original, stretched) length.
            // The red waveform is drawn at its stretched length; the original
            // length stays as a faint ghost + tick so the change is readable.
            let s = CGFloat(au.stimmeWarpEngaged ? max(0.125, min(8.0, au.stimmeStretchFactor)) : 1.0)
            let span = max(1.0, s)
            let redW = waveRect.width * s / span          // stretched waveform width
            let origW = waveRect.width / span             // original length on the same time axis
            let cy = waveRect.midY
            func strip(width w: CGFloat) {
                let nLines = max(2, Int(w))
                let win = max(1, len / nLines)
                for i in 0..<nLines {
                    let t = Double(i) / Double(nLines - 1)
                    let idx = Int(t * Double(len - 1))
                    var lo: Float = 0, hi: Float = 0
                    for j in 0..<win {
                        let v = data[min(len - 1, idx + j)]
                        if v < lo { lo = v }
                        if v > hi { hi = v }
                    }
                    let x = waveRect.minX + CGFloat(i) * w / CGFloat(nLines)
                    ctx.move(to: NSPoint(x: x, y: cy + CGFloat(lo) * waveRect.height * 0.45))
                    ctx.addLine(to: NSPoint(x: x, y: cy + CGFloat(hi) * waveRect.height * 0.45))
                }
                ctx.strokePath()
            }
            if abs(s - 1) > 0.005 {
                ctx.setStrokeColor(inkMid.withAlphaComponent(0.30).cgColor); ctx.setLineWidth(1.0)
                strip(width: origW)
            }
            ctx.setStrokeColor(red.cgColor); ctx.setLineWidth(1.0)
            strip(width: redW)
            if abs(s - 1) > 0.005 {
                // Tick where the original sample would have ended.
                let ox = waveRect.minX + origW
                ctx.setStrokeColor(inkMid.withAlphaComponent(0.7).cgColor); ctx.setLineWidth(0.7)
                ctx.setLineDash(phase: 0, lengths: [2, 2])
                ctx.move(to: NSPoint(x: ox, y: waveRect.minY + 2)); ctx.addLine(to: NSPoint(x: ox, y: waveRect.maxY - 2)); ctx.strokePath()
                ctx.setLineDash(phase: 0, lengths: [])
            }
            let ph = CGFloat(au.stimmePlayhead)
            let phx = waveRect.minX + redW * max(0, min(1, ph))
            ctx.setStrokeColor(inkDark.cgColor); ctx.setLineWidth(0.7)
            ctx.move(to: NSPoint(x: phx, y: waveRect.minY)); ctx.addLine(to: NSPoint(x: phx, y: waveRect.maxY)); ctx.strokePath()

            let dur = Double(len) / srcSR
            let info: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular), .foregroundColor: inkDark]
            var line = String(format: "%@ · %.2fs", au.stimmeSampleName, dur)
            if let w = warpSummary(au) {
                // Playback starts at the onset, so the part that is stretched
                // (and locked to the bar in SYNC) is onset → end.
                let played = Double(max(1, len - Int(au.stimmeSampleOnset))) / srcSR
                line += String(format: " · plays %.2fs → %.2fs · %@", played, played * Double(s), w)
            }
            NSString(string: line).draw(at: NSPoint(x: waveRect.minX + 4, y: waveRect.maxY + 2), withAttributes: info)
        } else {
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular), .foregroundColor: inkMid]
            let s = NSString(string: hovering ? "DROP TO LOAD" : "— EMPTY · DROP AUDIO FILE HERE —")
            let sz = s.size(withAttributes: a)
            s.draw(at: NSPoint(x: waveRect.midX - sz.width * 0.5, y: waveRect.midY - 5), withAttributes: a)
        }

        // ── MIX scope — live bass + voice intertwined ───────────────────
        // The bass envelope is drawn from the centerline upward (red); the
        // vocal envelope is drawn from the centerline downward (cream/dark
        // ink). Watching the two streams cross is the point of this view —
        // it makes it obvious how the layers are "mashed together."
        ctx.setFillColor(NSColor(calibratedWhite: 0.10, alpha: 1).cgColor); ctx.fill(scopeRect)
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.6).cgColor); ctx.setLineWidth(0.5); ctx.stroke(scopeRect)

        // Centerline
        ctx.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.18).cgColor); ctx.setLineWidth(0.5)
        ctx.move(to: NSPoint(x: scopeRect.minX, y: scopeRect.midY))
        ctx.addLine(to: NSPoint(x: scopeRect.maxX, y: scopeRect.midY))
        ctx.strokePath()

        if let au = audioUnit {
            let want = min(Int(scopeRect.width), Int(au.probeSize))
            if want > 4 {
                var bass = [Float](repeating: 0, count: want)
                var vox  = [Float](repeating: 0, count: want)
                let got = bass.withUnsafeMutableBufferPointer { bp -> Int in
                    vox.withUnsafeMutableBufferPointer { vp in
                        Int(au.readProbeBass(bp.baseAddress!, vox: vp.baseAddress!, count: want))
                    }
                }
                if got > 1 {
                    let halfH = scopeRect.height * 0.45
                    let scale: CGFloat = 1.6
                    // Bass — red, upper half (filled area for body)
                    let bp = CGMutablePath()
                    bp.move(to: NSPoint(x: scopeRect.minX, y: scopeRect.midY))
                    for i in 0..<got {
                        let x = scopeRect.minX + CGFloat(i) / CGFloat(max(1, got - 1)) * scopeRect.width
                        let y = scopeRect.midY + max(0, CGFloat(bass[i]) * halfH * scale)
                        bp.addLine(to: NSPoint(x: x, y: y))
                    }
                    bp.addLine(to: NSPoint(x: scopeRect.maxX, y: scopeRect.midY))
                    bp.closeSubpath()
                    ctx.addPath(bp); ctx.setFillColor(red.withAlphaComponent(0.85).cgColor); ctx.fillPath()

                    // Voice — cream, lower half mirrored
                    let vp = CGMutablePath()
                    vp.move(to: NSPoint(x: scopeRect.minX, y: scopeRect.midY))
                    let cream = Palette.cream
                    for i in 0..<got {
                        let x = scopeRect.minX + CGFloat(i) / CGFloat(max(1, got - 1)) * scopeRect.width
                        let y = scopeRect.midY - max(0, CGFloat(abs(vox[i])) * halfH * scale)
                        vp.addLine(to: NSPoint(x: x, y: y))
                    }
                    vp.addLine(to: NSPoint(x: scopeRect.maxX, y: scopeRect.midY))
                    vp.closeSubpath()
                    ctx.addPath(vp); ctx.setFillColor(cream.withAlphaComponent(0.85).cgColor); ctx.fillPath()

                    // Outline pass — sharp edge so the layers read as
                    // distinct waveforms rather than blobs.
                    ctx.setLineWidth(0.8)
                    ctx.setStrokeColor(red.cgColor)
                    for i in 0..<got {
                        let x = scopeRect.minX + CGFloat(i) / CGFloat(max(1, got - 1)) * scopeRect.width
                        let y = scopeRect.midY + max(0, CGFloat(bass[i]) * halfH * scale)
                        if i == 0 { ctx.move(to: NSPoint(x: x, y: y)) }
                        else { ctx.addLine(to: NSPoint(x: x, y: y)) }
                    }
                    ctx.strokePath()
                    ctx.setStrokeColor(cream.cgColor)
                    for i in 0..<got {
                        let x = scopeRect.minX + CGFloat(i) / CGFloat(max(1, got - 1)) * scopeRect.width
                        let y = scopeRect.midY - max(0, CGFloat(abs(vox[i])) * halfH * scale)
                        if i == 0 { ctx.move(to: NSPoint(x: x, y: y)) }
                        else { ctx.addLine(to: NSPoint(x: x, y: y)) }
                    }
                    ctx.strokePath()
                }
            }
        }

        // Scope label
        let scopeLabel: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .heavy), .foregroundColor: NSColor.white.withAlphaComponent(0.55), .kern: 0.8]
        NSString(string: "BASS ▲  VOICE ▼  ·  LIVE MIX").draw(at: NSPoint(x: scopeRect.minX + 4, y: scopeRect.maxY - 11), withAttributes: scopeLabel)   // top-left, clear of the drop hint

        // Hint bottom
        let hint: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .regular), .foregroundColor: inkMid, .kern: 0.4]
        NSString(string: "Drop any audio here  ·  Voice fx: filters / drive / tone / air / shimmer →").draw(at: NSPoint(x: outer.minX + 8, y: outer.minY + 2), withAttributes: hint)
    }

    // MARK: - Drag & Drop

    private func acceptableURL(from sender: NSDraggingInfo) -> URL? {
        let pb = sender.draggingPasteboard
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL],
              let url = urls.first else { return nil }
        return StimmePanel.isAudioURL(url) ? url : nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if acceptableURL(from: sender) != nil { hovering = true; return .copy }
        return []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { hovering = false }
    override func draggingEnded(_ sender: NSDraggingInfo) { hovering = false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = acceptableURL(from: sender), let au = audioUnit else { hovering = false; return false }
        hovering = false
        loadAudio(at: url, into: au)
        return true
    }

    private func loadAudio(at url: URL, into au: BMSAudioUnit) {
        let _ = url.startAccessingSecurityScopedResource()
        defer { url.stopAccessingSecurityScopedResource() }
        guard let file = try? AVAudioFile(forReading: url) else { return }
        let srcFmt = file.processingFormat
        let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: AVAudioFrameCount(file.length))
        guard let srcBuf, (try? file.read(into: srcBuf)) != nil else { return }
        guard let dstFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: srcFmt.sampleRate, channels: 1, interleaved: false) else { return }
        guard let cv = AVAudioConverter(from: srcFmt, to: dstFmt) else { return }
        guard let dst = AVAudioPCMBuffer(pcmFormat: dstFmt, frameCapacity: srcBuf.frameLength) else { return }
        var done = false
        let _ = cv.convert(to: dst, error: nil) { _, status in
            if done { status.pointee = .noDataNow; return nil }
            done = true; status.pointee = .haveData; return srcBuf
        }
        guard let p = dst.floatChannelData?[0] else { return }
        au.setStimmeSampleData(p, length: Int(dst.frameLength), sampleRate: srcFmt.sampleRate, name: url.lastPathComponent)
        needsDisplay = true
    }
}

// MARK: - KeysPanel: compact playable keyboard that drives the vocal pitch
//
// SynthThing's "keys" is a full 8-row × 16-step melodic grid. This is a slim,
// roughly-half-footprint take on it: a 2-octave (C2–C4) playable keyboard.
// Clicking a key plays a note straight into the engine (au.playNote) — and the
// Stimme vocal underlay FOLLOWs that pitch (Engine note-follow tunes MIDI 36 =
// original), so you're literally playing a melody onto the voice. RANDOM ✦
// mirrors the synth's randomizer: it rolls a random in-scale melody and loops
// it through the very same note path.

final class KeysPanel: NSView {
    weak var audioUnit: BMSAudioUnit? { didSet { loadHarmonizerState() } }

    // ── HARMONIZER (engine params 34-38) — KEY/SCALE live in the engine so the
    // harmony follows them for MIDI input too, and they persist with the song.
    private let kHarmOn: AUParameterAddress = 34, kHarmMode: AUParameterAddress = 35
    private let kHarmSub: AUParameterAddress = 36, kHarmKey: AUParameterAddress = 37
    private let kHarmScale: AUParameterAddress = 38
    private let harmModeNames = ["3+5", "3RD", "5TH", "3+5+8"]
    private var harmRect: NSRect = .zero, harmModeRect: NSRect = .zero, harmSubRect: NSRect = .zero
    private func param(_ a: AUParameterAddress) -> AUParameter? { audioUnit?.parameterTree?.parameter(withAddress: a) }
    private func pval(_ a: AUParameterAddress) -> Int { Int((param(a)?.value ?? 0).rounded()) }
    private func setP(_ a: AUParameterAddress, _ v: Int) { param(a)?.setValue(AUValue(v), originator: nil) }
    /// Push KEY / SCALE into the engine (the harmonizer's key).
    private func syncHarmKeyScale() { setP(kHarmKey, rootOffset); setP(kHarmScale, scaleIdx) }
    /// Restore KEY / SCALE from the saved engine state.
    private func loadHarmonizerState() {
        guard audioUnit != nil else { return }
        if let i = rootOffsets.firstIndex(of: pval(kHarmKey)) { rootIdx = i }
        scaleIdx = max(0, min(scales.count - 1, pval(kHarmScale)))
        needsDisplay = true
    }

    private let inkDark = Palette.inkLight
    private let inkMid  = Palette.inkMidL
    private let red     = Palette.red
    private let panel   = Palette.panelDark
    private let cream   = Palette.cream

    // C2 (MIDI 36): with Stimme FOLLOW on, the root key plays the sample near
    // its original pitch (Engine tunes MIDI 36 = original).
    private let baseMidi = 36
    private let octaves  = 2
    private var topMidi: Int { baseMidi + octaves * 12 }   // inclusive top C

    // ── Generative controls (click the header segments to cycle) ──
    private let scales: [(name: String, pcs: [Int])] = [
        ("PENTA",  [0, 2, 4, 7, 9]),
        ("MAJOR",  [0, 2, 4, 5, 7, 9, 11]),
        ("MINOR",  [0, 2, 3, 5, 7, 8, 10]),
        ("DORIAN", [0, 2, 3, 5, 7, 9, 10]),
        ("CHROM",  [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]),
    ]
    private var scaleIdx = 0
    private var scalePCs: [Int] { scales[scaleIdx].pcs }
    // Step length in beats (1/4 = 1 beat … 1/16T).
    private let rates: [(name: String, beats: Double)] = [
        ("1/4", 1.0), ("1/8", 0.5), ("1/8T", 1.0 / 3.0), ("1/16", 0.25), ("1/16T", 1.0 / 6.0)
    ]
    private var rateIdx = 1
    private let stepCounts = [8, 16, 32, 64]
    private var stepsIdx = 2          // 32 steps = a 2-bar phrase at 1/8
    private let gates: [Double] = [0.4, 0.55, 0.7, 0.85, 1.0]
    private var gateIdx = 2
    // Root note for the generator (H = German B). The scale is built on this.
    private let rootNames   = ["C", "D", "E", "F", "G", "A", "H"]
    private let rootOffsets = [0, 2, 4, 5, 7, 9, 11]
    private var rootIdx = 0
    private var rootOffset: Int { rootOffsets[rootIdx] }

    // Generated melody: one entry per step, a MIDI note or -1 for a rest.
    private var melody: [Int] = []
    private var lastPlayed = -1
    private var playing = false           // sequencer armed
    private var stepTimer: Timer?

    // Host-synced stepping state.
    private var lastFiredStep = -1
    private var noteOnBeat = 0.0
    private var freeBeat = 0.0            // fallback clock when the host isn't moving

    // Lit key for the highlight — set by a manual press or the sequencer.
    private var activeMidi = -1
    private var manualMidi = -1

    // Header hit-rects.
    private var randomRect: NSRect = .zero
    private var mutateRect: NSRect = .zero
    private var stopRect:   NSRect = .zero
    private var rootRect:   NSRect = .zero
    private var rateRect:   NSRect = .zero
    private var scaleRect:  NSRect = .zero
    private var stepsRect:  NSRect = .zero
    private var gateRect:   NSRect = .zero
    private var resetRect:  NSRect = .zero

    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    deinit {
        stepTimer?.invalidate()
        // The sequencer lives in the AU's render block now — closing the
        // plug-in window must not stop the melody.
    }

    // MARK: Geometry

    private func isWhite(_ midi: Int) -> Bool {
        let pc = ((midi % 12) + 12) % 12
        return pc == 0 || pc == 2 || pc == 4 || pc == 5 || pc == 7 || pc == 9 || pc == 11
    }

    private func keyboardRect() -> NSRect {
        let o = bounds.insetBy(dx: 2, dy: 2)
        return NSRect(x: o.minX + 8, y: o.minY + 8, width: o.width - 16, height: o.height - 30)
    }

    private func whiteKeys() -> [(midi: Int, rect: NSRect)] {
        let kb = keyboardRect()
        let whites = (baseMidi...topMidi).filter { isWhite($0) }
        let n = max(1, whites.count)
        let ww = kb.width / CGFloat(n)
        var out: [(midi: Int, rect: NSRect)] = []
        for (i, m) in whites.enumerated() {
            out.append((midi: m, rect: NSRect(x: kb.minX + CGFloat(i) * ww, y: kb.minY, width: ww - 1, height: kb.height)))
        }
        return out
    }

    private func blackKeys() -> [(midi: Int, rect: NSRect)] {
        let kb = keyboardRect()
        let whites = whiteKeys()
        let ww = (whites.first?.rect.width ?? kb.width) + 1
        let bw = ww * 0.62
        var out: [(midi: Int, rect: NSRect)] = []
        var wi = -1
        for m in baseMidi...topMidi {
            if isWhite(m) { wi += 1; continue }
            let centerX = kb.minX + CGFloat(wi + 1) * ww
            out.append((midi: m, rect: NSRect(x: centerX - bw * 0.5, y: kb.minY + kb.height * 0.40,
                                              width: bw, height: kb.height * 0.60)))
        }
        return out
    }

    private func midiAt(_ p: NSPoint) -> Int? {
        for k in blackKeys() where k.rect.contains(p) { return k.midi }   // on top
        for k in whiteKeys() where k.rect.contains(p) { return k.midi }
        return nil
    }

    // MARK: Drawing

    private let kNoteNames = ["C","C♯","D","D♯","E","F","F♯","G","G♯","A","A♯","B"]
    private func noteName(_ midi: Int) -> String {
        "\(kNoteNames[((midi % 12) + 12) % 12])\(midi / 12 - 1)"
    }

    override func draw(_ r: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let outer = bounds.insetBy(dx: 2, dy: 2)
        ctx.setFillColor(panel.cgColor); ctx.fill(outer)
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.6).cgColor); ctx.setLineWidth(0.5); ctx.stroke(outer)

        // Title + red dot + subtitle.
        let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: inkDark, .kern: 1.2]
        NSString(string: "KEYS").draw(at: NSPoint(x: outer.minX + 8, y: outer.maxY - 14), withAttributes: title)
        ctx.setFillColor(red.cgColor); ctx.fill(NSRect(x: outer.minX + 42, y: outer.maxY - 10, width: 6, height: 6))
        let sub: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .regular), .foregroundColor: inkMid, .kern: 0.5]
        NSString(string: "MELODY → VOICE").draw(at: NSPoint(x: outer.minX + 58, y: outer.maxY - 13), withAttributes: sub)

        // ── Right-aligned buttons: PLAY/STOP · MUTATE · RANDOM ──
        let rh: CGFloat = 18, by = outer.maxY - rh - 3
        let rw: CGFloat = 86
        randomRect = NSRect(x: outer.maxX - rw - 8, y: by, width: rw, height: rh)
        drawHdrButton(ctx, randomRect, "RANDOM ✦", filled: false)
        let mw: CGFloat = 62
        mutateRect = NSRect(x: randomRect.minX - mw - 6, y: by, width: mw, height: rh)
        drawHdrButton(ctx, mutateRect, "MUTATE", filled: false)
        let sw: CGFloat = 52
        stopRect = NSRect(x: mutateRect.minX - sw - 6, y: by, width: sw, height: rh)
        drawHdrButton(ctx, stopRect, playing ? "STOP ■" : "PLAY ▶", filled: playing)
        // RESET — wipes the generated melody and puts KEY / RATE / SCALE / LEN /
        // GATE back to their defaults.
        let xw: CGFloat = 54
        resetRect = NSRect(x: stopRect.minX - xw - 6, y: by, width: xw, height: rh)
        drawHdrButton(ctx, resetRect, "RESET", filled: false)

        // ── Generative control segments (click to cycle) ──
        let segY = outer.maxY - 13
        var sx = outer.minX + 150
        let sync = (audioUnit?.hostIsPlaying ?? false) && playing
        rootRect  = drawHdrSeg(ctx, &sx, segY, "KEY",   rootNames[rootIdx])
        scaleRect = drawHdrSeg(ctx, &sx, segY, "SCALE", scales[scaleIdx].name)
        // HARMONIZER — rubber key (red = on), interval set, sub-octave key.
        let harmOn = pval(kHarmOn) != 0, harmSub = pval(kHarmSub) != 0
        harmRect = NSRect(x: sx - 3, y: segY - 4, width: 40, height: 17)
        drawHdrKey(ctx, harmRect, "HARM", on: harmOn)
        sx = harmRect.maxX + 5
        harmModeRect = NSRect(x: sx - 2, y: segY - 4, width: 38, height: 17)
        let mAttr: [NSAttributedString.Key: Any] = [.font: Palette.printFont(9.5),
            .foregroundColor: harmOn ? red : inkMid, .kern: 0.3]
        let ms = NSString(string: harmModeNames[max(0, min(3, pval(kHarmMode)))]); let mz = ms.size(withAttributes: mAttr)
        ms.draw(at: NSPoint(x: harmModeRect.midX - mz.width * 0.5, y: segY - 1), withAttributes: mAttr)
        sx = harmModeRect.maxX + 3
        harmSubRect = NSRect(x: sx, y: segY - 4, width: 30, height: 17)
        drawHdrKey(ctx, harmSubRect, "SUB", on: harmSub && harmOn)
        sx = harmSubRect.maxX + 13
        rateRect  = drawHdrSeg(ctx, &sx, segY, "RATE",  rates[rateIdx].name)
        stepsRect = drawHdrSeg(ctx, &sx, segY, "LEN",   "\(stepCounts[stepsIdx])")
        gateRect  = drawHdrSeg(ctx, &sx, segY, "GATE",  "\(Int(gates[gateIdx] * 100))")
        // SYNC indicator — lit when locked to the host bar grid.
        let syncAttr: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .heavy),
            .foregroundColor: sync ? red : inkMid.withAlphaComponent(0.6), .kern: 0.6]
        NSString(string: sync ? "● SYNC" : "○ FREE").draw(at: NSPoint(x: sx, y: segY - 1), withAttributes: syncAttr)

        // ── Keyboard ────────────────────────────────────────────────────
        for k in whiteKeys() {
            let lit = (k.midi == activeMidi)
            ctx.setFillColor((lit ? red : cream).cgColor); ctx.fill(k.rect)
            ctx.setStrokeColor(NSColor(calibratedWhite: 0.05, alpha: 1.0).cgColor); ctx.setLineWidth(0.5); ctx.stroke(k.rect)
            if (k.midi % 12) == 0 {
                let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .regular), .foregroundColor: lit ? cream : inkMid]
                NSString(string: noteName(k.midi)).draw(at: NSPoint(x: k.rect.minX + 2, y: k.rect.minY + 2), withAttributes: a)
            }
        }
        for k in blackKeys() {
            let lit = (k.midi == activeMidi)
            ctx.setFillColor((lit ? red : NSColor(calibratedWhite: 0.08, alpha: 1.0)).cgColor); ctx.fill(k.rect)
            ctx.setStrokeColor(NSColor(calibratedWhite: 0.02, alpha: 1.0).cgColor); ctx.setLineWidth(0.5); ctx.stroke(k.rect)
        }
    }

    private func drawHdrButton(_ ctx: CGContext, _ r: NSRect, _ label: String, filled: Bool) {
        if filled { ctx.setFillColor(red.cgColor); ctx.fill(r) }
        else { ctx.setStrokeColor(red.cgColor); ctx.setLineWidth(1.0); ctx.stroke(r) }
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 9, weight: .heavy),
            .foregroundColor: filled ? cream : red, .kern: 0.5]
        let s = NSString(string: label); let z = s.size(withAttributes: a)
        s.draw(at: NSPoint(x: r.midX - z.width * 0.5, y: r.midY - z.height * 0.5 - 1), withAttributes: a)
    }

    /// Small rubber key with a DIN label (analog scheme) — red when on.
    private func drawHdrKey(_ ctx: CGContext, _ r: NSRect, _ label: String, on: Bool) {
        if !ButtonTex.draw(ctx, rect: r, active: on) {
            ctx.setFillColor((on ? red : panel).cgColor); ctx.fill(r)
        }
        let a: [NSAttributedString.Key: Any] = [.font: Palette.printFont(8.5), .foregroundColor: cream, .kern: 0.4]
        let s = NSString(string: label); let z = s.size(withAttributes: a)
        s.draw(at: NSPoint(x: r.midX - z.width * 0.5, y: r.midY - z.height * 0.5), withAttributes: a)
    }

    /// Draw a "LABEL value" segment at `x`, advance `x`, and return its hit-rect.
    private func drawHdrSeg(_ ctx: CGContext, _ x: inout CGFloat, _ y: CGFloat, _ label: String, _ value: String) -> NSRect {
        let lAttr: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .regular), .foregroundColor: inkMid, .kern: 0.3]
        let vAttr: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 9, weight: .heavy), .foregroundColor: red, .kern: 0.3]
        let ls = NSString(string: label + " "); let lz = ls.size(withAttributes: lAttr)
        ls.draw(at: NSPoint(x: x, y: y - 1), withAttributes: lAttr)
        let vs = NSString(string: value); let vz = vs.size(withAttributes: vAttr)
        vs.draw(at: NSPoint(x: x + lz.width, y: y - 1), withAttributes: vAttr)
        let total = lz.width + vz.width
        let rect = NSRect(x: x - 3, y: y - 3, width: total + 6, height: 16)
        x += total + 13
        return rect
    }

    // MARK: Interaction

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // Generative control segments (cycle on click).
        if harmRect.contains(p)     { setP(kHarmOn, pval(kHarmOn) != 0 ? 0 : 1); syncHarmKeyScale(); needsDisplay = true; return }
        if harmModeRect.contains(p) { setP(kHarmMode, (pval(kHarmMode) + 1) % harmModeNames.count); needsDisplay = true; return }
        if harmSubRect.contains(p)  { setP(kHarmSub, pval(kHarmSub) != 0 ? 0 : 1); needsDisplay = true; return }
        if rootRect.contains(p)  { rootIdx  = (rootIdx + 1) % rootNames.count;   syncHarmKeyScale(); randomizeMelody(); needsDisplay = true; return }
        if rateRect.contains(p)  { rateIdx  = (rateIdx + 1) % rates.count;       pushMelody(); needsDisplay = true; return }
        if scaleRect.contains(p) { scaleIdx = (scaleIdx + 1) % scales.count;     syncHarmKeyScale(); needsDisplay = true; return }
        if stepsRect.contains(p) { stepsIdx = (stepsIdx + 1) % stepCounts.count; randomizeMelody(); needsDisplay = true; return }
        if gateRect.contains(p)  { gateIdx  = (gateIdx + 1) % gates.count;       pushMelody(); needsDisplay = true; return }
        if resetRect.contains(p) { resetAll(); needsDisplay = true; return }
        // Buttons.
        if randomRect.contains(p) { randomizeMelody(); armSequencer(); needsDisplay = true; return }
        if mutateRect.contains(p) { if melody.isEmpty { randomizeMelody() } else { mutateMelody() }; armSequencer(); needsDisplay = true; return }
        if stopRect.contains(p)   { if playing { stopSequencer() } else { armSequencer() }; needsDisplay = true; return }
        if let m = midiAt(p) {
            manualMidi = m
            audioUnit?.playNote(Int32(m), velocity: 0.9)
            activeMidi = m
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        if manualMidi >= 0 {
            audioUnit?.stopNote(Int32(manualMidi))
            if activeMidi == manualMidi && !playing { activeMidi = -1 }
            manualMidi = -1
            needsDisplay = true
        }
    }

    // MARK: Sequencer (UI-timer driven melody loop)

    // ── Bass-line writer ─────────────────────────────────────────────────
    // A sub-bass line is not a random walk over the scale: it outlines the
    // chord. So the generator first picks a chord progression (scale-degree
    // roots, one chord per bar = 8 steps at 1/8), then plays one groove
    // template per chord whose onsets have ROLES — root, fifth, octave,
    // third, a passing tone, and an APPROACH note that slides into the next
    // chord's root on the last onset of the bar. The same template repeats
    // across the phrase (that is what makes it a groove), and the final bar
    // gets a turnaround variation.

    private static let bassProgressions: [[Int]] = [
        [0, 0, 0, 0], [0, 5, 3, 4], [0, 3, 4, 4], [0, 4, 5, 3], [0, 3, 0, 4],
        [5, 3, 0, 4], [0, 0, 3, 4], [0, 6, 3, 4], [0, 2, 4, 3], [0, 5, 4, 3],
    ]
    /// 8-step bass templates. R root · 5 fifth · O octave · 3 third ·
    /// P passing tone toward the next root · A approach note (a step under
    /// the next root) · . rest.
    private static let bassTemplates: [String] = [
        "R.......",   // one long sub note per bar
        "R...R...",   // halves
        "R.....A.",   // root, approach into the next chord
        "R..R..A.",   // tresillo-ish push
        "R.R.5.O.",   // walking octave
        "R...5..A",   // root – fifth – approach
        "R.R.R.A.",   // driving
        "R..O..5.",   // octave pop
        "R.5.R.A.",   // bounce
        "RR..R.P.",   // double-hit, passing tone
        "R..R.O.A",   // syncopated, walks up
        "R.....P.",   // long note, one lead-in
    ]

    /// Roll a fresh chord-outlining bass line of the selected length.
    private func randomizeMelody() {
        let steps = stepCounts[stepsIdx]
        let pcs   = scalePCs                                   // relative to the root
        let scaleSet = Set(pcs)
        let n     = pcs.count
        let low   = baseMidi + rootOffset                       // the bass octave starts on the key
        // Chord roots in the bass octave [low, low+12).
        func rootMidi(_ degree: Int) -> Int {
            let d = ((degree % n) + n) % n
            var m = low + pcs[d]
            while m >= low + 12 { m -= 12 }
            return min(topMidi, max(baseMidi, m))
        }
        /// Nearest in-scale pitch class to `pc` (semitones above the key).
        func snapPC(_ pcIn: Int) -> Int {
            let x = ((pcIn % 12) + 12) % 12
            if scaleSet.contains(x) { return x }
            var best = pcs[0], bestD = 12
            for p in pcs { let d = min(abs(p - x), 12 - abs(p - x)); if d < bestD { bestD = d; best = p } }
            return best
        }
        /// A note `interval` semitones above the chord root, snapped into the
        /// scale, kept in the playable window.
        func above(_ root: Int, _ interval: Int) -> Int {
            let rel = ((root - low) % 12 + 12) % 12
            let target = snapPC(rel + interval)
            var m = root - rel + target
            if m < root { m += 12 }
            while m > topMidi { m -= 12 }
            return max(baseMidi, m)
        }

        let chordLen = steps >= 16 ? 8 : 4
        let bars     = max(1, steps / chordLen)
        let prog     = Self.bassProgressions.randomElement()!
        var roots: [Int] = []
        for b in 0..<bars { roots.append(rootMidi(prog[b % prog.count])) }

        var tpl  = Array(Self.bassTemplates.randomElement()!)
        let turn = Array(Self.bassTemplates.randomElement()!)     // turnaround for the last bar
        if chordLen == 4 { tpl = Array(tpl.prefix(4)) }
        let thirdInt = (n == 12 || scaleSet.contains(4)) && !scaleSet.contains(3) ? 4 : 3

        var m = [Int](repeating: -1, count: steps)
        for b in 0..<bars {
            let root = roots[b]
            let next = roots[(b + 1) % bars]
            let t = (b == bars - 1 && bars > 1 && Bool.random()) ? Array(turn.prefix(chordLen)) : tpl
            var last = root
            for i in 0..<min(chordLen, t.count) {
                let step = b * chordLen + i
                guard step < steps else { break }
                let note: Int
                switch t[i] {
                case "R": note = root
                case "5": note = above(root, 7)
                case "O": note = min(topMidi, root + 12)
                case "3": note = above(root, thirdInt)
                case "P":                                       // scale step walking toward the next root
                    note = next > last ? above(last, 2) : above(next, 2)
                case "A":                                       // chromatic approach from below (or above)
                    let a = [next - 1, next - 1, next + 1, next - 2].randomElement()!
                    note = min(topMidi, max(baseMidi, a))
                default: continue
                }
                m[step] = note; last = note
            }
        }
        // A rest somewhere in the phrase keeps it breathing (never on beat 1).
        if steps >= 16 && Int.random(in: 0..<3) == 0 {
            let i = Int.random(in: 1..<steps); if i % chordLen != 0 { m[i] = -1 }
        }
        if m.allSatisfy({ $0 < 0 }) { m[0] = low }
        melody = m
        lastFiredStep = -1
        pushMelody()
    }

    /// Hand the melody + timing to the AU's render-thread sequencer.
    private func pushMelody() {
        audioUnit?.setSequencerMelody(melody.map { NSNumber(value: $0) },
                                      stepBeats: rates[rateIdx].beats, gate: gates[gateIdx])
    }

    /// RESET ALL for the generator: stop, forget the melody, defaults back.
    private func resetAll() {
        stopSequencer()
        melody.removeAll()
        rootIdx = 0; rateIdx = 1; scaleIdx = 0; stepsIdx = 2; gateIdx = 2
        syncHarmKeyScale()
        pushMelody()
    }

    /// Vary the current melody — change about a third of its notes in-scale.
    private func mutateMelody() {
        guard !melody.isEmpty else { return }
        let pcs = scalePCs
        let n = max(1, melody.count / 3)
        for _ in 0..<n {
            let i = Int.random(in: 0..<melody.count)
            if Double.random(in: 0...1) < 0.15 { melody[i] = -1; continue }
            let oct = Int.random(in: 0..<max(1, octaves))
            let pc = pcs.randomElement() ?? 0
            var m = baseMidi + rootOffset + oct * 12 + pc
            while m > topMidi { m -= 12 }              // wrap into range (clamping parked notes on C4, out of key)
            melody[i] = m
        }
        if melody.allSatisfy({ $0 < 0 }) { melody[0] = baseMidi }
        pushMelody()
    }

    /// Arm the sequencer. The stepping itself happens inside the AU on the
    /// render thread (sample-accurate, locked to Logic's bar grid); this
    /// view only pushes the melody and polls the sounding note for the
    /// key highlight.
    private func armSequencer() {
        if melody.isEmpty { randomizeMelody() } else { pushMelody() }
        if playing { return }                 // already running — keep phase
        playing = true
        audioUnit?.sequencerArmed = true
        stepTimer?.invalidate()
        stepTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func stopSequencer() {
        playing = false
        stepTimer?.invalidate(); stepTimer = nil
        audioUnit?.sequencerArmed = false
        lastPlayed = -1
        activeMidi = (manualMidi >= 0) ? manualMidi : -1
        needsDisplay = true
    }

    /// Display poll: mirror the AU's sounding note onto the keyboard.
    private func tick() {
        guard playing, let au = audioUnit else { return }
        let note = Int(au.sequencerNote)
        let shown = note >= 0 ? note : ((manualMidi >= 0) ? manualMidi : -1)
        if shown != activeMidi { activeMidi = shown; needsDisplay = true }
    }
}
