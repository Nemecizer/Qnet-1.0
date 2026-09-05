/*
 * srbm_eval.c – Interior and boundary BAR evaluation.
 * Translations of Valuating.m and Daluating.m.
 */
#include "srbm_eval.h"
#include "srbm_mem.h"
#include <string.h>
#include <math.h>

#ifdef _OPENMP
#include <omp.h>
#endif

/* Access macros (same as srbm_basis.c) */
#define II(i, col) idx->I[(i) * (d + 1) + (col)]
#define BB(i, j, h) bas->data[(i) * n_basis * (d + 1) + (j) * (d + 1) + (h)]

/* --------------------------------------------------------------------------
 * Interior evaluation  (Valuating.m)
 *
 * V is [npoints * n_basis] row-major, so V[j * n_basis + i] is the
 * contribution at grid point j for test function i.
 *
 * MATLAB:
 *   for i=1:size(I,1)           -- over each test function
 *     v1 = find(B(i,:,1))       -- columns j where B(i,j,1) != 0
 *     for j = v1
 *       v2 = find(I(j,1:d))     -- coordinates where exponent != 0
 *       I2 = I(j,v2)
 *       P2 = P(:,v2)
 *       ... monomial evaluation ...
 *       V(:,i) += B(i,j,1) * prod(P(:,v2).^I(j,v2))
 * -------------------------------------------------------------------------- */
void srbm_eval_interior(const srbm_index_t *idx, const srbm_basis_t *bas,
                        const srbm_grid_t *grid, double *V)
{
    int n_basis  = idx->n_basis;
    int d        = idx->d;
    int npoints  = grid->npoints;
    const double *P = grid->P;

    memset(V, 0, (size_t)npoints * n_basis * sizeof(double));

    #ifdef _OPENMP
    #pragma omp parallel for schedule(dynamic, 4)
    #endif
    for (int i = 0; i < n_basis; i++) {
        /* Find columns j where B(i,j,0) != 0 */
        for (int j = 0; j < n_basis; j++) {
            double coef = BB(i, j, 0);
            if (coef == 0.0) continue;

            /* Identify non-zero exponents of basis function j */
            int v2[SRBM_MAX_DIM];
            int I2[SRBM_MAX_DIM];
            int nv = 0;
            for (int k = 0; k < d; k++) {
                if (II(j, k) != 0) {
                    v2[nv] = k;
                    I2[nv] = II(j, k);
                    nv++;
                }
            }

            /* Evaluate monomial at each grid point and accumulate */
            if (nv == 0) {
                /* Constant term: V(:,i) += coef */
                for (int p = 0; p < npoints; p++)
                    V[p * n_basis + i] += coef;
            } else if (nv == 1) {
                /* Single variable: V(:,i) += coef * P(:,v2[0])^I2[0] */
                int c = v2[0];
                int e = I2[0];
                for (int p = 0; p < npoints; p++) {
                    double pv = P[p * d + c];
                    double mono = 1.0;
                    for (int q = 0; q < e; q++) mono *= pv;
                    V[p * n_basis + i] += coef * mono;
                }
            } else {
                /* Multiple variables: prod of powers */
                for (int p = 0; p < npoints; p++) {
                    double prod = 1.0;
                    for (int q = 0; q < nv; q++) {
                        double pv = P[p * d + v2[q]];
                        for (int e = 0; e < I2[q]; e++) prod *= pv;
                    }
                    V[p * n_basis + i] += coef * prod;
                }
            }
        }
    }
}

/* --------------------------------------------------------------------------
 * Boundary evaluation  (Daluating.m)
 *
 * D[h] is [bdy_count[h] * n_basis] row-major, where h = 0..d-1 is the face.
 *
 * MATLAB:
 *   for i=1:size(I,1)
 *     for h=1:d
 *       v1 = find(B(i,:,h+1))         -- columns j where B(i,j,h+1) != 0
 *       v3 = find(P(:,h)==0)           -- boundary points for face h
 *       for j = v1
 *         ... evaluate monomial at boundary points ...
 *         D(v3, i, h) += B(i,j,h+1) * prod(P(v3,v2).^I(j,v2))
 * -------------------------------------------------------------------------- */
void srbm_eval_boundary(const srbm_index_t *idx, const srbm_basis_t *bas,
                        const srbm_grid_t *grid, double **D)
{
    int n_basis  = idx->n_basis;
    int d        = idx->d;
    const double *P = grid->P;

    /* Zero-initialize D arrays */
    for (int h = 0; h < d; h++) {
        memset(D[h], 0, (size_t)grid->bdy_count[h] * n_basis * sizeof(double));
    }

    #ifdef _OPENMP
    #pragma omp parallel for collapse(2) schedule(dynamic, 4)
    #endif
    for (int i = 0; i < n_basis; i++) {
        for (int h = 0; h < d; h++) {
            int nbdy = grid->bdy_count[h];
            const int *bdy = grid->bdy_idx[h];

            for (int j = 0; j < n_basis; j++) {
                double coef = BB(i, j, h + 1);  /* B(i, j, h+1) in MATLAB */
                if (coef == 0.0) continue;

                /* Non-zero exponents of basis function j */
                int v2[SRBM_MAX_DIM];
                int I2[SRBM_MAX_DIM];
                int nv = 0;
                for (int k = 0; k < d; k++) {
                    if (II(j, k) != 0) {
                        v2[nv] = k;
                        I2[nv] = II(j, k);
                        nv++;
                    }
                }

                if (nv == 0) {
                    for (int b = 0; b < nbdy; b++)
                        D[h][b * n_basis + i] += coef;
                } else if (nv == 1) {
                    int c = v2[0];
                    int e = I2[0];
                    for (int b = 0; b < nbdy; b++) {
                        int pidx = bdy[b];
                        double pv = P[pidx * d + c];
                        double mono = 1.0;
                        for (int q = 0; q < e; q++) mono *= pv;
                        D[h][b * n_basis + i] += coef * mono;
                    }
                } else {
                    for (int b = 0; b < nbdy; b++) {
                        int pidx = bdy[b];
                        double prod = 1.0;
                        for (int q = 0; q < nv; q++) {
                            double pv = P[pidx * d + v2[q]];
                            for (int e = 0; e < I2[q]; e++) prod *= pv;
                        }
                        D[h][b * n_basis + i] += coef * prod;
                    }
                }
            }
        }
    }
}

#undef II
#undef BB
