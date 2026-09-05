/*
 * srbm_grid.c — Uniform tensor grid on the box [0, b_1] × … × [0, b_d],
 * with per-face index lists for both lower (xᵢ = 0) and upper (xᵢ = bᵢ)
 * boundaries. Replaces the orthant builders (exponential / dyadic /
 * exprandom) used by BNAlp.
 */
#include "srbm_grid.h"
#include "srbm_mem.h"
#include <stdlib.h>
#include <string.h>

#ifdef _OPENMP
#include <omp.h>
#endif

static int ipow(int base, int exp)
{
    int r = 1;
    for (int i = 0; i < exp; i++) r *= base;
    return r;
}

/* Uniform grid: along each axis k, n nodes with x_k[i] = i * b_k / (n-1)
 * for i = 0..n-1. Endpoints are exact (xi=0 → 0, xi=n-1 → b_k) so the
 * face index lookup below uses integer comparison on xi to avoid any
 * floating-point ambiguity. */
static void build_uniform_grid(int d, int n, const double *b_upper,
                               srbm_grid_t *grid)
{
    int npoints = ipow(n, d);
    grid->npoints = npoints;
    grid->P = (double *)srbm_malloc((size_t)npoints * d * sizeof(double));

    double scale[SRBM_MAX_DIM];
    for (int k = 0; k < d; k++)
        scale[k] = (n > 1) ? b_upper[k] / (double)(n - 1) : 0.0;

    #ifdef _OPENMP
    #pragma omp parallel for schedule(static)
    #endif
    for (int j = 0; j < npoints; j++) {
        for (int k = 0; k < d; k++) {
            int aux = ipow(n, d - 1 - k);
            int xi  = (j / aux) % n;
            grid->P[j * d + k] = (double)xi * scale[k];
        }
    }
}

void srbm_grid_build(int d, int n, int grid_type, const double *b_upper,
                     srbm_grid_t *grid)
{
    memset(grid, 0, sizeof(*grid));
    grid->d = d;
    grid->n = n;

    /* Only one grid type currently; placeholder for future Chebyshev. */
    (void)grid_type;
    build_uniform_grid(d, n, b_upper, grid);

    /* Per-face index lists. We use the integer node index on axis k
     * (xi = (j / ipow(n, d-1-k)) % n) instead of comparing P[j,k] against
     * 0.0 or b_upper[k] so the lookup is exact regardless of any drift
     * in the floating-point representation. */
    for (int k = 0; k < d; k++) {
        int aux = ipow(n, d - 1 - k);
        int n_per_face = ipow(n, d - 1);

        grid->bdy_minus_count[k] = n_per_face;
        grid->bdy_minus_idx[k] =
            (int *)srbm_malloc((size_t)n_per_face * sizeof(int));
        grid->bdy_plus_count[k]  = n_per_face;
        grid->bdy_plus_idx[k]  =
            (int *)srbm_malloc((size_t)n_per_face * sizeof(int));

        int posm = 0, posp = 0;
        for (int j = 0; j < grid->npoints; j++) {
            int xi = (j / aux) % n;
            if (xi == 0)        grid->bdy_minus_idx[k][posm++] = j;
            else if (xi == n-1) grid->bdy_plus_idx[k][posp++]  = j;
        }
    }
}

void srbm_grid_free(srbm_grid_t *grid)
{
    srbm_free(grid->P);
    for (int k = 0; k < grid->d; k++) {
        srbm_free(grid->bdy_minus_idx[k]);
        srbm_free(grid->bdy_plus_idx[k]);
    }
    memset(grid, 0, sizeof(*grid));
}
