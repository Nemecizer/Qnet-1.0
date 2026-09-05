/*
 * rbm_mlmc.c
 *
 * Two-Parameter Multilevel Monte Carlo estimator for steady-state
 * expectations of Reflected Brownian Motion (RBM) in the positive orthant.
 *
 * Implements Algorithm 1 from:
 *   Blanchet, Chen, Glynn, Si (2021)
 *   "Efficient Steady-State Simulation of High-Dimensional Stochastic Networks"
 *   Stochastic Systems 11(2):174-192
 *
 * Parallelization backends (selectable at runtime):
 *   --backend accelerate   Apple Accelerate/vDSP + GCD (default on macOS)
 *   --backend openmp       OpenMP threading
 *   --backend serial       Single-threaded
 *
 * Usage: rbm_mlmc <input_file> <gamma> <epsilon> [options]
 *   Options:
 *     --seed S         Random seed (default: time-based)
 *     --backend B      accelerate, openmp, or serial (default: accelerate)
 *     --threads N      Number of threads (default: auto-detect)
 *     --T val          Override mixing time T (default: (ln d)^2 / 2)
 *     --L val          Override number of MLMC levels L
 *     --N val          Override number of samples N
 *   Legacy: rbm_mlmc <input_file> <gamma> <epsilon> <seed>
 *
 * Input file format (text):
 *   Line 1: d (dimension)
 *   Next line: mu_1 mu_2 ... mu_d
 *   Next d lines: Sigma (covariance matrix, row by row)
 *   Next d lines: R (reflection matrix, row by row)
 *   Lines starting with # are comments. Blank lines are skipped.
 *
 * Output: estimated E[Y_i(infinity)] for each dimension i.
 *
 * Uses SuiteSparse/CXSparse for Cholesky factorization.
 * Uses Apple Accelerate (BLAS/vDSP/LAPACK) when backend=accelerate.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <errno.h>
#include <limits.h>
#include <ctype.h>
#include <time.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <cs.h>

/* Compact output mode (-c flag) */
static int compact_mode = 0;
static int saved_stdout_fd = -1;

static void compact_suppress_stdout(void) {
    fflush(stdout);
    saved_stdout_fd = dup(STDOUT_FILENO);
    int devnull = open("/dev/null", O_WRONLY);
    dup2(devnull, STDOUT_FILENO);
    close(devnull);
}

static void compact_restore_stdout(void) {
    fflush(stdout);
    dup2(saved_stdout_fd, STDOUT_FILENO);
    close(saved_stdout_fd);
    saved_stdout_fd = -1;
}

#ifdef __APPLE__
#define ACCELERATE_NEW_LAPACK
#include <Accelerate/Accelerate.h>
#include <dispatch/dispatch.h>
#endif

#ifdef _OPENMP
#include <omp.h>
#endif

typedef enum { BACKEND_ACCELERATE, BACKEND_OPENMP, BACKEND_SERIAL } backend_t;

/* Used by a handful of small on-stack scratch arrays (antithetic Z_plus,
 * per-dim summaries).  Queueing networks above this are exceedingly rare;
 * raise as needed. */
#define SRBM_MAX_DIM 1024

/* Strict numeric parsing is important here: atoi/atof silently turn malformed
 * values into zero and overflowing floating-to-int conversions are undefined
 * behaviour in C.  These helpers require a complete, finite value and check
 * the destination range before any cast. */
static int only_trailing_space(const char *p)
{
    while (*p != '\0' && isspace((unsigned char)*p)) p++;
    return *p == '\0';
}

static int parse_finite_double(const char *name, const char *text, double *out)
{
    char *end = NULL;
    errno = 0;
    double value = strtod(text, &end);
    if (end == text || errno == ERANGE || !isfinite(value) ||
        !only_trailing_space(end)) {
        fprintf(stderr, "Invalid %s value: '%s'\n", name, text);
        return 0;
    }
    *out = value;
    return 1;
}

static int parse_int_in_range(const char *name, const char *text,
                              int minimum, int maximum, int *out)
{
    char *end = NULL;
    errno = 0;
    long long value = strtoll(text, &end, 10);
    if (end == text || errno == ERANGE || !only_trailing_space(end) ||
        value < minimum || value > maximum) {
        fprintf(stderr, "Invalid %s value '%s' (expected %d..%d)\n",
                name, text, minimum, maximum);
        return 0;
    }
    *out = (int)value;
    return 1;
}

static int parse_long_value(const char *name, const char *text, long *out)
{
    char *end = NULL;
    errno = 0;
    long value = strtol(text, &end, 10);
    if (end == text || errno == ERANGE || !only_trailing_space(end)) {
        fprintf(stderr, "Invalid %s value: '%s'\n", name, text);
        return 0;
    }
    *out = value;
    return 1;
}

static int checked_integral_double(const char *name, double value,
                                   int minimum, int maximum, int *out)
{
    if (!isfinite(value) || value < (double)minimum || value > (double)maximum) {
        fprintf(stderr,
                "%s is outside the supported integer range %d..%d (got %.17g)\n",
                name, minimum, maximum, value);
        return 0;
    }
    *out = (int)value;
    return 1;
}

/* ========================================================================== */
/* Thread-safe RNG: xoshiro256** with per-thread state                        */
/* ========================================================================== */

typedef struct {
    uint64_t s[4];
    int      has_spare;
    double   spare;
} rng_state_t;

static inline uint64_t rotl64(const uint64_t x, int k)
{
    return (x << k) | (x >> (64 - k));
}

static inline uint64_t xoshiro256ss(rng_state_t *rng)
{
    const uint64_t result = rotl64(rng->s[1] * 5, 7) * 9;
    const uint64_t t = rng->s[1] << 17;
    rng->s[2] ^= rng->s[0];
    rng->s[3] ^= rng->s[1];
    rng->s[1] ^= rng->s[2];
    rng->s[0] ^= rng->s[3];
    rng->s[2] ^= t;
    rng->s[3] = rotl64(rng->s[3], 45);
    return result;
}

static inline double rng_uniform(rng_state_t *rng)
{
    return (double)(xoshiro256ss(rng) >> 11) * 0x1.0p-53;
}

static double rng_randn(rng_state_t *rng)
{
    if (rng->has_spare) {
        rng->has_spare = 0;
        return rng->spare;
    }
    rng->has_spare = 1;
    double u, v, s;
    do {
        u = 2.0 * rng_uniform(rng) - 1.0;
        v = 2.0 * rng_uniform(rng) - 1.0;
        s = u * u + v * v;
    } while (s >= 1.0 || s == 0.0);
    s = sqrt(-2.0 * log(s) / s);
    rng->spare = v * s;
    return u * s;
}

/* Seed RNG using SplitMix64 to expand a single 64-bit seed */
static void rng_seed(rng_state_t *rng, uint64_t seed)
{
    rng->has_spare = 0;
    rng->spare = 0.0;
    for (int i = 0; i < 4; i++) {
        seed += 0x9e3779b97f4a7c15ULL;
        uint64_t z = seed;
        z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
        z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
        rng->s[i] = z ^ (z >> 31);
    }
}

/* ========================================================================== */
/* Per-thread workspace                                                       */
/* ========================================================================== */

typedef struct {
    double *Y_fine, *Y_coarse;
    double *z_vec, *Cz;
    double *dx_fine, *dx_acc;
    double *x_uncon, *y_lcp;
    int    *B_idx;
    double *R_BB, *lcp_rhs, *L_B;
    double *Z_sum_local;
    double *Z_sq_sum_local;  /* sum of Z_i^2 per thread for sample variance   */
    long long n_local;       /* # samples processed by this thread            */
    long long gaussians_local;
    int    *ipiv;
    rng_state_t rng;
    /* Antithetic scratch (allocated iff antithetic sampling is used) */
    double *Y_fine_a, *Y_coarse_a, *dx_fine_a, *x_uncon_a, *y_lcp_a;
} workspace_t;

static workspace_t *alloc_workspace(int d, int antithetic)
{
    workspace_t *w = calloc(1, sizeof(workspace_t));
    w->Y_fine      = malloc(d * sizeof(double));
    w->Y_coarse    = malloc(d * sizeof(double));
    w->z_vec       = malloc(d * sizeof(double));
    w->Cz          = malloc(d * sizeof(double));
    w->dx_fine     = malloc(d * sizeof(double));
    w->dx_acc      = malloc(d * sizeof(double));
    w->x_uncon     = malloc(d * sizeof(double));
    w->y_lcp       = malloc(d * sizeof(double));
    w->B_idx       = malloc(d * sizeof(int));
    w->R_BB        = malloc(d * d * sizeof(double));
    w->lcp_rhs     = malloc(d * sizeof(double));
    w->L_B         = malloc(d * sizeof(double));
    w->Z_sum_local    = calloc(d, sizeof(double));
    w->Z_sq_sum_local = calloc(d, sizeof(double));
    w->n_local        = 0;
    w->gaussians_local = 0;
    w->ipiv        = malloc(d * sizeof(int));
    if (antithetic) {
        w->Y_fine_a   = malloc(d * sizeof(double));
        w->Y_coarse_a = malloc(d * sizeof(double));
        w->dx_fine_a  = malloc(d * sizeof(double));
        w->x_uncon_a  = malloc(d * sizeof(double));
        w->y_lcp_a    = malloc(d * sizeof(double));
    }
    return w;
}

static void free_workspace(workspace_t *w)
{
    free(w->Y_fine);   free(w->Y_coarse);
    free(w->z_vec);    free(w->Cz);
    free(w->dx_fine);  free(w->dx_acc);
    free(w->x_uncon);  free(w->y_lcp);
    free(w->B_idx);    free(w->R_BB);
    free(w->lcp_rhs);  free(w->L_B);
    free(w->Z_sum_local);
    free(w->Z_sq_sum_local);
    free(w->ipiv);
    if (w->Y_fine_a) {
        free(w->Y_fine_a);   free(w->Y_coarse_a);
        free(w->dx_fine_a);  free(w->x_uncon_a);
        free(w->y_lcp_a);
    }
    free(w);
}

