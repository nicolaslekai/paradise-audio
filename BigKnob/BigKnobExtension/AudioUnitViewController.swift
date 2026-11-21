import CoreAudioKit

public class AudioUnitViewController: AUViewController, AUAudioUnitFactory {
    public override func loadView() {
        view = BigKnobParameterView(frame: NSRect(x: 0, y: 0, width: 720, height: 560))
        preferredContentSize = NSSize(width: 720, height: 560)
    }
    public func createAudioUnit(with d: AudioComponentDescription) throws -> AUAudioUnit {
        let au = try BigKnobAudioUnit(componentDescription: d, options: [])
        DispatchQueue.main.async { if let v = self.view as? BigKnobParameterView { v.audioUnit = au } }
        return au
    }
}

@objc(BigKnobAudioUnitFactory)
public class BigKnobAudioUnitFactory: NSObject, AUAudioUnitFactory, NSExtensionRequestHandling {
    public func createAudioUnit(with d: AudioComponentDescription) throws -> AUAudioUnit {
        return try BigKnobAudioUnit(componentDescription: d, options: [])
    }
    public func beginRequest(with context: NSExtensionContext) {}
}
