// AU wrapper smoke test: latency follows LOOKAHEAD only, old sessions migrate to
// Bloom + Off, NULL-mData hosts render into the AU's own buffer.
import AVFoundation
import AudioToolbox
func fourCC(_ s: String) -> OSType { s.utf8.reduce(0) { ($0 << 8) | OSType($1) } }
let desc = AudioComponentDescription(componentType: fourCC("aufx"), componentSubType: fourCC("Urv1"),
                                     componentManufacturer: fourCC("Para"), componentFlags: 0, componentFlagsMask: 0)
let au = try! UltraReverseAudioUnit(componentDescription: desc, options: [])
let tree = au.parameterTree!
var ok = true
func check(_ c: Bool, _ msg: String) { print((c ? "PASS " : "FAIL ") + msg); if !c { ok = false } }
var kvo = 0
let obs = au.observe(\.latency, options: [.new]) { _, _ in kvo += 1 }
check(abs(au.latency - 1.0) < 1e-9, "default latency 1.0 s (got \(au.latency))")
tree.parameter(withAddress: 16)!.value = 3; check(abs(au.latency - 2.0) < 1e-9 && kvo >= 1, "lookahead 2 s → latency \(au.latency), KVO fired \(kvo)")
let before = au.latency
tree.parameter(withAddress: 9)!.value = 0; tree.parameter(withAddress: 1)!.value = 0.2; tree.parameter(withAddress: 11)!.value = 6
check(au.latency == before, "mode/size/division do not change latency")
// State round-trip + legacy migration.
let st = au.fullState!
check(st["urvEngineVersion"] as? Int == 2, "fullState carries the engine version marker")
var legacy = st; legacy.removeValue(forKey: "urvEngineVersion")
tree.parameter(withAddress: 9)!.value = 3; tree.parameter(withAddress: 16)!.value = 2
au.fullState = legacy
check(tree.parameter(withAddress: 9)!.value == 0 && tree.parameter(withAddress: 16)!.value == 0 && au.latency == 0,
      "legacy session → Bloom + lookahead Off, latency \(au.latency)")
// Render with NULL mData (host asks the AU to own the output buffers).
au.maximumFramesToRender = 512
try! au.allocateRenderResources()
let rb = au.renderBlock
var flags = AudioUnitRenderActionFlags(); var ts = AudioTimeStamp(); ts.mFlags = .sampleTimeValid
let abl = AudioBufferList.allocate(maximumBuffers: 2)
for i in 0..<2 { abl[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 512 * 4, mData: nil) }
let pull: AURenderPullInputBlock = { _, _, n, _, list in
    let l = UnsafeMutableAudioBufferListPointer(list)
    for b in l { if let d = b.mData { let p = d.assumingMemoryBound(to: Float.self); for i in 0..<Int(n) { p[i] = i == 10 ? 1 : 0 } } }
    return noErr
}
var st2: AUAudioUnitStatus = noErr
for _ in 0..<200 { for i in 0..<2 { abl[i].mData = nil; abl[i].mDataByteSize = 512 * 4 }; st2 = rb(&flags, &ts, 512, 0, abl.unsafeMutablePointer, pull); ts.mSampleTime += 512 }
check(st2 == noErr && abl[0].mData != nil, "NULL-mData render OK (status \(st2))")
check(au.tailTime > 1.0 && au.tailTime <= 60, "tailTime \(String(format: "%.1f", au.tailTime)) s")
_ = obs
print(ok ? "AU SMOKE: ALL PASS" : "AU SMOKE: FAILED"); exit(ok ? 0 : 1)
