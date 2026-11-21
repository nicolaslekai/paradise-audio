//
//  HandyEngine.hpp
//  2-zone sampler with warming chain. Each zone (pad) holds a mono float buffer
//  and covers a 16-note keyboard span. Zone 1 spans keys 1–16 (root C2 = 36),
//  zone 2 spans the next 16 keys (root E3 = 52 = 36 + kZoneSize). Incoming MIDI
//  notes are routed to whichever zone's span contains them, then played
//  pitch-shifted via varispeed (so dropping ONE sample on a zone makes its
//  whole span playable chromatically). Each zone has a CHOP knob (4 algorithms:
//  forward / reverse / stutter / halftime), a KEY-TRIGGER switch (GATE = play
//  while held, vs 1-SHOT), and a normalized RANGE (start01..end01) selecting
//  which portion of the loaded sample actually plays. A single global PITCH
//  knob transposes the whole instrument (-24..+24 semitones). The pad array is
//  still sized kNumPads (4) for back-compat with saved state, but only the
//  first two are surfaced as zones in the UI.
//

#pragma once
#include "DSPCommon.hpp"
#include <atomic>

namespace hdy {

constexpr int kNumPads   = 4;  // storage slots (zones 1..2 are surfaced in UI)
constexpr int kNumZones  = 2;  // large stacked sample boxes
constexpr int kMaxVoices = 16;
constexpr int kMidiBase  = 36; // zone 1 root = C2 (36) — first of the 32 keys
constexpr int kZoneSize  = 16; // each zone covers 16 MIDI notes (16 keys)
// SampleStore decodes every file to this rate (and fullState stores it so).
// Playback compensates for the host rate, otherwise a 44.1 kHz project plays
// every zone ~1.4 semitones flat and a 96 kHz one an octave up.
constexpr float kStoreRate = 48000.0f;

enum ChopAlgo : int {
    kChopForward = 0,
    kChopReverse = 1,
    kChopStutter = 2,
    kChopHalfTime = 3
};

class Voice {
public:
    void reset() { active = false; padIndex = -1; pos = 0; vel = 0; ratio = 1.0f; algo = kChopForward; noteNum = -1; releaseEnv = 0; releasing = false; winStart = 0; winLen = 0; holdLoop = false; fadeIn = 0; relMul = 0.9985f; }

    // 4-point Hermite read of the pad buffer at a fractional index (clamped at
    // the buffer ends). The old 2-point linear read dulled the top end and
    // added interpolation noise whenever a pad was played off its root pitch.
    static inline float readAt(const float *buf, int bufLen, int i0, float frac) {
        const int im = (i0 > 0) ? i0 - 1 : 0;
        const int i1 = (i0 + 1 < bufLen) ? i0 + 1 : bufLen - 1;
        const int i2 = (i0 + 2 < bufLen) ? i0 + 2 : bufLen - 1;
        const float xm = buf[im], x0 = buf[i0], x1 = buf[i1], x2 = buf[i2];
        const float c1 = 0.5f * (x1 - xm);
        const float c2 = xm - 2.5f * x0 + 2.0f * x1 - 0.5f * x2;
        const float c3 = 0.5f * (x2 - xm) + 1.5f * (x0 - x1);
        return ((c3 * frac + c2) * frac + c1) * frac + x0;
    }

