// ddsp_decoder.cpp — see ddsp_decoder.h.

#include "ddsp_decoder.h"

#include <cmath>
#include <cstring>

#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif

namespace upi_ddsp {

namespace {

constexpr float kLnEps      = 1e-3f;
constexpr float kLeakyAlpha = 0.2f;
constexpr float kExpSigPow  = 2.30258509299f;  // ln(10)
constexpr float kExpSigMax  = 2.0f;
constexpr float kExpSigThr  = 1e-7f;
constexpr float kNoiseBias  = -5.0f;
constexpr float kNyquistHz  = 8000.0f;         // model trained at 16 kHz

inline float sigmoidf(float x) { return 1.0f / (1.0f + std::exp(-x)); }

inline float expSigmoid(float x) {
    return kExpSigMax * std::pow(sigmoidf(x), kExpSigPow) + kExpSigThr;
}

// y[o] = b[o] + sum_i W[o*IN + i] * x[i]     (tflite FULLY_CONNECTED layout)
//
// This is the decoder's whole cost — the GRU alone is two 1536x512 mat-vecs per
// 50 Hz hop, x2 decoders. Four independent accumulators break the reduction
// dependency chain so the compiler emits NEON/AVX FMAs; ~8x over the naive loop
// and enough to stay well inside a small-buffer audio deadline.
inline void fc(const float *x, const float *W, const float *b,
               float *y, int in, int out) {
    for (int o = 0; o < out; ++o) {
        const float *row = W + (std::size_t)o * in;
        int i = 0;
        float acc;
#if defined(__ARM_NEON)
        float32x4_t v0 = vdupq_n_f32(0.f), v1 = vdupq_n_f32(0.f);
        for (; i + 8 <= in; i += 8) {
            v0 = vfmaq_f32(v0, vld1q_f32(row + i),     vld1q_f32(x + i));
            v1 = vfmaq_f32(v1, vld1q_f32(row + i + 4), vld1q_f32(x + i + 4));
        }
        acc = b[o] + vaddvq_f32(vaddq_f32(v0, v1));
#else
        float a0 = 0.f, a1 = 0.f, a2 = 0.f, a3 = 0.f;
        for (; i + 4 <= in; i += 4) {
            a0 += row[i + 0] * x[i + 0]; a1 += row[i + 1] * x[i + 1];
            a2 += row[i + 2] * x[i + 2]; a3 += row[i + 3] * x[i + 3];
        }
        acc = b[o] + (a0 + a1) + (a2 + a3);
#endif
        for (; i < in; ++i) acc += row[i] * x[i];
        y[o] = acc;
    }
}

// in-place LayerNorm over `n` features, then affine (g, b).
inline void layerNorm(float *x, const float *g, const float *b, int n) {
    float mean = 0.0f;
    for (int i = 0; i < n; ++i) mean += x[i];
    mean /= (float)n;
    float var = 0.0f;
    for (int i = 0; i < n; ++i) { const float d = x[i] - mean; var += d * d; }
    var /= (float)n;
    const float inv = 1.0f / std::sqrt(var + kLnEps);
    for (int i = 0; i < n; ++i) x[i] = (x[i] - mean) * inv * g[i] + b[i];
}

inline void leakyRelu(float *x, int n) {
    for (int i = 0; i < n; ++i) if (x[i] < 0.0f) x[i] *= kLeakyAlpha;
}

// dense from a scalar input: y[o] = b[o] + W[o] * x
inline void denseFromScalar(float x, const float *W, const float *b, float *y, int out) {
    for (int o = 0; o < out; ++o) y[o] = b[o] + W[o] * x;
}

} // namespace

bool DdspDecoder::load(const void *data, std::size_t bytes) {
    loaded_ = false;
    static const char kMagic[8] = { 'D','D','S','P','W','1',0,0 };
    if (bytes < 8 || std::memcmp(data, kMagic, 8) != 0) return false;

    const std::size_t nFloats = (bytes - 8) / sizeof(float);
    // fc_pw(256+256+256+256) fc_f0(1024) gru(2*(1536*512)+2*1536)
    //   fc_out(256*1024+256+256+256) dense(126*256+126)
    const std::size_t expect =
        4u * 256 + 4u * 256 +
        2u * ((std::size_t)1536 * 512) + 2u * 1536 +
        (std::size_t)256 * 1024 + 256 + 256 + 256 +
        (std::size_t)126 * 256 + 126;
    if (nFloats != expect) return false;

    buf_.resize(nFloats);
    std::memcpy(buf_.data(), (const char *)data + 8, nFloats * sizeof(float));

    const float *p = buf_.data();
    auto take = [&](std::size_t n) { const float *r = p; p += n; return r; };

    fc_pw_W = take(256); fc_pw_b = take(256); ln_pw_g = take(256); ln_pw_b = take(256);
    fc_f0_W = take(256); fc_f0_b = take(256); ln_f0_g = take(256); ln_f0_b = take(256);
    gru_Wx  = take((std::size_t)1536 * 512); gru_bx = take(1536);
    gru_Wh  = take((std::size_t)1536 * 512); gru_bh = take(1536);
    fc_out_W = take((std::size_t)256 * 1024); fc_out_b = take(256);
    ln_out_g = take(256); ln_out_b = take(256);
    dense_W = take((std::size_t)126 * 256); dense_b = take(126);

    reset();
    loaded_ = true;
    return true;
}

void DdspDecoder::reset() { std::memset(state_, 0, sizeof(state_)); }

void DdspDecoder::step(float f0Scaled, float pwScaled, float f0Hz,
                       float &amp, float *harm, float *noise) {
    if (!loaded_) { amp = 0.0f; std::memset(harm, 0, kHarmonics * sizeof(float));
                    std::memset(noise, 0, kNoiseBands * sizeof(float)); return; }

    // --- input MLPs ---
    float pw[256], f0[256];
    denseFromScalar(pwScaled, fc_pw_W, fc_pw_b, pw, 256);
    layerNorm(pw, ln_pw_g, ln_pw_b, 256); leakyRelu(pw, 256);
    denseFromScalar(f0Scaled, fc_f0_W, fc_f0_b, f0, 256);
    layerNorm(f0, ln_f0_g, ln_f0_b, 256); leakyRelu(f0, 256);

    // --- GRU (reset_after), input = concat(pw, f0) ---
    float cat[512];
    std::memcpy(cat, pw, sizeof(pw));
    std::memcpy(cat + 256, f0, sizeof(f0));

    float Rx[1536], Rh[1536];
    fc(cat,    gru_Wx, gru_bx, Rx, 512, 1536);
    fc(state_, gru_Wh, gru_bh, Rh, 512, 1536);
    for (int j = 0; j < kGru; ++j) {
        const float z  = sigmoidf(Rx[j]        + Rh[j]);
        const float r  = sigmoidf(Rx[512 + j]  + Rh[512 + j]);
        const float hh = std::tanh(Rx[1024 + j] + r * Rh[1024 + j]);
        state_[j] = z * state_[j] + (1.0f - z) * hh;
    }

    // --- output MLP, input = concat(pw, f0, gru_out) ---
    float cat2[1024];
    std::memcpy(cat2, pw, sizeof(pw));
    std::memcpy(cat2 + 256, f0, sizeof(f0));
    std::memcpy(cat2 + 512, state_, sizeof(state_));

    float mlp[256];
    fc(cat2, fc_out_W, fc_out_b, mlp, 1024, 256);
    layerNorm(mlp, ln_out_g, ln_out_b, 256); leakyRelu(mlp, 256);

    float out126[126];
    fc(mlp, dense_W, dense_b, out126, 256, 126);

    // --- exp_sigmoid heads ---
    amp = expSigmoid(out126[0]);
    for (int i = 0; i < kHarmonics; ++i)  harm[i]  = expSigmoid(out126[1 + i]);
    for (int i = 0; i < kNoiseBands; ++i) noise[i] = expSigmoid(out126[61 + i] + kNoiseBias);

    // --- harmonic Nyquist mask (16 kHz) + renormalise to sum 1 ---
    float total = 0.0f;
    for (int i = 0; i < kHarmonics; ++i) {
        if ((float)(i + 1) * f0Hz >= kNyquistHz) harm[i] = 0.0f;
        total += harm[i];
    }
    const float denom = total > 0.0f ? total : kExpSigThr;
    for (int i = 0; i < kHarmonics; ++i) harm[i] /= denom;
}

} // namespace upi_ddsp
