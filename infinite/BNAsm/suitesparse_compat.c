/*
 * suitesparse_compat.c - Implementation of SuiteSparse compatibility layer
 */

#include "suitesparse_compat.h"

/* Verbosity level from bnet */
extern int verbosity;

/* Global CHOLMOD common structure */
cholmod_common g_cholmod_common;
int g_cholmod_initialized = 0;

void init_global_cholmod(void) {
    if (!g_cholmod_initialized) {
        cholmod_start(&g_cholmod_common);
        g_cholmod_initialized = 1;
    }
}

void finish_global_cholmod(void) {
    if (g_cholmod_initialized) {
        cholmod_finish(&g_cholmod_common);
        g_cholmod_initialized = 0;
    }
}

/* Allocate a dense matrix (uninitialized) */
DMAT *dmat_alloc(int m, int n) {
    DMAT *A = (DMAT *)malloc(sizeof(DMAT));
    if (!A) {
        fprintf(stderr, "Error: Failed to allocate DMAT structure\n");
        exit(1);
    }
    A->m = m;
    A->n = n;
    A->data = (double *)malloc(m * n * sizeof(double));
    if (!A->data) {
        fprintf(stderr, "Error: Failed to allocate DMAT data (%d x %d)\n", m, n);
        exit(1);
    }
    return A;
}

/* Allocate a dense matrix (zero-initialized) */
DMAT *dmat_calloc(int m, int n) {
    DMAT *A = (DMAT *)malloc(sizeof(DMAT));
    if (!A) {
        fprintf(stderr, "Error: Failed to allocate DMAT structure\n");
        exit(1);
    }
    A->m = m;
    A->n = n;
    A->data = (double *)calloc(m * n, sizeof(double));
    if (!A->data) {
        fprintf(stderr, "Error: Failed to allocate DMAT data (%d x %d)\n", m, n);
        exit(1);
    }
    return A;
}

/* Allocate a dense vector (uninitialized) */
DVEC *dvec_alloc(int dim) {
    DVEC *v = (DVEC *)malloc(sizeof(DVEC));
    if (!v) {
        fprintf(stderr, "Error: Failed to allocate DVEC structure\n");
        exit(1);
    }
    v->dim = dim;
    v->data = (double *)malloc(dim * sizeof(double));
    if (!v->data) {
        fprintf(stderr, "Error: Failed to allocate DVEC data (%d)\n", dim);
        exit(1);
    }
    return v;
}

/* Allocate a dense vector (zero-initialized) */
DVEC *dvec_calloc(int dim) {
    DVEC *v = (DVEC *)malloc(sizeof(DVEC));
    if (!v) {
        fprintf(stderr, "Error: Failed to allocate DVEC structure\n");
        exit(1);
    }
    v->dim = dim;
    v->data = (double *)calloc(dim, sizeof(double));
    if (!v->data) {
        fprintf(stderr, "Error: Failed to allocate DVEC data (%d)\n", dim);
        exit(1);
    }
    return v;
}

/* Allocate permutation */
DPERM *dperm_alloc(int size) {
    DPERM *p = (DPERM *)malloc(sizeof(DPERM));
    if (!p) {
        fprintf(stderr, "Error: Failed to allocate DPERM structure\n");
        exit(1);
    }
    p->size = size;
    p->data = (int *)malloc(size * sizeof(int));
    if (!p->data) {
        fprintf(stderr, "Error: Failed to allocate DPERM data (%d)\n", size);
        exit(1);
    }
    return p;
}

/* Free functions */
void dmat_free(DMAT *A) {
    if (A) {
        if (A->data) free(A->data);
        free(A);
    }
}

void dvec_free(DVEC *v) {
    if (v) {
        if (v->data) free(v->data);
        free(v);
    }
}

void dperm_free(DPERM *p) {
    if (p) {
        if (p->data) free(p->data);
        free(p);
    }
}

/* Copy functions */
void dmat_copy(DMAT *src, DMAT *dst) {
    if (src->m != dst->m || src->n != dst->n) {
        fprintf(stderr, "Error: dmat_copy dimension mismatch\n");
        exit(1);
    }
    memcpy(dst->data, src->data, src->m * src->n * sizeof(double));
}

