// ddsp-decoder-smoke.cpp — validate the hand-rolled DDSP decoder against the
// TFLite reference produced by tools/ddsp-convert.py.
//
//   c++ -std=c++17 -O2 -I backends/DdspBackend tools/ddsp-decoder-smoke.cpp \
//       backends/DdspBackend/ddsp_decoder.cpp -o /tmp/ddsp-decoder-smoke
//   /tmp/ddsp-decoder-smoke instrument-packs/hello-ddsp/backend/trumpet
//
// Expects <base>.ddspw and <base>.ref next to each other.

#include "ddsp_decoder.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <vector>

using upi_ddsp::DdspDecoder;

static std::vector<char> slurp(const char *path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) { std::fprintf(stderr, "cannot open %s\n", path); std::exit(1); }
    return std::vector<char>((std::istreambuf_iterator<char>(f)),
                             std::istreambuf_iterator<char>());
}

int main(int argc, char **argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: %s <base>\n", argv[0]); return 1; }
    std::string base = argv[1];

    auto blob = slurp((base + ".ddspw").c_str());
    auto ref  = slurp((base + ".ref").c_str());

    DdspDecoder dec;
    if (!dec.load(blob.data(), blob.size())) {
        std::fprintf(stderr, "DECODER FAIL: bad .ddspw (magic/size)\n"); return 1;
    }

    if (ref.size() < 12 || std::memcmp(ref.data(), "DREF1\0\0\0", 8) != 0) {
        std::fprintf(stderr, "DECODER FAIL: bad .ref\n"); return 1;
    }
    uint32_t n; std::memcpy(&n, ref.data() + 8, 4);
    const char *p = ref.data() + 12;

    float maxAmp = 0, maxHarm = 0, maxNoiseRel = 0;
    for (uint32_t k = 0; k < n; ++k) {
        float f0s, pws, refAmp;
        std::memcpy(&f0s, p, 4);  std::memcpy(&pws, p + 4, 4);  std::memcpy(&refAmp, p + 8, 4);
        const float *refHarm  = reinterpret_cast<const float *>(p + 12);
        const float *refNoise = refHarm + 60;
        p += 12 + (60 + 65) * 4;

        const float midi = f0s * 127.0f;
        const float f0Hz = 440.0f * std::pow(2.0f, (midi - 69.0f) / 12.0f);

        float amp, harm[60], noise[65];
        dec.step(f0s, pws, f0Hz, amp, harm, noise);

        maxAmp = std::max(maxAmp, std::fabs(amp - refAmp));
        for (int i = 0; i < 60; ++i) maxHarm = std::max(maxHarm, std::fabs(harm[i] - refHarm[i]));
        for (int i = 0; i < 65; ++i) {
            const float denom = std::max(1e-6f, std::fabs(refNoise[i]));
            maxNoiseRel = std::max(maxNoiseRel, std::fabs(noise[i] - refNoise[i]) / denom);
        }
    }

    std::printf("%s: %u hops  ·  max|Δamp|=%.2e  max|Δharm|=%.2e  max noise rel err=%.2e\n",
                base.c_str(), n, maxAmp, maxHarm, maxNoiseRel);

    // hand-rolled float vs XNNPACK-fused tflite: a few 1e-3 is fine.
    if (maxAmp > 5e-3f || maxHarm > 5e-3f || maxNoiseRel > 0.05f) {
        std::fprintf(stderr, "DECODER FAIL: exceeds tolerance\n"); return 1;
    }
    std::printf("DECODER PASS\n");
    return 0;
}