/* ========================================================================== */
/* Simulation context (shared read-only data for all threads)                 */
/* ========================================================================== */

typedef struct {
    int d, Lev, ratio, N;
    double gamma, T, Kgamma;
    const double *mu;
    const double *R_dense;
    /* Cholesky factor L of Sigma.  Always available in sparse CSC form;
     * only built in dense form when use_sparse_L == 0. */
    const double *L_dense;      /* dense column-major lower triangular (or NULL) */
    const int    *Lp;           /* CSC column pointers [d+1] */
    const int    *Li;           /* CSC row indices [nnz] */
    const double *Lx;           /* CSC values [nnz] */
    int    L_nnz;
    int    use_sparse_L;        /* 1 => sparse trmv; 0 => dense trmv */
    /* Reflection matrix R in row-major dense AND in CSC form so the LCP
     * column-update step can do sparse daxpy when R has few non-zeros. */
    const int    *Rp;           /* CSC column pointers [d+1] */
    const int    *Ri;           /* CSC row indices [nnz] */
    const double *Rx;           /* CSC values [nnz] */
    int    R_nnz;
    int    use_sparse_R;        /* 1 => sparse LCP col-update */
    int    use_accelerate;
    int    antithetic;          /* 1 => each sample = ±noise pair averaged */
    atomic_int *progress;       /* shared progress counter */
} sim_ctx_t;

/* ========================================================================== */
/* Network metadata for per-class queueing output                             */
/* ========================================================================== */

typedef struct {
    int has_metadata;
    int num_classes;
    int num_stations;
    int *servers;            /* [num_stations] servers per station */
    double *alpha_total;     /* [num_stations] total throughput per station */
    double *alpha_class;     /* [num_classes * num_stations], row-major */
    double *mu_class;        /* [num_classes * num_stations], row-major */
    double *lambda_ext;      /* [num_classes * num_stations], row-major */
    double *capacities;      /* [num_stations] station capacities */
    char **class_names;      /* [num_classes] allocated strings */
    char **station_names;    /* [num_stations] allocated strings */
} network_meta_t;

static void init_network_meta(network_meta_t *m)
{
    memset(m, 0, sizeof(network_meta_t));
}

static void free_network_meta(network_meta_t *m)
{
    if (!m->has_metadata) return;
    free(m->servers);
    free(m->alpha_total);
    free(m->alpha_class);
    free(m->mu_class);
    free(m->lambda_ext);
    free(m->capacities);
    if (m->class_names) {
        for (int i = 0; i < m->num_classes; i++) free(m->class_names[i]);
        free(m->class_names);
    }
    if (m->station_names) {
        for (int i = 0; i < m->num_stations; i++) free(m->station_names[i]);
        free(m->station_names);
    }
}

/* ========================================================================== */
/* Input file parser                                                          */
/* ========================================================================== */

static int next_line(FILE *f, char *buf, int bufsize)
{
    while (fgets(buf, bufsize, f)) {
        char *p = buf;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '#' || *p == '\n' || *p == '\r' || *p == '\0') continue;
        return 1;
    }
    return 0;
}

static void parse_metadata_body(FILE *f, char *buf, int bufsize,
                                 network_meta_t *meta)
{
    int K = meta->num_stations;
    int alpha_row = 0, mu_row = 0, lambda_row = 0;
    int class_name_idx = 0, station_name_idx = 0;

    while (next_line(f, buf, bufsize)) {
        /* Skip to first non-whitespace */
        char *p = buf;
        while (*p == ' ' || *p == '\t') p++;

        if (strncmp(p, "END_METADATA", 12) == 0) break;

        /* Extract keyword */
        char keyword[64] = {0};
        sscanf(p, "%63s", keyword);
        char *vals = p + strlen(keyword);
        while (*vals == ' ' || *vals == '\t') vals++;

        if (strcmp(keyword, "num_classes") == 0) {
            meta->num_classes = atoi(vals);
            int C = meta->num_classes;
            meta->servers      = calloc(K, sizeof(int));
            meta->alpha_total  = calloc(K, sizeof(double));
            meta->alpha_class  = calloc(C * K, sizeof(double));
            meta->mu_class     = calloc(C * K, sizeof(double));
            meta->lambda_ext   = calloc(C * K, sizeof(double));
            meta->capacities   = calloc(K, sizeof(double));
            meta->class_names  = calloc(C, sizeof(char *));
            meta->station_names = calloc(K, sizeof(char *));
            for (int i = 0; i < C; i++) {
                char dflt[32];
                snprintf(dflt, sizeof(dflt), "Class%d", i + 1);
                meta->class_names[i] = strdup(dflt);
            }
            for (int i = 0; i < K; i++) {
                char dflt[32];
                snprintf(dflt, sizeof(dflt), "Q%d", i + 1);
                meta->station_names[i] = strdup(dflt);
            }
            for (int i = 0; i < K; i++) meta->servers[i] = 1;
        }
        else if (strcmp(keyword, "servers") == 0 && meta->servers) {
            char *vp = vals;
            for (int i = 0; i < K; i++)
                meta->servers[i] = (int)strtol(vp, &vp, 10);
        }
        else if (strcmp(keyword, "capacities") == 0 && meta->capacities) {
            char *vp = vals;
            for (int i = 0; i < K; i++)
                meta->capacities[i] = strtod(vp, &vp);
        }
        else if (strcmp(keyword, "alpha_total") == 0 && meta->alpha_total) {
            char *vp = vals;
            for (int i = 0; i < K; i++)
                meta->alpha_total[i] = strtod(vp, &vp);
        }
        else if (strcmp(keyword, "alpha_class") == 0 && meta->alpha_class) {
            if (alpha_row < meta->num_classes) {
                char *vp = vals;
                for (int j = 0; j < K; j++)
                    meta->alpha_class[alpha_row * K + j] = strtod(vp, &vp);
                alpha_row++;
            }
        }
        else if (strcmp(keyword, "mu_class") == 0 && meta->mu_class) {
            if (mu_row < meta->num_classes) {
                char *vp = vals;
                for (int j = 0; j < K; j++)
                    meta->mu_class[mu_row * K + j] = strtod(vp, &vp);
                mu_row++;
            }
        }
        else if (strcmp(keyword, "lambda_ext") == 0 && meta->lambda_ext) {
            if (lambda_row < meta->num_classes) {
                char *vp = vals;
                for (int j = 0; j < K; j++)
                    meta->lambda_ext[lambda_row * K + j] = strtod(vp, &vp);
                lambda_row++;
            }
        }
        else if (strcmp(keyword, "class_name") == 0 && meta->class_names) {
            if (class_name_idx < meta->num_classes) {
                char name[64] = {0};
                sscanf(vals, "%63s", name);
                free(meta->class_names[class_name_idx]);
                meta->class_names[class_name_idx] = strdup(name);
                class_name_idx++;
            }
        }
        else if (strcmp(keyword, "station_name") == 0 && meta->station_names) {
            if (station_name_idx < meta->num_stations) {
                char name[64] = {0};
                sscanf(vals, "%63s", name);
                free(meta->station_names[station_name_idx]);
                meta->station_names[station_name_idx] = strdup(name);
                station_name_idx++;
            }
        }
    }
}

static void parse_input(const char *filename, int *d_out, double **mu_out,
                         double **Sigma_out, double **R_out,
                         network_meta_t *meta)
{
    FILE *f = fopen(filename, "r");
    if (!f) { fprintf(stderr, "Cannot open %s\n", filename); exit(1); }

    char buf[65536];
    int d;

    if (!next_line(f, buf, sizeof(buf))) { fprintf(stderr, "Missing dimension\n"); exit(1); }
    if (!parse_int_in_range("dimension", buf, 1, SRBM_MAX_DIM, &d)) {
        fclose(f);
        exit(1);
    }

    double *mu    = calloc(d, sizeof(double));
    double *Sigma = calloc(d * d, sizeof(double));
    double *R     = calloc(d * d, sizeof(double));

    if (!next_line(f, buf, sizeof(buf))) { fprintf(stderr, "Missing mu\n"); exit(1); }
    {
        char *p = buf;
        for (int i = 0; i < d; i++) mu[i] = strtod(p, &p);
    }

    for (int i = 0; i < d; i++) {
        if (!next_line(f, buf, sizeof(buf))) {
            fprintf(stderr, "Missing Sigma row %d\n", i); exit(1);
        }
        char *p = buf;
        for (int j = 0; j < d; j++) Sigma[i * d + j] = strtod(p, &p);
    }

    for (int i = 0; i < d; i++) {
        if (!next_line(f, buf, sizeof(buf))) {
            fprintf(stderr, "Missing R row %d\n", i); exit(1);
        }
        char *p = buf;
        for (int j = 0; j < d; j++) R[i * d + j] = strtod(p, &p);
    }

    /* Parse optional network metadata section */
    init_network_meta(meta);
    if (next_line(f, buf, sizeof(buf))) {
        char *p = buf;
        while (*p == ' ' || *p == '\t') p++;
        if (strncmp(p, "NETWORK_METADATA", 16) == 0) {
            meta->has_metadata = 1;
            meta->num_stations = d;
            parse_metadata_body(f, buf, sizeof(buf), meta);
            fprintf(stderr, "Loaded network metadata: %d classes, %d stations\n",
                    meta->num_classes, meta->num_stations);
        }
    }

    fclose(f);
    *d_out = d; *mu_out = mu; *Sigma_out = Sigma; *R_out = R;
}

/* ========================================================================== */
/* Cholesky factorization via CXSparse, then extract to dense column-major    */
/* ========================================================================== */

