/*
 * srbm_output.c – Moment computation, marginal extraction, CSV output.
 * Translations of moments.m, ETRBM.m, SETRBM.m.
 */
#include "srbm_output.h"
#include "srbm_mem.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

/* --------------------------------------------------------------------------
 * moments.m:
 *   for i=1:k, for j=1:d, EM(i,j) = (P(:,j).^i)' * pd
 * -------------------------------------------------------------------------- */
void srbm_moments(const double *pd, const double *P,
                  int npoints, int d, int max_k, double *EM)
{
    memset(EM, 0, (size_t)max_k * d * sizeof(double));

    for (int ki = 0; ki < max_k; ki++) {
        int power = ki + 1;  /* 1-based moment order */
        for (int j = 0; j < d; j++) {
            double sum = 0.0;
            for (int p = 0; p < npoints; p++) {
                double pv = P[p * d + j];
                double pw = 1.0;
                for (int q = 0; q < power; q++) pw *= pv;
                sum += pw * pd[p];
            }
            EM[ki * d + j] = sum;
        }
    }
}

/* Comparison for qsort of (value, index) pairs */
typedef struct { double val; int idx; } vi_pair_t;
static int cmp_vi(const void *a, const void *b)
{
    double da = ((const vi_pair_t *)a)->val;
    double db = ((const vi_pair_t *)b)->val;
    return (da > db) - (da < db);
}

/* --------------------------------------------------------------------------
 * ETRBM.m:  Extract marginal densities from interior distribution.
 *
 * For each coordinate k:
 *   1. Sort grid values
 *   2. Aggregate probabilities at identical grid values
 *   3. Normalize by bin width (except last bin → 0)
 * -------------------------------------------------------------------------- */
void srbm_marginals(const double *pd, const double *P,
                    int npoints, int n, int d,
                    double **ez, double **epx, int *counts)
{
    (void)n;  /* n not directly used; npoints = n^d already accounts for it */

    vi_pair_t *pairs = (vi_pair_t *)srbm_malloc(npoints * sizeof(vi_pair_t));

    for (int k = 0; k < d; k++) {
        /* Build (value, index) pairs for coordinate k */
        for (int p = 0; p < npoints; p++) {
            pairs[p].val = P[p * d + k];
            pairs[p].idx = p;
        }
        qsort(pairs, npoints, sizeof(vi_pair_t), cmp_vi);

        /* Count distinct values */
        int ndist = 1;
        for (int i = 1; i < npoints; i++) {
            if (pairs[i].val != pairs[i - 1].val)
                ndist++;
        }

        ez[k]  = (double *)srbm_calloc(ndist, sizeof(double));
        epx[k] = (double *)srbm_calloc(ndist, sizeof(double));
        counts[k] = ndist;

        /* Aggregate probabilities */
        int j = 0;
        ez[k][0]  = pairs[0].val;
        epx[k][0] = pd[pairs[0].idx];

        for (int i = 1; i < npoints; i++) {
            if (pairs[i].val == pairs[i - 1].val) {
                epx[k][j] += pd[pairs[i].idx];
            } else {
                /* Normalize previous bin by width */
                double width = pairs[i].val - ez[k][j];
                if (width > 0.0)
                    epx[k][j] /= width;
                j++;
                ez[k][j]  = pairs[i].val;
                epx[k][j] = pd[pairs[i].idx];
            }
        }
        /* Last bin: set to 0 (as in MATLAB) */
        epx[k][ndist - 1] = 0.0;
    }

    srbm_free(pairs);
}

/* --------------------------------------------------------------------------
 * SETRBM.m:  Smooth marginal densities (3-point moving average).
 * -------------------------------------------------------------------------- */
void srbm_smooth_marginals(double **epx, int d, const int *counts,
                           double **spx)
{
    for (int k = 0; k < d; k++) {
        int x = counts[k];
        spx[k] = (double *)srbm_malloc(x * sizeof(double));

        if (x <= 1) {
            spx[k][0] = epx[k][0];
            continue;
        }

        spx[k][0] = (2.0 / 3.0) * epx[k][0] + (1.0 / 3.0) * epx[k][1];
        for (int i = 1; i < x - 1; i++) {
            spx[k][i] = (1.0 / 3.0) * epx[k][i - 1]
                       + (1.0 / 3.0) * epx[k][i]
                       + (1.0 / 3.0) * epx[k][i + 1];
        }
        spx[k][x - 1] = (2.0 / 3.0) * epx[k][x - 1]
                       + (1.0 / 3.0) * epx[k][x - 2];
    }
}

void srbm_print_moments(const double *EM, int max_k, int d)
{
    printf("\nMoments:\n");
    printf("  %-8s", "Order");
    for (int j = 0; j < d; j++)
        printf("  E[Z_%d^k]    ", j + 1);
    printf("\n");

    for (int ki = 0; ki < max_k; ki++) {
        printf("  k=%-5d", ki + 1);
        for (int j = 0; j < d; j++)
            printf("  %12.6f", EM[ki * d + j]);
        printf("\n");
    }
}

void srbm_write_marginals_csv(const char *prefix, double **ez, double **spx,
                              int d, const int *counts)
{
    for (int k = 0; k < d; k++) {
        char fname[512];
        snprintf(fname, sizeof(fname), "%s_marginal_%d.csv", prefix, k + 1);
        FILE *fp = fopen(fname, "w");
        if (!fp) {
            fprintf(stderr, "Cannot open %s for writing\n", fname);
            continue;
        }
        fprintf(fp, "z_%d,density\n", k + 1);
        for (int i = 0; i < counts[k]; i++)
            fprintf(fp, "%.10e,%.10e\n", ez[k][i], spx[k][i]);
        fclose(fp);
        printf("  Wrote %s (%d points)\n", fname, counts[k]);
    }
}

void srbm_write_distribution_csv(const char *prefix, const double *pd,
                                 const double *P, int npoints, int d)
{
    char fname[512];
    snprintf(fname, sizeof(fname), "%s_distribution.csv", prefix);
    FILE *fp = fopen(fname, "w");
    if (!fp) {
        fprintf(stderr, "Cannot open %s for writing\n", fname);
        return;
    }
    /* Header */
    for (int j = 0; j < d; j++)
        fprintf(fp, "z_%d,", j + 1);
    fprintf(fp, "probability\n");

    for (int p = 0; p < npoints; p++) {
        for (int j = 0; j < d; j++)
            fprintf(fp, "%.10e,", P[p * d + j]);
        fprintf(fp, "%.10e\n", pd[p]);
    }
    fclose(fp);
    printf("  Wrote %s (%d points)\n", fname, npoints);
}

void srbm_marginals_free(double **ez, double **epx, double **spx, int d)
{
    for (int k = 0; k < d; k++) {
        srbm_free(ez[k]);
        srbm_free(epx[k]);
        if (spx) srbm_free(spx[k]);
    }
}
