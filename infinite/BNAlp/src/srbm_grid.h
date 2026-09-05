#ifndef SRBM_GRID_H
#define SRBM_GRID_H

#include "srbm_types.h"

/* Generate the approximating grid.
 * grid_type: 0 = exponential (ExpGrid), 1 = dyadic (DyaGrid), 2 = exprandom (ExpRanGrid)
 * mu_grid: spacing parameter (used for exponential grids)
 */
void srbm_grid_build(int d, int n, int grid_type, const double *mu_grid,
                     srbm_grid_t *grid);
void srbm_grid_free(srbm_grid_t *grid);

#endif /* SRBM_GRID_H */
