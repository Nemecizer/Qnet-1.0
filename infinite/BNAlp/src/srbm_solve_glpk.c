/*
 * srbm_solve_glpk.c – GLPK backend for the LP solver.
 */
#ifdef HAVE_GLPK

#include "srbm_solve.h"
#include "srbm_mem.h"
#include <glpk.h>
#include <stdio.h>
#include <string.h>

static int glpk_init(void)
{
    /* GLPK requires no global initialization */
    return 0;
}

static int glpk_solve(const srbm_lp_t *lp, srbm_solution_t *sol)
{
    glp_prob *prob = glp_create_prob();
    glp_set_prob_name(prob, "srbm_lp");
    glp_set_obj_dir(prob, GLP_MIN);

    int nrows = lp->nrows;
    int ncols = lp->ncols;

    /* Add rows */
    glp_add_rows(prob, nrows);
    for (int r = 0; r < nrows; r++) {
        switch (lp->sense[r]) {
        case 'L': glp_set_row_bnds(prob, r + 1, GLP_UP, 0.0, lp->rhs[r]); break;
        case 'E': glp_set_row_bnds(prob, r + 1, GLP_FX, lp->rhs[r], lp->rhs[r]); break;
        case 'G': glp_set_row_bnds(prob, r + 1, GLP_LO, lp->rhs[r], 0.0); break;
        }
    }

    /* Add columns */
    glp_add_cols(prob, ncols);
    for (int c = 0; c < ncols; c++) {
        if (lp->ub[c] >= 1.0e29)
            glp_set_col_bnds(prob, c + 1, GLP_LO, lp->lb[c], 0.0);
        else
            glp_set_col_bnds(prob, c + 1, GLP_DB, lp->lb[c], lp->ub[c]);
        glp_set_obj_coef(prob, c + 1, lp->obj[c]);
    }

    /* Load constraint matrix from CSC.
     * GLPK uses 1-based triplet format via glp_load_matrix. */
    int nnz = lp->col_start[ncols];
    int    *ia = (int *)   srbm_malloc((nnz + 1) * sizeof(int));
    int    *ja = (int *)   srbm_malloc((nnz + 1) * sizeof(int));
    double *ar = (double *)srbm_malloc((nnz + 1) * sizeof(double));

    int idx = 1;  /* GLPK arrays are 1-based */
    for (int c = 0; c < ncols; c++) {
        for (int p = lp->col_start[c]; p < lp->col_start[c + 1]; p++) {
            ia[idx] = lp->row_idx[p] + 1;   /* 1-based row */
            ja[idx] = c + 1;                 /* 1-based col */
            ar[idx] = lp->val[p];
            idx++;
        }
    }
    glp_load_matrix(prob, nnz, ia, ja, ar);
    srbm_free(ia);
    srbm_free(ja);
    srbm_free(ar);

    /* Solve */
    glp_smcp parm;
    glp_init_smcp(&parm);
    parm.msg_lev = GLP_MSG_ERR;
    int ret = glp_simplex(prob, &parm);
    if (ret != 0) {
        fprintf(stderr, "GLPK: glp_simplex failed, ret = %d\n", ret);
        glp_delete_prob(prob);
        sol->status = -1;
        return -1;
    }

    int stat = glp_get_status(prob);
    if (stat != GLP_OPT) {
        fprintf(stderr, "GLPK: non-optimal status = %d\n", stat);
        glp_delete_prob(prob);
        sol->status = stat;
        return -1;
    }

    /* Extract solution */
    sol->status  = 0;
    sol->obj_val = glp_get_obj_val(prob);
    sol->d       = lp->d;
    sol->npoints = lp->n_interior;

    sol->lambda = (double *)srbm_malloc(sol->npoints * sizeof(double));
    for (int j = 0; j < sol->npoints; j++)
        sol->lambda[j] = glp_get_col_prim(prob, j + 1);

    for (int k = 0; k < lp->d; k++) {
        int nb = lp->n_boundary[k];
        sol->n_boundary[k] = nb;
        sol->gamma[k] = (double *)srbm_malloc(nb * sizeof(double));
        int col0 = lp->col_offset[k + 1];
        for (int b = 0; b < nb; b++)
            sol->gamma[k][b] = glp_get_col_prim(prob, col0 + b + 1);
    }

    glp_delete_prob(prob);
    return 0;
}

static void glpk_cleanup(void)
{
    glp_free_env();
}

const srbm_solver_backend_t srbm_solver_glpk = {
    .name    = "glpk",
    .init    = glpk_init,
    .solve   = glpk_solve,
    .cleanup = glpk_cleanup
};

#endif /* HAVE_GLPK */
