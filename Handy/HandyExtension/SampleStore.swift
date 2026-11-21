//
//  SampleStore.swift
//
//  Loads audio files (MP3, AAC, M4A, OGG, WAV, AIFF — anything AVAudioFile
//  can decode) and hands the resulting mono Float32 buffer to the AU.
//  Files are loaded at the AU's current sample rate so no playback resample
//  is needed.
//
//  Also keeps a small recents list (per process) for the right-click menu.
//

import AVFoundation
import AppKit
import UniformTypeIdentifiers

final class SampleStore {

    // MARK: - Recents (process-wide, no persistence)
    private static var _recents: [URL] = []
    private static let recentsCap = 24

    static var recents: [URL] { return _recents }

    // MARK: - Waveform peaks (per zone, for the ZoneBoxView display)
    // Downsampled mirrored peak envelope of the last sample loaded into each
    // zone. The UI reads this to draw the waveform; it is NOT used for audio.
    private static var _peaks: [Int: [Float]] = [:]
    static func peaks(for zone: Int) -> [Float] { _peaks[zone] ?? [] }
    static func clearPeaks(for zone: Int) { _peaks[zone] = nil }
    static func setPeaks(_ p: [Float], for zone: Int) { _peaks[zone] = p }

    /// Reduce a mono buffer to `bins` peak values (max |sample| per bin), 0..1.
    static func computePeaks(_ data: [Float], bins: Int = 240) -> [Float] {
        guard data.count > 1, bins > 1 else { return [] }
        var out = [Float](repeating: 0, count: bins)
        let per = Double(data.count) / Double(bins)
        var peak: Float = 0
        for b in 0..<bins {
            let lo = Int(Double(b) * per)
            let hi = min(data.count, Int(Double(b + 1) * per))
            var m: Float = 0
            var i = lo
            while i < hi { let a = abs(data[i]); if a > m { m = a }; i += 1 }
            out[b] = m
            if m > peak { peak = m }
        }
        if peak > 0.0001 { for i in 0..<bins { out[i] /= peak } }   // normalise to 1.0
        return out
    }

    static func addRecent(_ url: URL) {
        _recents.removeAll { $0 == url }
        _recents.insert(url, at: 0)
        if _recents.count > recentsCap { _recents = Array(_recents.prefix(recentsCap)) }
    }

    // MARK: - Core load

    static func load(url: URL, targetSampleRate: Double) -> (data: [Float], name: String)? {
        let _ = url.startAccessingSecurityScopedResource()
        defer { url.stopAccessingSecurityScopedResource() }

        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let srcFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else { return nil }
        do { try file.read(into: srcBuf) } catch { return nil }

        // Convert to mono Float32 @ targetSampleRate.
        guard let dstFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: targetSampleRate,
                                            channels: 1,
                                            interleaved: false) else { return nil }
        guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else { return nil }

        let ratio = targetSampleRate / srcFormat.sampleRate
        let dstFrames = AVAudioFrameCount(Double(srcBuf.frameLength) * ratio + 256)
        guard let dstBuf = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: dstFrames) else { return nil }

        var done = false
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if done { status.pointee = .noDataNow; return nil }
            done = true
            status.pointee = .haveData
            return srcBuf
        }
        var err: NSError?
        _ = converter.convert(to: dstBuf, error: &err, withInputFrom: inputBlock)
        if err != nil { return nil }

        guard let chans = dstBuf.floatChannelData else { return nil }
        let n = Int(dstBuf.frameLength)
        var out = [Float](repeating: 0, count: n)
        memcpy(&out, chans[0], MemoryLayout<Float>.size * n)

        return (out, url.lastPathComponent)
    }

    /// Load a specific URL into the given pad (used for drag-drop and recents).
    @discardableResult
    static func loadFile(url: URL, into audioUnit: HandyAudioUnit, pad: Int) -> Bool {
        let sr = 48000.0
        guard let result = load(url: url, targetSampleRate: sr) else {
            NSSound.beep(); return false
        }
        var ok = false
        result.data.withUnsafeBufferPointer { p in
            guard let addr = p.baseAddress else { return }
            audioUnit.setSamplePad(pad, data: addr, length: result.data.count, name: result.name)
            ok = true
        }
        if ok {
            addRecent(url)
            _peaks[pad] = computePeaks(result.data)   // cache waveform for the zone box
        }
        return ok
    }

    /// Open an NSOpenPanel and load into the given pad of the audio unit.
    static func openAndLoad(into audioUnit: HandyAudioUnit, pad: Int) {
        let panel = NSOpenPanel()
        // Accept every audio type the system knows about (plus a couple of
        // codecs that report as their own UTType) rather than a fixed list.
        var types: [UTType] = [.audio]
        for id in ["org.xiph.flac", "org.xiph.ogg", "public.opus", "org.xiph.opus"] {
            if let t = UTType(id) { types.append(t) }
        }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = loadFile(url: url, into: audioUnit, pad: pad)
    }
}
