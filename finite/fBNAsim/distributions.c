/*
 * distributions.c - Random variate generation
 *
 * Parameter conventions (stored in dist->params[]):
 *
 *   exponential : params[0] = rate (lambda)
 *   gamma       : params[0] = shape (alpha), params[1] = scale (beta)
 *   uniform     : params[0] = min,           params[1] = max
 *   constant    : params[0] = value
 *   weibull     : params[0] = shape (k),     params[1] = scale (lambda)
 *   erlang      : params[0] = k (integer),   params[1] = rate
 *   lognormal   : params[0] = mu,            params[1] = sigma
 *   pareto      : params[0] = shape (alpha), params[1] = scale (x_m)
 *   poisson     : params[0] = lambda (mean)
 */

#include "distributions.h"
#include <math.h>

/* ------------------------------------------------------------------ */
/* Standard normal via Marsaglia polar method                         */
/* ------------------------------------------------------------------ */
double dist_standard_normal(RNG *rng, NormalState *ns)
{
    if (ns->has_spare) {
        ns->has_spare = 0;
        return ns->spare;
    }

    double u, v, s;
    do {
        u = 2.0 * rng_next_double(rng) - 1.0;
        v = 2.0 * rng_next_double(rng) - 1.0;
        s = u * u + v * v;
    } while (s >= 1.0 || s == 0.0);

    double f = sqrt(-2.0 * log(s) / s);
    ns->spare     = v * f;
    ns->has_spare = 1;
    return u * f;
}

/* ------------------------------------------------------------------ */
/* Gamma variate — Marsaglia & Tsang (2000)                           */
/* ------------------------------------------------------------------ */
static double sample_gamma(double alpha, double beta, RNG *rng, NormalState *ns)
{
    /* For alpha < 1 use the Ahrens-Dieter boost:
     * Gamma(alpha) = Gamma(alpha+1) * U^(1/alpha) */
    if (alpha < 1.0) {
        double u = rng_next_double(rng);
        return sample_gamma(alpha + 1.0, beta, rng, ns) * pow(u, 1.0 / alpha);
    }

    double d = alpha - 1.0 / 3.0;
    double c = 1.0 / sqrt(9.0 * d);

    for (;;) {
        double x, v;
        do {
            x = dist_standard_normal(rng, ns);
            v = 1.0 + c * x;
        } while (v <= 0.0);

        v = v * v * v;
        double u = rng_next_double(rng);

        /* Squeeze test */
        if (u < 1.0 - 0.0331 * (x * x) * (x * x))
            return d * v * beta;

        if (log(u) < 0.5 * x * x + d * (1.0 - v + log(v)))
            return d * v * beta;
    }
}

/* ------------------------------------------------------------------ */
/* Public sampler                                                     */
/* ------------------------------------------------------------------ */
double dist_sample(const Distribution *dist, RNG *rng, NormalState *ns)
{
    switch (dist->type) {

    case DIST_EXPONENTIAL: {
        double rate = dist->params[0];
        return -log(rng_next_double(rng)) / rate;
    }

    case DIST_GAMMA:
        return sample_gamma(dist->params[0], dist->params[1], rng, ns);

    case DIST_UNIFORM: {
        double lo = dist->params[0];
        double hi = dist->params[1];
        return lo + (hi - lo) * rng_next_double(rng);
    }

    case DIST_CONSTANT:
        return dist->params[0];

    case DIST_WEIBULL: {
        double k      = dist->params[0];
        double lambda  = dist->params[1];
        return lambda * pow(-log(rng_next_double(rng)), 1.0 / k);
    }

    case DIST_ERLANG: {
        int    k    = (int)dist->params[0];
        double rate = dist->params[1];
        if (k > 20) {
            /* For large k, use the gamma sampler for efficiency. */
            return sample_gamma((double)k, 1.0 / rate, rng, ns);
        }
        double sum = 0.0;
        for (int i = 0; i < k; i++)
            sum += -log(rng_next_double(rng)) / rate;
        return sum;
    }

    case DIST_LOGNORMAL: {
        double mu    = dist->params[0];
        double sigma = dist->params[1];
        double z     = dist_standard_normal(rng, ns);
        return exp(mu + sigma * z);
    }

    case DIST_PARETO: {
        double alpha = dist->params[0];
        double xm    = dist->params[1];
        return xm / pow(rng_next_double(rng), 1.0 / alpha);
    }

    case DIST_POISSON: {
        /* Qnet semantics: "poisson lambda=L" denotes a Poisson PROCESS
         * with rate lambda — i.e. inter-arrival times are Exp(lambda)
         * with mean 1/lambda. The simulator uses dist_sample as an
         * inter-arrival generator, so this case must return an
         * exponential sample, NOT a Poisson count. (The previous
         * implementation returned a Poisson(lambda) integer count and
         * used it as a delay, which inverted the rate — every Poisson
         * source generated arrivals at ~1/lambda per unit time.)
         */
        double lambda = dist->params[0];
        if (lambda <= 0.0) return 0.0;
        double u = rng_next_double(rng);
        if (u <= 0.0) u = 1e-300;   /* avoid log(0) */
        return -log(u) / lambda;
    }

    }

    /* Should not reach here. */
    return 1.0;
}
