#!/usr/bin/env python3
"""Before/after table from Tests/sq/out/metrics_before.txt and metrics_after.txt.
   python3 Tests/sq/table.py            → prints the table and writes out/before_after.txt
Every row is one harness metric (run_sq.sh); 'before' = DSP frozen in before_dsp/,
'after' = live VoiceBoxExtension/DSP."""
import os, re, sys
here = os.path.dirname(os.path.abspath(__file__))
def load(tag):
    with open(os.path.join(here, 'out', f'metrics_{tag}.txt'), encoding='utf-8') as f:
        return [l[7:].rstrip('\n') for l in f if l.startswith('METRIC ')]
B, A = load('before'), load('after')
def find(lines, pat):
    for l in lines:
        m = re.search(pat, l)
        if m: return m
    return None
def val(lines, pat, fmt='{}'):
    m = find(lines, pat)
    return fmt.format(*m.groups()) if m else 'n/a'
rows = []
def row(what, pat, fmt='{}', note=''):
    rows.append((what, val(B, pat, fmt), val(A, pat, fmt), note))
def sec(title): rows.append((title, None, None, None))
num = r'([+\-]?\d+\.?\d*)'

sec('1  PSOLA core (AUTOTUNE / HARMONY / LOW TUNER / PITCH-SKIP)')
row('Burst at a word end, autotune on, real vocal (output peak; input −9.85 dBFS)', r'voice realH131 at_tuned_maj .*peak\s+' + num, '{} dBFS')
row('  same take, worst 10 ms level jump vs input', r'voice realH131 at_tuned_maj .*env_max\s+' + num, '{} dB')
row('Autotune on, AMOUNT 0 (must be identical to the input): worst level error, real vocal', r'voice realH131 at_amt0 .*env_max\s+' + num, '{} dB')
row('  low spoken voice (Stimme, < 105 Hz)', r'voice stimme\s+at_amt0 .*env_max\s+' + num, '{} dB')
for hz in (110, 220, 330):
    for c, name in ((30, '+30 cents (typical correction)'), (-500, '−5 st'), (-1200, '−12 st'), (700, '+7 st'), (1200, '+12 st')):
        row(f'Clean sung vowel {hz} Hz shifted {name}: harmonic-to-noise ratio', rf'steady glottal {hz} Hz shift\s+' + re.escape(f'{c:+d}') + r' c: HNR\s+' + num, '{} dB', 'higher = cleaner; < 30 dB is audibly rough')
row('Real vocal, LOW TUNER −5: frames clearly rougher than the input', r'voice realH33\s+low-5 .*frames_worse\s+' + num, '{} %')
row('Real vocal, LOW TUNER −12: frames clearly rougher than the input', r'voice realH33\s+low-12 .*frames_worse\s+' + num, '{} %')
row('Real vocal, hard autotune (major): frames clearly rougher than the input', r'voice realH131 at_tuned_maj .*frames_worse\s+' + num, '{} %')
rows.append(('Hard-tune pitch wobble on a vibrato note at a note boundary (regression bench T3, SD)', '3.7 cents', '1.4 cents', 'Tests/renders/metrics_new.txt(.pre-sq)'))

sec('2  Pitch tracker')
row('High phrase (207–830 Hz): time spent on a wrong octave', r'tracker synth sr48000 base56 normal .*gross_err\s+' + num, '{} %')
row('Low phrase (104–415 Hz): time spent on a wrong octave', r'tracker synth sr48000 base44 normal .*gross_err\s+' + num, '{} %')
row('Quiet take (peaks −40 dBFS): share of the phrase that is tracked/tuned', r'tracker noise: .*phrase at −40 dBFS peak: voiced ' + num, '{} %', '≈ 75 % is "all sung parts"')
row('Room noise tracked as a voice', r'tracker noise: white −48 dBFS voiced ' + num, '{} %')
row('Pitch marks off by > 15 % of a period, real vocal', r'tracker realH33 .*bad_marks\s+' + num, '{} %')

sec('3  Gain staging / output')
row('All effects off, 220 Hz sine at −1 dBFS: THD+N', r'thd off_220Hz\s+in -1dBFS THD\+N\s+' + num, '{} dB')
for name in ('vocoder', 'P_ROBOT', 'P_FULL', 'harmonizer', 'P_GHOST'):
    row(f'{name}: gain at 0 dBFS input minus gain at −40 dBFS (0 = behaves the same at every level)', rf'levels_linearity {name}\s+gain\(0dBFS\)-gain\(-40dBFS\)\s+' + num, '{} dB')
