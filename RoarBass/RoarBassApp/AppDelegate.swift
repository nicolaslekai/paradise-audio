//
//  AppDelegate.swift
//  RoarBassApp
//
//  Minimal AppKit host. AUv3 ships inside an app bundle on macOS.
//  This window just confirms install and shows a quick path to use the AU.
//

import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let rect = NSRect(x: 100, y: 100, width: 540, height: 320)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "RoarBass"
        window.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.08, alpha: 1.0)

        let title = NSTextField(labelWithString: "ROAR")
        title.font = NSFont.systemFont(ofSize: 32, weight: .heavy)
        title.textColor = NSColor(calibratedRed: 1.0, green: 0.55, blue: 0.10, alpha: 1.0)
        title.frame = NSRect(x: 30, y: 240, width: 480, height: 42)

        let sub = NSTextField(labelWithString: "deep bass synth · AUv3")
        sub.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        sub.textColor = NSColor(calibratedWhite: 0.65, alpha: 1.0)
        sub.frame = NSRect(x: 30, y: 215, width: 480, height: 18)

        let body = NSTextField(wrappingLabelWithString: """
        The RoarBass Audio Unit is installed. To use it:

        1.  Open Logic Pro.
        2.  Create an instrument track.
        3.  Choose AU Instruments ▸ Anthropic ▸ RoarBass.

        Logic will scan and validate the plug-in on first launch.
        If it doesn't appear, run “auval -v aumu Roar Anth” in Terminal
        to see the validation log.
        """)
        body.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        body.textColor = NSColor(calibratedWhite: 0.78, alpha: 1.0)
        body.frame = NSRect(x: 30, y: 30, width: 480, height: 175)

        let cv = window.contentView!
        cv.addSubview(title)
        cv.addSubview(sub)
        cv.addSubview(body)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
