/*
 * oscillator_backend.h — Phase 0 reference backend.
 *
 * A dependency-free, realtime-safe, 8-voice polyphonic PolyBLEP oscillator with
 * a per-voice ADSR, portamento, a one-pole lowpass and a noise blend. No model,
 * no data — it exists to prove the pipeline end to end.
 *
 * Backend id (in instrument.json): "com.upi.backend.oscillator"
 */
#ifndef UPI_OSCILLATOR_BACKEND_H
#define UPI_OSCILLATOR_BACKEND_H

#include "upi_backend.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Registry entry point. Returns a static vtable; never NULL. */
const UPIBackendVTable *upi_oscillator_backend_entry(void);

/* Parameter addresses (also the order returned by parameter_info). */
enum {
    UPI_OSC_PARAM_WAVEFORM = 0, /* 0 sine, 1 triangle, 2 saw, 3 square */
    UPI_OSC_PARAM_ATTACK   = 1, /* seconds */
    UPI_OSC_PARAM_DECAY    = 2, /* seconds */
    UPI_OSC_PARAM_SUSTAIN  = 3, /* 0..1 */
    UPI_OSC_PARAM_RELEASE  = 4, /* seconds */
    UPI_OSC_PARAM_GAIN     = 5, /* 0..1 linear */
    UPI_OSC_PARAM_GLIDE    = 6, /* seconds to target pitch */
    UPI_OSC_PARAM_CUTOFF   = 7, /* 0..1 (maps to 40 Hz .. Nyquist, log) */
    UPI_OSC_PARAM_NOISE    = 8, /* 0..1 white-noise blend */
    UPI_OSC_PARAM_COUNT    = 9
};

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* UPI_OSCILLATOR_BACKEND_H */