static cs_di *compute_cholesky_factor(int d, const double *Sigma)
{
    cs_di *T = cs_di_spalloc(d, d, d * (d + 1) / 2, 1, 1);
    if (!T) { fprintf(stderr, "cs_di_spalloc failed\n"); exit(1); }

    /* Only store non-zero entries so CXSparse can exploit sparsity.
     * Diagonal elements are always kept (even if numerically zero they must
     * appear in the structure; a true zero would mean Sigma isn't PD). */
    for (int j = 0; j < d; j++)
        for (int i = 0; i <= j; i++) {
            double v = Sigma[i * d + j];
            if (i == j || v != 0.0)
                cs_di_entry(T, i, j, v);
        }

    cs_di *A = cs_di_compress(T);
    cs_di_spfree(T);
    if (!A) { fprintf(stderr, "cs_di_compress failed\n"); exit(1); }

    cs_dis *S = cs_di_schol(0, A);
    if (!S) { fprintf(stderr, "cs_di_schol failed\n"); exit(1); }

    cs_din *N = cs_di_chol(A, S);
    if (!N) { fprintf(stderr, "cs_di_chol failed (Sigma not positive definite?)\n"); exit(1); }

    cs_di *L = N->L;
    N->L = NULL;
    cs_di_nfree(N);
    cs_di_sfree(S);
    cs_di_spfree(A);
    return L;
}

/* Convert CXSparse compressed-column L to dense column-major matrix */
static double *sparse_to_dense_lower(const cs_di *L, int d)
{
    double *Ld = calloc(d * d, sizeof(double));
    for (int j = 0; j < d; j++)
        for (int p = L->p[j]; p < L->p[j + 1]; p++)
            Ld[j * d + L->i[p]] = L->x[p];   /* col-major: (i,j) at j*d+i */
    return Ld;
}

/* ========================================================================== */
/* Dense lower-triangular matrix-vector: y = L * x                            */
/* L is d x d column-major lower triangular.                                  */
/* ========================================================================== */

static void dense_trmv_lower(int d, const double *L, const double *x, double *y)
{
    memset(y, 0, d * sizeof(double));
    for (int j = 0; j < d; j++) {
        double xj = x[j];
        for (int i = j; i < d; i++)
            y[i] += L[j * d + i] * xj;
    }
}

/* ========================================================================== */
/* Sparse CSC lower-triangular matrix-vector: y = L * x                       */
/*                                                                            */
/* L stored in compressed sparse column (CSC) form as produced by CXSparse.   */
/* Work is O(nnz(L)) rather than O(d^2); for tridiagonal/banded Sigma the     */
/* Cholesky factor L is bidiagonal/banded, so this reduces to O(d).           */
/* ========================================================================== */

static inline void sparse_trmv_lower_csc(int d, const int *Lp, const int *Li,
                                          const double *Lx,
                                          const double *x, double *y)
{
    memset(y, 0, d * sizeof(double));
    for (int j = 0; j < d; j++) {
        double xj = x[j];
        int p_end = Lp[j + 1];
        for (int p = Lp[j]; p < p_end; p++)
            y[Li[p]] += Lx[p] * xj;
    }
}

/* ========================================================================== */
/* Dense Gaussian elimination with partial pivoting: solve A*x = b            */
/* A is n x n row-major, b is n-vector. Solution overwrites b.                */
/* A is MODIFIED in place.                                                    */
/* ========================================================================== */

static void dense_solve(int n, double *A, double *b)
{
    for (int k = 0; k < n; k++) {
        int pivot = k;
        double maxval = fabs(A[k * n + k]);
        for (int i = k + 1; i < n; i++) {
            double v = fabs(A[i * n + k]);
            if (v > maxval) { maxval = v; pivot = i; }
        }
        if (pivot != k) {
            for (int j = k; j < n; j++) {
                double tmp = A[k * n + j]; A[k * n + j] = A[pivot * n + j]; A[pivot * n + j] = tmp;
            }
            double tmp = b[k]; b[k] = b[pivot]; b[pivot] = tmp;
        }
        double diag = A[k * n + k];
        if (fabs(diag) < 1e-30) {
            fprintf(stderr, "Warning: near-singular matrix in LCP solve\n");
            continue;
        }
        for (int i = k + 1; i < n; i++) {
            double factor = A[i * n + k] / diag;
            for (int j = k + 1; j < n; j++)
                A[i * n + j] -= factor * A[k * n + j];
            b[i] -= factor * b[k];
        }
    }
    for (int k = n - 1; k >= 0; k--) {
        for (int j = k + 1; j < n; j++)
            b[k] -= A[k * n + j] * b[j];
        b[k] /= A[k * n + k];
    }
}

/* ========================================================================== */
/* Skorokhod problem solver: Algorithm A.1                                    */
/* Supports both hand-coded and Accelerate (LAPACK/BLAS) code paths.          */
/* ========================================================================== */

static void solve_lcp(int d, const double *R, const double *x, double *y,
                       int *B_idx, double *R_BB, double *rhs, double *L_B,
                       int *ipiv, int use_accelerate,
                       const int *Rp, const int *Ri, const double *Rx,
                       int use_sparse_R)
{
    static const double e = 1e-8;
    memcpy(y, x, d * sizeof(double));

#ifndef __APPLE__
    (void)ipiv; (void)use_accelerate;
#endif

    for (int iter = 0; iter < 100; iter++) {
        int neg_found = 0;
        for (int i = 0; i < d; i++) {
            if (y[i] < -e) { neg_found = 1; break; }
        }
        if (!neg_found) break;

        int nb = 0;
        for (int i = 0; i < d; i++) {
            if (y[i] < e) B_idx[nb++] = i;
        }
        if (nb == 0) break;

#ifdef __APPLE__
        if (use_accelerate) {
            /* Extract R_{B,B} in column-major for LAPACK, rhs = -x_B */
            for (int j = 0; j < nb; j++) {
                for (int i = 0; i < nb; i++)
                    R_BB[j * nb + i] = R[B_idx[i] * d + B_idx[j]];
                L_B[j] = -x[B_idx[j]];
            }

            /* Solve R_{B,B} * L_B = -x_B via LAPACK dgesv_ */
            int n_ = nb, nrhs_ = 1, lda_ = nb, ldb_ = nb, info_;
            dgesv_(&n_, &nrhs_, R_BB, &lda_, ipiv, L_B, &ldb_, &info_);
            if (info_ != 0)
                fprintf(stderr, "Warning: dgesv_ info=%d in LCP\n", (int)info_);

            /* y = x + R[:,B] * L_B  -- choose sparse or dense daxpy */
            memcpy(y, x, d * sizeof(double));
            if (use_sparse_R) {
                for (int j = 0; j < nb; j++) {
                    int col = B_idx[j];
                    double lval = L_B[j];
                    int p_end = Rp[col + 1];
                    for (int p = Rp[col]; p < p_end; p++)
                        y[Ri[p]] += Rx[p] * lval;
                }
            } else {
                /* dense: R is row-major, so col c lives at stride d */
                for (int j = 0; j < nb; j++)
                    cblas_daxpy(d, L_B[j], &R[B_idx[j]], d, y, 1);
            }
        } else
#endif
        {
            /* Extract R_{B,B} row-major, rhs = -x_B */
            for (int i = 0; i < nb; i++) {
                rhs[i] = -x[B_idx[i]];
                for (int j = 0; j < nb; j++)
                    R_BB[i * nb + j] = R[B_idx[i] * d + B_idx[j]];
            }
            memcpy(L_B, rhs, nb * sizeof(double));
            dense_solve(nb, R_BB, L_B);

            memcpy(y, x, d * sizeof(double));
            if (use_sparse_R) {
                for (int j = 0; j < nb; j++) {
                    int col = B_idx[j];
                    double lval = L_B[j];
                    int p_end = Rp[col + 1];
                    for (int p = Rp[col]; p < p_end; p++)
                        y[Ri[p]] += Rx[p] * lval;
                }
            } else {
                for (int j = 0; j < nb; j++) {
                    int col = B_idx[j];
                    double lval = L_B[j];
                    for (int i = 0; i < d; i++)
                        y[i] += R[i * d + col] * lval;
                }
            }
        }
    }

    for (int i = 0; i < d; i++)
        if (y[i] < 0.0) y[i] = 0.0;
}

/* ========================================================================== */
/* Draw level M from {0, 1, ..., L-1} with P(M=m) = K(gamma) * gamma^m       */
/* ========================================================================== */

static int draw_level(rng_state_t *rng, double gamma, int L)
{
    double U = rng_uniform(rng);
    double gammaL = pow(gamma, L);
    double val = 1.0 - U * (1.0 - gammaL);
    if (val <= 0.0) return L - 1;
    double raw = ceil(log(val) / log(gamma)) - 1.0;
    if (!isfinite(raw) || raw >= (double)(L - 1)) return L - 1;
    if (raw <= 0.0) return 0;
    /* raw is now explicitly bounded by [1, L-2] before the cast. */
    return (int)raw;
}

/* The path loops use int counters.  Check the largest possible level before
 * starting any workers so an extreme T/L/gamma combination fails
 * deterministically rather than overflowing only when that level is sampled. */
static int validate_path_step_counts(double T, double gamma, int L)
{
    int ignored;
    double finest_h = pow(gamma, (double)L);
    double max_fine_steps = round(T / finest_h);
    if (!checked_integral_double("maximum fine path step count", max_fine_steps,
                                 0, INT_MAX, &ignored)) {
        fprintf(stderr, "Reduce --T/--L or use a larger gamma.\n");
        return 0;
    }
    if (L > 1) {
        double coarsest_h_at_max_level = pow(gamma, (double)(L - 1));
        double max_coarse_steps = round((double)(L - 1) * T /
                                        coarsest_h_at_max_level);
        if (!checked_integral_double("maximum coarse path step count",
                                     max_coarse_steps, 0, INT_MAX, &ignored)) {
            fprintf(stderr, "Reduce --T/--L or use a larger gamma.\n");
            return 0;
        }
    }
    return 1;
}

