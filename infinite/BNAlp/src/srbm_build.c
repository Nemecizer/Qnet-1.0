/*
 * srbm_build.c – Assemble the LP(n,m) in CSC format.
 * Translation of Build.m.
 *
 * Decision variables:
 *   y = (lambda_1..lambda_{npoints},
 *        gamma_{1,1}..gamma_{1,bdy_count[0]},
 *        ...,
 *        gamma_{d,1}..gamma_{d,bdy_count[d-1]},
 *        u)
 *
 * Constraints (row layout):
 *   [0, n_basis)             :  +BAR <= u     i.e.  A_bar * y  - u <= 0
 *   [n_basis, 2*n_basis)     :  -BAR <= u     i.e. -A_bar * y  - u <= 0
 *   2*n_basis                :  sum(lambda) = 1     (equality)
 *   [2*n_basis+1, 2*n_basis+d]:  boundary finiteness  sum(gamma_k) <= K[...]
 *   2*n_basis+d+1            :  interior tightness    sum(P * lambda) <= K[...]
 *   [2*n_basis+d+2, 2*n_basis+2d+1]: boundary tightness
 *
 * Objective: minimize u (last variable)
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

/* ipow for the smoothness neighbor-stride computation */
static int ipow_local(int b, int e)
{
    int r = 1;
    for (int i = 0; i < e; i++) r *= b;
    return r;
}

