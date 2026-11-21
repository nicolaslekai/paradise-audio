import CoreAudioKit

public class AudioUnitViewController: AUViewController, AUAudioUnitFactory {
    public override func loadView() {
        view = StringThingParameterView(frame: NSRect(x: 0, y: 0, width: 1280, height: 760))
        preferredContentSize = NSSize(width: 1280, height: 760)
    }
    public func createAudioUnit(with d: AudioComponentDescription) throws -> AUAudioUnit {
        let au = try StringThingAudioUnit(componentDescription: d, options: [])
        DispatchQueue.main.async {
            if let v = self.view as? StringThingParameterView { v.audioUnit = au }
        }
        return au
    }
}

@objc(StringThingAudioUnitFactory)
public class StringThingAudioUnitFactory: NSObject, AUAudioUnitFactory, NSExtensionRequestHandling {
    public func createAudioUnit(with d: AudioComponentDescription) throws -> AUAudioUnit {
        return try StringThingAudioUnit(componentDescription: d, options: [])
    }
    public func beginRequest(with context: NSExtensionContext) {}
}
