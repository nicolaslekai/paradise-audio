//
//  ZoneBoxView.swift — one large horizontal sample box (a "zone").
//
//  Handy surfaces TWO of these, stacked vertically:
//      • Zone 1 covers the first 16 keys  (C2 .. D#3)
//      • Zone 2 covers the next  16 keys  (E3 .. G4)
//
//  Each box is a drop target + waveform display with a RANGE selector — two
//  draggable handles over the waveform pick which portion of the loaded sample
//  actually plays. Click auditions, shift-click loads, option-click clears,
//  right-click opens the menu (mirrors the old PadView affordances).
//
//  Internal layout (top→bottom):
//      ┌──────────────────────────────────────────────────────────────┐
//      │ ▸ ZONE 1   C2–D#3                              [ GATE ] [REV] │  header
//      │  ┃░░░░░░░░░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░┃                │  waveform + range
//      │  └ start handle      selected window      end handle ┘        │
//      │  my-loop.wav                                  RANGE 12–78%    │  footer
//      └──────────────────────────────────────────────────────────────┘
//

import AppKit
import UniformTypeIdentifiers

protocol ZoneBoxViewDelegate: AnyObject {
    func zone(_ box: ZoneBoxView, didTriggerAt index: Int)
    func zone(_ box: ZoneBoxView, didRequestLoadAt index: Int)
    func zone(_ box: ZoneBoxView, didRequestClearAt index: Int)
    func zone(_ box: ZoneBoxView, didDropFileAt index: Int, url: URL)
    func zone(_ box: ZoneBoxView, didRequestRecentAt index: Int) -> [URL]
    func zone(_ box: ZoneBoxView, didPickRecentURL url: URL, at index: Int)

    // RANGE (normalized 0..1 start/end).
    func zoneRange(for index: Int) -> (start: Float, end: Float)
    func zoneSetRange(_ start: Float, _ end: Float, for index: Int)

    // CHOP knob (0..1 → FWD/REV/STUT/HALF) and KEY-TRIGGER (GATE / 1-SHOT).
    func zoneChop(for index: Int) -> Float
    func zoneSetChop(_ knob: Float, for index: Int)
    func zoneKeyTrigger(for index: Int) -> Bool
    func zoneSetKeyTrigger(_ on: Bool, for index: Int)

    // Key-span caption (e.g. "C2–D#3").
    func zoneKeySpan(for index: Int) -> String
}

final class ZoneBoxView: NSView {
    let index: Int
    weak var delegate: ZoneBoxViewDelegate?

    var sampleName: String = "— EMPTY —" {
        didSet {
            // A different sample means the old FRAME window is meaningless.
            if sampleName != oldValue { viewStart = 0; viewEnd = 1 }
            needsDisplay = true
        }
    }
    var isSelected: Bool = false { didSet { needsDisplay = true } }
    var isLoaded: Bool = false { didSet { needsDisplay = true } }
    /// Pre-computed mirrored peak envelope of the loaded sample (0..1), drawn as
    /// the waveform. Empty → falls back to a flat baseline.
    var peaks: [Float] = [] { didSet { needsDisplay = true } }
    private var isDragHovering: Bool = false { didSet { needsDisplay = true } }

    /// FRAME — a purely visual zoom window over the sample (normalised 0..1).
    /// The playing RANGE is untouched by this; framing just stretches the
    /// chosen slice of the waveform across the full width of the box so a 1%
    /// region is actually editable instead of being three pixels wide.
    private var viewStart: Float = 0
    private var viewEnd:   Float = 1
    private var isFramed: Bool { viewStart > 0.0001 || viewEnd < 0.9999 }
    /// Reset the zoom whenever a different sample lands in this zone.
    func resetFrame() { viewStart = 0; viewEnd = 1; needsDisplay = true }

    private let inkDark = Palette.inkLight
    private let inkMid  = Palette.inkMidL
    private let red     = Palette.red
    private let panel   = Palette.panelDark
    private let waveBg  = NSColor(calibratedWhite: 0.08, alpha: 1.0)

    private let chopLabels = ["FWD", "REV", "STUT", "HALF"]