    inline float process(const float *buf, int bufLen) {
        if (!active) return 0.0f;
        if (!buf || bufLen <= 1) { active = false; return 0.0f; }   // pad was cleared under us
        // RANGE: read only within the selected window [winStart, winStart+winLen).
        // The window is captured at spawn from the zone's start01/end01. All
        // chop math runs in window-local coordinates, then we add winStart for
        // the final buffer fetch. Guard against a degenerate window.
        const int wStart = (winLen > 1) ? winStart : 0;
        const int wLen   = (winLen > 1) ? winLen   : bufLen;
        // Map the canonical (forward) read position into the algorithm-specific
        // window-local index.
        // (double: a float read position only resolves 1/32 sample 5 s into a
        // sample and 1/4 sample after 45 s, so any pitched or rate-converted
        // playback of a long loop drifted off pitch in steps — a 48 kHz loop in a
        // 44.1 kHz project ended up a semitone and a half flat.)
        double readPos = pos;
        // De-click gain: every place the read head starts, stops or jumps inside
        // the audio gets a ~1.5 ms ramp (edge = distance to that point, in
        // OUTPUT samples). Before, a RANGE that started or ended mid-waveform,
        // every REV start and every STUT repeat was a hard step = a click.
        float edge = 1e9f;                       // output samples to the nearest cut
        const float inv = 1.0f / std::max(0.05f, ratio);
        switch (algo) {
            case kChopReverse:
                readPos = (double)(wLen - 1) - pos;
                if (readPos < 0) { active = false; return 0.0f; }
                edge = (float)readPos * inv;     // running out at the window start
                break;
            case kChopStutter: {
                // Loop a small chunk of the window (1/8th) to create stutter.
                const double chunk = (double)wLen / 8.0;
                readPos = std::fmod(pos, chunk);
                edge = (float)std::min(readPos, chunk - readPos) * inv;   // both sides of the repeat
                if (pos < chunk * 0.5) edge = (float)(chunk - readPos) * inv;   // first pass: natural start
                break;
            }
            case kChopHalfTime:
                // Halve the read rate — engine already increments pos by `ratio`
                // each frame; halve the effective position so it plays back at
                // half speed (one octave down + 2× duration).
                readPos = pos * 0.5;
                edge = (float)((double)(wLen - 1) - readPos) * inv * 2.0f;
                break;
            case kChopForward:
            default:
                edge = (float)((double)(wLen - 1) - readPos) * inv;
                break;
        }
        // End of the window. REV finishes through its own `readPos < 0` test
        // above (its readPos STARTS at wLen-1, so the forward test would have
        // killed every reverse note on its first sample). STUT loops for as
        // long as the key is held in GATE mode; in 1-SHOT it runs for the
        // window's natural length and then stops instead of looping forever.
        if (algo == kChopStutter) {
            if (!holdLoop && pos >= (double)(wLen - 1)) { active = false; return 0.0f; }
        } else if (algo != kChopReverse && readPos >= (double)(wLen - 1)) {
            active = false; return 0.0f;
        }
        // Window-local → absolute buffer index, clamped into the buffer.
        const int   i0 = std::min(wStart + (int)readPos, bufLen - 1);
        const float frac = (float)(readPos - (double)(int)readPos);
        float s = readAt(buf, bufLen, i0, frac);
        pos += (double)ratio;
        // ramps: cut points (edge) and the note start when it is not the natural
        // start of the sample (fadeIn counts output samples since spawn)
        if (edge < fadeLen) s *= std::max(0.0f, edge) / fadeLen;
        if (fadeIn < fadeLen) { if (softStart) s *= fadeIn / fadeLen; fadeIn += 1.0f; }
        // Key-trigger release ramp: when noteOff arrives, releasing=true
        // and the voice fades out over ~15 ms instead of cutting hard
        // (avoids click). Voice deactivates when env hits ~0.
        if (releasing) {
            releaseEnv *= relMul;      // ~15 ms decay (rate-compensated)
            if (releaseEnv < 0.001f) { active = false; return 0.0f; }
            return s * vel * releaseEnv;
        }
        return s * vel;
    }
    bool  active = false;
    int   padIndex = -1;
    double pos = 0.0;     // canonical (forward) read position, in pad samples
    float vel = 1.0f;
    float ratio = 1.0f;   // varispeed read rate (1.0 = root pitch)
    int   algo = kChopForward;
    int   noteNum = -1;   // MIDI note that triggered this voice (for key-trigger noteOff)
    bool  releasing = false; // when keyTrigger=true and noteOff received, voice ramps out
    float releaseEnv = 0.0f; // 1.0 -> 0.0 during release
    int   winStart = 0;   // RANGE window start (absolute sample index)
    int   winLen   = 0;   // RANGE window length in samples (0 = whole buffer)
    bool  holdLoop = false; // GATE zone: STUT keeps looping until note-off
    float fadeIn = 0.0f;    // output samples since spawn (for the soft start)
    float fadeLen = 72.0f;  // de-click ramp length in output samples (~1.5 ms)
    bool  softStart = false; // the note starts inside the audio (RANGE start > 0 / REV)
    float relMul = 0.9985f; // per-sample release multiplier (set from the sample rate)
};
// Simple per-channel warming chain: tilt EQ, downward expander, soft tanh.
class WarmingChain {
public:
    void prepare(float sr) {
        sr_ = sr;
        for (int ch = 0; ch < 2; ++ch) { lp_[ch] = 0; env_[ch] = 0; dcX_[ch] = 0; dcY_[ch] = 0; }
        // The chain was voiced at 48 kHz with per-sample constants (crossover
        // coefficient 0.12, attack 0.5, release recomputed with exp() on every
        // sample). Keep exactly that voicing, but as times / frequencies, so a
        // 44.1 or 96 kHz project sounds the same: 0.12 @ 48k = 977 Hz,
        // 0.5 @ 48k = a 30 µs attack.
        lpCoeff_  = 1.0f - std::exp(-2.0f * kPi * 976.6f / sr_);
        atkCoeff_ = 1.0f - std::pow(0.5f, 48000.0f / sr_);
        relCoeff_ = timeToCoeff(80.0f, sr_);
        dcR_      = 1.0f - 2.0f * kPi * 5.0f / sr_;          // 5 Hz DC blocker
        kSmooth_  = 1.0f - std::exp(-1.0f / (0.010f * sr_)); // 10 ms control smoothing
        snap_ = true;
    }
    void setHF(float v)        { hf_       = clamp(v, 0.0f, 1.0f); }
    void setNoiseDB(float db)  { nrThrDB_  = db; }
    void setTransient(float t) { trans_    = clamp(t, -1.0f, 1.0f); }
    void setWarmth(float w)    { warm_     = clamp(w, 0.0f, 1.0f); }
    void setLevelDB(float db)  { outGain_  = dbToLin(db); }
    void setMix(float m)       { mix_      = clamp(m, 0.0f, 1.0f); }
    /// Once per frame, before the per-channel process(): smooth the controls
    /// (they used to step once per host buffer — TRANS zippered at −29 dBFS).
    inline void tick() {
        if (snap_) { outS_ = outGain_; mixS_ = mix_; hfS_ = hf_; trS_ = trans_; warmS_ = warm_; nrS_ = nrThrDB_; snap_ = false; }
        outS_  += kSmooth_ * (outGain_ - outS_);
        mixS_  += kSmooth_ * (mix_ - mixS_);
        hfS_   += kSmooth_ * (hf_ - hfS_);
        trS_   += kSmooth_ * (trans_ - trS_);
        warmS_ += kSmooth_ * (warm_ - warmS_);
        nrS_   += kSmooth_ * (nrThrDB_ - nrS_);
        if (std::fabs(trans_ - trS_) < 1e-5f) trS_ = trans_;
    }
    inline float process(int ch, float dry, float x) {
        lp_[ch] += lpCoeff_ * (x - lp_[ch]);
        const float hi = x - lp_[ch];
        const float hiBoost = hi * (1.0f + hfS_ * 1.5f);
        const float hiSat   = std::tanh(hiBoost * (1.0f + hfS_));
        x = lp_[ch] + hiSat;
        const float absX = std::fabs(x);
        const float a = (absX > env_[ch]) ? atkCoeff_ : relCoeff_;
        env_[ch] += a * (absX - env_[ch]);
        const float envDB = linToDb(env_[ch]);
        if (envDB < nrS_) {
            const float diff = nrS_ - envDB;
            const float reduce = std::min(1.0f, diff * 0.05f);
            x *= (1.0f - reduce);
        }
        if (trS_ != 0.0f) {
            const float fast = absX;
            const float slow = env_[ch];
            x += (fast - slow) * trS_;
        }
        const float drive = 1.0f + warmS_ * 1.4f;
        x = std::tanh(x * drive) / drive;
        // The TRANS term adds a rectified copy of the signal, i.e. a DC offset
        // that follows the level (about −19 dB below a sustained tone at the
        // default +0.30). Block it so the pads don't thump the bus / eat headroom.
        float y = x - dcX_[ch] + dcR_ * dcY_[ch];
        dcX_[ch] = x; dcY_[ch] = y;
        // Re-centred, an asymmetric waveform can reach further than the soft
        // clipper's ±1/drive (hard-driven chords came out near full scale).
        // Guard: untouched below 0.9, eased into a ceiling of 1.0 above it, so
        // the chain still never exceeds 0 dBFS before LEVEL.
        const float ay = std::fabs(y);
        if (ay > 0.9f) y = std::copysign(0.9f + 0.1f * std::tanh((ay - 0.9f) * 10.0f), y);
        const float wet = y * outS_;
        return (1.0f - mixS_) * dry + mixS_ * wet;
    }
private:
    float sr_ = 48000;
    float lp_[2] = {0, 0};
    float env_[2] = {0, 0};
    float dcX_[2] = {0, 0}, dcY_[2] = {0, 0};
    float lpCoeff_ = 0.12f, atkCoeff_ = 0.5f, relCoeff_ = 0.00026f, dcR_ = 0.9993f;
    float kSmooth_ = 0.002f, outS_ = 1.0f, mixS_ = 1.0f;
    float hfS_ = 0.65f, trS_ = 0.30f, warmS_ = 0.40f, nrS_ = -18.0f;
    bool  snap_ = true;
    float hf_ = 0.65f, nrThrDB_ = -18.0f, trans_ = 0.30f, warm_ = 0.40f;
    float outGain_ = 1.0f, mix_ = 1.0f;
};

class HandyEngine {
public:
    void prepare(float sr) {
        sr_ = sr;
        warm_.prepare(sr);
        for (auto &v : voices_) v.reset();
        for (auto &v : tails_)  v.reset();
        // The per-pad settings (root, pitch, chop, range) are NOT touched here:
        // prepare() runs on every re-allocate (buffer-size or sample-rate
        // change, bounce), and it used to reset them to their defaults — after
        // which a restored project played every zone at chop/pitch/range zero
        // until the editor pushed them again. Their defaults live in the member
        // initialisers below.
    }
    void reset() { for (auto &v : voices_) v.reset(); for (auto &v : tails_) v.reset(); }

