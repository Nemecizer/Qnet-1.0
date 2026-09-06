/*
 * bnet_pyrandom.h — CPython's `random.Random` stream, in C. Header-only.
 *
 * Why bit-compatibility and not just "a good RNG": BNArmc now ships a C engine
 * beside its Python one and the user picks between them in Settings. If the
 * two engines drew from different streams, switching engines would change
 * every number on screen, and "which one is right?" would have no answer — the
 * comparison would be between two samples, not two implementations. Drawing
 * the SAME stream makes the choice what it should be, a choice of speed: the
 * two engines produce byte-identical output, and any divergence is a bug in
 * one of them that a test can catch.
 *
 * This is MT19937 exactly as CPython uses it:
 *   - `random.Random(n)` seeds with init_by_array over the 32-bit little-endian
 *     words of abs(n) (CPython Modules/_randommodule.c random_seed).
 *   - `random.random()` is genrand_res53: two draws, 27 + 26 bits, scaled by
 *     2**-53 (init_genrand/genrand_uint32 are the reference Matsumoto/Nishimura
 *     implementation).
 *
 * `common/tests/test_pyrandom.c` compares the first draws of several seeds
 * against values printed by the interpreter this project runs, so a CPython
 * change that moved the stream would fail the build rather than silently
 * desynchronise the two engines.
 */

#ifndef BNET_PYRANDOM_H
#define BNET_PYRANDOM_H

#include <stdint.h>
#include <string.h>

#define BNET_MT_N 624
#define BNET_MT_M 397
#define BNET_MT_MATRIX_A   0x9908b0dfUL
#define BNET_MT_UPPER_MASK 0x80000000UL
#define BNET_MT_LOWER_MASK 0x7fffffffUL

typedef struct {
    uint32_t mt[BNET_MT_N];
    int      index;
} bnet_pyrandom;

static inline void bnet_pyrandom_init_genrand(bnet_pyrandom *r, uint32_t s)
{
    int i;
    r->mt[0] = s;
    for (i = 1; i < BNET_MT_N; i++) {
        r->mt[i] = (uint32_t)(1812433253UL * (r->mt[i - 1] ^ (r->mt[i - 1] >> 30)) + (uint32_t)i);
    }
    r->index = BNET_MT_N;
}

static inline void bnet_pyrandom_init_by_array(bnet_pyrandom *r,
                                               const uint32_t *key, size_t key_length)
{
    size_t i = 1, j = 0, k;
    bnet_pyrandom_init_genrand(r, 19650218UL);
    k = (BNET_MT_N > key_length) ? (size_t)BNET_MT_N : key_length;
    for (; k; k--) {
        r->mt[i] = (uint32_t)((r->mt[i] ^ ((r->mt[i - 1] ^ (r->mt[i - 1] >> 30)) * 1664525UL))
                              + key[j] + (uint32_t)j);
        i++; j++;
        if (i >= BNET_MT_N) { r->mt[0] = r->mt[BNET_MT_N - 1]; i = 1; }
        if (j >= key_length) j = 0;
    }
    for (k = BNET_MT_N - 1; k; k--) {
        r->mt[i] = (uint32_t)((r->mt[i] ^ ((r->mt[i - 1] ^ (r->mt[i - 1] >> 30)) * 1566083941UL))
                              - (uint32_t)i);
        i++;
        if (i >= BNET_MT_N) { r->mt[0] = r->mt[BNET_MT_N - 1]; i = 1; }
    }
    r->mt[0] = 0x80000000UL;
    r->index = BNET_MT_N;
}

/* `random.Random(seed)` for a non-negative integer seed. CPython takes the
 * absolute value and feeds its 32-bit little-endian words to init_by_array;
 * a seed of 0 is the one-word key {0}, not the empty key. */
static inline void bnet_pyrandom_seed_u64(bnet_pyrandom *r, uint64_t seed)
{
    uint32_t key[2];
    size_t length;
    key[0] = (uint32_t)(seed & 0xffffffffUL);
    key[1] = (uint32_t)(seed >> 32);
    length = key[1] ? 2u : 1u;
    bnet_pyrandom_init_by_array(r, key, length);
}

static inline uint32_t bnet_pyrandom_uint32(bnet_pyrandom *r)
{
    uint32_t y;
    static const uint32_t mag01[2] = { 0x0UL, BNET_MT_MATRIX_A };
    if (r->index >= BNET_MT_N) {
        int kk;
        for (kk = 0; kk < BNET_MT_N - BNET_MT_M; kk++) {
            y = (r->mt[kk] & BNET_MT_UPPER_MASK) | (r->mt[kk + 1] & BNET_MT_LOWER_MASK);
            r->mt[kk] = r->mt[kk + BNET_MT_M] ^ (y >> 1) ^ mag01[y & 0x1UL];
        }
        for (; kk < BNET_MT_N - 1; kk++) {
            y = (r->mt[kk] & BNET_MT_UPPER_MASK) | (r->mt[kk + 1] & BNET_MT_LOWER_MASK);
            r->mt[kk] = r->mt[kk + (BNET_MT_M - BNET_MT_N)] ^ (y >> 1) ^ mag01[y & 0x1UL];
        }
        y = (r->mt[BNET_MT_N - 1] & BNET_MT_UPPER_MASK) | (r->mt[0] & BNET_MT_LOWER_MASK);
        r->mt[BNET_MT_N - 1] = r->mt[BNET_MT_M - 1] ^ (y >> 1) ^ mag01[y & 0x1UL];
        r->index = 0;
    }
    y = r->mt[r->index++];
    y ^= (y >> 11);
    y ^= (y << 7)  & 0x9d2c5680UL;
    y ^= (y << 15) & 0xefc60000UL;
    y ^= (y >> 18);
    return y;
}

/* genrand_res53 — exactly what `random.random()` returns. */
static inline double bnet_pyrandom_double(bnet_pyrandom *r)
{
    uint32_t a = bnet_pyrandom_uint32(r) >> 5;
    uint32_t b = bnet_pyrandom_uint32(r) >> 6;
    return (a * 67108864.0 + b) * (1.0 / 9007199254740992.0);
}

/* SplitMix64, as regenerative_mc.py's `derive_seed` uses it to turn one
 * (base_seed, stream, component) triple into a component seed. */
static inline uint64_t bnet_splitmix64(uint64_t value)
{
    value += 0x9E3779B97F4A7C15ULL;
    value = (value ^ (value >> 30)) * 0xBF58476D1CE4E5B9ULL;
    value = (value ^ (value >> 27)) * 0x94D049BB133111EBULL;
    return value ^ (value >> 31);
}

static inline uint64_t bnet_derive_seed(uint64_t base_seed, uint64_t stream, uint64_t component)
{
    return bnet_splitmix64(base_seed + 0x9E3779B97F4A7C15ULL * (stream + 1u) + component);
}

#endif /* BNET_PYRANDOM_H */
