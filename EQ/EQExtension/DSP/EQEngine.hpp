//
//  EQEngine.hpp
//
//  6-band parametric EQ: HP → low shelf/bell → low-mid bell → high-mid bell
//  → high shelf/bell → LP, in series. Per-channel state, shared coefficients.
//
//  History:
//   v1 — 4 bands (HP / Low shelf / High shelf / LP)
//   v2 — added bell toggle on the low + high bands
//   v3 — added LM (low-mid) + HM (high-mid) peaking bands so the user has
//        actual mid-band points to drag on the curve.
//   v4 — selectable HP/LP slope: 12 dB/oct (single biquad, default — same as
//        before) or 24 dB/oct (a second cascaded Butterworth section). The
//        second stage is only run when engaged, so the default path and CPU
//        cost are unchanged.
//

#pragma once

#include "Biquad.hpp"
#include <atomic>
#include <cstring>
#include <cstdint>

namespace eq {

class EQEngine {
public:
    void prepare(float sampleRateHz) {
        sr_ = sampleRateHz;
        for (int ch = 0; ch < 2; ++ch) {
            hp_[ch].setType(Biquad::kHighPass);
            hp2_[ch].setType(Biquad::kHighPass);   // second HP section (24 dB/oct)
            ls_[ch].setType(Biquad::kLowShelf);
            lm_[ch].setType(Biquad::kPeaking);     // low-mid — always bell
            hm_[ch].setType(Biquad::kPeaking);     // high-mid — always bell
            hs_[ch].setType(Biquad::kHighShelf);
            lp_[ch].setType(Biquad::kLowPass);
            lp2_[ch].setType(Biquad::kLowPass);    // second LP section (24 dB/oct)
            hp_[ch].reset(); hp2_[ch].reset(); ls_[ch].reset();
            lm_[ch].reset(); hm_[ch].reset();
            hs_[ch].reset(); lp_[ch].reset(); lp2_[ch].reset();
        }
        // Control smoothing: the audio path follows `cur_`, which glides to the
        // knob values in ~20 ms, re-tuning the filters every 16 samples while
        // something moves. (They used to be re-tuned in one step per host buffer:
        // zipper on gain / cutoff automation.)
        kCtl_ = 1.0f - std::exp(-(float)kCtlBlock / (0.020f * sr_));
        snap_ = true; ctl_ = 0;
        cur_ = target();
        updateCoeffs();
    }

    void reset() {
        for (int ch = 0; ch < 2; ++ch) {
            hp_[ch].reset(); hp2_[ch].reset(); ls_[ch].reset();
            lm_[ch].reset(); hm_[ch].reset();
            hs_[ch].reset(); lp_[ch].reset(); lp2_[ch].reset();
        }
    }