    // Sample storage
    void setSample(int pad, const float *data, int len) {
        if (pad < 0 || pad >= kNumPads) return;
        // Voices still reading this pad would dereference the old buffer
        // after `assign` frees it — stop them first. (The AU also holds the
        // engine lock here and the render block try-locks it, so the audio
        // thread never runs concurrently with the swap.)
        for (auto &v : voices_) if (v.active && v.padIndex == pad) v.reset();
        for (auto &v : tails_)  if (v.active && v.padIndex == pad) v.reset();
        if (data && len > 0) pads_[pad].assign(data, data + len);
        else                 pads_[pad].clear();
    }
    /// Copy up to `maxFrames` of a pad's mono buffer into `dst` (UI: waveform
    /// peaks after a project reload). Returns the frames copied.
    int copySample(int pad, float *dst, int maxFrames) const {
        if (pad < 0 || pad >= kNumPads || !dst || maxFrames <= 0) return 0;
        const int n = std::min(maxFrames, (int)pads_[pad].size());
        if (n > 0) std::copy(pads_[pad].begin(), pads_[pad].begin() + n, dst);
        return n;
    }
    void clearSample(int pad) { setSample(pad, nullptr, 0); }
    int  sampleLength(int pad) const { return (pad >= 0 && pad < kNumPads) ? (int)pads_[pad].size() : 0; }
    bool hasSample(int pad) const { return sampleLength(pad) > 0; }
    /// Raw mono buffer pointer for a pad (nullptr if empty). Used by the AU to
    /// serialise the loaded sample into its saved state.
    const float *sampleData(int pad) const {
        return (pad >= 0 && pad < kNumPads && !pads_[pad].empty()) ? pads_[pad].data() : nullptr;
    }

