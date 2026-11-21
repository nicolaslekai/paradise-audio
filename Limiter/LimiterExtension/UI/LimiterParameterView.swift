//
//  LimiterParameterView.swift
//
//  Layout (researched against Pro-L 2 + the LUFS-meter UI conventions
//  noted in the design docs):
//
//   ┌──────────────────────────────────────────────────────────────────┐
//   │  PARADISE AUDIO · LIMITER — LIM-1                                │
//   ├──────────────────────────────────────────────────────────────────┤
//   │  ╔════════════════════════════════════════════════════════════╗  │
//   │  ║       SCROLLING WAVEFORM (post-limit, 2 s window)          ║  │
//   │  ╚════════════════════════════════════════════════════════════╝  │
//   │  ┌─────────────┐ ┌─────────────┐  ┌─────────────┐ ┌───────────┐  │
//   │  │ SHORT-TERM  │ │ INTEGRATED  │  │  BROADCAST  │ │  STREAM   │  │
//   │  │  −14.2 LUFS │ │  −15.1 LUFS │  │  −23 LUFS   │ │ −14 LUFS  │  │
//   │  └─────────────┘ └─────────────┘  └─────────────┘ └───────────┘  │
//   │     [GAIN]    [CEILING]    [RELEASE]                  IN | GR    │
//   └──────────────────────────────────────────────────────────────────┘
//

import AppKit
import AudioToolbox

final class LimiterParameterView: NSView {

    var audioUnit: LimiterAudioUnit? { didSet { rebind() } }

    private let cream     = Palette.cream
    private let panelBg   = Palette.panelDark
    private let inkDark   = Palette.inkLight
    private let inkMid    = Palette.inkMidL
    private let accentRed = Palette.accentRed
    private let faceBg    = Palette.faceBg
    private let undoCtl   = ParamUndo()

    private var knobs: [KnobView] = []
    private let waveform = WaveformView(frame: .zero)
    private var meterTimer: Timer?

    // Latched meter values, refreshed at 30 Hz on the main thread.
    private var grDB:    Float = 0
    private var inPeakDB: Float = -60
    private var stLUFS:   Float = -120
    private var iLUFS:    Float = -120

    // Hit rects, set during draw / consumed by mouseDown.
    private var broadcastRect: NSRect = .zero
    private var streamRect:    NSRect = .zero
    private var iResetRect:    NSRect = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = faceBg.cgColor
        layer?.drawsAsynchronously = true
        addSubview(waveform)
        startMeterTimer()
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    deinit { meterTimer?.invalidate() }