/* ========================================================================== */
/* Cz = L * z  dispatcher: sparse CSC when available, dense otherwise         */
/* ========================================================================== */

static inline void compute_Cz(int d,
                               int sparseL, const int *Lp, const int *Li,
                               const double *Lx, const double *L_dense,
                               int use_acc,
                               const double *z, double *Cz)
{
    if (sparseL) {
        sparse_trmv_lower_csc(d, Lp, Li, Lx, z, Cz);
        return;
    }

    /* Dense path */
#ifdef __APPLE__
    if (use_acc) {
        memcpy(Cz, z, d * sizeof(double));
        cblas_dtrmv(CblasColMajor, CblasLower, CblasNoTrans, CblasNonUnit,
                    d, L_dense, d, Cz, 1);
        return;
    }
#else
    (void)use_acc;
#endif
    dense_trmv_lower(d, L_dense, z, Cz);
}

/* ========================================================================== */
/* simulate_path: simulate one MLMC path to the terminal times given M and    */
/* a noise_sign in {+1, -1}.  Puts Y_fine, Y_coarse into w on return.         */
/* Does NOT touch Z_sum_local / Z_sq_sum_local / n_local / progress.          */
/* ========================================================================== */

static void simulate_path(const sim_ctx_t *ctx, workspace_t *w,
                           int M, double noise_sign)
{
    const int    d       = ctx->d;
    const double gamma   = ctx->gamma;
    const int    ratio   = ctx->ratio;
    const double T       = ctx->T;
    const double *mu      = ctx->mu;
    const double *R_d     = ctx->R_dense;
    const double *L_d     = ctx->L_dense;
    const int    *Lp      = ctx->Lp;
    const int    *Li      = ctx->Li;
    const double *Lx      = ctx->Lx;
    const int    sparseL  = ctx->use_sparse_L;
    const int    *Rp      = ctx->Rp;
    const int    *Ri      = ctx->Ri;
    const double *Rx      = ctx->Rx;
    const int    sparseR  = ctx->use_sparse_R;
    const int    use_acc  = ctx->use_accelerate;

    double h_fine   = pow(gamma, M + 1);
    double h_coarse = pow(gamma, M);
    double sqrt_hf  = sqrt(h_fine);
    double eff_sqrt_hf = noise_sign * sqrt_hf;  /* flip noise for antithetic */

    double phase1_count = round(T / h_fine);
    double coarse_count = (M > 0) ? round((double)M * T / h_coarse) : 0.0;
    int n_phase1, n_coarse;
    if (!checked_integral_double("fine path step count", phase1_count,
                                 0, INT_MAX, &n_phase1) ||
        !checked_integral_double("coarse path step count", coarse_count,
                                 0, INT_MAX, &n_coarse)) {
        exit(1);
    }

    memset(w->Y_fine,   0, d * sizeof(double));
    memset(w->Y_coarse, 0, d * sizeof(double));

    /* ------ Phase 1: [0, T] -- fine path only ------ */
    for (int step = 0; step < n_phase1; step++) {
        for (int j = 0; j < d; j++) w->z_vec[j] = rng_randn(&w->rng);
        w->gaussians_local += d;

        compute_Cz(d, sparseL, Lp, Li, Lx, L_d, use_acc, w->z_vec, w->Cz);

#ifdef __APPLE__
        if (use_acc) {
            vDSP_vsmulD(mu, 1, &h_fine, w->dx_fine, 1, d);
            vDSP_vsmaD(w->Cz, 1, &eff_sqrt_hf, w->dx_fine, 1, w->dx_fine, 1, d);
            vDSP_vaddD(w->Y_fine, 1, w->dx_fine, 1, w->x_uncon, 1, d);
        } else
#endif
        {
            for (int j = 0; j < d; j++)
                w->dx_fine[j] = mu[j] * h_fine + eff_sqrt_hf * w->Cz[j];
            for (int j = 0; j < d; j++)
                w->x_uncon[j] = w->Y_fine[j] + w->dx_fine[j];
        }

        solve_lcp(d, R_d, w->x_uncon, w->y_lcp,
                  w->B_idx, w->R_BB, w->lcp_rhs, w->L_B, w->ipiv, use_acc,
                  Rp, Ri, Rx, sparseR);
        memcpy(w->Y_fine, w->y_lcp, d * sizeof(double));
    }

    /* ------ Phase 2: [T, (M+1)T] -- fine and coarse paths coupled ------ */
    for (int cs_step = 0; cs_step < n_coarse; cs_step++) {
        memset(w->dx_acc, 0, d * sizeof(double));

        for (int sub = 0; sub < ratio; sub++) {
            for (int j = 0; j < d; j++) w->z_vec[j] = rng_randn(&w->rng);
            w->gaussians_local += d;

            compute_Cz(d, sparseL, Lp, Li, Lx, L_d, use_acc, w->z_vec, w->Cz);

#ifdef __APPLE__
            if (use_acc) {
                vDSP_vsmulD(mu, 1, &h_fine, w->dx_fine, 1, d);
                vDSP_vsmaD(w->Cz, 1, &eff_sqrt_hf, w->dx_fine, 1, w->dx_fine, 1, d);
                vDSP_vaddD(w->Y_fine, 1, w->dx_fine, 1, w->x_uncon, 1, d);
            } else
#endif
            {
                for (int j = 0; j < d; j++)
                    w->dx_fine[j] = mu[j] * h_fine + eff_sqrt_hf * w->Cz[j];
                for (int j = 0; j < d; j++)
                    w->x_uncon[j] = w->Y_fine[j] + w->dx_fine[j];
            }

            solve_lcp(d, R_d, w->x_uncon, w->y_lcp,
                      w->B_idx, w->R_BB, w->lcp_rhs, w->L_B, w->ipiv, use_acc,
                      Rp, Ri, Rx, sparseR);
            memcpy(w->Y_fine, w->y_lcp, d * sizeof(double));

#ifdef __APPLE__
            if (use_acc)
                vDSP_vaddD(w->dx_acc, 1, w->dx_fine, 1, w->dx_acc, 1, d);
            else
#endif
                for (int j = 0; j < d; j++) w->dx_acc[j] += w->dx_fine[j];
        }

#ifdef __APPLE__
        if (use_acc)
            vDSP_vaddD(w->Y_coarse, 1, w->dx_acc, 1, w->x_uncon, 1, d);
        else
#endif
            for (int j = 0; j < d; j++) w->x_uncon[j] = w->Y_coarse[j] + w->dx_acc[j];

        solve_lcp(d, R_d, w->x_uncon, w->y_lcp,
                  w->B_idx, w->R_BB, w->lcp_rhs, w->L_B, w->ipiv, use_acc,
                  Rp, Ri, Rx, sparseR);
        memcpy(w->Y_coarse, w->y_lcp, d * sizeof(double));
    }
}

/* ========================================================================== */
/* simulate_sample: draw M, simulate one path (or an antithetic ± pair),      */
/* accumulate Z and Z^2 into the thread-local accumulators.                   */
/* ========================================================================== */

static void simulate_sample(const sim_ctx_t *ctx, workspace_t *w)
{
    const int    d       = ctx->d;
    const double gamma   = ctx->gamma;
    const double Kgamma  = ctx->Kgamma;

    int M = draw_level(&w->rng, gamma, ctx->Lev);
    double pM = Kgamma * pow(gamma, M);
    double inv_pM = 1.0 / pM;

    double Z_contrib[SRBM_MAX_DIM];

    if (!ctx->antithetic) {
        simulate_path(ctx, w, M, +1.0);
        for (int j = 0; j < d; j++)
            Z_contrib[j] = (w->Y_fine[j] - w->Y_coarse[j]) * inv_pM;
    } else {
        /* Antithetic pair: two paths share the same M and the same underlying
         * Brownian increments, but the second run flips every noise vector's
         * sign.  The contribution of the sample is the pair average, which
         * usually has lower variance than either path alone. */
        rng_state_t saved_rng = w->rng;
        long long   saved_g   = w->gaussians_local;

        simulate_path(ctx, w, M, +1.0);
        double Z_plus[SRBM_MAX_DIM];
        for (int j = 0; j < d; j++)
            Z_plus[j] = (w->Y_fine[j] - w->Y_coarse[j]) * inv_pM;

        /* Rewind RNG so the antithetic pass draws the identical z sequence. */
        w->rng = saved_rng;
        w->gaussians_local = saved_g;  /* re-count in the second pass         */

        simulate_path(ctx, w, M, -1.0);
        for (int j = 0; j < d; j++) {
            double Z_minus = (w->Y_fine[j] - w->Y_coarse[j]) * inv_pM;
            Z_contrib[j] = 0.5 * (Z_plus[j] + Z_minus);
        }
    }

    /* Accumulate Z and Z^2 (for on-the-fly variance / SE) */
    for (int j = 0; j < d; j++) {
        w->Z_sum_local[j]    += Z_contrib[j];
        w->Z_sq_sum_local[j] += Z_contrib[j] * Z_contrib[j];
    }
    w->n_local++;

    /* Progress reporting */
    if (ctx->progress) {
        int done = atomic_fetch_add_explicit(ctx->progress, 1, memory_order_relaxed) + 1;
        int interval = ctx->N / 20;
        if (interval > 0 && done % interval == 0)
            fprintf(stderr, "  Completed %d / %d (%.0f%%)\n",
                    done, ctx->N, 100.0 * done / ctx->N);
    }
}

/* ========================================================================== */
/* Batch drivers: run `n` samples of `simulate_sample` across `nthreads`      */
/* threads.  Exposed separately so the adaptive-sampling outer loop in main() */
/* can call them once per batch without rebuilding the parallel region every  */
/* time.                                                                      */
/* ========================================================================== */

