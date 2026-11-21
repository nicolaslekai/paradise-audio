import CoreAudioKit

public class AudioUnitViewController: AUViewController, AUAudioUnitFactory {
    public override func loadView() {
        view = PitchKnobParameterView(frame: NSRect(x: 0, y: 0, width: 720, height: 560))
        preferredContentSize = NSSize(width: 720, height: 560)
    }
    public func createAudioUnit(with d: AudioComponentDescription) throws -> AUAudioUnit {
        let au = try PitchKnobAudioUnit(componentDescription: d, options: [])
        DispatchQueue.main.async { if let v = self.view as? PitchKnobParameterView { v.audioUnit = au } }
        return au
    }
}

@objc(PitchKnobAudioUnitFactory)
public class PitchKnobAudioUnitFactory: NSObject, AUAudioUnitFactory, NSExtensionRequestHandling {
    public func createAudioUnit(with d: AudioComponentDescription) throws -> AUAudioUnit {
        return try PitchKnobAudioUnit(componentDescription: d, options: [])
    }
    public func beginRequest(with context: NSExtensionContext) {}
}
