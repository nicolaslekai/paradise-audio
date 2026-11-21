# Reverb

Paradise Audio algorithmic reverb AUv3. Freeverb-style 8-comb / 4-allpass
network, with pre-delay, low/high cut input shaping, and parallel mix.

Note: this initial release ships the 7 core knobs. PITCH and REVERSE
(visible in the render spec) are scheduled for v1.1.

| Param      | Range          | Default |
|------------|----------------|---------|
| Size       | 0 .. 1         | 0.65    |
| Decay      | 0.5 .. 8 s     | 2.1 s   |
| Damping    | 0 .. 1         | 0.4     |
| Predelay   | 0 .. 200 ms    | 12 ms   |
| EQ Lo Cut  | 20 .. 1000 Hz  | 80 Hz   |
| EQ Hi Cut  | 1 .. 18 kHz    | 9 kHz   |
| Mix        | 0 .. 1         | 0.35    |

Build: `./Installer/build_installer.sh`. Logic: **Paradise Audio ▸ Reverb**.
