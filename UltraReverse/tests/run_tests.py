#!/usr/bin/env python3
"""Ultra Reverse offline tests (REVERSE_PLAN.md §6). Run: python3 tests/run_tests.py
Writes renders to UltraReverse/tests/renders/, demos to UltraReverse/_sound_previews/."""
import os, subprocess, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BIN = os.path.join(HERE, "bin")
RND = os.path.join(HERE, "renders"); os.makedirs(RND, exist_ok=True)
DEMO = os.path.join(ROOT, "_sound_previews"); os.makedirs(DEMO, exist_ok=True)
SR = 48000
results = {}

def write_f32(path, st):   # st: (n, 2)
    st.astype(np.float32).reshape(-1).tofile(path)
def read_f32(path):
    return np.fromfile(path, dtype=np.float32).reshape(-1, 2)
def run(sig, name, **kw):
    ip = os.path.join(RND, name + "_in.f32"); op = os.path.join(RND, name + "_out.f32")
    write_f32(ip, sig)
    args = [os.path.join(BIN, "urv_cli"), ip, op] + [f"{k}={v}" for k, v in kw.items()]
    out = subprocess.run(args, capture_output=True, text=True, check=True).stdout
    return read_f32(op), out
def wav(path, st):
    raw = path + ".f32"; write_f32(raw, st)
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "f32le", "-ar", str(SR), "-ac", "2", "-i", raw,
                    "-c:a", "pcm_s24le", path], check=True)
    os.remove(raw)
def spectro(path_wav, png, title):
    subprocess.run(["sox", path_wav, "-n", "remix", "1", "spectrogram", "-x", "1200", "-y", "300", "-t", title, "-o", png], check=True)

t = np.arange(int(SR * 6.0)) / SR
# ── signals ────────────────────────────────────────────────────────────────
f0, f1, T = 100.0, 8000.0, 6.0
chirp = 0.5 * np.sin(2 * np.pi * (f0 * t + (f1 - f0) / (2 * T) * t ** 2))
rng = np.random.default_rng(3)
clicks = np.zeros_like(t); pos = np.cumsum(rng.integers(3000, 11000, 60)); pos = pos[pos < len(t)]
clicks[pos] = rng.uniform(0.3, 0.9, len(pos))
def drums(sec=8.0, bpm=120.0):
    n = int(SR * sec); x = np.zeros(n); spb = 60 / bpm * SR
    for b in range(int(sec * bpm / 60 * 4)):              # 16ths
        s = int(b * spb / 4)
        if b % 4 == 0:   # kick
            k = np.arange(int(0.25 * SR)); x[s:s + len(k)] += 0.9 * np.sin(2 * np.pi * (50 + 120 * np.exp(-k / 900)) * k / SR) * np.exp(-k / 5000)
        if b % 8 == 4:   # snare
            k = np.arange(int(0.2 * SR)); x[s:s + len(k)] += 0.5 * rng.standard_normal(len(k)) * np.exp(-k / 2500) + 0.3 * np.sin(2 * np.pi * 190 * k / SR) * np.exp(-k / 3000)
        k = np.arange(int(0.05 * SR)); hat = rng.standard_normal(len(k)); hat = np.diff(hat, prepend=0)
        x[s:s + len(k)] += (0.18 if b % 2 else 0.09) * hat * np.exp(-k / 600)
    return np.clip(x[:n], -1, 1)
def vocal(sec=8.0):
    n = int(SR * sec); tt = np.arange(n) / SR
    notes = [57, 60, 64, 62, 60, 57, 55, 57]                   # A minor phrase, 1 s each
    f = np.repeat([440 * 2 ** ((m - 69) / 12) for m in notes], SR)[:n] * (1 + 0.006 * np.sin(2 * np.pi * 5.5 * tt))
    ph = 2 * np.pi * np.cumsum(f) / SR
    saw = sum(np.sin(k * ph) / k for k in range(1, 30))
    y = np.zeros(n)
    for fc, bw, g in ((700, 110, 1.0), (1220, 120, 0.6), (2600, 160, 0.25)):   # "ah" formants
        r = np.exp(-np.pi * bw / SR); w = 2 * np.pi * fc / SR
        a1, a2 = -2 * r * np.cos(w), r * r; z1 = z2 = 0.0; out = np.empty(n)
        for i in range(n):
            v = saw[i] - a1 * z1 - a2 * z2; out[i] = v; z2 = z1; z1 = v
        y += g * out * (1 - r)
    env = np.minimum(1, np.minimum(tt % 1.0 / 0.04, (1.0 - tt % 1.0) / 0.12))
    y = y * env; return 0.6 * y / np.max(np.abs(y))
