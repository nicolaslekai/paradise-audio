//
//  PadView.swift — single sample pad.
//  • Click            → trigger (audition)
//  • Shift-click      → open file picker for this pad
//  • Option-click     → clear this pad
//  • Drag & drop      → drop an audio file directly onto the pad to load it
//  • Right-click      → context menu (Load…, Clear, Reveal, Recent Files)
//
//  Internal layout (stacked, non-overlapping — clearly labelled):
//      ┌───────────────────────────────────────────────┐
//      │ ●01                                 [ GATE ]   │  header: number + key-trig
//      │                                                │
//      │                 ∿ waveform ∿                   │  loaded sample glyph
//      │                                                │
//      │                  my-loop.wav                   │  sample name
//      │  PITCH +3st          CHOP REV         ROOT C1  │  control captions + values
//      │  [▮▮▮▮ pitch bar ]   [ chop segs   ]           │  control bars
//      └───────────────────────────────────────────────┘
//

import AppKit
import UniformTypeIdentifiers

protocol PadViewDelegate: AnyObject {
    func pad(_ pad: PadView, didTriggerAt index: Int)
    func pad(_ pad: PadView, didRequestLoadAt index: Int)
    func pad(_ pad: PadView, didRequestClearAt index: Int)
    func pad(_ pad: PadView, didDropFileAt index: Int, url: URL)
    func pad(_ pad: PadView, didRequestRecentAt index: Int) -> [URL]
    func pad(_ pad: PadView, didPickRecentURL url: URL, at index: Int)
    func pad(_ pad: PadView, didRequestRevealAt index: Int)

    // Per-pad pitch (-12..+12 st) and chop knob (0..1 selects 1 of 4 algos)
    func padPitch(for index: Int) -> Float
    func padSetPitch(_ semi: Float, for index: Int)
    func padChop(for index: Int) -> Float
    func padSetChop(_ knob: Float, for index: Int)
    func padRootNote(for index: Int) -> Int

    // KEY TRIGGER (per pad). When true, the pad's sample only plays while the
    // key is held (gate mode). When false (default), it's one-shot.
    func padKeyTrigger(for index: Int) -> Bool
    func padSetKeyTrigger(_ on: Bool, for index: Int)
}

final class PadView: NSView {
    let index: Int
    weak var delegate: PadViewDelegate?

    var sampleName: String = "— EMPTY —" { didSet { needsDisplay = true } }
    var isSelected: Bool = false { didSet { needsDisplay = true } }
    var isLoaded: Bool = false { didSet { needsDisplay = true } }
    private var isDragHovering: Bool = false { didSet { needsDisplay = true } }

    private let inkDark = Palette.inkLight
    private let inkMid  = Palette.inkMidL
    private let red     = Palette.red
    private let panel   = Palette.panelDark
    private let barBg   = NSColor(calibratedWhite: 0.10, alpha: 1.0)

    private let chopLabels = ["FWD", "REV", "STUT", "HALF"]

    // Fallback extension allowlist (used when the system can't resolve a
    // UTType for the file). The primary gate is "does it conform to .audio",
    // so this just covers odd/uncommon extensions.
    private static let acceptedExts: Set<String> = [
        "mp3", "m4a", "m4b", "m4r", "mp4", "aac", "adts",
        "wav", "wave", "bwf", "rf64", "w64",
        "aif", "aiff", "aifc", "caf", "snd", "au",
        "ogg", "oga", "opus", "flac",
        "mp2", "ac3", "amr", "3gp", "3gpp", "sd2", "voc"
    ]

    /// Accept any file the system recognises as audio, plus the explicit
    /// fallback extensions above. This widens drag-drop well beyond the old
    /// fixed list — anything AVAudioFile can decode will load.
    private static func isAudioURL(_ url: URL) -> Bool {
        if let t = UTType(filenameExtension: url.pathExtension.lowercased()),
           t.conforms(to: .audio) {
            return true
        }
        return acceptedExts.contains(url.pathExtension.lowercased())
    }

    init(index: Int) {
        self.index = index
        super.init(frame: .zero)
        wantsLayer = true
        layer?.drawsAsynchronously = true
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("no") }

    // MARK: - Draw

