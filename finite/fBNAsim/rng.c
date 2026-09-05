/*
 * rng.c - xoshiro256** pseudo-random number generator
 *
 * Based on the public-domain implementation by David Blackman and
 * Sebastiano Vigna (2018).  State is seeded by expanding a single
 * 64-bit value through SplitMix64.
 */

#include "rng.h"

/* ------------------------------------------------------------------ */
/* SplitMix64 — used only for seeding                                 */
/* ------------------------------------------------------------------ */
static uint64_t splitmix64(uint64_t *state)
{
    uint64_t z = (*state += 0x9e3779b97f4a7c15ULL);
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
    return z ^ (z >> 31);
}

void rng_seed(RNG *rng, uint64_t seed)
{
    uint64_t sm = seed;
    rng->s[0] = splitmix64(&sm);
    rng->s[1] = splitmix64(&sm);
    rng->s[2] = splitmix64(&sm);
    rng->s[3] = splitmix64(&sm);
    rng->antithetic = 0;
}

/* ------------------------------------------------------------------ */
/* xoshiro256** core                                                  */
/* ------------------------------------------------------------------ */
static inline uint64_t rotl(const uint64_t x, int k)
{
    return (x << k) | (x >> (64 - k));
}

uint64_t rng_next_u64(RNG *rng)
{
    const uint64_t result = rotl(rng->s[1] * 5, 7) * 9;
    const uint64_t t = rng->s[1] << 17;

    rng->s[2] ^= rng->s[0];
    rng->s[3] ^= rng->s[1];
    rng->s[1] ^= rng->s[2];
    rng->s[0] ^= rng->s[3];

    rng->s[2] ^= t;
    rng->s[3] = rotl(rng->s[3], 45);

    return result;
}

double rng_next_double(RNG *rng)
{
    /* Use upper 53 bits for a double in (0, 1).
     * We add 0.5 ULP to avoid returning exactly 0. */
    double u = ((rng_next_u64(rng) >> 11) + 0.5) * (1.0 / 9007199254740992.0);
    return rng->antithetic ? (1.0 - u) : u;
}
