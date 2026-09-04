// ddsp_synth.cpp — see ddsp_synth.h. Ported from magenta/ddsp-vst (Apache-2.0).

#include "ddsp_synth.h"
#include "ddsp_fft.h"

#include <algorithm>
#include <cmath>

namespace upi_ddsp {

namespace {
constexpr float  kTwoPi = 6.28318530717958647692f;

// Half-linear / half-hold interpolation across a hop. Linear `from`->`to` over
// the first half, hold `to` for the second — DDSP-VST's `midwayLerp`, chosen
// over plain linear to avoid "swoop" artifacts at the 20 ms hop rate.
void midwayLerp(float from, float to, float* out, int n) {
    const int mid = n / 2;
    if (mid > 0) {
        const float delta = (to - from) / (float)mid;
        float v = from;
        for (int i = 0; i < mid; ++i, v += delta) out[i] = v;
    }
    for (int i = mid; i < n; ++i) out[i] = to;
}
} // namespace

// ---- HarmonicSynth ------------------------------------------------------------

void HarmonicSynth::prepare(double sampleRate, int hopSamples) {
    sr_  = sampleRate > 0 ? sampleRate : 48000.0;
    hop_ = hopSamples > 0 ? hopSamples : 960;
    fEnv_.assign(hop_, 0.0f);
    ampEnv_.assign(kNumHarmonics, std::vector<float>(hop_, 0.0f));
    dist_.assign(kNumHarmonics, 0.0f);
    reset();
}

void HarmonicSynth::reset() {
    phase_  = 0.0;
    prevF0_ = 0.0f;
    primed_ = false;
    std::fill(std::begin(prevDist_), std::end(prevDist_), 0.0f);
}

void HarmonicSynth::render(const DdspControls& c, float* out, int hop) {
    // --- Nyquist-mask + renormalise the distribution at the render rate ---
    float f0 = c.f0Hz > 0.0f ? c.f0Hz : (prevF0_ > 0.0f ? prevF0_ : 1.0f);
    const float nyquist = 0.5f * (float)sr_;
    for (int i = 0; i < kNumHarmonics; ++i) {
        const float f = (float)(i + 1) * f0;
        float d = c.harmonicDist[i] < 0.0f ? 0.0f : c.harmonicDist[i];
        dist_[i] = (f >= nyquist) ? 0.0f : d;
    }
    float total = 0.0f;
    for (float d : dist_) total += d;
    const float scale = (total > 0.0f) ? (c.amplitude / total) : 0.0f;
    for (int i = 0; i < kNumHarmonics; ++i) dist_[i] *= scale;   // now sums to amplitude

    if (!primed_) {
        prevF0_ = f0;
        for (int i = 0; i < kNumHarmonics; ++i) prevDist_[i] = dist_[i];
        primed_ = true;
    }

    // --- control-rate -> audio-rate ---
    midwayLerp(prevF0_, f0, fEnv_.data(), hop);
    for (int i = 0; i < kNumHarmonics; ++i)
        midwayLerp(prevDist_[i], dist_[i], ampEnv_[i].data(), hop);

    // --- additive synthesis via a per-sample harmonic phasor recurrence ---
    const double twoPiOverSr = kTwoPi / sr_;
    double phase = phase_;
    for (int n = 0; n < hop; ++n) {
        phase += twoPiOverSr * fEnv_[n];
        const float ph = (float)phase;
        const float c1 = std::cos(ph), s1 = std::sin(ph);
        float zr = c1, zi = s1, acc = 0.0f;
        for (int h = 0; h < kNumHarmonics; ++h) {
            acc += zi * ampEnv_[h][n];               // zi == sin((h+1) * ph)
            const float nzr = zr * c1 - zi * s1;
            zi = zr * s1 + zi * c1;
            zr = nzr;
        }
        out[n] += acc;
    }
    phase_ = std::fmod(phase, kTwoPi);

    prevF0_ = f0;
    for (int i = 0; i < kNumHarmonics; ++i) prevDist_[i] = dist_[i];
}

// ---- NoiseSynth -------------------------------------------------------------

void NoiseSynth::prepare(double sampleRate, int hopSamples) {
    sr_     = sampleRate > 0 ? sampleRate : 48000.0;
    maxHop_ = hopSamples > 0 ? hopSamples : 960;

    // FIR length: the 16 kHz design is 128 taps ((kNumNoiseBands-1)*2); keep at
    // least that much time support at the host rate. Must be a power of two —
    // irfft_from_magnitudes()/fft() are radix-2.
    const int base = (kNumNoiseBands - 1) * 2;
    const double want = (double)base * sr_ / kModelSampleRate;
    irLen_ = base;
    while ((double)irLen_ < want) irLen_ <<= 1;
    magBins_ = irLen_ / 2 + 1;

    int need = (maxHop_ + irLen_) + irLen_ - 1;
    nfft_ = 1;
    while (nfft_ < need) nfft_ <<= 1;

    hann_.assign(irLen_, 0.0f);
    for (int i = 0; i < irLen_; ++i)
        hann_[i] = 0.5f * (1.0f - std::cos(kTwoPi * (float)i / (float)irLen_));
    std::rotate(hann_.begin(), hann_.begin() + irLen_ / 2, hann_.end());   // zero-phase form: peak at index 0

    mag_.assign(magBins_, 0.0f);
    ir_.assign(irLen_, 0.0f);
    noise_.assign(maxHop_ + irLen_, 0.0f);
    irScratch_.assign(irLen_, Cx{ 0.0f, 0.0f });
    fftA_.assign(nfft_, Cx{ 0.0f, 0.0f });
    fftB_.assign(nfft_, Cx{ 0.0f, 0.0f });
    reset();
}

void NoiseSynth::reset() { rng_ = 0x2545F491u; }

void NoiseSynth::render(const float* bands, float* out, int hop) {
    if (hop > maxHop_) hop = maxHop_;

    // Resample the 65 band magnitudes (spanning [0, kModelSampleRate/2]) onto
    // the host-rate one-sided spectrum; zero above the model's 8 kHz Nyquist.
    const float bandHz  = 0.5f * (float)kModelSampleRate;
    const float binHz   = (float)sr_ / (float)irLen_;
    const float perBand = bandHz / (float)(kNumNoiseBands - 1);
    for (int k = 0; k < magBins_; ++k) {
        const float f = (float)k * binHz;
        if (f >= bandHz) { mag_[k] = 0.0f; continue; }
        const float pos = f / perBand;
        const int   i0  = (int)pos;
        const float fr  = pos - (float)i0;
        const int   i1  = i0 + 1 < kNumNoiseBands ? i0 + 1 : kNumNoiseBands - 1;
        mag_[k] = bands[i0] + (bands[i1] - bands[i0]) * fr;
    }

    // frequency sampling: magnitude spectrum -> linear-phase Hann-windowed FIR
    irfft_from_magnitudes(mag_.data(), magBins_, irScratch_.data(), ir_.data());
    for (int i = 0; i < irLen_; ++i) ir_[i] *= hann_[i];
    std::rotate(ir_.begin(), ir_.begin() + irLen_ / 2, ir_.end());          // -> causal / linear phase

    for (int i = 0; i < hop + irLen_; ++i) noise_[i] = whiteNoise();

    fft_convolve(noise_.data(), hop + irLen_, ir_.data(), irLen_,
                 fftA_.data(), fftB_.data(), nfft_,
                 out, hop, irLen_ / 2);                     // FIR group-delay trim
}

} // namespace upi_ddsp
