/*
 * suitesparse_compat.h - Compatibility layer for SuiteSparse CHOLMOD
 *
 * Provides DMAT/DVEC types to replace meschach MAT/VEC,
 * with CHOLMOD-based Cholesky solver and UMFPACK-based LU solver.
 */

#ifndef SUITESPARSE_COMPAT_H
#define SUITESPARSE_COMPAT_H

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>
#include <suitesparse/cholmod.h>
#include <suitesparse/umfpack.h>

/* Dense matrix type - row-major storage */
typedef struct {
    double *data;   /* Row-major: data[i*n + j] = element at (i,j) */
    int m;          /* Number of rows */
    int n;          /* Number of columns */
} DMAT;

/* Dense vector type */
typedef struct {
    double *data;   /* data[i] = element i */
    int dim;        /* Dimension */
} DVEC;

/* Permutation type (for compatibility) */
typedef struct {
    int *data;
    int size;
} DPERM;

/* Access macros */
#define MAT_AT(A, i, j)  ((A)->data[(i) * (A)->n + (j)])
#define VEC_AT(v, i)     ((v)->data[i])

/* Allocation functions */
DMAT *dmat_alloc(int m, int n);
DVEC *dvec_alloc(int dim);
DPERM *dperm_alloc(int size);

/* Zero-initialized allocation */
DMAT *dmat_calloc(int m, int n);
DVEC *dvec_calloc(int dim);

/* Free functions */
void dmat_free(DMAT *A);
void dvec_free(DVEC *v);
void dperm_free(DPERM *p);

/* Copy functions */
void dmat_copy(DMAT *src, DMAT *dst);
void dvec_copy(DVEC *src, DVEC *dst);

/* CHOLMOD Cholesky solver for symmetric positive definite systems */
/* Solves A*x = b where A is symmetric positive definite */
/* Returns 0 on success, non-zero on failure (e.g., matrix not positive definite) */
int chol_solve(DMAT *A, DVEC *b, DVEC *x, cholmod_common *cc);

/* Apply regularization to matrix diagonal */
void apply_regularization(DMAT *A, double epsilon);

/* LU solver for general square systems (sparse - uses UMFPACK) */
/* Solves A*x = b for general A */
void lu_solve(DMAT *A, DVEC *b, DVEC *x);

/* Dense LU solver using LAPACK (for large dense matrices) */
/* Solves A*x = b for general dense A */
void dense_lu_solve(DMAT *A, DVEC *b, DVEC *x);

/* Initialize/finalize CHOLMOD */
void cholmod_init(cholmod_common *cc);
void cholmod_finish_wrapper(cholmod_common *cc);

/* Global CHOLMOD common structure (initialized once) */
extern cholmod_common g_cholmod_common;
extern int g_cholmod_initialized;

/* Initialize global CHOLMOD */
void init_global_cholmod(void);
void finish_global_cholmod(void);

#endif /* SUITESPARSE_COMPAT_H */