    void setHPFreq(float hz)       { if (hz != hpHz_) { hpHz_ = hz; touch(); } }
    void setLowFreq(float hz)      { if (hz != lsHz_) { lsHz_ = hz; touch(); } }
    void setLowGainDB(float db)    { if (db != lsDB_) { lsDB_ = db; touch(); } }
    void setLowMidFreq(float hz)   { if (hz != lmHz_) { lmHz_ = hz; touch(); } }
    void setLowMidGainDB(float db) { if (db != lmDB_) { lmDB_ = db; touch(); } }
    void setLowMidQ(float q)       { if (q != lmQ_)  { lmQ_  = q;  touch(); } }
    void setHighMidFreq(float hz)  { if (hz != hmHz_) { hmHz_ = hz; touch(); } }
    void setHighMidGainDB(float db){ if (db != hmDB_) { hmDB_ = db; touch(); } }
    void setHighMidQ(float q)      { if (q != hmQ_)  { hmQ_  = q;  touch(); } }
    void setLowQ(float q)          { if (q != lsQ_)  { lsQ_  = q;  touch(); } }
    void setHighFreq(float hz)     { if (hz != hsHz_) { hsHz_ = hz; touch(); } }
    void setHighGainDB(float db)   { if (db != hsDB_) { hsDB_ = db; touch(); } }
    void setHighQ(float q)         { if (q != hsQ_)  { hsQ_  = q;  touch(); } }
    void setLPFreq(float hz)       { if (hz != lpHz_) { lpHz_ = hz; touch(); } }
    // Slope switches — false = 12 dB/oct (single section, default),
    // true = 24 dB/oct (a second cascaded Butterworth section is engaged).
    void setHPSlope24(bool b)      { if (b != hpSlope24_) { hpSlope24_ = b; for (int ch=0;ch<2;++ch) hp2_[ch].reset(); touch(); } }
    void setLPSlope24(bool b)      { if (b != lpSlope24_) { lpSlope24_ = b; for (int ch=0;ch<2;++ch) lp2_[ch].reset(); touch(); } }
    bool hpSlope24() const         { return hpSlope24_; }
    bool lpSlope24() const         { return lpSlope24_; }
    // Shape switches — false = shelf (default), true = peaking bell.
    void setLowIsBell(bool b)      { lowBell_ = b; for (int ch=0;ch<2;++ch) ls_[ch].setType(b ? Biquad::kPeaking : Biquad::kLowShelf); touch(); }
    void setHighIsBell(bool b)     { highBell_ = b; for (int ch=0;ch<2;++ch) hs_[ch].setType(b ? Biquad::kPeaking : Biquad::kHighShelf); touch(); }
    bool lowIsBell() const         { return lowBell_; }
    bool highIsBell() const        { return highBell_; }

    // Getters for the UI/AU layer
    float hpFreq() const           { return hpHz_; }
    float lowFreq() const          { return lsHz_; }
    float lowGainDB() const        { return lsDB_; }
    float lowQ() const             { return lsQ_; }
    float lowMidFreq() const       { return lmHz_; }
    float lowMidGainDB() const     { return lmDB_; }
    float lowMidQ() const          { return lmQ_; }
    float highMidFreq() const      { return hmHz_; }
    float highMidGainDB() const    { return hmDB_; }
    float highMidQ() const         { return hmQ_; }
    float highFreq() const         { return hsHz_; }
    float highGainDB() const       { return hsDB_; }
    float highQ() const            { return hsQ_; }
    float lpFreq() const           { return lpHz_; }

    inline void processFrame(float& left, float& right) {
        if (snap_) { cur_ = target(); updateCoeffs(); snap_ = false; ctl_ = 0; }
        else if (++ctl_ >= kCtlBlock) { ctl_ = 0; if (dirty_) glide(); }
        // Explicit chain so the optional 24 dB/oct second sections can be
        // inserted right after their first stage. Order: HP(→HP2) → low
        // shelf/bell → low-mid → high-mid → high shelf/bell → LP(→LP2).
        float l = left, r = right;
        l = hp_[0].process(l);   r = hp_[1].process(r);
        if (hpSlope24_) { l = hp2_[0].process(l); r = hp2_[1].process(r); }
        l = ls_[0].process(l);   r = ls_[1].process(r);
        l = lm_[0].process(l);   r = lm_[1].process(r);
        l = hm_[0].process(l);   r = hm_[1].process(r);
        l = hs_[0].process(l);   r = hs_[1].process(r);
        l = lp_[0].process(l);   r = lp_[1].process(r);
        if (lpSlope24_) { l = lp2_[0].process(l); r = lp2_[1].process(r); }
        left = l; right = r;
    }

    /// Magnitude response in dB at frequency f, using the *current*
    /// coefficients (read from the first channel — coeffs are identical
    /// across channels).
    /// Parameter snapshot the UI hands in before asking for the response
    /// curve. The render thread's setters only run while the host renders, so
    /// the curve must not depend on them: the AU pushes its parameter atomics
    /// here from the UI thread and the display biquads follow immediately.
    struct DisplayParams {
        float hp, lsHz, lsDB, lsQ, lmHz, lmDB, lmQ, hmHz, hmDB, hmQ, hsHz, hsDB, hsQ, lp;
        bool  hp24, lp24;
    };
    void setDisplayParams(const DisplayParams& p) {
        if (!haveDP_ || std::memcmp(&p, &dp_, sizeof(p)) != 0) { dp_ = p; haveDP_ = true; dispDirty_ = true; }
    }

