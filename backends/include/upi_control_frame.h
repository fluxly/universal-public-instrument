/*
 * upi_control_frame.h — the versioned control packet handed to a backend each render block.
 *
 * Contract (see docs/upi-app-spec.md "ControlFrame"):
 *   - Plain C struct, C ABI.
 *   - `version` must equal UPI_CONTROL_FRAME_VERSION.
 *   - Changes within a major version are ADDITIVE ONLY (append fields, never
 *     reorder or resize existing ones). Bump the major on any breaking change.
 *
 * Produced by the Performance Layer (a stub in Phase 0). Consumed by any backend.
 */
#ifndef UPI_CONTROL_FRAME_H
#define UPI_CONTROL_FRAME_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define UPI_CONTROL_FRAME_VERSION 1u

/* Hard caps. Backends may support fewer voices than UPI_MAX_VOICES. */
#define UPI_MAX_VOICES     16u
#define UPI_MACRO_COUNT     8u
#define UPI_IDENTITY_DIMS   8u

/* One sounding (or releasing) voice. MPE per-note expression lives here, not
 * as global channel values, so a polyphonic-expressive backend can read it
 * per voice and a monophonic one can collapse the array. */
typedef struct UPIVoiceState {
    int32_t  note_id;      /* unique id for the life of the note; -1 = slot unused */
    uint8_t  note;         /* base MIDI note number, 0..127 */
    uint8_t  gate;         /* 1 while the key is held, 0 once released */
    uint8_t  _pad[2];
    float    velocity;     /* note-on velocity, 0..1 */
    float    pitch_hz;     /* target frequency incl. tuning + per-note bend */
    float    pitch_bend;   /* per-note bend already resolved to semitones */
    float    pressure;     /* per-note pressure / aftertouch, 0..1 */
    float    slide;        /* per-note timbre (MPE "Y" / CC74), 0..1 */
    float    age_seconds;  /* seconds since note-on */
} UPIVoiceState;

typedef struct UPIControlFrame {
    uint32_t version;            /* == UPI_CONTROL_FRAME_VERSION */
    uint32_t voice_count;        /* number of valid entries in `voices` */

    double   sample_rate;
    double   tempo_bpm;          /* 0 if the host provides no tempo */
    uint64_t host_sample_time;   /* sample position at the start of this block */
    int32_t  transport_playing;  /* 1 if the host transport is running */
    int32_t  _pad;

    float    macros[UPI_MACRO_COUNT];       /* normalized 0..1, order = instrument.json "macros" */
    float    identity[UPI_IDENTITY_DIMS];   /* backend-interpreted identity vector */

    UPIVoiceState voices[UPI_MAX_VOICES];
} UPIControlFrame;

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* UPI_CONTROL_FRAME_H */
