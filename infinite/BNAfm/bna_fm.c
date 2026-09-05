/*
 * bna_fm.c — Brownian Network Analyzer (Finite-Element Method) for SRBM
 * in the K-dimensional ORTHANT.
 *
 * Algorithm: Chen & Shen, "Computing the Stationary Distribution of an
 * SRBM in an Orthant with Applications to Queueing Networks," Queueing
 * Systems 45:27-45, 2003. Approximates the orthant SRBM by a sequence
 * of hypercube SRBMs with growing boundary b^n = b^1 + (n-1)c. Each
 * hypercube SRBM is solved by the existing finite/fBNAfm BNAfm
 * algorithm (Shen, Chen, Dai, Dai 2002, eq. 13 of this paper applies
 * Lemma 2.2 to build the hypercube data from orthant data via R̄ = (R, -I)).
 *
 * Termination (eq. 7-8 of the paper):
 *   |δ^n_{K+i}| ≤ ε_1   (boundary mass at upper face is small)
 *   |q^n_i − q^{n-1}_i| / q^{n-1}_i ≤ ε_2   (means converged)
 *
 * This sits next to BNAsm (the global-polynomial spectral solver) and
 * fixes the documented Cholesky-breakdown failure on Lu-Kumar at order
 * ≥ 12 — FEM is numerically more stable than global polynomials.
 *
 * Input file format (.in):
 *   K
 *   theta[1..K]                         (drift)
 *   Gamma[i][j]                         (K×K covariance, K rows)
 *   R[i][j]                             (K×K reflection — orthant only)
 *   service_rates[1..K]                 (optional; for traffic intensity)
 *   mesh_n[1..K]                        (FEM mesh size per dim)
 *
 * Wrapper invokes ../../finite/fBNAfm/bna_fm_gauss for each iteration.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <unistd.h>
#include <sys/wait.h>
#include <libgen.h>

#define MAX_DIM 8
#define MAX_ITER 12

/* Tolerances per Chen-Shen 2003 §3 (recommended defaults). */
static double EPS_DELTA  = 1e-3;   /* upper-boundary mass */
static double EPS_Q_REL  = 1e-2;   /* relative change in stationary mean */
static double EPS_TAIL   = 1e-4;   /* product-form tail probability for b^1 */

static char fbnafm_bin[1024] = "../../finite/fBNAfm/bna_fm_gauss";

typedef struct {
    int    K;
    double theta[MAX_DIM];
    double Gamma[MAX_DIM][MAX_DIM];
    double R[MAX_DIM][MAX_DIM];        /* orthant reflection (K×K) */
    double svc[MAX_DIM];               /* optional service rates */
    int    has_svc;
    int    mesh_n[MAX_DIM];
} OrthantData;

/* ------------------------------------------------------------------ */
/* Parser                                                              */
/* ------------------------------------------------------------------ */

static int next_data_line(FILE *fp, char *buf, int sz)
{
    while (fgets(buf, sz, fp)) {
        char *p = buf;
        while (*p == ' ' || *p == '\t') p++;
        if (*p && *p != '#' && *p != '\n' && *p != '\r') return 1;
    }
    return 0;
}

