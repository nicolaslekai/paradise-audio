//
//  PitchShifterHQ.hpp
//
//  Formant-preserving phase-vocoder pitch shifter. Since 2026-11-20 it is the
//  FALLBACK shifter only (harmony beyond ±12 st, LOW TUNER below −12 st); the
//  main pitch path is the PSOLA engine in Psola.hpp.
//
//  Derived from Stephan M. Bernsee's smbPitchShift, extended per instance with
//  cepstral formant preservation. Licence of the original (kept as required):
//
//  COPYRIGHT 1999-2015 Stephan M. Bernsee <s.bernsee [AT] zynaptiq [DOT] com>
//                      The Wide Open License (WOL)
//  Permission to use, copy, modify, distribute and sell this software and its
//  documentation for any purpose is hereby granted without fee, provided that
//  the above copyright notice and this license appear in all source copies.
//  THIS SOFTWARE IS PROVIDED "AS IS" WITHOUT EXPRESS OR IMPLIED WARRANTY OF
//  ANY KIND. See http://www.dspguru.com/wol.htm for more information.
//
//  2026-11-20 quality fixes (VoiceBox/AUDIO_QUALITY_PLAN.md):
//   • P1 the synthesis phase accumulator is wrapped every hop (it was a float
//     growing without bound → the output got rougher the longer it ran);
//   • P2 colliding bins keep the frequency of the STRONGEST source bin;
//   • P7 periodic Hann window.
//  2026-11-21 sound-quality pass: unity gain (the overlap-add was scaled 3× =
//  +9.5 dB too hot) and per-frame energy matching, so the fallback path sits at
//  the same level as the PSOLA voices for every interval.
//  The frame follows the sample rate (1024 up to 48 kHz, 2048 at 88.2/96 kHz,
//  4096 above) — a fixed 1024 frame at 96 kHz had 94 Hz bins and smeared low
//  voices; the formant lifter is 0.83 ms at every rate.
//  Real latency of this structure is one full frame — `trueLatency()` (the
//  engine aligns every other path to it).
//
//  Mono (a harmony is one voice) → cheaper than the per-channel time-domain
//  shifter. Feed one sample at a time; returns one shifted sample (with the
//  vocoder's inherent latency of one frame).
//
//  NOTE: tuned conservatively; if the harmony sounds metallic/phasey after a
//  build, the knobs to turn are kFrame / kOver and the formant lifter width.
//

#pragma once
#include <cmath>
#include <cstring>
#include <algorithm>
#include <vector>

namespace vbx {

class PitchShifterHQ {
public:
    static constexpr int kMaxFrame = 4096;
    static constexpr int kOver  = 4;      // oversampling → hop = frame/kOver

    /// FFT size for a sample rate: 1024 (≤ 48 kHz), 2048 (88.2/96 kHz), 4096 (above).
    static int frameFor(float sr) { return sr < 64000.0f ? 1024 : (sr < 128000.0f ? 2048 : 4096); }
    /// Measured end-to-end delay of this shifter in samples (bench T7) — one frame.
    int trueLatency() const { return kFrame; }

    void prepare(float sr) {
        sr_ = sr;
        kFrame = frameFor(sr); kHop = kFrame / kOver; kLat = kFrame - kHop;
        lifter_ = std::max(8, (int)std::lround(40.0 * sr / 48000.0));
        for (int k = 0; k < kFrame; ++k) winBuf_[k] = 0.5f * (1.0f - std::cos(2.0f*(float)M_PI*(float)k/(float)kFrame));   // P7: periodic
        reset();
    }
    void reset() {
        std::fill(inFIFO_,     inFIFO_ + kMaxFrame, 0.0f);
        std::fill(outFIFO_,    outFIFO_ + kMaxFrame, 0.0f);
        std::fill(lastPhase_,  lastPhase_ + kMaxFrame/2 + 1, 0.0f);
        std::fill(sumPhase_,   sumPhase_ + kMaxFrame/2 + 1, 0.0f);
        std::fill(outAccum_,   outAccum_ + 2*kMaxFrame, 0.0f);
        rover_ = kLat;   // prime so first output is delayed one frame (latency)
    }

    void setFormantPreserve(bool on) { formant_ = on; }

