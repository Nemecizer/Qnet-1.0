/* mc_fem.h — FEM solver library entry point. */

#ifndef MC_FEM_H
#define MC_FEM_H

#include "bna_fm.h"
#include "mc_srbm.h"

/* Run the full FEM solve on a prepared BNAParams.
 *   output_format = 0 → verbose, 1 → compact, 2 → GUI (-G-style)
 */
int mc_fem_run(BNAParams *params, int output_format);

/* Convert MCParams → BNAParams so the solver can consume it. */
void mc_params_to_bnaparams(const MCParams *src, BNAParams *dst, int mesh_n);

#endif /* MC_FEM_H */