static int parse_input(const char *path, OrthantData *d)
{
    FILE *fp = fopen(path, "r");
    if (!fp) { fprintf(stderr, "bna_fm: cannot open '%s'\n", path); return -1; }
    char buf[2048];
    int K, i, j;

    if (!next_data_line(fp, buf, sizeof(buf)) || sscanf(buf, "%d", &K) != 1) goto bad;
    if (K < 1 || K > MAX_DIM) {
        fprintf(stderr, "bna_fm: invalid K=%d (max %d)\n", K, MAX_DIM);
        fclose(fp); return -1;
    }
    d->K = K;

    /* theta */
    if (!next_data_line(fp, buf, sizeof(buf))) goto bad;
    {
        char *tok = strtok(buf, " \t\n\r");
        for (i = 0; i < K; i++) {
            if (!tok) goto bad;
            d->theta[i] = atof(tok);
            tok = strtok(NULL, " \t\n\r");
        }
    }

    /* Gamma rows */
    for (i = 0; i < K; i++) {
        if (!next_data_line(fp, buf, sizeof(buf))) goto bad;
        char *tok = strtok(buf, " \t\n\r");
        for (j = 0; j < K; j++) {
            if (!tok) goto bad;
            d->Gamma[i][j] = atof(tok);
            tok = strtok(NULL, " \t\n\r");
        }
    }

    /* R rows (K columns — orthant only) */
    for (i = 0; i < K; i++) {
        if (!next_data_line(fp, buf, sizeof(buf))) goto bad;
        char *tok = strtok(buf, " \t\n\r");
        for (j = 0; j < K; j++) {
            if (!tok) goto bad;
            d->R[i][j] = atof(tok);
            tok = strtok(NULL, " \t\n\r");
        }
    }

    /* Optional service rates row, then mesh_n. We try to read service
     * rates; if the first parse fails we treat that line as mesh_n. */
    d->has_svc = 0;
    if (!next_data_line(fp, buf, sizeof(buf))) goto mesh_only;

    {
        /* Sniff: if all tokens are integers, treat as mesh_n; else svc. */
        char tmp[2048];
        strncpy(tmp, buf, sizeof(tmp));
        tmp[sizeof(tmp)-1] = 0;
        char *tok = strtok(tmp, " \t\n\r");
        int all_int = 1, count = 0;
        while (tok) {
            for (char *p = tok; *p; p++) {
                if (*p == '.' || *p == 'e' || *p == 'E') { all_int = 0; break; }
            }
            count++;
            tok = strtok(NULL, " \t\n\r");
        }
        if (count == K && all_int) {
            /* mesh_n only */
            tok = strtok(buf, " \t\n\r");
            for (i = 0; i < K; i++) {
                d->mesh_n[i] = atoi(tok);
                tok = strtok(NULL, " \t\n\r");
            }
        } else {
            /* service rates */
            tok = strtok(buf, " \t\n\r");
            for (i = 0; i < K; i++) {
                if (!tok) goto bad;
                d->svc[i] = atof(tok);
                tok = strtok(NULL, " \t\n\r");
            }
            d->has_svc = 1;
            /* mesh_n on next line */
            if (!next_data_line(fp, buf, sizeof(buf))) goto mesh_default;
            tok = strtok(buf, " \t\n\r");
            for (i = 0; i < K; i++) {
                if (!tok) goto mesh_default;
                d->mesh_n[i] = atoi(tok);
                tok = strtok(NULL, " \t\n\r");
            }
        }
    }
    fclose(fp);
    return 0;

mesh_only:
    /* No mesh_n provided — defaults */
mesh_default:
    /* Default mesh: 20 elements per dimension. fBNAfm with K=1 has a FEM
     * degeneracy and produces spurious flat solutions; for K≥2 a 20-elem
     * mesh on a hypercube of side ~5 yields ~1% accuracy. Larger b needs
     * proportionally finer mesh — we leave that to the user via input. */
    for (i = 0; i < K; i++) d->mesh_n[i] = 20;
    fclose(fp);
    return 0;

bad:
    fprintf(stderr, "bna_fm: parse error in '%s'\n", path);
    fclose(fp);
    return -1;
}

/* ------------------------------------------------------------------ */
/* Hypercube file emission and child invocation                       */
/* ------------------------------------------------------------------ */

static int write_hypercube_input(const char *path, const OrthantData *d, const double *ub)
{
    FILE *fp = fopen(path, "w");
    if (!fp) return -1;
    int K = d->K;
    fprintf(fp, "%d\n\n", K);
    for (int i = 0; i < K; i++) fprintf(fp, "%.10g ", d->theta[i]);
    fprintf(fp, "\n\n");
    for (int i = 0; i < K; i++) {
        for (int j = 0; j < K; j++) fprintf(fp, "%.10g ", d->Gamma[i][j]);
        fprintf(fp, "\n");
    }
    fprintf(fp, "\n");
    /* R̄ = (R, -I) per Chen-Shen Lemma 2.2 (α = 1) — first K columns
     * are the orthant lower-bound faces, next K columns the upper. */
    for (int i = 0; i < K; i++) {
        for (int j = 0; j < K; j++) fprintf(fp, "%.10g ", d->R[i][j]);
        for (int j = 0; j < K; j++) fprintf(fp, "%.10g ", (i == j) ? -1.0 : 0.0);
        fprintf(fp, "\n");
    }
    fprintf(fp, "\n");
    for (int i = 0; i < K; i++) fprintf(fp, "%.10g ", ub[i]);
    fprintf(fp, "\n");
    for (int i = 0; i < K; i++) fprintf(fp, "%d ", d->mesh_n[i]);
    fprintf(fp, "\n");
    fclose(fp);
    return 0;
}

