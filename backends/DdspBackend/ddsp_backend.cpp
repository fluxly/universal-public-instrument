// ddsp_backend.cpp — see ddsp_backend.h.
//
// Realtime rules in render(): no allocation, no locks, no syscalls. All buffers
// are sized in prepare().

#include "ddsp_backend.h"
#include "ddsp_synth.h"
#include "ddsp_decoder.h"
#include "ddsp_reverb.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <new>
#include <vector>

namespace {

using namespace upi_ddsp;

constexpr float  kControlRate = (float)kModelSampleRate / (float)kModelHop;  // 50 Hz

inline float clampf(float x, float lo, float hi) { return x < lo ? lo : (x > hi ? hi : x); }
inline float lerpf(float a, float b, float t)    { return a + (b - a) * t; }

// ---- analytic identity endpoints -----------------------------------------
//
// Stand-ins for the trained DDSP decoders. `bright` / `air` are 0..1 macro
// positions. Hand-tuned by shape, not by measurement — the point is the
// architecture; a listening pass (or the real .tflite models) refines them.

void trumpetSpectrum(float f0, float bright, float* harm) {
    for (int i = 0; i < kNumHarmonics; ++i) {
        const int   n  = i + 1;
        const float fn = (float)n * f0;
        float a = std::pow((float)n, -0.70f - 0.55f * (1.0f - bright));   // brighter => shallower rolloff
        const float formant = std::exp(-0.5f * std::pow((fn - 1500.0f) / 750.0f, 2.0f));
        a *= 1.0f + 1.1f * formant;                                       // ~1.5 kHz brass formant
        harm[i] = a;
    }
}

void clarinetSpectrum(float f0, float bright, float* harm) {
    (void)f0;
    for (int i = 0; i < kNumHarmonics; ++i) {
        const int   n   = i + 1;
        const float odd = (n & 1) ? 1.0f : 0.16f;                         // hollow: odd-dominant
        const float rolloff = std::pow((float)n, -1.25f + 0.45f * bright);
        const float cutN    = 9.0f + 9.0f * bright;
        const float lp      = 1.0f / (1.0f + std::pow((float)n / cutN, 4.0f));  // steep upper cut
        harm[i] = odd * rolloff * lp;
    }
}

void trumpetNoise(float air, float* nb) {
    for (int i = 0; i < kNumNoiseBands; ++i) {
        const float fc = (float)i * (float)(kModelSampleRate * 0.5 / (kNumNoiseBands - 1));
        const float shape = std::exp(-0.5f * std::pow((fc - 1800.0f) / 1700.0f, 2.0f)) + 0.12f;
        nb[i] = air * 0.030f * shape;
    }
}

void clarinetNoise(float air, float* nb) {
    for (int i = 0; i < kNumNoiseBands; ++i) {
        const float fc = (float)i * (float)(kModelSampleRate * 0.5 / (kNumNoiseBands - 1));
        const float shape = std::exp(-fc / 1300.0f) + 0.04f;
        nb[i] = air * 0.022f * shape;
    }
}

// ---- amplitude envelope (control rate) ----------------------------------

struct AREnvelope {
    float level = 0.0f;
    float atkCoef = 0.0f, relCoef = 0.0f;

    void setTimes(float atkSeconds, float relSeconds) {
        atkCoef = atkSeconds > 1e-4f ? std::exp(-1.0f / (atkSeconds * kControlRate)) : 0.0f;
        relCoef = relSeconds > 1e-4f ? std::exp(-1.0f / (relSeconds * kControlRate)) : 0.0f;
    }
    float tick(bool gate) {
        const float target = gate ? 1.0f : 0.0f;
        const float c = gate ? atkCoef : relCoef;
        level = target + (level - target) * c;
        if (!gate && level < 1e-5f) level = 0.0f;
        return level;
    }
    bool active(bool gate) const { return gate || level > 1e-5f; }
};

// ---- backend instance --------------------------------------------------

struct DdspBackend {
    double   sampleRate   = 48000.0;
    uint32_t channelCount = 2;
    uint32_t maxFrames    = 512;

