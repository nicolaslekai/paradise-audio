import CoreAudioKit

public class AudioUnitViewController: AUViewController, AUAudioUnitFactory {
    public override func loadView() {
        view = UltraReverseParameterView(frame: NSRect(x: 0, y: 0, width: 880, height: 520))
        preferredContentSize = NSSize(width: 880, height: 520)
    }
    public func createAudioUnit(with d: AudioComponentDescription) throws -> AUAudioUnit {
        let au = try UltraReverseAudioUnit(componentDescription: d, options: [])
        DispatchQueue.main.async { if let v = self.view as? UltraReverseParameterView { v.audioUnit = au } }
        return au
    }
}

@objc(UltraReverseAudioUnitFactory)
public class UltraReverseAudioUnitFactory: NSObject, AUAudioUnitFactory, NSExtensionRequestHandling {
    public func createAudioUnit(with d: AudioComponentDescription) throws -> AUAudioUnit {
        return try UltraReverseAudioUnit(componentDescription: d, options: [])
    }
    public func beginRequest(with context: NSExtensionContext) {}
}