    float magnitudeDBAt(float f) {
        // UI thread. Uses its own display biquads (never the coefficients the
        // audio thread is filtering with — that used to tear a high-Q bell
        // mid-block while dragging). Refreshed when the UI pushed new
        // DisplayParams or a setter bumped `version_` (bell/shelf flips).
        const uint32_t v = version_.load(std::memory_order_acquire);
        if (v != dispVersion_ || dispDirty_) { dispVersion_ = v; dispDirty_ = false; updateDisplayCoeffs(); }
        float m =
            dhp_.magnitudeAt(f) *
            dls_.magnitudeAt(f) *
            dlm_.magnitudeAt(f) *
            dhm_.magnitudeAt(f) *
            dhs_.magnitudeAt(f) *
            dlp_.magnitudeAt(f);
        const bool hp24 = haveDP_ ? dp_.hp24 : hpSlope24_, lp24 = haveDP_ ? dp_.lp24 : lpSlope24_;
        if (hp24) m *= dhp2_.magnitudeAt(f);   // second HP section
        if (lp24) m *= dlp2_.magnitudeAt(f);   // second LP section
        return linToDb(m);
    }

private:
    void touch() { dirty_ = true; version_.fetch_add(1, std::memory_order_release); }

    /// Display-only copies of the eight sections, computed from the same
    /// parameters, owned by the UI thread.
    void updateDisplayCoeffs() {
        const float qBW = 0.7071f;
        // Prefer the UI's own snapshot; fall back to the live values before the
        // first push.
        const DisplayParams p = haveDP_ ? dp_ : DisplayParams{ hpHz_, lsHz_, lsDB_, lsQ_, lmHz_, lmDB_, lmQ_,
                                                               hmHz_, hmDB_, hmQ_, hsHz_, hsDB_, hsQ_, lpHz_, hpSlope24_, lpSlope24_ };
        dhp_.setType(Biquad::kHighPass);  dhp2_.setType(Biquad::kHighPass);
        dls_.setType(lowBell_  ? Biquad::kPeaking : Biquad::kLowShelf);
        dlm_.setType(Biquad::kPeaking);   dhm_.setType(Biquad::kPeaking);
        dhs_.setType(highBell_ ? Biquad::kPeaking : Biquad::kHighShelf);
        dlp_.setType(Biquad::kLowPass);   dlp2_.setType(Biquad::kLowPass);
        dhp_.update(sr_, p.hp, qBW, 0.0f);  dhp2_.update(sr_, p.hp, qBW, 0.0f);
        dls_.update(sr_, p.lsHz, lowBell_  ? p.lsQ : qBW, p.lsDB);
        dlm_.update(sr_, p.lmHz, p.lmQ, p.lmDB);
        dhm_.update(sr_, p.hmHz, p.hmQ, p.hmDB);
        dhs_.update(sr_, p.hsHz, highBell_ ? p.hsQ : qBW, p.hsDB);
        dlp_.update(sr_, p.lp, qBW, 0.0f);  dlp2_.update(sr_, p.lp, qBW, 0.0f);
    }

    // The 14 continuous controls, as the audio path currently hears them.
    struct Vals { float hp, lsHz, lsDB, lsQ, lmHz, lmDB, lmQ, hmHz, hmDB, hmQ, hsHz, hsDB, hsQ, lp; };
    Vals target() const { return Vals{ hpHz_, lsHz_, lsDB_, lsQ_, lmHz_, lmDB_, lmQ_, hmHz_, hmDB_, hmQ_, hsHz_, hsDB_, hsQ_, lpHz_ }; }

