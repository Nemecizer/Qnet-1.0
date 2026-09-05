/*
 * bnet_memcheck.h — RAM-aware allocation guard, header-only.
 *
 * Each BNET analysis binary (bnet, bna_qna, bna_sbd, bna_fm_gauss,
 * bna_fm_cbc, jackson_sim, fBNAsim, srbm_solver, …) has at least one
 * allocation whose size grows polynomially or combinatorially in the
 * input dimensions (basis polynomials, mesh tensor products, etc.).
 * Without a pre-flight check, oversized inputs cause the OS to thrash
 * in swap or hit a malloc guard page — both of which lock the user's
 * machine.
 *
 * Include this header and call `bnet_memcheck_alloc(bytes, label, hint)`
 * before each large allocation. If the request exceeds the configured
 * budget the binary prints an actionable diagnostic and exits cleanly
 * with status 2 instead of asking the OS for memory it can't deliver.
 *
 * Budget = min(BNET_MAX_BYTES env var, 50% of physical RAM). Defaults
 * are conservative on purpose — running an analysis that consumes more
 * than half of RAM is the point at which other apps start swapping
 * and the system feels frozen even when nothing has actually crashed.
 *
 * Header-only because the binaries live in separate directories with
 * separate Makefiles; pulling them all under a shared object file
 * would mean editing every Makefile. The whole helper is ~80 lines —
 * not worth the build-system change.
 */

#ifndef BNET_MEMCHECK_H
#define BNET_MEMCHECK_H

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#if defined(__APPLE__)
#  include <sys/sysctl.h>
#  include <sys/types.h>
#elif defined(__linux__)
#  include <unistd.h>
#endif

/* Total physical RAM in bytes, or 0 if the platform query failed. */
static inline uint64_t bnet_mem_total_bytes(void) {
#if defined(__APPLE__)
    int64_t bytes = 0;
    size_t  len   = sizeof(bytes);
    int     mib[] = { CTL_HW, HW_MEMSIZE };
    if (sysctl(mib, 2, &bytes, &len, NULL, 0) != 0) return 0;
    return (uint64_t) bytes;
#elif defined(__linux__)
    long pages     = sysconf(_SC_PHYS_PAGES);
    long page_size = sysconf(_SC_PAGE_SIZE);
    if (pages <= 0 || page_size <= 0) return 0;
    return (uint64_t) pages * (uint64_t) page_size;
#else
    return 0;
#endif
}

/* Per-binary memory budget. Defaults to 50% of total RAM; users can
   override at runtime with BNET_MAX_BYTES (decimal bytes) — useful
   on shared workstations where the user wants to cap BNET's footprint
   well below the physical limit. Returns 0 only if neither source is
   available, in which case `bnet_memcheck_alloc` falls back to an
   8 GB hard cap so we never ship without any guardrail at all. */
static inline uint64_t bnet_mem_budget_bytes(void) {
    const char *env = getenv("BNET_MAX_BYTES");
    if (env && *env) {
        long long parsed = atoll(env);
        if (parsed > 0) return (uint64_t) parsed;
    }
    uint64_t total = bnet_mem_total_bytes();
    if (total > 0) return total / 2;
    return (uint64_t) 8 * 1024 * 1024 * 1024;  /* 8 GB fallback */
}

/* Print a one-line GB-formatted size into a static buffer (returned
   pointer is to a thread-local-ish small buffer; safe for two distinct
   calls in the same printf since we use two static slots). */
static inline const char *bnet_mem_human(uint64_t bytes) {
    static char buf[2][64];
    static int  slot = 0;
    char *out = buf[slot ^= 1];
    double gb = (double) bytes / (1024.0 * 1024.0 * 1024.0);
    if (gb >= 1.0) {
        snprintf(out, sizeof(buf[0]), "%.2f GB", gb);
    } else {
        double mb = (double) bytes / (1024.0 * 1024.0);
        snprintf(out, sizeof(buf[0]), "%.1f MB", mb);
    }
    return out;
}

/* Bail out cleanly if `requested_bytes` exceeds the budget. `label`
   names the data structure (e.g. "spectral system matrix"). `hint`
   is a one-line suggestion the user can act on (e.g. "reduce
   polynomial order or dimension"). */
static inline void bnet_memcheck_alloc(uint64_t requested_bytes,
                                       const char *label,
                                       const char *hint) {
    uint64_t budget = bnet_mem_budget_bytes();
    if (requested_bytes <= budget) return;

    uint64_t total = bnet_mem_total_bytes();
    fprintf(stderr,
        "\nERROR: requested allocation exceeds the memory budget.\n"
        "  data structure   : %s\n"
        "  requested        : %s\n"
        "  per-run budget   : %s  (50%% of physical RAM, or BNET_MAX_BYTES)\n",
        label ? label : "(unnamed)",
        bnet_mem_human(requested_bytes),
        bnet_mem_human(budget));
    if (total > 0) {
        fprintf(stderr,
            "  physical RAM     : %s\n", bnet_mem_human(total));
    }
    if (hint && *hint) {
        fprintf(stderr, "  suggestion       : %s\n", hint);
    }
    fprintf(stderr,
        "Set BNET_MAX_BYTES=<bytes> to override (at your own risk of\n"
        "freezing the machine in swap thrash).\n");
    exit(2);
}

#endif /* BNET_MEMCHECK_H */