    // Per-pad pitch trim (-24..+24 st = ±2 octaves) and chop knob (0..1 picks algorithm)
    void setPitchSemi(int pad, float st) {
        if (pad >= 0 && pad < kNumPads) pitchSemi_[pad] = clamp(st, -24.0f, 24.0f);
    }
    float pitchSemi(int pad) const { return (pad >= 0 && pad < kNumPads) ? pitchSemi_[pad] : 0.0f; }

    void setChop(int pad, float knob01) {
        if (pad >= 0 && pad < kNumPads) chopKnob_[pad] = clamp(knob01, 0.0f, 1.0f);
    }
    float chop(int pad) const { return (pad >= 0 && pad < kNumPads) ? chopKnob_[pad] : 0.0f; }

    // RANGE selector — normalized [0,1] start/end picking the portion of the
    // loaded sample that actually plays. end is kept >= start + small epsilon so
    // the window never collapses to zero. New voices read this window; voices
    // already sounding keep the window they were spawned with.
    void setRange(int pad, float start01, float end01) {
        if (pad < 0 || pad >= kNumPads) return;
        float s = clamp(start01, 0.0f, 1.0f);
        float e = clamp(end01,   0.0f, 1.0f);
        if (e < s + 0.01f) e = std::min(1.0f, s + 0.01f);
        if (s > e - 0.01f) s = std::max(0.0f, e - 0.01f);
        start01_[pad] = s; end01_[pad] = e;
    }
    float rangeStart(int pad) const { return (pad >= 0 && pad < kNumPads) ? start01_[pad] : 0.0f; }
    float rangeEnd(int pad)   const { return (pad >= 0 && pad < kNumPads) ? end01_[pad]   : 1.0f; }

