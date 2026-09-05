/*
 * mc_srbm.h — Multi-class SRBM research prototype
 *
 * Research-grade improvements over the production SRBMExporter.swift:
 *   (1) Compound service-time aggregation: harmonic mean of rates, not
 *       arithmetic mean. Two-moment aggregation for service SCV.
 *   (2) Harrison-Reiman covariance Σ built from per-class routing variance
 *       (Dai 1990, §2.3; Harrison 1988, eq. (4.6)).
 *   (3) Per-class post-processing: E[X^c_i], W^c_i, T^c_i via class visit
 *       ratios.
 *
 * State remains d-dimensional (one per station); per-class dynamics are
 * reflected in the PDE coefficients (θ, Σ, R) rather than in the state.
 * This is the tractable Harrison-Peterson workload-SRBM approach.
 */

#ifndef MC_SRBM_H
#define MC_SRBM_H

#include <stddef.h>

#define MC_MAX_DIM     8   /* max stations */
#define MC_MAX_CLASSES 8   /* max customer classes */
#define MC_NAME_LEN    64

/* Distribution kinds (must fit the set emitted by the GUI). */
typedef enum {
    DIST_EXPONENTIAL = 0,
    DIST_ERLANG,
    DIST_GAMMA,
    DIST_CONSTANT,
    DIST_UNIFORM,
    DIST_WEIBULL,
    DIST_LOGNORMAL,
    DIST_PARETO,
    DIST_POISSON,
    DIST_UNKNOWN
} MCDistKind;

typedef struct {
    MCDistKind kind;
    /* Parameter semantics depend on kind:
     *   EXPONENTIAL:   p0 = rate
     *   ERLANG:        p0 = k (shape),     p1 = rate
     *   GAMMA:         p0 = shape,         p1 = scale
     *   CONSTANT:      p0 = value
     *   UNIFORM:       p0 = min,           p1 = max
     *   WEIBULL:       p0 = shape,         p1 = scale
     *   LOGNORMAL:     p0 = mu,            p1 = sigma
     *   PARETO:        p0 = shape,         p1 = scale
     *   POISSON:       p0 = lambda  (treated as rate = lambda for an IAT stream)
     */
    double p0, p1, p2;
} MCDist;

/* Mean and SCV (c²) of a distribution. */
double mc_dist_mean(const MCDist *d);
double mc_dist_scv (const MCDist *d);

/* ─── Network representation (post-parse) ─────────────────────────────── */

typedef struct {
    char    name[MC_NAME_LEN];
    int     station_idx;                  /* 0..d-1, or -1 if no station */
    int     num_servers;                  /* s_i >= 1 */
    int     buffer_size;                  /* a_i (buffer slots) */
    int     infinite_buffer;              /* 1 if network is infinite-buffer */
    /* Per-class service distribution at this station. If a class has
     * default_service == 1, use `default_service_dist`; otherwise use
     * `service[class_idx]`. */
    int     default_service;              /* 1 = use default for all classes */
    MCDist  default_service_dist;
    MCDist  service[MC_MAX_CLASSES];
} MCStation;

typedef struct {
    int     class_idx;                    /* 0..K-1 */
    MCDist  arrival;                      /* interarrival-time distribution */
    int     entry_station;                /* which station this source feeds */
} MCSource;

/* Per-class routing matrix.  P[c][i][j] = P(class c at station i → j).
 * Absorbing state is implicitly "the sink": rows need NOT sum to 1;
 * the slack is routed out of the system. */
typedef struct MCNetwork {
    int         d;                               /* stations */
    int         K;                               /* customer classes */
    int         infinite_buffer;                 /* 1 = infinite buffers */
    MCStation   stations[MC_MAX_DIM];
    MCSource    sources[MC_MAX_CLASSES];
    double      P[MC_MAX_CLASSES][MC_MAX_DIM][MC_MAX_DIM];
} MCNetwork;

/* Parse a .bnet JSON file into MCNetwork.  Returns 0 on success, -1 on
 * failure (and writes a human-readable message to `errbuf`). */
int mc_parse_bnet(const char *path, MCNetwork *net,
                  char *errbuf, size_t errbuf_len);

/* ─── SRBM primitives ─────────────────────────────────────────────────── */

typedef struct {
    int d;                      /* stations */
    int K;                      /* classes */
    int infinite;               /* 1 = infinite buffers */

    /* Per-class primitives (for output / post-processing) */
    double lambda_ext[MC_MAX_CLASSES];                      /* per-class total external λ^c */
    double alpha_c[MC_MAX_CLASSES][MC_MAX_DIM];             /* α^c_i, per-class throughput */
    double mu_c[MC_MAX_CLASSES][MC_MAX_DIM];                /* μ^c_i */
    double scv_s_c[MC_MAX_CLASSES][MC_MAX_DIM];             /* service SCV per class */
    double scv_a_c[MC_MAX_CLASSES];                         /* external arrival SCV per class */

    /* Aggregated per-station primitives */
    double alpha[MC_MAX_DIM];                               /* α_i = Σ_c α^c_i */
    double mean_S[MC_MAX_DIM];                              /* E[S_i] = Σ_c π^c·(1/μ^c_i)  (compound) */
    double mean_S2[MC_MAX_DIM];                             /* E[S²_i] compound */
    double mu_eff[MC_MAX_DIM];                              /* 1 / E[S_i] */
    double scv_eff[MC_MAX_DIM];                             /* E[S²]/E[S]² - 1 */
    double scv_a[MC_MAX_DIM];                               /* merged arrival SCV at station i */

    int    num_servers[MC_MAX_DIM];                         /* s_i */
    double capacity[MC_MAX_DIM];                            /* c_i = s_i·μ_eff_i */

    /* Aggregated routing P_ij = Σ_c (α^c_i / α_i) · P^c_ij */
    double P[MC_MAX_DIM][MC_MAX_DIM];

    /* SRBM PDE coefficients */
    double theta[MC_MAX_DIM];                               /* drift */
    double Sigma[MC_MAX_DIM][MC_MAX_DIM];                   /* covariance */
    double a[MC_MAX_DIM];                                   /* buffer size / upper bound */
    double R[MC_MAX_DIM][2 * MC_MAX_DIM];                   /* reflection, d × 2d */
} MCParams;

/* Formula flavor: new (compound / per-class-variance) or legacy (the
 * arithmetic-mean-rate, weighted-mean-SCV, aggregated-routing-variance
 * formulas that ship in SRBMExporter.swift). */
typedef enum {
    MC_PARAM_FLAVOR_NEW    = 0,
    MC_PARAM_FLAVOR_LEGACY = 1,
} MCParamFlavor;

/* Compute MCParams from MCNetwork.  `flavor` selects which aggregation
 * formulas are used.  Returns 0 on success; -1 on failure (details in
 * errbuf).  */
int mc_params_build_flavor(const MCNetwork *net, MCParams *p,
                           MCParamFlavor flavor,
                           char *errbuf, size_t errbuf_len);

/* Convenience wrapper: MC_PARAM_FLAVOR_NEW. */
int mc_params_build(const MCNetwork *net, MCParams *p,
                    char *errbuf, size_t errbuf_len);

/* Dump MCParams in human-readable form to stdout for inspection. */
void mc_params_dump(const MCParams *p);

#endif /* MC_SRBM_H */
