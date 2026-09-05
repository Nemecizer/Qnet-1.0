/*
 * srbm_solve_cplex.c – CPLEX backend for the LP solver.
 */
#ifdef HAVE_CPLEX

#include "srbm_solve.h"
#include "srbm_mem.h"
#include <ilcplex/cplex.h>
#include <stdio.h>
#include <string.h>

static CPXENVptr env = NULL;

static int cplex_init(void)
{
    int status = 0;
    env = CPXopenCPLEX(&status);
    if (env == NULL) {
        fprintf(stderr, "CPLEX: CPXopenCPLEX failed, status = %d\n", status);
        return -1;
    }
    CPXsetintparam(env, CPXPARAM_ScreenOutput, CPX_OFF);
    CPXsetintparam(env, CPXPARAM_Read_DataCheck, CPX_DATACHECK_WARN);
    /* Scaling left at CPLEX default (0 = equilibration); aggressive scaling
     * (1) fixes the m>=8 "optimal with unscaled infeasibilities" failures
     * but perturbs vertex selection for degenerate cases (u*=0).  For larger m
     * consider also enabling `basis_normalize 1` in the input file, which
     * scales monomial rows into [0,1] and obviates aggressive scaling. */
    return 0;
}

static int cplex_solve(const srbm_lp_t *lp, srbm_solution_t *sol)
{
    int status = 0;
    CPXLPptr prob = CPXcreateprob(env, &status, "srbm_lp");
    if (prob == NULL) {
        fprintf(stderr, "CPLEX: CPXcreateprob failed, status = %d\n", status);
        return -1;
    }

    /* CPXcopylp expects:
     *   numcols, numrows, objsen, obj, rhs, sense,
     *   matbeg, matcnt, matind, matval, lb, ub, rngval
     *
     * matbeg[j] = col_start[j]
     * matcnt[j] = col_start[j+1] - col_start[j]
     * matind = row_idx
     * matval = val
     */
    int ncols = lp->ncols;
    int nrows = lp->nrows;
    int *matcnt = (int *)srbm_malloc(ncols * sizeof(int));
    for (int j = 0; j < ncols; j++)
        matcnt[j] = lp->col_start[j + 1] - lp->col_start[j];

    status = CPXcopylp(env, prob, ncols, nrows,
                       CPX_MIN,           /* objsen: minimize */
                       lp->obj,
                       lp->rhs,
                       lp->sense,
                       lp->col_start,
                       matcnt,
                       lp->row_idx,
                       lp->val,
                       lp->lb,
                       lp->ub,
                       NULL);             /* rngval */
    srbm_free(matcnt);

    if (status) {
        fprintf(stderr, "CPLEX: CPXcopylp failed, status = %d\n", status);
        CPXfreeprob(env, &prob);
        return -1;
    }

    /* Solve */
    status = CPXlpopt(env, prob);
    if (status) {
        fprintf(stderr, "CPLEX: CPXlpopt failed, status = %d\n", status);
        CPXfreeprob(env, &prob);
        return -1;
    }

    int solstat = CPXgetstat(env, prob);
    if (solstat != CPX_STAT_OPTIMAL) {
        fprintf(stderr, "CPLEX: non-optimal status = %d\n", solstat);
        CPXfreeprob(env, &prob);
        sol->status = solstat;
        return -1;
    }

    double objval = 0.0;
    CPXgetobjval(env, prob, &objval);

    /* ------------------------------------------------------------------
     * Stage 2 (optional): when smoothness slacks are present, refine the
     * solution by fixing u ≈ u* and re-optimizing against TV(lambda)
     * alone.  This breaks degenerate-vertex ties that simplex would
     * otherwise resolve arbitrarily (paper §6.3 smoothness idea).
     * ------------------------------------------------------------------ */
    if (lp->n_slack > 0) {
        /* Recover stage-1 u* (first component of the current objective) */
        double y_u = 0.0;
        CPXgetx(env, prob, &y_u, lp->u_col, lp->u_col);
        double u_tol = 1e-8 + 1e-6 * (y_u > 0 ? y_u : 0.0);
        double u_bound = y_u + u_tol;
        char bkind = 'U';
        int u_col_arr = lp->u_col;
        CPXchgbds(env, prob, 1, &u_col_arr, &bkind, &u_bound);

        /* Replace objective: zero on u, unit on each slack. */
        int nobj = lp->n_slack + 1;
        int    *cidx = (int *)   srbm_malloc(nobj * sizeof(int));
        double *cval = (double *)srbm_malloc(nobj * sizeof(double));
        cidx[0] = lp->u_col;
        cval[0] = 0.0;
        for (int e = 0; e < lp->n_slack; e++) {
            cidx[1 + e] = lp->slack_col_start + e;
            cval[1 + e] = 1.0;
        }
        CPXchgobj(env, prob, nobj, cidx, cval);
        srbm_free(cidx);
        srbm_free(cval);

        status = CPXlpopt(env, prob);
        if (status == 0) {
            solstat = CPXgetstat(env, prob);
            if (solstat == CPX_STAT_OPTIMAL) {
                /* keep the stage-1 u* in sol->obj_val */
                objval = y_u;
            } else {
                fprintf(stderr, "CPLEX stage-2 non-optimal status = %d "
                        "(keeping stage-1 result)\n", solstat);
            }
        } else {
            fprintf(stderr, "CPLEX stage-2 CPXlpopt failed status = %d "
                    "(keeping stage-1 result)\n", status);
        }
    }

    /* Extract final solution (stage-2 if run, else stage-1) */
    double *y = (double *)srbm_malloc(ncols * sizeof(double));
    CPXgetx(env, prob, y, 0, ncols - 1);

    sol->status  = 0;
    sol->obj_val = objval;   /* stage-1 u* even after stage-2 refinement */
    sol->d       = lp->d;
    sol->npoints = lp->n_interior;

    /* Interior distribution */
    sol->lambda = (double *)srbm_malloc(sol->npoints * sizeof(double));
    memcpy(sol->lambda, y, sol->npoints * sizeof(double));

    /* Boundary distributions: lower then upper */
    int d = lp->d;
    for (int k = 0; k < d; k++) {
        int nbm = lp->n_minus[k];
        sol->n_minus[k] = nbm;
        sol->gamma_minus[k] = (double *)srbm_malloc(nbm * sizeof(double));
        memcpy(sol->gamma_minus[k], y + lp->col_offset[k + 1],
               nbm * sizeof(double));

        int nbp = lp->n_plus[k];
        sol->n_plus[k] = nbp;
        sol->gamma_plus[k] = (double *)srbm_malloc(nbp * sizeof(double));
        memcpy(sol->gamma_plus[k], y + lp->col_offset[d + 1 + k],
               nbp * sizeof(double));
    }

    srbm_free(y);
    CPXfreeprob(env, &prob);
    return 0;
}

static void cplex_cleanup(void)
{
    if (env) {
        CPXcloseCPLEX(&env);
        env = NULL;
    }
}

const srbm_solver_backend_t srbm_solver_cplex = {
    .name    = "cplex",
    .init    = cplex_init,
    .solve   = cplex_solve,
    .cleanup = cplex_cleanup
};

#endif /* HAVE_CPLEX */
