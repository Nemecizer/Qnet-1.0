#ifndef SRBM_BASIS_H
#define SRBM_BASIS_H

#include "srbm_types.h"

/* Compute BAR coefficients for the polynomial test basis on the box.
 *
 * bas->data is [n_basis * n_basis * (2*d+1)] with layout:
 *   data[i * n_basis * (2*d+1) + j * (2*d+1) + h]
 * where:
 *   h = 0           : interior (Lf)
 *   h = 1..d        : lower-face derivative  Rᵢ⁻·∇f at xᵢ = 0  (i = h)
 *   h = d+1..2d     : upper-face derivative  Rᵢ⁺·∇f at xᵢ = bᵢ (i = h-d)
 *
 * The interior + lower-face block is identical to BNAlp's orthant solver.
 * The upper-face block re-uses the same kernel with R_plus instead of R.
 */
void srbm_basis_build(const srbm_index_t *idx, const double *G,
                      const double *M, const double *R,
                      const double *R_plus,
                      int d, int m, srbm_basis_t *bas);
void srbm_basis_free(srbm_basis_t *bas);

#endif /* SRBM_BASIS_H */
