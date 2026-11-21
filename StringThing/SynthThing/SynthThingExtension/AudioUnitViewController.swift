import CoreAudioKit

public class AudioUnitViewController: AUViewController, AUAudioUnitFactory {
    public override func loadView() {
        view = SynthThingParameterView(frame: NSRect(x: 0, y: 0, width: 1280, height: 760))
        preferredContentSize = NSSize(width: 1280, height: 760)
    }
    public func createAudioUnit(with d: AudioComponentDescription) throws -> AUAudioUnit {
        let au = try SynthThingAudioUnit(componentDescription: d, options: [])
        DispatchQueue.main.async {
            if let v = self.view as? SynthThingParameterView { v.audioUnit = au }
        }
        return au
    }
}

@objc(SynthThingAudioUnitFactory)
public class SynthThingAudioUnitFactory: NSObject, AUAudioUnitFactory, NSExtensionRequestHandling {
    public func createAudioUnit(with d: AudioComponentDescription) throws -> AUAudioUnit {
        return try SynthThingAudioUnit(componentDescription: d, options: [])
    }
    public func beginRequest(with context: NSExtensionContext) {}
}
