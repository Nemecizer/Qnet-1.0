/*
 * srbm_build.c — Assemble the LP in CSC format for the rectangle case.
 *
 * Decision variables (column order):
 *   λ_j                          j = 0..npoints-1
 *   γ⁻_{0,b}, γ⁻_{1,b}, ..., γ⁻_{d-1,b}
 *   γ⁺_{0,b}, γ⁺_{1,b}, ..., γ⁺_{d-1,b}
 *   u
 *   smoothness slacks (optional)
 *
 * `col_offset` is cumulative:
 *   col_offset[0]    = 0                          start of λ
 *   col_offset[1]    = npoints                    start of γ⁻_0
 *   col_offset[k+1]  = col_offset[k] + bdy_minus_count[k-1]   k = 1..d
 *   col_offset[d+1]  =                            start of γ⁺_0
 *   col_offset[d+1+k+1] = col_offset[d+1+k] + bdy_plus_count[k]  k = 0..d-1
 *   col_offset[2d+1] =                            end of γ⁺ block
 *   u_col            = col_offset[2d+1]
 *   slack_col_start  = u_col + 1
 *
 * Row layout (n = n_basis, K of length 4d+1):
 *   [0, n)               +BAR <= u
 *   [n, 2n)              -BAR <= u
 *   2n                   sum(λ) = 1
 *   [2n+1, 2n+d]         sum(γ⁻_h) <= K[h]              h = 0..d-1
 *   [2n+d+1, 2n+2d]      sum(γ⁺_h) <= K[d+h]            h = 0..d-1
 *   2n+2d+1              sum |x|₁ λ <= K[2d]
 *   [2n+2d+2, 2n+3d+1]   sum |y|₁ γ⁻_h <= K[2d+1+h]     h = 0..d-1
 *   [2n+3d+2, 2n+4d+1]   sum |y|₁ γ⁺_h <= K[3d+1+h]     h = 0..d-1
 *   + 2 * n_slack         smoothness pair rows (optional)
 *
 * Objective: min u + smoothness_weight * Σ slacks.
 */
#include "srbm_build.h"
#include "srbm_sparse.h"
#include "srbm_mem.h"
#include <string.h>
#include <stdio.h>
#include <math.h>

#ifdef _OPENMP
#include <omp.h>
#endif

static int ipow_local(int b, int e)
{
    int r = 1;
    for (int i = 0; i < e; i++) r *= b;
    return r;
}

#define SRBM_COO_ABS_EPS  1e-14

