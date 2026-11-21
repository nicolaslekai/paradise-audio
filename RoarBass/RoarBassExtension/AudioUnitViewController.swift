//
//  AudioUnitViewController.swift
//  RoarBassExtension
//
//  Entry point the host calls to instantiate the AU and (optionally) the view.
//

import CoreAudioKit
import AudioToolbox
import AppKit

public class AudioUnitViewController: AUViewController, AUAudioUnitFactory {

    var audioUnit: AUAudioUnit?
    private weak var paramView: RoarBassParameterView?

    public override func viewDidLoad() {
        super.viewDidLoad()
        // Use a sensible default size; Logic respects this.
        if preferredContentSize == .zero {
            preferredContentSize = NSSize(width: 1000, height: 440)
        }
        installViewIfReady()
        watchEditorVisibility()
    }

    // ── No drawing unless a host actually shows the editor ─────────────────
    // The system builds this view controller's view inside the extension as soon
    // as the audio unit is instantiated — in EVERY host, whether or not it ever
    // asks for the editor — and parks it in a window that is not visible. The
    // views in there used to draw anyway (meters at 30 Hz), which is wasted CPU
    // for every instance whose plug-in window is closed, and in a host without a
    // GUI session a text draw can throw inside CoreText and take the extension
    // process down with the render (Compressor / Limiter / Bass mit Stimme crash
    // logs of 2026-11-21). So: the root view stays hidden — AppKit then draws
    // none of it — until its window is really on screen.
    private var visibilityObserver: NSObjectProtocol?
    private func syncEditorVisibility() {
        guard isViewLoaded, Bundle.main.bundleURL.pathExtension == "appex" else { return }
        let shown = view.window?.isVisible ?? false
        if view.isHidden == shown { view.isHidden = !shown }
    }
    private func watchEditorVisibility() {
        // Only inside the real extension. The offline tools (Tools/au_offline,
        // UltraReverse/tests/ui_render) compile this class into a plain program
        // and render the view without ever putting a window on screen.
        guard Bundle.main.bundleURL.pathExtension == "appex" else { return }
        view.isHidden = true
        visibilityObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] n in
                guard let self, self.isViewLoaded, (n.object as? NSWindow) === self.view.window else { return }
                self.syncEditorVisibility()
        }
        // Belt and braces: whatever notification a host does or does not cause,
        // the editor is unhidden within half a second of its window showing.
        visibilityTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.syncEditorVisibility()
        }
        DispatchQueue.main.async { [weak self] in self?.syncEditorVisibility() }
    }
    private var visibilityTimer: Timer?
    public override func viewWillAppear() { super.viewWillAppear(); syncEditorVisibility() }
    public override func viewDidAppear()  { super.viewDidAppear();  syncEditorVisibility() }
    public override func viewDidDisappear() { super.viewDidDisappear(); syncEditorVisibility() }
    deinit {
        visibilityTimer?.invalidate()
        if let o = visibilityObserver { NotificationCenter.default.removeObserver(o) }
    }

    public override func loadView() {
        // Provide our custom dark panel.
        let v = RoarBassParameterView(frame: NSRect(x: 0, y: 0, width: 1000, height: 440))
        self.view = v
        self.paramView = v
    }

    public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        let au = try RoarBassAudioUnit(componentDescription: componentDescription, options: [])
        self.audioUnit = au
        DispatchQueue.main.async { [weak self] in
            self?.installViewIfReady()
        }
        return au
    }

    private func installViewIfReady() {
        guard let au = audioUnit, let v = paramView else { return }
        v.bind(to: au)
    }
}
