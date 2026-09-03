// oscillator_backend.cpp — see oscillator_backend.h
//
// Realtime rules obeyed in render(): no allocation, no locks, no syscalls.

#include "oscillator_backend.h"

#include <atomic>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <new>

namespace {

constexpr float kPi    = 3.14159265358979323846f;
constexpr float kTwoPi = 2.0f * kPi;

inline float clampf(float x, float lo, float hi) {
    return x < lo ? lo : (x > hi ? hi : x);
}

// PolyBLEP residual for band-limiting saw/square discontinuities.
inline float polyBlep(float t, float dt) {
    if (dt <= 0.0f) return 0.0f;
    if (t < dt) {
        t /= dt;
        return t + t - t * t - 1.0f;
    } else if (t > 1.0f - dt) {
        t = (t - 1.0f) / dt;
        return t * t + t + t + 1.0f;
    }
    return 0.0f;
}

struct Envelope {
    enum Stage { Idle, Attack, Decay, Sustain, Release };
    Stage stage = Idle;
    float level = 0.0f;

    void gateOn()  { stage = Attack; }
    void gateOff() { if (stage != Idle) stage = Release; }
    bool active() const { return stage != Idle; }

    float process(float a, float d, float s, float r, float sr) {
        const float aRate = a > 1e-4f ? 1.0f / (a * sr) : 1.0f;
        const float dRate = d > 1e-4f ? 1.0f / (d * sr) : 1.0f;
        const float rRate = r > 1e-4f ? 1.0f / (r * sr) : 1.0f;
        switch (stage) {
            case Attack:
                level += aRate;
                if (level >= 1.0f) { level = 1.0f; stage = Decay; }
                break;
            case Decay:
                level -= dRate;
                if (level <= s) { level = s; stage = Sustain; }
                break;
            case Sustain:
                level = s;
                break;
            case Release:
                level -= rRate;
                if (level <= 0.0f) { level = 0.0f; stage = Idle; }
                break;
            case Idle:
            default:
                level = 0.0f;
                break;
        }
        return level;
    }
};

struct Voice {
    int32_t  noteId   = -1;
    bool     gate     = false;
    float    phase    = 0.0f;   // 0..1
    float    freq     = 0.0f;   // current (glided) Hz
    float    target   = 0.0f;   // target Hz
    float    velocity = 0.0f;
    float    lpTri    = 0.0f;   // leaky integrator state for the triangle wave
    Envelope env;

    bool idle() const { return !env.active(); }
};

constexpr int kVoiceCount = 8;

struct OscBackend {
    double   sampleRate   = 48000.0;
    uint32_t maxFrames    = 512;
    uint32_t channelCount = 2;

    std::atomic<float> params[UPI_OSC_PARAM_COUNT];

    Voice    voices[kVoiceCount];
    float    lpState  = 0.0f;      // one-pole lowpass memory (post-mix)
    uint32_t rngState = 0x12345u;

    OscBackend() {
        const float defaults[UPI_OSC_PARAM_COUNT] = {
            /*waveform*/ 0.0f, /*attack*/ 0.005f, /*decay*/ 0.12f, /*sustain*/ 0.8f,
            /*release*/ 0.25f, /*gain*/ 0.8f, /*glide*/ 0.0f, /*cutoff*/ 1.0f,
            /*noise*/ 0.0f
        };
        for (uint32_t i = 0; i < UPI_OSC_PARAM_COUNT; ++i)
            params[i].store(defaults[i], std::memory_order_relaxed);
    }

    float p(int a) const { return params[a].load(std::memory_order_relaxed); }

    float whiteNoise() {
        rngState = rngState * 1664525u + 1013904223u;
        return (float)((int32_t)rngState) * (1.0f / 2147483648.0f);
    }