    override func draw(_ r: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds.insetBy(dx: 1, dy: 1)
        ctx.setFillColor(panel.cgColor); ctx.fill(b)

        // Drag-hover wash.
        if isDragHovering { ctx.setFillColor(red.withAlphaComponent(0.12).cgColor); ctx.fill(b) }

        // Border — red & thicker when selected or hovering.
        let strokeColor: NSColor, strokeW: CGFloat
        if isDragHovering      { strokeColor = red; strokeW = 2.5 }
        else if isSelected     { strokeColor = red; strokeW = 2.0 }
        else                   { strokeColor = inkDark.withAlphaComponent(0.85); strokeW = 1.0 }
        ctx.setStrokeColor(strokeColor.cgColor); ctx.setLineWidth(strokeW)
        if isDragHovering { ctx.setLineDash(phase: 0, lengths: [4, 3]) }
        ctx.stroke(b)
        ctx.setLineDash(phase: 0, lengths: [])

        // ── Header: pad number (top-left) ──────────────────────────────
        ctx.setFillColor(red.cgColor); ctx.fill(NSRect(x: b.minX + 6, y: b.maxY - 12, width: 5, height: 5))
        let numAttr: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 9, weight: .heavy), .foregroundColor: inkDark, .kern: 0.4]
        NSString(string: String(format: "PAD %02d", index + 1)).draw(at: NSPoint(x: b.minX + 14, y: b.maxY - 14), withAttributes: numAttr)
        drawPadLED(ctx, in: b)

        if isDragHovering {
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .heavy), .foregroundColor: red, .kern: 2.0]
            let s = NSString(string: "DROP TO LOAD"); let sz = s.size(withAttributes: a)
            s.draw(at: NSPoint(x: b.midX - sz.width * 0.5, y: b.midY - 6), withAttributes: a)
            return
        }

        if isLoaded {
            drawKeyTrigPill(ctx, in: b)
            drawWaveform(ctx, in: b)
            drawSampleName(ctx, in: b)
            drawControlBand(ctx, in: b)
        } else {
            drawEmpty(ctx, in: b)
        }
    }

    private func drawEmpty(_ ctx: CGContext, in b: NSRect) {
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular), .foregroundColor: inkMid]
        let s = NSString(string: "— EMPTY —"); let sz = s.size(withAttributes: a)
        s.draw(at: NSPoint(x: b.midX - sz.width * 0.5, y: b.midY + 2), withAttributes: a)
        let hAttr: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .regular), .foregroundColor: inkMid.withAlphaComponent(0.75), .kern: 0.5]
        let hs = NSString(string: "DROP FILE  ·  SHIFT-CLICK TO LOAD  ·  RIGHT-CLICK")
        let hsz = hs.size(withAttributes: hAttr)
        hs.draw(at: NSPoint(x: b.midX - hsz.width * 0.5, y: b.midY - 14), withAttributes: hAttr)
    }

    private func drawWaveform(_ ctx: CGContext, in b: NSRect) {
        // MPC-style mirrored waveform thumbnail — filled red bars from a centre
        // line, amplitude varying deterministically per pad so each loaded pad
        // reads as a distinct "sample" at a glance.
        let top = b.maxY - 22, bottom = b.minY + 58
        let cy = (top + bottom) * 0.5
        let w = b.width - 28, x0 = b.minX + 14
        let bars = 60
        let bw = w / CGFloat(bars)
        let maxH = (top - bottom) * 0.46
        let seed = Float(index) * 2.39
        for i in 0..<bars {
            let t = Float(i) / Float(bars - 1)
            var a = abs(sinf(t * 9.0 + seed)) * 0.55 + abs(sinf(t * 27.0 + 1.7)) * 0.30 + abs(sinf(t * 53.0)) * 0.15
            a *= 0.30 + 0.70 * sinf(t * 3.14159)          // soft amplitude envelope
            let h = CGFloat(min(1.0, a)) * maxH + 1
            let x = x0 + CGFloat(i) * bw
            ctx.setFillColor(red.withAlphaComponent(0.85).cgColor)
            ctx.fill(NSRect(x: x, y: cy - h, width: max(1.0, bw - 1.0), height: h * 2))
        }
        ctx.setStrokeColor(red.withAlphaComponent(0.35).cgColor); ctx.setLineWidth(0.5)
        ctx.move(to: NSPoint(x: x0, y: cy)); ctx.addLine(to: NSPoint(x: x0 + w, y: cy)); ctx.strokePath()
    }

    /// Per-pad status LED — top-centre. Off (empty), dim (loaded), bright glow
    /// (selected). Gives the grid a hardware-sampler vibe.
    private func drawPadLED(_ ctx: CGContext, in b: NSRect) {
        let c = NSPoint(x: b.midX, y: b.maxY - 9)
        let r: CGFloat = 3.5
        let col: NSColor
        if isSelected      { col = red }
        else if isLoaded   { col = red.withAlphaComponent(0.5) }
        else               { col = inkMid.withAlphaComponent(0.35) }
        if isSelected {
            ctx.setFillColor(red.withAlphaComponent(0.30).cgColor)
            ctx.fillEllipse(in: NSRect(x: c.x - r - 4, y: c.y - r - 4, width: (r + 4) * 2, height: (r + 4) * 2))
        }
        ctx.setFillColor(col.cgColor)
        ctx.fillEllipse(in: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }

    private func drawSampleName(_ ctx: CGContext, in b: NSRect) {
        let nAttr: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 9, weight: .medium), .foregroundColor: inkDark]
        let ns = NSString(string: sampleName)
        let avail = b.width - 16
        var nsz = ns.size(withAttributes: nAttr)
        if nsz.width > avail { nsz.width = avail }
        let nx = b.midX - nsz.width * 0.5
        ns.draw(in: NSRect(x: nx, y: b.minY + 44, width: avail, height: 12), withAttributes: nAttr)
    }

    // MARK: - Control band (captions + bars)

    private func bandCaptionY(_ b: NSRect) -> CGFloat { b.minY + 28 }

    private func pitchRect() -> NSRect {
        let b = bounds.insetBy(dx: 1, dy: 1)
        let gap: CGFloat = 12
        let w = (b.width - 20 - gap) * 0.5
        return NSRect(x: b.minX + 10, y: b.minY + 8, width: w, height: 17)
    }
    private func chopRect() -> NSRect {
        let pr = pitchRect()
        return NSRect(x: pr.maxX + 12, y: pr.minY, width: pr.width, height: pr.height)
    }
    private func gateRect() -> NSRect {
        let b = bounds.insetBy(dx: 1, dy: 1)
        return NSRect(x: b.maxX - 56, y: b.maxY - 20, width: 50, height: 15)
    }

    private func drawControlBand(_ ctx: CGContext, in b: NSRect) {
        let pr = pitchRect(), cr = chopRect()
        let pitchSemi = delegate?.padPitch(for: index) ?? 0
        let chopK     = delegate?.padChop(for: index) ?? 0
        let root      = delegate?.padRootNote(for: index) ?? (24 + index * 24)
        let activeSeg = min(3, max(0, Int(chopK * 4)))
        let capY = bandCaptionY(b)

        let capAttr: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .heavy), .foregroundColor: inkDark, .kern: 0.4]
        let valAttr: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .regular), .foregroundColor: inkMid]

        // ── Captions row: PITCH value · CHOP value · ROOT (right) ──
        NSString(string: "PITCH").draw(at: NSPoint(x: pr.minX, y: capY), withAttributes: capAttr)
        NSString(string: String(format: "%+0.0f st", Double(pitchSemi)))
            .draw(at: NSPoint(x: pr.minX + 38, y: capY), withAttributes: valAttr)
        NSString(string: "CHOP").draw(at: NSPoint(x: cr.minX, y: capY), withAttributes: capAttr)
        NSString(string: chopLabels[activeSeg])
            .draw(at: NSPoint(x: cr.minX + 36, y: capY), withAttributes: valAttr)
        let rootStr = NSString(string: "ROOT \(midiName(root))")
        let rsz = rootStr.size(withAttributes: valAttr)
        rootStr.draw(at: NSPoint(x: b.maxX - 10 - rsz.width, y: capY), withAttributes: valAttr)

        // ── PITCH bar — bipolar, fill grows from the centre tick ──
        ctx.setFillColor(barBg.cgColor); ctx.fill(pr)
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.5).cgColor); ctx.setLineWidth(0.5); ctx.stroke(pr)
        let pitchFrac = CGFloat(max(-24, min(24, pitchSemi))) / 48.0
        if abs(pitchFrac) > 0.001 {
            let fillW = abs(pitchFrac) * pr.width
            let fillX = pitchFrac > 0 ? pr.midX : pr.midX - fillW
            ctx.setFillColor(red.cgColor); ctx.fill(NSRect(x: fillX, y: pr.minY, width: fillW, height: pr.height))
        }
        ctx.setStrokeColor(inkDark.cgColor); ctx.setLineWidth(0.7)
        ctx.move(to: NSPoint(x: pr.midX, y: pr.minY)); ctx.addLine(to: NSPoint(x: pr.midX, y: pr.maxY)); ctx.strokePath()

        // ── CHOP bar — 4 segments, active one filled red ──
        ctx.setFillColor(barBg.cgColor); ctx.fill(cr)
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.5).cgColor); ctx.setLineWidth(0.5); ctx.stroke(cr)
        let segW = cr.width / 4.0
        ctx.setFillColor(red.cgColor)
        ctx.fill(NSRect(x: cr.minX + CGFloat(activeSeg) * segW, y: cr.minY, width: segW, height: cr.height))
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.4).cgColor); ctx.setLineWidth(0.4)
        for i in 1..<4 {
            let x = cr.minX + CGFloat(i) * segW
            ctx.move(to: NSPoint(x: x, y: cr.minY)); ctx.addLine(to: NSPoint(x: x, y: cr.maxY))
        }
        ctx.strokePath()
        // Tiny segment labels inside the bar (white on the active red one).
        let segOn:  [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 6, weight: .heavy), .foregroundColor: NSColor.white]
        let segOff: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 6, weight: .regular), .foregroundColor: inkMid]
        for i in 0..<4 {
            let s = NSString(string: chopLabels[i])
            let attrs = (i == activeSeg) ? segOn : segOff
            let sz = s.size(withAttributes: attrs)
            let cx = cr.minX + segW * (CGFloat(i) + 0.5)
            s.draw(at: NSPoint(x: cx - sz.width * 0.5, y: cr.midY - sz.height * 0.5), withAttributes: attrs)
        }
    }

    /// KEY-TRIGGER pill, top-right. GATE (held) ↔ 1-SHOT.
    private func drawKeyTrigPill(_ ctx: CGContext, in b: NSRect) {
        let kt = delegate?.padKeyTrigger(for: index) ?? false
        let gr = gateRect()
        if kt {
            ctx.setFillColor(red.cgColor); ctx.fill(gr)
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 8, weight: .heavy), .foregroundColor: NSColor.white, .kern: 0.5]
            let s = NSString(string: "GATE"); let sz = s.size(withAttributes: a)
            s.draw(at: NSPoint(x: gr.midX - sz.width * 0.5, y: gr.midY - sz.height * 0.5), withAttributes: a)
        } else {
            ctx.setStrokeColor(inkDark.withAlphaComponent(0.55).cgColor); ctx.setLineWidth(0.6); ctx.stroke(gr)
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 8, weight: .heavy), .foregroundColor: inkDark, .kern: 0.5]
            let s = NSString(string: "1-SHOT"); let sz = s.size(withAttributes: a)
            s.draw(at: NSPoint(x: gr.midX - sz.width * 0.5, y: gr.midY - sz.height * 0.5), withAttributes: a)
        }
    }

    private func midiName(_ note: Int) -> String {
        let names = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
        let octave = note / 12 - 1
        return "\(names[note % 12])\(octave)"
    }

    // MARK: - Mouse

    private enum Drag { case none, pitch, chop }
    private var drag: Drag = .none
    private var dragStartY: CGFloat = 0
    private var dragStartV: Float = 0

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        // Controls only respond on a loaded pad.
        if isLoaded {
            // KEY-TRIGGER pill — flip GATE ↔ 1-SHOT.
            if gateRect().contains(p) {
                let cur = delegate?.padKeyTrigger(for: index) ?? false
                delegate?.padSetKeyTrigger(!cur, for: index)
                needsDisplay = true
                return
            }
            // PITCH bar — drag vertically (⌥ = fine), double-click resets to 0.
            if pitchRect().contains(p) {
                if e.clickCount == 2 { delegate?.padSetPitch(0, for: index); needsDisplay = true; return }
                drag = .pitch
                dragStartY = p.y
                dragStartV = delegate?.padPitch(for: index) ?? 0
                return
            }
            // CHOP bar — click a segment, drag horizontally to scrub.
            if chopRect().contains(p) {
                let cr = chopRect()
                let frac = max(0.0, min(0.999, (p.x - cr.minX) / cr.width))
                delegate?.padSetChop(Float(frac), for: index)
                drag = .chop
                needsDisplay = true
                return
            }
        }
        if e.modifierFlags.contains(.shift) {
            delegate?.pad(self, didRequestLoadAt: index)
        } else if e.modifierFlags.contains(.option) {
            delegate?.pad(self, didRequestClearAt: index)
        } else {
            delegate?.pad(self, didTriggerAt: index)
        }
    }

    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        switch drag {
        case .pitch:
            let dy = Float(p.y - dragStartY)
            // Coarse drag spans the full ±24 st over a comfortable travel;
            // ⌥ gives fine control. Range widened from ±12 → ±24 (±2 oct).
            let scale: Float = e.modifierFlags.contains(.option) ? 0.06 : 0.22
            let nv = max(-24, min(24, dragStartV + dy * scale))
            delegate?.padSetPitch(nv, for: index)
            needsDisplay = true
        case .chop:
            let cr = chopRect()
            let frac = max(0.0, min(0.999, (p.x - cr.minX) / cr.width))
            delegate?.padSetChop(Float(frac), for: index)
            needsDisplay = true
        case .none:
            break
        }
    }

    override func mouseUp(with e: NSEvent) { drag = .none }

    // Two-finger / right-click → context menu
    override func rightMouseDown(with event: NSEvent) {
        if let m = menu(for: event) {
            NSMenu.popUpContextMenu(m, with: event, for: self)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu(title: "Pad \(index + 1)")

        let loadItem = NSMenuItem(title: "Load Sample…", action: #selector(menuLoad), keyEquivalent: "")
        loadItem.target = self
        m.addItem(loadItem)

        let clearItem = NSMenuItem(title: isLoaded ? "Clear Sample" : "Clear (empty)", action: #selector(menuClear), keyEquivalent: "")
        clearItem.target = self
        clearItem.isEnabled = isLoaded
        m.addItem(clearItem)

        if isLoaded {
            let revealItem = NSMenuItem(title: "Show Sample Info", action: #selector(menuReveal), keyEquivalent: "")
            revealItem.target = self
            m.addItem(revealItem)
        }

        m.addItem(.separator())

        // Recent files submenu
        let recents = delegate?.pad(self, didRequestRecentAt: index) ?? []
        let recentsRoot = NSMenuItem(title: "Recent Files", action: nil, keyEquivalent: "")
        let recentsMenu = NSMenu(title: "Recent Files")
        if recents.isEmpty {
            let empty = NSMenuItem(title: "— None yet —", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentsMenu.addItem(empty)
        } else {
            for url in recents.prefix(12) {
                let it = NSMenuItem(title: url.lastPathComponent, action: #selector(menuPickRecent(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = url
                it.toolTip = url.path
                recentsMenu.addItem(it)
            }
        }
        recentsRoot.submenu = recentsMenu
        m.addItem(recentsRoot)

        m.addItem(.separator())
        let info = NSMenuItem(title: "Pad \(index + 1) — \(sampleName)", action: nil, keyEquivalent: "")
        info.isEnabled = false
        m.addItem(info)
        return m
    }

    @objc private func menuLoad()  { delegate?.pad(self, didRequestLoadAt: index) }
    @objc private func menuClear() { delegate?.pad(self, didRequestClearAt: index) }
    @objc private func menuReveal(){ delegate?.pad(self, didRequestRevealAt: index) }
    @objc private func menuPickRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        delegate?.pad(self, didPickRecentURL: url, at: index)
    }

    // MARK: - Drag & Drop

    private func acceptableURL(from sender: NSDraggingInfo) -> URL? {
        let pb = sender.draggingPasteboard
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL],
              let url = urls.first else { return nil }
        return PadView.isAudioURL(url) ? url : nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if acceptableURL(from: sender) != nil {
            isDragHovering = true
            return .copy
        }
        return []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return acceptableURL(from: sender) != nil ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDragHovering = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isDragHovering = false
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return acceptableURL(from: sender) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = acceptableURL(from: sender) else { isDragHovering = false; return false }
        isDragHovering = false
        delegate?.pad(self, didDropFileAt: index, url: url)
        return true
    }
}
