/*
 * srbm_index.c – Multi-index enumeration for polynomial basis.
 * Faithful translation of Indexing.m (Saure, Glynn, Zeevi 2008).
 */
#include "srbm_index.h"
#include "srbm_mem.h"
#include <math.h>
#include <string.h>

/* Compute factorial(n) for small n (used only during indexing). */
static double factorial(int n)
{
    double f = 1.0;
    for (int i = 2; i <= n; i++)
        f *= i;
    return f;
}

void srbm_index_build(int d, int m, srbm_index_t *idx)
{
    /*
     * A(i, k) array from MATLAB (1-indexed there):
     *   MATLAB: A(d, m+1) = (m+d)! / (d! * m!)
     *           A(d, 1)   = 1
     *           A(d, i+1) = A(d, i+2) * (i+1) / (d+i+1)  for i = m-1 down to 1
     *           A(i, 1)   = 1
     *           A(i, k+1) = A(i+1, k+1) * (i+1) / (i+1+k)  for k = 1..m
     *
     * We use 0-based indexing: A[i][k], i=0..d-1 => MATLAB i+1, k=0..m => MATLAB k+1
     * So MATLAB A(i,k) => C A[i-1][k-1].
     */
    int dmax = d;
    int mmax = m;

    /* Allocate A as [dmax][mmax+1] */
    double *A_flat = (double *)srbm_calloc((size_t)dmax * (mmax + 1), sizeof(double));
    #define A(i, k) A_flat[(i) * (mmax + 1) + (k)]
    /* i is 0-based (0..d-1 maps to MATLAB 1..d), k is 0-based (0..m maps to MATLAB 1..m+1) */

    /* MATLAB: A(d, m+1) = factorial(m+d)/(factorial(d)*factorial(m))
     * C: A[d-1][m] */
    A(d - 1, m) = factorial(m + d) / (factorial(d) * factorial(m));

    /* MATLAB: A(d,1) = 1 => C: A[d-1][0] = 1 */
    A(d - 1, 0) = 1.0;

    /* MATLAB: for i=m-1:-1:1, A(d,i+1) = A(d,i+2)*(i+1)/(d+i+1)
     * C: for i=m-1 down to 1, A[d-1][i] = A[d-1][i+1]*(i+1)/(d+i+1) */
    for (int i = m - 1; i >= 1; i--) {
        A(d - 1, i) = A(d - 1, i + 1) * (double)(i + 1) / (double)(d + i + 1);
    }

    /* Build N (cumulative counts) from A(d,:) */
    /* MATLAB: N = A(d,:)  (1-indexed, length m+1) */
    idx->m = m;
    idx->d = d;
    idx->N = (int *)srbm_malloc((size_t)(m + 1) * sizeof(int));
    for (int k = 0; k <= m; k++) {
        idx->N[k] = (int)(A(d - 1, k) + 0.5); /* round to int */
    }
    idx->n_basis = idx->N[m];

    /* Fill remaining rows of A for dimensions d-1 down to 1 */
    /* MATLAB: for i=d-1:-1:1, A(i,1)=1, for k=1:m, A(i,k+1) = A(i+1,k+1)*(i+1)/(i+1+k)
     * C: for ii=d-2 down to 0, A[ii][0]=1, for k=1..m, A[ii][k] = A[ii+1][k]*(ii+2)/(ii+2+k) */
    for (int ii = d - 2; ii >= 0; ii--) {
        A(ii, 0) = 1.0;
        for (int k = 1; k <= m; k++) {
            /* MATLAB i = ii+1: A(i,k+1) = A(i+1,k+1)*(i+1)/(i+1+k)
             * => A[ii][k] = A[ii+1][k] * (ii+2) / (ii+2+k) */
            A(ii, k) = A(ii + 1, k) * (double)(ii + 2) / (double)(ii + 2 + k);
        }
    }

    /* Allocate multi-index array I [n_basis * (d+1)] */
    int n_basis = idx->n_basis;
    idx->I = (int *)srbm_calloc((size_t)n_basis * (d + 1), sizeof(int));

    /* Computing indexes (translation of Indexing.m inner loop)
     *
     * MATLAB uses 1-based indices everywhere.  The key mapping:
     *   MATLAB K(j) => C Karr[j-1], j=1..d => j_c=0..d-1
     *   MATLAB A(j,k) => C A[j-1][k-1]
     *   MATLAB I(i,:) => C idx->I[(i-1)*(d+1) + ...]
     */
    int *Karr = (int *)srbm_calloc(d, sizeof(int));

    for (int i_m = 1; i_m <= n_basis; i_m++) {   /* MATLAB i = 1 .. A(d,m+1) */
        memset(Karr, 0, d * sizeof(int));

        for (int j_m = d; j_m >= 1; j_m--) {     /* MATLAB j = d:-1:1 */
            Karr[j_m - 1] = 0;
            double aux = 0.0;
            for (int h_m = j_m + 1; h_m <= d; h_m++) { /* MATLAB h = j+1:d */
                if (Karr[h_m - 1] > 0) {
                    /* MATLAB: aux = aux + A(h, K(h))
                     * C: aux += A[h_m-1][Karr[h_m-1]-1] */
                    aux += A(h_m - 1, Karr[h_m - 1] - 1);
                }
            }

            /* MATLAB: if i - aux > A(j,1) */
            if ((double)i_m - aux > A(j_m - 1, 0)) {
                for (int k_m = 2; k_m <= m + 1; k_m++) { /* MATLAB k=2:m+1 */
                    /* MATLAB: if i - aux <= A(j,k) */
                    if ((double)i_m - aux <= A(j_m - 1, k_m - 1)) {
                        Karr[j_m - 1] = k_m - 1; /* MATLAB K(j) = k-1 */
                        break;
                    }
                }
            }
        }

        /* Assigning indexes.
         * MATLAB:
         *   I(i, d+1) = K(d)
         *   for j=1:d-1, I(i,j) = K(d+1-j) - K(d-j)
         *   I(i, d) = K(1)
         *
         * C (0-based row i_m-1, columns 0..d):
         *   I[row][d]   = K(d) = Karr[d-1]
         *   I[row][j-1] = K(d+1-j) - K(d-j) = Karr[d-j] - Karr[d-j-1]  for j=1..d-1
         *   I[row][d-1] = K(1) = Karr[0]
         */
        int row = i_m - 1;
        int *Irow = idx->I + row * (d + 1);

        Irow[d] = Karr[d - 1];   /* last column = total degree */
        for (int j_m = 1; j_m <= d - 1; j_m++) {
            Irow[j_m - 1] = Karr[d - j_m] - Karr[d - j_m - 1];
        }
        Irow[d - 1] = Karr[0];
    }

    srbm_free(Karr);
    srbm_free(A_flat);
    #undef A
}

void srbm_index_free(srbm_index_t *idx)
{
    srbm_free(idx->I);
    srbm_free(idx->N);
    idx->I = NULL;
    idx->N = NULL;
    idx->n_basis = 0;
}
