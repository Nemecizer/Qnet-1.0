/*
 * qmc_lattice_rules.c - Lattice rule integration methods
 *
 * Part of the QMC integration library.
 *
 * Implements three quasi-Monte Carlo lattice rule variants:
 *   1. Standard lattice rule
 *   2. Tent-transformed (baker's transformation) lattice rule
 *   3. Symmetrized lattice rule
 *
 * The 10-dimensional generating vector is from Hickernell, Kritzer, Kuo,
 * Nuyens (Numerical Algorithms, 59(2):161-183, 2012) for smoothness 3.
 */
#include "qmc.h"

#include <stdlib.h>
#include <math.h>
#include <string.h>
#include <time.h>

/* ------------------------------------------------------------------------ */
/* Built-in generating vector                                               */
/* ------------------------------------------------------------------------ */

const unsigned int qmc_z10[10] = {
    1, 364981, 245389, 97823, 488939, 62609, 400749, 385317, 21281, 223487
};

/* ------------------------------------------------------------------------ */
/* Internal helpers                                                         */
/* ------------------------------------------------------------------------ */

/* Wall-clock time in microseconds (POSIX) */
static long long get_usecs(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000000LL + (long long)ts.tv_nsec / 1000LL;
}

/* Compute lattice point: x[j] = ((z[j] * k) mod n) / n */
static void calc_lattice_point(size_t s, const unsigned int *z,
                                uint64_t n, double nrecip,
                                uint64_t k, double *x)
{
    size_t j;
    for (j = 0; j < s; j++) {
        x[j] = (double)(((uint64_t)z[j] * k) % n) * nrecip;
    }
}

/*
 * Count trailing zeros (position of rightmost set bit).
 * Ref: http://graphics.stanford.edu/~seander/bithacks.html
 */
static unsigned int zpos(unsigned int v)
{
    unsigned int c = 32;
    v &= (~v + 1u);            /* isolate lowest set bit */
    if (v)                c--;
    if (v & 0x0000FFFFu)  c -= 16;
    if (v & 0x00FF00FFu)  c -= 8;
    if (v & 0x0F0F0F0Fu)  c -= 4;
    if (v & 0x33333333u)  c -= 2;
    if (v & 0x55555555u)  c -= 1;
    return c;
}

/* ------------------------------------------------------------------------ */
/* qmc_combine_levels                                                       */
/* ------------------------------------------------------------------------ */

double qmc_combine_levels(const double *acc, unsigned int m)
{
    unsigned int v;
    double Q = acc[0];
    for (v = 1; v <= m; v++) {
        Q /= 2.0;
        Q += acc[v];
    }
    return Q;
}

/* ------------------------------------------------------------------------ */
/* Standard lattice rule                                                    */
/* ------------------------------------------------------------------------ */

int qmc_latq_base2(size_t s, qmc_integrand_fn fun, void *user_data,
                    const unsigned int *z, unsigned int m,
                    double *acc, long long *T_usecs)
{
    unsigned int v;
    double *x;

    if (s == 0 || m > 20 || !fun || !z || !acc) return -1;

    x = (double *)malloc(s * sizeof(double));
    if (!x) return -1;

    for (v = 0; v <= m; v++) {
        long long t0 = 0;
        uint64_t n = (uint64_t)1 << v;
        double nrecip = 1.0 / (double)n;
        uint64_t k;

        if (T_usecs) t0 = get_usecs();

        acc[v] = 0.0;
        for (k = 1; k <= n; k += 2) {
            calc_lattice_point(s, z, n, nrecip, k, x);
            acc[v] += fun(x, s, user_data);
        }
        acc[v] *= nrecip;

        if (T_usecs) T_usecs[v] = get_usecs() - t0;
    }

    free(x);
    return 0;
}

/* ------------------------------------------------------------------------ */
/* Tent-transformed lattice rule                                            */
/* ------------------------------------------------------------------------ */

int qmc_lattentq_base2(size_t s, qmc_integrand_fn fun, void *user_data,
                        const unsigned int *z, unsigned int m,
                        double *acc, long long *T_usecs)
{
    unsigned int v;
    double *x;

    if (s == 0 || m > 20 || !fun || !z || !acc) return -1;

    x = (double *)malloc(s * sizeof(double));
    if (!x) return -1;

    for (v = 0; v <= m; v++) {
        long long t0 = 0;
        uint64_t n = (uint64_t)1 << v;
        double nrecip = 1.0 / (double)n;
        uint64_t k;

        if (T_usecs) t0 = get_usecs();

        acc[v] = 0.0;
        for (k = 1; k <= n; k += 2) {
            size_t j;
            calc_lattice_point(s, z, n, nrecip, k, x);
            for (j = 0; j < s; j++) {
                x[j] = 1.0 - fabs(2.0 * x[j] - 1.0);
            }
            acc[v] += fun(x, s, user_data);
        }
        acc[v] *= nrecip;

        if (T_usecs) T_usecs[v] = get_usecs() - t0;
    }

    free(x);
    return 0;
}

/* ------------------------------------------------------------------------ */
/* Symmetrized lattice rule                                                 */
/* ------------------------------------------------------------------------ */

int qmc_latsymq_base2(size_t s, qmc_integrand_fn fun, void *user_data,
                       const unsigned int *z, unsigned int m,
                       double *acc, long long *T_usecs)
{
    unsigned int v;
    double *x;
    uint64_t S;

    if (s == 0 || m > 20 || !fun || !z || !acc) return -1;
    if (s > 62) return -1;  /* 2^s must fit in uint64_t */

    x = (double *)malloc(s * sizeof(double));
    if (!x) return -1;

    S = (uint64_t)1 << s;

    for (v = 0; v <= m; v++) {
        long long t0 = 0;
        uint64_t n = (uint64_t)1 << v;
        double nrecip = 1.0 / (double)n;
        double M = nrecip;
        uint64_t k = 1;

        if (T_usecs) t0 = get_usecs();

        acc[v] = 0.0;

        switch (v) {
        case 0: {
            size_t j;
            M /= (double)((uint64_t)1 << s);
            for (j = 0; j < s; j++) x[j] = 0.0;
            acc[0] += fun(x, s, user_data);
            goto symmetrize;
        }
        case 1:
            calc_lattice_point(s, z, n, nrecip, (uint64_t)1, x);
            acc[1] += fun(x, s, user_data) * nrecip;
            break;
        default:
            M /= (double)((uint64_t)1 << (s - 1));
            for (k = 1; k < n / 2; k += 2) {
                uint64_t i;
                calc_lattice_point(s, z, n, nrecip, k, x);
                acc[v] += fun(x, s, user_data);
symmetrize:
                for (i = 1; i < S; i++) {
                    unsigned int j = zpos((unsigned int)i);
                    x[j] = 1.0 - x[j];
                    acc[v] += fun(x, s, user_data);
                }
            }
            acc[v] *= M;
        }

        if (T_usecs) T_usecs[v] = get_usecs() - t0;
    }

    free(x);
    return 0;
}