    // Global PITCH transpose (-24..+24 semitones) applied to every zone.
    void  setTranspose(float st) { transpose_ = clamp(st, -24.0f, 24.0f); }
    float transpose() const { return transpose_; }

    /// KEY TRIGGER mode (per pad). When true, noteOff stops the playing
    /// voice (gate mode — sample only plays while key held). When false,
    /// noteOff is ignored and the sample plays through to its end (one-shot).
    /// Default is false (one-shot) so existing behaviour is preserved.
    void setKeyTrigger(int pad, bool on) {
        if (pad >= 0 && pad < kNumPads) keyTrigger_[pad] = on;
    }
    bool keyTrigger(int pad) const { return (pad >= 0 && pad < kNumPads) && keyTrigger_[pad]; }

    void setRootNote(int pad, int midiNote) {
        if (pad >= 0 && pad < kNumPads) rootNote_[pad] = std::max(0, std::min(127, midiNote));
    }
    int rootNote(int pad) const { return (pad >= 0 && pad < kNumPads) ? rootNote_[pad] : kMidiBase; }

    // Pick the pad whose zone contains the incoming note. Falls back to the
    // nearest pad whose root is closest to the note.
    int padForNote(int note) const {
        // Prefer the zone whose 16-key span actually contains the note.
        for (int i = 0; i < kNumZones; ++i) {
            if (!hasSample(i)) continue;
            if (note >= rootNote_[i] && note < rootNote_[i] + kZoneSize) return i;
        }
        // Fallback: nearest-root zone that has a sample.
        int best = -1, bestDist = 999;
        for (int i = 0; i < kNumZones; ++i) {
            if (!hasSample(i)) continue;
            int d = std::abs(note - rootNote_[i]);
            if (d < bestDist) { bestDist = d; best = i; }
        }
        return best;
    }