st = lambda m: np.stack([m, m], 1)

# ── (a) per-segment reversal, Reverse Echo, grid 1/4 @ 120 bpm, 100 % wet ──
L = SR // 2   # 1/4 at 120 bpm
corr_all, res_all = [], []
for name, sig in (("chirp", chirp), ("clicks", clicks)):
    y, _ = run(st(sig), "T1_" + name, mode=1, sync=1, division=3, bpm=120, mix=1, feedback=0, smooth=1, cut=0.5, lookahead=0)
    excl0, excl1 = 64, 8
    cs, rs = [], []
    for k in range(int(len(sig) / L) - 2):
        seg = sig[k * L:(k + 1) * L][::-1]
        o = y[(k + 1) * L:(k + 2) * L, 0]
        a, b = seg[excl0:L - excl1], o[excl0:L - excl1]
        if np.sum(a * a) < 1e-9: continue
        cs.append(float(np.dot(a, b) / np.sqrt(np.dot(a, a) * np.dot(b, b) + 1e-20)))
        rs.append(10 * np.log10(np.sum((a - b) ** 2) / np.sum(a * a) + 1e-30))
    corr_all += cs; res_all += rs
    results[f"a_{name}"] = f"segments {len(cs)}  min corr {min(cs):.6f}  worst residual {max(rs):.1f} dB"
results["a_pass"] = min(corr_all) > 0.95

# Impulse position (T1): impulse at s_k + j must land at s_k + 2L - 1 - j.
imp = np.zeros(int(SR * 3)); j = 5000; imp[L + j] = 1.0
y, _ = run(st(imp), "T1_impulse", mode=1, sync=1, division=3, bpm=120, mix=1, feedback=0, smooth=1, cut=0.5, lookahead=0)
pk = int(np.argmax(np.abs(y[:, 0]))); expect = L + 2 * L - 1 - j
results["a_impulse"] = f"expected sample {expect}, got {pk}, gain {y[pk,0]:.4f}"
results["a_impulse_pass"] = (pk == expect) and abs(y[pk, 0] - 1.0) < 0.01

# ── (b) spectrograms: chirp in + every mode ────────────────────────────────
cw = os.path.join(RND, "chirp_in_KJ_v001.wav"); wav(cw, st(chirp)); spectro(cw, os.path.join(RND, "spec_chirp_in_KJ_v001.png"), "input chirp")
for mode, mname in ((0, "bloom"), (1, "echo"), (2, "reverb"), (3, "preverb")):
    y, _ = run(st(chirp), f"T3_{mname}", mode=mode, sync=1, division=3, bpm=120, mix=1, feedback=0.0 if mode == 1 else 0.3, lookahead=2)
    p = os.path.join(RND, f"chirp_{mname}_KJ_v001.wav"); wav(p, y)
    spectro(p, os.path.join(RND, f"spec_chirp_{mname}_KJ_v001.png"), f"chirp through {mname}")
results["b"] = "spectrograms written to tests/renders/spec_chirp_*_KJ_v001.png"

