# Paradise Audio — Windows (VST3) Port Kit

17 plug-ins. Ready to build on Windows with Visual Studio 2022 + CMake + JUCE.

## Quick start

```bat
git clone https://github.com/juce-framework/JUCE.git
build.bat
```

Then copy the built `.vst3` folders from
`build\src\<Plugin>\<Plugin>_artefacts\Release\VST3\`
into `C:\Program Files\Common Files\VST3\`.

## Read this first

**[PORTING.md](PORTING.md)** — how this works, what ports and what doesn't, and the known gaps.
Start there. It's short and it will save you a day.

**[PARAMETERS.md](PARAMETERS.md)** — all 157 parameters, every ID / range / default / unit.

## What's in the box

| | |
|---|---|
| `src/<Plugin>/DSP/` | The original macOS audio engines. **Pure C++17, unmodified, verified to compile without any Apple SDK.** |
| `src/<Plugin>/PluginProcessor.*` | Generated JUCE wrapper — parameters, DSP wiring, MIDI, state. |
| `CMakeLists.txt` | Builds all 17 as VST3. |
| `build.bat` | One-click Release build. |
| `parameters.json` | The parameter data, machine-readable. |

## The short version

The audio engines port to Windows **untouched** — that's the part that matters and it's done.
Apple's plug-in wrapper and the SwiftUI interface do not port; JUCE replaces the wrapper (already
generated for you) and the UI is currently JUCE's generic slider panel.

Everything makes sound and every knob is automatable. Making it *look* like the Mac version is the
remaining work — see PORTING.md.
