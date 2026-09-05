#ifndef SRBM_BUILD_H
#define SRBM_BUILD_H

#include "srbm_types.h"

/* Assemble the LP in CSC format for the rectangle case.
 *
 * Inputs:
 *   V        — interior evaluations  [npoints * n_basis]
 *   D_minus  — lower-face evaluations, D_minus[h] is [bdy_minus_count[h]*n_basis]
 *   D_plus   — upper-face evaluations, D_plus[h]  is [bdy_plus_count[h]*n_basis]
 *   grid     — tensor grid + face index lists
 *   d        — dimension
 *   n_basis  — number of test functions
 *   K        — tightness vector of length (4*d + 1):
 *                K[0..d-1]            face finiteness, lower
 *                K[d..2d-1]           face finiteness, upper
 *                K[2d]                interior tightness
 *                K[2d+1..3d]          face tightness, lower
 *                K[3d+1..4d]          face tightness, upper
 *
 * Output:
 *   lp       — filled LP structure (caller must free with srbm_lp_free).
 */
void srbm_build_lp(const double *V, double **D_minus, double **D_plus,
                   const srbm_grid_t *grid, int d, int n_basis,
                   const double *K, double smoothness_weight,
                   int grid_n, int grid_type, srbm_lp_t *lp);

void srbm_lp_free(srbm_lp_t *lp);

#endif /* SRBM_BUILD_H */
