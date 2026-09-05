/*
 * BNA/FM Algorithm - Common Header
 *
 * Brownian Network Analyzer with Finite Element Method
 * for computing stationary distribution of SRBM in a hypercube.
 *
 * Based on: Shen, Chen, Dai, Dai (2000)
 *
 * This version uses SuiteSparse for sparse matrix operations.
 */

#ifndef BNA_FM_H
#define BNA_FM_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdint.h>

/* SuiteSparse headers */
#include <cholmod.h>
#include <umfpack.h>

/* Maximum supported dimension */
#define MAX_DIM 8
#define CC_MAX 32   /* Max customer classes */

/* Tolerance for floating point comparisons */
#define TOL 1e-12

/* ============================================================
 * Data Structures
 * ============================================================ */

/* Problem parameters from input file */
typedef struct {
    int K;                          /* Dimension */
    double Gamma[MAX_DIM][MAX_DIM]; /* Covariance matrix */
    double theta[MAX_DIM];          /* Drift vector */
    double R[MAX_DIM][2*MAX_DIM];   /* Reflection matrix */
    double lb[MAX_DIM];             /* Lower bounds */
    double ub[MAX_DIM];             /* Upper bounds */
    int mesh_n[MAX_DIM];            /* Mesh sizes */
    double h[MAX_DIM];              /* Element sizes */
    double service_rates[MAX_DIM];  /* Service rates (optional, for throughput) */
    int has_service_rates;          /* Whether service rates were provided */

    /* Customer class data (optional) */
    int cc_num_classes;                 /* K_cc; 0 = feature off */
    double cc_alpha_total[CC_MAX];      /* total throughput per station */
    double cc_lambda[CC_MAX];           /* external arrival rate per class */
    double cc_alpha[CC_MAX][CC_MAX];    /* alpha[k][i] K_cc x K */
    double cc_mu[CC_MAX][CC_MAX];       /* mu[k][i] K_cc x K */
} BNAParams;

/* Sparse matrix in triplet (COO) format for assembly.
 *
 * Optional dedup-on-insert: when `dedup` is non-zero, sparse_triplet_add
 * uses an open-addressing linear-probe hash table keyed on (row, col)
 * to find an existing entry and SUM into it instead of appending. This
 * collapses the per-thread duplicate inflation that comes from cubic
 * Hermite basis sharing between adjacent elements (typical 50× ratio
 * at K=4), shrinking the per-thread RAM peak by the same factor and
 * making the downstream triplet→CHOLMOD conversion O(unique) instead
 * of O(total_with_duplicates).
 *
 * `hash_idx[h]` stores the index into row/col/val of the entry hashing
 * to slot h, or -1 if the slot is empty. Linear probing on collision.
 * Resized (rehashed) when `nnz × 2 > hash_size` to keep load factor
 * ≤ 0.5. `hash_size` is always a power of 2 so we can mask with
 * `hash_size - 1`. */
typedef struct {
    int *row;
    int *col;
    double *val;
    int nnz;
    int capacity;
    int nrows;
    int ncols;
    int dedup;          /* 0 = append-only (legacy), 1 = dedup-on-insert */
    int *hash_idx;      /* size hash_size; -1 = empty slot */
    int hash_size;      /* power of 2 */
} SparseTriplet;

/* Global compact output flag (set by main, suppresses verbose output) */
extern int g_compact;

/* ============================================================
 * Function Declarations - Input/Output
 * ============================================================ */

int parse_input_file(const char *filename, BNAParams *params);
void print_params(const BNAParams *params);

/* ============================================================
 * Function Declarations - Sparse Matrix Operations
 * ============================================================ */

SparseTriplet* sparse_triplet_create(int nrows, int ncols, int initial_capacity);
void sparse_triplet_free(SparseTriplet *mat);
void sparse_triplet_add(SparseTriplet *mat, int row, int col, double val);
/* Enable dedup-on-insert with hash table sized to `expected_unique` entries
 * (rounded up to next power of 2, minimum 64). Allocates the hash table.
 * Must be called BEFORE the first sparse_triplet_add (or after a clear). */
void sparse_triplet_enable_dedup(SparseTriplet *mat, int expected_unique);

/* Convert triplet to CHOLMOD sparse matrix */
cholmod_sparse* triplet_to_cholmod(SparseTriplet *triplet, cholmod_common *c);

/* ============================================================
 * Function Declarations - Linear Solver (SuiteSparse)
 * ============================================================ */

/* Solve Ax = b using UMFPACK (general sparse LU) */
int umfpack_solve(cholmod_sparse *A, double *b, double *x, cholmod_common *c);

/* Solve Ax = b using CHOLMOD (symmetric positive definite) */
int cholmod_solve_system(cholmod_sparse *A, double *b, double *x, cholmod_common *c);

/* Solve Ax = b using Conjugate Gradient (for large symmetric systems) */
int cg_solve(cholmod_sparse *A, double *b, double *x, cholmod_common *c,
             double tol, int max_iter);

/* Smart solver: tries UMFPACK first, falls back to CG for large problems */
int smart_solve(cholmod_sparse *A, double *b, double *x, cholmod_common *c);

/* ============================================================
 * Function Declarations - Hermite Basis Functions
 * ============================================================ */

double phi_func(double xi);
double psi_func(double xi);
double phi_deriv1(double xi);
double psi_deriv1(double xi);
double phi_deriv2(double xi);
double psi_deriv2(double xi);

double hermite_1d(double x, double y, int r, int node_idx, int n, double hj);
double hermite_1d_deriv1(double x, double y, int r, int node_idx, int n, double hj);
double hermite_1d_deriv2(double x, double y, int r, int node_idx, int n, double hj);

/* ============================================================
 * Function Declarations - FEM Assembly
 * ============================================================ */

int node_to_global_idx(const int *node, const int *r, int K, const int *mesh_n);
int get_n_basis(int K, const int *mesh_n);

double eval_Lf_at_x(const double *x, const int *node, const int *r,
                    const BNAParams *params);
void eval_grad_f_at_x(const double *x, const int *node, const int *r,
                      const BNAParams *params, double *grad);

/* ============================================================
 * Function Declarations - Utility
 * ============================================================ */

/* Integer power */
static inline int ipow(int base, int exp) {
    int result = 1;
    while (exp > 0) {
        if (exp & 1) result *= base;
        exp >>= 1;
        base *= base;
    }
    return result;
}

/* Product of array elements */
static inline int prod_int(const int *arr, int n) {
    int result = 1;
    for (int i = 0; i < n; i++) result *= arr[i];
    return result;
}

static inline double prod_double(const double *arr, int n) {
    double result = 1.0;
    for (int i = 0; i < n; i++) result *= arr[i];
    return result;
}

#endif /* BNA_FM_H */
