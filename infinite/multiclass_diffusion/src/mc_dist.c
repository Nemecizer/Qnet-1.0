/* mc_dist.c — means and SCVs for the distributions emitted by the GUI. */

#include "mc_srbm.h"
#include <math.h>
#include <stdio.h>

double mc_dist_mean(const MCDist *d)
{
    switch (d->kind) {
    case DIST_EXPONENTIAL:   return 1.0 / d->p0;
    case DIST_ERLANG:        return d->p0 / d->p1;                 /* k/rate */
    case DIST_GAMMA:         return d->p0 * d->p1;                 /* shape·scale */
    case DIST_CONSTANT:      return d->p0;
    case DIST_UNIFORM:       return 0.5 * (d->p0 + d->p1);
    case DIST_WEIBULL: {
        /* E = scale · Γ(1 + 1/shape) */
        return d->p1 * tgamma(1.0 + 1.0 / d->p0);
    }
    case DIST_LOGNORMAL:     return exp(d->p0 + 0.5 * d->p1 * d->p1);
    case DIST_PARETO: {
        /* shape > 1:  E = scale · shape / (shape - 1) */
        if (d->p0 <= 1.0) return 1e300;
        return d->p1 * d->p0 / (d->p0 - 1.0);
    }
    case DIST_POISSON:       return 1.0 / d->p0;   /* treating λ as IAT rate */
    default:                 return 1.0;
    }
}

double mc_dist_scv(const MCDist *d)
{
    switch (d->kind) {
    case DIST_EXPONENTIAL:   return 1.0;
    case DIST_ERLANG:        return 1.0 / d->p0;                   /* 1/k */
    case DIST_GAMMA:         return 1.0 / d->p0;                   /* 1/shape */
    case DIST_CONSTANT:      return 0.0;
    case DIST_UNIFORM: {
        double a = d->p0, b = d->p1;
        double mean = 0.5 * (a + b);
        double var  = (b - a) * (b - a) / 12.0;
        return var / (mean * mean);
    }
    case DIST_WEIBULL: {
        double k = d->p0;
        double g1 = tgamma(1.0 + 1.0 / k);
        double g2 = tgamma(1.0 + 2.0 / k);
        return (g2 - g1 * g1) / (g1 * g1);
    }
    case DIST_LOGNORMAL: {
        double sigma2 = d->p1 * d->p1;
        return exp(sigma2) - 1.0;
    }
    case DIST_PARETO: {
        double a = d->p0;
        if (a <= 2.0) return 1e300;
        /* Type-I Pareto: Var / E[X]^2 = 1 / (a (a - 2)). */
        return 1.0 / (a * (a - 2.0));
    }
    case DIST_POISSON:       return 1.0;
    default:                 return 1.0;
    }
}
