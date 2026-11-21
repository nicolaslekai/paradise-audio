# Saturation

Paradise Audio drive/saturation AUv3. Asymmetric soft-clip waveshaper (tube
character) with DC bias, post-saturation tilt EQ, dry/wet mix, output trim.

```
in ─► × drive ─► + bias ─► tanh shape ─► − bias ─► tilt EQ ─► mix ─► × out ─► out
```

| Param  | Range          | Default |
|--------|----------------|---------|
| Drive  | -12 .. +24 dB  | +8 dB   |
| Bias   | -1 .. +1       | +0.15   |
| Tone   | -1 .. +1       | 0       |
| Mix    | 0 .. 1         | 1       |
| Output | -12 .. +12 dB  | -2 dB   |

Build: `./Installer/build_installer.sh`. Logic: **Paradise Audio ▸ Saturation**.
