/*
 * ddsp_fft.h — minimal power-of-two complex FFT + real-signal helpers.
 *
 * Header-only. The transforms do NOT allocate — the caller supplies scratch.
 * Used by the filtered-noise synth (frequency-sampling FIR design + FFT
 * convolution); sizes here are tiny (128 / 512) and run once per 20 ms hop.
 */
#ifndef UPI_DDSP_FFT_H
#define UPI_DDSP_FFT_H

#include <cmath>
#include <cstdint>

namespace upi_ddsp {

struct Cx { float re, im; };

/* In-place iterative radix-2 FFT. `inverse` does the conjugate transform
 * WITHOUT the 1/N scale (caller scales). `n` must be a power of two. */
inline void fft(Cx* a, int n, bool inverse) {
    for (int i = 1, j = 0; i < n; ++i) {
        int bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) { Cx t = a[i]; a[i] = a[j]; a[j] = t; }
    }
    for (int len = 2; len <= n; len <<= 1) {
        const float ang = (inverse ? 2.0f : -2.0f) * 3.14159265358979323846f / (float)len;
        const float wr = std::cos(ang), wi = std::sin(ang);
        for (int i = 0; i < n; i += len) {
            float cr = 1.0f, ci = 0.0f;
            for (int k = 0; k < len / 2; ++k) {
                Cx& x = a[i + k];
                Cx& y = a[i + k + len / 2];
                const float vr = y.re * cr - y.im * ci;
                const float vi = y.re * ci + y.im * cr;
                y.re = x.re - vr; y.im = x.im - vi;
                x.re = x.re + vr; x.im = x.im + vi;
                const float ncr = cr * wr - ci * wi;
                ci = cr * wi + ci * wr;
                cr = ncr;
            }
        }
    }
}

/* Real IFFT from `nBands` non-negative-frequency magnitudes (imag = 0),
 * writing `2*(nBands-1)` real samples to `out`. `scratch` must hold
 * 2*(nBands-1) Cx. */
inline void irfft_from_magnitudes(const float* mags, int nBands,
                                  Cx* scratch, float* out) {
    const int n = 2 * (nBands - 1);
    for (int i = 0; i < n; ++i) scratch[i] = Cx{ 0.0f, 0.0f };
    for (int i = 0; i < nBands; ++i)      scratch[i].re = mags[i];
    for (int i = 1; i < nBands - 1; ++i)  scratch[n - i].re = mags[i];
    fft(scratch, n, /*inverse=*/true);
    const float s = 1.0f / (float)n;
    for (int i = 0; i < n; ++i) out[i] = scratch[i].re * s;
}

/* Linear FFT convolution of x (length lx) with h (length lh), writing `outLen`
 * samples to `out` starting at `outOffset` of the full convolution (used to
 * compensate FIR group delay). `sx` / `sh` are scratch of `nfft` Cx each,
 * where nfft is the smallest power of two >= lx + lh - 1. */
inline void fft_convolve(const float* x, int lx, const float* h, int lh,
                         Cx* sx, Cx* sh, int nfft,
                         float* out, int outLen, int outOffset) {
    for (int i = 0; i < nfft; ++i) { sx[i] = Cx{ 0.0f, 0.0f }; sh[i] = Cx{ 0.0f, 0.0f }; }
    for (int i = 0; i < lx; ++i) sx[i].re = x[i];
    for (int i = 0; i < lh; ++i) sh[i].re = h[i];
    fft(sx, nfft, false);
    fft(sh, nfft, false);
    for (int i = 0; i < nfft; ++i) {
        const float re = sx[i].re * sh[i].re - sx[i].im * sh[i].im;
        const float im = sx[i].re * sh[i].im + sx[i].im * sh[i].re;
        sx[i] = Cx{ re, im };
    }
    fft(sx, nfft, true);
    const float s = 1.0f / (float)nfft;
    for (int i = 0; i < outLen; ++i) {
        const int src = i + outOffset;
        out[i] = (src >= 0 && src < nfft) ? sx[src].re * s : 0.0f;
    }
}

} // namespace upi_ddsp

#endif /* UPI_DDSP_FFT_H */