    private static let acceptedExts: Set<String> = [
        "mp3", "m4a", "m4b", "m4r", "mp4", "aac", "adts",
        "wav", "wave", "bwf", "rf64", "w64",
        "aif", "aiff", "aifc", "caf", "snd", "au",
        "ogg", "oga", "opus", "flac",
        "mp2", "ac3", "amr", "3gp", "3gpp", "sd2", "voc"
    ]
    private static func isAudioURL(_ url: URL) -> Bool {
        if let t = UTType(filenameExtension: url.pathExtension.lowercased()),
           t.conforms(to: .audio) { return true }
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

    // MARK: - Geometry

    /// Waveform rectangle (the range handles live over this).
    private func waveRect() -> NSRect {
        let b = bounds.insetBy(dx: 1, dy: 1)
        let top    = b.maxY - 22       // clear of the header row
        let bottom = b.minY + 20       // clear of the footer row
        return NSRect(x: b.minX + 10, y: bottom, width: b.width - 20, height: top - bottom)
    }
    private func gateRect() -> NSRect {
        let b = bounds.insetBy(dx: 1, dy: 1)
        return NSRect(x: b.maxX - 52, y: b.maxY - 19, width: 46, height: 14)
    }
    private func chopRect() -> NSRect {
        let g = gateRect()
        return NSRect(x: g.minX - 8 - 84, y: g.minY, width: 84, height: 14)
    }
    private func frameRect() -> NSRect {
        let c = chopRect()
        return NSRect(x: c.minX - 8 - 46, y: c.minY, width: 46, height: 14)
    }
    /// Sample position (0..1) -> x, through the current FRAME window.
    private func handleX(_ frac: Float) -> CGFloat {
        let w = waveRect()
        let span = max(0.0001, viewEnd - viewStart)
        let t = CGFloat(max(-0.5, min(1.5, (frac - viewStart) / span)))
        return w.minX + t * w.width
    }
    /// x -> sample position (0..1), the inverse of handleX.
    private func fracAtX(_ x: CGFloat) -> Float {
        let w = waveRect()
        let t = Float(max(0, min(1, (x - w.minX) / max(1, w.width))))
        return max(0, min(1, viewStart + t * (viewEnd - viewStart)))
    }

    // MARK: - Draw

    override func draw(_ r: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds.insetBy(dx: 1, dy: 1)
        ctx.setFillColor(panel.cgColor); ctx.fill(b)
        if isDragHovering { ctx.setFillColor(red.withAlphaComponent(0.12).cgColor); ctx.fill(b) }

        let strokeColor: NSColor, strokeW: CGFloat
        if isDragHovering   { strokeColor = red; strokeW = 2.5 }
        else if isSelected  { strokeColor = red; strokeW = 2.0 }
        else                { strokeColor = inkDark.withAlphaComponent(0.85); strokeW = 1.0 }
        ctx.setStrokeColor(strokeColor.cgColor); ctx.setLineWidth(strokeW)
        if isDragHovering { ctx.setLineDash(phase: 0, lengths: [4, 3]) }
        ctx.stroke(b)
        ctx.setLineDash(phase: 0, lengths: [])

        drawHeader(ctx, in: b)

        if isDragHovering {
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .heavy), .foregroundColor: red, .kern: 2.0]
            let s = NSString(string: "DROP TO LOAD"); let sz = s.size(withAttributes: a)
            s.draw(at: NSPoint(x: b.midX - sz.width * 0.5, y: b.midY - 6), withAttributes: a)
            return
        }

