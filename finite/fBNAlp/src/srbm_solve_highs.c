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

    /* HiGHS needs HighsInt for col_start and row_idx. Cast directly. */
    HighsInt *a_start = (HighsInt *)lp->col_start;
    HighsInt *a_index = (HighsInt *)lp->row_idx;

    /* Use the persistent Highs* handle so we can set options (time_limit
     * to avoid hanging on highly degenerate LPs, presolve/scaling for
     * conditioning).  Highs_lpCall — the one-shot API used previously —
     * doesn't expose option-setting and would loop indefinitely on certain
     * (n,m) combinations with off-diagonal upper-face reflection. */
    void *highs = Highs_create();
    Highs_setBoolOptionValue(highs, "output_flag", 0);
    Highs_setDoubleOptionValue(highs, "time_limit", 60.0);
    /* Default presolve + scaling are good; explicit setting documents intent. */
    Highs_setStringOptionValue(highs, "presolve", "on");
    /* IPM converges reliably on the highly-degenerate LPs we build at high m
     * (BAR rows become nearly redundant; dual simplex spends thousands of
     * pivots without progress). The slight loss of vertex sparsity doesn't
     * affect the moment computation, which only reads the primal values. */
    Highs_setStringOptionValue(highs, "solver", "ipm");
    Highs_setBoolOptionValue(highs, "run_crossover", 0);

    HighsInt pass_status = Highs_passLp(
        highs, ncols, nrows, nnz,
        1,                          /* a_format: 1 = column-wise CSC */
        kHighsObjSenseMinimize, 0.0,
        lp->obj, lp->lb, lp->ub,
        row_lower, row_upper,
        a_start, a_index, lp->val);
    if (pass_status != kHighsStatusOk) {
        fprintf(stderr, "HiGHS: Highs_passLp failed (status=%d)\n", (int)pass_status);
        Highs_destroy(highs);
        srbm_free(row_lower); srbm_free(row_upper);
        sol->status = -1;
        return -1;
    }

    HighsInt run_status   = Highs_run(highs);
    HighsInt model_status = Highs_getModelStatus(highs);

    /* Allocate solution arrays only after the run, then pull col_value. */
    double *col_value = (double *)srbm_calloc(ncols, sizeof(double));
    Highs_getSolution(highs, col_value, NULL, NULL, NULL);

    Highs_destroy(highs);
    srbm_free(row_lower);
    srbm_free(row_upper);

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

    int d = lp->d;
    for (int k = 0; k < d; k++) {
        int nbm = lp->n_minus[k];
        sol->n_minus[k] = nbm;
        sol->gamma_minus[k] = (double *)srbm_malloc(nbm * sizeof(double));
        memcpy(sol->gamma_minus[k], col_value + lp->col_offset[k + 1],
               nbm * sizeof(double));

        int nbp = lp->n_plus[k];
        sol->n_plus[k] = nbp;
        sol->gamma_plus[k] = (double *)srbm_malloc(nbp * sizeof(double));
        memcpy(sol->gamma_plus[k], col_value + lp->col_offset[d + 1 + k],
               nbp * sizeof(double));
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
