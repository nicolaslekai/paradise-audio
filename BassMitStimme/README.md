# Bass mit Stimme

Paradise Audio AUv3 bass synthesizer with vocal-sample layer (sample layer
placeholder for v1 — VOX FX activates once a vocal sample library is
supplied).

```
osc1 ─┐
osc2 ─┼─► filter ─► amp env ─► × gain ─► out
sub  ─┤      ▲
FM   ─┘      │
noise        filter env
```

| Param        | Range          | Default |
|--------------|----------------|---------|
| OSC1 Oct     | -2 .. +2       | 0       |
| OSC2 Detune  | -50 .. +50 c   | 6 c     |
| Sub Level    | 0 .. 1         | 0.7     |
| FM Growl     | 0 .. 1         | 0       |
| FM Ratio     | 0.25 .. 8      | 1.5     |
| Noise Level  | 0 .. 1         | 0       |
| Cutoff       | 20 Hz .. 18 kHz| 600 Hz  |
| Resonance    | 0 .. 1         | 0.25    |
| Filter EnvAmt| -1 .. +1       | +0.4    |
| Amp A/D/S/R  | 1 ms .. 4 s    | 5/180/0.7/320 |
| Filter A/D/S/R | 1 ms .. 4 s  | 2/200/0.5/400 |
| Gain         | 0 .. 2         | 1.0     |
| Glide        | 0 .. 1 s       | 0.045   |
| Voice Mode   | POLY / MONO / LEGATO | MONO |

Build: `./Installer/build_installer.sh`. Logic: **AU Instruments ▸ Paradise Audio ▸ Bass mit Stimme**.
