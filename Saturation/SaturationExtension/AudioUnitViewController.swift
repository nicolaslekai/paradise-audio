import CoreAudioKit

public class AudioUnitViewController: AUViewController, AUAudioUnitFactory {
    public override func loadView() {
        view = SaturationParameterView(frame: NSRect(x: 0, y: 0, width: 880, height: 520))
        preferredContentSize = NSSize(width: 880, height: 520)
    }
    public func createAudioUnit(with d: AudioComponentDescription) throws -> AUAudioUnit {
        let au = try SaturationAudioUnit(componentDescription: d, options: [])
        DispatchQueue.main.async { if let v = self.view as? SaturationParameterView { v.audioUnit = au } }
        return au
    }
}

@objc(SaturationAudioUnitFactory)
public class SaturationAudioUnitFactory: NSObject, AUAudioUnitFactory, NSExtensionRequestHandling {
    public func createAudioUnit(with d: AudioComponentDescription) throws -> AUAudioUnit {
        return try SaturationAudioUnit(componentDescription: d, options: [])
    }
    public func beginRequest(with context: NSExtensionContext) {}
}
