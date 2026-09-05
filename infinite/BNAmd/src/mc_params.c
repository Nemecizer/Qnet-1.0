/* mc_params.c — Multi-class SRBM parameter computation.
 *
 * This is the research contribution of the experiment.  Compared with the
 * production SRBMExporter.swift we:
 *
 *   (1) Use the compound service-time formula, not weighted-mean-of-rates:
 *         E[S_i]  = Σ_c π^c_i · E[S^c_i]
 *         E[S²_i] = Σ_c π^c_i · E[S^c_i]² · (1 + SCV^c_i)
 *         μ_eff_i = 1 / E[S_i]                              ← harmonic mean
 *         SCV_eff_i = E[S²_i] / E[S_i]² − 1                 ← compound variance
 *       The production formula μ_eff = Σ_c π^c μ^c (arithmetic mean of rates)
 *       is strictly larger than the correct 1/E[S], so it *over-states*
 *       capacity when classes have different service means.  The effect
 *       compounds upstream.
 *
 *   (2) Build Σ from the Reiman-Williams / Dai decomposition using per-class
 *       primitives throughout:
 *         Σ = A + (I − P^T)·diag(B)·(I − P) + Σ_routing
 *       where
 *         A_ii     = Σ_c α^c_ext,i · SCV^c_a_i     (ext-arrival renewal variance)
 *         B_ii     = α_i · SCV_eff_i               (service process variance using
 *                                                   compound SCV, not averaged)
 *         Σ_routing_ij = Σ_c Σ_k α^c_k · P^c_ki · (δ_ij − P^c_kj)
 *              (per-class multinomial routing variance — the production code
 *              aggregates P first and loses the per-class correlation term)
 *
 *   (3) Reflection matrix R unchanged from production (d-dim workload-SRBM
 *       reflection is already correctly single-class; blocking mass is
 *       aggregated by throughput-weighted class mix at the boundary, which
 *       is the same formula in both implementations).
 *
 * The state remains d-dimensional; per-class statistics are extracted in
 * post-processing via class visit ratios.
 */

#include "mc_srbm.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#define ERRLOG(...) do { if (errbuf) snprintf(errbuf, errbuf_len, __VA_ARGS__); } while(0)

/* ─── Linear algebra helpers (small, K ≤ 8 × d ≤ 8) ───────────────── */

/* Solve  (I − A^T) x = b   for x, where A is d×d.  Uses plain Gauss
 * elimination — our matrices are tiny. */
static int solve_traffic_eq(const double A[MC_MAX_DIM][MC_MAX_DIM],
                            const double b[MC_MAX_DIM],
                            double x[MC_MAX_DIM], int d)
{
    double M[MC_MAX_DIM][MC_MAX_DIM + 1];
    for (int i = 0; i < d; i++) {
        for (int j = 0; j < d; j++)
            M[i][j] = (i == j ? 1.0 : 0.0) - A[j][i];   /* (I − A^T) */
        M[i][d] = b[i];
    }
    for (int k = 0; k < d; k++) {
        /* partial pivot */
        int piv = k;
        double best = fabs(M[k][k]);
        for (int r = k + 1; r < d; r++) {
            if (fabs(M[r][k]) > best) { best = fabs(M[r][k]); piv = r; }
        }
        if (best < 1e-14) return -1;
        if (piv != k) {
            for (int j = 0; j <= d; j++) {
                double t = M[k][j]; M[k][j] = M[piv][j]; M[piv][j] = t;
            }
        }
        for (int r = k + 1; r < d; r++) {
            double m = M[r][k] / M[k][k];
            for (int j = k; j <= d; j++) M[r][j] -= m * M[k][j];
        }
    }
    for (int i = d - 1; i >= 0; i--) {
        double s = M[i][d];
        for (int j = i + 1; j < d; j++) s -= M[i][j] * x[j];
        x[i] = s / M[i][i];
    }
    return 0;
}

/* ─── Core: build all MCParams from MCNetwork ────────────────────────── */

int mc_params_build(const MCNetwork *net, MCParams *p,
                    char *errbuf, size_t errbuf_len)
{
    return mc_params_build_flavor(net, p, MC_PARAM_FLAVOR_NEW, errbuf, errbuf_len);
}

