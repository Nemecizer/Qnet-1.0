#include "srbm_mem.h"
#include "../../../common/bnet_memcheck.h"
#include <stdio.h>
#include <stdlib.h>

/* Pre-flight every allocation through bnet_memcheck_alloc — exits with
 * status 2 (and a human-readable diagnostic) if the request would push
 * past 50% of physical RAM (or BNET_MAX_BYTES). Cheaper than letting the
 * OS thrash in swap when the user fat-fingers a polynomial degree. */

void *srbm_malloc(size_t size)
{
    bnet_memcheck_alloc((uint64_t)size, "srbm_malloc",
                        "reduce polynomial degree, grid resolution, or dimension");
    void *p = malloc(size);
    if (!p && size > 0) {
        fprintf(stderr, "srbm: malloc failed for %zu bytes\n", size);
        exit(EXIT_FAILURE);
    }
    return p;
}

void *srbm_calloc(size_t count, size_t size)
{
    bnet_memcheck_alloc((uint64_t)count * (uint64_t)size, "srbm_calloc",
                        "reduce polynomial degree, grid resolution, or dimension");
    void *p = calloc(count, size);
    if (!p && count > 0 && size > 0) {
        fprintf(stderr, "srbm: calloc failed for %zu * %zu bytes\n", count, size);
        exit(EXIT_FAILURE);
    }
    return p;
}

void *srbm_realloc(void *ptr, size_t size)
{
    bnet_memcheck_alloc((uint64_t)size, "srbm_realloc",
                        "reduce polynomial degree, grid resolution, or dimension");
    void *p = realloc(ptr, size);
    if (!p && size > 0) {
        fprintf(stderr, "srbm: realloc failed for %zu bytes\n", size);
        exit(EXIT_FAILURE);
    }
    return p;
}

void srbm_free(void *ptr)
{
    free(ptr);
}