    int   hopHost = 960;                 // kModelHop resampled to the host rate
    float srRatio = 3.0f;                // hostRate / kModelSampleRate

    HarmonicSynth harmonic;
    NoiseSynth    noise;
    PlateReverb   reverb;
    AREnvelope    env;

    // trained DDSP decoders — endpoint A (identity 0) and B (identity 1).
    // When both load, the control model is neural; otherwise the analytic one.
    DdspDecoder decoderA, decoderB;
    bool  neural    = false;
    float masterGain = 1.6f;

    // voice 0
    float pitchHz  = 261.63f;
    float velocity = 0.0f;
    bool  gate     = false;

    // per-hop scratch (sized in prepare)
    std::vector<float> hopHarm;          // hopHost
    std::vector<float> hopNoise;         // hopHost (host-rate filtered noise)

    // output-block scratch (sized in prepare): mono synth -> stereo reverb
    std::vector<float> blkMono, blkL, blkR;

    // output ring (mono)
    std::vector<float> ring;
    size_t ringHead = 0, ringTail = 0, ringCap = 0;

    size_t ringCount() const { return (ringHead + ringCap - ringTail) % ringCap; }
    void ringPush(const float* mono, size_t n) {
        for (size_t i = 0; i < n; ++i) { ring[ringHead] = mono[i]; ringHead = (ringHead + 1) % ringCap; }
    }
    void ringPopMono(float* dst, uint32_t frames) {
        for (uint32_t f = 0; f < frames; ++f) {
            dst[f] = ring[ringTail];
            ringTail = (ringTail + 1) % ringCap;
        }
    }

    void renderHop() {
        DdspControls ctl;
        ctl.f0Hz = pitchHz;

        const float k          = clampf(gControlIdentity, 0.0f, 1.0f);
        const float expression = clampf(gControlExpr, 0.0f, 1.0f);
        const float bright     = clampf(gControlBright, 0.0f, 1.0f);
        const float air        = clampf(gControlAir, 0.0f, 1.0f);
        const float attackSec  = 0.002f + gControlAttack * gControlAttack * 0.5f;
        env.setTimes(attackSec, 0.20f);
        const float envLevel = env.tick(gate);

        float noiseScale = 1.0f;

        if (neural) {
            // loudness the model was conditioned on: a played dynamic envelope.
            const float midi = 69.0f + 12.0f * std::log2(std::max(20.0f, pitchHz) / 440.0f);
            const float f0Scaled = clampf(midi / 127.0f, 0.0f, 1.0f);
            const float loud = clampf(envLevel * (0.25f + 0.75f * velocity)
                                              * (0.35f + 0.65f * expression), 0.0f, 1.0f);

            float ampA, hA[kNumHarmonics], nA[kNumNoiseBands];
            float ampB, hB[kNumHarmonics], nB[kNumNoiseBands];
            decoderA.step(f0Scaled, loud, pitchHz, ampA, hA, nA);
            decoderB.step(f0Scaled, loud, pitchHz, ampB, hB, nB);

            ctl.amplitude = lerpf(ampA, ampB, k) * envLevel * masterGain;
            for (int i = 0; i < kNumHarmonics; ++i)  ctl.harmonicDist[i] = lerpf(hA[i], hB[i], k);
            for (int i = 0; i < kNumNoiseBands; ++i) ctl.noiseBands[i]    = lerpf(nA[i], nB[i], k);
            noiseScale = (0.2f + 0.8f * air) * envLevel * masterGain;
        } else {
            float tH[kNumHarmonics], cH[kNumHarmonics], tN[kNumNoiseBands], cN[kNumNoiseBands];
            trumpetSpectrum(pitchHz, bright, tH);
            clarinetSpectrum(pitchHz, bright, cH);
            trumpetNoise(air, tN);
            clarinetNoise(air, cN);
            for (int i = 0; i < kNumHarmonics; ++i)  ctl.harmonicDist[i] = lerpf(tH[i], cH[i], k);
            for (int i = 0; i < kNumNoiseBands; ++i) ctl.noiseBands[i]    = lerpf(tN[i], cN[i], k);
            ctl.amplitude = envLevel * (0.15f + 0.85f * velocity) * (0.3f + 0.7f * expression);
            noiseScale = ctl.amplitude;
        }

        // --- synth (both at the host rate) ---
        std::fill(hopHarm.begin(), hopHarm.end(), 0.0f);
        harmonic.render(ctl, hopHarm.data(), hopHost);
        noise.render(ctl.noiseBands, hopNoise.data(), hopHost);

        for (int j = 0; j < hopHost; ++j)
            hopHarm[j] = (hopHarm[j] + hopNoise[j] * noiseScale) * 0.5f;   // + headroom

        ringPush(hopHarm.data(), (size_t)hopHost);
    }

