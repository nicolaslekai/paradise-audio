# EQ

Paradise Audio 4-band parametric EQ — AUv3 for Logic Pro and any AU host on
macOS. HP filter, low shelf (freq + gain), high shelf (freq + gain), LP
filter. RBJ biquad cookbook coefficients, Butterworth Q on the filters.

```
in ─► HPF (Q=0.707) ─► LO SHELF ─► HI SHELF ─► LPF (Q=0.707) ─► out
```

## Build & install

```bash
cd EQ
./Installer/build_installer.sh
cp -R build/DerivedData/Build/Products/Release/EQ.app /Applications/
open /Applications/EQ.app
```

Logic: **AU Effects ▸ Paradise Audio ▸ EQ**.

| Param      | Range          | Default |
|------------|----------------|---------|
| HP         | 20 .. 1000 Hz  | 40 Hz   |
| Lo Freq    | 40 .. 800 Hz   | 120 Hz  |
| Lo Gain    | -18 .. +18 dB  | 0 dB    |
| Hi Freq    | 1 .. 16 kHz    | 6 kHz   |
| Hi Gain    | -18 .. +18 dB  | 0 dB    |
| LP         | 2 .. 20 kHz    | 18 kHz  |
