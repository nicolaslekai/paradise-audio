import Cocoa
@main
class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        let r = NSRect(x: 0, y: 0, width: 460, height: 200)
        window = NSWindow(contentRect: r, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Synth Thing"; window.center()
        window.contentView = HostInfoView(frame: r); window.makeKeyAndOrderFront(nil)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}
final class HostInfoView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.82, green: 0.79, blue: 0.74, alpha: 1.0).cgColor
        let l = NSTextField(labelWithString: "Synth Thing AUv3 installed.\n\nLogic ▸ AU Instruments ▸ Paradise Audio ▸ Synth Thing.")
        l.translatesAutoresizingMaskIntoConstraints = false; l.alignment = .center
        l.font = NSFont.systemFont(ofSize: 13); l.textColor = NSColor(calibratedWhite: 0.12, alpha: 1)
        addSubview(l)
        NSLayoutConstraint.activate([l.centerXAnchor.constraint(equalTo: centerXAnchor), l.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
}
