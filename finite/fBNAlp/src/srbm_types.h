#ifndef SRBM_TYPES_H
#define SRBM_TYPES_H

#include <stddef.h>
#include <stdint.h>

/* Maximum SRBM dimension supported. Hard cap matches BNAlp's. */
#define SRBM_MAX_DIM 10

/* ---------------------------------------------------------------------------
 * srbm_params_t  –  SRBM primitive parameters (parsed from input file).
 *
 * Extended from BNAlp's orthant solver to the finite rectangle case:
 *   - `b_upper[i]`   are the upper bounds bᵢ of the box [0, b₁]×…×[0, b_d].
 *   - `R_plus`       is the d×d reflection matrix at upper faces. If the
 *                    user supplies `reflection_form minus_only` (default),
 *                    `main.c` synthesises R_plus = -R (the manufacturing
 *                    blocking convention used by fBNAfm and fBNAsm).
 *   - `K[4*d+1]`     tightness vector. Layout (0-based):
 *                      K[0..d-1]              face finiteness, lower
 *                      K[d..2d-1]             face finiteness, upper
 *                      K[2d]                  interior tightness
 *                      K[2d+1..3d]            face tightness, lower
 *                      K[3d+1..4d]            face tightness, upper
 *   - `grid_type`    0 = uniform tensor on the box (default), 1 = chebyshev
 *                    (reserved). The orthant generators (exp / dyadic /
 *                    expran) are dropped — they have no analogue in a box.
 * --------------------------------------------------------------------------- */
typedef struct {
    int    d;                          /* dimension                          */
    int    n;                          /* grid points per coordinate         */
    int    m;                          /* polynomial basis degree            */
    int    grid_type;                  /* 0=uniform, 1=chebyshev (reserved)  */
    double mu[SRBM_MAX_DIM];          /* drift vector  (length d)           */
    double sigma[SRBM_MAX_DIM * SRBM_MAX_DIM]; /* covariance matrix (d x d) */
    double R[SRBM_MAX_DIM * SRBM_MAX_DIM];     /* lower-face reflection      */
    double R_plus[SRBM_MAX_DIM * SRBM_MAX_DIM];/* upper-face reflection      */
    int    R_full_2d;                  /* 0 => only R supplied, R_plus = -R; */
                                       /* 1 => R_plus came from input file.  */
    double b_upper[SRBM_MAX_DIM];     /* upper bounds of the box            */
    double K[4 * SRBM_MAX_DIM + 1];   /* tightness bounds                   */
    int    K_user;                     /* 1 if K was user-specified          */
    int    max_moments;                /* how many moments to compute        */
    char   solver[32];                 /* solver name: cplex, glpk, highs    */
    char   output_prefix[256];         /* output file prefix for CSV         */
    double smoothness_weight;          /* lex-2 weight on TV(lambda); 0=off  */
    int    basis_normalize;            /* 1 = scale monomial rows by         */
                                       /* 1/prod L^p ; 0 = raw (default).    */
    /* Optional per-station effective service rate (μ_eff_i = 1/E[service]).
     * If supplied, the solver prints rho_i, Gamma_i, sojourn_i derived from
     * the lower-face boundary measure δ⁻_i: Gamma_i = μ_eff_i − δ⁻_i,
     * rho_i = Gamma_i/μ_eff_i, sojourn_i = E[X_i]/Gamma_i (Little's law). */
    int    has_service_rates;
    double service_rates[SRBM_MAX_DIM];
} srbm_params_t;

/* ---------------------------------------------------------------------------
 * srbm_grid_t  –  Uniform tensor grid on the box.
 *
 *   bdy_minus_idx[k] : list of point indices j with P[j,k] == 0
 *   bdy_plus_idx[k]  : list of point indices j with P[j,k] == b_upper[k]
 *
 * Each face holds n^(d-1) points by construction.
 * --------------------------------------------------------------------------- */
