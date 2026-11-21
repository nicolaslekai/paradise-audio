# Paradise Audio — Windows Port Kit

Everything needed to build the Paradise Audio plug-ins as **VST3 on Windows**.

You do not need a Mac, and you do not need to understand the original macOS code.

---

## The one thing to understand first

The Mac plug-ins are **AUv3** — an Apple-only plug-in format. They are built from three layers:

| Layer | What it is | Ports to Windows? |
|---|---|---|
| **DSP** (`DSP/*.hpp`) | The actual audio engines — compressor, filters, oscillators, reverb | **Yes. Unchanged.** Pure ISO C++17. |
| **AU wrapper** (`*.mm`) | Objective-C++ glue to Apple's AudioUnit API | **No.** Replaced by JUCE. |
| **UI** (`*.swift`) | SwiftUI / AppKit interface | **No.** Replaced (see below). |

So this is **not** a recompile. It is: *keep the DSP, throw away the Apple-specific shell, bolt on a
cross-platform one.* JUCE is that shell.

The good news is that the DSP layer — the part that took the longest to get right, and the part that
actually makes these plug-ins sound the way they sound — is completely portable and **has already been
verified to compile with a non-Apple compiler** (`g++ -std=c++17`, no Apple SDK, all 38 headers, zero
errors). Nothing in it touches Foundation, Accelerate, CoreAudio or `simd`. It only uses
`<cmath>`, `<vector>`, `<atomic>`, `<algorithm>`, `<complex>`, `<random>`.

---

## What's already done for you

This kit is **not** a pile of source to figure out. It's a working JUCE project:

* All **38 DSP headers** copied in, unmodified, under `src/<Plugin>/DSP/`.
* All **157 parameters** extracted from the original AU sources — exact IDs, ranges, defaults, units —
  and code-generated into a JUCE `AudioProcessorValueTreeState` per plugin.
* A **`PluginProcessor.h/.cpp`** per plugin that already:
  * builds the parameter layout,
  * instantiates and calls the real DSP engine (`prepare` / `processFrame` / `render`),
  * pushes parameters into the engine each block (`syncParams()`),
  * handles MIDI note on/off for the five instruments that take MIDI,
  * reads host tempo from the playhead,
  * saves and restores state.
* **CMake** for all 17, plus a one-click `build.bat`.

Every generated `syncParams()` has been **compile-verified against the real DSP engines** — setter names,
argument counts and types all check out, for all 17 plugins.

The parameter→DSP wiring was not guessed from names. It was extracted from the original render loop —

```objc
dsp->setThresholdDB(aThr->load());     // original macOS AU
```
```cpp
engine.setThresholdDB(P("threshold")); // generated JUCE
```

