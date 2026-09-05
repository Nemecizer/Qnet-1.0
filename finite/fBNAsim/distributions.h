/*
 * distributions.h - Random variate generation for queueing distributions
 *
 * Supported families: exponential, gamma, uniform, constant,
 * weibull, erlang, lognormal, pareto, poisson.
 */

#ifndef DISTRIBUTIONS_H
#define DISTRIBUTIONS_H

#include "rng.h"

typedef enum {
    DIST_EXPONENTIAL,
    DIST_GAMMA,
    DIST_UNIFORM,
    DIST_CONSTANT,
    DIST_WEIBULL,
    DIST_ERLANG,
    DIST_LOGNORMAL,
    DIST_PARETO,
    DIST_POISSON
} DistType;

typedef struct {
    DistType type;
    double params[4]; /* meaning depends on type; see distributions.c */
} Distribution;

/* State for the cached normal generator (Marsaglia polar method). */
typedef struct {
    int    has_spare;
    double spare;
} NormalState;

/* Sample a variate from the given distribution.
 * ns is a per-stream NormalState (needed by gamma and lognormal). */
double dist_sample(const Distribution *dist, RNG *rng, NormalState *ns);

/* Generate a standard normal variate N(0,1). */
double dist_standard_normal(RNG *rng, NormalState *ns);

#endif /* DISTRIBUTIONS_H */
