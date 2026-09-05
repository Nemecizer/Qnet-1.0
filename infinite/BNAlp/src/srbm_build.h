#ifndef SRBM_BUILD_H
#define SRBM_BUILD_H

#include "srbm_types.h"

/* Assemble the LP(n,m) in CSC format from interior/boundary evaluations.
 * Translation of Build.m.
 *
 * Inputs:
 *   V       – interior evaluations [npoints * n_basis]
 *   D       – boundary evaluations D[h] is [bdy_count[h] * n_basis] for h=0..d-1
 *   grid    – grid structure (contains P, bdy_count, etc.)
 *   d       – dimension
 *   n_basis – number of basis functions
 *   K       – tightness/finiteness bounds [2*d+1]
 *
 * Output:
 *   lp      – filled LP structure (caller must free with srbm_lp_free)
 */
void srbm_build_lp(const double *V, double **D,
                   const srbm_grid_t *grid, int d, int n_basis,
                   const double *K, double smoothness_weight,
                   int grid_n, int grid_type, srbm_lp_t *lp);

void srbm_lp_free(srbm_lp_t *lp);

#endif /* SRBM_BUILD_H */
