//
//  DrumsOffline.hpp — offline render + file writers for Engine 909 exports.
//
//  Everything here runs on a background thread with its OWN DrumsEngine,
//  loaded from the live engine's state blob, so the audio thread is never
//  touched. The export range is the LINK chain (once through), or the active
//  pattern alone when ISOLATE is on / no chain is set.
//
//    renderOffline(...)   → stereo float buffers (+ optional trigger capture)
//    writeWav24(...)      → 24-bit PCM stereo WAV
//    writeMidiFile(...)   → SMF type 0, 480 PPQ, channel 10, note = 36 + voice
//                           (the same map the AU's MIDI input uses)
//
#pragma once
#include "DrumsEngine.hpp"
#include <memory>
#include <string>
#include <cstdio>

namespace drm {

static const char* const kVoiceFileNames[kVoices] = {
    "KICK", "SNARE", "CLAP", "JNG SN", "TOM 1", "TOM 2",
    "HAT M", "HAT C", "HAT O", "CRASH", "SUB", "LONG SUB"
};

struct OfflineResult {
    std::vector<float> L, R;
    std::vector<TrigEvent> events;   // sequencer triggers (frame, voice, vel)
    long long bodyFrames = 0;        // export range without the tail
};

/// Render the export range of `blob` at `sr`.
///  soloVoice  -1 = full mix as the user hears it; ≥0 = that voice only (stem).
///  tailSec    extra render after the range so reverb / delay tails ring out.
///  capture    log every trigger into result.events (MIDI export).
///  audio      false = only capture (skips writing samples; much cheaper on memory).
inline OfflineResult renderOffline(const std::vector<uint8_t>& blob, float sr, float bpm,
                                   float gainLin, int soloVoice, float tailSec,
                                   bool capture, bool audio = true) {
    OfflineResult res;
    auto eng = std::make_unique<DrumsEngine>();
    eng->prepare(sr);
    eng->deserialize(blob.data(), blob.size());
    if (bpm > 0) eng->setBPM(bpm);
    if (soloVoice >= 0) {
        eng->forceSolo(soloVoice);
        eng->setGlobalNoiseRaw(0.0f);   // stems: no hiss per file (it would stack ×N)
    }
    eng->beginOfflinePlayback();
    res.bodyFrames = eng->offlineLengthFrames(sr);
    const long long tail = (long long)(tailSec * sr);
    const long long total = res.bodyFrames + tail;
    if (capture) eng->capture_ = &res.events;
    if (audio) { res.L.resize((size_t)total); res.R.resize((size_t)total); }
    for (long long i = 0; i < total; ++i) {
        if (i == res.bodyFrames) eng->setPlaying(false);   // stop sequencing, let tails ring
        eng->captureFrame_ = i;
        float l = 0, r = 0;
        eng->processFrame(l, r);
        if (audio) { res.L[(size_t)i] = l * gainLin; res.R[(size_t)i] = r * gainLin; }
    }
    eng->capture_ = nullptr;
    return res;
}

/// Which voices fire in the export range AND are audible in the mix (mute /
/// solo respected) — the set that gets a stem.
inline std::vector<int> audibleVoicesWithHits(const std::vector<uint8_t>& blob, float sr, float bpm) {
    OfflineResult cap = renderOffline(blob, sr, bpm, 1.0f, -1, 0.0f, true, false);
    auto eng = std::make_unique<DrumsEngine>();
    eng->prepare(sr); eng->deserialize(blob.data(), blob.size());
    bool hit[kVoices] = {};
    for (const auto& e : cap.events) if (e.voice >= 0 && e.voice < kVoices) hit[e.voice] = true;
    std::vector<int> out;
    for (int v = 0; v < kVoices; ++v) if (hit[v] && !eng->mutedOrNotSoloed(v)) out.push_back(v);
    return out;
}

/// 24-bit little-endian PCM stereo WAV. Returns false on I/O error.
inline bool writeWav24(const std::string& path, const std::vector<float>& L,
                       const std::vector<float>& R, int sampleRate) {
    FILE* f = std::fopen(path.c_str(), "wb");
    if (!f) return false;
    const uint32_t n = (uint32_t)std::min(L.size(), R.size());
    const uint16_t ch = 2, bits = 24, blockAlign = ch * bits / 8;
    const uint32_t byteRate = (uint32_t)sampleRate * blockAlign;
    const uint32_t dataBytes = n * blockAlign;
    auto w32 = [&](uint32_t x) { std::fwrite(&x, 4, 1, f); };
    auto w16 = [&](uint16_t x) { std::fwrite(&x, 2, 1, f); };
    std::fwrite("RIFF", 1, 4, f); w32(36 + dataBytes); std::fwrite("WAVE", 1, 4, f);
    std::fwrite("fmt ", 1, 4, f); w32(16); w16(1); w16(ch); w32((uint32_t)sampleRate);
    w32(byteRate); w16(blockAlign); w16(bits);
    std::fwrite("data", 1, 4, f); w32(dataBytes);
    std::vector<uint8_t> buf; buf.reserve((size_t)dataBytes);
    auto put24 = [&](float x) {
        x = std::max(-1.0f, std::min(1.0f, x));
        int32_t s = (int32_t)std::lrint(x * 8388607.0f);
        buf.push_back((uint8_t)(s & 0xFF)); buf.push_back((uint8_t)((s >> 8) & 0xFF));
        buf.push_back((uint8_t)((s >> 16) & 0xFF));
    };
    for (uint32_t i = 0; i < n; ++i) { put24(L[i]); put24(R[i]); }
    const bool ok = std::fwrite(buf.data(), 1, buf.size(), f) == buf.size();
    return (std::fclose(f) == 0) && ok;
}

/// Standard MIDI file (type 0) of captured triggers. Tick = frame → beats at
/// `bpm`. Each hit is a 1/32 note (or shorter if the same note repeats sooner).
inline bool writeMidiFile(const std::string& path, const std::vector<TrigEvent>& evIn,
                          float sr, float bpm, const char* trackName = "Engine 909") {
    const int ppq = 480;
    const uint8_t chan = 9;   // MIDI channel 10 (drums)
    struct Msg { long long tick; int order; uint8_t a, b, c; };
    std::vector<Msg> msgs;
    auto toTick = [&](long long frame) {
        return (long long)std::llround((double)frame / (double)sr * (double)bpm / 60.0 * ppq);
    };
    std::vector<TrigEvent> ev = evIn;
    std::stable_sort(ev.begin(), ev.end(), [](const TrigEvent& x, const TrigEvent& y) { return x.frame < y.frame; });
    const long long noteLen = ppq / 8;   // 1/32 note
    for (size_t i = 0; i < ev.size(); ++i) {
        const int note = 36 + ev[i].voice;
        const long long t0 = toTick(ev[i].frame);
        long long t1 = t0 + noteLen;
        for (size_t j = i + 1; j < ev.size(); ++j)        // end before the next hit of the same note
            if (ev[j].voice == ev[i].voice) { t1 = std::min(t1, std::max(t0 + 1, toTick(ev[j].frame) - 1)); break; }
        const uint8_t vel = (uint8_t)std::max(1, std::min(127, (int)std::lround(ev[i].vel * 127.0f)));
        msgs.push_back({t0, 1, (uint8_t)(0x90 | chan), (uint8_t)note, vel});
        msgs.push_back({t1, 0, (uint8_t)(0x80 | chan), (uint8_t)note, 0});
    }
    std::stable_sort(msgs.begin(), msgs.end(), [](const Msg& x, const Msg& y) {
        return x.tick != y.tick ? x.tick < y.tick : x.order < y.order;   // note-offs first on a tick
    });
    std::vector<uint8_t> trk;
    auto vlq = [&](uint32_t v) {
        uint8_t tmp[5]; int n = 0; tmp[n++] = v & 0x7F;
        while ((v >>= 7)) tmp[n++] = (uint8_t)((v & 0x7F) | 0x80);
        while (n) trk.push_back(tmp[--n]);
    };
    // Track name + tempo + 4/4.
    const std::string nm(trackName);
    vlq(0); trk.push_back(0xFF); trk.push_back(0x03); vlq((uint32_t)nm.size()); trk.insert(trk.end(), nm.begin(), nm.end());
    const uint32_t uspq = (uint32_t)std::llround(60000000.0 / (double)bpm);
    vlq(0); trk.push_back(0xFF); trk.push_back(0x51); trk.push_back(3);
    trk.push_back((uint8_t)(uspq >> 16)); trk.push_back((uint8_t)(uspq >> 8)); trk.push_back((uint8_t)uspq);
    vlq(0); trk.push_back(0xFF); trk.push_back(0x58); trk.push_back(4);
    trk.push_back(4); trk.push_back(2); trk.push_back(24); trk.push_back(8);
    long long last = 0;
    for (const auto& m : msgs) {
        vlq((uint32_t)std::max(0LL, m.tick - last)); last = m.tick;
        trk.push_back(m.a); trk.push_back(m.b); trk.push_back(m.c);
    }
    vlq(0); trk.push_back(0xFF); trk.push_back(0x2F); trk.push_back(0);   // end of track

    FILE* f = std::fopen(path.c_str(), "wb");
    if (!f) return false;
    auto be32 = [&](uint32_t x) { uint8_t b[4] = {(uint8_t)(x >> 24), (uint8_t)(x >> 16), (uint8_t)(x >> 8), (uint8_t)x}; std::fwrite(b, 1, 4, f); };
    auto be16 = [&](uint16_t x) { uint8_t b[2] = {(uint8_t)(x >> 8), (uint8_t)x}; std::fwrite(b, 1, 2, f); };
    std::fwrite("MThd", 1, 4, f); be32(6); be16(0); be16(1); be16((uint16_t)ppq);
    std::fwrite("MTrk", 1, 4, f); be32((uint32_t)trk.size());
    const bool ok = std::fwrite(trk.data(), 1, trk.size(), f) == trk.size();
    return (std::fclose(f) == 0) && ok;
}

}  // namespace drm
