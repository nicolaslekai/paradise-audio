import CoreAudioKit

public class AudioUnitViewController: AUViewController, AUAudioUnitFactory {
    public override func loadView() {
        view = DrumsParameterView(frame: NSRect(x: 0, y: 0, width: 1280, height: 660))
        preferredContentSize = NSSize(width: 1280, height: 660)
    }
    public func createAudioUnit(with d: AudioComponentDescription) throws -> AUAudioUnit {
        let au = try DrumsAudioUnit(componentDescription: d, options: [])
        DispatchQueue.main.async { if let v = self.view as? DrumsParameterView { v.audioUnit = au } }
        return au
    }
}

@objc(DrumsAudioUnitFactory)
public class DrumsAudioUnitFactory: NSObject, AUAudioUnitFactory, NSExtensionRequestHandling {
    public func createAudioUnit(with d: AudioComponentDescription) throws -> AUAudioUnit {
        return try DrumsAudioUnit(componentDescription: d, options: [])
    }
    public func beginRequest(with context: NSExtensionContext) {}
}
