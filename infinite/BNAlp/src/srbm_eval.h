#ifndef SRBM_EVAL_H
#define SRBM_EVAL_H

#include "srbm_types.h"

/* Evaluate interior BAR terms (Valuating.m):
 * V[j * n_basis + i] = sum of BAR interior contributions at grid point j
 * for basis function i.
 * V is [npoints * n_basis], allocated by caller. */
void srbm_eval_interior(const srbm_index_t *idx, const srbm_basis_t *bas,
                        const srbm_grid_t *grid, double *V);

/* Evaluate boundary BAR terms (Daluating.m):
 * D[h] is [bdy_count[h] * n_basis] for face h=0..d-1.
 * Arrays D[h] allocated by caller. */
void srbm_eval_boundary(const srbm_index_t *idx, const srbm_basis_t *bas,
                        const srbm_grid_t *grid, double **D);

#endif /* SRBM_EVAL_H */
