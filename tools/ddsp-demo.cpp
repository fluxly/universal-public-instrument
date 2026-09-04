// ddsp-demo.cpp — render a listenable clip from the DDSP backend, off-device.
//
//   c++ -std=c++17 -O2 -I backends/include -I backends/DdspBackend \
//       tools/ddsp-demo.cpp backends/DdspBackend/ddsp_backend.cpp \
//       backends/DdspBackend/ddsp_synth.cpp -o /tmp/ddsp-demo
//   /tmp/ddsp-demo out.wav
//
// Plays a short phrase (a few held notes) while sweeping the identity axis
// Trumpet -> Clarinet, and writes a 48 kHz stereo float WAV.

#include "upi_backend.h"
#include "ddsp_backend.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

// Point at the trained decoders if present (else the backend falls back to
// the analytic model).
extern "C" const char *demo_resolve(void *, const char *key) {
    static std::string a = "instrument-packs/hello-ddsp/backend/trumpet.ddspw";
    static std::string b = "instrument-packs/hello-ddsp/backend/clarinet.ddspw";
    std::string *s = std::strcmp(key, "decoder_a") == 0 ? &a
                   : std::strcmp(key, "decoder_b") == 0 ? &b : nullptr;
    if (!s) return nullptr;
    FILE *f = std::fopen(s->c_str(), "rb");
    if (!f) return nullptr;
    std::fclose(f);
    return s->c_str();
}

static bool write_wav(const char* path, const std::vector<float>& inter, int sr, int ch) {
    uint32_t nf = (uint32_t)inter.size() / ch;
    uint16_t bits = 32, block = ch * 4;
    uint32_t byteRate = sr * block, dataSize = nf * block, chunk = 36 + dataSize;
    std::ofstream f(path, std::ios::binary);
    if (!f) return false;
    uint16_t fmt = 3, nc = (uint16_t)ch; uint32_t s = (uint32_t)sr, sc1 = 16;
    f.write("RIFF", 4); f.write((char*)&chunk, 4); f.write("WAVE", 4);
    f.write("fmt ", 4); f.write((char*)&sc1, 4);
    f.write((char*)&fmt, 2); f.write((char*)&nc, 2); f.write((char*)&s, 4);
    f.write((char*)&byteRate, 4); f.write((char*)&block, 2); f.write((char*)&bits, 2);
    f.write("data", 4); f.write((char*)&dataSize, 4);
    f.write((char*)inter.data(), inter.size() * 4);
    return f.good();
}

int main(int argc, char** argv) {
    const char* out = argc > 1 ? argv[1] : "ddsp-demo.wav";
    const double SR = 48000.0;

    const UPIBackendVTable* vt = upi_ddsp_backend_entry();
    UPIBackend* b = vt->create();
    UPIBackendConfig cfg; std::memset(&cfg, 0, sizeof(cfg));
    cfg.sample_rate = SR; cfg.max_frames = 512; cfg.channel_count = 2;
    cfg.resolve_resource = demo_resolve;
    vt->prepare(b, &cfg);

    const uint32_t block = 512;
    float L[512], R[512]; float* o[2] = { L, R };

    UPIControlFrame cf; std::memset(&cf, 0, sizeof(cf));
    cf.version = UPI_CONTROL_FRAME_VERSION;
    cf.sample_rate = SR;
    cf.macros[0] = 0.85f;  // expression
    cf.macros[2] = 0.5f;   // brightness
    cf.macros[3] = 0.12f;  // air
    cf.macros[4] = 0.15f;  // attack

    // a little phrase: E3 G3 C4 E4, ~1.6 s each, last one held long
    const int   notes[]   = { 52, 55, 60, 64 };
    const float durs[]    = { 1.4f, 1.4f, 1.4f, 3.4f };
    const int   nNotes    = 4;

    std::vector<float> inter;
    double t = 0.0;
    double totalDur = 0; for (float d : durs) totalDur += d;

    for (int ni = 0; ni < nNotes; ++ni) {
        const double hz = 440.0 * std::pow(2.0, (notes[ni] - 69) / 12.0);
        const int nBlocks = (int)(durs[ni] * SR / block);
        for (int blk = 0; blk < nBlocks; ++blk) {
            const bool releasing = blk > nBlocks - (int)(0.25 * SR / block);
            cf.voice_count = 1;
            cf.voices[0].note_id  = ni + 1;
            cf.voices[0].note     = (uint8_t)notes[ni];
            cf.voices[0].gate     = releasing ? 0 : 1;
            cf.voices[0].velocity = 0.85f;
            cf.voices[0].pitch_hz = (float)hz;
            cf.identity[0] = (float)(t / totalDur);           // 0 -> 1 across the phrase

            std::memset(L, 0, sizeof(L)); std::memset(R, 0, sizeof(R));
            vt->render(b, &cf, o, block);
            for (uint32_t i = 0; i < block; ++i) { inter.push_back(L[i]); inter.push_back(R[i]); }
            t += (double)block / SR;
        }
    }
    vt->destroy(b);

    if (!write_wav(out, inter, (int)SR, 2)) { std::fprintf(stderr, "write failed\n"); return 1; }
    std::printf("wrote %s (%.1fs, identity swept Trumpet->Clarinet)\n",
                out, inter.size() / 2.0 / SR);
    return 0;
}
