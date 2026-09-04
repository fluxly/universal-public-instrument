// ddsp-render-smoke.cpp — off-device check of the DDSP backend DSP.
//
// Compiles the backend straight into a host binary (no AU, no sandbox) and
// drives it through the C ABI with a synthetic ControlFrame: hold a note,
// render ~1 s at identity 0 (trumpet) and identity 1 (clarinet), assert both
// are non-silent and that trumpet is spectrally brighter than clarinet.
//
//   c++ -std=c++17 -O2 -I backends/include -I backends/DdspBackend \
//       tools/ddsp-render-smoke.cpp backends/DdspBackend/ddsp_backend.cpp \
//       backends/DdspBackend/ddsp_synth.cpp backends/DdspBackend/ddsp_decoder.cpp \
//       -o /tmp/ddsp-render-smoke && /tmp/ddsp-render-smoke
//
// If instrument-packs/hello-ddsp/backend/{trumpet,clarinet}.ddspw exist it
// exercises the trained decoders; otherwise the analytic fallback.

#include "upi_backend.h"
#include "ddsp_backend.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static std::string g_packDir = "instrument-packs/hello-ddsp";
extern "C" const char *ddsp_smoke_resolve(void *, const char *key) {
    static std::string a, b;   // distinct storage per key (resolver contract)
    std::string *slot;
    if (std::strcmp(key, "decoder_a") == 0)      { slot = &a; *slot = g_packDir + "/backend/trumpet.ddspw"; }
    else if (std::strcmp(key, "decoder_b") == 0) { slot = &b; *slot = g_packDir + "/backend/clarinet.ddspw"; }
    else return nullptr;
    FILE *f = std::fopen(slot->c_str(), "rb");
    if (!f) return nullptr;
    std::fclose(f);
    return slot->c_str();
}

static float rms(const std::vector<float>& x) {
    if (x.empty()) return 0.f;
    double s = 0;
    for (float v : x) s += (double)v * v;
    return (float)std::sqrt(s / x.size());
}
// crude brightness proxy: RMS of first difference / RMS of signal
static float tilt(const std::vector<float>& x) {
    if (x.size() < 2) return 0.f;
    std::vector<float> d(x.size() - 1);
    for (size_t i = 1; i < x.size(); ++i) d[i - 1] = x[i] - x[i - 1];
    float r = rms(x);
    return r > 0.f ? rms(d) / r : 0.f;
}

static std::vector<float> renderNote(const UPIBackendVTable* vt, UPIBackend* b,
                                     float identity) {
    vt->reset(b);
    const uint32_t block = 512;
    float L[512], R[512];
    float* out[2] = { L, R };

    UPIControlFrame cf;
    std::memset(&cf, 0, sizeof(cf));
    cf.version     = UPI_CONTROL_FRAME_VERSION;
    cf.sample_rate = 48000.0;
    cf.voice_count = 1;
    cf.voices[0].note_id  = 1;
    cf.voices[0].note     = 57;
    cf.voices[0].gate     = 1;
    cf.voices[0].velocity = 0.9f;
    cf.voices[0].pitch_hz = 220.0f;         // A3
    cf.identity[0] = identity;
    cf.macros[0] = 0.8f;   // expression
    cf.macros[2] = 0.5f;   // brightness
    cf.macros[3] = 0.12f;  // air
    cf.macros[4] = 0.2f;   // attack

    std::vector<float> acc;
    for (int blk = 0; blk < 90; ++blk) {    // ~1 s
        std::memset(L, 0, sizeof(L));
        std::memset(R, 0, sizeof(R));
        vt->render(b, &cf, out, block);
        if (blk > 20)
            for (uint32_t i = 0; i < block; ++i) acc.push_back(L[i]);
    }
    return acc;
}

int main() {
    const UPIBackendVTable* vt = upi_ddsp_backend_entry();
    if (!vt || vt->abi_version != UPI_BACKEND_ABI_VERSION) {
        std::fprintf(stderr, "DDSP RENDER FAIL: bad vtable\n"); return 1;
    }
    UPIBackend* b = vt->create();
    if (!b) { std::fprintf(stderr, "DDSP RENDER FAIL: create\n"); return 1; }

    UPIBackendConfig cfg;
    std::memset(&cfg, 0, sizeof(cfg));
    cfg.sample_rate      = 48000.0;
    cfg.max_frames       = 512;
    cfg.channel_count    = 2;
    cfg.resolve_resource = ddsp_smoke_resolve;
    if (vt->prepare(b, &cfg) != 0) { std::fprintf(stderr, "DDSP RENDER FAIL: prepare\n"); return 1; }

    UPIBackendCapabilities caps;
    vt->get_capabilities(b, &caps);

    auto trumpet  = renderNote(vt, b, 0.0f);
    auto clarinet = renderNote(vt, b, 1.0f);

    const float rt = rms(trumpet), rc = rms(clarinet);
    const float tt = tilt(trumpet), tc = tilt(clarinet);

    // waveform difference, RMS-normalised
    float diffSq = 0.f;
    size_t n = std::min(trumpet.size(), clarinet.size());
    for (size_t i = 0; i < n; ++i) {
        float a = rt > 0 ? trumpet[i] / rt : 0, c = rc > 0 ? clarinet[i] / rc : 0;
        diffSq += (a - c) * (a - c);
    }
    float diff = n ? std::sqrt(diffSq / n) : 0.f;

    std::printf("caps: continuous_identity=%d latency=%u\n",
                caps.continuous_identity, caps.latency_frames);
    std::printf("trumpet rms %.4f tilt %.3f  ·  clarinet rms %.4f tilt %.3f  ·  Δrms %.2f\n",
                rt, tt, rc, tc, diff);

    vt->destroy(b);

    if (rt < 1e-3f) { std::fprintf(stderr, "DDSP RENDER FAIL: silent trumpet\n"); return 1; }
    if (rc < 1e-3f) { std::fprintf(stderr, "DDSP RENDER FAIL: silent clarinet\n"); return 1; }
    if (diff < 0.3f) { std::fprintf(stderr, "DDSP RENDER FAIL: identity did not change timbre\n"); return 1; }
    if (tt <= tc) { std::fprintf(stderr, "DDSP RENDER FAIL: trumpet not brighter than clarinet\n"); return 1; }
    std::printf("DDSP RENDER PASS\n");
    return 0;
}
