/*
 * ddsp_backend.h — Phase 1 backend: DDSP-style additive + filtered-noise synth.
 *
 * The synthesis core (harmonic bank + frequency-sampled noise) is ported from
 * magenta/ddsp-vst (Apache-2.0). What DDSP-VST gets from a trained GRU per
 * 20 ms hop — an overall amplitude, a 60-wide harmonic distribution and 65
 * noise-band magnitudes — this backend currently gets from a hand-authored
 * "trumpet" and "clarinet" spectral model, crossfaded by the identity axis.
 * Swapping that analytic model for the real DDSP decoder (`Trumpet.tflite` /
 * `Clarinet.tflite`) is the next step and does not touch the synth.
 *
 * Backend id (instrument.json): "com.upi.backend.ddsp"
 * Resource keys: none yet (analytic model). Later: "decoder_a", "decoder_b".
 *
 * ControlFrame -> synth (voice 0; monophonic):
 *   voices[0].pitch_hz / gate / velocity
 *   identity[0]   0 = trumpet ... 1 = clarinet
 *   macros[0] expression   macros[2] brightness   macros[3] air   macros[4] attack
 */
#ifndef UPI_DDSP_BACKEND_H
#define UPI_DDSP_BACKEND_H

#include "upi_backend.h"

#ifdef __cplusplus
extern "C" {
#endif

const UPIBackendVTable *upi_ddsp_backend_entry(void);

#ifdef __cplusplus
}
#endif

#endif /* UPI_DDSP_BACKEND_H */
