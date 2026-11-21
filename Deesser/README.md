# De-esser

Paradise Audio sibilance de-esser AUv3. Band-passed sidechain (4–9 kHz
region tunable), peak detector, gain reduction applied broadband.

| Param      | Range          | Default |
|------------|----------------|---------|
| Frequency  | 1 .. 12 kHz    | 6.5 kHz |
| Threshold  | -40 .. 0 dB    | -22 dB  |
| Range      | -24 .. 0 dB    | -9 dB   |
| Release    | 10 .. 500 ms   | 120 ms  |
| Listen     | on / off       | off     |

Build: `./Installer/build_installer.sh`. Logic: **Paradise Audio ▸ De-esser**.
