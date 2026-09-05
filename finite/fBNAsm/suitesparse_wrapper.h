/*
 * suitesparse_wrapper.h - SuiteSparse/CHOLMOD wrapper for SRBM solver
 *
 * Provides thread-safe initialization, dense matrix operations,
 * and Cholesky factorization using CHOLMOD.
 */

#ifndef SUITESPARSE_WRAPPER_H
#define SUITESPARSE_WRAPPER_H

#ifdef USE_SUITESPARSE

#include <cholmod.h>

/* Global CHOLMOD context - initialized once per process */
extern cholmod_common ss_common;
extern int ss_initialized;

/* Initialize SuiteSparse with maximum threading */
int ss_init(void);

/* Cleanup SuiteSparse resources */
void ss_finish(void);

/* Get number of threads being used */
int ss_get_num_threads(void);

/*
 * Dense matrix operations
 * Note: CHOLMOD uses column-major storage
 */

/* Allocate nrow x ncol dense matrix */
cholmod_dense* ss_alloc_dense(int nrow, int ncol);

/* Free dense matrix */
void ss_free_dense(cholmod_dense **A);

/* Get element at (i,j) from column-major dense matrix */
static inline double ss_dense_get(const cholmod_dense *A, int i, int j) {
    return ((double*)A->x)[j * (int)A->d + i];
}

/* Set element at (i,j) in column-major dense matrix */
static inline void ss_dense_set(cholmod_dense *A, int i, int j, double val) {
    ((double*)A->x)[j * (int)A->d + i] = val;
}

/* Get pointer to raw data array */
static inline double* ss_dense_data(cholmod_dense *A) {
    return (double*)A->x;
}

/*
 * Cholesky factorization operations
 */

/* Compute Cholesky factorization of symmetric positive definite matrix G
 * Input: G - dense symmetric matrix (only lower triangle is used)
 * Output: L - dense lower triangular Cholesky factor (G = L*L^T)
 * Returns: 0 on success, -1 on failure
 */
int ss_cholesky_dense(cholmod_dense *G, cholmod_dense **L);

/* Solve L*x = b where L is lower triangular (forward substitution)
 * Input: L - lower triangular matrix, b - right-hand side
 * Output: x - solution (can be same as b for in-place solve)
 * Returns: 0 on success, -1 on failure
 */
int ss_solve_lower(const cholmod_dense *L, cholmod_dense *b, cholmod_dense *x);

/* Solve L^T*x = b where L is lower triangular (back substitution)
 * Input: L - lower triangular matrix, b - right-hand side
 * Output: x - solution (can be same as b for in-place solve)
 * Returns: 0 on success, -1 on failure
 */
int ss_solve_lower_transpose(const cholmod_dense *L, cholmod_dense *b, cholmod_dense *x);

/* Combined solve: x = L^{-T} * L^{-1} * b
 * This is the complete orthonormalization transformation
 * Returns: 0 on success, -1 on failure
 */
int ss_solve_cholesky(const cholmod_dense *L, cholmod_dense *b, cholmod_dense *x);

/*
 * Utility functions
 */

/* Print matrix for debugging */
void ss_print_dense(const cholmod_dense *A, const char *name);

/* Compute condition number estimate (1-norm) */
double ss_estimate_condition(const cholmod_dense *L);

#endif /* USE_SUITESPARSE */

#endif /* SUITESPARSE_WRAPPER_H */