/* Assign every global sample index to one stable logical RNG lane.  Including
 * batch_begin makes a fixed N-sample run consume exactly the same per-lane RNG
 * streams as an adaptive run split into several batches totaling N samples. */
static void run_logical_lane(const sim_ctx_t *ctx, workspace_t *w,
                             int lane, int lane_count,
                             long long batch_begin, int n)
{
    long long remainder = batch_begin % lane_count;
    long long first = ((long long)lane - remainder + lane_count) % lane_count;
    for (long long local = first; local < (long long)n; local += lane_count)
        simulate_sample(ctx, w);
}

#ifdef _OPENMP
static void run_batch_openmp(const sim_ctx_t *ctx, workspace_t **ws,
                              int nthreads, int n, long long batch_begin)
{
    /* Dynamic scheduling changes how many draws each per-worker RNG consumes,
     * so a fixed seed can otherwise produce different samples on every run.
     * Parallelize stable logical lanes, not samples or physical worker IDs.
     * Every lane is executed once even if OpenMP supplies a smaller team. */
    #pragma omp parallel for schedule(static) num_threads(nthreads)
    for (int lane = 0; lane < nthreads; lane++)
        run_logical_lane(ctx, ws[lane], lane, nthreads, batch_begin, n);
}
#else
static void run_batch_openmp(const sim_ctx_t *ctx, workspace_t **ws,
                              int nthreads, int n, long long batch_begin)
{
    for (int lane = 0; lane < nthreads; lane++)
        run_logical_lane(ctx, ws[lane], lane, nthreads, batch_begin, n);
}
#endif

#ifdef __APPLE__
static void run_batch_accelerate(const sim_ctx_t *ctx, workspace_t **ws,
                                  int nthreads, int n, long long batch_begin)
{
    const sim_ctx_t *ctx_p = ctx;
    workspace_t **ws_local = ws;
    const int n_local = n;
    const int nthreads_local = nthreads;
    const long long batch_begin_local = batch_begin;

    /* As with OpenMP, bind sample indices to workers rather than letting an
     * atomic work queue race decide which RNG stream consumes each sample. */
    dispatch_apply((size_t)nthreads,
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
        ^(size_t tid) {
            int lane = (int)tid; /* tid is bounded by nthreads_local <= INT_MAX */
            run_logical_lane(ctx_p, ws_local[lane], lane, nthreads_local,
                             batch_begin_local, n_local);
        });
}
#else
static void run_batch_accelerate(const sim_ctx_t *ctx, workspace_t **ws,
                                  int nthreads, int n, long long batch_begin)
{
    run_batch_openmp(ctx, ws, nthreads, n, batch_begin);
}
#endif

/* ========================================================================== */
/* Queueing network performance metrics from SRBM output                      */
/* ========================================================================== */

static void print_queueing_metrics(const network_meta_t *meta,
                                    const double *EZ, int d)
{
    if (!meta->has_metadata || meta->num_classes <= 0) return;

    int K = meta->num_stations;
    int C = meta->num_classes;

    /* Compute per-station sojourn and waiting times via Little's law */
    double *sojourn_i = malloc(K * sizeof(double));
    double *waiting_i = malloc(K * sizeof(double));

    for (int i = 0; i < K; i++) {
        /* Sojourn at station i: E[T_i] = E[Z_i] / alpha_i */
        if (meta->alpha_total[i] > 1e-15)
            sojourn_i[i] = EZ[i] / meta->alpha_total[i];
        else
            sojourn_i[i] = 0.0;

        /* Effective per-server rate: mu_eff_i = c_i / s_i */
        double mu_eff_i = 1.0;
        if (meta->servers[i] > 0 && meta->capacities[i] > 1e-15)
            mu_eff_i = meta->capacities[i] / meta->servers[i];

        /* Waiting time: W_i = E[T_i] - 1/mu_eff_i */
        waiting_i[i] = sojourn_i[i] - 1.0 / mu_eff_i;
        if (waiting_i[i] < 0.0) waiting_i[i] = 0.0;
    }

    printf("#\n");
    printf("# ============================================================\n");
    printf("# QUEUEING NETWORK PERFORMANCE METRICS\n");
    printf("# ============================================================\n");
    printf("#\n");

    /* Per-station expected content */
    printf("# Per-Station Expected Content E[Z_i]:\n");
    for (int i = 0; i < K; i++)
        printf("#   %-16s  %10.6f\n", meta->station_names[i], EZ[i]);
    printf("#\n");

    /* Per-station sojourn time */
    printf("# Per-Station Sojourn Time E[T_i] = E[Z_i] / alpha_i:\n");
    for (int i = 0; i < K; i++)
        printf("#   %-16s  %10.6f  (alpha_i = %.4f)\n",
               meta->station_names[i], sojourn_i[i], meta->alpha_total[i]);
    printf("#\n");

    /* Per-station waiting time */
    printf("# Per-Station Waiting Time W_i = E[T_i] - 1/mu_eff_i:\n");
    for (int i = 0; i < K; i++)
        printf("#   %-16s  %10.6f\n", meta->station_names[i], waiting_i[i]);
    printf("#\n");

    /* ---- Waiting Time Matrix ---- */
    printf("# ============================================================\n");
    printf("# Waiting Time Matrix\n");
    printf("# Rows = Customer classes, Columns = Station queues\n");
    printf("# (Waiting time is shared across all classes at each station)\n");
    printf("# ============================================================\n");
    printf("#\n");

    /* Header row */
    printf("# %16s", "");
    for (int i = 0; i < K; i++) printf("  %12s", meta->station_names[i]);
    printf("\n");

    for (int k = 0; k < C; k++) {
        printf("# %16s", meta->class_names[k]);
        for (int i = 0; i < K; i++) printf("  %12.6f", waiting_i[i]);
        printf("\n");
    }
    printf("#\n");

    /* ---- Sojourn Time at Each Station ---- */
    printf("# ============================================================\n");
    printf("# Sojourn Time at Each Station: T_{i,k} = W_i + 1/mu_{i,k}\n");
    printf("# Rows = Customer classes, Columns = Station queues\n");
    printf("# ============================================================\n");
    printf("#\n");

    double *sojourn_ik = malloc(C * K * sizeof(double));

    printf("# %16s", "");
    for (int i = 0; i < K; i++) printf("  %12s", meta->station_names[i]);
    printf("\n");

    for (int k = 0; k < C; k++) {
        printf("# %16s", meta->class_names[k]);
        for (int i = 0; i < K; i++) {
            double mu_ki = meta->mu_class[k * K + i];
            double service_time = (mu_ki > 1e-15) ? 1.0 / mu_ki : 0.0;
            sojourn_ik[k * K + i] = waiting_i[i] + service_time;
            printf("  %12.6f", sojourn_ik[k * K + i]);
        }
        printf("\n");
    }
    printf("#\n");

    /* ---- Expected Total Sojourn per Class ---- */
    printf("# ============================================================\n");
    printf("# Expected Total Sojourn Time per Customer Class\n");
    printf("# S_k = Sum_i v_{i,k} * T_{i,k}\n");
    printf("# where v_{i,k} = alpha_{i,k} / lambda_k (expected visits)\n");
    printf("# ============================================================\n");
    printf("#\n");

    for (int k = 0; k < C; k++) {
        /* Total external arrival rate for class k */
        double lambda_k = 0.0;
        for (int i = 0; i < K; i++)
            lambda_k += meta->lambda_ext[k * K + i];

        double S_k = 0.0;
        printf("#   %s:\n", meta->class_names[k]);
        printf("#     Visit ratios v_{i,k}:");
        for (int i = 0; i < K; i++) {
            double v_ik = (lambda_k > 1e-15) ?
                          meta->alpha_class[k * K + i] / lambda_k : 0.0;
            S_k += v_ik * sojourn_ik[k * K + i];
            printf("  %8.4f", v_ik);
        }
        printf("\n");
        printf("#     E[Sojourn] = %.6f\n", S_k);
        printf("#\n");
    }

    /* ---- Summary ---- */
    printf("# ============================================================\n");
    printf("# SUMMARY: Expected Wait per Station (all classes)\n");
    printf("# ============================================================\n");
    for (int i = 0; i < K; i++)
        printf("#   %-16s  W = %10.6f\n", meta->station_names[i], waiting_i[i]);
    printf("#\n");

    free(sojourn_i);
    free(waiting_i);
    free(sojourn_ik);
}

/* Print compact per-class sojourn times (for -c mode) */
static void print_compact_queueing(const network_meta_t *meta,
                                    const double *EZ, int d)
{
    if (!meta->has_metadata || meta->num_classes <= 0) return;

    int K = meta->num_stations;
    int C = meta->num_classes;

    /* Compute waiting times */
    for (int k = 0; k < C; k++) {
        double lambda_k = 0.0;
        for (int i = 0; i < K; i++)
            lambda_k += meta->lambda_ext[k * K + i];

        double S_k = 0.0;
        for (int i = 0; i < K; i++) {
            double sojourn = (meta->alpha_total[i] > 1e-15) ?
                             EZ[i] / meta->alpha_total[i] : 0.0;
            double mu_eff = (meta->servers[i] > 0 && meta->capacities[i] > 1e-15) ?
                            meta->capacities[i] / meta->servers[i] : 1.0;
            double wait = sojourn - 1.0 / mu_eff;
            if (wait < 0.0) wait = 0.0;

            double mu_ki = meta->mu_class[k * K + i];
            double T_ik = wait + ((mu_ki > 1e-15) ? 1.0 / mu_ki : 0.0);
            double v_ik = (lambda_k > 1e-15) ?
                          meta->alpha_class[k * K + i] / lambda_k : 0.0;
            S_k += v_ik * T_ik;
        }
        printf("E[Sojourn_%s] = %.6f\n", meta->class_names[k], S_k);
    }

    /* Per-station waiting times */
    for (int i = 0; i < K; i++) {
        double sojourn = (meta->alpha_total[i] > 1e-15) ?
                         EZ[i] / meta->alpha_total[i] : 0.0;
        double mu_eff = (meta->servers[i] > 0 && meta->capacities[i] > 1e-15) ?
                        meta->capacities[i] / meta->servers[i] : 1.0;
        double wait = sojourn - 1.0 / mu_eff;
        if (wait < 0.0) wait = 0.0;
        printf("W[%s] = %.6f\n", meta->station_names[i], wait);
    }
}

