/*
 * suitesparse_wrapper.c - SuiteSparse/CHOLMOD wrapper implementation
 */

#ifdef USE_SUITESPARSE

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#ifdef _OPENMP
#include <omp.h>
#endif

#ifdef __APPLE__
#include <Accelerate/Accelerate.h>
#else
#include <cblas.h>
#include <lapacke.h>
#endif

#include "suitesparse_wrapper.h"

/* Global CHOLMOD context */
cholmod_common ss_common;
int ss_initialized = 0;

int ss_init(void) {
    if (ss_initialized) return 0;

    /* Start CHOLMOD */
    cholmod_start(&ss_common);

    /* Configure for dense operations with supernodal Cholesky */
    ss_common.supernodal = CHOLMOD_SUPERNODAL;

    /* Configure threading */
#ifdef _OPENMP
    int n_threads = omp_get_max_threads();
    ss_common.nthreads_max = n_threads;
    fprintf(stderr, "SuiteSparse initialized with %d threads\n", n_threads);
#else
    ss_common.nthreads_max = 1;
    fprintf(stderr, "SuiteSparse initialized (single-threaded, compile with OPENMP=1 for parallelism)\n");
#endif

    ss_initialized = 1;
    return 0;
}

void ss_finish(void) {
    if (ss_initialized) {
        cholmod_finish(&ss_common);
        ss_initialized = 0;
    }
}

int ss_get_num_threads(void) {
#ifdef _OPENMP
    return omp_get_max_threads();
#else
    return 1;
#endif
}

cholmod_dense* ss_alloc_dense(int nrow, int ncol) {
    if (!ss_initialized) {
        fprintf(stderr, "Error: SuiteSparse not initialized. Call ss_init() first.\n");
        return NULL;
    }

    cholmod_dense *A = cholmod_allocate_dense(nrow, ncol, nrow,
                                               CHOLMOD_REAL, &ss_common);
    if (!A) {
        fprintf(stderr, "Error: Failed to allocate %dx%d dense matrix\n", nrow, ncol);
        return NULL;
    }

    /* Initialize to zero */
    memset(A->x, 0, nrow * ncol * sizeof(double));

    return A;
}

void ss_free_dense(cholmod_dense **A) {
    if (A && *A) {
        cholmod_free_dense(A, &ss_common);
        *A = NULL;
    }
}

int ss_cholesky_dense(cholmod_dense *G, cholmod_dense **L_out) {
    if (!G || !L_out) return -1;

    int n = (int)G->nrow;
    if (n != (int)G->ncol) {
        fprintf(stderr, "Error: Cholesky requires square matrix\n");
        return -1;
    }

    /* Allocate output matrix */
    cholmod_dense *L = ss_alloc_dense(n, n);
    if (!L) return -1;

    /* Copy lower triangle of G to L */
    double *g_data = (double*)G->x;
    double *l_data = (double*)L->x;

    for (int j = 0; j < n; j++) {
        for (int i = j; i < n; i++) {
            l_data[j * n + i] = g_data[j * n + i];
        }
    }

    /* Perform Cholesky factorization using LAPACK dpotrf */
    int info;

#ifdef __APPLE__
    /* Apple Accelerate */
    char uplo = 'L';  /* Lower triangular */
    int n_int = n;
    int lda = n;
    dpotrf_(&uplo, &n_int, l_data, &lda, &info);
#else
    /* LAPACKE interface */
    info = LAPACKE_dpotrf(LAPACK_COL_MAJOR, 'L', n, l_data, n);
#endif

    if (info != 0) {
        if (info > 0) {
            fprintf(stderr, "Error: Cholesky failed - matrix not positive definite at position %d\n", info);
        } else {
            fprintf(stderr, "Error: Cholesky failed - illegal argument %d\n", -info);
        }
        ss_free_dense(&L);
        return -1;
    }

    /* Zero out upper triangle (dpotrf doesn't touch it but we want clean output) */
    for (int j = 1; j < n; j++) {
        for (int i = 0; i < j; i++) {
            l_data[j * n + i] = 0.0;
        }
    }

    *L_out = L;
    return 0;
}

