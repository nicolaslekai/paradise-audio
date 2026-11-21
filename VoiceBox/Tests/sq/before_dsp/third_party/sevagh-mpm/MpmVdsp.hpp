//
//  MpmVdsp.hpp — McLeod Pitch Method (NSDF) on Accelerate.
//
//  Port of sevagh/pitch-detection (MIT, Copyright (c) 2018 Sevag Hanssian — see
//  LICENSE and NOTICE.txt in this folder): peak_picking(), the MPM cutoff rule
//  and parabolic_interpolation() follow src/mpm.cpp and
//  src/parabolic_interpolation.cpp; acorr_r() is re-done with vDSP_fft_zrip.
//  Added: NSDF normalisation n'(τ) = 2 r(τ) / m(τ) (McLeod & Wyvill 2005) so the
//  chosen peak's height is a clarity in 0…1.
//
#pragma once
#include <Accelerate/Accelerate.h>
#include <vector>
#include <cmath>
#include <algorithm>

namespace vbx { namespace mpm {

static constexpr float kCutoff      = 0.93f;   // MPM_CUTOFF
static constexpr float kSmallCutoff = 0.50f;   // MPM_SMALL_CUTOFF

class Detector {
public:
    ~Detector() { if (setup_) vDSP_destroy_fftsetup(setup_); }
    /// W = analysis window length (any size). FFT size = next power of two ≥ 2W
    /// (zero padding keeps the autocorrelation linear). Allocates everything.
    void prepare(int W) {
        W_ = W; log2n_ = 0; while ((1 << log2n_) < 2 * W) ++log2n_; nfft_ = 1 << log2n_;
        if (setup_) vDSP_destroy_fftsetup(setup_);
        setup_ = vDSP_create_fftsetup(log2n_, kFFTRadix2);
        buf_.assign(nfft_, 0.0f); re_.assign(nfft_ / 2, 0.0f); im_.assign(nfft_ / 2, 0.0f);
        acf_.assign(nfft_, 0.0f); nsdf_.assign(W_, 0.0f); peaks_.assign(W_, 0);
    }
    int window() const { return W_; }

    /// x: W samples (oldest first). Returns f0 in Hz (or -1) and clarity 0…1.
    float detect(const float* x, float sr, float minHz, float maxHz, float& clarity) {
        clarity = 0.0f;
        const int W = W_;
        // ── autocorrelation via FFT (acorr_r) ──
        std::copy(x, x + W, buf_.begin()); std::fill(buf_.begin() + W, buf_.end(), 0.0f);
        DSPSplitComplex sc{ re_.data(), im_.data() };
        vDSP_ctoz((const DSPComplex*)buf_.data(), 2, &sc, 1, nfft_ / 2);
        vDSP_fft_zrip(setup_, &sc, 1, log2n_, FFT_FORWARD);
        const float dc = re_[0] * re_[0], ny = im_[0] * im_[0];
        vDSP_zvmags(&sc, 1, re_.data(), 1, nfft_ / 2);          // |X|² into re
        std::fill(im_.begin(), im_.end(), 0.0f);
        re_[0] = dc; im_[0] = ny;                                // packed DC / Nyquist
        vDSP_fft_zrip(setup_, &sc, 1, log2n_, FFT_INVERSE);
        vDSP_ztoc(&sc, 1, (DSPComplex*)acf_.data(), 2, nfft_ / 2);
        // Exact scale from r(0) = Σx² (vDSP's packed transforms carry fixed gains).
        float e0 = 0.0f; vDSP_svesq(x, 1, &e0, W);
        if (e0 < 1e-9f || acf_[0] <= 0.0f) return -1.0f;
        const float scale = e0 / acf_[0];
        // ── NSDF n'(τ) = 2 r(τ) / m(τ), m(τ) = Σ x[j]² + x[j+τ]² ──
        const int maxLag = std::min(W - 1, (int)(sr / std::max(1.0f, minHz)) + 2);
        const int minLag = std::max(1, (int)(sr / maxHz) - 1);
        float m = 2.0f * e0;
        nsdf_[0] = 1.0f;
        for (int tau = 1; tau <= maxLag; ++tau) {
            m -= x[tau - 1] * x[tau - 1] + x[W - tau] * x[W - tau];
            nsdf_[tau] = m > 1e-9f ? 2.0f * acf_[tau] * scale / m : 0.0f;
        }
        const int size = maxLag + 1;
        // ── peak_picking (sevagh) ──
        int np = 0, pos = 0, cur = 0;
        while (pos < (size - 1) / 3 && nsdf_[pos] > 0) pos++;
        while (pos < size - 1 && nsdf_[pos] <= 0.0f) pos++;
        if (pos == 0) pos = 1;
        while (pos < size - 1) {
            if (nsdf_[pos] > nsdf_[pos - 1] && nsdf_[pos] >= nsdf_[pos + 1] && (cur == 0 || nsdf_[pos] > nsdf_[cur])) cur = pos;
            pos++;
            if (pos < size - 1 && nsdf_[pos] <= 0) {
                if (cur > 0) { peaks_[np++] = cur; cur = 0; }
                while (pos < size - 1 && nsdf_[pos] <= 0.0f) pos++;
            }
        }
        if (cur > 0) peaks_[np++] = cur;
        // ── estimates + cutoff (Mpm<T>::pitch) ──
        float highest = -1e9f; int nEst = 0;
        for (int i = 0; i < np; ++i) {
            const int p = peaks_[i];
            if (p < minLag) continue;
            highest = std::max(highest, nsdf_[p]);
            if (nsdf_[p] > kSmallCutoff) {
                float tp, vp; parabolic(p, size, tp, vp);
                estT_[nEst] = tp; estV_[nEst] = vp; highest = std::max(highest, vp);
                if (++nEst >= kMaxEst) break;
            }
        }
        if (nEst == 0) return -1.0f;
        const float cutoff = kCutoff * highest;
        for (int i = 0; i < nEst; ++i) {
            if (estV_[i] >= cutoff) {
                clarity = std::min(1.0f, estV_[i]);
                const float hz = sr / estT_[i];
                return (hz >= minHz && hz <= maxHz) ? hz : -1.0f;
            }
        }
        return -1.0f;
    }

private:
    // parabolic_interpolation (sevagh)
    void parabolic(int x, int size, float& tx, float& v) const {
        if (x < 1 || x >= size - 1) { tx = (float)x; v = nsdf_[x]; return; }
        const float den = nsdf_[x + 1] + nsdf_[x - 1] - 2 * nsdf_[x];
        const float delta = nsdf_[x - 1] - nsdf_[x + 1];
        if (den == 0.0f) { tx = (float)x; v = nsdf_[x]; return; }
        tx = x + delta / (2 * den);
        v = nsdf_[x] - delta * delta / (8 * den);
    }
    static constexpr int kMaxEst = 64;
    int W_ = 0, nfft_ = 0, log2n_ = 0;
    FFTSetup setup_ = nullptr;
    std::vector<float> buf_, re_, im_, acf_, nsdf_;
    std::vector<int> peaks_;
    float estT_[kMaxEst] = {}, estV_[kMaxEst] = {};
};

} } // namespace vbx::mpm
