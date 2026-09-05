/*
 * common/rng.h — xoshiro256** pseudo-random number generator
 *
 * Public-domain implementation by David Blackman and Sebastiano Vigna.
 * Period 2^256 - 1, passes BigCrush. Replaces the period-saturating
 * LCGs that several Qnet solvers used historically (BNAsim.md R1).
 *
 * Single-header — define QNET_RNG_IMPLEMENTATION in exactly one .c file
 * before including to emit the function bodies. All other includers get
 * just declarations.
 */

#ifndef QNET_COMMON_RNG_H
#define QNET_COMMON_RNG_H

#include <stdint.h>

typedef struct {
    uint64_t s[4];
    int antithetic;
} RNG;

void     rng_seed       (RNG *rng, uint64_t seed);
uint64_t rng_next_u64   (RNG *rng);
double   rng_next_double(RNG *rng);

#ifdef QNET_RNG_IMPLEMENTATION

static uint64_t qnet_rng_splitmix64(uint64_t *state)
{
    uint64_t z = (*state += 0x9e3779b97f4a7c15ULL);
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
    return z ^ (z >> 31);
}

void rng_seed(RNG *rng, uint64_t seed)
{
    uint64_t sm = seed;
    rng->s[0] = qnet_rng_splitmix64(&sm);
    rng->s[1] = qnet_rng_splitmix64(&sm);
    rng->s[2] = qnet_rng_splitmix64(&sm);
    rng->s[3] = qnet_rng_splitmix64(&sm);
    rng->antithetic = 0;
}

static inline uint64_t qnet_rng_rotl(const uint64_t x, int k)
{
    return (x << k) | (x >> (64 - k));
}

uint64_t rng_next_u64(RNG *rng)
{
    const uint64_t result = qnet_rng_rotl(rng->s[1] * 5, 7) * 9;
    const uint64_t t = rng->s[1] << 17;

    rng->s[2] ^= rng->s[0];
    rng->s[3] ^= rng->s[1];
    rng->s[1] ^= rng->s[2];
    rng->s[0] ^= rng->s[3];

    rng->s[2] ^= t;
    rng->s[3] = qnet_rng_rotl(rng->s[3], 45);

    return result;
}

double rng_next_double(RNG *rng)
{
    /* Top 53 bits → double in (0, 1); 0.5 ULP shift avoids returning 0. */
    double u = ((rng_next_u64(rng) >> 11) + 0.5) * (1.0 / 9007199254740992.0);
    return rng->antithetic ? (1.0 - u) : u;
}

#endif /* QNET_RNG_IMPLEMENTATION */

#endif /* QNET_COMMON_RNG_H */