int ss_solve_lower(const cholmod_dense *L, cholmod_dense *b, cholmod_dense *x) {
    if (!L || !b || !x) return -1;

    int n = (int)L->nrow;
    int nrhs = (int)b->ncol;

    /* Copy b to x if they're different */
    if (b != x) {
        memcpy(x->x, b->x, n * nrhs * sizeof(double));
    }

    double *l_data = (double*)L->x;
    double *x_data = (double*)x->x;

#ifdef __APPLE__
    /* Apple Accelerate: dtrsm */
    cblas_dtrsm(CblasColMajor, CblasLeft, CblasLower, CblasNoTrans, CblasNonUnit,
                n, nrhs, 1.0, l_data, n, x_data, n);
#else
    /* Standard CBLAS */
    cblas_dtrsm(CblasColMajor, CblasLeft, CblasLower, CblasNoTrans, CblasNonUnit,
                n, nrhs, 1.0, l_data, n, x_data, n);
#endif

    return 0;
}

int ss_solve_lower_transpose(const cholmod_dense *L, cholmod_dense *b, cholmod_dense *x) {
    if (!L || !b || !x) return -1;

    int n = (int)L->nrow;
    int nrhs = (int)b->ncol;

    /* Copy b to x if they're different */
    if (b != x) {
        memcpy(x->x, b->x, n * nrhs * sizeof(double));
    }

    double *l_data = (double*)L->x;
    double *x_data = (double*)x->x;

#ifdef __APPLE__
    /* Apple Accelerate: dtrsm with transpose */
    cblas_dtrsm(CblasColMajor, CblasLeft, CblasLower, CblasTrans, CblasNonUnit,
                n, nrhs, 1.0, l_data, n, x_data, n);
#else
    /* Standard CBLAS */
    cblas_dtrsm(CblasColMajor, CblasLeft, CblasLower, CblasTrans, CblasNonUnit,
                n, nrhs, 1.0, l_data, n, x_data, n);
#endif

    return 0;
}

int ss_solve_cholesky(const cholmod_dense *L, cholmod_dense *b, cholmod_dense *x) {
    if (!L || !b || !x) return -1;

    /* Solve L*y = b */
    if (ss_solve_lower(L, b, x) != 0) return -1;

    /* Solve L^T*x = y (in-place) */
    if (ss_solve_lower_transpose(L, x, x) != 0) return -1;

    return 0;
}

void ss_print_dense(const cholmod_dense *A, const char *name) {
    if (!A) {
        fprintf(stderr, "%s: (null)\n", name);
        return;
    }

    int nrow = (int)A->nrow;
    int ncol = (int)A->ncol;
    double *data = (double*)A->x;

    fprintf(stderr, "%s (%d x %d):\n", name, nrow, ncol);

    for (int i = 0; i < nrow && i < 10; i++) {  /* Print at most 10 rows */
        fprintf(stderr, "  [");
        for (int j = 0; j < ncol && j < 10; j++) {  /* Print at most 10 cols */
            fprintf(stderr, " %8.4f", data[j * nrow + i]);
        }
        if (ncol > 10) fprintf(stderr, " ...");
        fprintf(stderr, " ]\n");
    }
    if (nrow > 10) fprintf(stderr, "  ...\n");
}

double ss_estimate_condition(const cholmod_dense *L) {
    if (!L) return -1.0;

    int n = (int)L->nrow;
    double *l_data = (double*)L->x;

    /* Estimate condition number using diagonal elements */
    /* For L*L^T, the condition number is approximately (max(diag(L))/min(diag(L)))^2 */
    double max_diag = 0.0;
    double min_diag = 1e308;

    for (int i = 0; i < n; i++) {
        double val = fabs(l_data[i * n + i]);
        if (val > max_diag) max_diag = val;
        if (val < min_diag) min_diag = val;
    }

    if (min_diag < 1e-15) {
        return 1e308;  /* Essentially singular */
    }

    double ratio = max_diag / min_diag;
    return ratio * ratio;
}

#endif /* USE_SUITESPARSE */
