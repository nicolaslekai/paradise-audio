// Offline VoiceBox render WITH a synthetic sung voice fed through the AU, so the
// voice strip (head, spectrum, pitch readout) shows live data. args: out.png [addr=value ...]
import AppKit
import AudioToolbox
import AVFoundation

let args = CommandLine.arguments
let out = args.count > 1 ? args[1] : "au.png"
func fourCC(_ s: String) -> OSType { s.utf8.reduce(0) { ($0 << 8) | OSType($1) } }
_ = NSApplication.shared
let vc = AudioUnitViewController()
let v = vc.view
let desc = AudioComponentDescription(componentType: fourCC("aufx"), componentSubType: fourCC("test"),
                                     componentManufacturer: fourCC("Prds"), componentFlags: 0, componentFlagsMask: 0)
let au = try! vc.createAudioUnit(with: desc)
RunLoop.main.run(until: Date().addingTimeInterval(0.4))
for a in args.dropFirst(2) {
    let kv = a.split(separator: "=")
    if kv.count == 2, let addr = UInt64(kv[0]), let val = Float(kv[1]) { au.parameterTree?.parameter(withAddress: addr)?.setValue(val, originator: nil) }
}
try! au.allocateRenderResources()
let win = NSWindow(contentRect: v.frame, styleMask: [.borderless], backing: .buffered, defer: false)
win.contentView = v
v.layoutSubtreeIfNeeded(); v.needsDisplay = true
let sr = 48000.0, blk: AVAudioFrameCount = 400
let abl = AudioBufferList.allocate(maximumBuffers: 2)
let bufL = UnsafeMutablePointer<Float>.allocate(capacity: Int(blk)), bufR = UnsafeMutablePointer<Float>.allocate(capacity: Int(blk))
var n = 0
// Sung voice: glottal-ish saw at G3 + 35 cents sharp, 5.5 Hz vibrato, formant-ish tilt, syllable envelope.
var ph = 0.0, lp1 = 0.0, lp2 = 0.0
func sample() -> Float {
    let t = Double(n) / sr
    let f = 196.0 * pow(2, (35 + 25 * sin(2 * .pi * 5.5 * t)) / 1200)
    ph += f / sr; if ph >= 1 { ph -= 1 }
    let saw = 2 * ph - 1
    lp1 += 0.25 * (saw - lp1); lp2 += 0.5 * (lp1 - lp2)
    let env = 0.35 + 0.15 * sin(2 * .pi * 1.3 * t)
    n += 1
    return Float((lp2 * 0.7 + saw * 0.15) * env)
}
let pull: AURenderPullInputBlock = { _, _, frames, _, list in
    let l = UnsafeMutableAudioBufferListPointer(list)
    for i in 0..<Int(frames) {
        let s = sample()
        for b in 0..<l.count { l[b].mData!.assumingMemoryBound(to: Float.self)[i] = s }
    }
    return noErr
}
let render = au.renderBlock
var ts = AudioTimeStamp(); ts.mFlags = .sampleTimeValid
for _ in 0..<75 {          // 2.5 s of audio interleaved with UI frames
    for _ in 0..<4 {
        abl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: blk * 4, mData: bufL)
        abl[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: blk * 4, mData: bufR)
        var flags = AudioUnitRenderActionFlags()
        _ = render(&flags, &ts, blk, 0, abl.unsafeMutablePointer, pull)
        ts.mSampleTime += Double(blk)
    }
    RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 30.0))
}
let scale: CGFloat = 2
let W = v.bounds.width, H = v.bounds.height
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
v.cacheDisplay(in: v.bounds, to: rep)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
exit(0)