    /// One control-rate step of every value toward its target (frequencies and
    /// Q in the log domain, gains in dB), then re-tune. Stops when all arrived.
    void glide() {
        const Vals t = target();
        bool moving = false;
        auto lin = [&](float& c, float tg, float eps) {
            if (c == tg) return;
            c += kCtl_ * (tg - c);
            if (std::fabs(tg - c) < eps) c = tg; else moving = true;
        };
        auto lg = [&](float& c, float tg) {
            if (c == tg) return;
            if (c <= 0.0f || tg <= 0.0f) { c = tg; return; }
            c *= std::pow(tg / c, kCtl_);
            if (std::fabs(tg - c) < 1e-3f * tg) c = tg; else moving = true;
        };
        lg(cur_.hp, t.hp);     lg(cur_.lp, t.lp);
        lg(cur_.lsHz, t.lsHz); lin(cur_.lsDB, t.lsDB, 0.005f); lg(cur_.lsQ, t.lsQ);
        lg(cur_.lmHz, t.lmHz); lin(cur_.lmDB, t.lmDB, 0.005f); lg(cur_.lmQ, t.lmQ);
        lg(cur_.hmHz, t.hmHz); lin(cur_.hmDB, t.hmDB, 0.005f); lg(cur_.hmQ, t.hmQ);
        lg(cur_.hsHz, t.hsHz); lin(cur_.hsDB, t.hsDB, 0.005f); lg(cur_.hsQ, t.hsQ);
        updateCoeffs();
        dirty_ = moving;
    }

    void updateCoeffs() {
        const float qBW = 0.7071f;   // Butterworth — shelves + HP/LP
        const Vals& c = cur_;
        for (int ch = 0; ch < 2; ++ch) {
            hp_[ch].update(sr_, c.hp, qBW, 0.0f);
            // Second cascaded HP/LP sections — same cutoff, Butterworth Q.
            // Two cascaded Q=0.7071 sections give a 24 dB/oct response
            // (−6 dB at fc, monotonic) — a clean steeper option for cleanup.
            hp2_[ch].update(sr_, c.hp, qBW, 0.0f);
            // Shelves use the user Q only in bell mode; as shelves they stay
            // Butterworth. Mids are always bells driven by their own Q.
            ls_[ch].update(sr_, c.lsHz, lowBell_  ? c.lsQ : qBW, c.lsDB);
            lm_[ch].update(sr_, c.lmHz, c.lmQ, c.lmDB);
            hm_[ch].update(sr_, c.hmHz, c.hmQ, c.hmDB);
            hs_[ch].update(sr_, c.hsHz, highBell_ ? c.hsQ : qBW, c.hsDB);
            lp_[ch].update(sr_, c.lp, qBW, 0.0f);
            lp2_[ch].update(sr_, c.lp, qBW, 0.0f);
        }
        dirty_ = false;
    }

    float sr_ = 48000.0f;
    bool  dirty_ = true;
    bool  lowBell_  = false;
    bool  highBell_ = false;
    bool  hpSlope24_ = false;   // false = 12 dB/oct, true = 24 dB/oct
    bool  lpSlope24_ = false;

    float hpHz_ = 40.0f;
    float lsHz_ = 120.0f,  lsDB_ = 0.0f, lsQ_ = 0.9f;
    float lmHz_ = 500.0f,  lmDB_ = 0.0f, lmQ_ = 1.2f;
    float hmHz_ = 2500.0f, hmDB_ = 0.0f, hmQ_ = 1.2f;
    float hsHz_ = 6000.0f, hsDB_ = 0.0f, hsQ_ = 0.9f;
    float lpHz_ = 18000.0f;

    // smoothing state
    static constexpr int kCtlBlock = 16;
    Vals  cur_ = { 40.0f, 120.0f, 0.0f, 0.9f, 500.0f, 0.0f, 1.2f, 2500.0f, 0.0f, 1.2f, 6000.0f, 0.0f, 0.9f, 18000.0f };
    float kCtl_ = 0.016f;
    int   ctl_ = 0;
    bool  snap_ = true;

    Biquad hp_[2], hp2_[2], ls_[2], lm_[2], hm_[2], hs_[2], lp_[2], lp2_[2];
    // Parameter version (bumped by every setter) + the UI's display copies.
    std::atomic<uint32_t> version_{1};
    uint32_t dispVersion_ = 0;
    bool     dispDirty_ = false, haveDP_ = false;
    DisplayParams dp_ = {};
    Biquad dhp_, dhp2_, dls_, dlm_, dhm_, dhs_, dlp_, dlp2_;
};

} // namespace eq