/* Run fBNAfm and parse E[X_i] (mean) and δ(x_i=upper) from stdout. */
static int run_fbnafm(const char *input_path, int K, double *q_out, double *delta_upper_out)
{
    char cmd[2048];
    snprintf(cmd, sizeof(cmd), "%s %s 2>&1", fbnafm_bin, input_path);
    FILE *pp = popen(cmd, "r");
    if (!pp) return -1;
    char buf[1024];
    for (int i = 0; i < K; i++) { q_out[i] = 0.0; delta_upper_out[i] = 0.0; }
    while (fgets(buf, sizeof(buf), pp)) {
        int idx; double val;
        if (sscanf(buf, " E[X_%d] = %lf", &idx, &val) == 2) {
            if (idx >= 1 && idx <= K) q_out[idx-1] = val;
        } else if (sscanf(buf, " delta(x_%d=upper) = %lf", &idx, &val) == 2) {
            if (idx >= 1 && idx <= K) delta_upper_out[idx-1] = val;
        }
    }
    int rc = pclose(pp);
    if (rc != 0) {
        fprintf(stderr, "bna_fm: fBNAfm exited with status %d\n", rc);
        return -1;
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* Initial boundary b^1 from product-form tail (eq. 12-13)             */
/* ------------------------------------------------------------------ */

static void compute_initial_boundary(const OrthantData *d, double *b1)
{
    int K = d->K;
    for (int k = 0; k < K; k++) {
        double Rkk = d->R[k][k];
        double Gkk = d->Gamma[k][k];
        double thk = d->theta[k];
        if (fabs(Gkk) < 1e-15 || fabs(Rkk) < 1e-15 || thk >= 0) {
            /* degenerate or non-stable — fall back to a generous default */
            b1[k] = 25.0;
            continue;
        }
        double gamma_k = 2.0 * fabs(thk) * Rkk / Gkk;
        b1[k] = -log(1.0 - EPS_TAIL) / gamma_k;
        if (b1[k] < 1.0) b1[k] = 1.0;        /* don't start tiny */
        if (b1[k] > 200.0) b1[k] = 200.0;    /* don't start huge */
    }
}

/* ------------------------------------------------------------------ */
/* Resolve fBNAfm binary location relative to argv[0] when possible    */
/* ------------------------------------------------------------------ */

static void resolve_fbnafm_bin(const char *argv0)
{
    const char *env = getenv("FBNAFM_BIN");
    if (env && env[0]) {
        snprintf(fbnafm_bin, sizeof(fbnafm_bin), "%s", env);
        return;
    }
    /* If argv[0] contains a path, try sibling ../../finite/fBNAfm/bna_fm_gauss */
    if (strchr(argv0, '/')) {
        char buf[1024];
        snprintf(buf, sizeof(buf), "%s", argv0);
        char *dir = dirname(buf);
        snprintf(fbnafm_bin, sizeof(fbnafm_bin),
                 "%s/../../finite/fBNAfm/bna_fm_gauss", dir);
        if (access(fbnafm_bin, X_OK) == 0) return;
    }
    /* Default: relative path from the BNAfm directory */
    snprintf(fbnafm_bin, sizeof(fbnafm_bin), "../../finite/fBNAfm/bna_fm_gauss");
}

/* ------------------------------------------------------------------ */
/* Main                                                                */
/* ------------------------------------------------------------------ */

int main(int argc, char *argv[])
{
    int compact = 0;
    const char *input_path = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-c")) compact = 1;
        else if (argv[i][0] != '-') input_path = argv[i];
    }
    if (!input_path) {
        fprintf(stderr, "Usage: bna_fm <input.in> [-c]\n"
                "  Chen-Shen 2003 orthant SRBM solver (wraps fBNAfm).\n"
                "  FBNAFM_BIN env overrides the fBNAfm binary path.\n");
        return 2;
    }
    resolve_fbnafm_bin(argv[0]);
    if (access(fbnafm_bin, X_OK) != 0) {
        fprintf(stderr, "bna_fm: fBNAfm binary not executable at '%s'\n", fbnafm_bin);
        fprintf(stderr, "  Set FBNAFM_BIN env var or build finite/fBNAfm first.\n");
        return 2;
    }

    OrthantData d;
    if (parse_input(input_path, &d) != 0) return 2;

    double b[MAX_DIM], q_prev[MAX_DIM], q[MAX_DIM], du[MAX_DIM];
    compute_initial_boundary(&d, b);

    if (!compact) {
        fprintf(stderr, "bna_fm (Chen-Shen 2003 orthant SRBM, wraps fBNAfm)\n");
        fprintf(stderr, "  K = %d\n  initial boundary b^1 =", d.K);
        for (int i = 0; i < d.K; i++) fprintf(stderr, " %.3f", b[i]);
        fprintf(stderr, "\n");
    }

    /* Iterate over growing hypercubes. */
    char tmpfile[256];
    snprintf(tmpfile, sizeof(tmpfile), "/tmp/bna_fm_%d.in", (int)getpid());
    int converged = 0;

    for (int it = 1; it <= MAX_ITER; it++) {
        /* Scale mesh with b: maintain ≥4 elements per unit of b along
         * each dimension so the FEM can resolve the exponential decay
         * near the lower boundary as the hypercube grows. The user's
         * input mesh_n is the FLOOR. Cap at 60 per dim (60^K can blow up
         * memory for K≥3; user can override with smaller scaling). */
        int mesh_active[MAX_DIM];
        for (int i = 0; i < d.K; i++) {
            int needed = (int)ceil(b[i] * 4.0);
            mesh_active[i] = (d.mesh_n[i] > needed) ? d.mesh_n[i] : needed;
            if (mesh_active[i] > 60) mesh_active[i] = 60;
        }
        OrthantData scaled = d;
        for (int i = 0; i < d.K; i++) scaled.mesh_n[i] = mesh_active[i];

        if (write_hypercube_input(tmpfile, &scaled, b) != 0) {
            fprintf(stderr, "bna_fm: cannot write '%s'\n", tmpfile);
            return 2;
        }
        for (int i = 0; i < d.K; i++) q_prev[i] = q[i];
        if (run_fbnafm(tmpfile, d.K, q, du) != 0) {
            fprintf(stderr, "bna_fm: fBNAfm call failed at iteration %d\n", it);
            return 2;
        }

        if (!compact) {
            fprintf(stderr, "  iter %d  b =", it);
            for (int i = 0; i < d.K; i++) fprintf(stderr, " %.2f", b[i]);
            fprintf(stderr, "\n        q =");
            for (int i = 0; i < d.K; i++) fprintf(stderr, " %.4f", q[i]);
            fprintf(stderr, "\n        δ_upper =");
            for (int i = 0; i < d.K; i++) fprintf(stderr, " %.2e", du[i]);
            fprintf(stderr, "\n");
        }

        if (it > 1) {
            int ok = 1;
            for (int i = 0; i < d.K; i++) {
                if (fabs(du[i]) > EPS_DELTA) { ok = 0; break; }
                double denom = (q_prev[i] > 1e-12) ? q_prev[i] : 1.0;
                if (fabs(q[i] - q_prev[i]) / denom > EPS_Q_REL) { ok = 0; break; }
            }
            if (ok) { converged = 1; break; }
        }

        /* Grow boundary: b^{n+1} = b^n + c, c=5 if b^1 ≤ 25 else 10. */
        for (int i = 0; i < d.K; i++) {
            double c = (b[i] <= 25.0) ? 5.0 : 10.0;
            b[i] += c;
        }
    }

    remove(tmpfile);

    if (!converged) {
        fprintf(stderr, "bna_fm: WARNING — did not converge within %d iterations\n", MAX_ITER);
        fprintf(stderr, "  loosen --eps-delta or --eps-q-rel, or check stability.\n");
    }

    if (compact) {
        printf("BNAfm-orthant (Chen-Shen 2003)\n=================\n");
    }
    for (int i = 0; i < d.K; i++) {
        printf("E[X_%d] = %.6f\n", i + 1, q[i]);
    }
    return 0;
}