— so it reproduces the Mac behaviour exactly. **155 of 157** parameters are wired this way; the other
two are handled explicitly (Drums' output gain is a post-multiply, not a setter).

---

## Build it

**Prerequisites**

* Windows 10/11 x64
* [Visual Studio 2022](https://visualstudio.microsoft.com/) with the **"Desktop development with C++"** workload
* [CMake](https://cmake.org/download/) 3.22+
* [Git](https://git-scm.com/)

**Steps**

```bat
git clone https://github.com/juce-framework/JUCE.git
build.bat
```

That's it. `build.bat` configures CMake and builds everything in Release.
(If you skip the `git clone`, CMake fetches JUCE automatically via `FetchContent`.)

To build one plugin instead of all 17:

```bat
cmake -B build -G "Visual Studio 17 2022" -A x64
cmake --build build --config Release --target Compressor
```

**Install:** copy the resulting `.vst3` folders to

```
C:\Program Files\Common Files\VST3\
```

They are produced in `build\src\<Plugin>\<Plugin>_artefacts\Release\VST3\`.

Test in any VST3 host — Reaper, Ableton Live, FL Studio, Cubase, Bitwig.

---

## The 17 plug-ins

| Plugin | Type | Params | Notes |
|---|---|---|---|
| Compressor | effect | 10 | plus an internal "duck" engine, tempo-synced to the host |
| EQ | effect | 16 | 12/24 dB-per-oct HP/LP, four bands |
| Reverb | effect | 7 | Freeverb |
| Saturation | effect | 5 | |
| Deesser | effect | 5 | |
| Delay | effect | 10 | stereo |
| Limiter | effect | 3 | plus loudness metering |
| BigKnob | effect | 2 | |
| PitchKnob | effect | 2 | |
| UltraReverse | effect | 9 | reverse-reverb texture |
| VoiceBox | effect | 23 | autotune / harmoniser / vocoder |
| RoarBass | instrument | 26 | FM + ladder filter. Takes MIDI. |
| BassMitStimme | instrument | 31 | vocal-sample bass. Takes MIDI. |
| Handy | instrument | 7 | sample pads. Takes MIDI. |
| Drums | instrument | 1 | **step sequencer — no MIDI input** |
| SynthThing | instrument | 0 | **see gap #2 below** |
| StringThing | instrument | 0 | **see gap #2 below** |

---

## Known gaps — read this before you start

These are the honest edges. None of them block a working build; they're things that need a decision.

### 1. There is no custom UI

Every plugin currently uses JUCE's **`GenericAudioProcessorEditor`** — an automatically generated list of
sliders. It is fully functional: every parameter is present, automatable and connected to the DSP. It
simply looks generic rather than like the OP-1-style Mac faceplates.

This was a deliberate call ("function first"). The SwiftUI interface cannot be ported; it would have to
be rebuilt in JUCE from scratch. The hook is `createEditor()` in each `PluginProcessor.h`.

### 2. SynthThing and StringThing expose zero automatable parameters

This is not a porting bug — it is how they were written. Both do:

```objc
_parameterTree = [AUParameterTree createTreeWithChildren:@[]];
```

An **empty** parameter tree. Their entire state — step grid, scale, root, sequencer, FX — lives in
Objective-C methods called directly by the Swift UI and is persisted through the AU's `fullState`
dictionary. The host never sees any of it.

So for these two the DSP ports fine and will make sound, but **someone has to design a parameter scheme**
— decide what should be host-visible and expose it. Until then they build and run but have nothing to
turn. The engines' public APIs are already there (roughly 40 setters each) in
`src/SynthThing/DSP/SynthThingEngine.hpp` and `src/StringThing/DSP/StringThingEngine.hpp`.

Drums is a milder case of the same thing: one automatable parameter (gain); the grid and the per-voice
level/mute/solo controls are all direct method calls.

### 3. Sequencer host-sync

Drums, SynthThing and StringThing hard-snap their sequencers to the host bar grid. The port reads tempo
from JUCE's playhead (`hostBpm`), but the **transport position and loop handling was Logic-specific** and
needs redoing against `juce::AudioPlayHead::PositionInfo` (`ppqPosition`, `isPlaying`, `isLooping`).

### 4. Sample loading, drag-and-drop, WAV bounce

Handy and StringThing accept dropped audio files, and StringThing can bounce its output to a WAV. On the
Mac that used `AVFoundation` plus macOS sandbox entitlements. On Windows it needs the JUCE equivalents:
`juce::AudioFormatManager` to load, `juce::FileChooser` for the dialog, `juce::WavAudioFormat` to write.
The DSP side (`CaptureWav.hpp`) is portable — only the file-I/O shell is Apple-specific.

### 5. Presets

Factory presets (Compressor's drum presets, VoiceBox's ten presets, StringThing's grid presets) live in
the **Swift UI layer**, not in the DSP, so they did not come across. VoiceBox's are the easiest to
recover — they're a plain C table (`kPresets[10][23]`) sitting in `VoiceBoxAudioUnit.mm` in the Mac repo.

---

## How the generated code is laid out

```
src/<Plugin>/
  DSP/*.hpp            <- original engines, unchanged. Don't edit these.
  PluginProcessor.h    <- JUCE processor + APVTS + engine instance
  PluginProcessor.cpp  <- parameter layout, syncParams(), processBlock()
  CMakeLists.txt
```

The engine contract is identical across all 17, which is why this generated so cleanly:

```cpp
engine.prepare (float sampleRate);
engine.processFrame (float& left, float& right);   // per sample, in place
engine.noteOn (int midiNote, int velocity);        // instruments only
engine.noteOff (int midiNote);
```

RoarBass is the single exception — it renders a whole block: `engine.render (n, L, R)`.

`syncParams()` runs once per block, which matches the original AU (the Mac code refreshed DSP parameters
per render slice, not per sample — so there is deliberately no parameter smoothing).

---

## If something doesn't build

The DSP is verified clean, so failures will almost certainly be in the JUCE layer rather than the audio code:

* **`juce::ParameterID` not found** — you're on JUCE 6. This kit targets **JUCE 7/8**; pin `GIT_TAG 8.0.4`.
* **Linker error on `createPluginFilter`** — that plugin's `CMakeLists.txt` isn't being picked up. Check it
  is listed in `PARADISE_PLUGINS` in the root `CMakeLists.txt`.
* **MSVC narrowing / conversion warnings** — the DSP was written against Clang. These are warnings, not
  errors; `juce_recommended_warning_flags` is set so they aren't fatal.

---

## Parameter reference

See **`PARAMETERS.md`** for all 157 parameters — every ID, range, default and unit, per plugin. They match
the Mac plug-ins exactly, so a preset transcribed by hand will behave identically.

`parameters.json` is the same data in machine-readable form, if you'd rather generate something from it.
