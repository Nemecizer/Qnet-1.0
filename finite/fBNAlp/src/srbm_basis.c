/*
 * srbm_basis.c — BAR coefficient kernel for the rectangle case.
 *
 * Each (i, j) entry stores B(i, j, h) at h = 0..2d:
 *   h = 0           interior generator coefficient (Lf, drift + diffusion).
 *   h = 1..d        lower-face derivative Rᵢ⁻·∇f at xᵢ = 0.
 *   h = d+1..2d     upper-face derivative Rᵢ⁺·∇f at xᵢ = bᵢ.
 *
 * The drift / diffusion / lower-face logic is the same as the orthant
 * version translated from Basis.m. The upper-face block is filled by
 * running the lower-face kernel a second time using R_plus in place of R
 * and writing into h ∈ d+1..2d. For Qnet's manufacturing-blocking
 * convention the caller passes R_plus = -R, but the kernel works for
 * arbitrary R_plus.
 */
#include "srbm_basis.h"
#include "srbm_mem.h"
#include <string.h>

/* B(i, j, h) over (2d+1) faces: data[i*nbasis*(2d+1) + j*(2d+1) + h] */
#define B(i, j, h) bas->data[(i) * n_basis * (2 * d + 1) + (j) * (2 * d + 1) + (h)]
#define II(i, col) idx->I[(i) * (d + 1) + (col)]

void srbm_basis_build(const srbm_index_t *idx, const double *G,
                      const double *M, const double *R,
                      const double *R_plus,
                      int d, int m, srbm_basis_t *bas)
{
    (void)m;  /* degree implicit in idx->n_basis; kept for API symmetry */

    int n_basis = idx->n_basis;

    bas->n_basis = n_basis;
    bas->d       = d;
    bas->data    = (double *)srbm_calloc(
        (size_t)n_basis * n_basis * (2 * d + 1), sizeof(double));

    /* The orthant translation of Basis.m, extended to fill the upper-face
     * block (h = d+1..2d) with R_plus in place of R. The interior (h = 0)
     * and diffusion terms have no boundary direction, so they are filled
     * once. Drift and reflection terms write face-h coefficients. */

    for (int i = 1; i < n_basis; i++) {
        int deg_i = II(i, d);
        int ni = (deg_i - 1 > 0) ? deg_i - 1 : 0;
        int n0 = (deg_i - 3 > 0) ? deg_i - 3 : 0;

        int aux_start_m = 1;
        if (deg_i > 2) aux_start_m = idx->N[n0] + 1;

        int j_begin = aux_start_m - 1;
        int j_end   = idx->N[ni];

        for (int j = j_begin; j < j_end; j++) {
            B(i, j, 0) = 0.0;

            int aux1[SRBM_MAX_DIM];
            for (int k = 0; k < d; k++)
                aux1[k] = II(i, k) - II(j, k);

            int aux2[SRBM_MAX_DIM];
            int aux3[SRBM_MAX_DIM];
            int n_nonzero = 0;
            for (int k = 0; k < d; k++) {
                if (aux1[k] != 0) {
                    aux2[n_nonzero] = k;
                    aux3[n_nonzero] = aux1[k];
                    n_nonzero++;
                }
            }

            int all_nonneg = 1;
            int sum_aux3   = 0;
            for (int q = 0; q < n_nonzero; q++) {
                if (aux3[q] < 0) { all_nonneg = 0; break; }
                sum_aux3 += aux3[q];
            }
            if (!all_nonneg) continue;

            if (sum_aux3 == 1 && n_nonzero == 1) {
                /* Drift + reflection. Coordinate `a` differs by 1
                 * (α_j = α_i − e_a, α_i_a ≥ 1). */
                int a = aux2[0];
                if (II(i, a) <= 0) continue;
                int ai_a = II(i, a);

                B(i, j, 0) = (double)ai_a * M[a];

                /* Lower face xₐ = 0: the boundary monomial x^{α_j} survives
                 * iff α_j has α_j_k = 0 for the face index k.  This forces
                 *   k = a  with α_i_a = 1   (diagonal contribution), or
                 *   k ≠ a  with α_i_k = 0   (off-diagonal contribution).
                 * Anywhere else x_k = 0 kills the monomial, so B(i,j,*) = 0. */
                if (ai_a == 1) {
                    B(i, j, a + 1) = R[a * d + a];
                }
                for (int k = 0; k < d; k++) {
                    if (k != a && II(i, k) == 0) {
                        B(i, j, k + 1) = (double)ai_a * R[a * d + k];
                    }
                }

                /* Upper face xₖ = bₖ > 0: the monomial b_k^{α_j_k} ≥ 1 never
                 * vanishes from a positive-exponent factor, so EVERY face k
                 * (diagonal a=k or off-diagonal a≠k) gets the contribution
                 *   B(i,j,d+1+k) = α_i_a · R⁺[a, k].
                 * Restrictions like α_i_a == 1 or α_i_k == 0 — which the
                 * lower face needs — would be incorrect here and were the
                 * source of badly mis-estimated E[X_i] at low (n,m). */
                for (int k = 0; k < d; k++) {
                    B(i, j, d + 1 + k) = (double)ai_a * R_plus[a * d + k];
                }
            } else if (sum_aux3 == 2) {
                /* Diffusion. No face contribution. */
                if (n_nonzero == 1) {
                    int a = aux2[0];
                    if (II(i, a) > 1) {
                        B(i, j, 0) = G[a * d + a]
                                   * (double)(II(i, a) * (II(i, a) - 1)) / 2.0;
                    }
                } else {
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
