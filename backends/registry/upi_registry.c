// upi_registry.c — every backend compiled into this build. See upi_registry.h.

#include "upi_registry.h"
#include <string.h>

#include "oscillator_backend.h"
#include "pd_backend.h"
#include "ddsp_backend.h"
// #include "mrt2_backend.h"   // later

typedef struct RegistryRow {
    const char *id;
    UPIBackendEntry entry;
} RegistryRow;

static const RegistryRow kRows[] = {
    { "com.upi.backend.oscillator", upi_oscillator_backend_entry },
    { "com.upi.backend.libpd",      upi_pd_backend_entry },
    { "com.upi.backend.ddsp",       upi_ddsp_backend_entry },
    // { "com.upi.backend.mrt2-small", upi_mrt2_backend_entry },
};

static const uint32_t kRowCount = (uint32_t)(sizeof(kRows) / sizeof(kRows[0]));

const UPIBackendVTable *upi_registry_lookup(const char *backend_id) {
    if (!backend_id) return NULL;
    for (uint32_t i = 0; i < kRowCount; ++i) {
        if (strcmp(kRows[i].id, backend_id) == 0) {
            const UPIBackendVTable *vt = kRows[i].entry();
            if (vt && vt->abi_version == UPI_BACKEND_ABI_VERSION) return vt;
            return NULL;
        }
    }
    return NULL;
}

uint32_t upi_registry_count(void) { return kRowCount; }

const char *upi_registry_id_at(uint32_t index) {
    return index < kRowCount ? kRows[index].id : NULL;
}