    Voice *findVoice(int32_t noteId) {
        for (auto &v : voices) if (v.noteId == noteId) return &v;
        return nullptr;
    }
    Voice *allocVoice() {
        Voice *quietest = &voices[0];
        for (auto &v : voices) {
            if (v.idle()) return &v;
            if (v.env.level < quietest->env.level) quietest = &v;
        }
        return quietest; // steal
    }
};

// ---- vtable implementations ------------------------------------------------

UPIBackend *osc_create(void) {
    return reinterpret_cast<UPIBackend *>(new (std::nothrow) OscBackend());
}

void osc_destroy(UPIBackend *self) {
    delete reinterpret_cast<OscBackend *>(self);
}

int32_t osc_prepare(UPIBackend *self, const UPIBackendConfig *cfg) {
    auto *b = reinterpret_cast<OscBackend *>(self);
    if (!b || !cfg || cfg->sample_rate <= 0.0) return -1;
    b->sampleRate   = cfg->sample_rate;
    b->maxFrames    = cfg->max_frames;
    b->channelCount = cfg->channel_count ? cfg->channel_count : 2;
    b->lpState = 0.0f;
    for (auto &v : b->voices) v = Voice{};
    return 0;
}

void osc_reset(UPIBackend *self) {
    auto *b = reinterpret_cast<OscBackend *>(self);
    for (auto &v : b->voices) v = Voice{};
    b->lpState = 0.0f;
}

void osc_get_capabilities(UPIBackend *, UPIBackendCapabilities *out) {
    out->abi_version         = UPI_BACKEND_ABI_VERSION;
    out->voice_mode          = UPI_VOICE_POLY;
    out->thread_model        = UPI_THREAD_AUDIO;
    out->max_voices          = kVoiceCount;
    out->continuous_identity = 0;
    out->latency_frames      = 0;
    out->tail_frames         = 0;
}

uint32_t osc_parameter_count(UPIBackend *) { return UPI_OSC_PARAM_COUNT; }

void osc_parameter_info(UPIBackend *, uint32_t index, UPIParameterInfo *out) {
    struct Row { uint32_t addr; const char *id; const char *name;
                 float lo, hi, def; const char *unit; };
    static const Row rows[UPI_OSC_PARAM_COUNT] = {
        { UPI_OSC_PARAM_WAVEFORM, "waveform",  "Waveform",   0.0f, 3.0f, 0.0f,   nullptr },
        { UPI_OSC_PARAM_ATTACK,   "attack",    "Attack",     0.0f, 4.0f, 0.005f, "s" },
        { UPI_OSC_PARAM_DECAY,    "decay",     "Decay",      0.0f, 4.0f, 0.12f,  "s" },
        { UPI_OSC_PARAM_SUSTAIN,  "sustain",   "Sustain",    0.0f, 1.0f, 0.8f,   nullptr },
        { UPI_OSC_PARAM_RELEASE,  "release",   "Release",    0.0f, 8.0f, 0.25f,  "s" },
        { UPI_OSC_PARAM_GAIN,     "gain",      "Gain",       0.0f, 1.0f, 0.8f,   nullptr },
        { UPI_OSC_PARAM_GLIDE,    "glide",     "Glide",      0.0f, 2.0f, 0.0f,   "s" },
        { UPI_OSC_PARAM_CUTOFF,   "cutoff",    "Brightness", 0.0f, 1.0f, 1.0f,   nullptr },
        { UPI_OSC_PARAM_NOISE,    "noise",     "Air",        0.0f, 1.0f, 0.0f,   nullptr },
    };
    if (index >= UPI_OSC_PARAM_COUNT) { std::memset(out, 0, sizeof(*out)); return; }
    const Row &r = rows[index];
    out->address       = r.addr;
    out->identifier    = r.id;
    out->display_name  = r.name;
    out->min_value     = r.lo;
    out->max_value     = r.hi;
    out->default_value = r.def;
    out->unit          = r.unit;
}

void osc_set_parameter(UPIBackend *self, uint32_t address, float value) {
    auto *b = reinterpret_cast<OscBackend *>(self);
    if (address < UPI_OSC_PARAM_COUNT)
        b->params[address].store(value, std::memory_order_relaxed);
}

float osc_get_parameter(UPIBackend *self, uint32_t address) {
    auto *b = reinterpret_cast<OscBackend *>(self);
    return address < UPI_OSC_PARAM_COUNT ? b->p((int)address) : 0.0f;
}

void osc_render(UPIBackend *self, const UPIControlFrame *cf,
                float *const *out, uint32_t frames) {
    auto *b = reinterpret_cast<OscBackend *>(self);

    // --- reconcile the control frame's voice list with our voice pool ------
    bool seen[kVoiceCount] = {};
    for (uint32_t i = 0; i < cf->voice_count && i < UPI_MAX_VOICES; ++i) {
        const UPIVoiceState &vs = cf->voices[i];
        if (vs.note_id < 0) continue;
        Voice *v = b->findVoice(vs.note_id);
        if (!v) {
            v = b->allocVoice();
            *v = Voice{};
            v->noteId = vs.note_id;
            v->freq   = vs.pitch_hz > 0.0f ? vs.pitch_hz : 440.0f;
            v->env.gateOn();
        }
        v->target   = vs.pitch_hz > 0.0f ? vs.pitch_hz : v->target;
        v->velocity = vs.velocity;
        const bool held = vs.gate != 0;
        if (!held && v->gate) v->env.gateOff();
        v->gate = held;
        for (int k = 0; k < kVoiceCount; ++k) if (&b->voices[k] == v) seen[k] = true;
    }
    // A voice the frame no longer lists: treat as released.
    for (int k = 0; k < kVoiceCount; ++k) {
        Voice &v = b->voices[k];
        if (v.noteId >= 0 && !seen[k]) { v.env.gateOff(); v.gate = false; v.noteId = -1; }
    }

    const float sr       = (float)b->sampleRate;
    const int   waveform = (int)std::lround(clampf(b->p(UPI_OSC_PARAM_WAVEFORM), 0.0f, 3.0f));
    const float atk      = b->p(UPI_OSC_PARAM_ATTACK);
    const float dec      = b->p(UPI_OSC_PARAM_DECAY);
    const float sus      = b->p(UPI_OSC_PARAM_SUSTAIN);
    const float rel      = b->p(UPI_OSC_PARAM_RELEASE);
    const float gain     = b->p(UPI_OSC_PARAM_GAIN);
    const float glide    = b->p(UPI_OSC_PARAM_GLIDE);
    const float cutoffN  = clampf(b->p(UPI_OSC_PARAM_CUTOFF), 0.0f, 1.0f);
    const float noiseAmt = clampf(b->p(UPI_OSC_PARAM_NOISE), 0.0f, 1.0f);

    const float fcMax   = 0.45f * sr;
    const float fc      = 40.0f * std::pow(fcMax / 40.0f, cutoffN);
    const float lpCoeff = 1.0f - std::exp(-kTwoPi * fc / sr);
    const float glideCoeff = glide > 1e-4f ? std::exp(-1.0f / (glide * sr)) : 0.0f;

    for (uint32_t n = 0; n < frames; ++n) {
        float mix = 0.0f;
        for (auto &v : b->voices) {
            if (v.idle()) continue;

            v.freq = glideCoeff > 0.0f
                       ? (v.target + (v.freq - v.target) * glideCoeff)
                       : v.target;

            const float dt = clampf(v.freq / sr, 0.0f, 0.5f);
            float s;
            switch (waveform) {
                case 1: { // triangle via leaky-integrated square
                    float sq = v.phase < 0.5f ? 1.0f : -1.0f;
                    sq += polyBlep(v.phase, dt);
                    sq -= polyBlep(std::fmod(v.phase + 0.5f, 1.0f), dt);
                    v.lpTri += (4.0f * dt) * (sq - v.lpTri);
                    s = clampf(v.lpTri * 3.0f, -1.0f, 1.0f);
                    break;
                }
                case 2: { // saw
                    s = 2.0f * v.phase - 1.0f;
                    s -= polyBlep(v.phase, dt);
                    break;
                }
                case 3: { // square
                    s = v.phase < 0.5f ? 1.0f : -1.0f;
                    s += polyBlep(v.phase, dt);
                    s -= polyBlep(std::fmod(v.phase + 0.5f, 1.0f), dt);
                    break;
                }
                default: // sine
                    s = std::sin(kTwoPi * v.phase);
                    break;
            }

            v.phase += dt;
            if (v.phase >= 1.0f) v.phase -= 1.0f;

            const float e = v.env.process(atk, dec, sus, rel, sr);
            mix += s * e * v.velocity;

            if (v.idle()) v.noteId = -1;
        }

        if (noiseAmt > 0.0f)
            mix = mix * (1.0f - noiseAmt) + b->whiteNoise() * noiseAmt * 0.5f;

        b->lpState += lpCoeff * (mix - b->lpState);
        const float y = b->lpState * gain * 0.35f; // headroom for 8 voices

        for (uint32_t ch = 0; ch < b->channelCount; ++ch) out[ch][n] = y;
    }
}

} // namespace

extern "C" const UPIBackendVTable *upi_oscillator_backend_entry(void) {
    static const UPIBackendVTable vt = {
        UPI_BACKEND_ABI_VERSION,
        osc_create, osc_destroy, osc_prepare, osc_reset,
        osc_get_capabilities, osc_parameter_count, osc_parameter_info,
        osc_set_parameter, osc_get_parameter, osc_render
    };
    return &vt;
}