int mc_params_build_flavor(const MCNetwork *net, MCParams *p,
                           MCParamFlavor flavor,
                           char *errbuf, size_t errbuf_len)
{
    memset(p, 0, sizeof(*p));
    p->d = net->d;
    p->K = net->K;
    p->infinite = net->infinite_buffer;

    /* ─── Per-class primitives: λ^c_ext (at entry station), μ^c_i, SCVs ── */
    double lambda_ext_per_station[MC_MAX_CLASSES][MC_MAX_DIM] = {{0}};
    for (int c = 0; c < net->K; c++) {
        const MCSource *sr = &net->sources[c];
        double rate = 1.0 / mc_dist_mean(&sr->arrival);
        lambda_ext_per_station[c][sr->entry_station] = rate;
        p->lambda_ext[c] = rate;
        p->scv_a_c[c] = mc_dist_scv(&sr->arrival);
    }

    for (int c = 0; c < net->K; c++) {
        for (int i = 0; i < net->d; i++) {
            const MCStation *st = &net->stations[i];
            const MCDist    *d  = st->default_service ? &st->default_service_dist : &st->service[c];
            double mean_S_ci = mc_dist_mean(d);
            p->mu_c [c][i] = (mean_S_ci > 0) ? 1.0 / mean_S_ci : 0.0;
            p->scv_s_c[c][i] = mc_dist_scv(d);
        }
    }

    /* ─── Per-class traffic equations: α^c = (I − (P^c)^T)^-1 · λ^c ────── */
    for (int c = 0; c < net->K; c++) {
        double A[MC_MAX_DIM][MC_MAX_DIM];
        double b[MC_MAX_DIM];
        for (int i = 0; i < net->d; i++) {
            b[i] = lambda_ext_per_station[c][i];
            for (int j = 0; j < net->d; j++) A[i][j] = net->P[c][i][j];
        }
        double alpha_c[MC_MAX_DIM];
        if (solve_traffic_eq(A, b, alpha_c, net->d) != 0) {
            ERRLOG("class %d traffic equations are singular", c + 1);
            return -1;
        }
        for (int i = 0; i < net->d; i++) {
            p->alpha_c[c][i] = alpha_c[i];
        }
    }

    /* Aggregate throughput per station. */
    for (int i = 0; i < net->d; i++) {
        double s = 0.0;
        for (int c = 0; c < net->K; c++) s += p->alpha_c[c][i];
        p->alpha[i] = s;
    }

    /* ─── Service-time aggregation per station ────────────────────────
     * NEW flavor: compound formula (harmonic mean of rates for μ_eff,
     *             compound-variance formula for SCV_eff).  Correct when
     *             classes have different service-time means.
     * LEGACY flavor: arithmetic mean of rates; weighted mean of SCVs.
     *                Matches SRBMExporter.swift. */
    for (int i = 0; i < net->d; i++) {
        double ES = 0.0, ES2 = 0.0;
        double mu_leg = 0.0, scv_leg = 0.0;
        if (p->alpha[i] > 0) {
            for (int c = 0; c < net->K; c++) {
                double pi_ci = p->alpha_c[c][i] / p->alpha[i];
                if (p->mu_c[c][i] <= 0) continue;
                double mean_c = 1.0 / p->mu_c[c][i];
                double second_c = mean_c * mean_c * (1.0 + p->scv_s_c[c][i]);
                ES      += pi_ci * mean_c;
                ES2     += pi_ci * second_c;
                mu_leg  += pi_ci * p->mu_c[c][i];
                scv_leg += pi_ci * p->scv_s_c[c][i];
            }
        } else {
            double mean0 = 1.0 / (p->mu_c[0][i] > 0 ? p->mu_c[0][i] : 1.0);
            ES  = mean0;
            ES2 = mean0 * mean0 * (1.0 + p->scv_s_c[0][i]);
            mu_leg  = p->mu_c[0][i] > 0 ? p->mu_c[0][i] : 1.0;
            scv_leg = p->scv_s_c[0][i];
        }
        p->mean_S [i] = ES;
        p->mean_S2[i] = ES2;
        if (flavor == MC_PARAM_FLAVOR_NEW) {
            p->mu_eff [i] = (ES > 0) ? 1.0 / ES : 0.0;
            p->scv_eff[i] = (ES > 0) ? ES2 / (ES * ES) - 1.0 : 0.0;
        } else {
            p->mu_eff [i] = mu_leg;                    /* arithmetic mean */
            p->scv_eff[i] = scv_leg;                   /* weighted mean   */
        }
        if (p->scv_eff[i] < 0) p->scv_eff[i] = 0;
        p->num_servers[i] = net->stations[i].num_servers;
        p->capacity[i] = (double)p->num_servers[i] * p->mu_eff[i];
    }

    /* Upper bounds — buffer sizes. */
    for (int i = 0; i < net->d; i++) {
        p->a[i] = (double)net->stations[i].buffer_size;
    }

    /* ─── Aggregated arrival SCV at each station.
     *
     * At station i, the input stream is a superposition of renewal processes:
     *   — external arrivals of each class c that enters here (sources[c].entry_station = i)
     *   — departures from each station j routed here: P^c_ji · (α^c_j / α_j) of j's departures
     *
     * For the superposition of independent renewal processes (Whitt 1982),
     * the aggregate SCV is the rate-weighted mean of component SCVs. For
     * internal flows we approximate the departure SCV via the Kingman/Whitt
     * formula c²_d = ρ² · c²_s + (1 − ρ²) · c²_a  (per Harrison 1988 §4). */

    /* Compute ρ_i = α_i / (s_i · μ_eff_i) */
    double rho[MC_MAX_DIM];
    for (int i = 0; i < net->d; i++) {
        rho[i] = (p->capacity[i] > 0) ? p->alpha[i] / p->capacity[i] : 0.0;
    }

    /* Approximate the departure SCV at each station using two-moment
     * approximation.  This is an iterative but fast formula per Whitt. */
    double c2_d[MC_MAX_DIM];   /* departure SCV */
    double c2_a[MC_MAX_DIM];   /* aggregate arrival SCV */
    /* Initialize with external contribution only, then iterate. */
    for (int i = 0; i < net->d; i++) {
        double rate_sum = 0.0, scv_sum = 0.0;
        for (int c = 0; c < net->K; c++) {
            if (net->sources[c].entry_station == i) {
                rate_sum += p->lambda_ext[c];
                scv_sum  += p->lambda_ext[c] * p->scv_a_c[c];
            }
        }
        c2_a[i] = (rate_sum > 0) ? scv_sum / rate_sum : 1.0;
        c2_d[i] = c2_a[i];
    }
    /* Fixed-point iteration (8 sweeps is more than enough for convergence). */
    for (int iter = 0; iter < 8; iter++) {
        double new_c2_a[MC_MAX_DIM] = {0};
        double new_c2_d[MC_MAX_DIM] = {0};
        /* departure SCV */
        for (int i = 0; i < net->d; i++) {
            new_c2_d[i] = rho[i] * rho[i] * p->scv_eff[i] +
                          (1.0 - rho[i] * rho[i]) * c2_a[i];
            if (new_c2_d[i] < 0) new_c2_d[i] = 0;
        }
        /* new arrival SCV as superposition of external + internal */
        for (int i = 0; i < net->d; i++) {
            double rate_sum = 0.0, scv_sum = 0.0;
            /* external */
            for (int c = 0; c < net->K; c++) {
                if (net->sources[c].entry_station == i) {
                    rate_sum += p->lambda_ext[c];
                    scv_sum  += p->lambda_ext[c] * p->scv_a_c[c];
                }
            }
            /* internal: flow from every station j to i */
            for (int j = 0; j < net->d; j++) {
                for (int c = 0; c < net->K; c++) {
                    double flow = p->alpha_c[c][j] * net->P[c][j][i];
                    if (flow > 0) {
                        rate_sum += flow;
                        scv_sum  += flow * new_c2_d[j];
                    }
                }
            }
            new_c2_a[i] = (rate_sum > 0) ? scv_sum / rate_sum : 1.0;
        }
        for (int i = 0; i < net->d; i++) {
            c2_a[i] = new_c2_a[i];
            c2_d[i] = new_c2_d[i];
        }
    }
    for (int i = 0; i < net->d; i++) p->scv_a[i] = c2_a[i];

    /* ─── Aggregated routing matrix (throughput-weighted, per station i) ── */
    for (int i = 0; i < net->d; i++) {
        for (int j = 0; j < net->d; j++) {
            double s = 0.0;
            if (p->alpha[i] > 0) {
                for (int c = 0; c < net->K; c++) {
                    s += (p->alpha_c[c][i] / p->alpha[i]) * net->P[c][i][j];
                }
            }
            p->P[i][j] = s;
        }
    }

    /* ─── Drift θ_i = α_i − c_i ───────────────────────────────────────── */
    for (int i = 0; i < net->d; i++) {
        p->theta[i] = p->alpha[i] - p->capacity[i];
    }

    /* ─── Covariance matrix Σ with per-class routing variance ─────────── */
    double A[MC_MAX_DIM][MC_MAX_DIM]       = {{0}};
    double B_diag[MC_MAX_DIM]              =  {0};
    double Sig_rt[MC_MAX_DIM][MC_MAX_DIM]  = {{0}};

    /* A_ii = Σ_c λ^c · SCV^c_a, aggregated arrival variance at the entry face */
    for (int i = 0; i < net->d; i++) {
        for (int c = 0; c < net->K; c++) {
            if (net->sources[c].entry_station == i) {
                A[i][i] += p->lambda_ext[c] * p->scv_a_c[c];
            }
        }
    }

    /* Service variance diagonal: B_i = α_i · SCV_eff_i */
    for (int i = 0; i < net->d; i++) {
        B_diag[i] = p->alpha[i] * p->scv_eff[i];
    }

    /* Routing-variance contribution to Σ.
     *
     * NEW:    per-class multinomial variance (Dai 1990 §2.3):
     *           Σ_rt_ij = Σ_c Σ_k α^c_k · P^c_ki · (δ_ij − P^c_kj)
     *         — keeps per-class correlation between rows k → (i,j).
     *
     * LEGACY: aggregated-routing version (SRBMExporter.swift):
     *           Σ_rt_ij = Σ_k α_k · P_ki · (δ_ij − P_kj)
     *         — loses per-class correlation when classes have different
     *         routings P^c_k*. */
    for (int i = 0; i < net->d; i++) {
        for (int j = 0; j < net->d; j++) {
            double s = 0.0;
            double delta_ij = (i == j ? 1.0 : 0.0);
            if (flavor == MC_PARAM_FLAVOR_NEW) {
                for (int k = 0; k < net->d; k++) {
                    for (int c = 0; c < net->K; c++) {
                        double Pki = net->P[c][k][i];
                        if (Pki == 0.0) continue;
                        s += p->alpha_c[c][k] * Pki * (delta_ij - net->P[c][k][j]);
                    }
                }
            } else {
                for (int k = 0; k < net->d; k++) {
                    double Pki = p->P[k][i];
                    if (Pki == 0.0) continue;
                    s += p->alpha[k] * Pki * (delta_ij - p->P[k][j]);
                }
            }
            Sig_rt[i][j] = s;
        }
    }

    /* Build Σ = A + (I − P^T) diag(B) (I − P) + Σ_routing
     *   ("term1" is the (I-P^T) B (I-P) piece) */
    double term1[MC_MAX_DIM][MC_MAX_DIM] = {{0}};
    for (int i = 0; i < net->d; i++) {
        for (int j = 0; j < net->d; j++) {
            double s = 0.0;
            for (int k = 0; k < net->d; k++) {
                double IPT_ik = (i == k ? 1.0 : 0.0) - p->P[k][i];
                double IP_kj  = (k == j ? 1.0 : 0.0) - p->P[k][j];
                s += IPT_ik * B_diag[k] * IP_kj;
            }
            term1[i][j] = s;
        }
    }

    for (int i = 0; i < net->d; i++) {
        for (int j = 0; j < net->d; j++) {
            p->Sigma[i][j] = A[i][j] + term1[i][j] + Sig_rt[i][j];
        }
    }

    /* Symmetrize to cancel round-off. */
    for (int i = 0; i < net->d; i++) {
        for (int j = i + 1; j < net->d; j++) {
            double avg = 0.5 * (p->Sigma[i][j] + p->Sigma[j][i]);
            p->Sigma[i][j] = p->Sigma[j][i] = avg;
        }
    }

    /* ─── Reflection matrix ────────────────────────────────────────────── */
    /* Column ordering: GROUPED — [lower_0, lower_1, ..., upper_0, upper_1, ...]
     * This matches the FEM solver convention (bna_fm_gauss.c indexes
     * columns 0..d-1 as lower faces, d..2d-1 as upper faces).
     *
     * Infinite-buffer (Harrison-Reiman orthant SRBM):
     *   lower_k column = (I − Pᵀ)_{:,k}   (Dai 1990 eq. 2.6; Harrison 1988)
     *   upper_k column = −e_k (truncation wall; mass at upper face ≈ 0)
     *
     * Finite-buffer (manufacturing blocking):
     *   lower_k column = e_k       (idle server; work just accumulates)
     *   upper_k column = −e_k + Σ_i P_{i,k} e_i  (blocked predecessors) */
    for (int k = 0; k < net->d; k++) {
        int colLo = k;
        int colHi = net->d + k;
        if (p->infinite) {
            for (int i = 0; i < net->d; i++)
                p->R[i][colLo] = ((i == k) ? 1.0 : 0.0) - p->P[k][i];
            for (int i = 0; i < net->d; i++)
                p->R[i][colHi] = (i == k) ? -1.0 : 0.0;
        } else {
            for (int i = 0; i < net->d; i++)
                p->R[i][colLo] = (i == k) ? 1.0 : 0.0;
            for (int i = 0; i < net->d; i++)
                p->R[i][colHi] = ((i == k) ? -1.0 : 0.0) + p->P[i][k];
        }
    }

    return 0;
}