void srbm_build_lp(const double *V, double **D,
                   const srbm_grid_t *grid, int d, int n_basis,
                   const double *K, double smoothness_weight,
                   int grid_n, int grid_type, srbm_lp_t *lp)
{
    int npoints = grid->npoints;
    const double *P = grid->P;

    /* Column offsets:
     *   col_offset[0] = 0
     *   col_offset[1] = npoints
     *   col_offset[k+1] = col_offset[k] + bdy_count[k-1]  for k=1..d
     *   col_offset[d+1] = start of u column (also = start of slack cols if
     *                    smoothness is disabled).
     *   u_col  = col_offset[d+1]
     *   slack vars follow u
     *
     * Total columns = col_offset[d+1] + 1 + n_slack
     */
    memset(lp, 0, sizeof(*lp));
    lp->d = d;
    lp->n_interior = npoints;
    lp->col_offset[0] = 0;
    lp->col_offset[1] = npoints;
    for (int k = 0; k < d; k++) {
        lp->n_boundary[k] = grid->bdy_count[k];
        lp->col_offset[k + 2] = lp->col_offset[k + 1] + grid->bdy_count[k];
    }
    lp->u_col = lp->col_offset[d + 1];

    /* Smoothness: for a tensor grid of shape n^d (grid_type 0 or 1 with our
     * enumeration), neighbor pairs along coord k are flattened-index pairs
     * (j, j+stride_k) where stride_k = n^(d-1-k) and i_k < n-1.
     * Total edges: d * (n-1) * n^(d-1). */
    int n_slack = 0;
    if (smoothness_weight > 0.0 && (grid_type == 0 || grid_type == 1)) {
        int per_face = ipow_local(grid_n, d - 1);
        n_slack = d * (grid_n - 1) * per_face;
    }
    lp->n_slack = n_slack;
    lp->slack_col_start = lp->u_col + 1;

    int ncols = lp->u_col + 1 + n_slack;

    /* Row layout */
    int n_bar_rows = 2 * n_basis;          /* +BAR and -BAR rows        */
    int n_norm     = 1;                    /* normalization              */
    int n_bdy_fin  = d;                    /* boundary finiteness        */
    int n_int_tight = 1;                   /* interior tightness         */
    int n_bdy_tight = d;                   /* boundary tightness         */
    int n_smooth_rows = 2 * n_slack;       /* |lam_a - lam_b| <= s_e     */
    int nrows = n_bar_rows + n_norm + n_bdy_fin + n_int_tight + n_bdy_tight
              + n_smooth_rows;

    lp->nrows = nrows;
    lp->ncols = ncols;

    /* Allocate dense RHS, sense, obj, bounds */
    lp->rhs   = (double *)srbm_calloc(nrows, sizeof(double));
    lp->sense  = (char *)  srbm_malloc(nrows * sizeof(char));
    lp->obj    = (double *)srbm_calloc(ncols, sizeof(double));
    lp->lb     = (double *)srbm_calloc(ncols, sizeof(double));
    lp->ub     = (double *)srbm_malloc(ncols * sizeof(double));

    /* Objective: minimize u + smoothness_weight * sum(slack) */
    lp->obj[lp->u_col] = 1.0;
    for (int e = 0; e < n_slack; e++)
        lp->obj[lp->slack_col_start + e] = smoothness_weight;

    /* Lower bounds: all >= 0 */
    /* (calloc already set to 0) */

    /* Upper bounds: all +Inf (we use 1e30 as a practical infinity) */
    for (int c = 0; c < ncols; c++)
        lp->ub[c] = 1.0e30;

    /* Row senses and RHS */
    int row = 0;

    /* Rows 0..n_basis-1:     +BAR <= 0   (i.e. V^T lambda + D^T gamma - u <= 0) */
    for (int r = 0; r < n_basis; r++) {
        lp->sense[row] = 'L';
        lp->rhs[row]   = 0.0;
        row++;
    }
    /* Rows n_basis..2*n_basis-1: -BAR <= 0 */
    for (int r = 0; r < n_basis; r++) {
        lp->sense[row] = 'L';
        lp->rhs[row]   = 0.0;
        row++;
    }
    /* Normalization: sum(lambda) = 1 */
    lp->sense[row] = 'E';
    lp->rhs[row]   = 1.0;
    row++;

    /* Boundary finiteness: sum(gamma_k) <= K[...] */
    for (int k = 0; k < d; k++) {
        lp->sense[row] = 'L';
        lp->rhs[row]   = K[k];    /* K(1:d) in MATLAB correspond to K[0..d-1] */
        row++;
    }

    /* Interior tightness: sum_j (sum_k P(j,k)) * lambda_j <= K[d] */
    lp->sense[row] = 'L';
    lp->rhs[row]   = K[d];
    row++;

    /* Boundary tightness: for each face k,
     * sum over boundary pts of (sum_c P(bdy,c)) * gamma(bdy,k) <= K[d+1+k] */
    for (int k = 0; k < d; k++) {
        lp->sense[row] = 'L';
        lp->rhs[row]   = K[d + 1 + k];
        row++;
    }

    /* ---- Build constraint matrix in COO format, then convert to CSC ---- */

    /* Estimate nnz:
     *   BAR rows: each row has at most npoints + sum(bdy_counts) + 1 entries
     *   Plus normalization, finiteness, tightness rows.
     * Upper bound: 2*n_basis*(npoints + total_bdy + 1) + npoints + total_bdy + npoints + d*max_bdy
     */
    int total_bdy = 0;
    for (int k = 0; k < d; k++) total_bdy += grid->bdy_count[k];
    int est_nnz = 2 * n_basis * (npoints + total_bdy + 1)
                + npoints + total_bdy + npoints + total_bdy + 256;
    srbm_coo_t coo;
    srbm_coo_init(&coo, nrows, ncols, est_nnz);

    /* ---- +BAR rows (rows 0..n_basis-1) ----
     *
     * Network-sparsity optimisation: skip not only exact zeros but also
     * entries whose magnitude is below a tight tolerance.  For networks
     * with banded / sparse primitives (tandem, bidiagonal R, tridiagonal
     * Sigma) the polynomial evaluations produce many values that are
     * mathematically zero but show up as ~1e-16 due to floating-point
     * round-off; with CPLEX-style presolve these become bogus "nonzero"
     * constraints.  Using a relative tolerance (max absolute value over
     * this row times eps) keeps large-scale networks tractable.
     *
     * Row i:
     *   For each grid point j, column j has coefficient V[j * n_basis + i]   (= V^T)
     *   For each face k, for each boundary point b, column col_offset[k+1]+b_local
     *     has coefficient D[k][b_local * n_basis + i]                        (= D^T)
     *   Column ncols-1 (u) has coefficient -1
     */
    #define SRBM_COO_ABS_EPS  1e-14

    for (int i = 0; i < n_basis; i++) {
        /* First pass: compute the max-abs value in this row so the tolerance
         * scales sensibly with the row's natural magnitude (polynomials of
         * degree m evaluated at grid points can be 1e+6, for example). */
        double row_max = 0.0;
        for (int j = 0; j < npoints; j++) {
            double a = fabs(V[j * n_basis + i]);
            if (a > row_max) row_max = a;
        }
        for (int k = 0; k < d; k++) {
            int nbdy = grid->bdy_count[k];
            for (int b = 0; b < nbdy; b++) {
                double a = fabs(D[k][b * n_basis + i]);
                if (a > row_max) row_max = a;
            }
        }
        double tol = SRBM_COO_ABS_EPS * (row_max > 1.0 ? row_max : 1.0);

        /* Interior columns (lambda) */
        for (int j = 0; j < npoints; j++) {
            double v = V[j * n_basis + i];
            if (fabs(v) > tol)
                srbm_coo_push(&coo, i, j, v);
        }
        /* Boundary columns (gamma) */
        for (int k = 0; k < d; k++) {
            int nbdy = grid->bdy_count[k];
            int col0 = lp->col_offset[k + 1];
            for (int b = 0; b < nbdy; b++) {
                double dv = D[k][b * n_basis + i];
                if (fabs(dv) > tol)
                    srbm_coo_push(&coo, i, col0 + b, dv);
            }
        }
        /* u column: -1 */
        srbm_coo_push(&coo, i, lp->u_col, -1.0);
    }

    /* ---- -BAR rows (rows n_basis..2*n_basis-1) ----
     * Same as above but all coefficients negated (and same tolerance gate). */
    for (int i = 0; i < n_basis; i++) {
        int r = n_basis + i;
        double row_max = 0.0;
        for (int j = 0; j < npoints; j++) {
            double a = fabs(V[j * n_basis + i]);
            if (a > row_max) row_max = a;
        }
        for (int k = 0; k < d; k++) {
            int nbdy = grid->bdy_count[k];
            for (int b = 0; b < nbdy; b++) {
                double a = fabs(D[k][b * n_basis + i]);
                if (a > row_max) row_max = a;
            }
        }
        double tol = SRBM_COO_ABS_EPS * (row_max > 1.0 ? row_max : 1.0);

        for (int j = 0; j < npoints; j++) {
            double v = V[j * n_basis + i];
            if (fabs(v) > tol)
                srbm_coo_push(&coo, r, j, -v);
        }
        for (int k = 0; k < d; k++) {
            int nbdy = grid->bdy_count[k];
            int col0 = lp->col_offset[k + 1];
            for (int b = 0; b < nbdy; b++) {
                double dv = D[k][b * n_basis + i];
                if (fabs(dv) > tol)
                    srbm_coo_push(&coo, r, col0 + b, -dv);
            }
        }
        srbm_coo_push(&coo, r, ncols - 1, -1.0);
    }
    #undef SRBM_COO_ABS_EPS

    row = 2 * n_basis;

    /* ---- Normalization row: sum(lambda) = 1 ---- */
    for (int j = 0; j < npoints; j++)
        srbm_coo_push(&coo, row, j, 1.0);
    row++;

    /* ---- Boundary finiteness: for each face k, sum(gamma_k) <= K[k] ---- */
    for (int k = 0; k < d; k++) {
        int nbdy = grid->bdy_count[k];
        int col0 = lp->col_offset[k + 1];
        for (int b = 0; b < nbdy; b++)
            srbm_coo_push(&coo, row, col0 + b, 1.0);
        row++;
    }

    /* ---- Interior tightness: sum_j (sum_c P(j,c)) * lambda_j <= K[d] ---- */
    for (int j = 0; j < npoints; j++) {
        double s = 0.0;
        for (int c = 0; c < d; c++)
            s += P[j * d + c];
        if (s != 0.0)
            srbm_coo_push(&coo, row, j, s);
    }
    row++;

    /* ---- Boundary tightness: for each face k ---- */
    for (int k = 0; k < d; k++) {
        int nbdy = grid->bdy_count[k];
        int col0 = lp->col_offset[k + 1];
        const int *bdy = grid->bdy_idx[k];
        for (int b = 0; b < nbdy; b++) {
            int pidx = bdy[b];
            double s = 0.0;
            for (int c = 0; c < d; c++)
                s += P[pidx * d + c];
            if (s != 0.0)
                srbm_coo_push(&coo, row, col0 + b, s);
        }
        row++;
    }

    /* ---- Smoothness constraints: |lambda_a - lambda_b| <= h_e * s_e ----
     *
     * Neighbor enumeration for tensor grid (grid_type 0/1): for each
     * coordinate k in 0..d-1 and each flattened grid index j with i_k < n-1,
     * neighbor is j + stride_k where stride_k = n^(d-1-k).  Edge length
     *     h_e = x_{j_n}[k] - x_j[k]
     * is the Euclidean distance between the two grid points (they differ only
     * on coord k).
     *
     * With slack coefficient h_e rather than 1, the slack variable represents
     *     s_e  >=  |lambda_j - lambda_jn| / h_e
     * i.e. a discrete density slope, not a raw TV.  Minimizing sum(s_e) then
     * approximates minimizing  integral |grad lambda|, which is grid-spacing
     * aware — essential for exponentially-spaced grids where edges near the
     * origin are O(1/n) long and edges in the tail are O(1).
     *
     * We emit slack vars and a pair of <= rows in the same order so the e-th
     * slack variable is lined up with its two rows. */
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
                if (h_e <= 0.0) h_e = 1e-12;    /* degenerate, avoid /0 */
                int slack_col = lp->slack_col_start + e;
                /*   lambda_j - lambda_jn - h_e * s_e  <=  0 */
                srbm_coo_push(&coo, row, j,         1.0);
                srbm_coo_push(&coo, row, jn,       -1.0);
                srbm_coo_push(&coo, row, slack_col,-h_e);
                lp->sense[row] = 'L';
                lp->rhs[row]   = 0.0;
                row++;
                /*   lambda_jn - lambda_j - h_e * s_e  <=  0 */
                srbm_coo_push(&coo, row, jn,        1.0);
                srbm_coo_push(&coo, row, j,        -1.0);
                srbm_coo_push(&coo, row, slack_col,-h_e);
                lp->sense[row] = 'L';
                lp->rhs[row]   = 0.0;
                row++;
                e++;
            }
        }
        /* Sanity */
        if (e != n_slack) {
            fprintf(stderr, "srbm_build_lp: slack-edge count mismatch %d != %d\n",
                    e, n_slack);
        }
    }

    /* ---- Convert COO to CSC ---- */
    lp->nnz = coo.nnz;
    lp->col_start = (int *)   srbm_malloc(((size_t)ncols + 1) * sizeof(int));
    lp->row_idx   = (int *)   srbm_malloc((size_t)coo.nnz * sizeof(int));
    lp->val       = (double *)srbm_malloc((size_t)coo.nnz * sizeof(double));

    srbm_coo_to_csc(&coo, lp->col_start, lp->row_idx, lp->val);

    /* Update nnz after potential duplicate merging */
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
