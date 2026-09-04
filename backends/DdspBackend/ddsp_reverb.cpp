// ddsp_reverb.cpp — see ddsp_reverb.h.

#include "ddsp_reverb.h"

#include <cmath>

namespace upi_ddsp {

namespace {

// Freeverb tuning, in samples at 44.1 kHz. Scaled to the host rate in prepare().
constexpr int kCombTuning[8]    = { 1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617 };
constexpr int kAllpassTuning[4] = { 556, 441, 341, 225 };
constexpr int kStereoSpread     = 23;

constexpr float kFixedGain   = 0.015f;   // input scale (8 combs in parallel)
constexpr float kRoomSize    = 0.86f;    // fixed "medium-large" room  (0..1 -> feedback)
constexpr float kDamping     = 0.35f;    // fixed HF absorption        (0..1)

constexpr float kRoomScale   = 0.28f;
constexpr float kRoomOffset  = 0.70f;

inline int scaled(int n44100, double sr) {
    int s = (int)std::lround((double)n44100 * sr / 44100.0);
    return s > 1 ? s : 1;
}

} // namespace

void PlateReverb::prepare(double sampleRate) {
    sr_ = sampleRate > 0 ? sampleRate : 48000.0;

    const float feedback = kRoomSize * kRoomScale + kRoomOffset;
    const float damp1    = kDamping * 0.4f;
    const float damp2    = 1.0f - damp1;

    for (int i = 0; i < kCombs; ++i) {
        combL_[i].init(scaled(kCombTuning[i], sr_));
        combR_[i].init(scaled(kCombTuning[i] + kStereoSpread, sr_));
        for (Comb* c : { &combL_[i], &combR_[i] }) {
            c->feedback = feedback; c->damp1 = damp1; c->damp2 = damp2;
        }
    }
    for (int i = 0; i < kAllpass; ++i) {
        apL_[i].init(scaled(kAllpassTuning[i], sr_));
        apR_[i].init(scaled(kAllpassTuning[i] + kStereoSpread, sr_));
    }
    reset();
}

void PlateReverb::reset() {
    for (int i = 0; i < kCombs;   ++i) { combL_[i].clear(); combR_[i].clear(); }
    for (int i = 0; i < kAllpass; ++i) { apL_[i].clear();   apR_[i].clear();   }
}

void PlateReverb::process(const float* in, float* outL, float* outR, int n, float mix) {
    mix = mix < 0.0f ? 0.0f : (mix > 1.0f ? 1.0f : mix);
    const float wet = mix;
    const float dry = 1.0f - 0.5f * mix;          // keep the instrument present even when wet

    if (wet <= 1.0e-4f) {
        for (int i = 0; i < n; ++i) outL[i] = outR[i] = in[i];
        return;
    }

    for (int i = 0; i < n; ++i) {
        const float x = std::isfinite(in[i]) ? in[i] * kFixedGain : 0.0f;
        float wl = 0.0f, wr = 0.0f;
        for (int c = 0; c < kCombs; ++c) { wl += combL_[c].process(x); wr += combR_[c].process(x); }
        for (int a = 0; a < kAllpass; ++a) { wl = apL_[a].process(wl); wr = apR_[a].process(wr); }
        // A stray NaN/inf would otherwise recirculate in the feedback lines
        // forever — scrub the whole tank if one appears.
        if (!std::isfinite(wl) || !std::isfinite(wr)) { reset(); wl = wr = 0.0f; }
        const float dryS = std::isfinite(in[i]) ? in[i] : 0.0f;
        outL[i] = dryS * dry + wl * wet;
        outR[i] = dryS * dry + wr * wet;
    }
}

} // namespace upi_ddsp
