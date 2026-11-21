import CoreAudioKit

public class AudioUnitViewController: AUViewController, AUAudioUnitFactory {
    public override func loadView() {
        view = DeesserParameterView(frame: NSRect(x: 0, y: 0, width: 880, height: 520))
        preferredContentSize = NSSize(width: 880, height: 520)
    }
    public func createAudioUnit(with d: AudioComponentDescription) throws -> AUAudioUnit {
        let au = try DeesserAudioUnit(componentDescription: d, options: [])
        DispatchQueue.main.async { if let v = self.view as? DeesserParameterView { v.audioUnit = au } }
        return au
    }
}

@objc(DeesserAudioUnitFactory)
public class DeesserAudioUnitFactory: NSObject, AUAudioUnitFactory, NSExtensionRequestHandling {
    public func createAudioUnit(with d: AudioComponentDescription) throws -> AUAudioUnit {
        return try DeesserAudioUnit(componentDescription: d, options: [])
    }
    public func beginRequest(with context: NSExtensionContext) {}
}
