/*
 * upi_kernel.h — the realtime C++ core of UPIInstrument.appex.
 *
 * Sits between the Swift AUAudioUnit and a backend:
 *   - owns the backend instance (via the compiled-in registry),
 *   - is the Phase 0 Performance Layer stub: parses MIDI / MPE into per-voice
 *     state and builds a versioned UPIControlFrame each block,
 *   - calls backend->render on the audio thread.
 *
 * Everything in upi_kernel_render() is realtime-safe. The rest is called from
 * the main/allocate thread.
 */
#ifndef UPI_KERNEL_H
#define UPI_KERNEL_H

#include <AudioToolbox/AudioToolbox.h>
#include <AudioToolbox/AUAudioUnitImplementation.h>
#include "upi_backend.h"
#include "upi_control_frame.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct UPIKernel UPIKernel;

UPIKernel *upi_kernel_create(void);
void       upi_kernel_destroy(UPIKernel *k);

/* Load/replace the backend named by `backend_id` (registry lookup).
 * `instrument_json` is the raw manifest text; `resolver`/`ctx` turn resource
 * keys ("weights", "patch", …) into absolute paths. Not realtime-safe.
 * Returns 0 on success, <0 if the backend id is unknown to this build,
 * >0 if the backend failed to prepare. */
int32_t upi_kernel_set_backend(UPIKernel *k,
                               const char *backend_id,
                               const char *instrument_json,
                               UPIResourceResolver resolver,
                               void *ctx);

int32_t upi_kernel_prepare(UPIKernel *k, double sample_rate,
                           uint32_t max_frames, uint32_t channel_count);
void    upi_kernel_reset(UPIKernel *k);

/* Backend parameter passthrough. */
uint32_t upi_kernel_parameter_count(UPIKernel *k);
void     upi_kernel_parameter_info(UPIKernel *k, uint32_t index, UPIParameterInfo *out);
void     upi_kernel_set_parameter(UPIKernel *k, uint32_t address, float value);
float    upi_kernel_get_parameter(UPIKernel *k, uint32_t address);

/* Extension-owned controls (not backend parameters). */
void upi_kernel_set_mpe_bend_range(UPIKernel *k, float semitones);

/* Macro bus: value published in ControlFrame.macros[index] each block. Index
 * order matches instrument.json "macros". Out-of-range indices are ignored. */
void upi_kernel_set_macro(UPIKernel *k, uint32_t macro_index, float value01);

/* Identity Layer input. Phase 1 is 1-D pass-through: dim 0 carries the single
 * identity-axis position (0..1). Published in ControlFrame.identity[dim]. */
void upi_kernel_set_identity(UPIKernel *k, uint32_t dim, float value);

/* Realtime. Parses `event_list` (may be NULL), updates the control frame,
 * renders into `out`. Events are currently applied at block start (no
 * sample-accurate scheduling yet — Phase 0). */
void upi_kernel_render(UPIKernel *k,
                       const AudioTimeStamp *timestamp,
                       AUAudioFrameCount frame_count,
                       AudioBufferList *out,
                       const AURenderEvent *event_list);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* UPI_KERNEL_H */
