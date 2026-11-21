//
//  AppDelegate.swift
//  LimiterApp — minimal host shell so the embedded AUv3 registers via
//  Launch Services on first launch.
//

import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let rect = NSRect(x: 0, y: 0, width: 460, height: 200)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Limiter"
        window.center()
        window.contentView = HostInfoView(frame: rect)
        window.makeKeyAndOrderFront(nil)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

final class HostInfoView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.82, green: 0.79, blue: 0.74, alpha: 1.0).cgColor
        let label = NSTextField(labelWithString:
            "Limiter AUv3 installed.\n\nQuit this app and look for it in\nLogic ▸ AU Effects ▸ Paradise Audio ▸ Limiter.")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        label.textColor = NSColor(calibratedWhite: 0.12, alpha: 1.0)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
}