void dvec_copy(DVEC *src, DVEC *dst) {
    if (src->dim != dst->dim) {
        fprintf(stderr, "Error: dvec_copy dimension mismatch\n");
        exit(1);
    }
    memcpy(dst->data, src->data, src->dim * sizeof(double));
}

/*
 * Apply regularization to matrix diagonal
 * Adds epsilon to each diagonal element to help ensure positive definiteness
 */
void apply_regularization(DMAT *A, double epsilon) {
    int n = A->m;
    int i;

    if (A->m != A->n) {
        fprintf(stderr, "Error: apply_regularization requires square matrix\n");
        exit(1);
    }

    if (verbosity >= 2)
        fprintf(stderr, "         [Regularization] Adding %.2e to diagonal elements...\n", epsilon);

    for (i = 0; i < n; i++) {
        MAT_AT(A, i, i) += epsilon;
    }
}

/*
 * Cholesky solver using CHOLMOD
 * Solves A*x = b where A is symmetric positive definite
 * Only the lower triangular part of A is used
 * Returns 0 on success, 1 if matrix is not positive definite, 2 for other errors
 */
int chol_solve(DMAT *A, DVEC *b, DVEC *x, cholmod_common *cc) {
    int n = A->m;
    int i, j, k;

    if (A->m != A->n) {
        fprintf(stderr, "Error: chol_solve requires square matrix\n");
        return 2;
    }
    if (b->dim != n || x->dim != n) {
        fprintf(stderr, "Error: chol_solve dimension mismatch\n");
        return 2;
    }

    /* Count non-zeros in lower triangular part */
    int nnz = (n * (n + 1)) / 2;

    if (verbosity >= 2) {
        fprintf(stderr, "         [CHOLMOD] Converting dense matrix to sparse format...\n");
        fprintf(stderr, "         [CHOLMOD] Matrix size: %d x %d, non-zeros in lower triangle: %d\n", n, n, nnz);
    }

    /* Create CHOLMOD triplet from dense symmetric matrix (lower triangular) */
    cholmod_triplet *T = cholmod_allocate_triplet(n, n, nnz, 1, CHOLMOD_REAL, cc);
    if (!T) {
        fprintf(stderr, "Error: Failed to allocate CHOLMOD triplet\n");
        return 2;
    }

    int *Ti = (int *)T->i;
    int *Tj = (int *)T->j;
    double *Tx = (double *)T->x;

    k = 0;
    for (i = 0; i < n; i++) {
        for (j = 0; j <= i; j++) {
            Ti[k] = i;
            Tj[k] = j;
            Tx[k] = MAT_AT(A, i, j);
            k++;
        }
    }
    T->nnz = k;

    /* Convert triplet to sparse */
    cholmod_sparse *S = cholmod_triplet_to_sparse(T, k, cc);
    if (!S) {
        fprintf(stderr, "Error: Failed to convert triplet to sparse\n");
        cholmod_free_triplet(&T, cc);
        return 2;
    }

    /* Analyze and factorize */
    if (verbosity >= 2)
        fprintf(stderr, "         [CHOLMOD] Analyzing sparsity pattern...\n");
    cholmod_factor *L = cholmod_analyze(S, cc);
    if (!L) {
        fprintf(stderr, "Error: CHOLMOD analyze failed\n");
        cholmod_free_sparse(&S, cc);
        cholmod_free_triplet(&T, cc);
        return 2;
    }

    if (verbosity >= 2)
        fprintf(stderr, "         [CHOLMOD] Computing Cholesky factorization (A = L*L')...\n");
    int status = cholmod_factorize(S, L, cc);
    if (!status || cc->status != CHOLMOD_OK) {
        /* Check if it's specifically a "not positive definite" error */
        int ret_status = (cc->status == CHOLMOD_NOT_POSDEF) ? 1 : 2;
        cholmod_free_factor(&L, cc);
        cholmod_free_sparse(&S, cc);
        cholmod_free_triplet(&T, cc);
        return ret_status;
    }

    /* Create dense vector for b */
    cholmod_dense *b_chol = cholmod_allocate_dense(n, 1, n, CHOLMOD_REAL, cc);
    if (!b_chol) {
        fprintf(stderr, "Error: Failed to allocate CHOLMOD dense for b\n");
        cholmod_free_factor(&L, cc);
        cholmod_free_sparse(&S, cc);
        cholmod_free_triplet(&T, cc);
        return 2;
    }
    memcpy(b_chol->x, b->data, n * sizeof(double));

    /* Solve A*x = b */
    if (verbosity >= 2)
        fprintf(stderr, "         [CHOLMOD] Solving triangular systems (forward/back substitution)...\n");
    cholmod_dense *x_chol = cholmod_solve(CHOLMOD_A, L, b_chol, cc);
    if (!x_chol) {
        fprintf(stderr, "Error: CHOLMOD solve failed\n");
        cholmod_free_dense(&b_chol, cc);
        cholmod_free_factor(&L, cc);
        cholmod_free_sparse(&S, cc);
        cholmod_free_triplet(&T, cc);
        return 2;
    }

    /* Copy result to x */
    memcpy(x->data, x_chol->x, n * sizeof(double));
    if (verbosity >= 2)
        fprintf(stderr, "         [CHOLMOD] Solution computed successfully.\n");

    /* Cleanup */
    cholmod_free_dense(&x_chol, cc);
    cholmod_free_dense(&b_chol, cc);
    cholmod_free_factor(&L, cc);
    cholmod_free_sparse(&S, cc);
    cholmod_free_triplet(&T, cc);

    return 0;
}