/* ─── Debug dump ──────────────────────────────────────────────────────── */
void mc_params_dump(const MCParams *p)
{
    printf("───── MCParams ─────\n");
    printf("d = %d    K = %d    infinite=%d\n", p->d, p->K, p->infinite);
    printf("\nPer-class external arrival rates λ^c:\n");
    for (int c = 0; c < p->K; c++)
        printf("  class %d:   λ = %.6f   c²_a = %.6f\n",
               c + 1, p->lambda_ext[c], p->scv_a_c[c]);

    printf("\nPer-class throughput α^c_i (rows = class, cols = station):\n");
    for (int c = 0; c < p->K; c++) {
        printf("  c=%d:", c + 1);
        for (int i = 0; i < p->d; i++) printf("  %8.4f", p->alpha_c[c][i]);
        printf("\n");
    }

    printf("\nAggregated per-station primitives:\n");
    printf("    i  servers   α_i     E[S_i]   E[S²_i]    μ_eff   SCV_eff   c²_a_agg   θ_i=α-c    a_i\n");
    for (int i = 0; i < p->d; i++) {
        double ci = p->capacity[i];
        double rho = (ci > 0) ? p->alpha[i] / ci : 0.0;
        printf("  %3d   %3d   %8.4f  %8.4f  %8.4f  %8.4f  %8.4f  %8.4f  %+8.4f  %6.1f   (ρ=%.3f)\n",
               i + 1, p->num_servers[i], p->alpha[i], p->mean_S[i], p->mean_S2[i],
               p->mu_eff[i], p->scv_eff[i], p->scv_a[i], p->theta[i], p->a[i], rho);
    }

    printf("\nAggregated routing P (row i → col j):\n");
    for (int i = 0; i < p->d; i++) {
        printf("   ");
        for (int j = 0; j < p->d; j++) printf("  %7.4f", p->P[i][j]);
        printf("\n");
    }

    printf("\nCovariance matrix Σ:\n");
    for (int i = 0; i < p->d; i++) {
        printf("   ");
        for (int j = 0; j < p->d; j++) printf("  %9.4f", p->Sigma[i][j]);
        printf("\n");
    }

    printf("\nReflection matrix R (rows = station, cols = face [lo_0, ..., lo_{d-1}, hi_0, ..., hi_{d-1}]):\n");
    for (int i = 0; i < p->d; i++) {
        printf("   ");
        for (int k = 0; k < 2 * p->d; k++) printf("  %+6.3f", p->R[i][k]);
        printf("\n");
    }
    printf("────────────────────\n");
}
