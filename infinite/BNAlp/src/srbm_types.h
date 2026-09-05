#ifndef SRBM_TYPES_H
#define SRBM_TYPES_H

#include <stddef.h>
#include <stdint.h>

/* Maximum SRBM dimension supported */
#define SRBM_MAX_DIM 10

/* ---------------------------------------------------------------------------
 * srbm_params_t  –  SRBM primitive parameters (parsed from input file)
 * --------------------------------------------------------------------------- */
typedef struct {
    int    d;                          /* dimension                          */
    int    n;                          /* grid points per coordinate         */
    int    m;                          /* polynomial basis degree            */
    int    grid_type;                  /* 0=exponential, 1=dyadic, 2=exprandom */
    double mu[SRBM_MAX_DIM];          /* drift vector  (length d)           */
    double sigma[SRBM_MAX_DIM * SRBM_MAX_DIM]; /* covariance matrix (d x d) */
    double R[SRBM_MAX_DIM * SRBM_MAX_DIM];     /* reflection matrix (d x d) */
    double mu_grid[SRBM_MAX_DIM];     /* grid spacing parameter (length d)  */
    double K[2 * SRBM_MAX_DIM + 1];   /* tightness bounds                   */
    int    K_user;                     /* 1 if K was user-specified          */
    int    max_moments;                /* how many moments to compute        */
    char   solver[32];                 /* solver name: cplex, glpk, highs    */
    char   output_prefix[256];         /* output file prefix for CSV         */
    double smoothness_weight;          /* lex-2 weight on TV(lambda);        */
                                       /* 0 = disabled (paper eq 18 / §6.3). */
    int    basis_normalize;            /* 1 = scale monomial rows by         */
                                       /* 1/prod L^p ; 0 = raw (default).    */
} srbm_params_t;

/* ---------------------------------------------------------------------------
 * srbm_grid_t  –  Approximating grid S_n
 * --------------------------------------------------------------------------- */
typedef struct {
    int     d;                         /* dimension                          */
    int     n;                         /* grid points per coordinate         */
    int     npoints;                   /* total grid points = n^d            */
    double *P;                         /* grid coordinates [npoints * d] row-major */
    /* boundary indices: bdy_idx[k] is the list of point indices with P[j,k]==0 */
    int    *bdy_idx[SRBM_MAX_DIM];
    int     bdy_count[SRBM_MAX_DIM];  /* number of boundary points per face */
} srbm_grid_t;

/* ---------------------------------------------------------------------------
 * srbm_index_t  –  Multi-index enumeration for polynomial basis
 * --------------------------------------------------------------------------- */
typedef struct {
    int     d;
    int     m;
    int     n_basis;                   /* total number of basis functions    */
    int    *I;                         /* multi-indices [n_basis * (d+1)]    */
    int    *N;                         /* cumulative counts [m+1]            */
} srbm_index_t;

/* ---------------------------------------------------------------------------
 * srbm_basis_t  –  BAR coefficients
 * --------------------------------------------------------------------------- */
typedef struct {
    int     n_basis;
    int     d;
    double *data;                      /* [n_basis * n_basis * (d+1)] dense 3D */
    /* data[i * n_basis * (d+1) + j * (d+1) + h]
       = B(i,j,h)  where h=0 => interior, h=1..d => boundary face h */
} srbm_basis_t;

/* ---------------------------------------------------------------------------
 * srbm_lp_t  –  LP in CSC (compressed sparse column) format
 *
 *   minimize  obj' * x
 *   subject to  A * x <= rhs   (for inequality rows)
 *               A * x  = rhs   (for equality rows)
 *               lb <= x <= ub
 * --------------------------------------------------------------------------- */
typedef struct {
    int     nrows;                     /* number of constraints              */
    int     ncols;                     /* number of variables                */
    int     nnz;                       /* number of non-zeros in A           */
    double *obj;                       /* objective [ncols]                  */
    int    *col_start;                 /* CSC column starts [ncols+1]        */
    int    *row_idx;                   /* CSC row indices [nnz]              */
    double *val;                       /* CSC values [nnz]                   */
    double *rhs;                       /* right-hand side [nrows]            */
    char   *sense;                     /* 'L' (<=), 'E' (=), 'G' (>=) [nrows] */
    double *lb;                        /* lower bounds [ncols]               */
    double *ub;                        /* upper bounds [ncols]               */
    /* auxiliary: column variable offsets */
    int     n_interior;                /* n^d                                */
    int     n_boundary[SRBM_MAX_DIM];  /* boundary points per face           */
    int     col_offset[SRBM_MAX_DIM + 2]; /* cumulative column offsets       */
    int     d;
    int     u_col;                     /* column index of u variable         */
    int     n_slack;                   /* number of smoothness slack vars    */
    int     slack_col_start;           /* col index of first slack var       */
} srbm_lp_t;

/* ---------------------------------------------------------------------------
 * srbm_solution_t  –  LP solution
 * --------------------------------------------------------------------------- */
typedef struct {
    int     status;                    /* 0 = optimal, nonzero = error       */
    double  obj_val;                   /* optimal objective value (u*)       */
    double *lambda;                    /* interior distribution [npoints]    */
    double *gamma[SRBM_MAX_DIM];       /* boundary distributions per face    */
    int     npoints;
    int     d;
    int     n_boundary[SRBM_MAX_DIM];
} srbm_solution_t;

/* ---------------------------------------------------------------------------
 * srbm_solver_backend_t  –  Solver vtable
 * --------------------------------------------------------------------------- */
typedef struct srbm_solver_backend {
    const char *name;
    int  (*init)(void);
    int  (*solve)(const srbm_lp_t *lp, srbm_solution_t *sol);
    void (*cleanup)(void);
} srbm_solver_backend_t;

#endif /* SRBM_TYPES_H */