    // Trigger a pad without keyboard-spread (UI audition click — original pitch).
    void triggerPad(int pad, float velocity) {
        if (pad < 0 || pad >= kNumPads || !hasSample(pad)) return;
        // Audition at root pitch + global transpose so the click preview matches
        // what the keyboard plays at the zone root.
        const float ratio = std::pow(2.0f, (pitchSemi_[pad] + transpose_) / 12.0f);
        spawn(pad, ratio, velocity);
    }

    // MIDI note-on: route to the pad whose zone contains the note, play
    // pitch-shifted via varispeed.
    void noteOn(int noteNum, int velocity) {
        if (noteNum < 0 || noteNum > 127) return;
        int pad = padForNote(noteNum);
        if (pad < 0 || !hasSample(pad)) return;
        const float offsetSemi = (float)(noteNum - rootNote_[pad]) + pitchSemi_[pad] + transpose_;
        const float ratio = std::pow(2.0f, offsetSemi / 12.0f);
        spawn(pad, ratio, std::min(1.0f, std::max(0.0f, velocity / 127.0f)), noteNum);
    }

    // MIDI note-off: if any voice with matching noteNum is on a pad with
    // keyTrigger=true, start its release ramp. Otherwise ignored.
    void noteOff(int noteNum) {
        if (noteNum < 0 || noteNum > 127) return;
        for (auto &v : voices_) {
            if (!v.active || v.noteNum != noteNum) continue;
            if (v.padIndex >= 0 && v.padIndex < kNumPads && keyTrigger_[v.padIndex]) {
                v.releasing = true;
                v.releaseEnv = 1.0f;
            }
        }
    }

    // Warming chain forwards
    void setHF(float v)       { warm_.setHF(v); }
    void setNoiseDB(float db) { warm_.setNoiseDB(db); }
    void setTransient(float t){ warm_.setTransient(t); }
    void setWarmth(float w)   { warm_.setWarmth(w); }
    void setLevelDB(float db) { warm_.setLevelDB(db); }
    void setMix(float m)      { warm_.setMix(m); }

    inline void processFrame(float& outL, float& outR) {
        float sum = 0.0f;
        for (auto &v : voices_) {
            if (!v.active) continue;
            const auto &buf = pads_[v.padIndex];
            sum += v.process(buf.data(), (int)buf.size());
        }
        for (auto &v : tails_) {                 // stolen voices fading out
            if (!v.active) continue;
            const auto &buf = pads_[v.padIndex];
            sum += v.process(buf.data(), (int)buf.size());
        }
        const float dry = sum;
        warm_.tick();
        outL = warm_.process(0, dry, sum);
        outR = warm_.process(1, dry, sum);

        // ── Output probe — peak-bucketed mono for the live UI scope. Cheap
        // (one abs + compare per sample), lock-free single-writer ring. ──
        const float a = std::fabs(0.5f * (outL + outR));
        if (a > probeAcc_) probeAcc_ = a;
        if (++probeDiv_ >= kProbeDecim) {
            probeDiv_ = 0;
            const int w = probeW_.load(std::memory_order_relaxed);
            probe_[w & kProbeMask] = probeAcc_;
            probeW_.store(w + 1, std::memory_order_relaxed);
            probeAcc_ = 0.0f;
        }
    }

    // Live output scope probe (UI thread reads the most-recent `count` peak
    // buckets, oldest→newest). ~0.68 s window at 48 kHz.
    static constexpr int probeSize() { return kProbeSize; }
    void readProbe(float *out, int count) const {
        const int n = std::min(count, kProbeSize);
        const int w = probeW_.load(std::memory_order_relaxed);
        for (int i = 0; i < n; ++i) {
            const int idx = (w - n + i) & kProbeMask;
            out[i] = probe_[idx];
        }
    }

private:
    int chopFromKnob(float k) const {
        if (k < 0.25f) return kChopForward;
        if (k < 0.50f) return kChopReverse;
        if (k < 0.75f) return kChopStutter;
        return kChopHalfTime;
    }

