/*
 * pd_backend.h — Phase 0.5 backend: a Pure Data patch driven by libpd.
 *
 * Proves that a `.pd` patch shipped as Instrument Pack *data* can be a UPI
 * backend, with libpd's 64-sample internal block reconciled to arbitrary host
 * block sizes via an output ring buffer. Multi-instance libpd
 * (third_party/libpd built with PD_MULTI) so several Pd packs can coexist.
 *
 * Backend id (instrument.json): "com.upi.backend.libpd"
 * Required resource key: "patch"  ->  a .pd file inside the pack.
 *
 * ControlFrame -> Pd receivers (voice 0; monophonic for Phase 0.5):
 *   [r pitch]  float, Hz (incl. MPE bend)
 *   [r gate]   float, 1 while held / 0 on release
 *   [r vel]    float, 0..1
 */
#ifndef UPI_PD_BACKEND_H
#define UPI_PD_BACKEND_H

#include "upi_backend.h"

#ifdef __cplusplus
extern "C" {
#endif

const UPIBackendVTable *upi_pd_backend_entry(void);

#ifdef __cplusplus
}
#endif

#endif /* UPI_PD_BACKEND_H */