    // control atomics are simple floats written from render() only (audio
    // thread), so plain members are fine here.
    float gControlIdentity = 0.0f, gControlExpr = 0.8f, gControlBright = 0.5f;
    float gControlAir = 0.12f, gControlAttack = 0.2f, gControlReverb = 0.2f;
};

// Read a whole file into `dst`. prepare()-time only (not realtime).
bool slurpFile(const char *path, std::vector<char> &dst) {
    FILE *f = std::fopen(path, "rb");
    if (!f) return false;
    std::fseek(f, 0, SEEK_END);
    const long n = std::ftell(f);
    std::fseek(f, 0, SEEK_SET);
    bool ok = n > 0;
    if (ok) {
        dst.resize((size_t)n);
        ok = std::fread(dst.data(), 1, (size_t)n, f) == (size_t)n;
    }
    std::fclose(f);
    return ok;
}

// ---- vtable ------------------------------------------------------------

UPIBackend *ddsp_create(void) {
    return reinterpret_cast<UPIBackend *>(new (std::nothrow) DdspBackend());
}

void ddsp_destroy(UPIBackend *self) { delete reinterpret_cast<DdspBackend *>(self); }

int32_t ddsp_prepare(UPIBackend *self, const UPIBackendConfig *cfg) {
    auto *b = reinterpret_cast<DdspBackend *>(self);
    if (!b || !cfg || cfg->sample_rate <= 0.0) return -1;

    b->sampleRate   = cfg->sample_rate;
    b->channelCount = cfg->channel_count ? cfg->channel_count : 2;
    b->maxFrames    = cfg->max_frames ? cfg->max_frames : 512;

    b->srRatio = (float)(b->sampleRate / kModelSampleRate);
    b->hopHost = (int)std::lround((double)kModelHop * b->srRatio);

    b->harmonic.prepare(b->sampleRate, b->hopHost);
    b->noise.prepare(b->sampleRate, b->hopHost);
    b->reverb.prepare(b->sampleRate);
    b->env = AREnvelope{};

    // trained DDSP endpoints (identity 0 / 1). Both must load, else fall back
    // to the analytic control model.
    b->neural = false;
    if (cfg->resolve_resource) {
        const char *pa = cfg->resolve_resource(cfg->resolver_ctx, "decoder_a");
        const char *pb = cfg->resolve_resource(cfg->resolver_ctx, "decoder_b");
        std::vector<char> ba, bb;
        if (pa && pb && slurpFile(pa, ba) && slurpFile(pb, bb) &&
            b->decoderA.load(ba.data(), ba.size()) &&
            b->decoderB.load(bb.data(), bb.size())) {
            b->neural = true;
        }
    }

    b->hopHarm.assign((size_t)b->hopHost, 0.0f);
    b->hopNoise.assign((size_t)b->hopHost, 0.0f);
    b->blkMono.assign((size_t)b->maxFrames, 0.0f);
    b->blkL.assign((size_t)b->maxFrames, 0.0f);
    b->blkR.assign((size_t)b->maxFrames, 0.0f);

    const size_t worst = (size_t)b->maxFrames + (size_t)b->hopHost + 1;
    b->ringCap = worst;
    b->ring.assign(b->ringCap, 0.0f);
    b->ringHead = b->ringTail = 0;

    b->pitchHz = 261.63f; b->velocity = 0.0f; b->gate = false;
    return 0;
}

void ddsp_reset(UPIBackend *self) {
    auto *b = reinterpret_cast<DdspBackend *>(self);
    if (!b) return;
    b->harmonic.reset();
    b->noise.reset();
    b->reverb.reset();
    b->decoderA.reset();
    b->decoderB.reset();
    b->env = AREnvelope{};
    b->gate = false; b->velocity = 0.0f;
    b->ringHead = b->ringTail = 0;
    std::fill(b->ring.begin(), b->ring.end(), 0.0f);
}

void ddsp_get_capabilities(UPIBackend *, UPIBackendCapabilities *out) {
    out->abi_version         = UPI_BACKEND_ABI_VERSION;
    out->voice_mode          = UPI_VOICE_MONO;
    out->thread_model        = UPI_THREAD_AUDIO;
    out->max_voices          = 1;
    out->continuous_identity = 1;                 // genuine continuous timbre morph
    out->latency_frames      = 0;                 // ring stays <= 1 hop behind
    out->tail_frames         = (uint32_t)(PlateReverb::kTailSeconds * 48000.0f);
}

uint32_t ddsp_parameter_count(UPIBackend *) { return 0; }
void     ddsp_parameter_info(UPIBackend *, uint32_t, UPIParameterInfo *out) {
    if (out) std::memset(out, 0, sizeof(*out));
}
void  ddsp_set_parameter(UPIBackend *, uint32_t, float) {}
float ddsp_get_parameter(UPIBackend *, uint32_t) { return 0.0f; }

void ddsp_render(UPIBackend *self, const UPIControlFrame *cf,
                 float *const *out, uint32_t frames) {
    auto *b = reinterpret_cast<DdspBackend *>(self);
    if (!b) return;
    const uint32_t chans = b->channelCount;

    // voice 0 (monophonic)
    b->gate = false;
    if (cf->voice_count > 0) {
        const UPIVoiceState &v = cf->voices[0];
        if (v.note_id >= 0) {
            b->gate     = v.gate != 0;
            b->pitchHz  = v.pitch_hz > 0.0f ? v.pitch_hz : b->pitchHz;
            b->velocity = v.velocity;
        }
    }
    b->gControlIdentity = cf->identity[0];
    b->gControlExpr     = cf->macros[0];
    b->gControlBright   = cf->macros[2];
    b->gControlAir      = cf->macros[3];
    b->gControlAttack   = cf->macros[4];
    b->gControlReverb   = cf->macros[5];

    if (frames > b->maxFrames) frames = b->maxFrames;   // scratch is sized to maxFrames

    while (b->ringCount() < (size_t)frames) b->renderHop();
    b->ringPopMono(b->blkMono.data(), frames);
    b->reverb.process(b->blkMono.data(), b->blkL.data(), b->blkR.data(),
                      (int)frames, clampf(b->gControlReverb, 0.0f, 1.0f));

    for (uint32_t f = 0; f < frames; ++f) {
        const float L = b->blkL[f], R = b->blkR[f];
        if (chans == 1) {
            out[0][f] = 0.5f * (L + R);
        } else {
            for (uint32_t c = 0; c < chans; ++c) out[c][f] = (c & 1u) ? R : L;
        }
    }
}

} // namespace

extern "C" const UPIBackendVTable *upi_ddsp_backend_entry(void) {
    static const UPIBackendVTable vt = {
        UPI_BACKEND_ABI_VERSION,
        ddsp_create, ddsp_destroy, ddsp_prepare, ddsp_reset,
        ddsp_get_capabilities, ddsp_parameter_count, ddsp_parameter_info,
        ddsp_set_parameter, ddsp_get_parameter, ddsp_render
    };
    return &vt;
}
