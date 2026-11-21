import CoreAudioKit
import AppKit

public class AudioUnitViewController: AUViewController, AUAudioUnitFactory {
    /// Set by createAudioUnit; hands the audio unit to the editor once it exists.
    private var connectView: (() -> Void)?

    // The size is known without building the view, so a host can ask for it early.
    public override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        preferredContentSize = NSSize(width: 880, height: 520)
    }
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        preferredContentSize = NSSize(width: 880, height: 520)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        connectView?()
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
        view = UltraReverseParameterView(frame: NSRect(x: 0, y: 0, width: 880, height: 520))
        preferredContentSize = NSSize(width: 880, height: 520)
    }
    public func createAudioUnit(with d: AudioComponentDescription) throws -> AUAudioUnit {
        let au = try UltraReverseAudioUnit(componentDescription: d, options: [])
        // The editor is NOT touched here. This used to read `self.view`, which
        // built the whole editor (and let it draw) in every host as soon as the
        // AU existed — also in hosts that never show it. In a host without a GUI
        // session the first text draw then threw inside CoreText and took the
        // extension process, and with it the render, down (Compressor / Limiter /
        // Bass mit Stimme crash logs of 2026-11-21). The editor now connects when
        // — and only if — a host asks for the view.
        DispatchQueue.main.async {
            self.connectView = { [weak self] in
                if let v = self?.view as? UltraReverseParameterView { v.audioUnit = au }
            }
            if self.isViewLoaded { self.connectView?() }
        }
        return au
    }
}

@objc(UltraReverseAudioUnitFactory)
public class UltraReverseAudioUnitFactory: NSObject, AUAudioUnitFactory, NSExtensionRequestHandling {
    public func createAudioUnit(with d: AudioComponentDescription) throws -> AUAudioUnit {
        return try UltraReverseAudioUnit(componentDescription: d, options: [])
    }
    public func beginRequest(with context: NSExtensionContext) {}
}
