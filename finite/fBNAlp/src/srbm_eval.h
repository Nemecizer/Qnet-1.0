#ifndef SRBM_EVAL_H
#define SRBM_EVAL_H

#include "srbm_types.h"

/* Interior BAR evaluation. V[j*n_basis + i] is the contribution at grid
 * point j for test function i. Allocated by caller as [npoints*n_basis]. */
void srbm_eval_interior(const srbm_index_t *idx, const srbm_basis_t *bas,
                        const srbm_grid_t *grid, double *V);

/* Boundary BAR evaluation for both lower (xᵢ = 0) and upper (xᵢ = bᵢ)
 * faces. The caller pre-allocates D_minus[h] and D_plus[h] each as
 * [bdy_*_count[h] * n_basis]. */
void srbm_eval_boundary(const srbm_index_t *idx, const srbm_basis_t *bas,
                        const srbm_grid_t *grid,
                        double **D_minus, double **D_plus);

#endif /* SRBM_EVAL_H */
