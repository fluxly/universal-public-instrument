/*
 * ddsp_synth.h — the DDSP synthesis core: additive harmonic + filtered noise.
 *
 * Ported (de-JUCE'd) from magenta/ddsp-vst (Apache-2.0):
 *   src/audio/HarmonicSynthesizer.cpp, src/audio/NoiseSynthesizer.cpp
 *
 * Driven once per 20 ms hop by a `DdspControls` struct — amplitude, a 60-wide
 * relative harmonic distribution, and 65 noise-band magnitudes. Where those
 * numbers come from (a hand-authored spectral model now, a trained GRU later)
 * is the control model's job, not the synth's.
 */
#ifndef UPI_DDSP_SYNTH_H
#define UPI_DDSP_SYNTH_H

#include <cstdint>
#include <vector>

namespace upi_ddsp {

constexpr int    kNumHarmonics    = 60;
constexpr int    kNumNoiseBands   = 65;
constexpr double kModelSampleRate = 16000.0;   // noise band structure spans [0, 8 kHz]
constexpr int    kModelHop        = 320;       // samples @ 16 kHz  ->  50 Hz frame rate

/// One hop of control-rate synthesis parameters.
struct DdspControls {
    float amplitude = 0.0f;                       // overall harmonic level (>= 0)
    float harmonicDist[kNumHarmonics]  = {};      // relative harmonic amplitudes (>= 0)
    float noiseBands[kNumNoiseBands]   = {};      // per-band noise magnitude (>= 0)
    float f0Hz = 0.0f;                            // fundamental for this hop
};

/// Additive synth. Renders at the host sample rate directly (SR-agnostic:
/// Nyquist masking uses the render rate).
class HarmonicSynth {
public:
    void prepare(double sampleRate, int hopSamples);
    void reset();
    /// Adds `hop` samples of harmonic audio into `out`.
    void render(const DdspControls& c, float* out, int hop);

private:
    double sr_    = 48000.0;
    int    hop_   = 960;
    double phase_ = 0.0;                          // accumulated fundamental phase (rad)
    float  prevF0_ = 0.0f;
    float  prevDist_[kNumHarmonics] = {};
    bool   primed_ = false;
    std::vector<float> fEnv_;                     // per-sample fundamental Hz (scratch)
    std::vector<std::vector<float>> ampEnv_;      // per-harmonic per-sample amp (scratch)
    std::vector<float> dist_;                     // masked/normalised distribution (scratch)
};

/// Frequency-sampling filtered white noise. Always renders at kModelSampleRate;
/// the backend resamples the hop to the host rate.
class NoiseSynth {
public:
    void prepare();
    void reset();
    /// Writes `kModelHop` samples of filtered noise into `out`.
    void render(const float* bands, float* out);

private:
    static constexpr int kIrLen = (kNumNoiseBands - 1) * 2;   // 128
    std::vector<float> hann_;                     // zero-phase Hann window, kIrLen
    std::vector<float> ir_;                       // windowed impulse response
    std::vector<float> noise_;                    // white-noise scratch
    uint32_t rng_ = 0x2545F491u;

    float whiteNoise() {
        rng_ ^= rng_ << 13; rng_ ^= rng_ >> 17; rng_ ^= rng_ << 5;
        return (float)(int32_t)rng_ * (1.0f / 2147483648.0f);
    }
};

} // namespace upi_ddsp

#endif /* UPI_DDSP_SYNTH_H */
