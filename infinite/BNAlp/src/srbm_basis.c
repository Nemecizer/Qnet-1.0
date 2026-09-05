/*
 * srbm_basis.c – BAR coefficient computation.
 * Faithful translation of Basis.m (Saure, Glynn, Zeevi 2008).
 */
#include "srbm_basis.h"
#include "srbm_mem.h"
#include <string.h>

/* Access macro for 3D basis array B(i, j, h):
 *   data[i * n_basis * (d+1) + j * (d+1) + h]
 */
#define B(i, j, h) bas->data[(i) * n_basis * (d + 1) + (j) * (d + 1) + (h)]

/* Access macro for index array I(i, col):
 *   I[i * (d+1) + col]   col = 0..d-1 are exponents, col = d is total degree
 */
#define II(i, col) idx->I[(i) * (d + 1) + (col)]

void srbm_basis_build(const srbm_index_t *idx, const double *G,
                      const double *M, const double *R,
                      int d, int m, srbm_basis_t *bas)
{
    int n_basis = idx->n_basis;

    bas->n_basis = n_basis;
    bas->d       = d;
    bas->data    = (double *)srbm_calloc((size_t)n_basis * n_basis * (d + 1),
                                         sizeof(double));

    /*
     * Translation of Basis.m.  MATLAB is 1-based; C is 0-based.
     *
     * MATLAB: for i=2:N(m+1)       =>  C: for i=1 to n_basis-1
     *   ni = max(I(i,d+1)-1, 0)    =>  max(II(i,d)-1, 0)
     *   n0 = max(I(i,d+1)-3, 0)    =>  max(II(i,d)-3, 0)
     *   aux = 1; if I(i,d+1)>2, aux = N(n0+1)+1
     *                           =>  if II(i,d)>2, aux_start = N[n0]+1 (but 0-based: N[n0])
     *   for j = aux:N(ni+1)    =>  for j = aux_start-1 .. N[ni]-1 (0-based)
     *
     * Key array mappings:
     *   MATLAB I(i, 1:d) => C II(i, 0..d-1)    (variable exponents)
     *   MATLAB I(i, d+1) => C II(i, d)          (total degree)
     *   MATLAB M(k)      => C M[k-1]
     *   MATLAB G(a,b)    => C G[(a-1)*d + (b-1)]  (row-major)
     *   MATLAB R(a,b)    => C R[(a-1)*d + (b-1)]  (row-major)
     *   MATLAB N(k)      => C idx->N[k-1]
     *   MATLAB B(i,j,h)  => C B(i-1, j-1, h-1)
     */

    for (int i = 1; i < n_basis; i++) {   /* MATLAB i = 2 .. N(m+1) */
        int deg_i = II(i, d);             /* I(i, d+1) in MATLAB */
        int ni = (deg_i - 1 > 0) ? deg_i - 1 : 0;
        int n0 = (deg_i - 3 > 0) ? deg_i - 3 : 0;

        /* aux_start in 1-based MATLAB indexing */
        int aux_start_m = 1;
        if (deg_i > 2) {
            aux_start_m = idx->N[n0] + 1;  /* MATLAB N(n0+1) + 1 */
        }

        /* j loop: MATLAB j = aux_start_m : N(ni+1)
         * In 0-based C: j = aux_start_m-1 .. N[ni]-1 */
        int j_begin = aux_start_m - 1;
        int j_end   = idx->N[ni];  /* MATLAB N(ni+1) => C N[ni] */

        for (int j = j_begin; j < j_end; j++) {
            B(i, j, 0) = 0.0;  /* MATLAB B(i,j,1) = 0 */

            /* aux1 = I(i,1:d) - H(j,1:d)
             * In MATLAB, H = I at this point (they initialize H = I but never modify it)
             * So aux1(k) = I(i,k) - I(j,k) for k=1..d
             *           => II(i,k) - II(j,k) for k=0..d-1 */
            int aux1[SRBM_MAX_DIM];
            for (int k = 0; k < d; k++)
                aux1[k] = II(i, k) - II(j, k);

            /* aux2 = find(aux1)  : indices where aux1 != 0  (1-based in MATLAB)
             * aux3 = aux1(aux2)  : nonzero values */
            int aux2[SRBM_MAX_DIM];
            int aux3[SRBM_MAX_DIM];
            int n_nonzero = 0;
            for (int k = 0; k < d; k++) {
                if (aux1[k] != 0) {
                    aux2[n_nonzero] = k;        /* 0-based index */
                    aux3[n_nonzero] = aux1[k];
                    n_nonzero++;
                }
            }

            /* Check: (aux3 >= 0) i.e. all nonzero diffs are positive */
            int all_nonneg = 1;
            int sum_aux3   = 0;
            for (int q = 0; q < n_nonzero; q++) {
                if (aux3[q] < 0) { all_nonneg = 0; break; }
                sum_aux3 += aux3[q];
            }
            if (!all_nonneg) continue;

            if (sum_aux3 == 1 && n_nonzero == 1) {
                /* Drift term:  aux3 >= 0, sum(aux3)==1, length(aux2)==1
                 * MATLAB: B(i,j,1) = I(i,aux2)*M(aux2)
                 *
                 * Here aux2[0] is the 0-based coordinate index where the diff is 1.
                 * Also need: I(i, aux2) > 0 in MATLAB:
                 *   MATLAB: if (aux3 >=0) & (sum(aux3)==1) & (I(i,aux2)>0)
                 *   This is always true since aux3[0]=1 and I(i,aux2) = aux1[aux2[0]] + I(j,aux2[0]) >= 1.
                 *   Actually MATLAB checks I(i,aux2)>0 which is II(i,aux2[0])>0.
                 */
                int a = aux2[0];  /* 0-based coordinate */
                if (II(i, a) <= 0) continue;

                B(i, j, 0) = (double)II(i, a) * M[a];

                /* Boundary reflection terms:
                 * MATLAB: if I(i,aux2)==1, B(i,j,aux2+1) = R(aux2,aux2)
                 *         for k=1:d, if I(i,k)==0, B(i,j,k+1) = I(i,aux2)*R(aux2,k) */
                if (II(i, a) == 1) {
                    /* B(i,j,a+1) in MATLAB => B(i,j,a+1) in 0-based h index */
                    B(i, j, a + 1) = R[a * d + a];
                }
                for (int k = 0; k < d; k++) {
                    if (II(i, k) == 0) {
                        /* MATLAB: B(i,j,k+1) = I(i,aux2)*R(aux2,k)
                         * C: B(i,j,k+1) = II(i,a) * R[a*d + k] */
                        B(i, j, k + 1) = (double)II(i, a) * R[a * d + k];
                    }
                }

            } else if (sum_aux3 == 2) {
                /* Diffusion term */
                if (n_nonzero == 1) {
                    /* Single coordinate differs by 2: second derivative
                     * MATLAB: if (length(aux2)==1) & (I(i,aux2)>1)
                     *   B(i,j,1) = G(aux2,aux2) * I(i,aux2)*(I(i,aux2)-1) / 2 */
                    int a = aux2[0];
                    if (II(i, a) > 1) {
                        B(i, j, 0) = G[a * d + a]
                                   * (double)(II(i, a) * (II(i, a) - 1)) / 2.0;
                    }
                } else {
                    /* Two coordinates each differ by 1: cross derivative
                     * MATLAB: if I(i,aux2)>0,  B(i,j,1) = prod(I(i,aux2))*G(aux2(1),aux2(2))
                     * Check that both I(i,aux2(1))>0 and I(i,aux2(2))>0 */
                    int a1 = aux2[0], a2 = aux2[1];
                    if (II(i, a1) > 0 && II(i, a2) > 0) {
                        B(i, j, 0) = (double)(II(i, a1) * II(i, a2))
                                   * G[a1 * d + a2];
                    }
                }
            }
        }
    }
}

#undef B
#undef II

void srbm_basis_free(srbm_basis_t *bas)
{
    srbm_free(bas->data);
    bas->data = NULL;
}
