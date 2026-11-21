//
//  CaptureWav.hpp — Paradise Audio shared "bounce to audio" output capture.
//
//  A tiny real-time-safe stereo capture buffer used by the instrument AUs to
//  implement a BOUNCE / capture-to-WAV button. The audio thread only writes
//  into a pre-allocated buffer (no allocation, no locks); the UI thread arms
//  (allocates), disarms, then copies the captured frames out and writes the
//  file with AVAudioFile (which handles the sandbox-granted destination URL).
//
//  Ordering: arm() publishes the freshly-allocated buffer with a release store
//  on `armed`; capture() only touches the buffer after an acquire load sees
//  armed == true, so the buffer's contents/size are visible on the audio
//  thread. Capture auto-stops when the buffer is full (bounded length).
//

#pragma once
#include <vector>
#include <atomic>
#include <algorithm>

namespace cap {

struct WavCapture {
    std::vector<float> buf;          // interleaved stereo L,R,L,R…
    int               maxFrames = 0;
    std::atomic<int>  frames{0};
    std::atomic<bool> armed{false};

    // ── UI thread ──
    /// Allocate the capture buffer and start recording. `maxSeconds` bounds it.
    void arm(double sr, double maxSeconds) {
        maxFrames = (int)(sr * maxSeconds);
        if (maxFrames < 1) maxFrames = 1;
        buf.assign((size_t)maxFrames * 2, 0.0f);
        frames.store(0, std::memory_order_relaxed);
        armed.store(true, std::memory_order_release);
    }
    void disarm() { armed.store(false, std::memory_order_release); }
    bool isArmed() const { return armed.load(std::memory_order_acquire); }
    int  capturedFrames() const {
        return std::min(frames.load(std::memory_order_acquire), maxFrames);
    }
    /// Copy up to `maxF` captured frames (interleaved stereo) into `dst`.
    int copyOut(float *dst, int maxF) const {
        const int n = std::min(capturedFrames(), maxF);
        if (n > 0) std::copy(buf.begin(), buf.begin() + (size_t)n * 2, dst);
        return n;
    }
    /// Release the buffer after the file has been written.
    void freeBuf() { buf.clear(); buf.shrink_to_fit(); maxFrames = 0; frames.store(0); }

    // ── Audio thread ──
    inline void capture(float L, float R) {
        if (!armed.load(std::memory_order_acquire)) return;
        int f = frames.load(std::memory_order_relaxed);
        if (f >= maxFrames) { armed.store(false, std::memory_order_release); return; }
        buf[(size_t)f * 2]     = L;
        buf[(size_t)f * 2 + 1] = R;
        frames.store(f + 1, std::memory_order_relaxed);
    }
};

} // namespace cap
