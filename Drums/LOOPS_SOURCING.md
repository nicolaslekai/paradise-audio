# LOOPS row: hi-hat loop sourcing and licensing

Research date: 2026-11-20. Scope: about 10 organic hi-hat loops per genre for the 25 Engine 909
genres, played tempo-synced, **shipped inside the plug-in installer** (so the files themselves are
redistributed to third parties, which is a different right from "royalty-free use in your songs").

Not legal advice. Quotes are copied from the licence pages listed with each entry.

---

## TL;DR

| Question | Answer |
|---|---|
| Apple Loops in the plug-in? | **NO.** The Logic Pro licence forbids distributing the assets "on a standalone basis" and repackaging them "as audio samples ... sound libraries". |
| Best bundle-safe audio source | **Freesound filtered to CC0** (API, free key). Roughly 450 to 550 CC0 hi-hat loops in total, but very uneven by genre (see table). Needs a manual quality and provenance check. |
| Best bundle-safe one-shot source | **VCSL** (CC0, GitHub): 15 acoustic hi-hat samples plus shakers, cabasa, tambourines, agogo, gongs, balafon. Plus Freesound CC0 hat one-shots (≈135 "one shot" hits, ≈330 "closed hihat", ≈215 "open hihat"). |
| Recommendation | **Generate the loops ourselves**: humanized hat patterns (MIDI-like event lists) played through CC0 acoustic one-shots and/or the plug-in's own `Hat` voice. Fully clean, every genre covered, tempo sync is free (re-sequencing, no stretching). Use Freesound CC0 audio loops only as a hand-picked extra where a genre has good material. |
| Time-stretch library (only if real audio loops ship) | **Signalsmith Stretch**, MIT ("MIT License / Copyright (c) 2022 Geraint Luff / Signalsmith Audio Ltd."). Its one dependency, Signalsmith `linear`, is MIT as well. |

---

## 1. Apple Loops

### Licence text

Source: Apple Logic Pro software licence agreement, https://www.apple.com/legal/sla/docs/LogicPro.pdf
(document tag EA1004), section 2.B "Sample Content". Apple repeats the same restriction word for word in
support article https://support.apple.com/en-us/101908 ("Use the royalty-free content included with Logic
Pro for Mac and MainStage in commercial works"). GarageBand uses the same Sample Content wording.

> B. Sample Content. The Apple Software may contain sample content including but not limited to
> artwork, audio files, **audio loops**, built-in sound files, graphics, images, impulse responses,
> photographs, samples, sound sets, sound settings, video files, or similar assets ("Sample Content").
> This Sample Content is proprietary to Apple and/or its licensors, and is protected by applicable
> intellectual property and other laws, including but not limited to copyright. Except as otherwise
> provided, all Sample Content included in the Apple Software may be used on a royalty-free basis to
> create your own original soundtracks for your film, video and audio projects. You may broadcast
> and/or distribute your own soundtracks that were created using the Sample Content, however,
> **individual Sample Content assets may not be commercially or otherwise distributed on a standalone
> basis, nor may they be repackaged in whole or in part as audio samples, clipart, music beds, sound
> effects, sound files, sound libraries, stock animation, or similar assets.**

### Verdict: NOT OK to bundle

A LOOPS row in a third-party plug-in is a repackaging "as audio samples ... sound libraries". It is also
distribution "on a standalone basis", because the loop reaches the user as a loop, not as part of a
finished soundtrack. The words "commercially or otherwise" mean that a free installer is forbidden
too. Re-recording, time-stretching or slicing does not help, since the clause covers repackaging "in
whole or in part". Apple Loops may only be used in the owner's own songs.

### Installed locally (`/Library/Audio/Apple Loops`)

`find -iname '*hat*' -o -iname '*hi-hat*' -o -iname '*hihat*' -o -iname '*hh*' -o -iname '*cymbal*'`, files only.
1,745 loop files are installed in total.

