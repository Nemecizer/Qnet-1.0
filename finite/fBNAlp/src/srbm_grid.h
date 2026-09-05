#ifndef SRBM_GRID_H
#define SRBM_GRID_H

#include "srbm_types.h"

/* Build a tensor grid on the box [0, b_upper[0]] × … × [0, b_upper[d-1]]
 * and populate per-face index lists for both the lower (xᵢ = 0) and upper
 * (xᵢ = bᵢ) boundaries. Each face holds n^(d-1) points by construction.
 *
 *   grid_type: 0 = uniform, 1 = chebyshev (reserved — currently uniform).
 */
void srbm_grid_build(int d, int n, int grid_type, const double *b_upper,
                     srbm_grid_t *grid);
void srbm_grid_free(srbm_grid_t *grid);

#endif /* SRBM_GRID_H */
