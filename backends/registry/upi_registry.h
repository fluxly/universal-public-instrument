/*
 * upi_registry.h — the compiled-in backend registry.
 *
 * Maps a backend id string (from instrument.json "backend") to the backend's
 * entry point. Every backend the extension ships is listed in upi_registry.c.
 * Adding a NEW backend architecture means editing this file and rebuilding the
 * extension — that is the one thing an Instrument Pack cannot do on its own.
 */
#ifndef UPI_REGISTRY_H
#define UPI_REGISTRY_H

#include "upi_backend.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Returns the vtable for `backend_id`, or NULL if this build has no such
 * backend (the host then tells the user to update UPI). */
const UPIBackendVTable *upi_registry_lookup(const char *backend_id);

/* Enumeration, for diagnostics / a "backends in this build" list. */
uint32_t     upi_registry_count(void);
const char  *upi_registry_id_at(uint32_t index);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* UPI_REGISTRY_H */