typedef struct {
    int     d;
    int     n;
    int     npoints;                   /* n^d                                */
    double *P;                         /* [npoints * d] row-major coords     */
    int    *bdy_minus_idx[SRBM_MAX_DIM];
    int     bdy_minus_count[SRBM_MAX_DIM];
    int    *bdy_plus_idx[SRBM_MAX_DIM];
    int     bdy_plus_count[SRBM_MAX_DIM];
} srbm_grid_t;

/* ---------------------------------------------------------------------------
 * srbm_index_t  –  Multi-index enumeration for polynomial basis (unchanged).
 * --------------------------------------------------------------------------- */
typedef struct {
    int     d;
    int     m;
    int     n_basis;
    int    *I;                         /* [n_basis * (d+1)] multi-indices   */
    int    *N;                         /* [m+1] cumulative counts            */
} srbm_index_t;

/* ---------------------------------------------------------------------------
 * srbm_basis_t  –  BAR coefficients for the rectangle case.
 *
 * Layout: data[i * n_basis * (2*d+1) + j * (2*d+1) + h]
 *   h = 0           : interior (Lf)
 *   h = 1..d        : lower-face derivative  Rᵢ⁻·∇f at xᵢ = 0   (i = h)
 *   h = d+1..2d     : upper-face derivative  Rᵢ⁺·∇f at xᵢ = bᵢ  (i = h-d)
 * --------------------------------------------------------------------------- */
typedef struct {
    int     n_basis;
    int     d;
    double *data;
} srbm_basis_t;

/* ---------------------------------------------------------------------------
 * srbm_lp_t  –  LP in CSC format (column layout extended for upper faces).
 *
 * Decision variables (column order):
 *   λ_j               j = 0..npoints-1
 *   γ⁻_{0,b}, γ⁻_{1,b}, …, γ⁻_{d-1,b}
 *   γ⁺_{0,b}, γ⁺_{1,b}, …, γ⁺_{d-1,b}
 *   u
 *   smoothness slacks (optional)
 *
 * `col_offset[k]` is the cumulative start of:
 *   k=0          : interior block
 *   k=1..d       : lower-face block start for face k-1
 *   k=d+1..2d    : upper-face block start for face k-d-1
 *   k=2d+1       : end of γ⁺ block / start of u column
 * --------------------------------------------------------------------------- */
typedef struct {
    int     nrows;
    int     ncols;
    int     nnz;
    double *obj;
    int    *col_start;
    int    *row_idx;
    double *val;
    double *rhs;
    char   *sense;                     /* 'L' (<=), 'E' (=), 'G' (>=)        */
    double *lb;
    double *ub;
    int     n_interior;                /* n^d                                */
    int     n_minus[SRBM_MAX_DIM];     /* boundary points per lower face     */
    int     n_plus[SRBM_MAX_DIM];      /* boundary points per upper face     */
    int     col_offset[2 * SRBM_MAX_DIM + 2];
    int     d;
    int     u_col;
    int     n_slack;
    int     slack_col_start;
} srbm_lp_t;

/* ---------------------------------------------------------------------------
 * srbm_solution_t  –  LP solution.
 * --------------------------------------------------------------------------- */
typedef struct {
    int     status;
    double  obj_val;
    double *lambda;                    /* interior weights [npoints]         */
    double *gamma_minus[SRBM_MAX_DIM]; /* lower-face boundary weights        */
    double *gamma_plus[SRBM_MAX_DIM];  /* upper-face boundary weights        */
    int     npoints;
    int     d;
    int     n_minus[SRBM_MAX_DIM];
    int     n_plus[SRBM_MAX_DIM];
} srbm_solution_t;

/* ---------------------------------------------------------------------------
 * srbm_solver_backend_t  –  Solver vtable (unchanged from BNAlp).
 * --------------------------------------------------------------------------- */
typedef struct srbm_solver_backend {
    const char *name;
    int  (*init)(void);
    int  (*solve)(const srbm_lp_t *lp, srbm_solution_t *sol);
    void (*cleanup)(void);
} srbm_solver_backend_t;

#endif /* SRBM_TYPES_H */