/* ========================================================================== */
/* Main                                                                       */
/* ========================================================================== */

int main(int argc, char *argv[])
{
    /* Check for -c (compact output) as first argument */
    int arg_offset = 1;
    if (argc > 1 && strcmp(argv[1], "-c") == 0) {
        compact_mode = 1;
        arg_offset = 2;
    }

    if (argc < arg_offset + 3) {
        fprintf(stderr,
            "Usage: %s [-c] <input_file> <gamma> <epsilon> [options]\n"
            "Options:\n"
            "  -c                   Compact output (algorithm name + means only)\n"
            "  --seed S             Random seed (default: time-based)\n"
            "  --backend B          accelerate, openmp, or serial (default: accelerate)\n"
            "  --threads N          Number of threads (default: auto-detect)\n"
            "  --T val              Override mixing time T (default: (ln d)^2 / 2)\n"
            "  --L val              Override number of MLMC levels L\n"
            "  --N val              Override fixed-run N; adaptive fallback cap\n"
            "  --antithetic         Antithetic variate pairs (±noise) per sample\n"
            "  --adaptive           Run in batches; stop when worst-case SE < epsilon\n"
            "  --batch-size K       Batch size for --adaptive (default 1000)\n"
            "  --min-samples K      Minimum samples before --adaptive can stop\n"
            "                       (default: 5 * batch-size; prevents small-N premature stops)\n"
            "  --max-samples M      Positive adaptive sample cap (required unless --N is set)\n"
            "Legacy: %s [-c] <input_file> <gamma> <epsilon> <seed>\n",
            argv[0], argv[0]);
        return 1;
    }

    const char *input_file = argv[arg_offset];
    double gamma, epsilon;
    if (!parse_finite_double("gamma", argv[arg_offset + 1], &gamma) ||
        !parse_finite_double("epsilon", argv[arg_offset + 2], &epsilon)) {
        return 1;
    }
    long   seed    = (long)time(NULL);
    int    nthreads = 0;   /* 0 = auto-detect */
    double T_override = -1.0;  /* <0 means use default */
    int    L_override = -1;    /* <0 means use default */
    int    N_override = -1;    /* <0 means use default */
    int    antithetic = 0;     /* 1 = ± noise pair per sample             */
    int    adaptive   = 0;     /* 1 = run in batches, stop when SE < eps  */
    int    batch_size = 1000;
    int    max_samples = 0;    /* 0 = not supplied                         */
    int    min_samples = 0;    /* 0 => default = 5*batch_size             */

#ifdef _OPENMP
    backend_t backend = BACKEND_OPENMP;
#elif defined(__APPLE__)
    backend_t backend = BACKEND_ACCELERATE;
#else
    backend_t backend = BACKEND_SERIAL;
#endif

    /* Parse optional arguments */
    for (int i = arg_offset + 3; i < argc; i++) {
        if (strcmp(argv[i], "--backend") == 0) {
            if (i + 1 >= argc) { fprintf(stderr, "Missing value for --backend\n"); return 1; }
            i++;
            if (strcmp(argv[i], "accelerate") == 0)
                backend = BACKEND_ACCELERATE;
            else if (strcmp(argv[i], "openmp") == 0)
                backend = BACKEND_OPENMP;
            else if (strcmp(argv[i], "serial") == 0)
                backend = BACKEND_SERIAL;
            else { fprintf(stderr, "Unknown backend: %s\n", argv[i]); return 1; }
        } else if (strcmp(argv[i], "--threads") == 0) {
            if (i + 1 >= argc) { fprintf(stderr, "Missing value for --threads\n"); return 1; }
            if (!parse_int_in_range("--threads", argv[++i], 0, INT_MAX,
                                    &nthreads)) return 1;
        } else if (strcmp(argv[i], "--seed") == 0) {
            if (i + 1 >= argc) { fprintf(stderr, "Missing value for --seed\n"); return 1; }
            if (!parse_long_value("--seed", argv[++i], &seed)) return 1;
        } else if (strcmp(argv[i], "--T") == 0) {
            if (i + 1 >= argc) { fprintf(stderr, "Missing value for --T\n"); return 1; }
            if (!parse_finite_double("--T", argv[++i], &T_override)) return 1;
            if (T_override <= 0.0) { fprintf(stderr, "--T must be > 0\n"); return 1; }
        } else if (strcmp(argv[i], "--L") == 0) {
            if (i + 1 >= argc) { fprintf(stderr, "Missing value for --L\n"); return 1; }
            if (!parse_int_in_range("--L", argv[++i], 1, INT_MAX,
                                    &L_override)) return 1;
        } else if (strcmp(argv[i], "--N") == 0) {
            if (i + 1 >= argc) { fprintf(stderr, "Missing value for --N\n"); return 1; }
            if (!parse_int_in_range("--N", argv[++i], 1, INT_MAX,
                                    &N_override)) return 1;
        } else if (strcmp(argv[i], "--antithetic") == 0) {
            antithetic = 1;
        } else if (strcmp(argv[i], "--adaptive") == 0) {
            adaptive = 1;
        } else if (strcmp(argv[i], "--batch-size") == 0) {
            if (i + 1 >= argc) { fprintf(stderr, "Missing value for --batch-size\n"); return 1; }
            if (!parse_int_in_range("--batch-size", argv[++i], 1, INT_MAX,
                                    &batch_size)) return 1;
        } else if (strcmp(argv[i], "--max-samples") == 0) {
            if (i + 1 >= argc) { fprintf(stderr, "Missing value for --max-samples\n"); return 1; }
            if (!parse_int_in_range("--max-samples", argv[++i], 1, INT_MAX,
                                    &max_samples)) return 1;
        } else if (strcmp(argv[i], "--min-samples") == 0) {
            if (i + 1 >= argc) { fprintf(stderr, "Missing value for --min-samples\n"); return 1; }
            if (!parse_int_in_range("--min-samples", argv[++i], 1, INT_MAX,
                                    &min_samples)) return 1;
        } else if (argv[i][0] != '-') {
            if (!parse_long_value("seed", argv[i], &seed)) return 1;
        } else {
            fprintf(stderr, "Unknown option: %s\n", argv[i]);
            return 1;
        }
    }

    /* Validate parameters */
    if (gamma <= 0.0 || gamma >= 1.0) {
        fprintf(stderr, "gamma must be in (0,1)\n"); return 1;
    }
    if (epsilon <= 0.0) {
        fprintf(stderr, "epsilon must be > 0\n"); return 1;
    }
    double reciprocal = 1.0 / gamma;
    double rounded_reciprocal = round(reciprocal);
    int ratio;
    if (!checked_integral_double("1/gamma", rounded_reciprocal,
                                 1, INT_MAX, &ratio)) return 1;
    if (fabs(ratio * gamma - 1.0) > 1e-9) {
        fprintf(stderr, "1/gamma must be a positive integer (got 1/gamma = %g)\n",
                1.0 / gamma);
        return 1;
    }

    /* Validate backend availability */
#ifndef __APPLE__
    if (backend == BACKEND_ACCELERATE) {
        fprintf(stderr, "Accelerate backend requires macOS. Falling back to serial.\n");
        backend = BACKEND_SERIAL;
    }
#endif
#ifndef _OPENMP
    if (backend == BACKEND_OPENMP) {
        fprintf(stderr, "OpenMP not available (install libomp: brew install libomp). "
                        "Falling back to serial.\n");
        backend = BACKEND_SERIAL;
    }
#endif

    /* Auto-detect thread count */
    if (backend == BACKEND_SERIAL) {
        nthreads = 1;
    } else if (nthreads <= 0) {
#ifdef _OPENMP
        if (backend == BACKEND_OPENMP)
            nthreads = omp_get_max_threads();
        else
#endif
        {
            long detected_threads = sysconf(_SC_NPROCESSORS_ONLN);
            if (detected_threads > INT_MAX)
                nthreads = INT_MAX;
            else if (detected_threads > 0)
                nthreads = (int)detected_threads;
            else
                nthreads = 1;
        }
        if (nthreads <= 0) nthreads = 1;
    }

    /* In compact mode, suppress stdout */
    if (compact_mode) {
        compact_suppress_stdout();
    }

    /* Parse input */
    int d;
    double *mu, *Sigma, *R_dense;
    network_meta_t net_meta;
    parse_input(input_file, &d, &mu, &Sigma, &R_dense, &net_meta);

    /* Build CSC form of R (column-major; only non-zero entries) so the LCP
     * column-update can do a sparse daxpy when R is banded. */
    cs_di *R_csc = NULL;
    int    R_nnz = 0;
    int    use_sparse_R = 0;
    {
        cs_di *Rt = cs_di_spalloc(d, d, d * d, 1, 1);
        for (int j = 0; j < d; j++)
            for (int i = 0; i < d; i++) {
                double v = R_dense[i * d + j];
                if (v != 0.0) cs_di_entry(Rt, i, j, v);
            }
        R_csc = cs_di_compress(Rt);
        cs_di_spfree(Rt);
        R_nnz = R_csc->p[d];
        use_sparse_R = (R_nnz <= 4 * d);
    }

    /* Compute Cholesky factor L via CXSparse.  Keep CSC form; build a dense
     * copy only if L is not sparse enough for the sparse path to win. */
    cs_di *L_sparse = compute_cholesky_factor(d, Sigma);
    int    L_nnz    = L_sparse->p[d];

    /* Use sparse trmv when nnz(L) <= 4*d (handles diagonal, bidiagonal,
     * tridiagonal, pentadiagonal, and typical queueing-network structure).
     * Dense L*z is cache-friendly and well-optimized by cblas_dtrmv, so we
     * switch back to dense once L has more than ~4d non-zeros.
     * Environment override: BNAMC_SPARSE=0 forces dense, =1 forces sparse. */
    int use_sparse_L = (L_nnz <= 4 * d);
    const char *env_s = getenv("BNAMC_SPARSE");
    if (env_s) use_sparse_L = (atoi(env_s) != 0);

    double *L_dense = NULL;
    if (!use_sparse_L) {
        L_dense = sparse_to_dense_lower(L_sparse, d);
    }
    fprintf(stderr, "Sigma nnz ratio: L has %d non-zeros of %d^2 = %d  (%.2f%%); "
                    "using %s path\n",
            L_nnz, d, d * d, 100.0 * L_nnz / (double)(d * d),
            use_sparse_L ? "SPARSE CSC" : "dense BLAS");
    fprintf(stderr, "R     nnz ratio: %d non-zeros of %d^2 = %d  (%.2f%%); "
                    "using %s LCP column update\n",
            R_nnz, d, d * d, 100.0 * R_nnz / (double)(d * d),
            use_sparse_R ? "SPARSE CSC" : "dense BLAS");

    /* Env overrides for benchmarking */
    {
        const char *e_sR = getenv("BNAMC_SPARSE_R");
        if (e_sR) use_sparse_R = (atoi(e_sR) != 0);
    }

    /* Compute MLMC parameters (defaults from Section 4 of the paper) */
    double log_d   = log((double)d);
    double T       = log_d * log_d / 2.0;
    if (T < 5.0) T = 5.0;  /* paper formula is for large d; enforce minimum */

    /* Estimate mixing time from problem parameters: eta = R^{-1} * mu,
     * then stationary mean ~ Sigma_kk / (2*|eta_k|).  Set T to at least
     * 10 * max(mean_est) so the process has time to reach stationarity. */
    {
        double *Rcopy = malloc(d * d * sizeof(double));
        double *eta   = malloc(d * sizeof(double));
        for (int i = 0; i < d * d; i++) Rcopy[i] = R_dense[i];
        for (int i = 0; i < d; i++) eta[i] = mu[i];

        /* Gaussian elimination: solve R * eta = mu (row-major) */
        for (int col = 0; col < d; col++) {
            int pivot = col;
            double pv = fabs(Rcopy[col * d + col]);
            for (int row = col + 1; row < d; row++) {
                if (fabs(Rcopy[row * d + col]) > pv) {
                    pv = fabs(Rcopy[row * d + col]);
                    pivot = row;
                }
            }
            if (pivot != col) {
                for (int j = 0; j < d; j++) {
                    double tmp = Rcopy[col * d + j];
                    Rcopy[col * d + j] = Rcopy[pivot * d + j];
                    Rcopy[pivot * d + j] = tmp;
                }
                double tmp = eta[col]; eta[col] = eta[pivot]; eta[pivot] = tmp;
            }
            if (fabs(Rcopy[col * d + col]) > 1e-14) {
                for (int row = col + 1; row < d; row++) {
                    double f = Rcopy[row * d + col] / Rcopy[col * d + col];
                    for (int j = col; j < d; j++)
                        Rcopy[row * d + j] -= f * Rcopy[col * d + j];
                    eta[row] -= f * eta[col];
                }
            }
        }
        for (int i = d - 1; i >= 0; i--) {
            for (int j = i + 1; j < d; j++)
                eta[i] -= Rcopy[i * d + j] * eta[j];
            if (fabs(Rcopy[i * d + i]) > 1e-14)
                eta[i] /= Rcopy[i * d + i];
        }

        double max_relax = 0.0;
        for (int k = 0; k < d; k++) {
            if (fabs(eta[k]) > 1e-14) {
                /* Relaxation time ~ Sigma_kk / (2 * eta_k^2) */
                double tau = Sigma[k * d + k] / (2.0 * eta[k] * eta[k]);
                if (tau > max_relax) max_relax = tau;
            }
        }
        double T_est = 5.0 * max_relax;  /* 5 relaxation times */
        if (T_est > T) T = T_est;

        free(Rcopy);
        free(eta);
    }
    int Lev;
    if (L_override > 0) {
        /* Do not evaluate the automatic formula when the caller supplied L. */
        Lev = L_override;
    } else if (d == 1) {
        /* log(log(1)) is -Inf; the limiting/clamped value is one level. */
        Lev = 1;
    } else {
        /* Work in log space so very small positive epsilon values do not
         * overflow in an intermediate 1/epsilon calculation. */
        double raw_levels = ceil((log(log_d) - 2.0 * log(epsilon) - 2.0)
                                 / -log(gamma));
        if (raw_levels < 1.0) raw_levels = 1.0;
        if (!checked_integral_double("automatic level count", raw_levels,
                                     1, INT_MAX, &Lev)) return 1;
    }

    if (T_override > 0.0) T = T_override;
    if (!isfinite(T) || T <= 0.0) {
        fprintf(stderr, "Mixing time T must be finite and > 0 (got %.17g)\n", T);
        return 1;
    }
    if (!validate_path_step_counts(T, gamma, Lev)) return 1;

    double gammaL = pow(gamma, (double)Lev);
    double denominator = 1.0 - gammaL;
    if (!isfinite(gammaL) || gammaL < 0.0 || gammaL >= 1.0 ||
        !isfinite(denominator) || denominator <= 0.0) {
        fprintf(stderr, "Could not form a finite level distribution for gamma=%g, L=%d\n",
                gamma, Lev);
        return 1;
    }
    double Kgamma = (1.0 - gamma) / denominator;
    if (!isfinite(Kgamma) || Kgamma <= 0.0) {
        fprintf(stderr, "Invalid level-distribution normalizer for gamma=%g, L=%d\n",
                gamma, Lev);
        return 1;
    }

    int N;
    int adaptive_cap_from_n = 0;
    if (adaptive) {
        /* Adaptive sampling is governed by a real positive cap.  --N is a
         * backward-compatible fallback only when --max-samples was omitted.
         * In particular, never evaluate gamma^-L in this branch. */
        if (max_samples <= 0) {
            if (N_override > 0) {
                max_samples = N_override;
                adaptive_cap_from_n = 1;
            } else {
                fprintf(stderr,
                        "--adaptive requires a positive --max-samples cap "
                        "(or --N as a fallback cap)\n");
                return 1;
            }
        } else if (N_override > 0) {
            fprintf(stderr,
                    "Note: --max-samples controls adaptive sampling; --N is ignored.\n");
        }
        if (max_samples < 2) {
            fprintf(stderr,
                    "The adaptive sample cap must be at least 2 so a sample variance can be estimated\n");
            return 1;
        }
        if (min_samples > 0 && min_samples > max_samples) {
            fprintf(stderr,
                    "--min-samples (%d) must not exceed the adaptive cap (%d)\n",
                    min_samples, max_samples);
            return 1;
        }
        N = max_samples;
    } else if (N_override > 0) {
        /* A supplied N must bypass the potentially overflowing automatic
         * gamma^-L calculation entirely. */
        N = N_override;
    } else {
        double inverse_level_scale = pow(gamma, -(double)Lev);
        double raw_samples = ceil((1.0 / Kgamma) * inverse_level_scale * (double)Lev);
        if (!checked_integral_double("automatic sample count", raw_samples,
                                     1, INT_MAX, &N)) {
            fprintf(stderr,
                    "Use a positive --N override, or --adaptive with a positive sample cap.\n");
            return 1;
        }
    }

    /* No run needs more workers than samples in its smallest dispatch. */
    int worker_cap = adaptive && batch_size < N ? batch_size : N;
    if (nthreads > worker_cap) nthreads = worker_cap;

    const char *backend_name = (backend == BACKEND_ACCELERATE) ? "accelerate" :
                               (backend == BACKEND_OPENMP)     ? "openmp"     : "serial";

    fprintf(stderr, "Dimension d   = %d\n", d);
    fprintf(stderr, "gamma         = %g\n", gamma);
    fprintf(stderr, "epsilon       = %g\n", epsilon);
    fprintf(stderr, "seed          = %ld\n", seed);
    fprintf(stderr, "T             = %.4f\n", T);
    fprintf(stderr, "L (levels)    = %d\n", Lev);
    if (adaptive) {
        fprintf(stderr, "sample cap    = %d (%s)\n", max_samples,
                adaptive_cap_from_n ? "--N fallback" : "--max-samples");
    } else {
        fprintf(stderr, "N (samples)   = %d\n", N);
    }
    fprintf(stderr, "ratio (1/gam) = %d\n", ratio);
    fprintf(stderr, "backend       = %s\n", backend_name);
    fprintf(stderr, "threads       = %d\n", nthreads);
    fprintf(stderr, "\n");

    /* Allocate per-thread workspaces, each with independent RNG stream */
    workspace_t **ws = malloc(nthreads * sizeof(workspace_t *));
    for (int t = 0; t < nthreads; t++) {
        ws[t] = alloc_workspace(d, antithetic);
        rng_seed(&ws[t]->rng, (uint64_t)seed + (uint64_t)t);
    }

    /* Set up simulation context */
    atomic_int progress_counter = ATOMIC_VAR_INIT(0);
    sim_ctx_t ctx = {
        .d = d, .Lev = Lev, .ratio = ratio, .N = N,
        .gamma = gamma, .T = T, .Kgamma = Kgamma,
        .mu = mu, .R_dense = R_dense, .L_dense = L_dense,
        .Lp = L_sparse->p, .Li = L_sparse->i, .Lx = L_sparse->x,
        .L_nnz = L_nnz,
        .use_sparse_L = use_sparse_L,
        .Rp = R_csc->p, .Ri = R_csc->i, .Rx = R_csc->x,
        .R_nnz = R_nnz,
        .use_sparse_R = use_sparse_R,
        .use_accelerate = (backend == BACKEND_ACCELERATE),
        .antithetic = antithetic,
        .progress = (N >= 100) ? &progress_counter : NULL
    };

    fprintf(stderr, "antithetic    = %s\n", antithetic ? "on" : "off");
    fprintf(stderr, "adaptive      = %s", adaptive ? "on" : "off");
    if (adaptive) fprintf(stderr, " (batch=%d, SE target=%g)", batch_size, epsilon);
    fprintf(stderr, "\n\n");

    /* ====== Run simulation ====== */
    struct timespec t_start, t_end;
    clock_gettime(CLOCK_MONOTONIC, &t_start);

    /* Dispatch one batch.  begin is the global sample offset, which keeps
     * logical RNG lanes stable when adaptive mode splits a run into batches. */
    #define RUN_BATCH(batch, begin) do {                                    \
        const int _n = (batch);                                             \
        const long long _begin = (begin);                                   \
        ctx.N = _n; /* for progress reporting */                            \
        atomic_store(&progress_counter, 0);                                 \
        if (backend == BACKEND_ACCELERATE) {                                \
            _Pragma("clang diagnostic push")                                \
            _Pragma("clang diagnostic ignored \"-Wunused-variable\"")       \
            _Pragma("clang diagnostic pop")                                 \
            run_batch_accelerate(&ctx, ws, nthreads, _n, _begin);           \
        } else if (backend == BACKEND_OPENMP) {                             \
            run_batch_openmp(&ctx, ws, nthreads, _n, _begin);               \
        } else {                                                            \
            workspace_t *w = ws[0];                                         \
            for (int s = 0; s < _n; s++) simulate_sample(&ctx, w);          \
        }                                                                   \
    } while (0)

    /*
     * Classical mode:   one flat run of N samples.
     * Adaptive mode:    successive batches of `batch_size` samples.  After
     *                   each batch we compute the worst-case standard error
     *                   across dimensions and stop when it's below the
     *                   epsilon target or when its required sample cap is
     *                   reached.
     */
    long long n_total = 0;
    int stop_reason = 0;   /* 0=N reached, 1=SE target met, 2=adaptive cap */

    if (!adaptive) {
        RUN_BATCH(N, 0LL);
        n_total = N;
        stop_reason = 0;
    } else {
        /* max_samples is guaranteed positive by the preflight above. */
        long long cap = (long long)max_samples;
        long long floor_samples = (min_samples > 0) ? min_samples
                                                    : 5LL * (long long)batch_size;
        while (n_total < cap) {
            int b = batch_size;
            if (n_total + b > cap) b = (int)(cap - n_total);
            RUN_BATCH(b, n_total);
            n_total += b;

            /* Don't attempt an early stop before we've drawn enough samples to
             * have likely seen at least a few realizations of the rare high-M
             * levels (where Z carries large weight 1/p(M)); otherwise the
             * sample variance underestimates the true variance. */
            if (n_total < floor_samples) continue;

            /* Compute running mean + variance across the accumulators */
            double worst_se = 0.0;
            for (int j = 0; j < d; j++) {
                double S1 = 0.0, S2 = 0.0;
                long long N1 = 0;
                for (int t = 0; t < nthreads; t++) {
                    S1 += ws[t]->Z_sum_local[j];
                    S2 += ws[t]->Z_sq_sum_local[j];
                    if (j == 0) N1 += ws[t]->n_local;  /* once */
                }
                if (j == 0) n_total = N1;             /* keep in sync      */
                if (n_total < 2) continue;
                double m  = S1 / (double)n_total;
                double v  = (S2 - (double)n_total * m * m) / (double)(n_total - 1);
                if (!isfinite(S1) || !isfinite(S2) || !isfinite(m) || !isfinite(v)) {
                    fprintf(stderr,
                            "Non-finite MLMC accumulator for component %d after %lld samples; "
                            "reduce --T/--L or inspect the model inputs.\n",
                            j + 1, n_total);
                    exit(EXIT_FAILURE);
                }
                if (v < 0.0) v = 0.0;
                double se = sqrt(v / (double)n_total);
                if (!isfinite(se)) {
                    fprintf(stderr,
                            "Non-finite MLMC standard error for component %d after %lld samples.\n",
                            j + 1, n_total);
                    exit(EXIT_FAILURE);
                }
                if (se > worst_se) worst_se = se;
            }
            if (n_total >= 2 && worst_se < epsilon) {
                stop_reason = 1;
                break;
            }
        }
        if (stop_reason != 1) stop_reason = 2;
    }

    clock_gettime(CLOCK_MONOTONIC, &t_end);
    double elapsed = (double)(t_end.tv_sec - t_start.tv_sec) +
                     (double)(t_end.tv_nsec - t_start.tv_nsec) * 1e-9;

    /* Reduce across threads */
    double *Z_sum  = calloc(d, sizeof(double));
    double *Z_sq   = calloc(d, sizeof(double));
    long long total_gaussians = 0;
    long long n_check = 0;
    for (int t = 0; t < nthreads; t++) {
        for (int j = 0; j < d; j++) {
            Z_sum[j] += ws[t]->Z_sum_local[j];
            Z_sq[j]  += ws[t]->Z_sq_sum_local[j];
        }
        total_gaussians += ws[t]->gaussians_local;
        n_check += ws[t]->n_local;
    }
    if (n_check > 0) n_total = n_check;
    if (n_total < 1) n_total = 1;

    /* Compute E[Z_i] = Z_sum[i] / n_total, plus per-dim SE and 95% CI */
    double *EZ = malloc(d * sizeof(double));
    double *SE = calloc(d, sizeof(double));
    for (int j = 0; j < d; j++) {
        double m = Z_sum[j] / (double)n_total;
        if (!isfinite(Z_sum[j]) || !isfinite(Z_sq[j]) || !isfinite(m)) {
            fprintf(stderr,
                    "Non-finite MLMC result for component %d after %lld samples; "
                    "reduce --T/--L or inspect the model inputs.\n",
                    j + 1, n_total);
            exit(EXIT_FAILURE);
        }
        EZ[j] = m;
        if (n_total >= 2) {
            double v = (Z_sq[j] - (double)n_total * m * m) / (double)(n_total - 1);
            if (!isfinite(v)) {
                fprintf(stderr,
                        "Non-finite MLMC variance for component %d after %lld samples.\n",
                        j + 1, n_total);
                exit(EXIT_FAILURE);
            }
            if (v < 0.0) v = 0.0;
            SE[j] = sqrt(v / (double)n_total);
            if (!isfinite(SE[j])) {
                fprintf(stderr,
                        "Non-finite MLMC standard error for component %d after %lld samples.\n",
                        j + 1, n_total);
                exit(EXIT_FAILURE);
            }
        }
    }
    /* Student-t 95% one-tailed approximated by 1.96 once N ≥ ~30 */
    const double Z_95 = 1.96;

    /* Output */
    printf("# Dimension: %d\n", d);
    printf("# gamma=%.4f  epsilon=%.4f  T=%.4f  L=%d  N=%lld  seed=%ld\n",
           gamma, epsilon, T, Lev, n_total, seed);
    printf("# backend=%s  threads=%d  elapsed=%.3fs\n",
           backend_name, nthreads, elapsed);
    printf("# Total Gaussian RVs generated: %lld\n", total_gaussians);
    printf("# antithetic=%s adaptive=%s",
           antithetic ? "on" : "off",
           adaptive ? "on" : "off");
    if (adaptive) {
        const char *why = adaptive_cap_from_n ? "hit --N fallback cap"
                                              : "hit --max-samples cap";
        if (stop_reason == 1) why = "SE target achieved";
        printf(" stop=%s", why);
    }
    printf("\n#\n");
    printf("# Component   E[Y_i(inf)]     SE          95%% CI half-width\n");
    for (int j = 0; j < d; j++) {
        printf("  %4d        %.6f     %.6f     %.6f\n",
               j + 1, EZ[j], SE[j], Z_95 * SE[j]);
    }

    double avg = 0.0;
    for (int j = 0; j < d; j++) {
        avg += EZ[j];
    }
    avg /= d;
    printf("#\n");
    printf("# Average across all components: %.6f  "
           "(point estimate only; joint SE/CI requires cross-component covariance "
           "or independent replications)\n",
           avg);
    printf("# Total complexity (Gaussian RVs): %lld\n", total_gaussians);

    /* Print queueing network metrics if network metadata is available */
    print_queueing_metrics(&net_meta, EZ, d);

    /* Restore stdout if compact mode was active */
    if (compact_mode) {
        compact_restore_stdout();
        printf("MLMC (BNAmc)\n");
        printf("=================\n");
    }

    /* Means: always printed last */
    for (int j = 0; j < d; j++) {
        printf("E[X_%d] = %.6f\n", j + 1, EZ[j]);
    }

    /* Compact per-class queueing output */
    print_compact_queueing(&net_meta, EZ, d);

    /* Cleanup */
    for (int t = 0; t < nthreads; t++)
        free_workspace(ws[t]);
    free(ws);
    free(Z_sum);
    free(Z_sq);
    free(SE);
    free(EZ);
    if (L_dense) free(L_dense);
    cs_di_spfree(L_sparse);
    cs_di_spfree(R_csc);
    free(mu); free(Sigma); free(R_dense);
    free_network_meta(&net_meta);

    return 0;
}
