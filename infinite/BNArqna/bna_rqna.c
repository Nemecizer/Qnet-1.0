/*
 * bna_rqna.c  --  Robust Queueing Network Analyzer (RQNA)
 *
 * Index-of-Dispersion–based parametric decomposition for open
 * queueing networks. Replaces QNA's scalar c² per stream with the
 * Index of Dispersion for Counts I(t) = Var(N(t))/E(N(t)) evaluated
 * at a discrete grid of timescales, capturing temporal correlation
 * that two-moment approximations miss.
 *
 * Reference:
 *   W. Whitt and W. You, "A Robust Queueing Network Analyzer Based
 *   on Indices of Dispersion," Naval Research Logistics, 69(1):36-56,
 *   2022. arXiv:2003.11174.
 *
 * Status: Phase 3c — full Whitt-You §3.3 IDC propagation rules
 * including the α correction for splitting under feedback (eq. 25)
 * and the β correction for superposition with shared origins
 * (eqs. 27-30) + RQ wait formula (eq. 12). Per-class IDC propagation
 * deferred to Phase 3d.
 *
 * Usage:
 *   bna_rqna <input_file> [-c]    analyze a .qna network
 *   bna_rqna --selftest            run IDC primitive self-tests
 *
 * Build:
 *   gcc -Wall -O2 -std=c99 -pedantic -o bna_rqna bna_rqna.c -lm
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#define MAX_NODES  64
#define LINE_BUF   4096
#define NUM_SCALES 20

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/* ================================================================
 *  IDC infrastructure
 * ================================================================
 *
 * Each stream is characterized by I(t) sampled on a fixed
 * logarithmic grid of NUM_SCALES timescales. The grid is set
 * relative to a reference scale (typically the network mean
 * service time), spanning 10^-2.5 to 10^2 of that reference.
 * That covers the four orders of magnitude in t/E[S] over which
 * the Whitt-You GI/G/1 fixed-point iteration searches for the
 * self-consistent t* = E[W]/E[S]. */

typedef struct {
    double t[NUM_SCALES];   /* timescale grid */
    double v[NUM_SCALES];   /* I(t_k) values  */
} Idc;

/* Initialize I->t to a log-spaced grid relative to t_ref; clear values. */
static void idc_init_grid(Idc *I, double t_ref)
{
    int k;
    /* Log-spaced grid spanning 10^-2.5 to 10^+2 (4.5 decades) of t_ref,
     * with NUM_SCALES sample points. Step = 4.5/(NUM_SCALES-1). */
    double e_lo = -2.5, e_hi = 2.0;
    double de = (NUM_SCALES > 1)
              ? (e_hi - e_lo) / (double)(NUM_SCALES - 1)
              : 0.0;
    for (k = 0; k < NUM_SCALES; k++) {
        double e = e_lo + de * (double)k;
        I->t[k] = t_ref * pow(10.0, e);
        I->v[k] = 0.0;
    }
}

/* Set I->v to a constant c at every timescale (preserves grid). */
static void idc_set_const(Idc *I, double c)
{
    int k;
    for (k = 0; k < NUM_SCALES; k++) I->v[k] = c;
}

/* ----------------------------------------------------------------
 *  Closed-form IDCs for standard arrival/service distributions.
 *  Caller is responsible for initializing the grid first via
 *  idc_init_grid().
 * ----------------------------------------------------------------
 *
 *  All "renewal" distributions below produce a constant IDC equal
 *  to the squared coefficient of variation c²; this is the
 *  Whitt-You §2.2 default for renewal processes characterized by
 *  two moments. The richer non-constant variation in I(t) comes
 *  from non-renewal processes (e.g. MMPP) and from departure
 *  streams (Phase 2). */

/* Poisson(λ): I(t) ≡ 1 exactly. */
static void idc_poisson(Idc *I)
{
    idc_set_const(I, 1.0);
}

/* Deterministic inter-arrival (D): equilibrium renewal IDC → 0.
 * Var(N(t)) is bounded (≤ 1/4) so I(t) → 0 as t → ∞. We use 0
 * as the renewal-asymptote approximation for all timescales. */
static void idc_deterministic(Idc *I)
{
    idc_set_const(I, 0.0);
}

/* Renewal arrival characterized by mean and SCV c²: I(t) ≡ c².
 * This is the workhorse when only two-moment data is available
 * from the input format (which is the case for .qna). */
static void idc_renewal_c2(Idc *I, double c2)
{
    idc_set_const(I, c2);
}

/* Erlang-k (sum of k iid exp): c² = 1/k. Renewal asymptote 1/k. */
static void idc_erlang(Idc *I, int k)
{
    if (k < 1) k = 1;
    idc_set_const(I, 1.0 / (double)k);
}

/* Hyperexponential-2: with prob p inter-arrival ~ Exp(μ₁), with prob
 * 1−p ~ Exp(μ₂). Computes c² from (p, μ₁, μ₂) and uses the renewal
 * asymptote.
 *   E[X]  = p/μ₁ + (1−p)/μ₂
 *   E[X²] = 2(p/μ₁² + (1−p)/μ₂²)
 *   c²    = E[X²]/E[X]² − 1
 */
static void idc_hyperexp2(Idc *I, double p, double mu1, double mu2)
{
    double mean = p / mu1 + (1.0 - p) / mu2;
    double sec  = 2.0 * (p / (mu1 * mu1) + (1.0 - p) / (mu2 * mu2));
    double c2   = sec / (mean * mean) - 1.0;
    idc_set_const(I, c2);
}

/* Lognormal(μ_log, σ²_log) inter-arrival: c² = exp(σ²) − 1.
 * Renewal asymptote at all timescales. */
static void idc_lognormal(Idc *I, double sigma2_log)
{
    double c2 = exp(sigma2_log) - 1.0;
    idc_set_const(I, c2);
}

/* Two-state MMPP with rates (λ₁, λ₂) in states (1, 2) and exit
 * rates (q₁, q₂) — i.e. infinitesimal generator
 *      Q = [[-q₁,  q₁],
 *           [ q₂, -q₂]].
 *
 * Closed-form variance-time function (Heffes-Lucantoni 1986):
 *   λ̄        = (q₂ λ₁ + q₁ λ₂) / (q₁ + q₂)
 *   E[N(t)]  = λ̄ t
 *   Var(N(t))= λ̄ t + 2 (λ₁ − λ₂)² q₁ q₂ / (q₁ + q₂)³
 *              · [t − (1 − e^(−(q₁+q₂)t)) / (q₁+q₂)]
 *
 * Therefore
 *   I(t) = 1 + 2(λ₁−λ₂)² q₁q₂ / (λ̄ (q₁+q₂)³)
 *          · [1 − (1 − e^(−(q₁+q₂)t)) / ((q₁+q₂) t)]
 *
 * I(0+) = 1 (Poisson-like at small t — no transitions yet),
 * I(∞)  = 1 + 2(λ₁−λ₂)² q₁q₂ / (λ̄ (q₁+q₂)³).
 *
 * This is the cleanest non-trivial (truly time-varying) IDC and the
 * primary self-test target for non-renewal processes. */
static void idc_mmpp2(Idc *I,
                      double lam1, double lam2,
                      double q1,   double q2)
{
    double qsum = q1 + q2;
    double lambar = (q2 * lam1 + q1 * lam2) / qsum;
    double pref = 2.0 * (lam1 - lam2) * (lam1 - lam2) * q1 * q2
                  / (lambar * qsum * qsum * qsum);
    int k;
    for (k = 0; k < NUM_SCALES; k++) {
        double t = I->t[k];
        double et = (qsum * t < 1e-12)
                    ? 0.0   /* avoid 0/0; bracket → 0 as t → 0 */
                    : 1.0 - (1.0 - exp(-qsum * t)) / (qsum * t);
        I->v[k] = 1.0 + pref * et;
    }
}

/* ================================================================
 *  IDC propagation rules (Whitt-You §3)
 * ================================================================
 *
 *  All three rules act pointwise in t — they combine IDC values at
 *  each timescale independently. This is the structural property
 *  that makes the network-level fixed point a sequence of NUM_SCALES
 *  independent linear systems (one per timescale), instead of a
 *  coupled-across-timescales nonlinear iteration. */

/* Superposition of K independent renewal-or-non streams with rates
 * lambdas[k] and IDCs idcs[k]. Result: I_super(t) = (Σ λ_k I_k(t)) / λ_total.
 * Derivation: independence ⇒ Var(N_total(t)) = Σ Var(N_k(t)) =
 * Σ λ_k I_k(t) t; mean = λ_total t; ratio gives weighted average.
 *
 * Out grid is taken from idcs[0]; caller must ensure all input IDCs
 * share the same grid (true if they all came through idc_init_grid
 * with the same t_ref). */
static void idc_superposition(Idc *out,
                              const double *lambdas,
                              const Idc *idcs,
                              int K)
{
    int k, s;
    double total = 0.0;
    for (k = 0; k < K; k++) total += lambdas[k];
    for (s = 0; s < NUM_SCALES; s++) out->t[s] = idcs[0].t[s];
    if (total <= 0.0) {
        for (s = 0; s < NUM_SCALES; s++) out->v[s] = 0.0;
        return;
    }
    for (s = 0; s < NUM_SCALES; s++) {
        double sum = 0.0;
        for (k = 0; k < K; k++) sum += lambdas[k] * idcs[k].v[s];
        out->v[s] = sum / total;
    }
}

/* Bernoulli splitting: each arrival of `in` independently routes to
 * the substream with probability p. Result: I_split(t) = p I(t) + (1-p).
 * Derivation: N_sub | N_in ~ Binomial(N_in, p). Tower:
 *   E[N_sub] = p · E[N_in] = p · λ t
 *   Var[N_sub] = E[Var(N_sub|N_in)] + Var[E(N_sub|N_in)]
 *              = E[N_in p(1-p)] + Var[p N_in]
 *              = p(1-p) λ t + p² λ t I_in(t)
 *   I_sub(t)  = Var/E = (1-p) + p I_in(t).
 * For a Poisson input (I=1) any split stays Poisson (I=1), as expected. */
static void idc_split(Idc *out, const Idc *in, double p)
{
    int s;
    for (s = 0; s < NUM_SCALES; s++) {
        out->t[s] = in->t[s];
        out->v[s] = p * in->v[s] + (1.0 - p);
    }
}

/* Departure IDC from a stationary GI/G/m queue, baseline form
 * (Marshall 1968 / Sriram-Whitt 1986 / Whitt 1983 eq. 38):
 *
 *   I_d(t) = 1 + (1 - ρ²) · (I_a(t) - 1)
 *              + ρ² · (I_s(t) - 1) / √m
 *
 * For m=1 this collapses to the convex combination
 *   I_d(t) = (1 - ρ²) I_a(t) + ρ² I_s(t).
 *
 * Limits:
 *   ρ → 0: I_d → I_a   (no queueing, departures inherit arrivals)
 *   ρ → 1: I_d → 1 + (I_s - 1)/√m (departures pace by service)
 *
 * The /√m server-pooling factor is Whitt 1983's correction for
 * multi-server stations.
 *
 * The full Whitt-You §3 refinement adds a workload-IDC correction
 * coupling I_d to t* = E[W]/E[S], which requires knowing E[W] —
 * that's the Phase 3 fixed-point. The baseline above is exact for
 * M/M/1 (Burke's theorem) and asymptotically correct elsewhere. */
static void idc_departure(Idc *out,
                          const Idc *I_a, const Idc *I_s,
                          double rho, int m_servers)
{
    if (m_servers < 1) m_servers = 1;
    double rho2 = rho * rho;
    double inv_sqrt_m = 1.0 / sqrt((double)m_servers);
    int s;
    for (s = 0; s < NUM_SCALES; s++) {
        out->t[s] = I_a->t[s];
        out->v[s] = 1.0
                  + (1.0 - rho2) * (I_a->v[s] - 1.0)
                  + rho2 * (I_s->v[s] - 1.0) * inv_sqrt_m;
    }
}

/* Evaluate I(t) at an arbitrary t by log-linear interpolation on the
 * (log t_k, v_k) grid. Outside the grid we clamp to the nearest end
 * value rather than extrapolating — the renewal asymptote is the
 * right answer at long t, and at short t the I(0+) value is what
 * the IDC primitives compute closed-form. */
static double idc_eval(const Idc *I, double t)
{
    if (t <= I->t[0])             return I->v[0];
    if (t >= I->t[NUM_SCALES - 1]) return I->v[NUM_SCALES - 1];
    double lt = log(t);
    int k;
    /* Find bracketing pair (t[k], t[k+1]) such that t[k] ≤ t < t[k+1]. */
    for (k = 0; k < NUM_SCALES - 1; k++) {
        if (t < I->t[k + 1]) break;
    }
    double l0 = log(I->t[k]);
    double l1 = log(I->t[k + 1]);
    double frac = (lt - l0) / (l1 - l0);
    return I->v[k] + frac * (I->v[k + 1] - I->v[k]);
}

/* ================================================================
 *  Whitt-You canonical weight function w*(t)  (eq. 19)
 * ================================================================
 *
 *  w*(t) = (1/(2t)) · [(t² + 2t − 1)(1 − 2Φᶜ(√t))
 *                       + 2φ(√t)·√t·(1+t) − t²]
 *
 *  where Φᶜ = 1 − Φ is the standard-normal complementary CDF and
 *  φ is the standard-normal PDF. Note (1 − 2Φᶜ(s)) = 2Φ(s) − 1.
 *
 *  Properties: w*(0) = 0, w*(∞) = 1, monotonically increasing.
 *
 *  Asymptotics (Taylor at t=0): Φ(√t) − 0.5 ≈ φ(0)·√t = √t/√(2π),
 *  so the bracketed quantity vanishes like 2·√(2/π)·t^{3/2} − t²
 *  near t=0, and w*(t) ~ √(2/π)·√t for small t. Below t < 1e-8
 *  we use this expansion to avoid catastrophic cancellation
 *  between (t² + 2t − 1)·(2Φ(√t) − 1) and 2φ(√t)·√t·(1+t), which
 *  individually scale as √t but differ by O(t^{3/2}).
 *
 *  Above t > 50, both terms are within 1e-9 of their asymptotes
 *  (Φ(√50) − 1 < 5e-13, φ(√50) ~ 5e-12) so we return 1 − 1/(2t)
 *  directly to avoid the 0·∞ form. */
static double std_normal_pdf(double x)
{
    return exp(-0.5 * x * x) / sqrt(2.0 * M_PI);
}

/* Tail Φ(x) for x ≥ 0 via erfc: Φ(x) = 0.5 + 0.5·erf(x/√2).
 * This avoids the cancellation in 1 − Φ when x is large. */
static double std_normal_cdf(double x)
{
    return 0.5 * (1.0 + erf(x / sqrt(2.0)));
}

static double canonical_w(double t)
{
    if (t <= 0.0) return 0.0;
    if (t < 1e-6) {
        /* Series expansion: collecting (s = √t) the s³ terms from
         *   (t²+2t-1)·(2Φ(√t)-1) using 2Φ(s)-1 = √(2/π)·(s - s³/6 + …)
         *   2φ(s)·s·(1+t) using φ(s) = (1/√(2π))·(1 - t/2 + …)
         *   minus t²
         * gives Sum = (8/3)·√(2/π)·t^{3/2} − t² + O(t^{5/2}), and
         * w*(t) = Sum/(2t) = (4/3)·√(2/π)·√t − t/2 + O(t^{3/2}). */
        return (4.0 / 3.0) * sqrt(2.0 / M_PI) * sqrt(t) - 0.5 * t;
    }
    if (t > 50.0) {
        /* Asymptote: w*(t) → 1 − 1/(2t) + exponentially small. */
        return 1.0 - 0.5 / t;
    }
    double s = sqrt(t);
    double Phi_s = std_normal_cdf(s);   /* Φ(√t) */
    double phi_s = std_normal_pdf(s);   /* φ(√t) */
    double term1 = (t * t + 2.0 * t - 1.0) * (2.0 * Phi_s - 1.0);
    double term2 = 2.0 * phi_s * s * (1.0 + t);
    double term3 = -t * t;
    return (term1 + term2 + term3) / (2.0 * t);
}

/* w_i(t) per Whitt-You eq. (18):
 *
 *   w_i(t) = w*( (1−ρ_i)² · λ_i · t / (ρ_i · c²_x,i) )
 *
 * where c²_x,i = c²_a,i + c²_s,i and c²_a,i = I_a,i(∞) is the
 * limiting (asymptotic) arrival IDC at station i, solved separately
 * via the limiting variability equations (eq. 32). */
static double idc_weight(double t, double rho, double lambda,
                         double c2_a_inf, double c2_s)
{
    double cx = c2_a_inf + c2_s;
    if (cx <= 0.0 || rho <= 0.0) return 1.0;
    double arg = (1.0 - rho) * (1.0 - rho) * lambda * t / (rho * cx);
    return canonical_w(arg);
}

