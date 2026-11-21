//
//  AudioUnitViewController.swift
//

import CoreAudioKit

public class AudioUnitViewController: AUViewController, AUAudioUnitFactory {

    public override func loadView() {
        view = CompressorParameterView(frame: NSRect(x: 0, y: 0, width: 1100, height: 660))
        preferredContentSize = NSSize(width: 1100, height: 660)
    }

    public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        let au = try CompressorAudioUnit(componentDescription: componentDescription, options: [])
        DispatchQueue.main.async {
            if let v = self.view as? CompressorParameterView { v.audioUnit = au }
        }
        return au
    }
}

@objc(CompressorAudioUnitFactory)
public class CompressorAudioUnitFactory: NSObject, AUAudioUnitFactory, NSExtensionRequestHandling {
    public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        return try CompressorAudioUnit(componentDescription: componentDescription, options: [])
    }
    public func beginRequest(with context: NSExtensionContext) {}
}