    private func startMeterTimer() {
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, let au = self.audioUnit else { return }
            self.grDB     = au.currentGainReductionDB
            self.inPeakDB = au.currentInputPeakDB
            self.stLUFS   = au.shortTermLUFS
            self.iLUFS    = au.integratedLUFS
            self.needsDisplay = true
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let pad: CGFloat       = 18
        let footerH: CGFloat   = 36
        let knobH: CGFloat     = 128
        let knobW: CGFloat     = 86
        let knobGap: CGFloat   = 18
        let waveH: CGFloat     = 150
        let lufsRowH: CGFloat  = 60

        // Top: scrolling waveform fills the full panel width
        let waveY = bounds.height - 40 - waveH
        waveform.frame = NSRect(x: pad, y: waveY,
                                 width: bounds.width - pad * 2,
                                 height: waveH)

        // Bottom: knob row (3 knobs, left-aligned) + reserve right side
        // of the row for the IN/GR mini-meters drawn directly in draw().
        let knobsY = footerH + 6
        var x = pad
        for k in knobs {
            k.frame = NSRect(x: x, y: knobsY, width: knobW, height: knobH)
            x += knobW + knobGap
        }
        // LUFS row sits between the knobs and the waveform — drawn in
        // draw() (no subviews; preset/LUFS panels are direct CG fills).
        _ = lufsRowH
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Subtle brushed-aluminium faceplate (keeps panel colour, adds analogue grain).
        FaceTexture.draw(in: bounds, ctx: ctx)
        let b = bounds

        // Brand strip — same as every Paradise plug-in
        ctx.setFillColor(accentRed.cgColor)
        BrandLogo.draw(in: NSRect(x: 12, y: 2, width: 30, height: 30), ctx: ctx)
        let brand: [NSAttributedString.Key: Any] = [
            .font: Palette.printFontCondensed(11),
            .foregroundColor: inkDark, .kern: 1.2
        ]
        NSString(string: "PARADISE AUDIO").draw(at: NSPoint(x: 46, y: 15), withAttributes: brand)
        let sub: [NSAttributedString.Key: Any] = [
            .font: Palette.printFont(7.5),
            .foregroundColor: inkMid, .kern: 0.6
        ]
        NSString(string: "LIMITER — LIM-1").draw(at: NSPoint(x: 46, y: 4), withAttributes: sub)
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.25).cgColor); ctx.setLineWidth(0.5)
        ctx.move(to: NSPoint(x: 16, y: 36)); ctx.addLine(to: NSPoint(x: b.width - 16, y: 36))
        ctx.strokePath()

        // Tag in top-right
        let tag: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 7, weight: .regular),
            .foregroundColor: inkMid, .kern: 0.5
        ]
        let tagStr = NSString(string: "AU v3 · STEREO · BS.1770")
        let tw = tagStr.size(withAttributes: tag)
        tagStr.draw(at: NSPoint(x: b.width - tw.width - 16, y: b.height - 14), withAttributes: tag)

        // ── LUFS row + preset buttons (between knobs and waveform) ─────
        let lufsRowY     = waveform.frame.minY - 70
        let lufsRowH: CGFloat = 60
        let lufsPanelW: CGFloat = 130
        let presetW:    CGFloat = 110
        let gap: CGFloat = 8

        // Two LUFS readout panels on the left
        let stRect = NSRect(x: 18,                      y: lufsRowY, width: lufsPanelW, height: lufsRowH)
        let iRect  = NSRect(x: stRect.maxX + gap,       y: lufsRowY, width: lufsPanelW, height: lufsRowH)
        drawLufsReadout(ctx, rect: stRect, title: "SHORT-TERM (3s)", lufs: stLUFS, gateActive: false)
        drawLufsReadout(ctx, rect: iRect,  title: "INTEGRATED",      lufs: iLUFS,  gateActive: true)
        // "I RESET" tap zone — narrow strip below the integrated panel
        let resetStr = NSString(string: "↺ RESET I")
        let resetAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 8, weight: .heavy),
            .foregroundColor: accentRed, .kern: 0.5
        ]
        let rsz = resetStr.size(withAttributes: resetAttr)
        iResetRect = NSRect(x: iRect.maxX - rsz.width - 6, y: iRect.maxY - rsz.height - 4,
                             width: rsz.width + 4, height: rsz.height + 2)
        resetStr.draw(at: NSPoint(x: iResetRect.minX + 2, y: iResetRect.minY + 1), withAttributes: resetAttr)

        // Two LUFS preset buttons on the right of the LUFS row
        broadcastRect = NSRect(x: b.width - 18 - presetW * 2 - gap, y: lufsRowY,
                                width: presetW, height: lufsRowH)
        streamRect    = NSRect(x: b.width - 18 - presetW,           y: lufsRowY,
                                width: presetW, height: lufsRowH)
        drawPresetButton(ctx, rect: broadcastRect, title: "BROADCAST", subtitle: "−23 LUFS")
        drawPresetButton(ctx, rect: streamRect,    title: "STREAM",    subtitle: "−14 LUFS")

        // ── Right-edge mini-meters (IN + GR) over the knob row ────────
        let metersX = b.width - 18 - 60
        let metersY: CGFloat = 36 + 6
        let metersH: CGFloat = 96
        let mW: CGFloat = 24
        let inMRect = NSRect(x: metersX,            y: metersY, width: mW, height: metersH)
        let grMRect = NSRect(x: metersX + mW + 8,   y: metersY, width: mW, height: metersH)
        drawMiniMeter(ctx, rect: inMRect, label: "IN",
                      frac: max(0, min(1, CGFloat((inPeakDB + 60) / 60))),
                      colour: NSColor(calibratedRed: 0.10, green: 0.65, blue: 0.30, alpha: 0.9),
                      anchorBottom: true)
        drawMiniMeter(ctx, rect: grMRect, label: "GR",
                      frac: max(0, min(1, CGFloat(grDB / 20))),
                      colour: accentRed, anchorBottom: false)

        // Undo / redo — top-right, just under the spec tag.
        undoCtl.draw(in: b, ctx: ctx, ink: inkDark, mid: inkMid, pad: 16, y: b.height - 30)
        // SAVE / LOAD named presets — header strip, clear of brand + spec tag
        // (LUFS row + BROADCAST/STREAM plates occupy the area above the knobs).
    }

    private func drawLufsReadout(_ ctx: CGContext, rect r: NSRect, title: String, lufs: Float, gateActive: Bool) {
        // Panel fill
        ctx.setFillColor(panelBg.cgColor); ctx.fill(r); PanelTex.draw(in: r, ctx: ctx)
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.55).cgColor); ctx.setLineWidth(0.6); ctx.stroke(r)
        // Title
        let titleAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 7, weight: .semibold),
            .foregroundColor: inkMid, .kern: 0.6
        ]
        NSString(string: title).draw(at: NSPoint(x: r.minX + 8, y: r.maxY - 13), withAttributes: titleAttr)
        // Big numeric LUFS readout
        let val = lufs <= -119.0
            ? "—"
            : String(format: "%+.1f", Double(lufs))
        let valAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 22, weight: .heavy),
            .foregroundColor: inkDark, .kern: 0.6
        ]
        let vstr = NSString(string: val)
        let vsz  = vstr.size(withAttributes: valAttr)
        vstr.draw(at: NSPoint(x: r.minX + 8, y: r.midY - 14), withAttributes: valAttr)
        // "LUFS" unit, smaller, to the right of the number
        let unitAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 8, weight: .heavy),
            .foregroundColor: inkMid, .kern: 1.0
        ]
        NSString(string: "LUFS").draw(at: NSPoint(x: r.minX + 12 + vsz.width, y: r.midY - 4),
                                       withAttributes: unitAttr)
        if gateActive {
            // Tiny gating-active pip
            ctx.setFillColor(accentRed.cgColor)
            ctx.fillEllipse(in: NSRect(x: r.maxX - 10, y: r.minY + 4, width: 4, height: 4))
        }
    }

    private func drawPresetButton(_ ctx: CGContext, rect r: NSRect, title: String, subtitle: String) {
        // Light preset plate (DESIGN.md §5) — matches Delay/VoiceBox/Compressor.
        // Was a dark near-black gradient that read as two heavy blocks on an
        // otherwise light face; now a soft white plate with a red outline.
        if !ButtonTex.draw(ctx, rect: r, active: false, corner: 4) {
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.6).cgColor); ctx.fill(r)
            ctx.setStrokeColor(accentRed.cgColor); ctx.setLineWidth(1.2); ctx.stroke(r)
        }
        ctx.setFillColor(accentRed.cgColor); ctx.fill(NSRect(x: r.minX + 5, y: r.maxY - 9, width: 4, height: 4))
        let titleAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .heavy),
            .foregroundColor: inkDark, .kern: 1.4
        ]
        let subAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: accentRed, .kern: 0.6
        ]
        let t = NSString(string: title); let ts = t.size(withAttributes: titleAttr)
        let s = NSString(string: subtitle); let ss = s.size(withAttributes: subAttr)
        t.draw(at: NSPoint(x: r.midX - ts.width * 0.5, y: r.midY - 2), withAttributes: titleAttr)
        s.draw(at: NSPoint(x: r.midX - ss.width * 0.5, y: r.midY - ss.height - 4), withAttributes: subAttr)
    }

    private func drawMiniMeter(_ ctx: CGContext, rect r: NSRect, label: String,
                                frac: CGFloat, colour: NSColor, anchorBottom: Bool) {
        ctx.setFillColor(panelBg.cgColor); ctx.fill(r); PanelTex.draw(in: r, ctx: ctx)
        ctx.setStrokeColor(inkDark.withAlphaComponent(0.6).cgColor); ctx.setLineWidth(0.5); ctx.stroke(r)
        let h = r.height * frac
        let fill = anchorBottom
            ? NSRect(x: r.minX, y: r.minY, width: r.width, height: h)
            : NSRect(x: r.minX, y: r.maxY - h, width: r.width, height: h)
        ctx.setFillColor(colour.cgColor); ctx.fill(fill)
        // Label below the meter
        let attr: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 7, weight: .heavy),
            .foregroundColor: inkDark, .kern: 0.7
        ]
        let s = NSString(string: label); let sz = s.size(withAttributes: attr)
        s.draw(at: NSPoint(x: r.midX - sz.width * 0.5, y: r.minY - 11), withAttributes: attr)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if undoCtl.handleClick(p) { needsDisplay = true; return }
        // Recompute the preset rects from live geometry rather than trusting
        // the draw-time copies — guards against stale rects if layout moved the
        // spectrum after the last draw (the preset-click regression).
        let lufsRowY = waveform.frame.minY - 70
        let lufsRowH: CGFloat = 60, presetW: CGFloat = 110, gap: CGFloat = 8
        let bc = NSRect(x: bounds.width - 18 - presetW * 2 - gap, y: lufsRowY, width: presetW, height: lufsRowH)
        let st = NSRect(x: bounds.width - 18 - presetW,           y: lufsRowY, width: presetW, height: lufsRowH)
        if bc.contains(p)         { audioUnit?.applyLoudnessPreset(0); needsDisplay = true; return }
        if st.contains(p)         { audioUnit?.applyLoudnessPreset(1); needsDisplay = true; return }
        if iResetRect.contains(p) { audioUnit?.resetIntegrated();      needsDisplay = true; return }
        super.mouseDown(with: event)
    }

    // MARK: - Param binding

    private func rebind() {
        knobs.forEach { $0.removeFromSuperview() }; knobs.removeAll()
        guard let au = audioUnit, let tree = au.parameterTree else { return }
        waveform.audioUnit = au
        undoCtl.attach(au)
        undoCtl.onChange = { [weak self] in self?.needsDisplay = true }
        for param in tree.allParameters {
            let k = KnobView(frame: .zero)
            k.bind(parameter: param)
            switch param.identifier {
            case "inputGain": k.displayFormatter = { String(format: "%+.1f dB", $0) }
            case "ceiling":   k.displayFormatter = { String(format: "%+.1f dB", $0) }
            case "release":   k.displayFormatter = { String(format: "%.0f ms", $0) }
            default: break
            }
            addSubview(k); knobs.append(k)
        }
        needsLayout = true; needsDisplay = true
    }
}