| Folder | Hi-hat-named files |
|---|---|
| Apple/02 Electro House | 8 |
| Apple/07 Chillwave | 2 |
| Apple/09 Disco Funk | 3 |
| Apple/10 Vintage Breaks | 2 |
| **Total** | **15** (14 with `*hat*` / `*hi-hat*` alone) |

None of them can be shipped.

---

## 2. Free sources: licence check

| Source | Licence | Redistribution clause (quoted) | Bundle in plug-in? |
|---|---|---|---|
| **Freesound, CC0 filter** (https://freesound.org) | CC0 1.0 per sound | CC0 legal code section 2: the affirmer waives all rights "(iv) for any purpose whatsoever, including without limitation commercial, advertising or promotional purposes" (https://creativecommons.org/publicdomain/zero/1.0/legalcode.en). Freesound FAQ: with CC0 "you can do pretty much what you want with the sound" (https://freesound.org/help/faq/). | **OK to bundle**, per sound, after a provenance check (see caveat) |
| Freesound, CC-BY | CC BY 3.0/4.0 | FAQ: "you should always mention the original creators of the sounds when you use them" | **OK with attribution** (credits file in the installer/About box). Use only if CC0 runs out. |
| Freesound, CC-BY-NC / Sampling+ | NC | FAQ: "you can't earn any money with the piece of work you create" | **NOT OK** (excluded, even for a free installer, to keep things clean) |
| Freesound API terms (https://freesound.org/help/tos_api/) | API ToS | Content may be used "in accordance with the applicable Content license/s"; prohibited: to "commercialize ... Content in breach of the Content Licenses"; "Terms for commercial use of the API will be negotiated on a case by case basis with UPF" | The API is only a **sourcing tool** (offline, one time). The plug-in never calls the API, so the commercial-API clause does not apply. The sounds' own licence (CC0) governs. |
| **VCSL, Versilian Community Sample Library** (https://github.com/sgossner/VCSL) | CC0 1.0 | README: "This collection is under a Creative Commons 0 license." (repo licence: CC0-1.0) | **OK to bundle** |
| DrumGizmo DRSKit, MuldjordKit, CrocellKit (https://drumgizmo.org/wiki/doku.php?id=kits:drskit) | CC BY 4.0 | "The DRSKit drumkit source files are released under the Creative Commons Attribution 4.0 International License." | **OK with attribution.** These are multi-mic kits, so the hats need a mixdown. |
| AVL Drumkits (https://www.bandshed.net/avldrumkits/) | CC BY-SA 3.0 | "licensed" under CC-BY-SA 3.0; attribution "is only required if you modify or fork the samples and library formats themselves." | **Unclear.** Share-alike would follow the samples into our bundle, and the samples would have to stay CC BY-SA. Avoid. |
| Looperman (https://www.looperman.com/help/terms) | Custom | Loops licensed for use "in new and original recordings of new and original musical and/or lyrical compositions" and "solely as they are embodied in the Derivative Works"; "The licences ... are non-transferable" | **NOT OK** |
| 99Sounds (https://99sounds.org/license/) | Custom | "You do not have the right to sell or redistribute (even for free) the audio files downloaded from 99Sounds ... on their own or as a separate attachment from any of your work." | **NOT OK** |
| Pixabay sound effects (https://pixabay.com/service/license-summary/) | Pixabay Content Licence | "You cannot sell or distribute Content (either in digital or physical form) on a Standalone basis." "Standalone means where no creative effort has been applied to the Content" | **NOT OK** (a loop in a loop browser is standalone) |
| Splice Sounds (https://splice.com/terms) | Splice ToS 2.3.1.4 | Forbidden: to "redistribute Sounds in new sample packs"; to "sublicense the Sounds in isolation as sound effects, loops, or as source material for any other form of sample"; to "use or sublicense Sounds in a manner competitive to DCI or its licensors" | **NOT OK** |
| Typical free/"royalty-free" packs (Cymatics, MusicRadar SampleRadar, BPB freebies, Samples From Mars freebies) | Custom | Licence pages not reachable (404) at research time. These packs follow the same pattern as above (use in your music, no redistribution of the raw samples). | **NOT OK** unless a pack's licence explicitly says otherwise |
| Apple Loops | Logic/GarageBand SLA | see section 1 | **NOT OK** |

### Caveat for Freesound CC0

CC0 is only as good as the uploader's claim. Freesound forum and KVR threads
(https://www.kvraudio.com/forum/viewtopic.php?p=7249270) warn that people sometimes upload loops cut from
commercial packs and mark them CC0. A sample-pack-style redistribution is the use that would surface such
a problem. Mitigation:

- Prefer uploaders who record or synthesize their own material, and skip anything that looks like a
  commercial loop (pack-style names such as `XX_120_hat_loop_03.wav`, or obviously over-produced audio).
- Keep a provenance log in the project for every shipped file: Freesound sound ID, URL, uploader, licence
  at download time, download date. Store a copy of the sound page (PDF/HTML).
- Rename files to our own scheme (`<genre>_hat_loop_KJ_v001.wav` style per the house naming rule). CC0 needs
  no credit, but crediting uploaders in an About/credits file is a nice gesture.

---

## 3. Volume per genre (OK sources only)

### Freesound CC0 hit counts

Counts from the freesound.org text search with the filter `license:"Creative Commons 0"` on 2026-11-20.
Query = `hat loop <genre>`. These are **raw hits**. They include full drum loops whose description
mentions hats, duplicates and low-quality uploads. Only the first result page of "hihat loop" was
spot-checked (about 8 of 15 titles were clear hat loops). The assumption here is that roughly 20 to 40 %
of hits are isolated hat or top loops, and fewer still pass a quality bar. The "realistic" column is an estimate
of usable, isolated, decent-sounding hat loops.

| Genre (preset BPM) | Raw CC0 hits | Realistic usable hat loops | 10 reachable? |
|---|---|---|---|
| House 4/4 (124) | 110 | 15–25 | yes |
| Deep House (120) | 30 | 5–10 (share the House pool) | with House pool |
| Tech House (126) | 8 | 2–4 (share the House/Techno pool) | with pool |
| Techno (130) | 74 | 15–20 | yes |
| Minimal Techno (125) | 33 | 6–10 | borderline |
| Trap (140) | 51 | 10–15 | yes |
| Boom Bap (92) | 1 (+125 "hip hop") | 10–20 via "hip hop" | yes |
| Lo-Fi Hip Hop (80) | 23 | 5–8 (+ hip hop pool) | with pool |
| Drum & Bass (174) | 41 "dnb" / 154 "drum bass" | 10–20 | yes |
| Jungle (170) | 2 | 0–2 (+ DnB pool) | no, use the DnB pool or generate |
| UK Garage (135) | 8 | 2–4 | no |
| 2-Step (132) | 3 | 0–2 | no |
| Dubstep (140) | 25 | 4–8 (half-time, shares the Trap/140 pool) | borderline |
| Disco (118) | 0 | 0 | no |
| Funk (110) | 12 | 3–5 | no |
| Breakbeat (138) | 23 | 4–8 | borderline |
| Rock (120) | 25 | 5–10 (acoustic) | borderline |
| Reggaeton / Dembow (95) | 0 | 0 | no |
| Afrobeats (108) | 0 ("afro": 0) | 0 (shaker loops: 110 generic CC0 hits) | no |
| Pop (116) | 15 | 3–6 | no |
| Gamelan (110) | 6 "gamelan loop" / 149 "gamelan" | 0 hat loops. Gamelan has no hi-hat; use ceng-ceng/gong one-shots | generate |
| Afro Poly (104) | 0 | 0 (shaker/tribal percussion: 58 CC0 hits) | no |
| Afro House (120) | 0 | 0 (House pool + shakers) | no |
| Tropical (118) | 0 | 0 | no |
| Ritual (88) | 0 ("percussion loop tribal": 58) | 0–5 shaker loops | no |

Totals: "hihat loop" gives 451 CC0 hits (1,276 under all licences), "hi-hat loop" 546, "hat loop" 729,
"hihat loop bpm" 205, "shaker loop" 110.

**Result:** Freesound CC0 realistically covers about 8 to 10 genres (House, Techno, Trap, Hip-Hop/Boom Bap,
DnB, plus Minimal, Rock, Breakbeat and Dubstep at a stretch). It does **not** cover Disco, Reggaeton,
Afrobeats, Afro House, Afro Poly, Tropical, Ritual, Gamelan, UK Garage/2-Step or Jungle.

### Tempo metadata

- **Filename/title:** frequently, but inconsistently. Examples from the CC0 list: "Hi-Hat Loop 8 (100
  bpm).mp3", "Drum&Bass Fast Synth HiHat Loop 160 BPM", "Among Us Hihat Loop [130 BPM]",
  "134-hi-hats-more-hats.wav" (number without unit), "81_gritdrumloop.wav". Some carry it only as a tag
  ("100-bpm", "140bpm"), some not at all.
- **API analysis:** every sound has `bpm` (beat-tracker estimate, filterable, e.g. `filter=bpm:[120 TO 130]`),
  `bpm_confidence`, `beat_count`, `beat_times`, `onset_times` and `loopable` (bool). The estimate is
  unreliable for sparse hat loops (half/double-time errors are common), so derive the tempo from
  `duration / bars` and check by ear. Store the verified BPM and bar count in our own manifest, not in the
  filename alone.

### Access

| Source | Method |
|---|---|
| Freesound | Free account. API key (token) is enough for search, metadata and previews: `GET https://freesound.org/apiv2/search/?query=hat+loop&filter=license:"Creative Commons 0" bpm:[120 TO 130]&fields=id,name,license,bpm,bpm_confidence,loopable,duration,username,url`. **Downloading originals requires OAuth2** (`/apiv2/sounds/<id>/download/`). Alternatively, download by hand on the website while logged in. Pull only shortlisted files, never bulk. |
| VCSL | Direct: GitHub repo `sgossner/VCSL`, folder `Idiophones/Struck Idiophones/` (sparse checkout of only the needed folders; the whole repo is large). |
| DrumGizmo kits | Direct zip download from drumgizmo.org (large multi-mic kits). |

### VCSL percussion relevant to hats (CC0, file counts from the repo tree)

| Folder | Files | Use |
|---|---|---|
| Hi-Hat Cymbal | 15 (closed rr1/rr2, HitC v1–v4 × rr1/rr2, HitLoose …) | acoustic closed/loose hat multisample: 4 velocity layers, 2 round robins |
| Shaker, Small / Shaker, Large | 16 / 6 | Afrobeats, Afro House, Reggaeton, Tropical, Ritual |
| Cabasa | 6 | Afro/Latin tops |
| Tambourine 1 / 2 | 7 / 7 | Disco, Funk, Pop, Motown-style tops |
| Agogo Bells | 15 | Afro Poly, Ritual |
| Gong 1 (+ Gong 2), Balafon (54) | 7 / 54 | Gamelan-ish metallic tops |

---

## 4. Alternative: generate the loops ourselves (recommended)

Licensing is clean: the output is our own performance data rendered through our own DSP or through CC0
samples. Nothing third-party is redistributed except CC0 one-shots, and those need no credit.

### What "organic" needs

1. **Micro-timing:** per-hit offsets of ±2 to 15 ms, pushed or laid back per genre (Boom Bap/Lo-Fi
   behind the beat, DnB ahead, Garage/2-Step swung 16ths at about 58–66 %). Add slow drift across the bar
   (correlated noise, not white noise) so a 2- or 4-bar loop breathes.
2. **Velocity curves:** accent maps per genre (downbeat/offbeat emphasis, "push-pull" 16ths), ±8–15 %
   random spread, and occasional ghost notes.
3. **Articulation variation:** closed / loose / open / pedal / choked open (open hat choked by the next
   closed hit), round-robin sample selection, and slight pitch/decay variation per hit.
4. **Length:** 2- or 4-bar loops with a variation in the last bar, so the 10 loops per genre differ in
   density (8ths, 16ths, triplets for Trap rolls, 32nd fills).

### Two render paths

| Path | Sound | Effort | Notes |
|---|---|---|---|
| A. Plug-in's own `Hat` voice (`DSP/DrumVoices.hpp`, class `Hat`, CHR WHT/MET/PED/909/808, free-running oscillators, two-stage envelope, velocity-dependent tone) | electronic/analog | small: the engine already has per-step swing (`stepSwing`), velocity and open/closed. Needs per-hit timing offsets and decay/tone jitter. | Good for House, Techno, Minimal, Trap, Dubstep, UK Garage, 2-Step, Breakbeat. Not "organic" for Funk/Rock/Afro. |
| B. CC0 acoustic one-shots (VCSL hats, shakers, tambourines, cabasa, agogo + Freesound CC0 one-shots) | organic/acoustic | medium: a small sample player voice (round robin, velocity layers, choke group). Either ship the one-shots plus pattern data, or pre-render 24-bit WAV loops offline. | Covers Disco, Funk, Rock, Pop, Boom Bap, Lo-Fi, Jungle, Afrobeats, Afro House, Afro Poly, Reggaeton, Tropical, Ritual, Gamelan (gong/agogo/balafon tops). |

**Best variant: ship patterns, not audio.** If a LOOPS entry is a humanized event list (time offset,
velocity, articulation) that plays one-shots in real time, then:

- tempo sync is exact at any host tempo, with no time-stretch, no artifacts and no transient smearing
  (offsets scale with the beat);
- the installer stays small (a few MB of one-shots instead of 250 loops × several MB);
- each loop can be re-humanized on every pass ("feel" or "amount" knob).

Pre-rendering through `DSP/DrumsOffline.hpp` (`renderOffline` + `writeWav24`) remains an option for
users who want to drag audio out.

**Effort estimate:** pattern authoring for 25 genres × 10 loops (a generator script with per-genre
groove templates, then curation by ear): 1–2 days. Sample-player voice with round robin, velocity layers
and choke: 1–2 days. LOOPS row UI (genre → loop picker): about 1 day. Total about 1 week, with no
licensing risk.

---

## 5. Time-stretch library (needed only for real audio loops)

| Library | Licence (verified from repo) | OK? |
|---|---|---|
| **Signalsmith Stretch**, https://github.com/Signalsmith-Audio/signalsmith-stretch | `LICENSE.txt`: **"MIT License / Copyright (c) 2022 Geraint Luff / Signalsmith Audio Ltd."** with the standard MIT grant ("to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies ..."; condition: "The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software."). Header-only C++11; last push 2026-10-22. | **YES** |
| ↳ dependency `signalsmith-linear` (`#include "signalsmith-linear/stft.h"`), https://github.com/Signalsmith-Audio/linear | `LICENSE.txt`: "MIT License / Copyright (c) 2025 Signalsmith Audio" | **YES** |
| Rubber Band, breakfastquay/rubberband | GPL-2.0 (commercial licence sold separately) | NO (GPL) |
| Bungee, kupix/bungee | MPL-2.0 | NO (outside the MIT/BSD/Apache/zlib set; file-level copyleft) |
| SoundTouch | LGPL-2.1 | NO (LGPL static linking in an AU appex is awkward) |

Integration notes for Signalsmith Stretch in the AU: call `presetDefault(channels, sampleRate)` once in
`prepare` (it allocates, so not on the audio thread). Per render block, call `process(in, inFrames, out,
outFrames)` with `inFrames = outFrames × hostBPM / loopBPM`, reading from the loop buffer with a
host-beat-locked read position, and re-seek on transport jumps. It adds latency (`inputLatency()` /
`outputLatency()`), so pre-roll the loop or report latency to the host. For hats, transients
matter: keep stretch ratios within about ±25 % by storing each loop at 2 or 3 source tempos (e.g. 90 /
125 / 170) and picking the nearest one.

Credit to add to the installer/About box: the MIT notice for Signalsmith Stretch and `linear`.