        if isLoaded {
            drawWaveform(ctx)
            drawRangeHandles(ctx)
            drawChop(ctx)
            drawFramePill(ctx)
            drawKeyTrigPill(ctx)
            drawFooter(ctx, in: b)
        } else {
            drawEmpty(ctx, in: b)
        }
    }

    private func drawHeader(_ ctx: CGContext, in b: NSRect) {
        ctx.setFillColor(red.cgColor)
        ctx.fill(NSRect(x: b.minX + 6, y: b.maxY - 13, width: 5, height: 5))
        let h: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 9, weight: .heavy), .foregroundColor: inkDark, .kern: 0.6]
        NSString(string: String(format: "ZONE %d", index + 1))
            .draw(at: NSPoint(x: b.minX + 14, y: b.maxY - 15), withAttributes: h)
        // Key-span caption next to the title.
        let span = delegate?.zoneKeySpan(for: index) ?? ""
        let sp: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 8, weight: .regular), .foregroundColor: inkMid, .kern: 0.5]
        NSString(string: span).draw(at: NSPoint(x: b.minX + 64, y: b.maxY - 14), withAttributes: sp)
    }

    private func drawEmpty(_ ctx: CGContext, in b: NSRect) {
        let w = waveRect()
        ctx.setFillColor(waveBg.cgColor); ctx.fill(w)
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.25).cgColor); ctx.setLineWidth(0.5); ctx.stroke(w)
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular), .foregroundColor: inkMid]
        let s = NSString(string: "— EMPTY —"); let sz = s.size(withAttributes: a)
        s.draw(at: NSPoint(x: w.midX - sz.width * 0.5, y: w.midY + 3), withAttributes: a)
        let hAttr: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .regular), .foregroundColor: inkMid.withAlphaComponent(0.75), .kern: 0.5]
        let hs = NSString(string: "DROP AUDIO HERE  ·  SHIFT-CLICK TO LOAD  ·  RIGHT-CLICK")
        let hsz = hs.size(withAttributes: hAttr)
        hs.draw(at: NSPoint(x: w.midX - hsz.width * 0.5, y: w.midY - 12), withAttributes: hAttr)
    }

    private func drawWaveform(_ ctx: CGContext) {
        let w = waveRect()
        ctx.setFillColor(waveBg.cgColor); ctx.fill(w)
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.25).cgColor); ctx.setLineWidth(0.5); ctx.stroke(w)

        let cy = w.midY, maxH = w.height * 0.46
        let (rs, re) = delegate?.zoneRange(for: index) ?? (0, 1)
        let count = peaks.count
        if count > 1 {
            // Draw one column per pixel across the FRAME window, taking the
            // max peak that falls in each column. At full zoom this is the
            // same picture as before; framed in, it resolves detail instead
            // of decimating it.
            let cols = max(1, Int(w.width))
            let span = max(0.0001, viewEnd - viewStart)
            for c in 0..<cols {
                let f0 = viewStart + span * Float(c)     / Float(cols)
                let f1 = viewStart + span * Float(c + 1) / Float(cols)
                var i0 = Int(f0 * Float(count - 1))
                var i1 = Int(f1 * Float(count - 1))
                i0 = max(0, min(count - 1, i0)); i1 = max(i0, min(count - 1, i1))
                var pk: Float = 0
                for i in i0...i1 { pk = max(pk, peaks[i]) }
                let mid = (f0 + f1) * 0.5
                let inWin = (mid >= rs && mid <= re)
                let h = CGFloat(min(1.0, pk)) * maxH + 0.5
                let x = w.minX + CGFloat(c)
                ctx.setFillColor((inWin ? red.withAlphaComponent(0.9) : inkMid.withAlphaComponent(0.35)).cgColor)
                ctx.fill(NSRect(x: x, y: cy - h, width: 1.0, height: h * 2))
            }
        } else {
            ctx.setStrokeColor(red.withAlphaComponent(0.4).cgColor); ctx.setLineWidth(0.5)
            ctx.move(to: NSPoint(x: w.minX, y: cy)); ctx.addLine(to: NSPoint(x: w.maxX, y: cy)); ctx.strokePath()
        }
    }

    /// RANGE handles — two draggable vertical bars; the area outside the
    /// selection is shaded so the playing window reads clearly.
    private func drawRangeHandles(_ ctx: CGContext) {
        let w = waveRect()
        let (rs, re) = delegate?.zoneRange(for: index) ?? (0, 1)
        let xs = handleX(rs), xe = handleX(re)

        // Dim the regions outside [start, end].
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        if xs > w.minX { ctx.fill(NSRect(x: w.minX, y: w.minY, width: xs - w.minX, height: w.height)) }
        if xe < w.maxX { ctx.fill(NSRect(x: xe, y: w.minY, width: w.maxX - xe, height: w.height)) }

        // Handle bars + grab caps (skip any scrolled out of the frame).
        for x in [xs, xe] where x >= w.minX - 1 && x <= w.maxX + 1 {
            ctx.setStrokeColor(red.cgColor); ctx.setLineWidth(2.0)
            ctx.move(to: NSPoint(x: x, y: w.minY)); ctx.addLine(to: NSPoint(x: x, y: w.maxY)); ctx.strokePath()
            ctx.setFillColor(red.cgColor)
            ctx.fill(NSRect(x: x - 3, y: w.maxY - 6, width: 6, height: 6))
            ctx.fill(NSRect(x: x - 3, y: w.minY, width: 6, height: 6))
        }
    }

    private func drawChop(_ ctx: CGContext) {
        let cr = chopRect()
        let chopK = delegate?.zoneChop(for: index) ?? 0
        let activeSeg = min(3, max(0, Int(chopK * 4)))
        ctx.setFillColor(NSColor(calibratedWhite: 0.10, alpha: 1).cgColor); ctx.fill(cr)
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.45).cgColor); ctx.setLineWidth(0.5); ctx.stroke(cr)
        let segW = cr.width / 4.0
        ctx.setFillColor(red.cgColor)
        ctx.fill(NSRect(x: cr.minX + CGFloat(activeSeg) * segW, y: cr.minY, width: segW, height: cr.height))
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

    /// FRAME / FULL pill. FRAME zooms the display to the selected RANGE;
    /// once framed the same button reads FULL and zooms back out.
    private func drawFramePill(_ ctx: CGContext) {
        let fr = frameRect()
        let label = isFramed ? "FULL" : "FRAME"
        if isFramed {
            ctx.setFillColor(red.cgColor); ctx.fill(fr)
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .heavy), .foregroundColor: NSColor.white, .kern: 0.5]
            let s = NSString(string: label); let sz = s.size(withAttributes: a)
            s.draw(at: NSPoint(x: fr.midX - sz.width * 0.5, y: fr.midY - sz.height * 0.5), withAttributes: a)
        } else {
            ctx.setStrokeColor(inkDark.withAlphaComponent(0.55).cgColor); ctx.setLineWidth(0.6); ctx.stroke(fr)
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .heavy), .foregroundColor: inkDark, .kern: 0.5]
            let s = NSString(string: label); let sz = s.size(withAttributes: a)
            s.draw(at: NSPoint(x: fr.midX - sz.width * 0.5, y: fr.midY - sz.height * 0.5), withAttributes: a)
        }
    }

    private func drawKeyTrigPill(_ ctx: CGContext) {
        let kt = delegate?.zoneKeyTrigger(for: index) ?? false
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

    private func drawFooter(_ ctx: CGContext, in b: NSRect) {
        let nAttr: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 9, weight: .medium), .foregroundColor: inkDark]
        NSString(string: sampleName).draw(at: NSPoint(x: b.minX + 10, y: b.minY + 4), withAttributes: nAttr)
        // RANGE readout, right-aligned.
        let (rs, re) = delegate?.zoneRange(for: index) ?? (0, 1)
        let rAttr: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 8, weight: .heavy), .foregroundColor: red, .kern: 0.4]
        let rstr = NSString(string: isFramed
            ? String(format: "RANGE %.1f–%.1f%%  ·  VIEW %.0f–%.0f%%", rs * 100, re * 100, viewStart * 100, viewEnd * 100)
            : String(format: "RANGE %.0f–%.0f%%", rs * 100, re * 100))
        let rsz = rstr.size(withAttributes: rAttr)
        rstr.draw(at: NSPoint(x: b.maxX - 10 - rsz.width, y: b.minY + 4), withAttributes: rAttr)
    }

    // MARK: - Mouse

    private enum Drag { case none, rangeStart, rangeEnd, chop }
    private var drag: Drag = .none

    private func nearestHandle(_ p: NSPoint) -> Drag {
        let (rs, re) = delegate?.zoneRange(for: index) ?? (0, 1)
        let dxS = abs(p.x - handleX(rs)), dxE = abs(p.x - handleX(re))
        let grab: CGFloat = 8
        if dxS <= grab && dxS <= dxE { return .rangeStart }
        if dxE <= grab { return .rangeEnd }
        return .none
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if isLoaded {
            // GATE pill.
            if gateRect().contains(p) {
                let cur = delegate?.zoneKeyTrigger(for: index) ?? false
                delegate?.zoneSetKeyTrigger(!cur, for: index); needsDisplay = true; return
            }
            // FRAME / FULL pill.
            if frameRect().contains(p) {
                if isFramed {
                    viewStart = 0; viewEnd = 1
                } else {
                    let (s0, e0) = delegate?.zoneRange(for: index) ?? (0, 1)
                    // Pad by 4% of the selection so the handles stay grabbable
                    // at the edges, and never frame tighter than 0.2%.
                    let pad = max(0.001, (e0 - s0) * 0.04)
                    viewStart = max(0, s0 - pad)
                    viewEnd   = min(1, max(viewStart + 0.002, e0 + pad))
                }
                needsDisplay = true; return
            }
            // CHOP segments.
            if chopRect().contains(p) {
                let cr = chopRect()
                let frac = max(0.0, min(0.999, (p.x - cr.minX) / cr.width))
                delegate?.zoneSetChop(Float(frac), for: index)
                drag = .chop; needsDisplay = true; return
            }
            // RANGE handles — grab whichever is nearest the click.
            if waveRect().insetBy(dx: 0, dy: -4).contains(p) {
                let h = nearestHandle(p)
                if h != .none { drag = h; updateRange(p); return }
            }
        }
        if e.modifierFlags.contains(.shift) {
            delegate?.zone(self, didRequestLoadAt: index)
        } else if e.modifierFlags.contains(.option) {
            delegate?.zone(self, didRequestClearAt: index)
        } else {
            delegate?.zone(self, didTriggerAt: index)
        }
    }

    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        switch drag {
        case .rangeStart, .rangeEnd: updateRange(p)
        case .chop:
            let cr = chopRect()
            let frac = max(0.0, min(0.999, (p.x - cr.minX) / cr.width))
            delegate?.zoneSetChop(Float(frac), for: index); needsDisplay = true
        case .none: break
        }
    }

    override func mouseUp(with e: NSEvent) { drag = .none }

    private func updateRange(_ p: NSPoint) {
        let frac = fracAtX(p.x)
        var (rs, re) = delegate?.zoneRange(for: index) ?? (0, 1)
        if drag == .rangeStart { rs = min(frac, re - 0.01) }
        else if drag == .rangeEnd { re = max(frac, rs + 0.01) }
        delegate?.zoneSetRange(rs, re, for: index)
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        if let m = menu(for: event) { NSMenu.popUpContextMenu(m, with: event, for: self) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu(title: "Zone \(index + 1)")
        let loadItem = NSMenuItem(title: "Load Sample…", action: #selector(menuLoad), keyEquivalent: "")
        loadItem.target = self; m.addItem(loadItem)
        let clearItem = NSMenuItem(title: isLoaded ? "Clear Sample" : "Clear (empty)", action: #selector(menuClear), keyEquivalent: "")
        clearItem.target = self; clearItem.isEnabled = isLoaded; m.addItem(clearItem)
        if isLoaded {
            let resetItem = NSMenuItem(title: "Reset Range (Full)", action: #selector(menuResetRange), keyEquivalent: "")
            resetItem.target = self; m.addItem(resetItem)
        }
        m.addItem(.separator())
        let recents = delegate?.zone(self, didRequestRecentAt: index) ?? []
        let recentsRoot = NSMenuItem(title: "Recent Files", action: nil, keyEquivalent: "")
        let recentsMenu = NSMenu(title: "Recent Files")
        if recents.isEmpty {
            let empty = NSMenuItem(title: "— None yet —", action: nil, keyEquivalent: "")
            empty.isEnabled = false; recentsMenu.addItem(empty)
        } else {
            for url in recents.prefix(12) {
                let it = NSMenuItem(title: url.lastPathComponent, action: #selector(menuPickRecent(_:)), keyEquivalent: "")
                it.target = self; it.representedObject = url; it.toolTip = url.path
                recentsMenu.addItem(it)
            }
        }
        recentsRoot.submenu = recentsMenu; m.addItem(recentsRoot)
        m.addItem(.separator())
        let info = NSMenuItem(title: "Zone \(index + 1) — \(sampleName)", action: nil, keyEquivalent: "")
        info.isEnabled = false; m.addItem(info)
        return m
    }

    @objc private func menuLoad()  { delegate?.zone(self, didRequestLoadAt: index) }
    @objc private func menuClear() { delegate?.zone(self, didRequestClearAt: index) }
    @objc private func menuResetRange() { delegate?.zoneSetRange(0, 1, for: index); needsDisplay = true }
    @objc private func menuPickRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        delegate?.zone(self, didPickRecentURL: url, at: index)
    }

    // MARK: - Drag & Drop

    private func acceptableURL(from sender: NSDraggingInfo) -> URL? {
        let pb = sender.draggingPasteboard
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL],
              let url = urls.first else { return nil }
        return ZoneBoxView.isAudioURL(url) ? url : nil
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if acceptableURL(from: sender) != nil { isDragHovering = true; return .copy }
        return []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return acceptableURL(from: sender) != nil ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { isDragHovering = false }
    override func draggingEnded(_ sender: NSDraggingInfo) { isDragHovering = false }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return acceptableURL(from: sender) != nil
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = acceptableURL(from: sender) else { isDragHovering = false; return false }
        isDragHovering = false
        delegate?.zone(self, didDropFileAt: index, url: url)
        return true
    }
}
