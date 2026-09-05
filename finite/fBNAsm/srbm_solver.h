/*
 * srbm_solver.h - SRBM solver interface
 *
 * Implementation of Dai & Harrison (1991) SRBM algorithm in C
 */

#ifndef SRBM_SOLVER_H
#define SRBM_SOLVER_H

#include "srbm_types.h"

/* Pre-computed power table for fast integration (replaces pow() calls) */
typedef struct {
    double div[MAX_DIM][2*MAX_POLY_ORDER+2]; /* pow(a[d], e+1)/(e+1) */
    double raw[MAX_DIM][2*MAX_POLY_ORDER+2]; /* pow(a[d], e) */
    int max_exp;
    int n_dim;
} PowerTable;

/* Initialize a power table from a_vec with exponents 0..max_exp */
void init_power_table(PowerTable *pt, const double *a_vec, int n_dim, int max_exp);

/*
 * Main solver function (original Gram-Schmidt implementation)
 *
 * Computes the stationary distribution of SRBM in a hypercube.
 *
 * Parameters:
 *   params  - SRBM problem parameters
 *   result  - Output structure for results (must be pre-allocated)
 *
 * Returns:
 *   0 on success, non-zero on error
 */
int srbm_solve(const SRBMParams *params, SRBMResult *result);

#ifdef USE_SUITESPARSE
/*
 * SuiteSparse-optimized solver (parallel Gram matrix + Cholesky)
 *
 * Faster than srbm_solve() for larger problems due to:
 * - Parallel Gram matrix construction using all available cores
 * - Optimized Cholesky factorization via CHOLMOD
 * - Integral caching to avoid redundant computations
 *
 * Parameters:
 *   params  - SRBM problem parameters
 *   result  - Output structure for results (must be pre-allocated)
 *
 * Returns:
 *   0 on success, non-zero on error
 */
int srbm_solve_suitesparse(const SRBMParams *params, SRBMResult *result);
#endif

/*
 * Generate all multi-indices with 1 <= |alpha| <= max_order
 *
 * Parameters:
 *   n_dim       - Number of dimensions
 *   max_order   - Maximum polynomial order
 *   indices     - Output array of multi-indices [n_indices x n_dim]
 *   n_indices   - Output: number of indices generated
 *
 * Returns:
 *   Pointer to allocated indices array (caller must free)
 */
int* generate_multi_indices(int n_dim, int max_order, int *n_indices);

/*
 * Compute A*f_alpha for monomial f_alpha = x^alpha
 *
 * Parameters:
 *   alpha   - Multi-index exponents [n_dim]
 *   params  - SRBM parameters
 *   af      - Output AfFunction (must be initialized)
 */
void compute_Af(const int *alpha, const SRBMParams *params, AfFunction *af);

/*
 * Compute inner product (f, g) in L^2(S, eta)
 *
 * Parameters:
 *   f       - First function
 *   g       - Second function
 *   pt      - Interior power table
 *   pt_bnd  - Boundary power tables [n_dim] (indexed by removed dimension)
 *
 * Returns:
 *   Inner product value
 */
double inner_product(const AfFunction *f, const AfFunction *g,
                     const PowerTable *pt, const PowerTable *pt_bnd);

/*
 * Gram-Schmidt orthogonalization
 *
 * Parameters:
 *   Af_list      - Input list of Af functions
 *   n_basis      - Number of basis functions
 *   pt           - Interior power table
 *   pt_bnd       - Boundary power tables [n_dim]
 *   ortho_basis  - Output orthonormal basis (must be pre-allocated)
 */
void gram_schmidt(AfFunction *Af_list, int n_basis,
                  const PowerTable *pt, const PowerTable *pt_bnd,
                  AfFunction *ortho_basis);

/* Pre-computed shifted Legendre polynomial coefficients on [0,1].
 * coeffs[n*(MAX_POLY_ORDER+1) + k] = coefficient of t^k in P_tilde_n(t)
 */
typedef struct {
    double coeffs[(MAX_POLY_ORDER+1) * (MAX_POLY_ORDER+1)];
    int max_order;
} LegendreTable;

/* Pre-compute shifted Legendre coefficients via recurrence */
void legendre_table_init(LegendreTable *table, int max_order);

/* Get coefficient of t^k in P_tilde_n(t) */
static inline double legendre_coeff(const LegendreTable *table, int n, int k) {
    if (k < 0 || k > n || n > table->max_order) return 0.0;
    return table->coeffs[n * (MAX_POLY_ORDER+1) + k];
}

/*
 * Compute A*f_alpha for Legendre basis function
 * f_alpha(x) = P_{alpha_1}(x_1/a_1) * ... * P_{alpha_d}(x_d/a_d)
 */
void compute_Af_legendre(const int *alpha, const SRBMParams *params,
                         const LegendreTable *table, AfFunction *af);

/*
 * Parse input file and populate parameters
 *
 * Parameters:
 *   filename - Path to input file
 *   params   - Output parameters structure
 *
 * Returns:
 *   0 on success, non-zero on error
 */
int parse_input_file(const char *filename, SRBMParams *params);

/*
 * Create standard reflection matrices
 *
 * Parameters:
 *   n_dim  - Number of dimensions
 *   type   - "normal", "tandem", or "jackson"
 *   R      - Output matrix [n_dim x 2*n_dim] (must be pre-allocated)
 */
void create_reflection_matrix(int n_dim, const char *type, double *R);

#endif /* SRBM_SOLVER_H */
