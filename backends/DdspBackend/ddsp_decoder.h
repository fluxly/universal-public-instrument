/*
 * ddsp_decoder.h — the DDSP `RnnFcDecoder` forward pass, hand-rolled.
 *
 * Replaces the analytic control model. Reads a `.ddspw` weight blob converted
 * from a DDSP-VST `.tflite` (tools/ddsp-convert.py) and, per 50 Hz hop, maps
 * (f0_scaled, loudness) -> (amplitude, 60 harmonic amplitudes, 65 noise bands)
 * that feed the same additive + filtered-noise synth.
 *
 * Architecture (verified against Trumpet/Clarinet.tflite, DDSP-VST v3.4.3):
 *   fc_pw : dense(1->256) + LayerNorm(eps 1e-3) + LeakyReLU(0.2)     [loudness]
 *   fc_f0 : dense(1->256) + LayerNorm + LeakyReLU(0.2)               [pitch]
 *   GRU(512, reset_after=True, gate order [z,r,h]) over concat(fc_pw, fc_f0)
 *   fc_out: dense(1024->256) + LayerNorm + LeakyReLU(0.2) over concat(fc_pw, fc_f0, gru_out)
 *   dense(256->126) -> split [1,60,65] -> exp_sigmoid (noise: x-5 first)
 *   harmonics: Nyquist-mask (f0*n >= 8 kHz) + renormalise to sum 1
 *
 * No runtime dependencies. ~2M float weights (~7.5 MB) per model.
 */
#ifndef UPI_DDSP_DECODER_H
#define UPI_DDSP_DECODER_H

#include <cstddef>
#include <vector>

namespace upi_ddsp {

class DdspDecoder {
public:
    static constexpr int kHarmonics  = 60;
    static constexpr int kNoiseBands = 65;
    static constexpr int kGru        = 512;

    /// Load a `.ddspw` blob (copies it). Returns false on bad magic / size.
    bool load(const void *data, std::size_t bytes);
    bool loaded() const { return loaded_; }

    /// Zero the recurrent state.
    void reset();

    /// One hop. `f0Scaled` = midiNote/127, `pwScaled` = loudness (0..1),
    /// `f0Hz` for the Nyquist harmonic mask. Outputs already exp_sigmoid'd;
    /// `harm` is normalised to sum 1.
    void step(float f0Scaled, float pwScaled, float f0Hz,
              float &amp, float *harm /*[60]*/, float *noise /*[65]*/);

private:
    bool loaded_ = false;
    std::vector<float> buf_;

    const float *fc_pw_W = nullptr, *fc_pw_b = nullptr, *ln_pw_g = nullptr, *ln_pw_b = nullptr;
    const float *fc_f0_W = nullptr, *fc_f0_b = nullptr, *ln_f0_g = nullptr, *ln_f0_b = nullptr;
    const float *gru_Wx = nullptr, *gru_bx = nullptr, *gru_Wh = nullptr, *gru_bh = nullptr;
    const float *fc_out_W = nullptr, *fc_out_b = nullptr, *ln_out_g = nullptr, *ln_out_b = nullptr;
    const float *dense_W = nullptr, *dense_b = nullptr;

    float state_[kGru] = {};
};

} // namespace upi_ddsp

#endif /* UPI_DDSP_DECODER_H */