/* ================================================================
 *  Self-test suite for the IDC primitives
 * ================================================================
 *
 *  Returns 0 on PASS, 1 on FAIL. Each test prints a one-line
 *  PASS/FAIL with the values it checked, so failures are
 *  diagnosable without reattaching a debugger. */

static int approx_eq(double a, double b, double tol)
{
    double d = a - b;
    if (d < 0) d = -d;
    return d <= tol;
}

static int test_poisson(void)
{
    Idc I;
    idc_init_grid(&I, 1.0);
    idc_poisson(&I);
    int k;
    for (k = 0; k < NUM_SCALES; k++) {
        if (!approx_eq(I.v[k], 1.0, 1e-15)) {
            printf("  FAIL  Poisson IDC at t=%g: got %g, expected 1.0\n",
                   I.t[k], I.v[k]);
            return 1;
        }
    }
    printf("  PASS  Poisson IDC ≡ 1 at all %d timescales\n", NUM_SCALES);
    return 0;
}

static int test_erlang(void)
{
    int kvals[] = {1, 2, 4, 10};
    int n = sizeof(kvals) / sizeof(kvals[0]);
    int i, k;
    for (i = 0; i < n; i++) {
        Idc I;
        idc_init_grid(&I, 1.0);
        idc_erlang(&I, kvals[i]);
        double expected = 1.0 / (double)kvals[i];
        for (k = 0; k < NUM_SCALES; k++) {
            if (!approx_eq(I.v[k], expected, 1e-15)) {
                printf("  FAIL  Erlang-%d IDC at t=%g: got %g, expected %g\n",
                       kvals[i], I.t[k], I.v[k], expected);
                return 1;
            }
        }
    }
    printf("  PASS  Erlang-k IDC ≡ 1/k for k ∈ {1, 2, 4, 10}\n");
    return 0;
}

static int test_hyperexp2(void)
{
    /* Symmetric H2: p=0.5, μ₁=2, μ₂=0.5
     * E[X]  = 0.5/2 + 0.5/0.5 = 0.25 + 1.0 = 1.25
     * E[X²] = 2 (0.5/4 + 0.5/0.25) = 2 (0.125 + 2.0) = 4.25
     * c²    = 4.25/1.5625 − 1 = 2.72 − 1 = 1.72 */
    Idc I;
    idc_init_grid(&I, 1.0);
    idc_hyperexp2(&I, 0.5, 2.0, 0.5);
    double expected = 4.25 / (1.25 * 1.25) - 1.0;
    int k;
    for (k = 0; k < NUM_SCALES; k++) {
        if (!approx_eq(I.v[k], expected, 1e-12)) {
            printf("  FAIL  H2 IDC at t=%g: got %g, expected %g\n",
                   I.t[k], I.v[k], expected);
            return 1;
        }
    }
    /* H2 must always have c² ≥ 1 (it's a mixture, hence over-dispersed
     * relative to its mean exp). */
    if (expected < 1.0) {
        printf("  FAIL  H2 c² = %g, must be ≥ 1\n", expected);
        return 1;
    }
    printf("  PASS  H2(p=0.5, μ₁=2, μ₂=0.5) IDC ≡ %g (≥ 1, as expected)\n",
           expected);
    return 0;
}

static int test_deterministic(void)
{
    Idc I;
    idc_init_grid(&I, 1.0);
    idc_deterministic(&I);
    int k;
    for (k = 0; k < NUM_SCALES; k++) {
        if (!approx_eq(I.v[k], 0.0, 1e-15)) {
            printf("  FAIL  Deterministic IDC at t=%g: got %g, expected 0.0\n",
                   I.t[k], I.v[k]);
            return 1;
        }
    }
    printf("  PASS  Deterministic IDC ≡ 0 (renewal asymptote)\n");
    return 0;
}

static int test_lognormal(void)
{
    /* σ²_log = ln(2): c² = exp(ln 2) − 1 = 1.0 */
    Idc I;
    idc_init_grid(&I, 1.0);
    idc_lognormal(&I, log(2.0));
    int k;
    for (k = 0; k < NUM_SCALES; k++) {
        if (!approx_eq(I.v[k], 1.0, 1e-12)) {
            printf("  FAIL  Lognormal IDC at t=%g: got %g, expected 1.0\n",
                   I.t[k], I.v[k]);
            return 1;
        }
    }
    printf("  PASS  Lognormal(σ²_log = ln 2) IDC ≡ 1.0 (= e^ln2 − 1)\n");
    return 0;
}

static int test_mmpp2(void)
{
    /* Test case: λ₁=2, λ₂=0.5, q₁=0.1, q₂=0.1
     * λ̄  = (0.1·2 + 0.1·0.5)/0.2 = 1.25
     * pref = 2·2.25·0.01/(1.25·0.008) = 4.5
     * I(0+) → 1, I(∞) → 1 + 4.5 = 5.5
     * I(t) is monotonic increasing in t. */
    Idc I;
    idc_init_grid(&I, 1.0);  /* grid spans 1e-2.5 .. 1e2 */
    idc_mmpp2(&I, 2.0, 0.5, 0.1, 0.1);

    /* Smallest timescale (t = 10^-2.5 ≈ 0.00316): qsum*t ≈ 6.32e-4,
     * bracket [1 − (1−e^-x)/x] ≈ x/2 for small x → 3.16e-4,
     * I ≈ 1 + 4.5·3.16e-4 ≈ 1.00142.
     * Check the small-t value is close to 1 (within ~0.01). */
    if (!approx_eq(I.v[0], 1.0, 0.01)) {
        printf("  FAIL  MMPP-2 IDC at small t=%g: got %g, expected ≈ 1.0\n",
               I.t[0], I.v[0]);
        return 1;
    }

    /* Largest timescale (t = 100): qsum*t = 20, bracket ≈ 1 − 1/20 = 0.95,
     * I ≈ 1 + 4.5·0.95 = 5.275. Check it has approached the asymptote
     * 5.5 to within 5%. */
    if (!approx_eq(I.v[NUM_SCALES - 1], 5.5, 0.5)) {
        printf("  FAIL  MMPP-2 IDC at large t=%g: got %g, expected ≈ 5.5\n",
               I.t[NUM_SCALES - 1], I.v[NUM_SCALES - 1]);
        return 1;
    }

    /* Monotonicity: I(t) must be increasing in t. */
    int k;
    for (k = 1; k < NUM_SCALES; k++) {
        if (I.v[k] < I.v[k - 1] - 1e-12) {
            printf("  FAIL  MMPP-2 IDC not monotonic at k=%d: "
                   "I(%g)=%g < I(%g)=%g\n",
                   k, I.t[k], I.v[k], I.t[k - 1], I.v[k - 1]);
            return 1;
        }
    }
    printf("  PASS  MMPP-2 IDC: I(0+) ≈ 1 (got %.5f), "
           "I(∞) → 5.5 (got %.4f at t=%g), monotonic ↑\n",
           I.v[0], I.v[NUM_SCALES - 1], I.t[NUM_SCALES - 1]);
    return 0;
}

static int test_superposition(void)
{
    /* Two Poisson streams superpose to Poisson: I ≡ 1 regardless of mix. */
    Idc I1, I2, sup;
    idc_init_grid(&I1, 1.0); idc_poisson(&I1);
    idc_init_grid(&I2, 1.0); idc_poisson(&I2);
    double lambdas[2] = {3.0, 7.0};
    Idc inputs[2] = {I1, I2};
    idc_superposition(&sup, lambdas, inputs, 2);
    int k;
    for (k = 0; k < NUM_SCALES; k++) {
        if (!approx_eq(sup.v[k], 1.0, 1e-15)) {
            printf("  FAIL  Super(2 Poissons) at t=%g: got %g, expected 1.0\n",
                   sup.t[k], sup.v[k]);
            return 1;
        }
    }
    /* Mixing IDC=2 (weight 1) with IDC=4 (weight 3): expected = (1·2+3·4)/4 = 3.5 */
    Idc A, B, mix;
    idc_init_grid(&A, 1.0); idc_set_const(&A, 2.0);
    idc_init_grid(&B, 1.0); idc_set_const(&B, 4.0);
    double w[2] = {1.0, 3.0};
    Idc inputs2[2] = {A, B};
    idc_superposition(&mix, w, inputs2, 2);
    for (k = 0; k < NUM_SCALES; k++) {
        if (!approx_eq(mix.v[k], 3.5, 1e-15)) {
            printf("  FAIL  Super weighted at t=%g: got %g, expected 3.5\n",
                   mix.t[k], mix.v[k]);
            return 1;
        }
    }
    printf("  PASS  Superposition: 2 Poissons → Poisson; "
           "weighted mix (1·2 + 3·4)/4 = 3.5\n");
    return 0;
}

static int test_split(void)
{
    /* Split of Poisson with any p stays Poisson: p·1 + (1-p) = 1. */
    Idc P, S;
    idc_init_grid(&P, 1.0); idc_poisson(&P);
    double ps[] = {0.1, 0.5, 0.9};
    int i, k;
    for (i = 0; i < 3; i++) {
        idc_split(&S, &P, ps[i]);
        for (k = 0; k < NUM_SCALES; k++) {
            if (!approx_eq(S.v[k], 1.0, 1e-15)) {
                printf("  FAIL  Split(Poisson, p=%g) at t=%g: got %g, expected 1.0\n",
                       ps[i], S.t[k], S.v[k]);
                return 1;
            }
        }
    }
    /* Split of IDC=5 with p=0.4: expected = 0.4·5 + 0.6 = 2.6 */
    Idc X, X4;
    idc_init_grid(&X, 1.0); idc_set_const(&X, 5.0);
    idc_split(&X4, &X, 0.4);
    for (k = 0; k < NUM_SCALES; k++) {
        if (!approx_eq(X4.v[k], 2.6, 1e-15)) {
            printf("  FAIL  Split at t=%g: got %g, expected 2.6\n",
                   X4.t[k], X4.v[k]);
            return 1;
        }
    }
    printf("  PASS  Split: Poisson stays Poisson under any p; "
           "0.4·5 + 0.6 = 2.6\n");
    return 0;
}

static int test_departure(void)
{
    Idc Ia, Is, Id;
    idc_init_grid(&Ia, 1.0); idc_init_grid(&Is, 1.0);

    /* M/M/1: I_a=1, I_s=1, any ρ → I_d=1 (Burke's theorem). */
    idc_poisson(&Ia); idc_poisson(&Is);
    double rhos[] = {0.1, 0.5, 0.9};
    int i, k;
    for (i = 0; i < 3; i++) {
        idc_departure(&Id, &Ia, &Is, rhos[i], 1);
        for (k = 0; k < NUM_SCALES; k++) {
            if (!approx_eq(Id.v[k], 1.0, 1e-14)) {
                printf("  FAIL  M/M/1 departure ρ=%g at t=%g: got %g, expected 1.0\n",
                       rhos[i], Id.t[k], Id.v[k]);
                return 1;
            }
        }
    }

    /* M/D/1, ρ=0.5: I_a=1, I_s=0 → I_d = (1-0.25)·1 + 0.25·0 = 0.75 */
    idc_poisson(&Ia); idc_deterministic(&Is);
    idc_departure(&Id, &Ia, &Is, 0.5, 1);
    for (k = 0; k < NUM_SCALES; k++) {
        if (!approx_eq(Id.v[k], 0.75, 1e-14)) {
            printf("  FAIL  M/D/1 ρ=0.5 at t=%g: got %g, expected 0.75\n",
                   Id.t[k], Id.v[k]);
            return 1;
        }
    }

    /* D/M/1, ρ=0.5: I_a=0, I_s=1 → I_d = 0.75·0 + 0.25·1 = 0.25 */
    idc_deterministic(&Ia); idc_poisson(&Is);
    idc_departure(&Id, &Ia, &Is, 0.5, 1);
    for (k = 0; k < NUM_SCALES; k++) {
        if (!approx_eq(Id.v[k], 0.25, 1e-14)) {
            printf("  FAIL  D/M/1 ρ=0.5 at t=%g: got %g, expected 0.25\n",
                   Id.t[k], Id.v[k]);
            return 1;
        }
    }

    /* M/M/4, ρ=0.5: I_d = 1 + 0.75·0 + 0.25·0/√4 = 1 (Poisson in/out
     * regardless of m, when service is exponential — multi-server M/M/m
     * is also Poisson-out by Burke). */
    idc_poisson(&Ia); idc_poisson(&Is);
    idc_departure(&Id, &Ia, &Is, 0.5, 4);
    for (k = 0; k < NUM_SCALES; k++) {
        if (!approx_eq(Id.v[k], 1.0, 1e-14)) {
            printf("  FAIL  M/M/4 ρ=0.5 at t=%g: got %g, expected 1.0\n",
                   Id.t[k], Id.v[k]);
            return 1;
        }
    }

    printf("  PASS  Departure: M/M/1 (Burke) ≡ 1; M/D/1 ρ=0.5 → 0.75; "
           "D/M/1 ρ=0.5 → 0.25; M/M/4 ≡ 1\n");
    return 0;
}

static int test_grid(void)
{
    /* Grid sanity: log-spaced, monotonic, spans the documented range. */
    Idc I;
    idc_init_grid(&I, 2.0);  /* reference scale 2 */
    double expected_ratio = pow(10.0, 4.5 / (double)(NUM_SCALES - 1));
    int k;
    for (k = 1; k < NUM_SCALES; k++) {
        double ratio = I.t[k] / I.t[k - 1];
        if (!approx_eq(ratio, expected_ratio, 1e-9)) {
            printf("  FAIL  grid spacing at k=%d: ratio %g ≠ %g\n",
                   k, ratio, expected_ratio);
            return 1;
        }
    }
    if (!approx_eq(I.t[0], 2.0 * pow(10.0, -2.5), 1e-12) ||
        !approx_eq(I.t[NUM_SCALES - 1], 2.0 * pow(10.0, 2.0), 1e-9)) {
        printf("  FAIL  grid endpoints: t[0]=%g, t[%d]=%g\n",
               I.t[0], NUM_SCALES - 1, I.t[NUM_SCALES - 1]);
        return 1;
    }
    printf("  PASS  Log grid: %d points, ratio %g, "
           "spans [%.4g, %.4g] × E[S]\n",
           NUM_SCALES, expected_ratio,
           pow(10.0, -2.5), pow(10.0, 2.0));
    return 0;
}

/* Forward decls: defined after the network solve so they can use it. */
static int test_tandem_mm1(void);
static int test_idc_eval(void);
static int test_wait_mm1(void);
static int test_wait_mg1(void);
static int test_canonical_w(void);
static int test_wait_mmm(void);
static int test_external_scv_pc(void);
static int test_pc_alpha_beta_k1_matches_3c(void);

static int run_selftest(void)
{
    printf("RQNA self-test: IDC primitives\n");
    printf("--------------------------------\n");
    int fails = 0;
    fails += test_grid();
    fails += test_poisson();
    fails += test_deterministic();
    fails += test_erlang();
    fails += test_hyperexp2();
    fails += test_lognormal();
    fails += test_mmpp2();
    fails += test_superposition();
    fails += test_split();
    fails += test_departure();
    fails += test_tandem_mm1();
    fails += test_canonical_w();
    fails += test_idc_eval();
    fails += test_wait_mm1();
    fails += test_wait_mg1();
    fails += test_wait_mmm();
    fails += test_external_scv_pc();
    fails += test_pc_alpha_beta_k1_matches_3c();
    printf("--------------------------------\n");
    if (fails) {
        printf("FAIL: %d test(s) failed\n", fails);
        return 1;
    }
    printf("PASS: all tests passed\n");
    return 0;
}

/* ================================================================
 *  Network input parser
 * ================================================================
 *
 *  Phase 1: parses the same .qna format as bna_qna (rate + SCV per
 *  arrival source, mean + SCV per service, routing matrix). Customer
 *  class data is skipped silently in Phase 1 — Phase 3 will exercise
 *  it via per-class IDC propagation. */

static int n;
static int    m_serv[MAX_NODES];     /* servers per node */
static double lambda0[MAX_NODES];    /* external arrival rate */
static double ca0_sq[MAX_NODES];     /* external arrival SCV */
static double tau[MAX_NODES];        /* mean service time */
static double cs_sq[MAX_NODES];      /* service SCV */
static double Q[MAX_NODES][MAX_NODES]; /* routing matrix */

static int compact = 0;

/* ── Customer-class data (optional, parsed when present) ─────────
 *
 * When the .qna file carries a `customer_classes K` block AND the
 * extended per-class variability data (cc_cs[k][i], cc_lambda_ext[k][i],
 * cc_routing[(k,i)][(k',j)]), Phase 3d uses per-class IDC propagation
 * instead of the per-station aggregation. */
#define MAX_CLASSES 32
#define MAX_PERCLASS 256   /* cap K·n to keep K·n × K·n matrices sane */

