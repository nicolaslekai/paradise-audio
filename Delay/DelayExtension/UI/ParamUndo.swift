//
//  ParamUndo.swift — Paradise Audio shared 10-step undo/redo for parameter-tree
//  plug-ins. Drop-in: works for any AUAudioUnit whose editable state lives in an
//  AUParameterTree (every Paradise FX plug-in).
//
//  How it works: we observe the parameter tree. Any change (knob drag, preset,
//  toggle, …) is debounced ~0.35 s and coalesced into ONE undo step, so a whole
//  knob sweep is a single undo. `committed` always holds the last settled state,
//  so we never need the pre-edit value up front. Our own undo/redo writes pass
//  the observer token as originator (and set an `applying` guard) so they don't
//  re-enter as new edits.
//
//  Integration (3 lines in a ParameterView):
//    private let undoCtl = ParamUndo()
//    …in rebind/didSet:  undoCtl.attach(au); undoCtl.onChange = { [weak self] in self?.needsDisplay = true }
//    …in draw():         undoCtl.draw(in: bounds, ctx: ctx, ink: inkDark, mid: inkMid)
//    …top of mouseDown:  if undoCtl.handleClick(p) { needsDisplay = true; return }
//

import AppKit
import AudioToolbox

final class ParamUndo {
    private var undo: [[AUParameterAddress: AUValue]] = []
    private var redo: [[AUParameterAddress: AUValue]] = []
    private var committed: [AUParameterAddress: AUValue] = [:]
    private weak var tree: AUParameterTree?
    private var token: AUParameterObserverToken?
    private var debounce: Timer?
    private var applying = false
    private let limit = 10

    /// Called on the main thread whenever the undo/redo state changes, so the
    /// host view can redraw the buttons / reflect restored values.
    var onChange: (() -> Void)?

    // Button hit rects, populated by draw().
    private(set) var undoRect: NSRect = .zero
    private(set) var redoRect: NSRect = .zero

    deinit { detach() }

    func attach(_ au: AUAudioUnit?) {
        detach()
        guard let t = au?.parameterTree else { return }
        tree = t
        committed = snapshot()
        token = t.token(byAddingParameterObserver: { [weak self] _, _ in
            self?.scheduleCommit()
        })
    }

    func detach() {
        if let t = token, let tr = tree { tr.removeParameterObserver(t) }
        token = nil
        debounce?.invalidate(); debounce = nil
    }

    private func snapshot() -> [AUParameterAddress: AUValue] {
        guard let t = tree else { return [:] }
        var d: [AUParameterAddress: AUValue] = [:]
        for p in t.allParameters { d[p.address] = p.value }
        return d
    }

    private func scheduleCommit() {
        if applying { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.debounce?.invalidate()
            self.debounce = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
                self?.commitNow()
            }
        }
    }

    private func commitNow() {
        let now = snapshot()
        if now != committed {
            undo.append(committed)
            if undo.count > limit { undo.removeFirst() }
            redo.removeAll()
            committed = now
            onChange?()
        }
    }

    private func apply(_ s: [AUParameterAddress: AUValue]) {
        guard let t = tree else { return }
        applying = true
        for (a, v) in s { t.parameter(withAddress: a)?.setValue(v, originator: token) }
        committed = s
        applying = false
        onChange?()
    }

    var canUndo: Bool { !undo.isEmpty }
    var canRedo: Bool { !redo.isEmpty }

    func performUndo() { guard let pre = undo.popLast() else { return }; redo.append(committed); apply(pre) }
    func performRedo() { guard let nx = redo.popLast() else { return }; undo.append(committed); apply(nx) }

    /// Hit-test the buttons. Returns true (and performs the action) on a hit.
    func handleClick(_ p: NSPoint) -> Bool {
        if undoRect.contains(p) { performUndo(); return true }
        if redoRect.contains(p) { performRedo(); return true }
        return false
    }

    /// Draw the ↶ / ↷ buttons. By default they sit at the top-right of `bounds`;
    /// pass `y`/`pad` to place them elsewhere (e.g. inside a top bar).
    func draw(in bounds: NSRect, ctx: CGContext, ink: NSColor, mid: NSColor,
              pad: CGFloat = 16, y: CGFloat? = nil) {
        let bw: CGFloat = 26, bh: CGFloat = 16, gap: CGFloat = 6
        let yy = y ?? (bounds.height - 14 - bh * 0.5)
        let rX = bounds.width - pad - bw
        let uX = rX - gap - bw
        undoRect = NSRect(x: uX, y: yy, width: bw, height: bh)
        redoRect = NSRect(x: rX, y: yy, width: bw, height: bh)
        button(ctx, undoRect, "↶", canUndo ? ink : mid.withAlphaComponent(0.4))
        button(ctx, redoRect, "↷", canRedo ? ink : mid.withAlphaComponent(0.4))
    }

    private func button(_ ctx: CGContext, _ r: NSRect, _ label: String, _ col: NSColor) {
        ctx.setStrokeColor(col.withAlphaComponent(0.7).cgColor); ctx.setLineWidth(0.8); ctx.stroke(r)
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                                                .foregroundColor: col]
        let s = NSString(string: label); let sz = s.size(withAttributes: a)
        s.draw(at: NSPoint(x: r.midX - sz.width * 0.5, y: r.midY - sz.height * 0.5 - 0.5), withAttributes: a)
    }
}
