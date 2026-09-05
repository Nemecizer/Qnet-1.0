/* mc_adapter.c — Map MCParams (multi-class research params) into a
 * BNAParams struct accepted by the ported FEM solver (mc_fem_gauss.c).
 *
 * The FEM solver itself is structurally single-class; the multi-class
 * research contribution is entirely in how we derive theta, Sigma, R.
 * The BNAParams struct also carries per-class statistics for post-
 * processing (cc_alpha, cc_lambda, cc_mu), which we fill so the solver
 * can emit per-class W_total, T_total, N_total lines.
 */

#include "bna_fm.h"
#include "mc_srbm.h"
#include "mc_fem.h"

#include <string.h>

void mc_params_to_bnaparams(const MCParams *src, BNAParams *dst, int mesh_n)
{
    memset(dst, 0, sizeof(*dst));
    dst->K = src->d;                     /* note: BNAParams.K means dimension */

    for (int i = 0; i < src->d; i++) {
        dst->theta[i] = src->theta[i];
        dst->lb[i] = 0.0;
        dst->ub[i] = src->a[i];
        dst->mesh_n[i] = mesh_n;
        dst->h[i] = (dst->ub[i] - dst->lb[i]) / (double)mesh_n;
        dst->service_rates[i] = src->mu_eff[i];
        for (int j = 0; j < src->d; j++) dst->Gamma[i][j] = src->Sigma[i][j];
        for (int k = 0; k < 2 * src->d; k++) dst->R[i][k] = src->R[i][k];
    }
    dst->has_service_rates = 1;

    /* Per-class data for post-processing.
     * BNAParams.cc_lambda[k]     = total external arrival rate of class k
     * BNAParams.cc_alpha[k][i]   = class-k throughput at station i
     * BNAParams.cc_mu[k][i]      = per-class service rate at station i
     * BNAParams.cc_alpha_total[i] not used by the solver directly.
     */
    dst->cc_num_classes = src->K;
    for (int c = 0; c < src->K; c++) {
        dst->cc_lambda[c] = src->lambda_ext[c];
        for (int i = 0; i < src->d; i++) {
            dst->cc_alpha[c][i] = src->alpha_c[c][i];
            dst->cc_mu[c][i]    = src->mu_c[c][i];
        }
    }
    for (int i = 0; i < src->d; i++) dst->cc_alpha_total[i] = src->alpha[i];
}