static int    cc_K = 0;                            /* number of classes; 0 = feature off */
static double cc_lambda[MAX_CLASSES];              /* external arrival per class (sum over stations) */
static double cc_alpha_total[MAX_NODES];           /* total throughput per station (parsed) */
static double cc_mueff[MAX_NODES];                 /* effective service rate per station */
static double cc_alpha[MAX_CLASSES][MAX_NODES];    /* α_{k,i}: per-class throughput at i */
static double cc_mu[MAX_CLASSES][MAX_NODES];       /* μ_{k,i}: per-class service rate */
static double cc_tau_w[MAX_NODES];                 /* per-station workload weight (parsed) */

/* Extended per-class variability block */
static int    cc_have_var = 0;                     /* 1 if cs/lambda_ext/routing all present */
static double cc_cs_var[MAX_CLASSES][MAX_NODES];   /* c²_s,k,i */
static double cc_lambda_ext[MAX_CLASSES][MAX_NODES]; /* λ_0,k,i */
static double *cc_routing = NULL;                  /* P_ex[(k,i)][(k',j)] heap K·n × K·n */
static double cc_ca_pc[MAX_CLASSES][MAX_NODES];    /* c²_a,k,i (output, per-class limiting) */
static double cc_ca0_pc[MAX_CLASSES][MAX_NODES];   /* per-(k,i) EXTERNAL SCV; default 1 (Poisson) */
static int    cc_have_ca0 = 0;                     /* 1 if .qna trailing ca0_pc block was parsed */

static int next_line(FILE *fp, char *buf, int size)
{
    while (fgets(buf, size, fp)) {
        char *p = buf;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '#' || *p == '\n' || *p == '\r' || *p == '\0')
            continue;
        return 1;
    }
    return 0;
}

