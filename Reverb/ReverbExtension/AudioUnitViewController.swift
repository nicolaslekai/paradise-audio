import CoreAudioKit

public class AudioUnitViewController: AUViewController, AUAudioUnitFactory {
    public override func loadView() {
        view = ReverbParameterView(frame: NSRect(x: 0, y: 0, width: 880, height: 520))
        preferredContentSize = NSSize(width: 880, height: 520)
    }
    public func createAudioUnit(with d: AudioComponentDescription) throws -> AUAudioUnit {
        let au = try ReverbAudioUnit(componentDescription: d, options: [])
        DispatchQueue.main.async { if let v = self.view as? ReverbParameterView { v.audioUnit = au } }
        return au
    }
}

@objc(ReverbAudioUnitFactory)
public class ReverbAudioUnitFactory: NSObject, AUAudioUnitFactory, NSExtensionRequestHandling {
    public func createAudioUnit(with d: AudioComponentDescription) throws -> AUAudioUnit {
        return try ReverbAudioUnit(componentDescription: d, options: [])
    }
    public func beginRequest(with context: NSExtensionContext) {}
}
