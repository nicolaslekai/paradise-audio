import CoreAudioKit

public class AudioUnitViewController: AUViewController, AUAudioUnitFactory {
    public override func loadView() {
        view = HandyParameterView(frame: NSRect(x: 0, y: 0, width: 920, height: 580))
        preferredContentSize = NSSize(width: 920, height: 580)
    }
    public func createAudioUnit(with d: AudioComponentDescription) throws -> AUAudioUnit {
        let au = try HandyAudioUnit(componentDescription: d, options: [])
        DispatchQueue.main.async { if let v = self.view as? HandyParameterView { v.audioUnit = au } }
        return au
    }
}

@objc(HandyAudioUnitFactory)
public class HandyAudioUnitFactory: NSObject, AUAudioUnitFactory, NSExtensionRequestHandling {
    public func createAudioUnit(with d: AudioComponentDescription) throws -> AUAudioUnit {
        return try HandyAudioUnit(componentDescription: d, options: [])
    }
    public func beginRequest(with context: NSExtensionContext) {}
}