static void parse_input(const char *filename)
{
    FILE *fp = fopen(filename, "r");
    char buf[LINE_BUF];
    int i, j;

    if (!fp) {
        fprintf(stderr, "bna_rqna: cannot open '%s'\n", filename);
        exit(EXIT_FAILURE);
    }

    if (!next_line(fp, buf, LINE_BUF)) goto bad;
    if (sscanf(buf, "%d", &n) != 1 || n < 1 || n > MAX_NODES) {
        fprintf(stderr, "bna_rqna: invalid n = %d (max %d)\n", n, MAX_NODES);
        exit(EXIT_FAILURE);
    }

    /* m_j */
    if (!next_line(fp, buf, LINE_BUF)) goto bad;
    {
        char *tok = strtok(buf, " \t\n\r");
        for (i = 0; i < n; i++) {
            if (!tok) goto bad;
            m_serv[i] = atoi(tok);
            if (m_serv[i] < 1) m_serv[i] = 1;
            tok = strtok(NULL, " \t\n\r");
        }
    }

    /* lambda0_j */
    if (!next_line(fp, buf, LINE_BUF)) goto bad;
    {
        char *tok = strtok(buf, " \t\n\r");
        for (i = 0; i < n; i++) {
            if (!tok) goto bad;
            lambda0[i] = atof(tok);
            tok = strtok(NULL, " \t\n\r");
        }
    }

    /* ca0² */
    if (!next_line(fp, buf, LINE_BUF)) goto bad;
    {
        char *tok = strtok(buf, " \t\n\r");
        for (i = 0; i < n; i++) {
            if (!tok) goto bad;
            ca0_sq[i] = atof(tok);
            tok = strtok(NULL, " \t\n\r");
        }
    }

    /* τ_j */
    if (!next_line(fp, buf, LINE_BUF)) goto bad;
    {
        char *tok = strtok(buf, " \t\n\r");
        for (i = 0; i < n; i++) {
            if (!tok) goto bad;
            tau[i] = atof(tok);
            tok = strtok(NULL, " \t\n\r");
        }
    }

    /* cs² */
    if (!next_line(fp, buf, LINE_BUF)) goto bad;
    {
        char *tok = strtok(buf, " \t\n\r");
        for (i = 0; i < n; i++) {
            if (!tok) goto bad;
            cs_sq[i] = atof(tok);
            tok = strtok(NULL, " \t\n\r");
        }
    }

    /* Q matrix */
    for (i = 0; i < n; i++) {
        char *tok;
        if (!next_line(fp, buf, LINE_BUF)) goto bad;
        tok = strtok(buf, " \t\n\r");
        for (j = 0; j < n; j++) {
            if (!tok) goto bad;
            Q[i][j] = atof(tok);
            tok = strtok(NULL, " \t\n\r");
        }
    }

    /* ── Optional customer class data (Phase 3d) ───────────────── */
    if (next_line(fp, buf, LINE_BUF)) {
        int K_in = 0;
        if (sscanf(buf, "customer_classes %d", &K_in) == 1
            && K_in > 0 && K_in <= MAX_CLASSES) {
            cc_K = K_in;
            int K = cc_K, k;

            /* tau_w (workload conversion factor per station) */
            if (!next_line(fp, buf, LINE_BUF)) goto bad_cc;
            { char *tok = strtok(buf, " \t\n\r");
              for (i = 0; i < n; i++) { if (!tok) goto bad_cc;
                  cc_tau_w[i] = atof(tok); tok = strtok(NULL, " \t\n\r"); } }

            /* alpha_total per station */
            if (!next_line(fp, buf, LINE_BUF)) goto bad_cc;
            { char *tok = strtok(buf, " \t\n\r");
              for (i = 0; i < n; i++) { if (!tok) goto bad_cc;
                  cc_alpha_total[i] = atof(tok); tok = strtok(NULL, " \t\n\r"); } }

            /* effective service rate per station */
            if (!next_line(fp, buf, LINE_BUF)) goto bad_cc;
            { char *tok = strtok(buf, " \t\n\r");
              for (i = 0; i < n; i++) { if (!tok) goto bad_cc;
                  cc_mueff[i] = atof(tok); tok = strtok(NULL, " \t\n\r"); } }

            /* lambda per class */
            if (!next_line(fp, buf, LINE_BUF)) goto bad_cc;
            { char *tok = strtok(buf, " \t\n\r");
              for (k = 0; k < K; k++) { if (!tok) goto bad_cc;
                  cc_lambda[k] = atof(tok); tok = strtok(NULL, " \t\n\r"); } }

            /* alpha[k][i] (K rows × n cols) */
            for (k = 0; k < K; k++) {
                if (!next_line(fp, buf, LINE_BUF)) goto bad_cc;
                char *tok = strtok(buf, " \t\n\r");
                for (i = 0; i < n; i++) { if (!tok) goto bad_cc;
                    cc_alpha[k][i] = atof(tok); tok = strtok(NULL, " \t\n\r"); }
            }

            /* mu[k][i] (K rows × n cols) */
            for (k = 0; k < K; k++) {
                if (!next_line(fp, buf, LINE_BUF)) goto bad_cc;
                char *tok = strtok(buf, " \t\n\r");
                for (i = 0; i < n; i++) { if (!tok) goto bad_cc;
                    cc_mu[k][i] = atof(tok); tok = strtok(NULL, " \t\n\r"); }
            }

            /* Optional per-class variability block (cs[k][i],
             * lambda_ext[k][i], P_ex[N][N] with N = K·n). All three
             * must be present together. Mirrors BNAqna's parser. */
            cc_have_var = 0;
            if (next_line(fp, buf, LINE_BUF)) {
                int parsed_cs = 1;
                for (k = 0; k < K; k++) {
                    if (k > 0 && !next_line(fp, buf, LINE_BUF)) { parsed_cs = 0; break; }
                    char *tok = strtok(buf, " \t\n\r");
                    for (i = 0; i < n; i++) {
                        if (!tok) { parsed_cs = 0; break; }
                        cc_cs_var[k][i] = atof(tok);
                        tok = strtok(NULL, " \t\n\r");
                    }
                    if (!parsed_cs) break;
                }
                if (parsed_cs) {
                    int parsed_le = 1;
                    for (k = 0; k < K; k++) {
                        if (!next_line(fp, buf, LINE_BUF)) { parsed_le = 0; break; }
                        char *tok = strtok(buf, " \t\n\r");
                        for (i = 0; i < n; i++) {
                            if (!tok) { parsed_le = 0; break; }
                            cc_lambda_ext[k][i] = atof(tok);
                            tok = strtok(NULL, " \t\n\r");
                        }
                        if (!parsed_le) break;
                    }
                    if (parsed_le) {
                        size_t N = (size_t)K * (size_t)n;
                        if (N > MAX_PERCLASS) {
                            fprintf(stderr, "bna_rqna: K·n = %zu > MAX_PERCLASS=%d, "
                                    "per-class variability disabled\n", N, MAX_PERCLASS);
                        } else {
                            cc_routing = (double *)calloc(N * N, sizeof(double));
                            if (cc_routing) {
                                int parsed_pex = 1;
                                for (size_t row = 0; row < N; row++) {
                                    if (!next_line(fp, buf, LINE_BUF)) { parsed_pex = 0; break; }
                                    char *tok = strtok(buf, " \t\n\r");
                                    for (size_t col = 0; col < N; col++) {
                                        if (!tok) { parsed_pex = 0; break; }
                                        cc_routing[row * N + col] = atof(tok);
                                        tok = strtok(NULL, " \t\n\r");
                                    }
                                    if (!parsed_pex) break;
                                }
                                if (parsed_pex) cc_have_var = 1;
                                else { free(cc_routing); cc_routing = NULL; }
                            }
                            /* Initialize per-class external SCV to Poisson
                             * default; overwritten below if trailing block
                             * is present in the .qna file. */
                            for (int k2 = 0; k2 < K; k2++)
                                for (int i2 = 0; i2 < n; i2++)
                                    cc_ca0_pc[k2][i2] = 1.0;
                            cc_have_ca0 = 0;

                            /* Optional trailing block — per-class external
                             * SCV (K rows × n cols). Backward-compatible:
                             * older .qna files stop after P_ex and we keep
                             * the Poisson defaults. */
                            if (cc_have_var) {
                                int parsed_ca0 = 1;
                                for (k = 0; k < K; k++) {
                                    if (!next_line(fp, buf, LINE_BUF)) { parsed_ca0 = 0; break; }
                                    char *tok = strtok(buf, " \t\n\r");
                                    for (i = 0; i < n; i++) {
                                        if (!tok) { parsed_ca0 = 0; break; }
                                        cc_ca0_pc[k][i] = atof(tok);
                                        tok = strtok(NULL, " \t\n\r");
                                    }
                                    if (!parsed_ca0) break;
                                }
                                if (parsed_ca0) cc_have_ca0 = 1;
                                else {
                                    /* Reset to Poisson on partial parse. */
                                    for (int k2 = 0; k2 < K; k2++)
                                        for (int i2 = 0; i2 < n; i2++)
                                            cc_ca0_pc[k2][i2] = 1.0;
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    fclose(fp);
    return;

bad_cc:
    fprintf(stderr, "bna_rqna: incomplete customer-class block; ignoring per-class data\n");
    cc_K = 0; cc_have_var = 0;
    if (cc_routing) { free(cc_routing); cc_routing = NULL; }
    fclose(fp);
    return;

bad:
    fprintf(stderr, "bna_rqna: premature end of input in '%s'\n", filename);
    fclose(fp);
    exit(EXIT_FAILURE);
}

/* ================================================================
 *  Network solve: traffic equations + IDC propagation
 * ================================================================
 *
 *  Mirrors BNAqna's flow plumbing: eliminate_feedback rewrites
 *  immediate self-loops (Q[i][i] > 0) into adjusted (τ, cs²) and a
 *  zero-diagonal Qt matrix; solve_traffic_rates inverts (I − Qt^T)
 *  to get total throughputs lam[i]; ρ_i = lam[i] · τ_i / m_i.
 *
 *  The IDC solve is then a sequence of NUM_SCALES independent linear
 *  systems with the same matrix — see solve_network_idcs(). */

/* Post-feedback-elimination network state */
static double tau_t[MAX_NODES];          /* transformed mean service */
static double cs_t[MAX_NODES];           /* transformed service SCV  */
static double Qt[MAX_NODES][MAX_NODES];  /* transformed routing      */
static double qii_orig[MAX_NODES];       /* original self-loop probs */
static double lam[MAX_NODES];            /* total arrival rate       */
static double rho[MAX_NODES];            /* utilization              */

/* Per-station IDC state (Phase 2 outputs) */
static Idc Ia[MAX_NODES];                /* arrival IDC per station  */
static Idc Id[MAX_NODES];                /* departure IDC per station*/
static Idc Is[MAX_NODES];                /* service IDC per station  */
static Idc Ia0[MAX_NODES];               /* external arrival IDC     */

static void eliminate_feedback(void)
{
    int i, j;
    for (i = 0; i < n; i++) {
        qii_orig[i] = Q[i][i];
        if (Q[i][i] > 0.0) {
            double f = Q[i][i];
            tau_t[i] = tau[i] / (1.0 - f);
            cs_t[i]  = f + (1.0 - f) * cs_sq[i];
            for (j = 0; j < n; j++)
                Qt[i][j] = (j == i) ? 0.0 : Q[i][j] / (1.0 - f);
        } else {
            tau_t[i] = tau[i];
            cs_t[i]  = cs_sq[i];
            for (j = 0; j < n; j++) Qt[i][j] = Q[i][j];
        }
    }
}

/* Solve (I − Qt^T) lam = lambda0 for the n total throughputs, then
 * derive ρ_i = lam_i · τ'_i / m_i. Aborts on overload (ρ ≥ 1) or
 * singular system. Standard Gaussian elimination with partial
 * pivoting (n ≤ 64). */
static void solve_traffic_rates(void)
{
    double A[MAX_NODES][MAX_NODES], b[MAX_NODES];
    int i, j, col, row, maxRow;
    double maxVal, factor, pivot;

    for (i = 0; i < n; i++) {
        for (j = 0; j < n; j++)
            A[i][j] = (i == j ? 1.0 : 0.0) - Qt[j][i];
        b[i] = lambda0[i];
    }
    for (col = 0; col < n; col++) {
        maxVal = fabs(A[col][col]); maxRow = col;
        for (row = col + 1; row < n; row++)
            if (fabs(A[row][col]) > maxVal) {
                maxVal = fabs(A[row][col]); maxRow = row;
            }
        if (maxRow != col) {
            for (j = 0; j < n; j++) {
                double tmp = A[col][j]; A[col][j] = A[maxRow][j]; A[maxRow][j] = tmp;
            }
            double tmp = b[col]; b[col] = b[maxRow]; b[maxRow] = tmp;
        }
        pivot = A[col][col];
        if (fabs(pivot) < 1e-15) {
            fprintf(stderr, "bna_rqna: singular traffic-rate matrix\n");
            exit(EXIT_FAILURE);
        }
        for (row = col + 1; row < n; row++) {
            factor = A[row][col] / pivot;
            for (j = col; j < n; j++) A[row][j] -= factor * A[col][j];
            b[row] -= factor * b[col];
        }
    }
    for (i = n - 1; i >= 0; i--) {
        lam[i] = b[i];
        for (j = i + 1; j < n; j++) lam[i] -= A[i][j] * lam[j];
        lam[i] /= A[i][i];
    }
    for (i = 0; i < n; i++) {
        rho[i] = lam[i] * tau_t[i] / (double)m_serv[i];
        if (rho[i] >= 1.0) {
            fprintf(stderr, "bna_rqna: node %d overloaded (ρ = %.6f ≥ 1)\n",
                    i + 1, rho[i]);
            exit(EXIT_FAILURE);
        }
    }
}

/* Solve a single n×n linear system via Gaussian elimination with
 * partial pivoting. A is modified in place; b becomes the solution.
 * Returns 0 on success, 1 on singular matrix. */
static int gauss_solve(double A[MAX_NODES][MAX_NODES], double b[MAX_NODES],
                       int dim)
{
    int col, row, maxRow, k;
    for (col = 0; col < dim; col++) {
        double maxVal = fabs(A[col][col]); maxRow = col;
        for (row = col + 1; row < dim; row++)
            if (fabs(A[row][col]) > maxVal) {
                maxVal = fabs(A[row][col]); maxRow = row;
            }
        if (maxRow != col) {
            for (k = 0; k < dim; k++) {
                double tmp = A[col][k]; A[col][k] = A[maxRow][k];
                A[maxRow][k] = tmp;
            }
            double tmp = b[col]; b[col] = b[maxRow]; b[maxRow] = tmp;
        }
        double pivot = A[col][col];
        if (fabs(pivot) < 1e-15) return 1;
        for (row = col + 1; row < dim; row++) {
            double factor = A[row][col] / pivot;
            for (k = col; k < dim; k++) A[row][k] -= factor * A[col][k];
            b[row] -= factor * b[col];
        }
    }
    double x[MAX_NODES];
    int i;
    for (i = dim - 1; i >= 0; i--) {
        double v = b[i];
        for (k = i + 1; k < dim; k++) v -= A[i][k] * x[k];
        x[i] = v / A[i][i];
    }
    for (i = 0; i < dim; i++) b[i] = x[i];
    return 0;
}

/* Solve the per-station arrival-IDC system at every timescale, using
 * the Whitt-You §3.3 propagation rules.
 *
 * STEP 1 — Limiting variability (eq. 32 with α=β=0):
 *   c²_a,i = (λ_0,i/λ_i)·c²_a,0,i
 *          + Σ_j (λ_j·p_j,i/λ_i) · [p_j,i·c²_a,j + (1 − p_j,i)]
 *
 * (Substituting c²_d,j = c²_a,j from w(∞)=1 into the splitting eq.)
 *
 *   In matrix form: (I − A_inf)·c²_a = b_inf, where
 *     A_inf,ij = (λ_j·p_j,i²)/λ_i
 *     b_inf,i  = (λ_0,i/λ_i)·c²_a,0,i + Σ_j (λ_j·p_j,i·(1−p_j,i))/λ_i
 *
 *  This is the Whitt-You "tree-structured" simplification. For
 *  general OQNs with feedback or shared origins, α/β corrections
 *  apply (deferred to Phase 3c).
 *
 * STEP 2 — Per-timescale IDC equations (eqs. 17, 23 with α=0):
 *   I_d,i(t) = w_i(t)·I_a,i(t) + (1 − w_i(t))·I_s,i(ρ_i·t)        (17)
 *   I_a,j,i(t) = p_j,i·I_d,j(t) + (1 − p_j,i)                    (23)
 *   I_a,i(t) = (λ_0,i/λ_i)·I_a,0,i(t)
 *            + Σ_j (λ_j·p_j,i/λ_i)·I_a,j,i(t)
 *
 * Substituting eq. (17) and (23) into the I_a equation:
 *
 *   I_a,i(t) = (λ_0,i/λ_i)·I_a,0,i(t)
 *            + Σ_j (λ_j·p_j,i²/λ_i)·w_j(t)·I_a,j(t)
 *            + Σ_j (λ_j·p_j,i²/λ_i)·(1−w_j(t))·I_s,j(ρ_j·t)
 *            + Σ_j (λ_j·p_j,i·(1−p_j,i)/λ_i)
 *
 * → (I − M(t))·I_a(t) = b(t), with
 *   M_ij(t) = (λ_j·p_j,i²/λ_i)·w_j(t)    [TIME-DEPENDENT]
 *   b_i(t)  = (λ_0,i/λ_i)·I_a,0,i(t)
 *           + Σ_j (λ_j·p_j,i²/λ_i)·(1−w_j(t))·I_s,j(ρ_j·t)
 *           + Σ_j (λ_j·p_j,i·(1−p_j,i)/λ_i)
 *
 * The matrix is now t-dependent through w_j(t), so we re-build and
 * solve it at every timescale (NUM_SCALES Gauss eliminations).
 * After I_a is solved, I_d follows directly from eq. (17). */

static double c2a_inf[MAX_NODES];   /* limiting arrival SCV per station */

/* ============================================================
 *  Phase 3d.3 — per-class α/β corrections (Whitt-You §4.1)
 * ============================================================
 *
 *  Generalizes Phase 3c's α/β corrections to the per-class state
 *  space (K·n × K·n × K·n). For K=1 these reduce exactly to the
 *  per-station Phase 3c formulas (modulo the external-SCV default
 *  noted below). The per-class c²_α and c²_β values feed both the
 *  per-class limiting solve (Phase 3d.1) and the per-class per-
 *  timescale solve (Phase 3d.2), removing the K=1 regression where
 *  Phase 3d's per-class IDC propagation lacked the feedback-
 *  amplification corrections.
 *
 *  Storage is heap-allocated lazily by build_pc_alpha_beta() and
 *  freed by free_pc_arrays() at the end of solve_network_idcs.
 *
 *  Math (with N = K·n, P = cc_routing, α = cc_alpha):
 *
 *    ξ_pc        = (I − P_ex')⁻¹                            (N×N)
 *    Σ_pc[s][i,j] = α_s · (δ_ij · P[s,i] − P[s,i] · P[s,j])
 *    M_pc        = diag(λ_0,s · c²_a,0,s) + Σ_s Σ_pc[s]     (N×N)
 *    T_pc        = ξ_pc · M_pc · ξ_pc'                      (N×N, precomputed)
 *    U_pc[i,j]   = Σ_m ξ_pc[i,m] · P[j,m]                    (N×N, precomputed)
 *    ν_s(dst)[m] = P[s,dst] · ξ_pc[s,m]                      (implicit)
 *    ζ_pc[dst,sj,sk] = ν_sj' M_pc ν_sk + ν_sk' Σ_sj e_dst + ν_sj' Σ_sk e_dst
 *                    = T_pc[sj,sk]·P[sj,dst]·P[sk,dst]
 *                    + α_sj·P[sk,dst]·P[sj,dst]·(ξ_pc[sk,dst] − U_pc[sk,sj])
 *                    + α_sk·P[sj,dst]·P[sk,dst]·(ξ_pc[sj,dst] − U_pc[sj,sk])
 *    c²_α_pc[s,d] = 2·ξ_pc[d,s]·P[s,d]·(1−P[s,d])           (limiting)
 *    c²_β_pc[d]   = (2/α_d) · Σ_{sj<sk} ζ_pc[d,sj,sk]        (limiting)
 *
 *  External SCV: defaults to 1 (Poisson) since the .qna format
 *  doesn't carry per-class external SCV. This matches Phase 3d.1's
 *  external term and Phase 3c's default for unspecified externals.
 * ============================================================ */

static int     N_pc = 0;
static double *xi_pc        = NULL;
static double *M_pc         = NULL;
static double *T_pc         = NULL;
static double *U_pc         = NULL;
static double *zeta_pc      = NULL;
static double *c2_alpha_pc  = NULL;
static double *c2_beta_pc   = NULL;
static double *c2x_pc       = NULL;
static int     have_pc_ab   = 0;

#define PC_IDX(k, i)         ((size_t)(k) * (size_t)n + (size_t)(i))
#define PC_AT(arr, r, c)     ((arr)[(size_t)(r) * (size_t)N_pc + (size_t)(c)])
#define PC_AT3(arr, r, j, k) ((arr)[((size_t)(r) * (size_t)N_pc + (size_t)(j)) \
                                     * (size_t)N_pc + (size_t)(k)])
#define PC_PE(r, c)          cc_routing[(size_t)(r) * (size_t)N_pc + (size_t)(c)]

static void free_pc_arrays(void)
{
    free(xi_pc);       xi_pc       = NULL;
    free(M_pc);        M_pc        = NULL;
    free(T_pc);        T_pc        = NULL;
    free(U_pc);        U_pc        = NULL;
    free(zeta_pc);     zeta_pc     = NULL;
    free(c2_alpha_pc); c2_alpha_pc = NULL;
    free(c2_beta_pc);  c2_beta_pc  = NULL;
    free(c2x_pc);      c2x_pc      = NULL;
    N_pc = 0;
    have_pc_ab = 0;
}

/* ξ_pc = (I − P_ex')⁻¹ via column-by-column Gaussian elimination on
 * a heap-allocated A. Returns 1 on success, 0 on singular matrix or
 * allocation failure. */
static int compute_xi_pc(void)
{
    int N = N_pc;
    double *A   = (double *)malloc((size_t)N * (size_t)N * sizeof(double));
    double *rhs = (double *)malloc((size_t)N * sizeof(double));
    if (!A || !rhs) { free(A); free(rhs); return 0; }

    int j;
    for (j = 0; j < N; j++) {
        int i, k;
        for (i = 0; i < N; i++) {
            for (k = 0; k < N; k++)
                A[(size_t)i * N + k] = (i == k ? 1.0 : 0.0) - PC_PE(k, i);
            rhs[i] = (i == j) ? 1.0 : 0.0;
        }
        for (int col = 0; col < N; col++) {
            double mv = fabs(A[(size_t)col * N + col]);
            int mr = col;
            for (int r = col + 1; r < N; r++) {
                double v = fabs(A[(size_t)r * N + col]);
                if (v > mv) { mv = v; mr = r; }
            }
            if (mr != col) {
                for (int c = 0; c < N; c++) {
                    double t = A[(size_t)col * N + c];
                    A[(size_t)col * N + c] = A[(size_t)mr * N + c];
                    A[(size_t)mr * N + c] = t;
                }
                double t = rhs[col]; rhs[col] = rhs[mr]; rhs[mr] = t;
            }
            double pv = A[(size_t)col * N + col];
            if (fabs(pv) < 1e-15) { free(A); free(rhs); return 0; }
            for (int r = col + 1; r < N; r++) {
                double f = A[(size_t)r * N + col] / pv;
                if (f == 0.0) continue;
                for (int c = col; c < N; c++)
                    A[(size_t)r * N + c] -= f * A[(size_t)col * N + c];
                rhs[r] -= f * rhs[col];
            }
        }
        for (int i2 = N - 1; i2 >= 0; i2--) {
            double s = rhs[i2];
            for (int c = i2 + 1; c < N; c++)
                s -= A[(size_t)i2 * N + c] * rhs[c];
            rhs[i2] = s / A[(size_t)i2 * N + i2];
        }
        for (i = 0; i < N; i++) PC_AT(xi_pc, i, j) = rhs[i];
    }
    free(A); free(rhs);
    return 1;
}

/* M_pc[i][j] = diag(λ_ext,s · c²_a,0,s) + Σ_s α_s · (δ_ij·P[s,i] − P[s,i]·P[s,j]).
 * External c²_a,0 defaults to 1 (Poisson). */
static void compute_M_pc(void)
{
    int N = N_pc, K = cc_K;
    size_t total = (size_t)N * (size_t)N;
    for (size_t r = 0; r < total; r++) M_pc[r] = 0.0;

    /* Diagonal external part: λ_0 · c²_a,0 per (class, station). */
    for (int k = 0; k < K; k++) {
        for (int i = 0; i < n; i++) {
            size_t idx = PC_IDX(k, i);
            double ca0 = cc_have_ca0 ? cc_ca0_pc[k][i] : 1.0;
            M_pc[idx * (size_t)N + idx] += cc_lambda_ext[k][i] * ca0;
        }
    }
    /* Per-source covariance contribution */
    for (int sk = 0; sk < K; sk++) {
        for (int sl = 0; sl < n; sl++) {
            size_t s = PC_IDX(sk, sl);
            double a = cc_alpha[sk][sl];
            if (a < 1e-15) continue;
            /* Diagonal: + α_s · P[s,i] */
            for (int i = 0; i < N; i++) {
                double psi = PC_PE((int)s, i);
                if (psi != 0.0) M_pc[(size_t)i * N + i] += a * psi;
            }
            /* All entries: − α_s · P[s,i] · P[s,j] (subtracts from diagonal too) */
            for (int i = 0; i < N; i++) {
                double psi = PC_PE((int)s, i);
                if (psi == 0.0) continue;
                for (int j = 0; j < N; j++) {
                    double psj = PC_PE((int)s, j);
                    if (psj == 0.0) continue;
                    M_pc[(size_t)i * N + j] -= a * psi * psj;
                }
            }
        }
    }
}

/* T_pc = ξ_pc · M_pc · ξ_pc' (precomputed once). */
static int compute_T_pc(void)
{
    int N = N_pc;
    double *XM = (double *)malloc((size_t)N * (size_t)N * sizeof(double));
    if (!XM) return 0;
    int i, j, m;
    for (i = 0; i < N; i++) {
        for (j = 0; j < N; j++) {
            double s = 0.0;
            for (m = 0; m < N; m++)
                s += PC_AT(xi_pc, i, m) * PC_AT(M_pc, m, j);
            XM[(size_t)i * N + j] = s;
        }
    }
    for (i = 0; i < N; i++) {
        for (j = 0; j < N; j++) {
            double s = 0.0;
            for (m = 0; m < N; m++)
                s += XM[(size_t)i * N + m] * PC_AT(xi_pc, j, m);
            PC_AT(T_pc, i, j) = s;
        }
    }
    free(XM);
    return 1;
}

/* U_pc[i,j] = Σ_m ξ_pc[i,m] · P_ex[j,m] (precomputed once). */
static void compute_U_pc(void)
{
    int N = N_pc;
    int i, j, m;
    for (i = 0; i < N; i++) {
        for (j = 0; j < N; j++) {
            double s = 0.0;
            for (m = 0; m < N; m++)
                s += PC_AT(xi_pc, i, m) * PC_PE(j, m);
            PC_AT(U_pc, i, j) = s;
        }
    }
}

/* ζ_pc[dst, sj, sk] from the closed form above. O(N^3) total. */
static void compute_zeta_pc(void)
{
    int N = N_pc;
    int dst, sj, sk;
    for (dst = 0; dst < N; dst++) {
        for (sj = 0; sj < N; sj++) {
            double pj = PC_PE(sj, dst);
            if (pj < 1e-15) {
                for (sk = 0; sk < N; sk++) PC_AT3(zeta_pc, dst, sj, sk) = 0.0;
                continue;
            }
            int sj_k = sj / n, sj_i = sj % n;
            double aj = cc_alpha[sj_k][sj_i];
            for (sk = 0; sk < N; sk++) {
                if (sj == sk) { PC_AT3(zeta_pc, dst, sj, sk) = 0.0; continue; }
                double pk = PC_PE(sk, dst);
                if (pk < 1e-15) { PC_AT3(zeta_pc, dst, sj, sk) = 0.0; continue; }
                int sk_k = sk / n, sk_i = sk % n;
                double ak = cc_alpha[sk_k][sk_i];

                double t1 = PC_AT(T_pc, sj, sk) * pj * pk;
                double t2 = aj * pj * pk
                          * (PC_AT(xi_pc, sk, dst) - PC_AT(U_pc, sk, sj));
                double t3 = ak * pj * pk
                          * (PC_AT(xi_pc, sj, dst) - PC_AT(U_pc, sj, sk));
                PC_AT3(zeta_pc, dst, sj, sk) = t1 + t2 + t3;
            }
        }
    }
}

static void compute_alpha_beta_pc_constants(void)
{
    int N = N_pc;
    int src, dst;
    /* c²_α_pc[s,d] = 2·ξ_pc[s,d]·P[s,d]·(1−P[s,d]).
     *
     * Index convention: xi_pc[i,j] = ((I−P_ex')⁻¹)[i,j] (matches the
     * per-station convention `xi[i][j] = ((I−P')⁻¹)[i,j]` set up by
     * compute_xi). Phase 3c uses `c2_alpha[i][j] = 2·xi[i][j]·Q[i][j]·...`,
     * so the per-class generalization is `c2_alpha_pc[s,d] = 2·xi_pc[s,d]·...`. */
    for (src = 0; src < N; src++) {
        for (dst = 0; dst < N; dst++) {
            double p = PC_PE(src, dst);
            PC_AT(c2_alpha_pc, src, dst) =
                2.0 * PC_AT(xi_pc, src, dst) * p * (1.0 - p);
        }
    }
    /* c²_β_pc[d] = (2/α_d) · Σ_{sj<sk} ζ_pc[d,sj,sk] */
    for (dst = 0; dst < N; dst++) {
        int dk = dst / n, di = dst % n;
        double a_dst = cc_alpha[dk][di];
        double sum = 0.0;
        int sj, sk;
        for (sj = 0; sj < N; sj++)
            for (sk = sj + 1; sk < N; sk++)
                sum += PC_AT3(zeta_pc, dst, sj, sk);
        c2_beta_pc[dst] = (a_dst > 1e-15) ? 2.0 * sum / a_dst : 0.0;
    }
}

/* Build all per-class α/β constants (xi_pc, M_pc, T_pc, U_pc, ζ_pc,
 * c2_alpha_pc, c2_beta_pc). Returns 1 on success, 0 if data is
 * unavailable or any allocation/factorization fails. */
static int build_pc_alpha_beta(void)
{
    if (cc_K == 0 || !cc_have_var || cc_routing == NULL) return 0;
    int N = cc_K * n;
    if (N <= 0 || N > MAX_PERCLASS) return 0;

    free_pc_arrays();
    xi_pc       = (double *)calloc((size_t)N * N,         sizeof(double));
    M_pc        = (double *)calloc((size_t)N * N,         sizeof(double));
    T_pc        = (double *)calloc((size_t)N * N,         sizeof(double));
    U_pc        = (double *)calloc((size_t)N * N,         sizeof(double));
    zeta_pc     = (double *)calloc((size_t)N * N * N,     sizeof(double));
    c2_alpha_pc = (double *)calloc((size_t)N * N,         sizeof(double));
    c2_beta_pc  = (double *)calloc((size_t)N,             sizeof(double));
    c2x_pc      = (double *)calloc((size_t)N * N,         sizeof(double));
    if (!xi_pc || !M_pc || !T_pc || !U_pc || !zeta_pc
        || !c2_alpha_pc || !c2_beta_pc || !c2x_pc) {
        free_pc_arrays();
        return 0;
    }
    N_pc = N;

    if (!compute_xi_pc())   { free_pc_arrays(); return 0; }
    compute_M_pc();
    if (!compute_T_pc())    { free_pc_arrays(); return 0; }
    compute_U_pc();
    compute_zeta_pc();
    compute_alpha_beta_pc_constants();
    have_pc_ab = 1;
    return 1;
}

/* c²_x_pc[src,dst] = P · c²_a,src + (1−P) + P · c²_s,src.
 * Computed AFTER per-class limiting fills cc_ca_pc. Used inside the
 * per-class per-timescale β formula. */
static void compute_c2x_pc(void)
{
    int N = N_pc;
    if (!have_pc_ab) return;
    int src, dst;
    for (src = 0; src < N; src++) {
        int sk = src / n, si = src % n;
        double cas = cc_ca_pc[sk][si];
        double css = cc_cs_var[sk][si];
        for (dst = 0; dst < N; dst++) {
            double p = PC_PE(src, dst);
            PC_AT(c2x_pc, src, dst) = p * cas + (1.0 - p) + p * css;
        }
    }
}

/* ============================================================
 *  Phase 3d.1 — per-class limiting variability solve
 * ============================================================
 *
 *  When the .qna file carries the extended per-class block (cc_K > 0
 *  AND cc_have_var), we solve the per-class limiting variability
 *  equations on the K·n × K·n state space. The per-class c²_a values
 *  are then aggregated into per-station c²_a (weighted by class flow
 *  rates) and used as the asymptote in the existing Phase 3c per-
 *  station per-timescale solver.
 *
 *  Per-class limiting equations (Whitt-You §4.1, with the per-class
 *  α/β corrections from Phase 3d.3 when those constants are built):
 *
 *    c²_a,k,j = (λ_0,k,j / α_{k,j}) · c²_a,0,k,j
 *             + c²_β_pc[(k,j)]
 *             + Σ_{(k',i')} (α_{k',i'}·P_ex / α_{k,j})
 *                          · [P_ex · c²_a,k',i' + (1 − P_ex)
 *                             + c²_α_pc[(k',i')→(k,j)]]
 *
 *  where P_ex = P_ex[(k',i')][(k,j)]. When have_pc_ab is 0 (e.g.
 *  alloc failed), the α and β terms are taken to be 0, recovering
 *  the original Phase 3d.1 / Phase 3d.2 path.
 *
 *  Returns 1 if the per-class solve succeeded and per-station
 *  asymptotes were updated; 0 if data is unavailable or the system
 *  is singular (caller falls back to the per-station limiting
 *  variability already in solve_network_idcs). */
static int solve_perclass_limiting_variability(void)
{
    if (cc_K == 0 || !cc_have_var || cc_routing == NULL) return 0;

    int K = cc_K;
    size_t N = (size_t)K * (size_t)n;
    if (N == 0 || N > MAX_PERCLASS) return 0;

    /* Heap-allocate the K·n × K·n linear system. */
    double *A = (double *)calloc(N * N, sizeof(double));
    double *b = (double *)calloc(N, sizeof(double));
    if (!A || !b) { free(A); free(b); return 0; }

    #define IDX(kk, ii)  ((size_t)(kk) * (size_t)n + (size_t)(ii))
    #define PE(r, c)     cc_routing[(r) * N + (c)]
    #define AA(r, c)     A          [(r) * N + (c)]

    /* Build A = (I − M_pc) and b. */
    for (int k = 0; k < K; k++) {
        for (int j = 0; j < n; j++) {
            size_t row = IDX(k, j);
            double a_kj = cc_alpha[k][j];
            if (a_kj < 1e-15) {
                /* Empty class-station: trivially c²_a = 1. */
                AA(row, row) = 1.0;
                b[row] = 1.0;
                continue;
            }
            /* External proportion. With the trailing ca0_pc block
             * (cc_have_ca0) the actual per-(k,i) external SCV is used;
             * otherwise the original Poisson default. */
            double p0 = cc_lambda_ext[k][j] / a_kj;
            double ca0_kj = cc_have_ca0 ? cc_ca0_pc[k][j] : 1.0;
            b[row] = p0 * ca0_kj;
            /* Phase 3d.3 — β correction at this destination. */
            if (have_pc_ab) b[row] += c2_beta_pc[row];

            /* Initialize row of A to identity */
            for (size_t c = 0; c < N; c++) AA(row, c) = 0.0;
            AA(row, row) = 1.0;

            /* Internal contributions: Σ_{(k',i')} (α_{k',i'}·P_ex/α_{k,j}) ·
             * [P_ex · c²_a,k',i' + (1 − P_ex) + c²_α_pc] */
            for (int kp = 0; kp < K; kp++) {
                for (int ip = 0; ip < n; ip++) {
                    size_t col = IDX(kp, ip);
                    double a_kp_ip = cc_alpha[kp][ip];
                    if (a_kp_ip < 1e-15) continue;
                    double pex = PE(col, row);
                    if (pex < 1e-15) continue;
                    double frac = a_kp_ip * pex / a_kj;
                    /* Coefficient of c²_a,k',i' in equation for (k,j) */
                    AA(row, col) -= frac * pex;
                    /* Constant residue (1 − P_ex) part */
                    b[row] += frac * (1.0 - pex);
                    /* Phase 3d.3 — α correction at the splitter */
                    if (have_pc_ab)
                        b[row] += frac * PC_AT(c2_alpha_pc, col, row);
                }
            }
        }
    }

    /* Heap variant of Gaussian elimination (gauss_solve takes a fixed-
     * size 2D array, so inline a flat-buffer version here). */
    for (size_t col = 0; col < N; col++) {
        double mv = fabs(AA(col, col));
        size_t mr = col;
        for (size_t r = col + 1; r < N; r++) {
            if (fabs(AA(r, col)) > mv) { mv = fabs(AA(r, col)); mr = r; }
        }
        if (mr != col) {
            for (size_t c = 0; c < N; c++) {
                double t = AA(col, c); AA(col, c) = AA(mr, c); AA(mr, c) = t;
            }
            double t = b[col]; b[col] = b[mr]; b[mr] = t;
        }
        double pv = AA(col, col);
        if (fabs(pv) < 1e-15) {
            free(A); free(b);
            return 0;
        }
        for (size_t r = col + 1; r < N; r++) {
            double f = AA(r, col) / pv;
            if (f == 0.0) continue;
            for (size_t c = col; c < N; c++) AA(r, c) -= f * AA(col, c);
            b[r] -= f * b[col];
        }
    }
    /* Back-substitute (use signed iteration since N is size_t). */
    for (long i = (long)N - 1; i >= 0; i--) {
        double s = b[i];
        for (size_t c = (size_t)i + 1; c < N; c++) s -= AA((size_t)i, c) * b[c];
        b[(size_t)i] = s / AA((size_t)i, (size_t)i);
    }

    /* Extract per-class results, then aggregate per-station. */
    for (int k = 0; k < K; k++)
        for (int j = 0; j < n; j++)
            cc_ca_pc[k][j] = (cc_alpha[k][j] > 1e-15) ? b[IDX(k, j)] : 1.0;

    /* Per-station aggregation: c²_a[i] = Σ_k (α_{k,i}/λ_i) · c²_a,k,i.
     * Use cc_alpha_total (parsed total throughput) as the denominator
     * to match Whitt-You's definition. */
    for (int i = 0; i < n; i++) {
        double tot = cc_alpha_total[i];
        if (tot < 1e-15) { c2a_inf[i] = 1.0; continue; }
        double agg = 0.0;
        for (int k = 0; k < K; k++)
            agg += (cc_alpha[k][i] / tot) * cc_ca_pc[k][i];
        c2a_inf[i] = agg;
    }

    free(A); free(b);
    #undef IDX
    #undef PE
    #undef AA
    return 1;
}

/* ============================================================
 *  Phase 3d.2 — per-class IDC at every timescale
 * ============================================================
 *
 *  When per-class data is present, replace the per-station
 *  per-timescale solve with a per-class K·n × K·n solve at each
 *  of the NUM_SCALES timescales. After the per-class IDCs are
 *  found, aggregate to per-station I_a[i] for the wait formula.
 *
 *  Per-class equations (no per-class α/β yet — Phase 3d.3 is the
 *  ξ_pc / Σ_pc / ζ_pc generalization at K·n complexity):
 *
 *    I_d^{(k,i)}(t) = w_{k,i}(t)·I_a^{(k,i)}(t)
 *                   + (1 − w_{k,i}(t))·I_s^{(k,i)}(ρ_i · t)
 *
 *    I_a^{((k,i)→(k',j))}(t) = P_ex·I_d^{(k,i)}(t) + (1 − P_ex)
 *
 *    I_a^{(k',j)}(t) = (λ_0,k',j/α_{k',j})·I_a^{(0,k',j)}(t)
 *                    + Σ_{(k,i)} (α_{k,i}·P_ex/α_{k',j})·I_a^{((k,i)→(k',j))}(t)
 *
 *  Substituting gives (I − M_pc(t))·I_a_pc(t) = b_pc(t) with
 *
 *    M_pc[(k',j),(k,i)](t) = (α_{k,i}·P_ex²/α_{k',j}) · w_{k,i}(t)
 *
 *  Per-class weight w_{k,i}(t) per Whitt-You eq. (18) with the
 *  per-class flow rate α_{k,i} substituted for λ_i and the per-
 *  class limiting c²_a value (cc_ca_pc[k][i]) substituted in c²_x.
 *
 *  Per-class service IDC I_s^{(k,i)}(t) is renewal with SCV =
 *  cc_cs_var[k][i] (constant in t — until richer external IDCs
 *  arrive in a future phase).
 *
 *  Aggregation: I_a[i](t_k) = Σ_k (α_{k,i}/cc_alpha_total[i])·I_a^{(k,i)}(t_k).
 *  This per-station I_a feeds into the existing RQ wait formula. */
static int solve_perclass_idc_per_timescale(void)
{
    if (cc_K == 0 || !cc_have_var || cc_routing == NULL) return 0;
    int K = cc_K;
    size_t N = (size_t)K * (size_t)n;
    if (N == 0 || N > MAX_PERCLASS) return 0;

    double *A = (double *)calloc(N * N, sizeof(double));
    double *b = (double *)calloc(N, sizeof(double));
    if (!A || !b) { free(A); free(b); return 0; }

    #define IDX(kk, ii)  ((size_t)(kk) * (size_t)n + (size_t)(ii))
    #define PE(r, c)     cc_routing[(r) * N + (c)]
    #define AA(r, c)     A          [(r) * N + (c)]

    int s;
    for (s = 0; s < NUM_SCALES; s++) {
        double t_k = Ia[0].t[s];

        /* Per-class w_{k,i}(t_k) and per-class I_s^{(k,i)}(ρ_i·t_k). */
        double w_pc[MAX_CLASSES][MAX_NODES];
        double Is_rt_pc[MAX_CLASSES][MAX_NODES];
        for (int k = 0; k < K; k++) {
            for (int i = 0; i < n; i++) {
                double cx_pc = cc_ca_pc[k][i] + cc_cs_var[k][i];
                if (cx_pc > 0.0 && rho[i] > 0.0 && rho[i] < 1.0
                    && cc_alpha[k][i] > 1e-15) {
                    double arg = (1.0 - rho[i]) * (1.0 - rho[i])
                               * cc_alpha[k][i] * t_k
                               / (rho[i] * cx_pc);
                    w_pc[k][i] = canonical_w(arg);
                } else {
                    w_pc[k][i] = 1.0;  /* limiting (renewal) value */
                }
                /* Per-class service IDC at ρ_i·t (renewal: constant). */
                Is_rt_pc[k][i] = cc_cs_var[k][i];
            }
        }

        /* Phase 3d.3 — per-class β(t) at each destination.
         *
         *   β_pc(t)[d] = Σ_{sj<sk} 2·(ζ_pc[d,sj,sk] / α_d) · w*(arg_pair)
         *
         * with arg_pair built from the higher-utilization source of
         * the pair (j or k), mirroring the per-station Phase 3c form
         * but using per-class α and per-class c²_x at (src→dst). */
        double beta_pc_t[MAX_PERCLASS];
        if (have_pc_ab) {
            int N_int = (int)N;
            for (int d = 0; d < N_int; d++) beta_pc_t[d] = 0.0;
            for (int d = 0; d < N_int; d++) {
                int dk = d / n, di = d % n;
                double a_dst = cc_alpha[dk][di];
                if (a_dst < 1e-15) continue;
                for (int sj = 0; sj < N_int; sj++) {
                    int sj_i = sj % n;
                    if (rho[sj_i] <= 0.0 || rho[sj_i] >= 1.0) continue;
                    for (int sk = sj + 1; sk < N_int; sk++) {
                        double zjk = PC_AT3(zeta_pc, d, sj, sk);
                        if (fabs(zjk) < 1e-30) continue;
                        int sk_i = sk % n;
                        if (rho[sk_i] <= 0.0 || rho[sk_i] >= 1.0) continue;
                        /* Higher-ρ source dictates the timescale. */
                        int hi = (rho[sj_i] >= rho[sk_i]) ? sj : sk;
                        int hi_k = hi / n, hi_i = hi % n;
                        double cxhi = PC_AT(c2x_pc, hi, d);
                        if (cxhi <= 0.0) continue;
                        double pjid = PC_PE(hi, d);
                        if (pjid <= 0.0) continue;
                        double a_hi = cc_alpha[hi_k][hi_i];
                        double arg = (1.0 - rho[hi_i]) * (1.0 - rho[hi_i])
                                   * pjid * a_hi * t_k
                                   / (rho[hi_i] * cxhi);
                        beta_pc_t[d] += 2.0 * (zjk / a_dst) * canonical_w(arg);
                    }
                }
            }
        }

        /* Build (I − M_pc(t_k))·I_a_pc = b_pc. */
        for (int k_dst = 0; k_dst < K; k_dst++) {
            for (int j_dst = 0; j_dst < n; j_dst++) {
                size_t row = IDX(k_dst, j_dst);
                double a_kj = cc_alpha[k_dst][j_dst];

                /* Identity row */
                for (size_t c = 0; c < N; c++) AA(row, c) = 0.0;
                AA(row, row) = 1.0;

                if (a_kj < 1e-15) {
                    b[row] = 1.0;
                    continue;
                }
                /* External arrival contribution at this timescale.
                 * For renewal externals the IDC is constant = SCV at
                 * every timescale, so we plug the per-(k,i) SCV
                 * (cc_ca0_pc) directly. With the trailing block absent,
                 * defaults to 1 (Poisson). Richer (non-renewal) external
                 * IDCs would replace this constant with a per-source
                 * IDC evaluated at t_k — deferred until the .qna format
                 * carries distribution-shape data. */
                double ca0_kj = cc_have_ca0 ? cc_ca0_pc[k_dst][j_dst] : 1.0;
                b[row] = (cc_lambda_ext[k_dst][j_dst] / a_kj) * ca0_kj;
                /* Phase 3d.3 — β(t) at destination */
                if (have_pc_ab) b[row] += beta_pc_t[(int)row];

                for (int k_src = 0; k_src < K; k_src++) {
                    for (int i_src = 0; i_src < n; i_src++) {
                        size_t col = IDX(k_src, i_src);
                        double a_ki = cc_alpha[k_src][i_src];
                        if (a_ki < 1e-15) continue;
                        double pex = PE(col, row);
                        if (pex < 1e-15) continue;
                        double frac = a_ki * pex / a_kj;
                        double w = w_pc[k_src][i_src];
                        /* M coefficient: M_pc[row,col] = frac · pex · w */
                        AA(row, col) -= frac * pex * w;
                        /* Constants */
                        b[row] += frac * (1.0 - pex);
                        b[row] += frac * pex * (1.0 - w) * Is_rt_pc[k_src][i_src];
                        /* Phase 3d.3 — α(t) at the splitter */
                        if (have_pc_ab)
                            b[row] += frac * PC_AT(c2_alpha_pc, col, row) * w;
                    }
                }
            }
        }

        /* Heap-Gauss with partial pivoting. */
        for (size_t col = 0; col < N; col++) {
            double mv = fabs(AA(col, col));
            size_t mr = col;
            for (size_t r = col + 1; r < N; r++) {
                if (fabs(AA(r, col)) > mv) { mv = fabs(AA(r, col)); mr = r; }
            }
            if (mr != col) {
                for (size_t c = 0; c < N; c++) {
                    double t = AA(col, c); AA(col, c) = AA(mr, c); AA(mr, c) = t;
                }
                double t = b[col]; b[col] = b[mr]; b[mr] = t;
            }
            double pv = AA(col, col);
            if (fabs(pv) < 1e-15) { free(A); free(b); return 0; }
            for (size_t r = col + 1; r < N; r++) {
                double f = AA(r, col) / pv;
                if (f == 0.0) continue;
                for (size_t c = col; c < N; c++) AA(r, c) -= f * AA(col, c);
                b[r] -= f * b[col];
            }
        }
        for (long i = (long)N - 1; i >= 0; i--) {
            double sv = b[i];
            for (size_t c = (size_t)i + 1; c < N; c++) sv -= AA((size_t)i, c) * b[c];
            b[(size_t)i] = sv / AA((size_t)i, (size_t)i);
        }

        /* Aggregate per-class → per-station I_a at this timescale. */
        for (int i = 0; i < n; i++) {
            double tot = cc_alpha_total[i];
            if (tot < 1e-15) { Ia[i].v[s] = 1.0; continue; }
            double agg = 0.0;
            for (int k = 0; k < K; k++)
                agg += (cc_alpha[k][i] / tot) * b[IDX(k, i)];
            Ia[i].v[s] = agg;
        }

        /* Recover per-station I_d from the per-station I_a using the
         * existing per-station weight (consistent with Phase 3c). The
         * per-class I_d values are implicit in the next timescale's
         * input but not stored separately in Phase 3d.2. */
        for (int i = 0; i < n; i++) {
            double w_i = idc_weight(t_k, rho[i], lam[i],
                                    c2a_inf[i], cs_t[i]);
            Id[i].v[s] = w_i * Ia[i].v[s]
                       + (1.0 - w_i) * idc_eval(&Is[i], rho[i] * t_k);
        }
    }

    free(A); free(b);
    #undef IDX
    #undef PE
    #undef AA
    return 1;
}

/* ============================================================
 *  Phase 3c — α/β correction terms (Whitt-You eqs. 25, 29-30)
 * ============================================================
 *
 *  α_{i,j}(t) accounts for the fact that when a queue's departures
 *  are split via Markovian routing, the resulting sub-streams are
 *  NOT independent in the presence of feedback (eq. 24).
 *
 *  β_i(t) accounts for the dependence between superposed arrival
 *  streams that share a common origin (eq. 28).
 *
 *  Both corrections vanish for tree-structured (feed-forward, no
 *  shared-origin) networks. They are non-zero on Lu-Kumar /
 *  Bramson / Kumar-Seidman, which is the regime Phase 3c targets. */

static double xi[MAX_NODES][MAX_NODES];    /* (I − P')⁻¹ */
static double Sig[MAX_NODES][MAX_NODES][MAX_NODES];  /* Σ_l[i][j] per station l */
static double Mbk[MAX_NODES][MAX_NODES];   /* diag(c²_{a,0,m}·λ₀,m) + Σ_l Σ_l */
static double c2_alpha[MAX_NODES][MAX_NODES];  /* α(∞) = 2·ξ_{i,j}·p_{i,j}·(1−p_{i,j}) */
static double c2_beta[MAX_NODES];               /* β(∞) = (2/λ_i)·Σ_{j<k} ζ_{j,i;k,i} */
static double zeta[MAX_NODES][MAX_NODES][MAX_NODES];   /* zeta[i][j][k] = ζ_{j,i;k,i} */

/* c²_{x,j,i} = p_{j,i}·c²_{a,j} + (1−p_{j,i}) + p_{j,i}·c²_{s,j} per (j,i),
 * needed in the per-timescale β formula (eq. 29). Filled after the
 * limiting solve once c²_{a,j} is known. */
static double c2x_ji[MAX_NODES][MAX_NODES];

/* Compute ξ = (I − P')⁻¹ by solving (I − P') · X = I column-by-column. */
static void compute_xi(void)
{
    int i, j, k;
    for (j = 0; j < n; j++) {
        double A[MAX_NODES][MAX_NODES], rhs[MAX_NODES];
        for (i = 0; i < n; i++) {
            for (k = 0; k < n; k++)
                A[i][k] = (i == k ? 1.0 : 0.0) - Qt[k][i];
            rhs[i] = (i == j) ? 1.0 : 0.0;
        }
        if (gauss_solve(A, rhs, n)) {
            fprintf(stderr, "bna_rqna: singular (I − P') matrix\n");
            exit(EXIT_FAILURE);
        }
        for (i = 0; i < n; i++) xi[i][j] = rhs[i];
    }
}

/* Σ_l[i][j] = covariance of routing decisions at station l:
 *    Σ_l[i][i] =  p_{l,i} · (1 − p_{l,i}) · λ_l         (variance of "go to i")
 *    Σ_l[i][j] = −p_{l,i} · p_{l,j} · λ_l    (i ≠ j)    (covariance of "go to i" vs "go to j") */
static void compute_Sigma_per_station(void)
{
    int l, i, j;
    for (l = 0; l < n; l++) {
        for (i = 0; i < n; i++) {
            for (j = 0; j < n; j++) {
                if (i == j) Sig[l][i][i] = Qt[l][i] * (1.0 - Qt[l][i]) * lam[l];
                else        Sig[l][i][j] = -Qt[l][i] * Qt[l][j] * lam[l];
            }
        }
    }
}

/* Mbk = diag(c²_{a,0,m}·λ₀,m) + Σ_{l=1..K} Σ_l. K×K, computed once. */
static void compute_Mbrack(void)
{
    int i, j, l;
    for (i = 0; i < n; i++)
        for (j = 0; j < n; j++) Mbk[i][j] = 0.0;
    for (i = 0; i < n; i++) Mbk[i][i] = ca0_sq[i] * lambda0[i];
    for (l = 0; l < n; l++)
        for (i = 0; i < n; i++)
            for (j = 0; j < n; j++)
                Mbk[i][j] += Sig[l][i][j];
}

/* ζ_{j,i;k,i} per eq. (30). Needs ν_l(i) = p_{l,i} · ξ[l,:] (1×n row). */
static void compute_zeta(void)
{
    int dst, src_j, src_k, m, p;
    for (dst = 0; dst < n; dst++) {
        /* Cache ν_l(dst) for all l. nu[l][m] = p_{l,dst}·ξ[l][m]. */
        double nu[MAX_NODES][MAX_NODES];
        for (int l = 0; l < n; l++) {
            double pli = Qt[l][dst];
            for (m = 0; m < n; m++) nu[l][m] = pli * xi[l][m];
        }
        for (src_j = 0; src_j < n; src_j++) {
            for (src_k = 0; src_k < n; src_k++) {
                if (src_j == src_k) { zeta[dst][src_j][src_k] = 0.0; continue; }
                /* t1 = ν_j' · Mbk · ν_k */
                double t1 = 0.0;
                for (m = 0; m < n; m++) {
                    double tmp = 0.0;
                    for (p = 0; p < n; p++) tmp += Mbk[m][p] * nu[src_k][p];
                    t1 += nu[src_j][m] * tmp;
                }
                /* t2 = ν_k' · Σ_j · e_dst = Σ_m nu[k][m] · Σ_j[m][dst] */
                double t2 = 0.0;
                for (m = 0; m < n; m++)
                    t2 += nu[src_k][m] * Sig[src_j][m][dst];
                /* t3 = ν_j' · Σ_k · e_dst */
                double t3 = 0.0;
                for (m = 0; m < n; m++)
                    t3 += nu[src_j][m] * Sig[src_k][m][dst];
                zeta[dst][src_j][src_k] = t1 + t2 + t3;
            }
        }
    }
}

/* Compute the limiting α and β values from primitives. Independent
 * of c²_a so they can be done before solving the limiting equations. */
static void compute_alpha_beta_constants(void)
{
    int i, j, k;
    compute_xi();
    compute_Sigma_per_station();
    compute_Mbrack();
    compute_zeta();
    /* c²_α[i][j] = 2·ξ_{i,j}·p_{i,j}·(1−p_{i,j}) */
    for (i = 0; i < n; i++)
        for (j = 0; j < n; j++)
            c2_alpha[i][j] = 2.0 * xi[i][j] * Qt[i][j] * (1.0 - Qt[i][j]);
    /* c²_β[i] = (2/λ_i)·Σ_{j<k} ζ_{j,i;k,i} */
    for (i = 0; i < n; i++) {
        double sum = 0.0;
        for (j = 0; j < n; j++)
            for (k = j + 1; k < n; k++)
                sum += zeta[i][j][k];
        c2_beta[i] = (lam[i] > 1e-15) ? 2.0 * sum / lam[i] : 0.0;
    }
}

static void solve_network_idcs(void)
{
    int i, j, s;
    double t_ref = 0.0;
    int count = 0;
    for (i = 0; i < n; i++)
        if (tau[i] > 0.0) { t_ref += tau[i]; count++; }
    t_ref = (count > 0) ? t_ref / (double)count : 1.0;

    /* Initialize all per-station IDCs on a shared grid. */
    for (i = 0; i < n; i++) {
        idc_init_grid(&Ia0[i], t_ref); idc_renewal_c2(&Ia0[i], ca0_sq[i]);
        idc_init_grid(&Is[i],  t_ref); idc_renewal_c2(&Is[i],  cs_t[i]);
        idc_init_grid(&Ia[i],  t_ref);
        idc_init_grid(&Id[i],  t_ref);
    }

    /* Proportions: p_0i = λ₀_i/λ_i; pj_i = λ_j·p_j,i/λ_i = λ_j·Qt[j][i]/λ_i. */
    double p0[MAX_NODES];
    double frac[MAX_NODES][MAX_NODES];   /* frac[i][j] = λ_j·p_j,i / λ_i */
    for (i = 0; i < n; i++) {
        if (lam[i] > 1e-15) {
            p0[i] = lambda0[i] / lam[i];
            for (j = 0; j < n; j++)
                frac[i][j] = lam[j] * Qt[j][i] / lam[i];
        } else {
            p0[i] = 1.0;
            for (j = 0; j < n; j++) frac[i][j] = 0.0;
        }
    }

    /* Phase 3c: α/β constants (depend only on routing/rates, not c²_a). */
    compute_alpha_beta_constants();
    /* Phase 3d.3: per-class α/β constants (no-op when per-class data
     * is unavailable). Built BEFORE the per-class limiting solve so
     * that solve includes the corrections. */
    int have_pc_ab_local = build_pc_alpha_beta();
    (void)have_pc_ab_local;

    /* ────────────────────────────────────────────────────────
     * STEP 1: Solve limiting variability (eq. 34) for c²_a,i.
     *   c²_a,i = Σ_j frac[i][j]·[p_{j,i}·c²_a,j + (1−p_{j,i}) + c²_α,j,i]
     *          + p0[i]·c²_a,0,i + c²_β,i
     * ──────────────────────────────────────────────────────── */
    {
        double A[MAX_NODES][MAX_NODES], b[MAX_NODES];
        for (i = 0; i < n; i++) {
            b[i] = p0[i] * ca0_sq[i] + c2_beta[i];
            for (j = 0; j < n; j++) {
                double pji = Qt[j][i];
                A[i][j] = (i == j ? 1.0 : 0.0) - frac[i][j] * pji;
                b[i] += frac[i][j] * (1.0 - pji);
                b[i] += frac[i][j] * c2_alpha[j][i];
            }
        }
        if (gauss_solve(A, b, n)) {
            fprintf(stderr, "bna_rqna: singular limiting-variability matrix\n");
            exit(EXIT_FAILURE);
        }
        for (i = 0; i < n; i++) c2a_inf[i] = b[i];
    }

    /* Phase 3d.1: per-class limiting variability — fills cc_ca_pc[k][i]
     * with the K·n c²_a values, then aggregates to per-station c2a_inf[i].
     * The per-station per-timescale solve below uses these as the
     * asymptote in w_i(t). With Phase 3d.3 in place this also includes
     * the per-class α/β corrections. */
    int have_per_class = solve_perclass_limiting_variability();
    if (have_per_class && !compact) {
        fprintf(stderr,
            "bna_rqna: using per-class limiting variability (K=%d, K·n=%d%s)\n",
            cc_K, cc_K * n, have_pc_ab ? ", with α/β" : "");
    }
    /* Phase 3d.3: now that cc_ca_pc is filled, compute c²_x_pc which
     * drives the per-class β(t) in the per-timescale solve. */
    if (have_per_class && have_pc_ab) compute_c2x_pc();

    /* Now that c²_a is known, fill c²_{x,j,i} = p_{j,i}·c²_{a,j} +
     * (1−p_{j,i}) + p_{j,i}·c²_{s,j} for use in the per-timescale β. */
    {
        int src, dst;
        for (src = 0; src < n; src++) {
            for (dst = 0; dst < n; dst++) {
                double p = Qt[src][dst];
                c2x_ji[src][dst] = p * c2a_inf[src] + (1.0 - p) + p * cs_t[src];
            }
        }
    }

    /* ────────────────────────────────────────────────────────
     * STEP 2: At each timescale, build M(t_k), b(t_k), solve.
     * ──────────────────────────────────────────────────────── */
    for (s = 0; s < NUM_SCALES; s++) {
        double t_k = Ia[0].t[s];

        /* Per-station weight w_j(t_k) — eq. (18). */
        double wj[MAX_NODES];
        for (j = 0; j < n; j++) {
            wj[j] = idc_weight(t_k, rho[j], lam[j], c2a_inf[j], cs_t[j]);
        }

        /* Per-station I_s,j(ρ_j · t_k) via eval. */
        double Is_rt[MAX_NODES];
        for (j = 0; j < n; j++) {
            Is_rt[j] = idc_eval(&Is[j], rho[j] * t_k);
        }

        /* Build (I − M(t_k)) and b(t_k), with α(t) and β(t). */
        double A[MAX_NODES][MAX_NODES], b[MAX_NODES];

        /* β_i(t) = Σ_{j<k} 2·(ζ_{j,i;k,i}/λ_i)·w*((1−ρ_max)²·p_max,i·λ_max·t
         *                                         /(ρ_max·c²_{x,max,i}))
         * where max = j or k, whichever has higher utilization. */
        double beta_t[MAX_NODES];
        for (i = 0; i < n; i++) beta_t[i] = 0.0;
        for (i = 0; i < n; i++) {
            if (lam[i] <= 1e-15) continue;
            int j2, k2;
            for (j2 = 0; j2 < n; j2++) {
                for (k2 = j2 + 1; k2 < n; k2++) {
                    double zjk = zeta[i][j2][k2];
                    if (fabs(zjk) < 1e-30) continue;
                    /* Pick higher-ρ source as the "j" in eq. 29 */
                    int hi = (rho[j2] >= rho[k2]) ? j2 : k2;
                    if (rho[hi] <= 0.0 || rho[hi] >= 1.0) continue;
                    double cxhi = c2x_ji[hi][i];
                    if (cxhi <= 0.0) continue;
                    double pji = Qt[hi][i];
                    if (pji <= 0.0) continue;
                    double arg = (1.0 - rho[hi]) * (1.0 - rho[hi])
                               * pji * lam[hi] * t_k
                               / (rho[hi] * cxhi);
                    /* β symmetry: β_{j,i;k,i} = β_{k,i;j,i} so the
                     * unordered pair contributes 2·ζ/λ_i·w*. */
                    beta_t[i] += 2.0 * (zjk / lam[i]) * canonical_w(arg);
                }
            }
        }

        for (i = 0; i < n; i++) {
            b[i] = p0[i] * Ia0[i].v[s] + beta_t[i];
            for (j = 0; j < n; j++) {
                double pji = Qt[j][i];
                /* M_ij(t) = frac[i][j] · p_j,i · w_j(t) */
                A[i][j] = (i == j ? 1.0 : 0.0) - frac[i][j] * pji * wj[j];
                /* b_i(t): I_s splitting residue + service contribution */
                b[i] += frac[i][j] * pji * (1.0 - wj[j]) * Is_rt[j];
                b[i] += frac[i][j] * (1.0 - pji);
                /* α_{j,i}(t) = c²_α[j][i] · w_j(t)  per eq. 25 */
                b[i] += frac[i][j] * c2_alpha[j][i] * wj[j];
            }
        }
        if (gauss_solve(A, b, n)) {
            fprintf(stderr, "bna_rqna: singular IDC matrix at scale %d\n", s);
            exit(EXIT_FAILURE);
        }
        for (i = 0; i < n; i++) Ia[i].v[s] = b[i];

        /* Recover I_d via eq. (17). */
        for (i = 0; i < n; i++) {
            Id[i].v[s] = wj[i] * Ia[i].v[s] + (1.0 - wj[i]) * Is_rt[i];
        }
    }

    /* Phase 3d.2: per-class IDC at every timescale overrides the
     * per-station Ia/Id values computed above, when per-class data is
     * available. Keeps the per-station results as a fallback. */
    if (have_per_class) {
        if (solve_perclass_idc_per_timescale() && !compact) {
            fprintf(stderr,
                "bna_rqna: per-class IDC propagation active at all %d timescales%s\n",
                NUM_SCALES, have_pc_ab ? ", with α/β" : "");
        }
    }
    free_pc_arrays();
}

/* ================================================================
 *  Whitt-You §2.2 robust-queueing wait formula  (eq. 12)
 * ================================================================
 *
 *  For a stable G/GI/1 queue (rate λ, service mean 1/μ, service
 *  SCV c²_s, total-arrival IDC I_a):
 *
 *     E[Z] ≈ Z* ≡ sup_{x≥0} { −(1−ρ)x + √2 · √(ρx(I_a(x) + c²_s)/μ) }
 *
 *     E[W] ≈ max{0, Z* / ρ − (c²_s + 1)/(2μ)}      (Brumelle, Remark 5)
 *
 *  The constant b = √2 makes this asymptotically EXACT in heavy
 *  traffic (Whitt-You 2018 Theorem 5) and reproduces:
 *     - M/M/1: E[W] = ρ/(μ(1−ρ))      EXACTLY
 *     - M/G/1: E[W] = ρ(1+c²_s)/(2μ(1−ρ))  (Pollaczek-Khinchine) EXACTLY
 *
 *  Differs from Kingman's `(c²_a + c²_s)/2` form by a (c²_a − 1)/(2μ)
 *  term, which goes to zero for Poisson arrivals.
 *
 *  Multi-server (m ≥ 2) is not handled by Whitt-You directly. We
 *  fall back to BNAqna's Allen-Cunneen formula `E[W] = Cm · E[S] ·
 *  (I_a(∞) + I_s(∞)/√m) / (2m(1−ρ))` with Cm = Erlang-C(m, ρm).
 *
 *  Implementation: discrete supremum over a fine log-spaced grid
 *  of x bracketing the constant-IDC analytical optimum
 *  x*_const = ρ(c²_a + c²_s)/(2μ(1−ρ)²). We sample 200 points
 *  spanning [x*_const · 1e-4, x*_const · 1e+4]. Cost is negligible
 *  (≈ 200 idc_eval calls × n stations). */

static double erlang_c(int servers, double offered)
{
    if (servers == 1) return offered;  /* C(1, ρ) = ρ */
    int k;
    double sum = 1.0, term = 1.0;
    for (k = 1; k < servers; k++) {
        term *= offered / (double)k;
        sum += term;
    }
    double last = term * offered / (double)servers;
    last = last * (double)servers / ((double)servers - offered);
    return last / (sum + last);
}

/* Per-station outputs */
static double EW[MAX_NODES];     /* mean waiting time */
static double EN[MAX_NODES];     /* mean number in system */
static double ET[MAX_NODES];     /* mean sojourn time */
static double Pw0[MAX_NODES];    /* P(wait > 0) */
static double t_star[MAX_NODES]; /* operating timescale */
static double Ia_at_tstar[MAX_NODES]; /* I_a(t*) — for diagnostic */
static double Is_at_tstar[MAX_NODES]; /* I_s(t*) */

/* RQ supremum wait formula at one station (m=1 case).
 *
 * Returns E[W] in the feedback-eliminated system. Diagnostics:
 *   x_star_out — the timescale at which the supremum is achieved
 *   Ia_t_out   — I_a evaluated at x_star
 *   Is_t_out   — I_s evaluated at x_star (averaged with cs2 inside the formula) */
#define RQ_GRID_PTS 200

static double rq_wait_station_m1(double rho_i, double mu_i,
                                 const Idc *Iai, double cs2_i,
                                 double *x_star_out,
                                 double *Ia_t_out)
{
    double ca2_inf = Iai->v[NUM_SCALES - 1];
    double cx = ca2_inf + cs2_i;
    if (cx <= 0.0 || rho_i <= 0.0 || rho_i >= 1.0) {
        if (x_star_out) *x_star_out = 0.0;
        if (Ia_t_out)   *Ia_t_out   = ca2_inf;
        return 0.0;
    }

    /* Constant-IDC analytical optimum (initial centering). */
    double x_const = rho_i * cx / (2.0 * mu_i * (1.0 - rho_i) * (1.0 - rho_i));

    /* Search range: 1e-4 to 1e+4 of the analytical optimum, log-spaced. */
    double lo = log(x_const * 1e-4);
    double hi = log(x_const * 1e+4);
    double dlog = (hi - lo) / (double)(RQ_GRID_PTS - 1);

    double Z_max = 0.0;     /* sup is over x ≥ 0; x=0 gives 0 */
    double x_at_max = x_const;
    double Ia_at_max = ca2_inf;
    int k_max = -1;
    double f_grid[RQ_GRID_PTS];
    int k;
    for (k = 0; k < RQ_GRID_PTS; k++) {
        double x = exp(lo + (double)k * dlog);
        double Ia_x = idc_eval(Iai, x);
        double inner = rho_i * x * (Ia_x + cs2_i) / mu_i;
        if (inner < 0.0) { f_grid[k] = -1e30; continue; }
        double f = -(1.0 - rho_i) * x + sqrt(2.0) * sqrt(inner);
        f_grid[k] = f;
        if (f > Z_max) {
            Z_max = f;
            x_at_max = x;
            Ia_at_max = Ia_x;
            k_max = k;
        }
    }

    /* Parabolic refinement: fit a parabola in log-x to the three
     * points around the discrete maximum and locate the analytic
     * vertex. Recovers true sup to machine precision when the IDC
     * is constant (M/M/1, M/G/1) and to O(grid_spacing²) generally. */
    if (k_max > 0 && k_max < RQ_GRID_PTS - 1) {
        double f_m = f_grid[k_max - 1];
        double f_0 = f_grid[k_max];
        double f_p = f_grid[k_max + 1];
        double denom = (f_m - 2.0 * f_0 + f_p);
        if (denom < -1e-30) {                  /* concave-down parabola */
            double delta = 0.5 * (f_m - f_p) / denom;  /* in dlog units */
            if (delta > -1.0 && delta < 1.0) {
                double x_refined = exp(lo + ((double)k_max + delta) * dlog);
                double Ia_r = idc_eval(Iai, x_refined);
                double inner_r = rho_i * x_refined * (Ia_r + cs2_i) / mu_i;
                if (inner_r >= 0.0) {
                    double f_r = -(1.0 - rho_i) * x_refined
                               + sqrt(2.0) * sqrt(inner_r);
                    if (f_r > Z_max) {
                        Z_max = f_r;
                        x_at_max = x_refined;
                        Ia_at_max = Ia_r;
                    }
                }
            }
        }
    }

    /* Brumelle relation: E[W] = Z* divided by ρ, minus (c²_s + 1)/(2μ). */
    double EW_val = Z_max / rho_i - (cs2_i + 1.0) / (2.0 * mu_i);
    if (EW_val < 0.0) EW_val = 0.0;

    if (x_star_out) *x_star_out = x_at_max;
    if (Ia_t_out)   *Ia_t_out   = Ia_at_max;
    return EW_val;
}

/* For each station: solve the RQ supremum (m=1) or fall back to
 * Allen-Cunneen for m≥2, derive EW (undoing feedback), then EN, ET,
 * Pw0. Mirrors BNAqna's compute_congestion field-for-field. */
static void compute_congestion(void)
{
    int i;
    for (i = 0; i < n; i++) {
        double ew_fb;
        double xs = 0.0, ia_xs = 0.0;
        double mu_i = 1.0 / tau_t[i];

        if (m_serv[i] == 1) {
            ew_fb = rq_wait_station_m1(rho[i], mu_i, &Ia[i], cs_t[i],
                                       &xs, &ia_xs);
        } else {
            /* Multi-server: Whitt-You §2.2 covers single-server only.
             *
             * We use Allen-Cunneen with c²_a evaluated at the diffusion
             * relaxation timescale t* = 1/(m·μ·(1−ρ)²) — the timescale
             * at which the GI/G/m heavy-traffic limit governs E[W].
             *
             *    E[W] = Cm · E[S] / (m·(1−ρ)) · (I_a(t*) + c²_s) / 2
             *    Cm   = Erlang-C(m, ρ·m)
             *
             * Properties:
             *   • EXACT for M/M/m (IDC ≡ 1, c²_s = 1 ⇒ correction = 1).
             *   • Reduces to Allen-Cunneen with renewal asymptote when
             *     IDC has converged by t*; uses the RQNA timescale-
             *     dependent c²_a otherwise.
             *   • Replaces the older Whitt-1993-style (c²_a + c²_s/√m)/2
             *     correction, which under-predicted M/M/m E[W] by
             *     15–25% (e.g., 14% off at M/M/2 ρ=0.5; 25% off at M/M/4
             *     ρ=0.5). The Whitt 1993 form was accurate for GI/D/m
             *     but biased for c²_s near 1; Allen-Cunneen is the
             *     safer default and matches BNAqna's m>1 behavior. */
            double m_d = (double)m_serv[i];
            double Cm = erlang_c(m_serv[i], rho[i] * m_d);
            double t_ht = 1.0 / (m_d * mu_i * (1.0 - rho[i]) * (1.0 - rho[i]));
            double ca2_t = idc_eval(&Ia[i], t_ht);
            ew_fb = (Cm * tau_t[i] / (m_d * (1.0 - rho[i])))
                  * 0.5 * (ca2_t + cs_t[i]);
            xs = t_ht;
            ia_xs = ca2_t;
        }

        EW[i] = (1.0 - qii_orig[i]) * ew_fb;
        ET[i] = tau[i] + EW[i];
        EN[i] = lam[i] * ET[i];

        if (m_serv[i] == 1) {
            Pw0[i] = rho[i];
        } else {
            Pw0[i] = erlang_c(m_serv[i], rho[i] * (double)m_serv[i]);
        }
        if (Pw0[i] < 0.0) Pw0[i] = 0.0;
        if (Pw0[i] > 1.0) Pw0[i] = 1.0;

        t_star[i]      = xs;
        Ia_at_tstar[i] = ia_xs;
        Is_at_tstar[i] = idc_eval(&Is[i], xs);
    }
}

/* ================================================================
 *  Network self-test: 2-station tandem M/M/1 (Burke's theorem)
 * ================================================================
 *
 *  Network: external Poisson rate λ=1 at station 1; both stations
 *  M/M/1 with τ=0.5 (so ρ=0.5); deterministic routing 1 → 2 → out.
 *  Burke's theorem says departures from each M/M/1 are Poisson, so
 *  Ia and Id at every station should be ≡ 1 at every timescale.
 *  This exercises every Phase 2 piece end-to-end. */
static int test_tandem_mm1(void)
{
    /* Set up an in-memory 2-station network */
    n = 2;
    m_serv[0] = 1; m_serv[1] = 1;
    lambda0[0] = 1.0; lambda0[1] = 0.0;
    ca0_sq[0]  = 1.0; ca0_sq[1]  = 1.0;
    tau[0]     = 0.5; tau[1]     = 0.5;
    cs_sq[0]   = 1.0; cs_sq[1]   = 1.0;
    Q[0][0] = 0.0; Q[0][1] = 1.0;
    Q[1][0] = 0.0; Q[1][1] = 0.0;

    eliminate_feedback();
    solve_traffic_rates();
    solve_network_idcs();

    int i, k;
    for (i = 0; i < n; i++) {
        for (k = 0; k < NUM_SCALES; k++) {
            if (!approx_eq(Ia[i].v[k], 1.0, 1e-12)) {
                printf("  FAIL  Tandem M/M/1: I_a^(%d)(t=%g) = %g, expected 1.0\n",
                       i + 1, Ia[i].t[k], Ia[i].v[k]);
                return 1;
            }
            if (!approx_eq(Id[i].v[k], 1.0, 1e-12)) {
                printf("  FAIL  Tandem M/M/1: I_d^(%d)(t=%g) = %g, expected 1.0\n",
                       i + 1, Id[i].t[k], Id[i].v[k]);
                return 1;
            }
        }
    }
    printf("  PASS  Tandem M/M/1 (ρ=0.5): I_a ≡ I_d ≡ 1 at both stations "
           "(Burke's theorem)\n");
    return 0;
}

/* ================================================================
 *  Phase 3 self-tests: canonical w*, idc_eval, wait formula
 * ================================================================ */

static int test_canonical_w(void)
{
    /* Boundary behavior */
    if (canonical_w(0.0) != 0.0) {
        printf("  FAIL  w*(0) ≠ 0: got %g\n", canonical_w(0.0));
        return 1;
    }
    /* w*(∞) → 1: at t=1000, asymptote 1 − 1/2000 = 0.9995 */
    double w_big = canonical_w(1000.0);
    if (!approx_eq(w_big, 1.0 - 0.5 / 1000.0, 1e-10)) {
        printf("  FAIL  w*(1000): got %.10f, expected 0.9995\n", w_big);
        return 1;
    }
    /* Monotonicity: 100-point log-spaced grid */
    double prev = 0.0;
    int k;
    for (k = 0; k < 100; k++) {
        double t = exp(-10.0 + 0.2 * (double)k);  /* 10^-4.34 to 10^8.69 */
        double w = canonical_w(t);
        if (w < prev - 1e-10) {
            printf("  FAIL  w* not monotonic at t=%g: w=%g < prev=%g\n",
                   t, w, prev);
            return 1;
        }
        if (w < 0.0 || w > 1.0 + 1e-10) {
            printf("  FAIL  w* out of [0,1] at t=%g: got %g\n", t, w);
            return 1;
        }
        prev = w;
    }
    /* Spot check: w*(1) should be in [0.6, 0.7] (numerical: ≈ 0.667) */
    double w1 = canonical_w(1.0);
    if (w1 < 0.6 || w1 > 0.72) {
        printf("  FAIL  w*(1): got %g, expected ≈ 0.667\n", w1);
        return 1;
    }
    /* Series leading-order: w*(t) ≈ (4/3)·√(2/π)·√t for small t.
     * Verify the small-t branch tracks this to <1% at t=1e-8. */
    double small_t = 1e-8;
    double w_small = canonical_w(small_t);
    double w_pred  = (4.0 / 3.0) * sqrt(2.0 / M_PI) * sqrt(small_t);
    if (fabs(w_small - w_pred) / w_pred > 0.01) {
        printf("  FAIL  w*(1e-8) = %.6e, leading-order prediction %.6e (diff > 1%%)\n",
               w_small, w_pred);
        return 1;
    }
    printf("  PASS  canonical w*: w*(0)=0, w*(∞)→1, monotonic, "
           "w*(1)≈%.4f, series↔formula consistent\n", w1);
    return 0;
}



static int test_idc_eval(void)
{
    /* Constant IDC: every interpolation point should hit the constant. */
    Idc I;
    idc_init_grid(&I, 1.0);
    idc_set_const(&I, 2.5);
    double samples[] = {0.001, 0.5, 1.0, 7.3, 1000.0};
    int i;
    for (i = 0; i < 5; i++) {
        double v = idc_eval(&I, samples[i]);
        if (!approx_eq(v, 2.5, 1e-12)) {
            printf("  FAIL  idc_eval(const=2.5) at t=%g: got %g\n",
                   samples[i], v);
            return 1;
        }
    }

    /* Linear-in-log: I.v = log(t) (set values manually so we know
     * the interpolation answers). */
    int k;
    for (k = 0; k < NUM_SCALES; k++) I.v[k] = log(I.t[k]);
    /* At a midpoint between grid points, log-linear interp should
     * give exactly log of that midpoint. */
    double t_mid = sqrt(I.t[3] * I.t[4]);  /* geometric midpoint */
    double v_got = idc_eval(&I, t_mid);
    double v_exp = log(t_mid);
    if (!approx_eq(v_got, v_exp, 1e-10)) {
        printf("  FAIL  idc_eval log-linear at t=%g: got %g, expected %g\n",
               t_mid, v_got, v_exp);
        return 1;
    }

    /* Clamp at boundaries */
    if (idc_eval(&I, 1e-10) != I.v[0] ||
        idc_eval(&I, 1e10)  != I.v[NUM_SCALES - 1]) {
        printf("  FAIL  idc_eval boundary clamp\n");
        return 1;
    }
    printf("  PASS  idc_eval: constant exact; log-linear midpoint exact; "
           "clamps at boundaries\n");
    return 0;
}

static int test_wait_mm1(void)
{
    /* M/M/1, ρ=0.5, E[S]=1: E[W] = ρ·E[S]/(1-ρ) · (1+1)/2 = 1.0 EXACTLY.
     * Whitt-You formula gives the same value as Kingman here because
     * the IDC is flat (Poisson + exp), so t* doesn't matter. */
    n = 1;
    m_serv[0] = 1;
    lambda0[0] = 0.5; ca0_sq[0] = 1.0;
    tau[0] = 1.0;     cs_sq[0]  = 1.0;
    Q[0][0] = 0.0;
    eliminate_feedback();
    solve_traffic_rates();
    solve_network_idcs();
    compute_congestion();
    if (!approx_eq(EW[0], 1.0, 1e-5)) {
        printf("  FAIL  M/M/1 ρ=0.5 E[S]=1: EW=%g, expected 1.0\n", EW[0]);
        return 1;
    }
    /* M/M/1 ρ=0.8 → E[W] = 0.8·1/0.2 = 4 */
    lambda0[0] = 0.8;
    eliminate_feedback();
    solve_traffic_rates();
    solve_network_idcs();
    compute_congestion();
    if (!approx_eq(EW[0], 4.0, 1e-5)) {
        printf("  FAIL  M/M/1 ρ=0.8 E[S]=1: EW=%g, expected 4.0\n", EW[0]);
        return 1;
    }
    printf("  PASS  M/M/1 wait formula: ρ=0.5 → 1.0; ρ=0.8 → 4.0 (exact)\n");
    return 0;
}

static int test_wait_mg1(void)
{
    /* M/G/1 with cs²=4, ρ=0.5, E[S]=1: Pollaczek-Khinchine
     *   E[W] = ρ·E[S]·(1 + cs²)/(2(1-ρ)) = 0.5·1·5/1 = 2.5 (EXACT).
     * Kingman with c_a²=1 (Poisson) reproduces P-K exactly, so this
     * is also a clean check on the formula. */
    n = 1;
    m_serv[0] = 1;
    lambda0[0] = 0.5; ca0_sq[0] = 1.0;
    tau[0] = 1.0;     cs_sq[0]  = 4.0;
    Q[0][0] = 0.0;
    eliminate_feedback();
    solve_traffic_rates();
    solve_network_idcs();
    compute_congestion();
    if (!approx_eq(EW[0], 2.5, 1e-5)) {
        printf("  FAIL  M/G/1 cs²=4 ρ=0.5: EW=%g, expected 2.5 (P-K)\n", EW[0]);
        return 1;
    }
    printf("  PASS  M/G/1 (cs²=4, ρ=0.5): EW = 2.5 (Pollaczek-Khinchine)\n");
    return 0;
}

/* ================================================================
 *  Multi-server self-test: M/M/m must match exact Erlang-C
 * ================================================================
 *
 *  Verifies the Allen-Cunneen-with-IDC-at-t* fallback (used in
 *  compute_congestion for m > 1) reproduces the exact M/M/m wait
 *  formula. For Poisson arrivals (IDC ≡ 1) and exponential service
 *  (c²_s = 1) the correction (I_a + c²_s)/2 = 1 exactly, so
 *  E[W] = Cm · E[S] / (m·(1−ρ)). */
static int test_wait_mmm(void)
{
    /* M/M/2, ρ = 0.5, E[S] = 1.   E[W] = C(2,1) / (2·0.5) = (1/3) / 1 = 1/3. */
    n = 1;
    m_serv[0] = 2;
    lambda0[0] = 1.0; ca0_sq[0] = 1.0;
    tau[0] = 1.0;     cs_sq[0]  = 1.0;
    Q[0][0] = 0.0;
    eliminate_feedback();
    solve_traffic_rates();
    solve_network_idcs();
    compute_congestion();
    double exp_mm2 = 1.0 / 3.0;
    if (!approx_eq(EW[0], exp_mm2, 1e-6)) {
        printf("  FAIL  M/M/2 ρ=0.5: EW=%.6g, expected %.6g\n", EW[0], exp_mm2);
        return 1;
    }

    /* M/M/4, ρ = 0.5, E[S] = 1. */
    m_serv[0] = 4;
    lambda0[0] = 2.0;
    eliminate_feedback();
    solve_traffic_rates();
    solve_network_idcs();
    compute_congestion();
    double Cm4 = erlang_c(4, 2.0);
    double exp_mm4 = Cm4 / (4.0 * 0.5);
    if (!approx_eq(EW[0], exp_mm4, 1e-6)) {
        printf("  FAIL  M/M/4 ρ=0.5: EW=%.6g, expected %.6g (= C(4,2)=%.6g / 2)\n",
               EW[0], exp_mm4, Cm4);
        return 1;
    }

    /* M/M/3 at high ρ = 0.9 (heavy traffic). */
    m_serv[0] = 3;
    lambda0[0] = 2.7;
    eliminate_feedback();
    solve_traffic_rates();
    solve_network_idcs();
    compute_congestion();
    double Cm3 = erlang_c(3, 2.7);
    double exp_mm3_ht = Cm3 / (3.0 * 0.1);
    if (!approx_eq(EW[0], exp_mm3_ht, 1e-5)) {
        printf("  FAIL  M/M/3 ρ=0.9: EW=%.6g, expected %.6g (heavy traffic)\n",
               EW[0], exp_mm3_ht);
        return 1;
    }

    /* Reset for any subsequent tests. */
    m_serv[0] = 1;
    n = 0;
    printf("  PASS  M/M/m wait: M/M/2 ρ=0.5 → 1/3; M/M/4 ρ=0.5 → C(4,2)/2; "
           "M/M/3 ρ=0.9 (exact Erlang-C)\n");
    return 0;
}

/* ================================================================
 *  External-SCV self-test: trailing ca0_pc block lifts the Poisson
 *  default and per-class limiting c²_a tracks the actual external
 *  variability.
 * ================================================================
 *
 *  2-station tandem (1 → 2, no feedback) with Erlang-4 external
 *  arrivals at station 1 (SCV = 0.25). The exact per-station
 *  Phase 3c result uses ca0_sq[0] = 0.25 directly. Phase 3d K=1
 *  with the trailing ca0_pc block populated must reproduce the
 *  same per-station c²_a values within 1e-9. Without the block
 *  (cc_have_ca0 = 0), Phase 3d would default to Poisson and the
 *  c²_a values would differ. */
static int test_external_scv_pc(void)
{
    n = 2;
    m_serv[0] = 1; m_serv[1] = 1;
    lambda0[0] = 0.5; lambda0[1] = 0.0;
    ca0_sq[0]  = 0.25; ca0_sq[1] = 1.0;   /* Erlang-4 at station 1 */
    tau[0]     = 1.0; tau[1]     = 1.0;
    cs_sq[0]   = 1.0; cs_sq[1]   = 1.0;
    Q[0][0] = 0.0; Q[0][1] = 1.0;
    Q[1][0] = 0.0; Q[1][1] = 0.0;

    /* (1) Phase 3c only — no per-class data. Uses ca0_sq directly. */
    cc_K = 0; cc_have_var = 0; cc_have_ca0 = 0;
    if (cc_routing) { free(cc_routing); cc_routing = NULL; }
    eliminate_feedback();
    solve_traffic_rates();
    solve_network_idcs();

    double ref[MAX_NODES];
    for (int i = 0; i < n; i++) ref[i] = c2a_inf[i];

    /* (2) Same network with K=1 per-class block AND ca0_pc block. */
    cc_K = 1;
    cc_have_var = 1;
    cc_have_ca0 = 1;
    cc_lambda[0] = lambda0[0];
    for (int i = 0; i < n; i++) {
        cc_lambda_ext[0][i] = lambda0[i];
        cc_cs_var[0][i] = cs_sq[i];
        cc_ca0_pc[0][i] = ca0_sq[i];   /* external SCV per (k=0, i) */
    }
    int N = cc_K * n;
    cc_routing = (double *)calloc((size_t)N * N, sizeof(double));
    if (!cc_routing) { printf("  FAIL  alloc cc_routing\n"); return 1; }
    for (int r = 0; r < N; r++)
        for (int c = 0; c < N; c++)
            cc_routing[r * N + c] = Q[r][c];

    eliminate_feedback();
    solve_traffic_rates();
    for (int i = 0; i < n; i++) {
        cc_alpha[0][i] = lam[i];
        cc_alpha_total[i] = lam[i];
    }
    solve_network_idcs();

    int fail = 0;
    for (int i = 0; i < n; i++) {
        if (!approx_eq(c2a_inf[i], ref[i], 1e-9)) {
            printf("  FAIL  ext-SCV K=1: c²_a[%d] = %.10g, expected %.10g (Phase 3c, ca0²=0.25)\n",
                   i + 1, c2a_inf[i], ref[i]);
            fail = 1;
        }
    }

    /* Sanity: c²_a,0 must equal the external SCV (single source, no
     * upstream feedback into station 0); with Erlang-4 input (SCV=0.25)
     * this should be exactly 0.25. */
    if (fabs(ref[0] - 0.25) > 1e-9) {
        printf("  FAIL  ext-SCV K=1: ref c²_a[1] = %.6g, expected 0.25 (Erlang-4 external)\n", ref[0]);
        fail = 1;
    }

    /* Cleanup */
    free(cc_routing); cc_routing = NULL;
    cc_K = 0; cc_have_var = 0; cc_have_ca0 = 0;
    for (int k = 0; k < MAX_CLASSES; k++)
        for (int i = 0; i < MAX_NODES; i++)
            cc_ca0_pc[k][i] = 1.0;

    if (fail) return 1;
    printf("  PASS  Per-class external SCV: Erlang-4 input (ca0²=0.25) propagates correctly; Phase 3d K=1 ↔ Phase 3c\n");
    return 0;
}

/* ================================================================
 *  Phase 3d.3 self-test: per-class α/β at K=1 reproduces Phase 3c
 * ================================================================
 *
 *  3-station network with a 2 → 0 feedback edge. Without feedback,
 *  ξ[i,j] = 0 for forward edges and α/β both vanish — the test would
 *  pass vacuously. With feedback, ξ has non-zero off-diagonals, so
 *  α at every splitter and β at the merge node are non-trivial.
 *
 *  We solve once via Phase 3c (no per-class data) and again with K=1
 *  per-class data populated — the per-class limiting c²_a must match
 *  the per-station Phase 3c c²_a within 1e-9, AND the result must
 *  deviate from c²_a ≡ 1 (otherwise the corrections aren't being
 *  exercised). */
static int test_pc_alpha_beta_k1_matches_3c(void)
{
    /* Setup */
    n = 3;
    m_serv[0] = 1; m_serv[1] = 1; m_serv[2] = 1;
    lambda0[0] = 0.4; lambda0[1] = 0.0; lambda0[2] = 0.0;
    ca0_sq[0]  = 1.0; ca0_sq[1]  = 1.0; ca0_sq[2]  = 1.0;
    tau[0]     = 1.0; tau[1]     = 1.0; tau[2]     = 1.0;
    cs_sq[0]   = 0.5; cs_sq[1]   = 1.5; cs_sq[2]   = 2.0;
    /* Routing: 0 → 1 (0.4), 0 → 2 (0.4), exit 0.2;
     *           1 → 2 (0.6), exit 0.4;
     *           2 → 0 (0.3), exit 0.7  ← feedback edge. */
    Q[0][0] = 0.0; Q[0][1] = 0.4; Q[0][2] = 0.4;
    Q[1][0] = 0.0; Q[1][1] = 0.0; Q[1][2] = 0.6;
    Q[2][0] = 0.3; Q[2][1] = 0.0; Q[2][2] = 0.0;

    /* (1) Phase 3c only — no per-class block. */
    cc_K = 0;
    cc_have_var = 0;
    if (cc_routing) { free(cc_routing); cc_routing = NULL; }
    eliminate_feedback();
    solve_traffic_rates();
    solve_network_idcs();

    double ref[MAX_NODES];
    int i;
    for (i = 0; i < n; i++) ref[i] = c2a_inf[i];

    /* (2) Same network with K=1 per-class block populated. */
    cc_K = 1;
    cc_have_var = 1;
    cc_lambda[0] = lambda0[0];
    for (i = 0; i < n; i++) {
        cc_lambda_ext[0][i] = lambda0[i];
        cc_cs_var[0][i] = cs_sq[i];
    }
    int N = cc_K * n;
    cc_routing = (double *)calloc((size_t)N * N, sizeof(double));
    if (!cc_routing) { printf("  FAIL  alloc cc_routing\n"); return 1; }
    int r, c;
    /* Q has no self-loops here, so Qt == Q. */
    for (r = 0; r < N; r++)
        for (c = 0; c < N; c++)
            cc_routing[r * N + c] = Q[r][c];

    eliminate_feedback();
    solve_traffic_rates();
    /* Fill cc_alpha[0][i] = lam[i] and cc_alpha_total[i] = lam[i]. */
    for (i = 0; i < n; i++) {
        cc_alpha[0][i] = lam[i];
        cc_alpha_total[i] = lam[i];
    }
    solve_network_idcs();

    int fail = 0;
    for (i = 0; i < n; i++) {
        if (!approx_eq(c2a_inf[i], ref[i], 1e-9)) {
            printf("  FAIL  Phase 3d.3 K=1: c²_a[%d] = %.10g, expected %.10g (Phase 3c)\n",
                   i + 1, c2a_inf[i], ref[i]);
            fail = 1;
        }
    }

    /* Sanity: at least one station's c²_a must differ from 1 by a
     * non-trivial margin, else the α/β code paths weren't exercised. */
    int corrections_active = 0;
    for (i = 0; i < n; i++) if (fabs(ref[i] - 1.0) > 1e-3) corrections_active = 1;
    if (!corrections_active) {
        printf("  FAIL  Phase 3d.3 K=1: c²_a ≡ 1 — α/β corrections not exercised\n");
        fail = 1;
    }

    /* Cleanup so subsequent tests start fresh. */
    free(cc_routing); cc_routing = NULL;
    cc_K = 0; cc_have_var = 0;

    if (fail) return 1;
    printf("  PASS  Phase 3d.3 K=1 ↔ Phase 3c c²_a: (%.6g, %.6g, %.6g) match within 1e-9\n",
           ref[0], ref[1], ref[2]);
    return 0;
}

/* ================================================================
 *  Arrival-IDC computation and printout
 * ================================================================ */

static void print_idc_row(const char *label, const Idc *I)
{
    int k;
    printf("    %-7s", label);
    for (k = 0; k < NUM_SCALES; k++) printf("%10.4g ", I->v[k]);
    printf("\n");
}

static void print_results(void)
{
    int i, k;

    if (compact) {
        /* Structured compact output matching BNAqna's format so the
         * GUI's Run Comparison awk consumer can extract the same
         * fields. Header + rho_i + Gamma_i (throughputs) + sojourn_i
         * + E[Q_i]. Per-class W_total/T_total/X are omitted because
         * RQNA Phase 3c doesn't yet propagate per-class IDCs. */
        printf("RQNA (BNArqna)\n");
        printf("==============\n");
        for (i = 0; i < n; i++) printf("rho_%d = %f\n",     i + 1, rho[i]);
        printf("\n");
        for (i = 0; i < n; i++) printf("Gamma_%d = %f\n",   i + 1, lam[i]);
        printf("\n");
        for (i = 0; i < n; i++) printf("sojourn_%d = %f\n", i + 1, ET[i]);
        printf("\n");
        for (i = 0; i < n; i++) printf("E[Q_%d] = %f\n",    i + 1, EN[i]);
        return;
    }

    printf("\nRQNA (Robust Queueing Network Analyzer)\n");
    printf("======================================\n\n");
    printf("Node  Servers  Util(rho)  ca²       Ia(t*)    Is(t*)    "
           "t*/E[S]   E[W]        E[N]        E[T]        P(W>0)\n");
    for (i = 0; i < n; i++) {
        double ca2 = Ia[i].v[NUM_SCALES - 1];   /* renewal asymptote */
        double ts_norm = (tau[i] > 0.0) ? t_star[i] / tau[i] : 0.0;
        printf("%-5d %-8d %-10.4f %-9.4f %-9.4f %-9.4f %-9.4f "
               "%-11.6f %-11.6f %-11.6f %-9.4f\n",
               i + 1, m_serv[i], rho[i], ca2,
               Ia_at_tstar[i], Is_at_tstar[i], ts_norm,
               EW[i], EN[i], ET[i], Pw0[i]);
    }

    double total_lambda0 = 0.0, total_EN = 0.0;
    for (i = 0; i < n; i++) total_lambda0 += lambda0[i];
    for (i = 0; i < n; i++) total_EN += EN[i];
    printf("\nNetwork Totals:\n");
    printf("  External arrival rate: %.6f\n", total_lambda0);
    printf("  Total E[N]: %.6f\n", total_EN);
    if (total_lambda0 > 0.0)
        printf("  Mean sojourn time E[T]: %.6f\n", total_EN / total_lambda0);

    printf("\n=== Per-station IDCs (Phase 2 details) ===\n");
    printf("Timescale grid (t_k / t_ref):\n    ");
    for (k = 0; k < NUM_SCALES; k++)
        printf("%10.3g ", Ia[0].t[k] / Ia[0].t[5]);
    printf("\n");
    for (i = 0; i < n; i++) {
        printf("  station %d:\n", i + 1);
        print_idc_row("Ia0",  &Ia0[i]);
        print_idc_row("Is",   &Is[i]);
        print_idc_row("Ia",   &Ia[i]);
        print_idc_row("Id",   &Id[i]);
    }

    /* Mirror BNAqna's E[Q_i] line for Run Comparison parity. */
    printf("\n");
    for (i = 0; i < n; i++) printf("E[Q_%d] = %.6f\n", i + 1, EN[i]);
}

/* ================================================================
 *  CLI
 * ================================================================ */

static void usage(const char *argv0)
{
    fprintf(stderr,
        "Usage: %s <input_file> [-c]\n"
        "       %s --selftest\n"
        "\n"
        "  <input_file>   .qna network file (same format as bna_qna)\n"
        "  -c             compact output (IDC values only)\n"
        "  --selftest     run IDC primitive self-tests, exit\n",
        argv0, argv0);
}

int main(int argc, char *argv[])
{
    if (argc < 2) {
        usage(argv[0]);
        return EXIT_FAILURE;
    }

    if (strcmp(argv[1], "--selftest") == 0) {
        return run_selftest();
    }

    int i;
    for (i = 2; i < argc; i++) {
        if (strcmp(argv[i], "-c") == 0) compact = 1;
        else {
            usage(argv[0]);
            return EXIT_FAILURE;
        }
    }

    parse_input(argv[1]);

    eliminate_feedback();
    solve_traffic_rates();
    solve_network_idcs();
    compute_congestion();
    print_results();

    return EXIT_SUCCESS;
}
