// pd_backend.cpp — see pd_backend.h
//
// Realtime rules in render(): no allocation, no locks, no syscalls. All Pd
// setup (open patch, init audio) happens in prepare().

#include "pd_backend.h"

extern "C" {
#include "z_libpd.h"
}

#include <atomic>
#include <cmath>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

namespace {

std::once_flag g_pdInitOnce;

// Silence for the (unused) Pd audio input.
float g_silentIn[4096] = {0};

struct PdBackend {
    t_pdinstance *pd = nullptr;
    void         *patchHandle = nullptr;
    std::string   patchDir, patchName;

    double   sampleRate   = 48000.0;
    uint32_t channelCount = 2;
    int      pdBlock      = 64;

    // output ring buffer: Pd renders in 64-frame ticks, the host asks for N
    std::vector<float> ring;   // interleaved, channelCount wide
    size_t ringHead = 0, ringTail = 0, ringCap = 0;

    std::vector<float> tickOut; // one tick, interleaved (pdBlock * channelCount)

    // last-seen voice-0 state, for change detection
    int32_t lastNoteId = -1;
    float   lastGate = -1.f, lastPitch = -1.f, lastVel = -1.f;

    size_t ringCount() const { return (ringHead + ringCap - ringTail) % ringCap; }

    void ringPush(const float *interleaved, size_t frames) {
        for (size_t f = 0; f < frames; ++f)
            for (uint32_t c = 0; c < channelCount; ++c) {
                ring[ringHead] = interleaved[f * channelCount + c];
                ringHead = (ringHead + 1) % ringCap;
            }
    }
    void ringPop(float *const *out, uint32_t frames) {
        for (uint32_t f = 0; f < frames; ++f)
            for (uint32_t c = 0; c < channelCount; ++c) {
                out[c][f] = ring[ringTail];
                ringTail = (ringTail + 1) % ringCap;
            }
    }
};

// ---- vtable ---------------------------------------------------------------

UPIBackend *pd_create(void) {
    std::call_once(g_pdInitOnce, [] { libpd_init(); });
    auto *b = new (std::nothrow) PdBackend();
    if (!b) return nullptr;
    b->pd = libpd_new_instance();
    return reinterpret_cast<UPIBackend *>(b);
}

void pd_destroy(UPIBackend *self) {
    auto *b = reinterpret_cast<PdBackend *>(self);
    if (!b) return;
    if (b->pd) {
        libpd_set_instance(b->pd);
        if (b->patchHandle) libpd_closefile(b->patchHandle);
        libpd_free_instance(b->pd);
    }
    delete b;
}

int32_t pd_prepare(UPIBackend *self, const UPIBackendConfig *cfg) {
    auto *b = reinterpret_cast<PdBackend *>(self);
    if (!b || !b->pd || !cfg || cfg->sample_rate <= 0.0) return -1;

    b->sampleRate   = cfg->sample_rate;
    b->channelCount = cfg->channel_count ? cfg->channel_count : 2;

    libpd_set_instance(b->pd);
    b->pdBlock = libpd_blocksize();
    if (libpd_init_audio(0, (int)b->channelCount, (int)b->sampleRate) != 0) return 2;

    // (re)open the patch named by the pack's "patch" resource key. Only tear
    // down an open patch once we have a new path to load — a re-prepare without
    // a resolver (e.g. allocateRenderResources) must keep the current patch.
    const char *patchPath = cfg->resolve_resource
        ? cfg->resolve_resource(cfg->resolver_ctx, "patch") : nullptr;
    if (patchPath) {
        if (b->patchHandle) { libpd_closefile(b->patchHandle); b->patchHandle = nullptr; }
        std::string p(patchPath);
        const size_t slash = p.find_last_of('/');
        b->patchDir  = slash == std::string::npos ? "." : p.substr(0, slash);
        b->patchName = slash == std::string::npos ? p   : p.substr(slash + 1);
        b->patchHandle = libpd_openfile(b->patchName.c_str(), b->patchDir.c_str());
        if (!b->patchHandle) return 4;
    } else if (!b->patchHandle) {
        return 3;   // never had a patch and nothing to resolve one from
    }

    // start Pd's DSP
    libpd_start_message(1); libpd_add_float(1.0f); libpd_finish_message("pd", "dsp");

    // size the ring for the worst-case host block plus a tick of slack
    const size_t maxTickFrames = (size_t)b->pdBlock;
    const size_t worst = (size_t)cfg->max_frames + maxTickFrames + 1;
    b->ringCap = worst * b->channelCount;
    b->ring.assign(b->ringCap, 0.0f);
    b->ringHead = b->ringTail = 0;
    b->tickOut.assign((size_t)b->pdBlock * b->channelCount, 0.0f);

    b->lastNoteId = -1; b->lastGate = b->lastPitch = b->lastVel = -1.f;
    return 0;
}

void pd_reset(UPIBackend *self) {
    auto *b = reinterpret_cast<PdBackend *>(self);
    if (!b || !b->pd) return;
    libpd_set_instance(b->pd);
    libpd_float("gate", 0.0f);
    b->ringHead = b->ringTail = 0;
    std::fill(b->ring.begin(), b->ring.end(), 0.0f);
    b->lastGate = -1.f;
}

void pd_get_capabilities(UPIBackend *, UPIBackendCapabilities *out) {
    out->abi_version         = UPI_BACKEND_ABI_VERSION;
    out->voice_mode          = UPI_VOICE_MONO;
    out->thread_model        = UPI_THREAD_AUDIO;
    out->max_voices          = 1;
    out->continuous_identity = 0;
    out->latency_frames      = 0;   // ring stays <= 1 tick behind
    out->tail_frames         = 0;
}

uint32_t pd_parameter_count(UPIBackend *) { return 0; }
void     pd_parameter_info(UPIBackend *, uint32_t, UPIParameterInfo *out) {
    if (out) std::memset(out, 0, sizeof(*out));
}
void  pd_set_parameter(UPIBackend *, uint32_t, float) {}
float pd_get_parameter(UPIBackend *, uint32_t) { return 0.0f; }

void pd_render(UPIBackend *self, const UPIControlFrame *cf,
               float *const *out, uint32_t frames) {
    auto *b = reinterpret_cast<PdBackend *>(self);
    if (!b || !b->pd || !b->patchHandle) {
        for (uint32_t c = 0; c < 1u; ++c)
            std::memset(out[c], 0, sizeof(float) * frames);
        return;
    }
    libpd_set_instance(b->pd);

    // --- control: voice 0 only (monophonic) ---
    float gate = 0.f, pitch = b->lastPitch < 0 ? 261.63f : b->lastPitch, vel = 0.f;
    if (cf->voice_count > 0) {
        const UPIVoiceState &v = cf->voices[0];
        if (v.note_id >= 0) {
            gate  = v.gate ? 1.0f : 0.0f;
            pitch = v.pitch_hz > 0.f ? v.pitch_hz : pitch;
            vel   = v.velocity;
        }
    }
    if (pitch != b->lastPitch) { libpd_float("pitch", pitch); b->lastPitch = pitch; }
    if (vel   != b->lastVel)   { libpd_float("vel",   vel);   b->lastVel = vel; }
    if (gate  != b->lastGate)  { libpd_float("gate",  gate);  b->lastGate = gate; }

    // --- render enough Pd ticks to satisfy `frames` ---
    while (b->ringCount() < (size_t)frames * b->channelCount) {
        libpd_process_float(1, g_silentIn, b->tickOut.data());
        b->ringPush(b->tickOut.data(), (size_t)b->pdBlock);
    }
    b->ringPop(out, frames);
}

} // namespace

extern "C" const UPIBackendVTable *upi_pd_backend_entry(void) {
    static const UPIBackendVTable vt = {
        UPI_BACKEND_ABI_VERSION,
        pd_create, pd_destroy, pd_prepare, pd_reset,
        pd_get_capabilities, pd_parameter_count, pd_parameter_info,
        pd_set_parameter, pd_get_parameter, pd_render
    };
    return &vt;
}
