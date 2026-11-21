# Drums

Paradise Audio AUv3 drum machine instrument. Ten procedural voices
(kick, snare, clap, rim, three toms, closed hat, open hat, crash) with
per-voice level + per-voice delay tap. Internal 16-step sequencer that
follows host transport (BPM + play). Plays automatically when the host
is playing, also responds to MIDI notes 36..45 for live triggering.

| Voice | MIDI Note | Description                          |
|-------|-----------|--------------------------------------|
| KICK  | 36        | Sine + pitch envelope + click        |
| SNARE | 37        | Body sine + filtered noise           |
| CLAP  | 38        | 3 noise bursts in quick succession   |
| RIM   | 39        | Short metallic enharmonic            |
| TOM 1 | 40        | Low pitched sine env                 |
| TOM 2 | 41        | Mid pitched sine env                 |
| TOM 3 | 42        | High pitched sine env                |
| HAT C | 43        | Closed hat — short noise burst       |
| HAT O | 44        | Open hat — longer noise tail         |
| CRASH | 45        | Bandpassed noise long decay          |

Pattern editing: this v1 ships with a baked-in 4-on-the-floor pattern.
A future v1.1 will add UI step-editing + pattern A/B/C/D switching.

Build: `./Installer/build_installer.sh`. Logic: **AU Instruments ▸ Paradise Audio ▸ Drums**.
