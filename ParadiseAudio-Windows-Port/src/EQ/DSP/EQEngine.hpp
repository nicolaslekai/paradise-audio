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
        updateCoeffs();
    }

    void reset() {
        for (int ch = 0; ch < 2; ++ch) {
            hp_[ch].reset(); hp2_[ch].reset(); ls_[ch].reset();
            lm_[ch].reset(); hm_[ch].reset();
            hs_[ch].reset(); lp_[ch].reset(); lp2_[ch].reset();
        }
    }

    void setHPFreq(float hz)       { hpHz_ = hz; dirty_ = true; }
    void setLowFreq(float hz)      { lsHz_ = hz; dirty_ = true; }
    void setLowGainDB(float db)    { lsDB_ = db; dirty_ = true; }
    void setLowMidFreq(float hz)   { lmHz_ = hz; dirty_ = true; }
    void setLowMidGainDB(float db) { lmDB_ = db; dirty_ = true; }
    void setLowMidQ(float q)       { lmQ_  = q;  dirty_ = true; }
    void setHighMidFreq(float hz)  { hmHz_ = hz; dirty_ = true; }
    void setHighMidGainDB(float db){ hmDB_ = db; dirty_ = true; }
    void setHighMidQ(float q)      { hmQ_  = q;  dirty_ = true; }
    void setLowQ(float q)          { lsQ_  = q;  dirty_ = true; }
    void setHighFreq(float hz)     { hsHz_ = hz; dirty_ = true; }
    void setHighGainDB(float db)   { hsDB_ = db; dirty_ = true; }
    void setHighQ(float q)         { hsQ_  = q;  dirty_ = true; }
    void setLPFreq(float hz)       { lpHz_ = hz; dirty_ = true; }
    // Slope switches — false = 12 dB/oct (single section, default),
    // true = 24 dB/oct (a second cascaded Butterworth section is engaged).
    void setHPSlope24(bool b)      { if (b != hpSlope24_) { hpSlope24_ = b; for (int ch=0;ch<2;++ch) hp2_[ch].reset(); dirty_ = true; } }
    void setLPSlope24(bool b)      { if (b != lpSlope24_) { lpSlope24_ = b; for (int ch=0;ch<2;++ch) lp2_[ch].reset(); dirty_ = true; } }
    bool hpSlope24() const         { return hpSlope24_; }
    bool lpSlope24() const         { return lpSlope24_; }
    // Shape switches — false = shelf (default), true = peaking bell.
    void setLowIsBell(bool b)      { lowBell_ = b; for (int ch=0;ch<2;++ch) ls_[ch].setType(b ? Biquad::kPeaking : Biquad::kLowShelf); dirty_ = true; }
    void setHighIsBell(bool b)     { highBell_ = b; for (int ch=0;ch<2;++ch) hs_[ch].setType(b ? Biquad::kPeaking : Biquad::kHighShelf); dirty_ = true; }
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
        if (dirty_) updateCoeffs();
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
    float magnitudeDBAt(float f) {
        if (dirty_) updateCoeffs();
        float m =
            hp_[0].magnitudeAt(f) *
            ls_[0].magnitudeAt(f) *
            lm_[0].magnitudeAt(f) *
            hm_[0].magnitudeAt(f) *
            hs_[0].magnitudeAt(f) *
            lp_[0].magnitudeAt(f);
        if (hpSlope24_) m *= hp2_[0].magnitudeAt(f);   // second HP section
        if (lpSlope24_) m *= lp2_[0].magnitudeAt(f);   // second LP section
        return linToDb(m);
    }

private:
    void updateCoeffs() {
        const float qBW = 0.7071f;   // Butterworth — shelves + HP/LP
        const float qBell = 1.4f;    // Moderate-width bell — feels musical
        for (int ch = 0; ch < 2; ++ch) {
            hp_[ch].update(sr_, hpHz_, qBW, 0.0f);
            // Second cascaded HP/LP sections — same cutoff, Butterworth Q.
            // Two cascaded Q=0.7071 sections give a 24 dB/oct response
            // (−6 dB at fc, monotonic) — a clean steeper option for cleanup.
            hp2_[ch].update(sr_, hpHz_, qBW, 0.0f);
            // Shelves use the user Q only in bell mode; as shelves they stay
            // Butterworth. Mids are always bells driven by their own Q.
            ls_[ch].update(sr_, lsHz_, lowBell_  ? lsQ_ : qBW, lsDB_);
            lm_[ch].update(sr_, lmHz_, lmQ_, lmDB_);
            hm_[ch].update(sr_, hmHz_, hmQ_, hmDB_);
            hs_[ch].update(sr_, hsHz_, highBell_ ? hsQ_ : qBW, hsDB_);
            lp_[ch].update(sr_, lpHz_, qBW, 0.0f);
            lp2_[ch].update(sr_, lpHz_, qBW, 0.0f);
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

    Biquad hp_[2], hp2_[2], ls_[2], lm_[2], hm_[2], hs_[2], lp_[2], lp2_[2];
};

} // namespace eq