/*
 * LU solver using UMFPACK
 * Solves A*x = b for general square matrix A
 */
void lu_solve(DMAT *A, DVEC *b, DVEC *x) {
    int n = A->m;
    int i, j, k;

    if (A->m != A->n) {
        fprintf(stderr, "Error: lu_solve requires square matrix\n");
        exit(1);
    }
    if (b->dim != n || x->dim != n) {
        fprintf(stderr, "Error: lu_solve dimension mismatch\n");
        exit(1);
    }

    if (verbosity >= 2)
        fprintf(stderr, "         [UMFPACK] Solving %d x %d general linear system...\n", n, n);

    /* Convert dense matrix to column-compressed sparse format */
    /* For a dense matrix, all n*n elements are non-zero */
    int nnz = n * n;

    if (verbosity >= 2)
        fprintf(stderr, "         [UMFPACK] Converting to column-compressed sparse format...\n");

    /* Allocate arrays for compressed column format */
    int *Ap = (int *)malloc((n + 1) * sizeof(int));
    int *Ai = (int *)malloc(nnz * sizeof(int));
    double *Ax = (double *)malloc(nnz * sizeof(double));

    if (!Ap || !Ai || !Ax) {
        fprintf(stderr, "Error: Failed to allocate UMFPACK arrays\n");
        exit(1);
    }

    /* Fill column-compressed format */
    /* Column j starts at Ap[j] and ends at Ap[j+1]-1 */
    k = 0;
    for (j = 0; j < n; j++) {
        Ap[j] = k;
        for (i = 0; i < n; i++) {
            Ai[k] = i;
            Ax[k] = MAT_AT(A, i, j);
            k++;
        }
    }
    Ap[n] = k;

    /* UMFPACK symbolic and numeric factorization */
    void *Symbolic, *Numeric;
    double Info[UMFPACK_INFO], Control[UMFPACK_CONTROL];

    umfpack_di_defaults(Control);

    if (verbosity >= 2)
        fprintf(stderr, "         [UMFPACK] Analyzing sparsity pattern...\n");
    int status = umfpack_di_symbolic(n, n, Ap, Ai, Ax, &Symbolic, Control, Info);
    if (status != UMFPACK_OK) {
        fprintf(stderr, "Error: UMFPACK symbolic failed (status=%d)\n", status);
        free(Ap); free(Ai); free(Ax);
        exit(1);
    }

    if (verbosity >= 2)
        fprintf(stderr, "         [UMFPACK] Computing LU factorization (A = L*U)...\n");
    status = umfpack_di_numeric(Ap, Ai, Ax, Symbolic, &Numeric, Control, Info);
    umfpack_di_free_symbolic(&Symbolic);
    if (status != UMFPACK_OK) {
        fprintf(stderr, "Error: UMFPACK numeric failed (status=%d)\n", status);
        free(Ap); free(Ai); free(Ax);
        exit(1);
    }

    /* Solve A*x = b */
    if (verbosity >= 2)
        fprintf(stderr, "         [UMFPACK] Solving triangular systems...\n");
    status = umfpack_di_solve(UMFPACK_A, Ap, Ai, Ax, x->data, b->data, Numeric, Control, Info);
    umfpack_di_free_numeric(&Numeric);

    if (status != UMFPACK_OK) {
        fprintf(stderr, "Error: UMFPACK solve failed (status=%d)\n", status);
        free(Ap); free(Ai); free(Ax);
        exit(1);
    }

    if (verbosity >= 2)
        fprintf(stderr, "         [UMFPACK] Solution computed successfully.\n");

    /* Cleanup */
    free(Ap);
    free(Ai);
    free(Ax);
}

