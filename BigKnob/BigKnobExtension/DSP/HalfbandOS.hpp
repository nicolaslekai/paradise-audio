//
//  HalfbandOS.hpp — linear-phase halfband oversampling (2x stages, cascadable).
//
//  Used around waveshapers so their harmonics land above the audio band of the
//  oversampled rate instead of folding back as inharmonic aliases. Linear phase,
//  so the (constant) delay can be reported to the host and matched on the dry
//  path. Real-time safe: fixed-size state, no allocation.
//
//  Three Kaiser (beta 8) halfband designs, cascaded 1x→2x→4x→8x:
//      stage 1  N = 63   flat to 0.43 fs, > 80 dB above 0.59 fs
//      stage 2  N = 19   (wide transition band at 2x)
//      stage 3  N = 11   (wider still at 4x)
//  Coefficients come from Tools/sound_audit (see the 2026-11-21 audit).
//
//  Same file is copied into every plug-in that needs it (each plug-in is its own
//  binary, so there is no ODR clash).
//

#pragma once
#include <cstring>

namespace pos {

static const float kHB63[32] = {
    -2.401525086e-05f, 1.090362234e-04f, -2.935600618e-04f, 6.381063336e-04f, -1.222075923e-03f, 2.145908431e-03f,
    -3.534414071e-03f, 5.543646654e-03f, -8.376209881e-03f, 1.231558223e-02f, -1.780469905e-02f, 2.563768360e-02f,
    -3.748937911e-02f, 5.772404061e-02f, -1.024425021e-01f, 3.170728513e-01f, 3.170728513e-01f, -1.024425021e-01f,
    5.772404061e-02f, -3.748937911e-02f, 2.563768360e-02f, -1.780469905e-02f, 1.231558223e-02f, -8.376209881e-03f,
    5.543646654e-03f, -3.534414071e-03f, 2.145908431e-03f, -1.222075923e-03f, 6.381063336e-04f, -2.935600618e-04f,
    1.090362234e-04f, -2.401525086e-05f };
static const float kHB19[10] = {
    8.272436386e-05f, -2.971480728e-03f, 1.820147746e-02f, -6.923445241e-02f, 3.039217313e-01f,
    3.039217313e-01f, -6.923445241e-02f, 1.820147746e-02f, -2.971480728e-03f, 8.272436386e-05f };
static const float kHB11[6] = {
    1.490313098e-04f, -2.408386692e-02f, 2.739348356e-01f, 2.739348356e-01f, -2.408386692e-02f, 1.490313098e-04f };

/// One halfband 2x stage usable as interpolator (up) and decimator (down).
/// `taps` = the even-index coefficients of an N = 2·nTaps − 1 halfband filter
/// (they sum to 0.5); the centre tap (0.5) is the odd phase, a pure delay.
class Halfband2x {
public:
    void init(const float* taps, int nTaps) {
        taps_ = taps; n_ = nTaps;
        dOdd_ = (nTaps - 2) / 2;          // (N-3)/4 : odd-phase delay in low-rate samples
        reset();
    }
    void reset() { std::memset(a_, 0, sizeof(a_)); std::memset(b_, 0, sizeof(b_)); w_ = 0; }

    /// Interpolate: one low-rate sample in → two high-rate samples out.
    inline void up(float x, float& y0, float& y1) {
        w_ = (w_ + 1) & kMask;
        a_[w_] = x;
        float acc = 0.0f;
        for (int k = 0; k < n_; ++k) acc += taps_[k] * a_[(w_ - k) & kMask];
        y0 = 2.0f * acc;                          // even phase: FIR
        y1 = a_[(w_ - dOdd_) & kMask];            // odd phase: delay (2 × 0.5 centre tap)
    }
    /// Decimate: two high-rate samples in (u0 older, u1 newer) → one low-rate sample out.
    inline float down(float u0, float u1) {
        w_ = (w_ + 1) & kMask;
        a_[w_] = u0;                              // odd stream  u[2n-1]
        b_[w_] = u1;                              // even stream u[2n]
        float acc = 0.0f;
        for (int k = 0; k < n_; ++k) acc += taps_[k] * b_[(w_ - k) & kMask];
        return acc + 0.5f * a_[(w_ - dOdd_) & kMask];
    }
private:
    static constexpr int kSize = 64, kMask = kSize - 1;
    const float* taps_ = kHB11; int n_ = 6, dOdd_ = 2;
    float a_[kSize] = {0}, b_[kSize] = {0};
    int   w_ = 0;
};

/// 4x or 8x oversampler for one channel. Call process(x, fn): fn is applied to
/// every oversampled sample. Total delay is an INTEGER number of base-rate
/// samples (latency()), so the host can compensate it and a dry path can be
/// delayed to match exactly.
class Oversampler {
public:
    /// factor: 4 or 8.
    void prepare(int factor) {
        factor_ = (factor >= 8) ? 8 : 4;
        u1_.init(kHB63, 32); d1_.init(kHB63, 32);
        u2_.init(kHB19, 10); d2_.init(kHB19, 10);
        u3_.init(kHB11, 6);  d3_.init(kHB11, 6);
        reset();
    }
    void reset() {
        u1_.reset(); d1_.reset(); u2_.reset(); d2_.reset(); u3_.reset(); d3_.reset();
        pad_ = 0.0f;
    }
    /// Base-rate samples of delay. A stage pair delays by (2c − 1)/2 low-rate
    /// samples (c = centre tap; the decimator samples the odd phase), i.e.
    /// 30.5 + 4.25 (+ 1.125); a one-sample pad at the top rate (0.25 resp.
    /// 0.125) makes that a whole number.
    int latency() const { return factor_ == 8 ? 36 : 35; }
    int factor()  const { return factor_; }

    template <typename F>
    inline float process(float x, F&& fn) {
        float a[2], b[4];
        u1_.up(x, a[0], a[1]);
        u2_.up(a[0], b[0], b[1]);
        u2_.up(a[1], b[2], b[3]);
        if (factor_ == 8) {
            float c[8];
            for (int i = 0; i < 4; ++i) u3_.up(b[i], c[2 * i], c[2 * i + 1]);
            for (int i = 0; i < 8; ++i) {            // shaper + 1-sample pad
                const float y = fn(c[i]);
                c[i] = pad_; pad_ = y;
            }
            for (int i = 0; i < 4; ++i) b[i] = d3_.down(c[2 * i], c[2 * i + 1]);
        } else {
            for (int i = 0; i < 4; ++i) {
                const float y = fn(b[i]);
                b[i] = pad_; pad_ = y;
            }
        }
        a[0] = d2_.down(b[0], b[1]);
        a[1] = d2_.down(b[2], b[3]);
        return d1_.down(a[0], a[1]);
    }
private:
    int factor_ = 8;
    Halfband2x u1_, u2_, u3_, d1_, d2_, d3_;
    float pad_ = 0.0f;
};

/// Integer delay for the dry path (≤ 63 samples).
class DryDelay {
public:
    void prepare(int samples) { d_ = samples & 63; reset(); }
    void reset() { std::memset(buf_, 0, sizeof(buf_)); w_ = 0; }
    inline float process(float x) {
        buf_[w_] = x;
        const float y = buf_[(w_ - d_) & 63];
        w_ = (w_ + 1) & 63;
        return y;
    }
private:
    float buf_[64] = {0}; int w_ = 0, d_ = 0;
};

} // namespace pos
