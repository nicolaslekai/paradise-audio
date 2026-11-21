import CoreAudioKit

public class AudioUnitViewController: AUViewController, AUAudioUnitFactory {
    public override func loadView() {
        view = DelayParameterView(frame: NSRect(x: 0, y: 0, width: 1100, height: 660))
        preferredContentSize = NSSize(width: 1100, height: 660)
    }
    public func createAudioUnit(with d: AudioComponentDescription) throws -> AUAudioUnit {
        let au = try DelayAudioUnit(componentDescription: d, options: [])
        DispatchQueue.main.async { if let v = self.view as? DelayParameterView { v.audioUnit = au } }
        return au
    }
}

@objc(DelayAudioUnitFactory)
public class DelayAudioUnitFactory: NSObject, AUAudioUnitFactory, NSExtensionRequestHandling {
    public func createAudioUnit(with d: AudioComponentDescription) throws -> AUAudioUnit {
        return try DelayAudioUnit(componentDescription: d, options: [])
    }
    public func beginRequest(with context: NSExtensionContext) {}
}