    void spawn(int pad, float ratio, float velocity, int noteNum = -1) {
        Voice *target = nullptr;
        for (auto &v : voices_) if (!v.active) { target = &v; break; }
        if (!target) {
            target = &voices_[0];
            for (auto &v : voices_) if (v.pos > target->pos) target = &v;
            // All 16 voices busy: the stolen one used to stop dead (click). Hand
            // it to a spare slot that fades it out over a few ms instead.
            Voice &t = tails_[tailNext_]; tailNext_ = (tailNext_ + 1) % kNumTails;
            t = *target;
            t.releasing = true; if (t.releaseEnv <= 0.0f || !target->releasing) t.releaseEnv = 1.0f;
            t.relMul = std::pow(0.001f, 1.0f / (0.004f * std::max(1.0f, sr_)));   // 4 ms to −60 dB
        }
        target->active = true;
        target->padIndex = pad;
        target->pos = 0.0;
        target->vel = velocity;
        target->ratio = std::max(0.05f, std::min(8.0f, ratio * (kStoreRate / std::max(1.0f, sr_))));
        target->algo = chopFromKnob(chopKnob_[pad]);
        target->holdLoop = keyTrigger_[pad];
        target->noteNum = noteNum;
        target->releasing = false;
        target->releaseEnv = 1.0f;
        target->relMul  = std::pow(0.9985f, 48000.0f / std::max(1.0f, sr_));   // ~15 ms at any rate
        target->fadeLen = std::max(8.0f, 0.0015f * sr_);
        target->fadeIn  = 0.0f;

        // RANGE → absolute sample window for this voice. Snapshot the zone's
        // normalized start/end against the current buffer length.
        const int len = (int)pads_[pad].size();
        int ws = (int)(start01_[pad] * (float)len);
        int we = (int)(end01_[pad]   * (float)len);
        ws = std::max(0, std::min(ws, len - 1));
        we = std::max(ws + 1, std::min(we, len));
        target->winStart = ws;
        target->winLen   = we - ws;
        // Soft start only where the note begins inside the audio; a pad played
        // from its natural start keeps its full transient.
        target->softStart = (ws > 0) || (target->algo == kChopReverse);
    }

    // Output scope probe (peak-bucketed ring). 256 buckets × 128 samples ≈
    // 32 768 samples ≈ 0.68 s @ 48 k.
    static constexpr int kProbeSize  = 256;
    static constexpr int kProbeMask  = kProbeSize - 1;
    static constexpr int kProbeDecim = 128;
    mutable float probe_[kProbeSize] = {0};
    mutable std::atomic<int> probeW_{0};
    int   probeDiv_ = 0;
    float probeAcc_ = 0.0f;

    float sr_ = 48000;
    std::vector<float> pads_[kNumPads];
    // Zone roots are set in prepare() to kMidiBase + i*kZoneSize:
    // zone 1 = C2 (36), zone 2 = E3 (52). These member initializers are just a
    // pre-prepare fallback (slots 3/4 are unused storage).
    int   rootNote_[kNumPads]  = {36, 52, 68, 84};
    float pitchSemi_[kNumPads] = {0, 0, 0, 0};
    float chopKnob_[kNumPads]  = {0, 0, 0, 0};
    // GATE (key-trigger) is the DEFAULT: a zone sounds only while the key is
    // held and ramps out on note-off. Click the GATE pill for 1-SHOT.
    bool  keyTrigger_[kNumPads] = {true, true, true, true};
    float start01_[kNumPads]   = {0, 0, 0, 0};   // RANGE start per zone
    float end01_[kNumPads]     = {1, 1, 1, 1};   // RANGE end per zone
    float transpose_ = 0.0f;                      // global PITCH knob (semitones)
    Voice voices_[kMaxVoices];
    static constexpr int kNumTails = 4;
    Voice tails_[kNumTails];           // stolen voices finishing their fade-out
    int   tailNext_ = 0;
    WarmingChain warm_;
};

}
