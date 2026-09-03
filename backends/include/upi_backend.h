/*
 * upi_backend.h — the C ABI every UPI synthesis backend implements.
 *
 * See docs/upi-app-spec.md "Neural Backend Interface".
 *
 * A backend is CODE, compiled into UPIInstrument.appex. An Instrument Pack is
 * DATA that names a backend id and supplies that backend's resources. The
 * registry (Phase 0: compiled in) maps a backend id string to the single
 * exported entry point below.
 *
 * ABI rules:
 *   - Pure C. No C++ types across the boundary.
 *   - `abi_version` in the capabilities struct must equal UPI_BACKEND_ABI_VERSION.
 *   - Struct layout changes within a major version are ADDITIVE ONLY.
 */
#ifndef UPI_BACKEND_H
#define UPI_BACKEND_H

#include <stdint.h>
#include "upi_control_frame.h"

#ifdef __cplusplus
extern "C" {
#endif

#define UPI_BACKEND_ABI_VERSION 1u

/* ---- capability declaration ------------------------------------------------ */

typedef enum UPIVoiceMode {
    UPI_VOICE_MONO = 0,
    UPI_VOICE_POLY = 1,
    UPI_VOICE_PARA = 2
} UPIVoiceMode;

typedef enum UPIThreadModel {
    /* render() is realtime-safe; the host calls it on the audio thread. */
    UPI_THREAD_AUDIO  = 0,
    /* backend renders on its own thread; host pulls through a ring buffer and
     * honours `latency_frames`. (Not exercised in Phase 0.) */
    UPI_THREAD_RENDER = 1
} UPIThreadModel;

typedef struct UPIBackendCapabilities {
    uint32_t       abi_version;         /* == UPI_BACKEND_ABI_VERSION */
    UPIVoiceMode   voice_mode;
    UPIThreadModel thread_model;
    uint32_t       max_voices;
    int32_t        continuous_identity; /* 1 = can morph identity continuously */
    uint32_t       latency_frames;
    uint32_t       tail_frames;
} UPIBackendCapabilities;

/* ---- parameters ---------------------------------------------------------- */

typedef struct UPIParameterInfo {
    uint32_t    address;        /* stable id used by set_parameter/get_parameter */
    const char *identifier;     /* short machine name, e.g. "attack" */
    const char *display_name;   /* human label, e.g. "Attack" */
    float       min_value;
    float       max_value;
    float       default_value;
    const char *unit;           /* nullable, e.g. "s", "dB" */
} UPIParameterInfo;

/* ---- prepare-time configuration ---------------------------------------- */

/* Resolve a logical resource key from instrument.json ("weights", "patch", …)
 * to an absolute filesystem path. Returns NULL when the key is absent. The
 * returned string is owned by the host and valid until prepare() returns. */
typedef const char *(*UPIResourceResolver)(void *ctx, const char *key);

typedef struct UPIBackendConfig {
    double               sample_rate;
    uint32_t             max_frames;      /* upper bound on `frames` in render() */
    uint32_t             channel_count;   /* output buffers passed to render() */
    UPIResourceResolver  resolve_resource;
    void                *resolver_ctx;
    const char          *instrument_json; /* raw manifest, for backend-specific keys */
} UPIBackendConfig;

/* ---- the backend instance --------------------------------------------- */

typedef struct UPIBackend UPIBackend; /* opaque */

typedef struct UPIBackendVTable {
    uint32_t abi_version; /* == UPI_BACKEND_ABI_VERSION */

    /* lifecycle */
    UPIBackend *(*create)(void);
    void        (*destroy)(UPIBackend *self);
    int32_t     (*prepare)(UPIBackend *self, const UPIBackendConfig *config); /* 0 = ok */
    void        (*reset)(UPIBackend *self);

    /* introspection */
    void        (*get_capabilities)(UPIBackend *self, UPIBackendCapabilities *out);
    uint32_t    (*parameter_count)(UPIBackend *self);
    void        (*parameter_info)(UPIBackend *self, uint32_t index, UPIParameterInfo *out);
    void        (*set_parameter)(UPIBackend *self, uint32_t address, float value);
    float       (*get_parameter)(UPIBackend *self, uint32_t address);

    /* render one block.
     *   control : valid for this block (already version-checked by the host)
     *   out     : planar float buffers, out[ch][frame], `channel_count` of them,
     *             each at least `frames` long. Backend writes, does not read.
     *   Realtime-safe iff capabilities.thread_model == UPI_THREAD_AUDIO. */
    void        (*render)(UPIBackend *self,
                          const UPIControlFrame *control,
                          float *const *out,
                          uint32_t frames);
} UPIBackendVTable;

/* Entry point type. Each backend exports one function of this shape returning a
 * pointer to a static (immortal) vtable. The compiled-in registry keeps a table
 * of { backend id string -> UPIBackendEntry }. */
typedef const UPIBackendVTable *(*UPIBackendEntry)(void);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* UPI_BACKEND_H */
