/*
 * srbm_grid.c – Grid generation for SRBM approximation.
 * Translations of ExpGrid.m, DyaGrid.m, ExpRanGrid.m.
 */
#include "srbm_grid.h"
#include "srbm_mem.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

#ifdef _OPENMP
#include <omp.h>
#endif

/* --------------------------------------------------------------------------
 * ipow – integer power (n^k) for small k
 * -------------------------------------------------------------------------- */
static int ipow(int base, int exp)
{
    int result = 1;
    for (int i = 0; i < exp; i++)
        result *= base;
    return result;
}

/* --------------------------------------------------------------------------
 * Exponential grid  (ExpGrid.m)
 *
 *   x(i, k) = -log(1 - (i-1)/n) / mu(k)      for i = 2..n
 *   x(1, k) = 0
 *   Then P is the d-dimensional tensor product of x values.
 * -------------------------------------------------------------------------- */
static void build_exp_grid(int d, int n, const double *mu, srbm_grid_t *grid)
{
    /* Build per-coordinate values */
    double *x = (double *)srbm_calloc((size_t)n * d, sizeof(double));
    for (int k = 0; k < d; k++) {
        x[0 * d + k] = 0.0;
        for (int i = 1; i < n; i++) {
            x[i * d + k] = -log(1.0 - (double)i / (double)n) / mu[k];
        }
    }

    int npoints = ipow(n, d);
    grid->npoints = npoints;
    grid->P = (double *)srbm_malloc((size_t)npoints * d * sizeof(double));

    #ifdef _OPENMP
    #pragma omp parallel for schedule(static)
    #endif
    for (int j = 0; j < npoints; j++) {
        for (int k = 0; k < d; k++) {
            int aux = ipow(n, d - 1 - k);
            int xi  = (j / aux) % n;
            grid->P[j * d + k] = x[xi * d + k];
        }
    }

    srbm_free(x);
}

/* --------------------------------------------------------------------------
 * Dyadic grid  (DyaGrid.m)
 * -------------------------------------------------------------------------- */
static void build_dya_grid(int d, int n, srbm_grid_t *grid)
{
    int ncoord  = n * n + 1;
    int npoints = ipow(ncoord, d);
    grid->npoints = npoints;
    grid->P = (double *)srbm_malloc((size_t)npoints * d * sizeof(double));

    double scale = 3.33 / (double)(n * n);

    #ifdef _OPENMP
    #pragma omp parallel for schedule(static)
    #endif
    for (int j = 0; j < npoints; j++) {
        for (int k = 0; k < d; k++) {
            int aux = ipow(ncoord, d - 1 - k);
            double val = (double)((j / aux) % ncoord) * scale;
            if (val > 3.0)
                val = val + (val - 3.0) * 10.0;
            grid->P[j * d + k] = val;
        }
    }
}

/* --------------------------------------------------------------------------
 * Random exponential grid  (ExpRanGrid.m)
 * -------------------------------------------------------------------------- */
static void build_expran_grid(int d, int n, const double *mu, srbm_grid_t *grid)
{
    /* npoints(1) = n^d, npoints(2:d+1) = 2*n */
    int np0 = ipow(n, d);
    int total = np0 + d * 2 * n;
    grid->npoints = total;
    grid->P = (double *)srbm_malloc((size_t)total * d * sizeof(double));

    int row = 0;
    /* Block k=0: n^d rows, all coordinates random exponential */
    for (int j = 0; j < np0; j++) {
        for (int c = 0; c < d; c++) {
            double u = (double)rand() / ((double)RAND_MAX + 1.0);
            grid->P[row * d + c] = -log(u) / mu[c];
        }
        row++;
    }
    /* Blocks k=1..d: 2n rows each, coordinate k-1 forced to 0 */
    for (int bk = 0; bk < d; bk++) {
        for (int j = 0; j < 2 * n; j++) {
            for (int c = 0; c < d; c++) {
                if (c == bk) {
                    grid->P[row * d + c] = 0.0;
                } else {
                    double u = (double)rand() / ((double)RAND_MAX + 1.0);
                    grid->P[row * d + c] = -log(u) / mu[c];
                }
            }
            row++;
        }
    }
}

/* --------------------------------------------------------------------------
 * Public entry point
 * -------------------------------------------------------------------------- */
void srbm_grid_build(int d, int n, int grid_type, const double *mu_grid,
                     srbm_grid_t *grid)
{
    memset(grid, 0, sizeof(*grid));
    grid->d = d;
    grid->n = n;

    switch (grid_type) {
    case 0:  build_exp_grid(d, n, mu_grid, grid);    break;
    case 1:  build_dya_grid(d, n, grid);              break;
    case 2:  build_expran_grid(d, n, mu_grid, grid);  break;
    default: build_exp_grid(d, n, mu_grid, grid);     break;
    }

    /* Build boundary index lists: for each face k, collect indices j
       where P[j,k] == 0. */
    for (int k = 0; k < d; k++) {
        /* First pass: count */
        int cnt = 0;
        for (int j = 0; j < grid->npoints; j++) {
            if (grid->P[j * d + k] == 0.0)
                cnt++;
        }
        grid->bdy_count[k] = cnt;
        grid->bdy_idx[k] = (int *)srbm_malloc((size_t)cnt * sizeof(int));

        /* Second pass: fill */
        int pos = 0;
        for (int j = 0; j < grid->npoints; j++) {
            if (grid->P[j * d + k] == 0.0)
                grid->bdy_idx[k][pos++] = j;
        }
    }
}

void srbm_grid_free(srbm_grid_t *grid)
{
    srbm_free(grid->P);
    for (int k = 0; k < grid->d; k++)
        srbm_free(grid->bdy_idx[k]);
    memset(grid, 0, sizeof(*grid));
}
