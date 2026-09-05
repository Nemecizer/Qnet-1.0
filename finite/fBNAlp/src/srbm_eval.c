/*
 * srbm_eval.c — Interior and boundary BAR evaluation for the rectangle.
 *
 * The interior loop is unchanged from the orthant version (just reads
 * B(i,j,0) under the new (2d+1) layout). The boundary loop now runs over
 * both lower (h ∈ 1..d, indices in bdy_minus_idx) and upper (h ∈ d+1..2d,
 * indices in bdy_plus_idx) faces, writing into D_minus and D_plus arrays
 * respectively.
 */
#include "srbm_eval.h"
#include <string.h>

#ifdef _OPENMP
#include <omp.h>
#endif

#define II(i, col) idx->I[(i) * (d + 1) + (col)]
#define BB(i, j, h) bas->data[(i) * n_basis * (2 * d + 1) + (j) * (2 * d + 1) + (h)]

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
        for (int j = 0; j < n_basis; j++) {
            double coef = BB(i, j, 0);
            if (coef == 0.0) continue;

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
                for (int p = 0; p < npoints; p++)
                    V[p * n_basis + i] += coef;
            } else if (nv == 1) {
                int c = v2[0];
                int e = I2[0];
                for (int p = 0; p < npoints; p++) {
                    double pv = P[p * d + c];
                    double mono = 1.0;
                    for (int q = 0; q < e; q++) mono *= pv;
                    V[p * n_basis + i] += coef * mono;
                }
            } else {
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

/* Internal helper: evaluate D for one face (lower or upper) given the
 * basis-array column h_offset (1..d for lower, d+1..2d for upper) and the
 * point-index list for that face. Single sweep over basis pairs (i, j). */
static void eval_one_face(const srbm_index_t *idx, const srbm_basis_t *bas,
                          const srbm_grid_t *grid,
                          int h_offset, const int *bdy, int nbdy,
                          double *D)
{
    int n_basis = idx->n_basis;
    int d       = idx->d;
    const double *P = grid->P;

    memset(D, 0, (size_t)nbdy * n_basis * sizeof(double));

    #ifdef _OPENMP
    #pragma omp parallel for schedule(dynamic, 4)
    #endif
    for (int i = 0; i < n_basis; i++) {
        for (int j = 0; j < n_basis; j++) {
            double coef = BB(i, j, h_offset);
            if (coef == 0.0) continue;

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
                    D[b * n_basis + i] += coef;
            } else if (nv == 1) {
                int c = v2[0];
                int e = I2[0];
                for (int b = 0; b < nbdy; b++) {
                    double pv = P[bdy[b] * d + c];
                    double mono = 1.0;
                    for (int q = 0; q < e; q++) mono *= pv;
                    D[b * n_basis + i] += coef * mono;
                }
            } else {
                for (int b = 0; b < nbdy; b++) {
                    int pidx = bdy[b];
                    double prod = 1.0;
                    for (int q = 0; q < nv; q++) {
                        double pv = P[pidx * d + v2[q]];
                        for (int e = 0; e < I2[q]; e++) prod *= pv;
                    }
                    D[b * n_basis + i] += coef * prod;
                }
            }
        }
    }
}

void srbm_eval_boundary(const srbm_index_t *idx, const srbm_basis_t *bas,
                        const srbm_grid_t *grid,
                        double **D_minus, double **D_plus)
{
    int d = idx->d;
    for (int h = 0; h < d; h++) {
        eval_one_face(idx, bas, grid, h + 1,
                      grid->bdy_minus_idx[h], grid->bdy_minus_count[h],
                      D_minus[h]);
        eval_one_face(idx, bas, grid, d + 1 + h,
                      grid->bdy_plus_idx[h],  grid->bdy_plus_count[h],
                      D_plus[h]);
    }
}

#undef II
#undef BB