row('VOCODER alone, vocal at −12 dBFS: gain', r'levels vocoder\s+in-12dBFS .*gain\s+' + num, '{} dB')
for p in ('P_CLEAN', 'P_TUNED', 'P_OCTAVE\\+', 'P_ROBOT', 'P_SLAP', 'P_DUB', 'P_GLITCH', 'P_STUTTER', 'P_GHOST', 'P_FULL'):
    row(f'{p.replace(chr(92), "")}, vocal peaking at 0 dBFS: output peak / samples over 0 dBFS / flat-topped samples', rf'overload {p}\s+voice at 0 dBFS: peak\s+' + num + r' dBFS samples_over_0dBFS\s+(\d+) flat_topped\s+(\d+)', '{} dBFS / {} / {}')
row('DELAY, steady tone at −6 dBFS in (echoes add up): THD+N', r'overload delay_fb.35\s+sine in -6dBFS: .*THD\+N\s+' + num + r' dB \(' + num, '{} dB ({} %)')
row('DUB preset, steady tone at 0 dBFS in: THD+N', r'overload P_DUB\s+sine in \+0dBFS: .*THD\+N\s+' + num + r' dB \(' + num, '{} dB ({} %)')
rows.append(('Harmony above +12 st / LOW below −12 st (STFT fallback): level vs the PSOLA voices', '+17 dB / +6 dB', '±1.5 dB', 'overlap-add was scaled 3×; measured with scratch tool, see HANDOFF'))
row('DC offset, ROBOT at 0 dBFS', r'levels P_ROBOT\s+in \+0dBFS .* dc ' + num, '{}')

sec('4  Switching effects on/off, moving knobs (click = jump vs the steady signal, 1.0 = none)')
for name in ('autotune', 'harmonizer', 'lowtuner', 'pitchskip', 'delay', 'chop', 'vocoder', 'reverb'):
    row(f'Toggle {name.upper()} every 0.5 s: worst jump / toggles that click', rf'toggle {name}\s+worst_jump/steady\s+' + num + r'\s+toggles_with_click\s+(\d+)/10', '{}× / {} of 10')
row('Sweep DELAY TIME 100→400 ms: worst jump / click events', r'zipper delay_time\s+max_jump/steady\s+' + num + r'\s+click_events\s+(\d+)', '{}× / {}')
row('Sweep VOC MIX 0→1: click events', r'zipper voc_mix\s+max_jump/steady\s+' + num + r'\s+click_events\s+(\d+)', '{}× / {}')
row('Sweep VERB MIX 0→1: worst jump', r'zipper rev_mix\s+max_jump/steady\s+' + num, '{}×')

sec('5  Consonants')
row('"s"/"sh" through hard AUTOTUNE: waveform match with the input', r'sibilants autotune_hard\s+s/sh level\s+[+\-\d.]+ dB\s+waveform_corr ' + num, '{}')
row('"s"/"sh" level vs the vowels, HARMONIZER +7', r'sibilants harmonizer\+7 .*sibilant boost\s+' + num, '{} dB')
row('"s"/"sh" level vs the vowels, PITCH-SKIP', r'sibilants pitchskip .*sibilant boost\s+' + num, '{} dB')
row('"s"/"sh" through the VOCODER: waveform match / level vs vowels', r'sibilants vocoder\s+s/sh level\s+[+\-\d.]+ dB\s+waveform_corr ' + num + r'.*sibilant boost\s+' + num, '{} / {} dB')

sec('6  Sample rate')
for sr in (44100, 48000, 88200, 96000):
    row(f'{sr} Hz: reverb decay (SIZE 0.5, RT60 below 2 kHz)', rf'samplerate\s+{sr} reverb size .5: RT60 ' + num, '{} s')
for sr in (44100, 48000, 96000):
    row(f'{sr} Hz: latency reported / measured', rf'samplerate\s+{sr} latency reported\s+(\d+) measured\(off\)\s+(\d+)', '{} / {}')
row('96000 Hz: vocoder wet level (vowel at −12 dBFS)', r'samplerate\s+96000 vocoder wet-only gain ' + num, '{} dB')
row('Dry/wet alignment (noise through LOW MIX 50 %): residual', r'comb low_mix.5\s+gain\s+[+\-\d.]+ dB\s+residual .*?' + num + r' dB$', '{} dB', 'no comb filtering before or after')
row('Block sizes 64/128/441/1024/4096 vs 512, FULL preset: max difference', r'blocks P_FULL\s+block\s+441 vs 512: max_abs_diff ' + r'(\S+)', '{}')

w0 = max(len(r[0]) for r in rows) + 2
out = [f'VoiceBox sound-quality pass 2026-11-21 — before / after (Tests/sq/run_sq.sh both all; python3 Tests/sq/table.py)', '']
for what, b, a, note in rows:
    if b is None: out += ['', what, '-' * len(what)]; continue
    out.append(f'{what:<{w0}} {b:>22}  →  {a:<22} {note}')
txt = '\n'.join(out) + '\n'
with open(os.path.join(here, 'out', 'before_after.txt'), 'w', encoding='utf-8') as f: f.write(txt)
sys.stdout.write(txt)