    // pitchRatio = 2^(semitones/12). Returns the shifted sample.
    inline float process(float in, float pitchRatio) {
        const float* win = winBuf_;
        inFIFO_[rover_] = in;
        const float out = outFIFO_[rover_ - kLat];   // delayed output (prev frame)
        rover_++;
        if (rover_ < kFrame) return out;
        rover_ = kLat;

        // ── Analysis ────────────────────────────────────────────────────
        float* fft = fftBuf_;
        for (int k = 0; k < kFrame; ++k) { fft[2*k] = inFIFO_[k] * win[k]; fft[2*k+1] = 0.0f; }
        fftLR(fft, kFrame, -1);

        const double freqPerBin = (double)sr_ / (double)kFrame;
        const double expct = 2.0 * M_PI * (double)kHop / (double)kFrame;
        const int half = kFrame/2;

        for (int k = 0; k <= half; ++k) {
            const float re = fft[2*k], im = fft[2*k+1];
            const float magn = 2.0f * std::sqrt(re*re + im*im);
            const float phase = std::atan2(im, re);
            double tmp = phase - lastPhase_[k];
            lastPhase_[k] = phase;
            tmp -= (double)k * expct;                       // subtract expected phase advance
            // wrap to ±π
            long qpd = (long)(tmp / M_PI);
            if (qpd >= 0) qpd += qpd & 1; else qpd -= qpd & 1;
            tmp -= M_PI * (double)qpd;
            tmp = (double)kOver * tmp / (2.0 * M_PI);
            const double trueFreq = (double)k * freqPerBin + tmp * freqPerBin;
            anaMag_[k]  = magn;
            anaFreq_[k] = (float)trueFreq;
        }

        // ── Formant envelope of the ORIGINAL spectrum (cepstral lifter) ──
        if (formant_) computeEnvelope(anaMag_, origEnv_, half);

        // ── Pitch shift: move bin k → k*ratio ────────────────────────────
        std::fill(synMag_,  synMag_  + half + 1, 0.0f);
        std::fill(synFreq_, synFreq_ + half + 1, 0.0f);
        std::fill(synPeak_, synPeak_ + half + 1, 0.0f);
        for (int k = 0; k <= half; ++k) {
            const int idx = (int)(k * pitchRatio + 0.5f);
            if (idx <= half) {
                synMag_[idx]  += anaMag_[k];
                if (anaMag_[k] >= synPeak_[idx]) {          // P2: strongest bin wins the frequency
                    synPeak_[idx] = anaMag_[k];
                    synFreq_[idx] = anaFreq_[k] * pitchRatio;
                }
            }
        }

        // ── Re-impose original formant envelope on the shifted magnitudes ─
        if (formant_) {
            computeEnvelope(synMag_, shiftEnv_, half);
            for (int k = 0; k <= half; ++k) {
                const float e = shiftEnv_[k] > 1e-6f ? (origEnv_[k] / shiftEnv_[k]) : 1.0f;
                synMag_[k] *= std::min(4.0f, std::max(0.25f, e));   // clamp correction
            }
        }

        // ── Level: a shifted frame carries the energy of the frame it came from ──
        // (2026-11-21) Without this the level depended on the interval and on the
        // formant correction: +7 dB for harmonies above +12 st, −4…−7 dB below −12 st.
        {
            float ea = 0.0f, es = 0.0f;
            for (int k = 0; k <= half; ++k) { ea += anaMag_[k] * anaMag_[k]; es += synMag_[k] * synMag_[k]; }
            if (es > 1e-20f) {
                // Overlapping frames of a shifted spectrum are less coherent than the original's, so
                // some level is lost in the overlap-add: +2.7 dB going down, +4.5 dB going up (measured
                // on voice and noise, Tests/sq) puts this path where the PSOLA voices are at ±12 st.
                const float trim = pitchRatio < 1.0f ? 1.0f + 0.36f * std::min(1.0f, (1.0f - pitchRatio) * 2.0f)
                                                     : 1.0f + 0.68f * std::min(1.0f, pitchRatio - 1.0f);
                const float gn = std::min(4.0f, std::max(0.1f, std::sqrt(ea / es))) * 0.85f * trim;
                for (int k = 0; k <= half; ++k) synMag_[k] *= gn;
            }
        }

        // ── Synthesis ─────────────────────────────────────────────────────
        for (int k = 0; k <= half; ++k) {
            const float magn = synMag_[k];
            double tmp = synFreq_[k];
            tmp -= (double)k * freqPerBin;
            tmp /= freqPerBin;
            tmp = 2.0 * M_PI * tmp / (double)kOver;
            tmp += (double)k * expct;
            // P1: wrap — a float that grows without bound loses phase precision.
            sumPhase_[k] = (float)std::remainder((double)sumPhase_[k] + tmp, 2.0 * M_PI);
            const float phase = sumPhase_[k];
            fft[2*k]   = magn * std::cos(phase);
            fft[2*k+1] = magn * std::sin(phase);
        }
        for (int k = half+1; k < kFrame; ++k) {              // negative freqs = conj
            fft[2*k]   =  fft[2*(kFrame-k)];
            fft[2*k+1] = -fft[2*(kFrame-k)+1];
        }
        fftLR(fft, kFrame, 1);

        // windowed overlap-add into the accumulator (2×kFrame, tail stays 0).
        // 2026-11-21: ÷3. Hann² at 4× overlap sums to 1.5 and the spectrum is written
        // into both halves (×2), so the old scaling made this path 3× (+9.5 dB) too loud.
        for (int k = 0; k < kFrame; ++k)
            outAccum_[k] += (2.0f / 3.0f) * win[k] * fft[2*k] / (float)(half * kOver);
        // publish the next hop of output, then shift buffers down by one hop
        for (int k = 0; k < kHop; ++k) outFIFO_[k] = outAccum_[k];
        std::memmove(outAccum_, outAccum_ + kHop, kFrame * sizeof(float));
        for (int k = 0; k < kLat; ++k) inFIFO_[k] = inFIFO_[k + kHop];
        return out;
    }

private:
    // Cepstral spectral envelope: log-mag → IFFT → keep low quefrencies → FFT → exp.
    void computeEnvelope(const float* mag, float* env, int half) {
        float* c = cepBuf_;
        for (int k = 0; k <= half; ++k) { c[2*k] = std::log(std::max(mag[k], 1e-6f)); c[2*k+1] = 0.0f; }
        for (int k = half+1; k < kFrame; ++k) { c[2*k] = c[2*(kFrame-k)]; c[2*k+1] = 0.0f; }
        fftLR(c, kFrame, 1);                                  // to cepstrum
        const int lifter = lifter_;                           // quefrency cutoff (formant width, 0.83 ms)
        for (int k = 0; k < kFrame; ++k) {
            float w = (k < lifter || k > kFrame - lifter) ? 1.0f : 0.0f;
            c[2*k] *= w / kFrame; c[2*k+1] *= w / kFrame;
        }
        fftLR(c, kFrame, -1);                                 // back to log-spectrum
        for (int k = 0; k <= half; ++k) env[k] = std::exp(c[2*k]);
    }

