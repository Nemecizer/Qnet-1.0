/*
 * srbm_linalg.c – Dense linear algebra wrappers via Apple Accelerate.
 * Compiled with -DACCELERATE_NEW_LAPACK to use the non-deprecated API.
 */
#include "srbm_linalg.h"
#include <Accelerate/Accelerate.h>
#include <stdio.h>
#include <stdlib.h>

int srbm_linalg_solve(int n, int nrhs, double *A, double *B)
{
    int nn   = n;
    int nrr  = nrhs;
    int lda  = n;
    int ldb  = n;
    int info = 0;
    int *ipiv = (int *)malloc(n * sizeof(int));

    dgesv_(&nn, &nrr, A, &lda, ipiv, B, &ldb, &info);

    free(ipiv);
    if (info != 0) {
        fprintf(stderr, "srbm_linalg_solve: dgesv failed, info = %d\n", info);
        return -1;
    }
    return 0;
}

int srbm_linalg_inv(int n, double *A)
{
    int nn   = n;
    int lda  = n;
    int info = 0;
    int *ipiv = (int *)malloc(n * sizeof(int));

    dgetrf_(&nn, &nn, A, &lda, ipiv, &info);
    if (info != 0) {
        fprintf(stderr, "srbm_linalg_inv: dgetrf failed, info = %d\n", info);
        free(ipiv);
        return -1;
    }

    int lwork = n * n;
    double *work = (double *)malloc(lwork * sizeof(double));
    dgetri_(&nn, A, &lda, ipiv, work, &lwork, &info);

    free(work);
    free(ipiv);
    if (info != 0) {
        fprintf(stderr, "srbm_linalg_inv: dgetri failed, info = %d\n", info);
        return -1;
    }
    return 0;
}

void srbm_linalg_mm(int n, double alpha, const double *A, const double *B,
                    double beta, double *C)
{
    cblas_dgemm(CblasColMajor, CblasNoTrans, CblasNoTrans,
                n, n, n, alpha, A, n, B, n, beta, C, n);
}

void srbm_linalg_mv(int m, int n, double alpha, const double *A,
                    const double *x, double beta, double *y)
{
    cblas_dgemv(CblasColMajor, CblasNoTrans,
                m, n, alpha, A, m, x, 1, beta, y, 1);
}