/* LAPACK dgesv declaration (Fortran interface) */
extern void dgesv_(int *n, int *nrhs, double *A, int *lda,
                   int *ipiv, double *b, int *ldb, int *info);

/*
 * Dense LU solver using LAPACK dgesv
 * Solves A*x = b for general dense matrix A
 * Note: A is modified (LU factorization stored in place)
 */
void dense_lu_solve(DMAT *A, DVEC *b, DVEC *x) {
    int n = A->m;
    int i, j;

    if (A->m != A->n) {
        fprintf(stderr, "Error: dense_lu_solve requires square matrix\n");
        exit(1);
    }
    if (b->dim != n || x->dim != n) {
        fprintf(stderr, "Error: dense_lu_solve dimension mismatch\n");
        exit(1);
    }

    if (verbosity >= 2)
        fprintf(stderr, "         [LAPACK] Solving %d x %d dense linear system...\n", n, n);

    /* LAPACK uses column-major order, our DMAT uses row-major */
    /* Allocate column-major copy of A */
    double *A_colmaj = (double *)malloc(n * n * sizeof(double));
    if (!A_colmaj) {
        fprintf(stderr, "Error: Failed to allocate column-major matrix\n");
        exit(1);
    }

    /* Transpose: A_colmaj[j*n + i] = A[i,j] */
    if (verbosity >= 2)
        fprintf(stderr, "         [LAPACK] Converting to column-major format...\n");
    for (i = 0; i < n; i++) {
        for (j = 0; j < n; j++) {
            A_colmaj[j * n + i] = MAT_AT(A, i, j);
        }
    }

    /* Copy b to x (dgesv overwrites b with solution) */
    memcpy(x->data, b->data, n * sizeof(double));

    /* Allocate pivot indices */
    int *ipiv = (int *)malloc(n * sizeof(int));
    if (!ipiv) {
        fprintf(stderr, "Error: Failed to allocate pivot array\n");
        free(A_colmaj);
        exit(1);
    }

    /* Call LAPACK dgesv */
    int nrhs = 1;
    int lda = n;
    int ldb = n;
    int info;

    if (verbosity >= 2)
        fprintf(stderr, "         [LAPACK] Computing LU factorization and solving...\n");

    dgesv_(&n, &nrhs, A_colmaj, &lda, ipiv, x->data, &ldb, &info);

    if (info != 0) {
        if (info < 0) {
            fprintf(stderr, "Error: LAPACK dgesv argument %d had illegal value\n", -info);
        } else {
            fprintf(stderr, "Error: LAPACK dgesv failed - matrix is singular (U[%d,%d] = 0)\n", info, info);
        }
        free(ipiv);
        free(A_colmaj);
        exit(1);
    }

    if (verbosity >= 2)
        fprintf(stderr, "         [LAPACK] Solution computed successfully.\n");

    /* Cleanup */
    free(ipiv);
    free(A_colmaj);
}

/* CHOLMOD init/finish wrappers */
void cholmod_init(cholmod_common *cc) {
    cholmod_start(cc);
}

void cholmod_finish_wrapper(cholmod_common *cc) {
    cholmod_finish(cc);
}
