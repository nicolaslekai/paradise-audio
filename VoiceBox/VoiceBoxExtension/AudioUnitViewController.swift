import CoreAudioKit

public class AudioUnitViewController: AUViewController, AUAudioUnitFactory {
    public override func loadView() {
        let size = VoiceBoxParameterView.preferredSize      // 960 × 460 (redesign 2026-11-21, was 900 × 720)
        view = VoiceBoxParameterView(frame: NSRect(origin: .zero, size: size))
        preferredContentSize = size
    }
    public func createAudioUnit(with d: AudioComponentDescription) throws -> AUAudioUnit {
        let au = try VoiceBoxAudioUnit(componentDescription: d, options: [])
        DispatchQueue.main.async { if let v = self.view as? VoiceBoxParameterView { v.audioUnit = au } }
        return au
    }
}

@objc(VoiceBoxAudioUnitFactory)
public class VoiceBoxAudioUnitFactory: NSObject, AUAudioUnitFactory, NSExtensionRequestHandling {
    public func createAudioUnit(with d: AudioComponentDescription) throws -> AUAudioUnit {
        return try VoiceBoxAudioUnit(componentDescription: d, options: [])
    }
    public func beginRequest(with context: NSExtensionContext) {}
}
