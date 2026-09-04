/*
 * ddsp_synth.h — the DDSP synthesis core: additive harmonic + filtered noise.
 *
 * Ported (de-JUCE'd) from magenta/ddsp-vst (Apache-2.0):
 *   src/audio/HarmonicSynthesizer.cpp, src/audio/NoiseSynthesizer.cpp
 *
 * Driven once per 20 ms hop by a `DdspControls` struct — amplitude, a 60-wide
 * relative harmonic distribution, and 65 noise-band magnitudes. Where those
 * numbers come from (a trained GRU decoder, or the analytic fallback) is the
 * control model's job, not the synth's.
 *
 * Both stages render directly at the host sample rate. DDSP-VST synthesises the
 * noise at the model's 16 kHz and resamples the audio; doing the frequency-
 * sampling FIR design at the host rate instead avoids the spectral images that
 * upsample folds in above 8 kHz (measured ~20 dB down, 8-24 kHz).
 */
#ifndef UPI_DDSP_SYNTH_H
#define UPI_DDSP_SYNTH_H

#include <cstdint>
#include <vector>

#include "ddsp_fft.h"

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

/// Frequency-sampling filtered white noise, rendered directly at the host rate.
///
/// The 65 band magnitudes describe the spectrum over [0, kModelSampleRate/2]
/// (8 kHz — the model's Nyquist); everything above that is synthesised as
/// silence. Designing the FIR at the host rate avoids the spectral images a
/// 16 kHz -> host upsample of the noise hop would fold in above 8 kHz.
class NoiseSynth {
public:
    /// `hopSamples` is the largest hop `render` will be asked for.
    void prepare(double sampleRate, int hopSamples);
    void reset();
    /// Writes `hop` host-rate samples of filtered noise into `out`.
    void render(const float* bands, float* out, int hop);

private:
    double sr_      = 48000.0;
    int    irLen_   = 0;                          // FIR length (even), ~128 * sr/16k
    int    magBins_ = 0;                          // irLen_/2 + 1
    int    nfft_    = 0;                           // pow2 for the convolution
    int    maxHop_  = 0;

    std::vector<float> hann_;                     // Hann window, irLen_
    std::vector<float> mag_;                      // host-rate magnitude spectrum, magBins_
    std::vector<float> ir_;                       // windowed impulse response, irLen_
    std::vector<float> noise_;                    // white-noise scratch, maxHop_ + irLen_
    std::vector<Cx>    irScratch_;                // irfft scratch, irLen_
    std::vector<Cx>    fftA_, fftB_;              // convolution scratch, nfft_

    uint32_t rng_ = 0x2545F491u;

    float whiteNoise() {
        rng_ ^= rng_ << 13; rng_ ^= rng_ >> 17; rng_ ^= rng_ << 5;
        return (float)(int32_t)rng_ * (1.0f / 2147483648.0f);
    }
};

} // namespace upi_ddsp

#endif /* UPI_DDSP_SYNTH_H */
