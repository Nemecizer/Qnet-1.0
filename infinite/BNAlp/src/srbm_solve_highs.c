/*
 * srbm_solve_highs.c – HiGHS backend for the LP solver.
 */
#ifdef HAVE_HIGHS

#include "srbm_solve.h"
#include "srbm_mem.h"
#include <interfaces/highs_c_api.h>
#include <stdio.h>
#include <string.h>

static int highs_init(void)
{
    return 0;
}

static int highs_solve(const srbm_lp_t *lp, srbm_solution_t *sol)
{
    HighsInt ncols = lp->ncols;
    HighsInt nrows = lp->nrows;
    HighsInt nnz   = lp->col_start[ncols];

    /* HiGHS row bounds: convert sense + rhs to (lower, upper) */
    double *row_lower = (double *)srbm_malloc(nrows * sizeof(double));
    double *row_upper = (double *)srbm_malloc(nrows * sizeof(double));
    for (int r = 0; r < nrows; r++) {
        switch (lp->sense[r]) {
        case 'L':
            row_lower[r] = -1.0e30;
            row_upper[r] = lp->rhs[r];
            break;
        case 'E':
            row_lower[r] = lp->rhs[r];
            row_upper[r] = lp->rhs[r];
            break;
        case 'G':
            row_lower[r] = lp->rhs[r];
            row_upper[r] = 1.0e30;
            break;
        }
    }

    /* HiGHS needs HighsInt for col_start and row_idx.
     * If HighsInt == int (no HIGHSINT64), we can cast directly. */
    HighsInt *a_start = (HighsInt *)lp->col_start;
    HighsInt *a_index = (HighsInt *)lp->row_idx;

    /* Allocate solution arrays */
    double   *col_value  = (double *)  srbm_calloc(ncols, sizeof(double));
    double   *col_dual   = (double *)  srbm_calloc(ncols, sizeof(double));
    double   *row_value  = (double *)  srbm_calloc(nrows, sizeof(double));
    double   *row_dual   = (double *)  srbm_calloc(nrows, sizeof(double));
    HighsInt *col_status  = (HighsInt *)srbm_calloc(ncols, sizeof(HighsInt));
    HighsInt *row_status  = (HighsInt *)srbm_calloc(nrows, sizeof(HighsInt));

    HighsInt model_status = 0;
    HighsInt run_status = Highs_lpCall(
        ncols, nrows, nnz,
        1,                           /* a_format: 1 = column-wise (CSC) */
        kHighsObjSenseMinimize,      /* sense: minimize */
        0.0,                         /* offset */
        lp->obj,
        lp->lb,
        lp->ub,
        row_lower,
        row_upper,
        a_start,
        a_index,
        lp->val,
        col_value,
        col_dual,
        row_value,
        row_dual,
        col_status,
        row_status,
        &model_status
    );

    srbm_free(row_lower);
    srbm_free(row_upper);
    srbm_free(col_dual);
    srbm_free(row_value);
    srbm_free(row_dual);
    srbm_free(col_status);
    srbm_free(row_status);

    if (run_status != kHighsStatusOk || model_status != kHighsModelStatusOptimal) {
        fprintf(stderr, "HiGHS: run_status=%d, model_status=%d\n",
                (int)run_status, (int)model_status);
        srbm_free(col_value);
        sol->status = -1;
        return -1;
    }

    /* Compute objective value */
    double objval = 0.0;
    for (int c = 0; c < ncols; c++)
        objval += lp->obj[c] * col_value[c];

    sol->status  = 0;
    sol->obj_val = objval;
    sol->d       = lp->d;
    sol->npoints = lp->n_interior;

    sol->lambda = (double *)srbm_malloc(sol->npoints * sizeof(double));
    memcpy(sol->lambda, col_value, sol->npoints * sizeof(double));

    for (int k = 0; k < lp->d; k++) {
        int nb = lp->n_boundary[k];
        sol->n_boundary[k] = nb;
        sol->gamma[k] = (double *)srbm_malloc(nb * sizeof(double));
        memcpy(sol->gamma[k], col_value + lp->col_offset[k + 1],
               nb * sizeof(double));
    }

    srbm_free(col_value);
    return 0;
}

static void highs_cleanup(void)
{
    /* No global state to clean up */
}

const srbm_solver_backend_t srbm_solver_highs = {
    .name    = "highs",
    .init    = highs_init,
    .solve   = highs_solve,
    .cleanup = highs_cleanup
};

#endif /* HAVE_HIGHS */