void srbm_build_lp(const double *V, double **D_minus, double **D_plus,
                   const srbm_grid_t *grid, int d, int n_basis,
                   const double *K, double smoothness_weight,
                   int grid_n, int grid_type, srbm_lp_t *lp)
{
    int npoints = grid->npoints;
    const double *P = grid->P;

    memset(lp, 0, sizeof(*lp));
    lp->d = d;
    lp->n_interior = npoints;

    /* Column layout */
    lp->col_offset[0] = 0;
    lp->col_offset[1] = npoints;
    for (int k = 0; k < d; k++) {
        lp->n_minus[k] = grid->bdy_minus_count[k];
        lp->col_offset[k + 2] = lp->col_offset[k + 1] + grid->bdy_minus_count[k];
    }
    /* col_offset[d+1] = start of γ⁺ block */
    for (int k = 0; k < d; k++) {
        lp->n_plus[k] = grid->bdy_plus_count[k];
        lp->col_offset[d + 1 + k + 1] =
            lp->col_offset[d + 1 + k] + grid->bdy_plus_count[k];
    }
    lp->u_col = lp->col_offset[2 * d + 1];

    /* Smoothness slack vars: edges along each axis k where i_k < n-1.
     * Only meaningful for the uniform tensor grid (grid_type 0). */
    int n_slack = 0;
    if (smoothness_weight > 0.0 && grid_type == 0 && grid_n > 1) {
        int per_face = ipow_local(grid_n, d - 1);
        n_slack = d * (grid_n - 1) * per_face;
    }
    lp->n_slack = n_slack;
    lp->slack_col_start = lp->u_col + 1;

    int ncols = lp->u_col + 1 + n_slack;

    /* Row count */
    int n_bar_rows  = 2 * n_basis;
    int n_norm      = 1;
    int n_face_fin  = 2 * d;          /* lower + upper finiteness */
    int n_int_tight = 1;
    int n_face_tight = 2 * d;         /* lower + upper tightness  */
    int n_smooth_rows = 2 * n_slack;
    int nrows = n_bar_rows + n_norm + n_face_fin + n_int_tight
              + n_face_tight + n_smooth_rows;

    lp->nrows = nrows;
    lp->ncols = ncols;

    lp->rhs   = (double *)srbm_calloc(nrows, sizeof(double));
    lp->sense = (char *)  srbm_malloc(nrows * sizeof(char));
    lp->obj   = (double *)srbm_calloc(ncols, sizeof(double));
    lp->lb    = (double *)srbm_calloc(ncols, sizeof(double));
    lp->ub    = (double *)srbm_malloc(ncols * sizeof(double));

    lp->obj[lp->u_col] = 1.0;
    for (int e = 0; e < n_slack; e++)
        lp->obj[lp->slack_col_start + e] = smoothness_weight;

    for (int c = 0; c < ncols; c++) lp->ub[c] = 1.0e30;

    /* Row senses + RHS for the structural rows. BAR rows are <= 0 (slack
     * goes through u via the -1 in the u column). */
    int row = 0;
    for (int r = 0; r < n_basis; r++) { lp->sense[row]='L'; lp->rhs[row]=0.0; row++; }
    for (int r = 0; r < n_basis; r++) { lp->sense[row]='L'; lp->rhs[row]=0.0; row++; }
    lp->sense[row]='E'; lp->rhs[row]=1.0; row++;

    /* face finiteness, lower then upper */
    for (int h = 0; h < d; h++) { lp->sense[row]='L'; lp->rhs[row]=K[h];        row++; }
    for (int h = 0; h < d; h++) { lp->sense[row]='L'; lp->rhs[row]=K[d + h];    row++; }
    /* interior tightness */
    lp->sense[row]='L'; lp->rhs[row]=K[2 * d]; row++;
    /* face tightness, lower then upper */
    for (int h = 0; h < d; h++) { lp->sense[row]='L'; lp->rhs[row]=K[2*d + 1 + h]; row++; }
    for (int h = 0; h < d; h++) { lp->sense[row]='L'; lp->rhs[row]=K[3*d + 1 + h]; row++; }

    /* ---- COO assembly ---- */

    int total_minus = 0, total_plus = 0;
    for (int k = 0; k < d; k++) {
        total_minus += grid->bdy_minus_count[k];
        total_plus  += grid->bdy_plus_count[k];
    }
    int total_bdy = total_minus + total_plus;

    int est_nnz = 2 * n_basis * (npoints + total_bdy + 1)
                + npoints + total_bdy + npoints + total_bdy + 256;
    srbm_coo_t coo;
    srbm_coo_init(&coo, nrows, ncols, est_nnz);

    /* +BAR rows */
    for (int i = 0; i < n_basis; i++) {
        double row_max = 0.0;
        for (int j = 0; j < npoints; j++) {
            double a = fabs(V[j * n_basis + i]);
            if (a > row_max) row_max = a;
        }
        for (int k = 0; k < d; k++) {
            int nbm = grid->bdy_minus_count[k];
            for (int b = 0; b < nbm; b++) {
                double a = fabs(D_minus[k][b * n_basis + i]);
                if (a > row_max) row_max = a;
            }
            int nbp = grid->bdy_plus_count[k];
            for (int b = 0; b < nbp; b++) {
                double a = fabs(D_plus[k][b * n_basis + i]);
                if (a > row_max) row_max = a;
            }
        }
        double tol = SRBM_COO_ABS_EPS * (row_max > 1.0 ? row_max : 1.0);

        for (int j = 0; j < npoints; j++) {
            double v = V[j * n_basis + i];
            if (fabs(v) > tol) srbm_coo_push(&coo, i, j, v);
        }
        for (int k = 0; k < d; k++) {
            int nbm = grid->bdy_minus_count[k];
            int col0m = lp->col_offset[k + 1];
            for (int b = 0; b < nbm; b++) {
                double dv = D_minus[k][b * n_basis + i];
                if (fabs(dv) > tol) srbm_coo_push(&coo, i, col0m + b, dv);
            }
            int nbp = grid->bdy_plus_count[k];
            int col0p = lp->col_offset[d + 1 + k];
            for (int b = 0; b < nbp; b++) {
                double dv = D_plus[k][b * n_basis + i];
                if (fabs(dv) > tol) srbm_coo_push(&coo, i, col0p + b, dv);
            }
        }
        srbm_coo_push(&coo, i, lp->u_col, -1.0);
    }

    /* -BAR rows */
    for (int i = 0; i < n_basis; i++) {
        int r = n_basis + i;
        double row_max = 0.0;
        for (int j = 0; j < npoints; j++) {
            double a = fabs(V[j * n_basis + i]);
            if (a > row_max) row_max = a;
        }
        for (int k = 0; k < d; k++) {
            int nbm = grid->bdy_minus_count[k];
            for (int b = 0; b < nbm; b++) {
                double a = fabs(D_minus[k][b * n_basis + i]);
                if (a > row_max) row_max = a;
            }
            int nbp = grid->bdy_plus_count[k];
            for (int b = 0; b < nbp; b++) {
                double a = fabs(D_plus[k][b * n_basis + i]);
                if (a > row_max) row_max = a;
            }
        }
        double tol = SRBM_COO_ABS_EPS * (row_max > 1.0 ? row_max : 1.0);

        for (int j = 0; j < npoints; j++) {
            double v = V[j * n_basis + i];
            if (fabs(v) > tol) srbm_coo_push(&coo, r, j, -v);
        }
        for (int k = 0; k < d; k++) {
            int nbm = grid->bdy_minus_count[k];
            int col0m = lp->col_offset[k + 1];
            for (int b = 0; b < nbm; b++) {
                double dv = D_minus[k][b * n_basis + i];
                if (fabs(dv) > tol) srbm_coo_push(&coo, r, col0m + b, -dv);
            }
            int nbp = grid->bdy_plus_count[k];
            int col0p = lp->col_offset[d + 1 + k];
            for (int b = 0; b < nbp; b++) {
                double dv = D_plus[k][b * n_basis + i];
                if (fabs(dv) > tol) srbm_coo_push(&coo, r, col0p + b, -dv);
            }
        }
        srbm_coo_push(&coo, r, lp->u_col, -1.0);
    }

    row = 2 * n_basis;

    /* normalization */
    for (int j = 0; j < npoints; j++)
        srbm_coo_push(&coo, row, j, 1.0);
    row++;

    /* face finiteness, lower */
    for (int h = 0; h < d; h++) {
        int nbm = grid->bdy_minus_count[h];
        int col0m = lp->col_offset[h + 1];
        for (int b = 0; b < nbm; b++) srbm_coo_push(&coo, row, col0m + b, 1.0);
        row++;
    }
    /* face finiteness, upper */
    for (int h = 0; h < d; h++) {
        int nbp = grid->bdy_plus_count[h];
        int col0p = lp->col_offset[d + 1 + h];
        for (int b = 0; b < nbp; b++) srbm_coo_push(&coo, row, col0p + b, 1.0);
        row++;
    }

    /* interior tightness */
    for (int j = 0; j < npoints; j++) {
        double s = 0.0;
        for (int c = 0; c < d; c++) s += P[j * d + c];
        if (s != 0.0) srbm_coo_push(&coo, row, j, s);
    }
    row++;

    /* face tightness, lower */
    for (int h = 0; h < d; h++) {
        int nbm = grid->bdy_minus_count[h];
        int col0m = lp->col_offset[h + 1];
        const int *bdy = grid->bdy_minus_idx[h];
        for (int b = 0; b < nbm; b++) {
            int pidx = bdy[b];
            double s = 0.0;
            for (int c = 0; c < d; c++) s += P[pidx * d + c];
            if (s != 0.0) srbm_coo_push(&coo, row, col0m + b, s);
        }
        row++;
    }
    /* face tightness, upper */
    for (int h = 0; h < d; h++) {
        int nbp = grid->bdy_plus_count[h];
        int col0p = lp->col_offset[d + 1 + h];
        const int *bdy = grid->bdy_plus_idx[h];
        for (int b = 0; b < nbp; b++) {
            int pidx = bdy[b];
            double s = 0.0;
            for (int c = 0; c < d; c++) s += P[pidx * d + c];
            if (s != 0.0) srbm_coo_push(&coo, row, col0p + b, s);
        }
        row++;
    }

    /* Smoothness pairs (optional). Same enumeration as BNAlp: along each
     * coord k, neighbours (j, j+stride_k) with i_k < n-1; edge length is
     * the spacing on that axis. For the uniform tensor grid h_e =
     * b_upper[k] / (n-1), constant per axis. */
    if (n_slack > 0) {
        int strides[SRBM_MAX_DIM];
        for (int k = 0; k < d; k++)
            strides[k] = ipow_local(grid_n, d - 1 - k);

        int e = 0;
        for (int k = 0; k < d; k++) {
            int stride = strides[k];
            for (int j = 0; j < npoints; j++) {
                int ik = (j / stride) % grid_n;
                if (ik >= grid_n - 1) continue;
                int jn = j + stride;
                double h_e = P[jn * d + k] - P[j * d + k];
                if (h_e <= 0.0) h_e = 1e-12;
                int slack_col = lp->slack_col_start + e;
                /* λ_j  - λ_jn - h_e * s_e <= 0 */
                srbm_coo_push(&coo, row, j,         1.0);
                srbm_coo_push(&coo, row, jn,       -1.0);
                srbm_coo_push(&coo, row, slack_col,-h_e);
                lp->sense[row] = 'L'; lp->rhs[row] = 0.0; row++;
                /* λ_jn - λ_j  - h_e * s_e <= 0 */
                srbm_coo_push(&coo, row, jn,        1.0);
                srbm_coo_push(&coo, row, j,        -1.0);
                srbm_coo_push(&coo, row, slack_col,-h_e);
                lp->sense[row] = 'L'; lp->rhs[row] = 0.0; row++;
                e++;
            }
        }
        if (e != n_slack)
            fprintf(stderr,
                    "srbm_build_lp: slack-edge count mismatch %d != %d\n",
                    e, n_slack);
    }

    /* ---- COO -> CSC ---- */
    lp->nnz = coo.nnz;
    lp->col_start = (int *)   srbm_malloc(((size_t)ncols + 1) * sizeof(int));
    lp->row_idx   = (int *)   srbm_malloc((size_t)coo.nnz * sizeof(int));
    lp->val       = (double *)srbm_malloc((size_t)coo.nnz * sizeof(double));

    srbm_coo_to_csc(&coo, lp->col_start, lp->row_idx, lp->val);

    lp->nnz = lp->col_start[ncols];

    srbm_coo_free(&coo);
}

void srbm_lp_free(srbm_lp_t *lp)
{
    srbm_free(lp->obj);
    srbm_free(lp->col_start);
    srbm_free(lp->row_idx);
    srbm_free(lp->val);
    srbm_free(lp->rhs);
    srbm_free(lp->sense);
    srbm_free(lp->lb);
    srbm_free(lp->ub);
    memset(lp, 0, sizeof(*lp));
}
