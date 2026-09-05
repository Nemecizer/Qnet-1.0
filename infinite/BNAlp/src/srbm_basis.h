#ifndef SRBM_BASIS_H
#define SRBM_BASIS_H

#include "srbm_types.h"

/* Compute BAR coefficients for the polynomial basis.
 * Translation of Basis.m.
 *
 * bas->data is [n_basis * n_basis * (d+1)] with layout:
 *   data[i * n_basis*(d+1) + j*(d+1) + h]
 * where h=0 is interior (Gf), h=1..d is boundary face h (D_h f).
 */
void srbm_basis_build(const srbm_index_t *idx, const double *G,
                      const double *M, const double *R,
                      int d, int m, srbm_basis_t *bas);
void srbm_basis_free(srbm_basis_t *bas);

#endif /* SRBM_BASIS_H */
