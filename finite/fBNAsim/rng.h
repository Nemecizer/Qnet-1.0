/*
 * rng.h - xoshiro256** pseudo-random number generator
 *
 * Based on the public-domain implementation by David Blackman and
 * Sebastiano Vigna. Period: 2^256 - 1. Passes BigCrush.
 */

#ifndef RNG_H
#define RNG_H

#include <stdint.h>

typedef struct {
    uint64_t s[4];
    int antithetic;
} RNG;

/* Seed the generator from a 64-bit value (expanded via SplitMix64). */
void rng_seed(RNG *rng, uint64_t seed);

/* Return a uniform 64-bit unsigned integer. */
uint64_t rng_next_u64(RNG *rng);

/* Return a uniform double in (0, 1). */
double rng_next_double(RNG *rng);

#endif /* RNG_H */
