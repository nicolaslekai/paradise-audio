//
//  PresetUI.swift — drop-in SAVE / LOAD named-preset buttons for parameter-tree
//  plug-ins. Mirrors ParamUndo's ergonomics.
//
//  Integration (4 lines in a ParameterView):
//     private let presetUI = PresetUI(plugin: "Reverb")
//     …in rebind/didSet:  presetUI.bind(tree: { [weak self] in self?.audioUnit?.parameterTree },
//                                        onLoad: { [weak self] in self?.needsDisplay = true })
//     …in draw():         presetUI.draw(in: bounds, ctx: ctx, ink: inkDark, mid: inkMid, x: 16, y: <y>)
//     …top of mouseDown:  if presetUI.handleClick(p, in: self) { return }
//

import AppKit
import AudioToolbox

final class PresetUI: NSObject {
    private let plugin: String
    private var tree: () -> AUParameterTree? = { nil }
    private var onLoad: () -> Void = {}
    private(set) var saveRect: NSRect = .zero
    private(set) var loadRect: NSRect = .zero

    // Built-in factory presets, shown above the user's saved presets in the
    // LOAD menu. Each is encoded as a parameter blob in the SAME format the
    // on-disk presets use (address-string → value), so they load through the
    // identical TreeState.apply path — no special-casing on apply.
    private var factory: [(name: String, data: Data)] = []

    init(plugin: String) { self.plugin = plugin }

    /// Register factory presets. `values` maps AUParameterAddress → value.
    /// Call once after `bind`, e.g. from the parameter view's rebind().
    func setFactory(_ presets: [(name: String, values: [AUParameterAddress: Float])]) {
        var built: [(name: String, data: Data)] = []
        for preset in presets {
            var dict: [String: Float] = [:]
            for (addr, v) in preset.values { dict[String(addr)] = v }
            let data = (try? JSONEncoder().encode(dict)) ?? Data()
            built.append((name: preset.name, data: data))
        }
        factory = built
    }

    func bind(tree: @escaping () -> AUParameterTree?, onLoad: @escaping () -> Void) {
        self.tree = tree; self.onLoad = onLoad
    }

    func draw(in bounds: NSRect, ctx: CGContext, ink: NSColor, mid: NSColor, x: CGFloat = 16, y: CGFloat? = nil) {
        let bw: CGFloat = 44, bh: CGFloat = 16, gap: CGFloat = 6
        let yy = y ?? (bounds.height - 14 - bh * 0.5)
        saveRect = NSRect(x: x, y: yy, width: bw, height: bh)
        loadRect = NSRect(x: x + bw + gap, y: yy, width: bw, height: bh)
        button(ctx, saveRect, "SAVE", ink)
        button(ctx, loadRect, "LOAD", ink)
    }

    private func button(_ ctx: CGContext, _ r: NSRect, _ label: String, _ col: NSColor) {
        ctx.setStrokeColor(col.withAlphaComponent(0.7).cgColor); ctx.setLineWidth(0.8); ctx.stroke(r)
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                                                .foregroundColor: col, .kern: 0.4]
        let s = NSString(string: label); let sz = s.size(withAttributes: a)
        s.draw(at: NSPoint(x: r.midX - sz.width * 0.5, y: r.midY - sz.height * 0.5 - 0.5), withAttributes: a)
    }

    /// Returns true (and presents the dialog) if a button was clicked.
    func handleClick(_ p: NSPoint, in view: NSView) -> Bool {
        if saveRect.contains(p) { presentSave(view); return true }
        if loadRect.contains(p) { presentLoad(view); return true }
        return false
    }

    private func presentSave(_ view: NSView) {
        let alert = NSAlert()
        alert.messageText = "Save Preset"
        alert.informativeText = "Name this preset. It'll be available in any project."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = "My Preset"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            PresetStore.save(plugin, name: field.stringValue, data: TreeState.data(tree()))
        }
    }

    private func presentLoad(_ view: NSView) {
        let names = PresetStore.list(plugin)
        let menu = NSMenu(title: "Load Preset")

        // ── Factory presets (built-in) ──
        if !factory.isEmpty {
            let header = NSMenuItem(title: "FACTORY", action: nil, keyEquivalent: "")
            header.isEnabled = false; menu.addItem(header)
            for (i, f) in factory.enumerated() {
                let it = NSMenuItem(title: f.name, action: #selector(pickFactory(_:)), keyEquivalent: "")
                it.target = self; it.tag = i; it.indentationLevel = 1; menu.addItem(it)
            }
            menu.addItem(.separator())
        }

        // ── User's saved presets ──
        if names.isEmpty {
            let it = NSMenuItem(title: factory.isEmpty ? "No saved presets yet" : "No saved presets",
                                action: nil, keyEquivalent: "")
            it.isEnabled = false; menu.addItem(it)
        } else {
            if !factory.isEmpty {
                let header = NSMenuItem(title: "SAVED", action: nil, keyEquivalent: "")
                header.isEnabled = false; menu.addItem(header)
            }
            for n in names {
                let it = NSMenuItem(title: n, action: #selector(pick(_:)), keyEquivalent: "")
                it.target = self; it.indentationLevel = factory.isEmpty ? 0 : 1; menu.addItem(it)
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: loadRect.minX, y: loadRect.minY), in: view)
    }

    @objc private func pick(_ sender: NSMenuItem) {
        if let d = PresetStore.load(plugin, name: sender.title) {
            TreeState.apply(d, to: tree())
            onLoad()
        }
    }

    @objc private func pickFactory(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < factory.count else { return }
        TreeState.apply(factory[sender.tag].data, to: tree())
        onLoad()
    }
}
