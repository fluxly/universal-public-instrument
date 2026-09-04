/*
 * ddsp_reverb.h — a compact stereo reverb for the DDSP backend's output stage.
 *
 * Schroeder/Moorer topology (the "Freeverb" arrangement): 8 damped feedback
 * comb filters in parallel into 4 series allpasses, per channel, with the right
 * channel's delays offset by a fixed stereo spread. Mono in, stereo out.
 *
 * There is no learned reverb in the DDSP-VST models (the .tflite is the decoder
 * only), so this is a plain algorithmic room — driven by one "mix" macro, with
 * room size and damping fixed to a musical default.
 *
 * Realtime-safe: all delay lines are sized in prepare(); process() does no
 * allocation.
 */
#ifndef UPI_DDSP_REVERB_H
#define UPI_DDSP_REVERB_H

#include <vector>

namespace upi_ddsp {

class PlateReverb {
public:
    /// Longest tail the room can produce — for UPIBackendCapabilities.tail_frames.
    static constexpr float kTailSeconds = 3.0f;

    void prepare(double sampleRate);
    void reset();

    /// outL/outR <- dry `in` crossfaded with the wet room by `mix` (0..1):
    /// mix 0 leaves `in` untouched (still duplicated L=R), mix 1 is fully wet.
    void process(const float* in, float* outL, float* outR, int n, float mix);

private:
    struct Comb {
        std::vector<float> buf;
        int   pos  = 0;
        float store = 0.0f;
        float feedback = 0.0f, damp1 = 0.0f, damp2 = 0.0f;
        void  init(int len) { buf.assign(len > 0 ? len : 1, 0.0f); pos = 0; store = 0.0f; }
        void  clear()       { std::fill(buf.begin(), buf.end(), 0.0f); pos = 0; store = 0.0f; }
        inline float process(float x) {
            float y = buf[pos];
            store = y * damp2 + store * damp1;
            buf[pos] = x + store * feedback;
            if (++pos == (int)buf.size()) pos = 0;
            return y;
        }
    };
    struct Allpass {
        std::vector<float> buf;
        int pos = 0;
        void init(int len) { buf.assign(len > 0 ? len : 1, 0.0f); pos = 0; }
        void clear()       { std::fill(buf.begin(), buf.end(), 0.0f); pos = 0; }
        inline float process(float x) {
            const float y = buf[pos];
            buf[pos] = x + y * 0.5f;                 // fixed allpass feedback
            if (++pos == (int)buf.size()) pos = 0;
            return y - x;
        }
    };

    static constexpr int kCombs    = 8;
    static constexpr int kAllpass  = 4;

    Comb    combL_[kCombs],   combR_[kCombs];
    Allpass apL_[kAllpass],   apR_[kAllpass];

    double sr_ = 48000.0;
};

} // namespace upi_ddsp

#endif /* UPI_DDSP_REVERB_H */
