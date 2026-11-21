// Offline AU view renderer: builds the plug-in's own AudioUnitViewController +
// AUAudioUnit in-process and writes the view to a PNG. No Xcode, no install.
import AppKit
import AudioToolbox
import AVFoundation

let args = CommandLine.arguments
let out = args.count > 1 ? args[1] : "au.png"
let typeStr = args.count > 2 ? args[2] : "aufx"
func fourCC(_ s: String) -> OSType { s.utf8.reduce(0) { ($0 << 8) | OSType($1) } }

_ = NSApplication.shared
let vc = AudioUnitViewController()
let v = vc.view
let desc = AudioComponentDescription(componentType: fourCC(typeStr), componentSubType: fourCC("test"),
                                     componentManufacturer: fourCC("Prds"), componentFlags: 0, componentFlagsMask: 0)
var au: AUAudioUnit? = nil
do { au = try vc.createAudioUnit(with: desc) } catch { print("createAudioUnit failed: \(error)") }
if args.count > 3, let m = Float(args[3]) { au?.parameterTree?.parameter(withAddress: 9)?.value = m }
if args.count > 4, let s = Float(args[4]) { au?.parameterTree?.parameter(withAddress: 10)?.value = s }
// extra "addr=value" pairs, and "feed" = run a test drum loop through the unit so the live lane has signal
var feed = false
for a in args.dropFirst(5) {
    if a == "feed" { feed = true; continue }
    let kv = a.split(separator: "="); if kv.count == 2, let k = UInt64(kv[0]), let v = Float(kv[1]) {
        au?.parameterTree?.parameter(withAddress: k)?.value = v
    }
}
if feed, let au = au {
    let sr = 48000.0, frames: AVAudioFrameCount = 512
    let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
    try? au.inputBusses[0].setFormat(fmt); try? au.outputBusses[0].setFormat(fmt)
    au.maximumFramesToRender = frames
    do { try au.allocateRenderResources() } catch { print("alloc failed \(error)") }
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!; buf.frameLength = frames
    var n = 0; var seed: UInt32 = 1
    func src(_ i: Int) -> Float {          // kick + snare-ish loop at 120 bpm
        let beat = Int(sr * 0.5), p = i % beat, t = Double(p) / sr, which = (i / beat) % 2
        seed = seed &* 1664525 &+ 1013904223
        let noise = Float(Int32(bitPattern: seed)) / Float(Int32.max)
        if which == 0 { return Float(sin(2 * .pi * (50 + 120 * exp(-t * 30)) * t) * exp(-t * 7)) * 0.9 }
        return noise * Float(exp(-t * 14)) * 0.6
    }
    let pull: AURenderPullInputBlock = { _, _, fc, _, abl in
        let l = UnsafeMutableAudioBufferListPointer(abl)
        for f in 0..<Int(fc) { let v = src(n + f); for b in l { b.mData!.assumingMemoryBound(to: Float.self)[f] = v } }
        return noErr
    }
    let block = au.renderBlock
    for _ in 0..<Int(sr * 2.3) / Int(frames) {
        var flags = AudioUnitRenderActionFlags(); var ts = AudioTimeStamp(); ts.mSampleTime = Double(n); ts.mFlags = .sampleTimeValid
        let l = UnsafeMutableAudioBufferListPointer(buf.mutableAudioBufferList)
        for i in 0..<l.count { l[i].mData = nil }
        let st = block(&flags, &ts, frames, 0, buf.mutableAudioBufferList, pull)
        if n == 0 { print("render status", st) }
        n += Int(frames)
    }
    if let u = au as? UltraReverseAudioUnit {
        var d = [Float](repeating: 0, count: 256), w = [Float](repeating: 0, count: 256)
        _ = u.readProbeDry(&d, wet: &w, count: 256); print("probe max dry", d.max() ?? 0, "wet", w.max() ?? 0)
    }
}
RunLoop.main.run(until: Date().addingTimeInterval(0.6))
let win = NSWindow(contentRect: v.frame, styleMask: [.borderless], backing: .buffered, defer: false)
win.contentView = v
v.layoutSubtreeIfNeeded(); v.needsDisplay = true
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
let scale: CGFloat = 2
let W = v.bounds.width, H = v.bounds.height
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
rep.size = NSSize(width: W, height: H)
v.cacheDisplay(in: v.bounds, to: rep)
if ProcessInfo.processInfo.environment["BENCH"] != nil, let viz = v.subviews.first(where: { String(describing: type(of: $0)) == "ReverseBloomView" }) {
    let r2 = viz.bitmapImageRepForCachingDisplay(in: viz.bounds)!
    let t0 = Date(); for _ in 0..<100 { viz.cacheDisplay(in: viz.bounds, to: r2) }
    print(String(format: "BENCH display draw %.2f ms/frame (2x)", Date().timeIntervalSince(t0) * 10))
}
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out) \(Int(W))x\(Int(H))")
exit(0)