# ── (c) Pre-Verb: swell rises BEFORE the (latency-compensated) hit ─────────
imp = np.zeros(int(SR * 4)); t0 = SR; imp[t0] = 1.0
y, out = run(st(imp), "T7_preverb", mode=3, mix=0.5, lookahead=2, length=0.8, gap=0, decay=4, size=0.7)
D = int(out.split("latency_samples=")[1].split()[0])
dry_pos = int(np.argmax(np.abs(y[:, 0])))
wet = y[:, 0].copy(); wet[t0 + D] -= 0.5           # remove the dry impulse (mix 0.5 → 0.5)
bins = np.array([np.sqrt(np.mean(wet[t0 + i * 480:t0 + (i + 1) * 480] ** 2)) for i in range(D // 480 + 30)])
bdb = 20 * np.log10(bins + 1e-12)
peak_bin = int(np.argmax(bins)); last_pre = D // 480 - 1
after = 20 * np.log10(np.sqrt(np.mean(wet[t0 + D + 960:t0 + D + 9600] ** 2)) + 1e-12) - bdb[peak_bin]
swell_bins = bdb[(D - int(0.8 * SR)) // 480:last_pre + 1]
rising = float(np.mean(np.diff(swell_bins) > 0))
b50 = np.array([np.sqrt(np.mean(wet[t0 + D - (i + 1) * 2400:t0 + D - i * 2400] ** 2)) for i in range(16)])[::-1]  # last 0.8 s
rising50 = float(np.mean(np.diff(20 * np.log10(b50 + 1e-12)) > 0))
crest_ms = (D - peak_bin * 480 - 480) / SR * 1000          # ms between crest bin end and the hit
results["c"] = (f"latency {D} samples; dry hit at {dry_pos} (expected {t0 + D}); wet crest {crest_ms:.0f}-{crest_ms+10:.0f} ms before the hit; "
                f"rising steps: {rising*100:.0f}% (10 ms bins), {rising50*100:.0f}% (50 ms bins); "
                f"20-200 ms after hit: {after:.1f} dB vs crest; swell starts {bdb[(D - int(0.8*SR))//480] - bdb[peak_bin]:.0f} dB below crest")
results["c_pass"] = dry_pos == t0 + D and crest_ms <= 30 and after < -50 and rising50 >= 0.9

# ── (d) stress: knob sweeps + mode changes + concurrent IR renders ────────
sm = 0.3 * np.sin(2 * np.pi * 440 * t) + 0.2 * np.sin(2 * np.pi * 110 * t)
y, out = run(st(sm[:SR * 6]), "T5_stress", sweep=1, mode=1, bpm=128, pace=1)   # real-time paced: background IR swaps mid-play
fin = bool(np.all(np.isfinite(y)))
jump = float(np.max(np.abs(np.diff(y, axis=0))))
inj = float(np.max(np.abs(np.diff(sm))))
dn = int(np.sum((np.abs(y) > 0) & (np.abs(y) < 1e-30)))
results["d"] = f"finite={fin}  max |Δ| out {jump:.4f} (input {inj:.4f})  denormals {dn}  {out.strip().splitlines()[-1]}"
nren = int(out.split("ir_renders=")[1].split()[0])
results["d_pass"] = fin and jump < 0.25 and dn == 0 and nren >= 10
# Same check with defaults (no sweeps) for each mode: splice clicks at default fades.
for mode, mname in ((1, "echo"), (2, "reverb"), (3, "preverb")):
    y, _ = run(st(sm[:SR * 4]), f"T5_{mname}", mode=mode, mix=1, feedback=0.3, lookahead=0)
    results[f"d_{mname}_jump"] = f"{float(np.max(np.abs(np.diff(y, axis=0)))):.4f}"

# ── (e) BLOOM regression against the pre-change engine ────────────────────
pl = np.zeros(int(SR * 4)); k = np.arange(int(0.4 * SR))
for s0 in (int(0.5 * SR), int(1.7 * SR), int(2.4 * SR)):
    pl[s0:s0 + len(k)] += 0.7 * np.sin(2 * np.pi * 440 * k / SR) * np.exp(-k / 2900)
ip = os.path.join(RND, "T11_in.f32"); write_f32(ip, st(pl))
subprocess.run([os.path.join(BIN, "bloom_old"), ip, os.path.join(RND, "T11_old.f32")], check=True)
old = read_f32(os.path.join(RND, "T11_old.f32"))
new, _ = run(st(pl), "T11_new", mode=0, lookahead=0, mix=0.4)
md = float(np.max(np.abs(old - new)))
results["e"] = f"BLOOM vs old engine: max |diff| {md:.3e}"
results["e_pass"] = md < 1e-6

# ── demos ──────────────────────────────────────────────────────────────────
dr, vo = drums(), vocal()
for mode, mname, kw in ((1, "echo", dict(division=3, feedback=0.35, mix=0.5)),
                        (2, "reverb", dict(division=6, mix=0.55, decay=5, size=0.8)),
                        (3, "preverb", dict(mix=0.5, length=0.9, decay=5, size=0.8)),
                        (0, "bloom", dict(mix=0.45))):
    parts = []
    for src in (dr, vo):
        y, _ = run(st(src), f"demo_{mname}", mode=mode, bpm=120, lookahead=2 if mode == 3 else 0, **kw)
        if mode == 3:  # show it as Logic would: remove the reported latency
            y = np.concatenate([y[48000:], np.zeros((48000, 2))])
        parts += [y, np.zeros((SR // 2, 2))]
    p = os.path.join(DEMO, f"reverse_{mname}_KJ_v001.wav"); wav(p, np.concatenate(parts) * 0.9)
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", p, "-c:a", "aac", "-b:a", "192k", p[:-4] + ".m4a"], check=True)
wav(os.path.join(DEMO, "reverse_source_dry_KJ_v001.wav"), np.concatenate([st(dr), np.zeros((SR // 2, 2)), st(vo)]) * 0.9)

for k_, v in results.items(): print(f"{k_:14s} {v}")
ok = all(v for k_, v in results.items() if k_.endswith("_pass"))
print("ALL PASS" if ok else "SOME FAILED"); sys.exit(0 if ok else 1)
