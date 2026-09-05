#ifndef SRBM_LINALG_H
#define SRBM_LINALG_H

/* Dense linear algebra wrappers using Apple Accelerate (LAPACK/BLAS).
 * All matrices are column-major (Fortran order). */

/* Solve A * X = B in-place (B is overwritten with solution).
 * A is n x n, B is n x nrhs.  Returns 0 on success. */
int srbm_linalg_solve(int n, int nrhs, double *A, double *B);

/* Compute matrix inverse in-place.  A is n x n, column-major.
 * Returns 0 on success. */
int srbm_linalg_inv(int n, double *A);

/* C = alpha * A * B + beta * C   (all n x n, column-major) */
void srbm_linalg_mm(int n, double alpha, const double *A, const double *B,
                    double beta, double *C);

/* y = alpha * A * x + beta * y   (A is m x n, column-major) */
void srbm_linalg_mv(int m, int n, double alpha, const double *A,
                    const double *x, double beta, double *y);

#endif /* SRBM_LINALG_H */
