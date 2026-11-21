//
//  AudioUnitViewController.swift
//
import CoreAudioKit

public class AudioUnitViewController: AUViewController, AUAudioUnitFactory {
    public override func loadView() {
        view = LimiterParameterView(frame: NSRect(x: 0, y: 0, width: 720, height: 440))
        preferredContentSize = NSSize(width: 720, height: 440)
    }
    public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        let au = try LimiterAudioUnit(componentDescription: componentDescription, options: [])
        DispatchQueue.main.async {
            if let v = self.view as? LimiterParameterView { v.audioUnit = au }
        }
        return au
    }
}

@objc(LimiterAudioUnitFactory)
public class LimiterAudioUnitFactory: NSObject, AUAudioUnitFactory, NSExtensionRequestHandling {
    public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        return try LimiterAudioUnit(componentDescription: componentDescription, options: [])
    }
    public func beginRequest(with context: NSExtensionContext) {}
}