    // In-place radix-2 FFT (Bernsee's smbFft form). sign=-1 forward, +1 inverse.
    static void fftLR(float* fftBuffer, long fftFrameSize, long sign) {
        float wr, wi, arg, *p1, *p2, temp;
        float tr, ti, ur, ui, *p1r, *p1i, *p2r, *p2i;
        long i, bitm, j, le, le2, k;
        for (i = 2; i < 2*fftFrameSize-2; i += 2) {
            for (bitm = 2, j = 0; bitm < 2*fftFrameSize; bitm <<= 1) {
                if (i & bitm) j++; j <<= 1;
            }
            if (i < j) {
                p1 = fftBuffer+i; p2 = fftBuffer+j;
                temp = *p1; *(p1++) = *p2; *(p2++) = temp;
                temp = *p1; *p1 = *p2; *p2 = temp;
            }
        }
        long kmax = (long)(std::log((double)fftFrameSize)/std::log(2.0) + 0.5);
        for (k = 0, le = 2; k < kmax; k++) {
            le <<= 1; le2 = le>>1;
            ur = 1.0f; ui = 0.0f;
            arg = (float)M_PI / (le2>>1);
            wr = std::cos(arg); wi = (float)sign * std::sin(arg);
            for (j = 0; j < le2; j += 2) {
                p1r = fftBuffer+j; p1i = p1r+1; p2r = p1r+le2; p2i = p2r+1;
                for (i = j; i < 2*fftFrameSize; i += le) {
                    tr = *p2r * ur - *p2i * ui;
                    ti = *p2r * ui + *p2i * ur;
                    *p2r = *p1r - tr; *p2i = *p1i - ti;
                    *p1r += tr; *p1i += ti;
                    p1r += le; p1i += le; p2r += le; p2i += le;
                }
                tr = ur*wr - ui*wi; ui = ur*wi + ui*wr; ur = tr;
            }
        }
    }

    float sr_ = 48000.0f;
    bool  formant_ = true;
    int   kFrame = 1024, kHop = 256, kLat = 768, lifter_ = 40;   // set in prepare() from the sample rate
    int   rover_ = 768;
    float winBuf_[kMaxFrame] = {};
    float inFIFO_[kMaxFrame] = {}, outFIFO_[kMaxFrame] = {};
    float outAccum_[2*kMaxFrame] = {};
    float fftBuf_[2*kMaxFrame] = {}, cepBuf_[2*kMaxFrame] = {};   // work buffers (were 2 × 8 kB on the audio thread's stack)
    float lastPhase_[kMaxFrame/2 + 1] = {}, sumPhase_[kMaxFrame/2 + 1] = {};
    float anaMag_[kMaxFrame/2 + 1] = {}, anaFreq_[kMaxFrame/2 + 1] = {};
    float synMag_[kMaxFrame/2 + 1] = {}, synFreq_[kMaxFrame/2 + 1] = {}, synPeak_[kMaxFrame/2 + 1] = {};
    float origEnv_[kMaxFrame/2 + 1] = {}, shiftEnv_[kMaxFrame/2 + 1] = {};
};

}
