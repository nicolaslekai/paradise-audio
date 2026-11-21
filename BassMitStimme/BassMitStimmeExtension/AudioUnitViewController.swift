import CoreAudioKit

public class AudioUnitViewController: AUViewController, AUAudioUnitFactory {
    public override func loadView() {
        view = BMSParameterView(frame: NSRect(x: 0, y: 0, width: 920, height: 720))
        preferredContentSize = NSSize(width: 920, height: 720)
    }
    public func createAudioUnit(with d: AudioComponentDescription) throws -> AUAudioUnit {
        let au = try BMSAudioUnit(componentDescription: d, options: [])
        DispatchQueue.main.async { if let v = self.view as? BMSParameterView { v.audioUnit = au } }
        return au
    }
}

@objc(BMSAudioUnitFactory)
public class BMSAudioUnitFactory: NSObject, AUAudioUnitFactory, NSExtensionRequestHandling {
    public func createAudioUnit(with d: AudioComponentDescription) throws -> AUAudioUnit {
        return try BMSAudioUnit(componentDescription: d, options: [])
    }
    public func beginRequest(with context: NSExtensionContext) {}
}
