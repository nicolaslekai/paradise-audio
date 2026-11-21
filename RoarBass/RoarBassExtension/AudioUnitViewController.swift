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
