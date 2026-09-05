/*
 * bnet.c - Main BNET solver
 * Updated to use SuiteSparse CHOLMOD and OpenMP parallelization
 *
 * This solver computes the stationary distribution of a reflected
 * Brownian motion in an orthant using polynomial approximation.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <pthread.h>
#include <omp.h>
#include "bnet.h"
#include "../../common/bnet_memcheck.h"

/* Unified Qnet progress protocol (-P PATH).
 * First line of progress file = decimal total + '\n'; each completed
 * unit appends one '.' byte. Locking via pthread_mutex protects
 * against torn writes from OpenMP threads. `bnet_progress_path` is
 * filled in by the option parser in bnetio.c, hence non-static. */
char  bnet_progress_path[1024] = "";
static FILE *bnet_progress_fp = NULL;
static pthread_mutex_t bnet_progress_lock = PTHREAD_MUTEX_INITIALIZER;

void bnet_progress_open(long total);
void bnet_progress_tick(void);
void bnet_progress_close(void);

void bnet_progress_open(long total) {
    if (!bnet_progress_path[0]) return;
    bnet_progress_fp = fopen(bnet_progress_path, "wb");
    if (!bnet_progress_fp) return;
    fprintf(bnet_progress_fp, "%ld\n", total);
    fflush(bnet_progress_fp);
}
void bnet_progress_tick(void) {
    if (!bnet_progress_fp) return;
    pthread_mutex_lock(&bnet_progress_lock);
    fputc('.', bnet_progress_fp);
    fflush(bnet_progress_fp);
    pthread_mutex_unlock(&bnet_progress_lock);
}
void bnet_progress_close(void) {
    if (bnet_progress_fp) {
        fclose(bnet_progress_fp);
        bnet_progress_fp = NULL;
    }
}

/* ── Customer class data (optional, read from input after degree) ── */
#define CC_MAX 64
static int    cc_num_classes = 0;       /* K; 0 = feature off        */
static double cc_tau[CC_MAX];           /* workload-to-queue factor   */
static double cc_alpha_total[CC_MAX];   /* total throughput per stn   */
static double cc_mueff[CC_MAX];         /* effective service rate/stn  */
static double cc_lambda[CC_MAX];        /* ext arrival rate per class  */
static double cc_alpha[CC_MAX][CC_MAX]; /* alpha[k][i] K x d          */
static double cc_mu[CC_MAX][CC_MAX];    /* mu[k][i] K x d             */

/* Compact output stdout suppression */
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

/* Forward declarations */
void initpoly(poly *f, int k, int **c, int d);
long Index(int dim, int *II, int **c);
real inner(poly *f, int t, poly *g, int m, int **c, int **I, int **Ib, real **w, int d);
real inner_2(int *I, int *J, int *K, real **w, DMAT *Gamma, DVEC *mu, DMAT *R, int d);
void half_linear(poly *f, int t, real a, poly *g, int m, poly *h, int **c, int d);
void fwsub(real **L, real *b, int n);
void bksub(real **L, real *b, int n);
int try_get_degree(FILE *input_fp, int d);

/* Progress reporting */
static void report_step(const char *step, const char *details) {
    /* Verbosity 0: no output */
    if (verbosity == 0) return;

    /* Verbosity 1: only "Step #" lines (skip sub-details) */
    if (verbosity == 1) {
        if (strncmp(step, "Step ", 5) != 0) return;
    }

    fprintf(stderr, "%s", step);
    if (details && details[0] != '\0') {
        fprintf(stderr, " - %s", details);
    }
    fprintf(stderr, "\n");
}

static void report_omp_info(void) {
    if (verbosity < 1) return;

    int max_threads = omp_get_max_threads();
    int num_procs = omp_get_num_procs();

    fprintf(stderr, "\n");
    fprintf(stderr, "================================================================================\n");
    fprintf(stderr, "  BNET Solver - Reflected Brownian Motion Stationary Distribution\n");
    fprintf(stderr, "  Using SuiteSparse CHOLMOD + OpenMP Parallelization\n");
    fprintf(stderr, "================================================================================\n");
    fprintf(stderr, "\n");

    if (verbosity >= 2) {
        fprintf(stderr, "[SYSTEM] OpenMP Configuration:\n");
        fprintf(stderr, "         Available processors: %d\n", num_procs);
        fprintf(stderr, "         Maximum threads:      %d\n", max_threads);
        fprintf(stderr, "         (Set OMP_NUM_THREADS environment variable to control thread count)\n");
        fprintf(stderr, "\n");
    }
}

static double get_time(void) {
    return omp_get_wtime();
}

#ifndef ANSI_C
int main(argc, argv)
     int argc;
     char *argv[];
#else
int main(int argc, char *argv[])
#endif
{
    int print = FALSE;
    int old_fash = FALSE;
    int bnet_solver = FALSE;
    int iterative = FALSE;
    int use_lu = FALSE;
    double regularization_epsilon = 0.0;  /* 0 means no regularization */
    double t_start, t_end, t_total_start;
    char details[256];

    /* ===== STEP 1: Parse command line options ===== */
    /* Parse options FIRST so verbosity is set before any output */
    FILE **fp = option(argc, argv, &print, &old_fash, &iterative, &bnet_solver,
                       &use_lu, &regularization_epsilon);
    FILE *input_fp = fp[0];
    FILE *output_fp = fp[1];

    /* In compact mode, suppress stdout output */
    if (compact_mode) {
        compact_suppress_stdout();
    }

    /* Report OpenMP configuration (only after verbosity is set) */
    report_omp_info();
    t_total_start = get_time();

    report_step("Step 1: Parsing command line options", NULL);

    /* ===== STEP 2: Read problem dimension ===== */
    t_start = get_time();
    report_step("Step 2: Reading problem parameters", NULL);
    int d = get_dimension(input_fp);

    /* ===== STEP 3: Read input matrices ===== */
    report_step("Step 3: Reading input data", NULL);

    if (verbosity >= 2)
        fprintf(stderr, "         Reading drift vector mu (%d elements)...\n", d);
    DVEC *mu = get_drift(d, input_fp);

    if (verbosity >= 2)
        fprintf(stderr, "         Reading covariance matrix Gamma (%d x %d)...\n", d, d);
    DMAT *Gamma = get_covariance(d, input_fp);

    if (verbosity >= 2)
        fprintf(stderr, "         Reading reflection matrix R (%d x %d)...\n", d, d);
    DMAT *R = get_reflection(d, input_fp);

    int n = try_get_degree(input_fp, d);

    /* Try to read optional customer class data after degree */
    {
        char keyword[64];
        if (fscanf(input_fp, "%63s", keyword) == 1
            && strcmp(keyword, "customer_classes") == 0) {
            int K, k, ii;
            if (fscanf(input_fp, "%d", &K) == 1 && K > 0 && K <= CC_MAX) {
                cc_num_classes = K;

                /* tau (workload-to-queue conversion) */
                for (ii = 0; ii < d && ii < CC_MAX; ii++)
                    fscanf(input_fp, "%lf", &cc_tau[ii]);

                /* alpha_total (total throughput per station) */
                for (ii = 0; ii < d && ii < CC_MAX; ii++)
                    fscanf(input_fp, "%lf", &cc_alpha_total[ii]);

                /* mueff (effective service rate per station) */
                for (ii = 0; ii < d && ii < CC_MAX; ii++)
                    fscanf(input_fp, "%lf", &cc_mueff[ii]);

                /* lambda_k (external arrival rate per class) */
                for (k = 0; k < K; k++)
                    fscanf(input_fp, "%lf", &cc_lambda[k]);

                /* alpha_ki (K rows x d cols) */
                for (k = 0; k < K; k++)
                    for (ii = 0; ii < d && ii < CC_MAX; ii++)
                        fscanf(input_fp, "%lf", &cc_alpha[k][ii]);

                /* mu_ki (K rows x d cols) */
                for (k = 0; k < K; k++)
                    for (ii = 0; ii < d && ii < CC_MAX; ii++)
                        fscanf(input_fp, "%lf", &cc_mu[k][ii]);
            }
        }
    }

    sprintf(details, "dimension d = %d, polynomial degree n = %d", d, n);
    report_step("         Problem size", details);
    t_end = get_time();
    sprintf(details, "completed in %.4f seconds", t_end - t_start);
    report_step("         Input data loaded", details);

    /* ===== STEP 4: Compute index arrays ===== */
    t_start = get_time();
    report_step("Step 4: Computing index arrays for polynomial basis", NULL);
    int **c = ComputeC(d, n);

    /* Sanity check the basis size BEFORE allocating index arrays or
       the (num_basis x num_basis) dense system matrix at line 326
       below. The basis grows combinatorially in (d, n) — e.g. d=20
       with n=8 gives C(28,8) = 3,108,105 polynomials, which would
       need ~76 TB for the dense matrix. The OS goes into swap thrash
       trying to satisfy something that big, which is what freezes
       the user's machine. Exit cleanly with a helpful message
       instead. The budget is RAM-aware (50% of physical memory by
       default, override via BNET_MAX_BYTES). */
    {
        uint64_t basis = (uint64_t) c[d][n];
        uint64_t dense_bytes = basis * basis * (uint64_t) sizeof(double);
        char hint[256];
        snprintf(hint, sizeof(hint),
            "reduce polynomial order (current n=%d) or dimension "
            "(current d=%d) — basis grows as C(d+n, n)", n, d);
        bnet_memcheck_alloc(dense_bytes, "spectral system matrix", hint);
    }

    int **I = ComputeIndex(c, d, n);
    int **Ib = ComputeIndex(c, d - 1, n);

    int num_basis = c[d][n] - 1;
    sprintf(details, "number of basis polynomials = %d", num_basis);
    report_step("         Index arrays computed", details);
    t_end = get_time();
    sprintf(details, "completed in %.4f seconds", t_end - t_start);
    report_step("         ", details);

    DVEC *mygamma = dvec_alloc(d);
    double **w;
    poly *Af, rn;
    double **_A;
    DMAT *A;
    DVEC *b;
    int i, j;

    if (print == TRUE)
        print_original_data(output_fp, Gamma, mu, R, n);

    /* ===== STEP 5: Scale the problem ===== */
    t_start = get_time();
    report_step("Step 5: Scaling problem for numerical stability", NULL);
    scaling(output_fp, Gamma, mu, R, mygamma);
    t_end = get_time();
    sprintf(details, "gamma_max = %.4f, completed in %.4f seconds", gmax, t_end - t_start);
    report_step("         Scaling complete", details);

    if (print == TRUE)
        print_converted_data(output_fp, Gamma, mu, R, mygamma);

    /* ===== STEP 6: Compute weights ===== */
    t_start = get_time();
    report_step("Step 6: Computing weight matrix for inner products", NULL);
    w = ComputeWeight(mygamma->data - 1, d, n); /* w[l][i] = i!/(2 gamma_l)^{i+1} */
    t_end = get_time();
    sprintf(details, "weight matrix size %d x %d, completed in %.4f seconds", d, 2*n+1, t_end - t_start);
    report_step("         Weights computed", details);

    /* ===== STEP 7: Build polynomial basis ===== */
    t_start = get_time();
    sprintf(details, "constructing %d basis polynomials using %d threads", num_basis, omp_get_max_threads());
    report_step("Step 7: Building polynomial basis (OpenMP parallel)", details);

    Af = (poly *)malloc((unsigned)(c[d][n] - 1) * sizeof(poly));
    if (!Af)
        Bneterror("Allocation Failure for Af in basis()");
    Af -= 2;

    /* Open the unified progress file. Total = basis + matrix = 2*num_basis;
     * each Basis() iteration and each coefficient() row will tick once.
     * If -P was not given, all calls are no-ops. */
    bnet_progress_open((long)(2 * num_basis));

    Basis(Af, Gamma, mu, R, c, I, n);
    t_end = get_time();
    sprintf(details, "completed in %.4f seconds", t_end - t_start);
    report_step("         Basis construction complete", details);

    /* ===== STEP 8: Assemble coefficient matrix and RHS vector ===== */
    t_start = get_time();
    sprintf(details, "matrix size %d x %d, using %d threads", num_basis, num_basis, omp_get_max_threads());
    report_step("Step 8: Assembling coefficient matrix A and vector b (OpenMP parallel)", details);

    A = dmat_alloc(c[d][n] - 1, c[d][n] - 1);
    b = dvec_alloc(c[d][n] - 1);

    coefficient(Af, A, b, c, I, Ib, w, n, Gamma, mu, R);
    /* Bar reaches 100% here. The downstream Cholesky/LU solve is
     * opaque (CHOLMOD internals); the Swift wrapper continues
     * animating a spinner appended to the full bar until the
     * binary exits, so the user knows the process is still alive. */
    bnet_progress_close();
    t_end = get_time();
    sprintf(details, "completed in %.4f seconds", t_end - t_start);
    report_step("         Matrix assembly complete", details);

    /* ===== STEP 9: Solve linear system ===== */
    t_start = get_time();

    /* Apply regularization if requested */
    if (regularization_epsilon > 0.0) {
        report_step("Step 9a: Applying regularization to ensure positive definiteness", NULL);
        apply_regularization(A, regularization_epsilon);
    }

    if (use_lu) {
        /* Use dense LU factorization (LAPACK) - works for any square matrix */
        report_step("Step 9: Solving linear system using LAPACK dense LU factorization", NULL);
        if (verbosity >= 2)
            fprintf(stderr, "         System size: %d x %d (general matrix)\n", num_basis, num_basis);
        dense_lu_solve(A, b, b);
    } else if (bnet_solver == FALSE) {
        report_step("Step 9: Solving linear system using CHOLMOD Cholesky factorization", NULL);
        if (verbosity >= 2)
            fprintf(stderr, "         System size: %d x %d (symmetric positive definite)\n", num_basis, num_basis);
        /* Initialize global CHOLMOD */
        init_global_cholmod();
        /* Solve using CHOLMOD */
        int chol_status = chol_solve(A, b, b, &g_cholmod_common);
        if (chol_status != 0) {
            if (chol_status == 1) {
                /* Matrix is not positive definite */
                fprintf(stderr, "\n");
                fprintf(stderr, "================================================================================\n");
                fprintf(stderr, "  ERROR: Matrix is not positive definite - Cholesky factorization failed.\n");
                fprintf(stderr, "\n");
                fprintf(stderr, "  This can happen with certain problem configurations or larger dimensions.\n");
                fprintf(stderr, "  Try running again with one of these options:\n");
                fprintf(stderr, "\n");
                fprintf(stderr, "    -l          Use LU factorization instead of Cholesky\n");
                fprintf(stderr, "                (works for non-positive-definite matrices)\n");
                fprintf(stderr, "\n");
                fprintf(stderr, "    -r epsilon  Apply regularization (add epsilon to diagonal)\n");
                fprintf(stderr, "                (helps ensure positive definiteness)\n");
                fprintf(stderr, "\n");
                fprintf(stderr, "  Example: ./bnet -l < input_file\n");
                fprintf(stderr, "           ./bnet -r 0.001 < input_file\n");
                fprintf(stderr, "           ./bnet -r 0.01 < input_file   (larger epsilon if needed)\n");
                fprintf(stderr, "================================================================================\n");
                fprintf(stderr, "\n");
            } else {
                fprintf(stderr, "Error: CHOLMOD solver failed with status %d\n", chol_status);
            }
            finish_global_cholmod();
            exit(1);
        }
    } else {
        report_step("Step 9: Solving linear system using BNET built-in Cholesky solver", NULL);
        if (verbosity >= 2)
            fprintf(stderr, "         System size: %d x %d\n", num_basis, num_basis);
        _A = dmatrix(1, c[d][n] - 1, 1, c[d][n] - 1);
        for (i = 1; i <= c[d][n] - 1; i++) {
            for (j = 1; j <= i; j++)
                _A[i][j] = MAT_AT(A, i - 1, j - 1); /* lower triangular part only */
        }
        gaxpy_cholesky(_A, c[d][n] - 1);
        fwsub(_A, b->data - 1, c[d][n] - 1);
        bksub(_A, b->data - 1, c[d][n] - 1);
        free_dmatrix(_A, 1, d, 1, d);
    }
    t_end = get_time();
    sprintf(details, "completed in %.4f seconds", t_end - t_start);
    report_step("         Linear solve complete", details);

    /* ===== STEP 10: Compute density function ===== */
    t_start = get_time();
    report_step("Step 10: Computing stationary density from polynomial coefficients", NULL);
    Density1(Af, b, &rn, c, I, Ib, w, d, n);
    dvec_free(b);
    t_end = get_time();
    sprintf(details, "completed in %.4f seconds", t_end - t_start);
    report_step("          Density computation complete", details);

    /* ===== STEP 11: Compute and output mean values ===== */
    t_start = get_time();
    report_step("Step 11: Computing mean position of reflected Brownian motion", NULL);
    Output(output_fp, &rn, Gamma, c, I, Ib, w, d, n);
    t_end = get_time();

    /* ===== Summary ===== */
    double t_total = get_time() - t_total_start;
    if (verbosity >= 2) {
        fprintf(stderr, "\n");
        fprintf(stderr, "================================================================================\n");
        fprintf(stderr, "  Computation complete!\n");
        fprintf(stderr, "  Total execution time: %.4f seconds\n", t_total);
        fprintf(stderr, "  Threads used: %d\n", omp_get_max_threads());
        fprintf(stderr, "================================================================================\n");
        fprintf(stderr, "\n");
    }

    /* ── Convert workload means to queue lengths if class data available ── */
    double eq[CC_MAX];     /* E[Q_i] = mean number at station i */
    double ew_sta[CC_MAX]; /* E[W_i] = mean wait at station i   */
    int has_cc = (cc_num_classes > 0);

    for (int l = 0; l < bnet_ndim; l++) {
        if (has_cc && cc_tau[l] > 1e-15) {
            eq[l] = bnet_means[l] / cc_tau[l];
            if (eq[l] < 0) eq[l] = 0;  /* clamp heavy-traffic artifact */
            if (cc_alpha_total[l] > 1e-15) {
                ew_sta[l] = eq[l] / cc_alpha_total[l] - 1.0 / cc_mueff[l];
                if (ew_sta[l] < 0) ew_sta[l] = 0;
            } else {
                ew_sta[l] = 0;
            }
        } else {
            eq[l] = bnet_means[l];  /* raw workload if no class data */
            ew_sta[l] = 0;
        }
    }

    /* ── Compute per-class statistics ──────────────────────────────── */
    double ew_total[CC_MAX], et_total[CC_MAX], en_total[CC_MAX];
    if (has_cc) {
        for (int k = 0; k < cc_num_classes; k++) {
            ew_total[k] = 0.0;
            et_total[k] = 0.0;
            if (cc_lambda[k] < 1e-15) { en_total[k] = 0; continue; }
            for (int l = 0; l < bnet_ndim; l++) {
                double visit_ratio = cc_alpha[k][l] / cc_lambda[k];
                ew_total[k] += visit_ratio * ew_sta[l];
                et_total[k] += visit_ratio * (ew_sta[l] + 1.0 / cc_mu[k][l]);
            }
            en_total[k] = cc_lambda[k] * et_total[k];
        }
    }

    /* Restore stdout if compact mode was active */
    if (compact_mode) {
        compact_restore_stdout();
        printf("Spectral Method (BNAsm)\n");
        printf("=================\n");
    }

    /* ── Network totals ─────────────────────────────────────────── */
    if (!compact_mode && has_cc) {
        double total_lambda0 = 0.0, total_EN = 0.0;
        for (int k = 0; k < cc_num_classes; k++)
            total_lambda0 += cc_lambda[k];
        for (int l = 0; l < bnet_ndim; l++)
            total_EN += eq[l];
        printf("\nNetwork Totals:\n");
        printf("  External arrival rate: %f\n", total_lambda0);
        printf("  Total E[N]: %f\n", total_EN);
        if (total_lambda0 > 1e-15)
            printf("  Mean sojourn time E[T]: %f\n", total_EN / total_lambda0);
    }

    /* ── Print per-class stats (full output) ──────────────────────── */
    if (!compact_mode && has_cc) {
        printf("\nCUSTOMER CLASS STATISTICS\n");
        printf("=========================\n");
        for (int k = 0; k < cc_num_classes; k++) {
            printf("\nClass %d:\n", k + 1);
            printf("  Mean queue time (total):   %f\n", ew_total[k]);
            printf("  Mean sojourn time (total): %f\n", et_total[k]);
            printf("  Mean number in system:     %f\n", en_total[k]);
        }
    }

    /* ── Compact per-class stats ──────────────────────────────────── */
    if (compact_mode && has_cc) {
        for (int k = 0; k < cc_num_classes; k++)
            printf("W_total(class %d) = %f\n", k + 1, ew_total[k]);
        for (int k = 0; k < cc_num_classes; k++)
            printf("T_total(class %d) = %f\n", k + 1, et_total[k]);
        printf("\n");

        for (int l = 0; l < bnet_ndim; l++)
            printf("rho_%d = %.6f\n", l + 1, cc_alpha_total[l] * cc_tau[l]);
        printf("\n");

        /* Per-station throughput (effective arrival rate) and sojourn
         * time. Throughput = cc_alpha_total (already computed from the
         * traffic equations); sojourn = E[Q_l] / throughput by Little's
         * Law. Emitted in the same Gamma_k / sojourn_k format the
         * finite-LP and finite-FE solvers use, so the comparison-table
         * AWK parser picks them up uniformly. */
        for (int l = 0; l < bnet_ndim; l++)
            printf("Gamma_%d = %.6f\n", l + 1, cc_alpha_total[l]);
        printf("\n");

        for (int l = 0; l < bnet_ndim; l++) {
            double soj = (cc_alpha_total[l] > 1e-12)
                ? eq[l] / cc_alpha_total[l] : 0.0;
            printf("sojourn_%d = %.6f\n", l + 1, soj);
        }
        printf("\n");

        for (int k = 0; k < cc_num_classes; k++)
            printf("X(class %d) = %.6f\n", k + 1, cc_lambda[k]);
        printf("\n");
    }

    /* ── Per-station mean number: always printed last ─────────────── */
    printf("\n");
    {
        int w = 1;
        for (int t = bnet_ndim; t >= 10; t /= 10) w++;
        for (int l = 0; l < bnet_ndim; l++) {
            printf("E[Q_%0*d] = %.6f\n", w, l + 1, eq[l]);
        }
    }
    printf("\n");

    /* Cleanup */
    finish_global_cholmod();

    return 0;
}

#ifndef ANSI_C
void Basis(Af, Gamma, mu, R, c, I, n)
     poly *Af;
     int **c, **I, n;
     DMAT *Gamma;
     DVEC *mu;
     DMAT *R;
#else
void Basis(poly *Af,
           DMAT *Gamma,
           DVEC *mu,
           DMAT *R,
           int **c,
           int **I,
           int n)
#endif
{
    int i, j, l, k, N;
    int d = Gamma->n;

    N = c[d][n];

    /* OpenMP parallelization of main loop - each iteration is independent */
    #pragma omp parallel
    {
        #pragma omp single
        {
            if (verbosity >= 2)
                fprintf(stderr, "         [Basis] Parallel region: using %d of %d available threads\n",
                        omp_get_num_threads(), omp_get_max_threads());
        }
    }

    #pragma omp parallel for schedule(dynamic) private(j, l, k)
    for (i = 2; i <= N; i++) {
        int *II = ivector(0, d);
        int *IIb = ivector(0, d - 1);

        initpoly(Af + i, I[i][0] - 1, c, d);

        /* Copy index values */
        for (j = 0; j <= d; j++)
            II[j] = I[i][j];

        /* Fill interior polynomial */
        for (j = 1; j <= d; j++) {
            if (II[j] >= 1) {
                II[0]--;
                II[j]--;
                Af[i].itr[Index(d, II, c)] = I[i][j] * VEC_AT(mu, j - 1);
                if (II[j] >= 1) {
                    II[0]--;
                    II[j]--;
                    Af[i].itr[Index(d, II, c)] = I[i][j] * (I[i][j] - 1) / 2;
                    II[0]++;
                    II[j]++;
                }
                II[0]++;
                II[j]++;
            }
        }

        for (j = 1; j <= d; j++)
            for (l = j + 1; l <= d; l++)
                if (II[j] >= 1 && II[l] >= 1) {
                    II[0] -= 2;
                    II[j]--;
                    II[l]--;
                    Af[i].itr[Index(d, II, c)] = I[i][j] * I[i][l] * MAT_AT(Gamma, j - 1, l - 1);
                    II[0] += 2;
                    II[j]++;
                    II[l]++;
                }

        /* Fill boundary polynomials */
        for (j = 1; j <= d; j++) {
            if (II[j] == 1) {
                IIb[0] = II[0] - 1;
                for (l = 1; l < j; l++)
                    IIb[l] = II[l];
                for (l = j; l < d; l++)
                    IIb[l] = II[l + 1];
                Af[i].bd[j][Index(d - 1, IIb, c)] = MAT_AT(R, j - 1, j - 1);
            }
            if (II[j] == 0) {
                for (l = 1; l <= d; l++)
                    if (II[l] >= 1) {
                        II[l]--;
                        for (k = 0; k < j; k++)
                            IIb[k] = II[k];
                        for (k = j; k < d; k++)
                            IIb[k] = II[k + 1];
                        IIb[0]--;
                        II[l]++;
                        Af[i].bd[j][Index(d - 1, IIb, c)] = II[l] * MAT_AT(R, l - 1, j - 1);
                    }
            }
        }

        free((char *)(II));
        free((char *)(IIb));
        bnet_progress_tick();
    }
}

void initpoly(f, k, c, d)
     poly *f;
     int k;
     int **c, d;
{
    f->itr = cvector(1, c[d][k]);
    f->bd = cmatrix(1, d, 1, c[d - 1][k]);
}

void Density1(Af, b, rn, c, I, Ib, w, d, n)
     poly *Af, *rn;
     DVEC *b;
     int **c, **I, **Ib;
     real **w;
     int d, n;
{
    int i, j, l, k, N;
    poly phi_0;
    real tmp;

    if (verbosity >= 2)
        fprintf(stderr, "          [Density] Initializing polynomial representation...\n");

    /* Initialize */
    initpoly(rn, n - 1, c, d);
    initpoly(&phi_0, 0, c, d);
    phi_0.itr[1] = 1.0;
    rn->itr[1] = 1.0;
    for (l = 1; l <= d; l++) {
        rn->bd[l][1] = 1.0;
    }

    N = c[d][n];
    if (verbosity >= 2)
        fprintf(stderr, "          [Density] Combining %d polynomial terms...\n", N - 1);
    for (k = 2; k <= N; k++) {
        half_linear(rn, n - 1, -VEC_AT(b, k - 2), Af + k, I[k][0] - 1, rn, c, d);
    }

    /* Normalize */
    if (verbosity >= 2)
        fprintf(stderr, "          [Density] Normalizing to unit integral...\n");
    tmp = inner(&phi_0, 0, rn, n - 1, c, I, Ib, w, d);
    if (tmp == 0.0)
        Bneterror(" can not be normalized into a density");
    tmp = 1 / tmp;

    N = c[d][n - 1];

    /* Parallelized normalization */
    #pragma omp parallel for
    for (i = 1; i <= N; i++)
        rn->itr[i] *= tmp;

    N = c[d - 1][n - 1];
    #pragma omp parallel for collapse(2)
    for (j = 1; j <= d; j++)
        for (i = 1; i <= N; i++)
            rn->bd[j][i] *= tmp;

    if (verbosity >= 2)
        fprintf(stderr, "          [Density] Normalization complete.\n");
}

void Density2(Af, rn, c, I, Ib, w, d, n)
     poly *Af, *rn;
     int **c, **I, **Ib;
     real **w;
     int d, n;
{
    int i, j, l, k, N;
    poly phi_0;
    real tmp;

    /* Initialize */
    initpoly(rn, n - 1, c, d);
    initpoly(&phi_0, 0, c, d);
    phi_0.itr[1] = 1.0;
    rn->itr[1] = 1.0;
    for (l = 1; l <= d; l++) {
        rn->bd[l][1] = 1.0;
        phi_0.bd[l][1] = 1.0;
    }

    N = c[d][n];
    for (k = 2; k <= N; k++) {
        tmp = inner(Af + k, I[k][0] - 1, Af + k, I[k][0] - 1, c, I, Ib, w, d);
        if (tmp == 0.0)
            Bneterror(" Can not be normalized when finding density");
        tmp = -inner(&phi_0, 0, Af + k, I[k][0] - 1, c, I, Ib, w, d) / tmp;
        half_linear(rn, n - 1, tmp, Af + k, I[k][0] - 1, rn, c, d);
    }

    /* Normalize */
    for (l = 1; l <= d; l++)
        phi_0.bd[l][1] = 0.0;
    tmp = inner(&phi_0, 0, rn, n - 1, c, I, Ib, w, d);
    if (tmp == 0.0)
        Bneterror(" can not be normalized into a density");
    tmp = 1 / tmp;

    N = c[d][n - 1];
    #pragma omp parallel for
    for (i = 1; i <= N; i++)
        rn->itr[i] *= tmp;

    N = c[d - 1][n - 1];
    #pragma omp parallel for collapse(2)
    for (j = 1; j <= d; j++)
        for (i = 1; i <= N; i++)
            rn->bd[j][i] *= tmp;
}

void orthogonalize(Af, c, I, Ib, w, d, n)
     poly *Af;
     int **c, **I, **Ib;
     real **w;
     int d, n;
{
    int t, i, N;
    real tmp;

    N = c[d][n];
    for (t = 3; t <= N; t++)
        for (i = 2; i < t; i++) {
            tmp = inner(Af + i, I[i][0] - 1, Af + i, I[i][0] - 1, c, I, Ib, w, d);
            if (tmp == 0.0)
                Bneterror(" Can not orthogonalize, divisor zero ");
            tmp = -inner(Af + t, I[t][0] - 1, Af + i, I[i][0] - 1, c, I, Ib, w, d) / tmp;
            half_linear(Af + t, I[t][0] - 1, tmp, Af + i, I[i][0] - 1, Af + t, c, d);
        }
}

void coefficient(Af, A, b, c, I, Ib, w, n, Gamma, mu, R)
     poly *Af;
     DMAT *A;
     DVEC *b;
     int **c, **I, **Ib;
     real **w;
     int n;
     DMAT *Gamma;
     DVEC *mu;
     DMAT *R;
{
    int t, i, N;
    int d = Gamma->n;
    poly psi_1;

    N = c[d][n];

    /* OpenMP parallelization of matrix assembly */
    #pragma omp parallel
    {
        #pragma omp single
        {
            if (verbosity >= 2) {
                fprintf(stderr, "         [Matrix A] Parallel region: using %d threads\n",
                        omp_get_num_threads());
                fprintf(stderr, "         [Matrix A] Computing %d matrix rows...\n", N - 1);
            }
        }

        int *K = ivector(1, d);

        #pragma omp for schedule(dynamic)
        for (t = 2; t <= N; t++) {
            for (i = 2; i <= t; i++) {
                MAT_AT(A, t - 2, i - 2) = inner_2(I[t], I[i], K, w, Gamma, mu, R, d);
            }
            bnet_progress_tick();
        }

        free((char *)(K + 1));
    }

    initpoly(&psi_1, 0, c, d);
    psi_1.itr[1] = 1.0;
    for (i = 1; i <= d; i++)
        psi_1.bd[i][1] = 1.0;

    if (verbosity >= 2)
        fprintf(stderr, "         [Vector b] Computing %d vector elements...\n", N - 1);

    /* OpenMP parallelization of vector assembly */
    #pragma omp parallel for
    for (t = 2; t <= N; t++)
        VEC_AT(b, t - 2) = inner(Af + t, I[t][0] - 1, &psi_1, 0, c, I, Ib, w, d);
}

real inner(f, t, g, m, c, I, Ib, w, d)
     poly *f, *g;
     int t, m;
     int **c, **I, **Ib;
     real **w;
     int d;
{
    int i, j, l, k, tt, mm = c[d][m];
    real tmp = 0.0;
    real prod;
    real *fp, *gp;

    /* Interior polynomial inner product */
    /* Note: OpenMP reduction for tmp accumulator */
    #pragma omp parallel for collapse(2) reduction(+:tmp) private(l, prod, fp, gp)
    for (i = 1; i <= c[d][t]; i++) {
        for (j = 1; j <= mm; j++) {
            prod = 1.0;
            for (l = d; l >= 1; l--)
                prod *= w[l][I[i][l] + I[j][l]];
            tmp += f->itr[i] * g->itr[j] * prod;
        }
    }

    tt = c[d - 1][t];
    mm = c[d - 1][m];

    /* Boundary polynomial inner product */
    real tmp2 = 0.0;
    #pragma omp parallel for collapse(2) reduction(+:tmp2) private(i, j, l, prod, fp, gp)
    for (k = 1; k <= d; k++) {
        for (i = 1; i <= tt; i++) {
            for (j = 1; j <= mm; j++) {
                prod = 1.0;
                for (l = k - 1; l >= 1; l--)
                    prod *= w[l][Ib[i][l] + Ib[j][l]];
                for (l = k; l < d; l++)
                    prod *= w[l + 1][Ib[i][l] + Ib[j][l]];
                tmp2 += 0.5 * f->bd[k][i] * g->bd[k][j] * prod;
            }
        }
    }
    tmp += tmp2;

    return (tmp);
}

void half_linear(f, t, a, g, m, h, c, d)
     int t, m;
     poly *f, *g, *h;
     real a;
     int **c;
     int d;
{
    int i = c[d][m], j, mm = c[d - 1][m];
    real *hp = h->itr + i, *fp = f->itr + i, *gp = g->itr + i;

    if (t < m)
        Bneterror(" the degree of first poly should be bigger ");
    while (i--)
        *hp-- = *fp-- + a * (*gp--);

    for (j = d; j >= 1; j--) {
        i = mm;
        hp = h->bd[j] + i;
        fp = f->bd[j] + i;
        gp = g->bd[j] + i;
        while (i--)
            *hp-- = *fp-- + a * (*gp--);
    }
}

real inner_2(I, J, K, w, Gamma, mu, R, d)
     int *I, *J, *K, d;
     real **w;
     DMAT *Gamma;
     DVEC *mu;
     DMAT *R;
{
    int i, l, j, k, m;
    real sum = 0.0, prod;

    for (m = d; m >= 1; m--)
        K[m] = I[m] + J[m];

    for (i = d; i >= 1; i--)
        for (j = d; j >= 1; j--)
            if (I[i] >= 1 && J[j] >= 1) {

                K[i]--;
                K[j]--;
                prod = 1.0;
                for (m = d; m >= 1; m--)
                    prod *= w[m][K[m]];
                sum += I[i] * VEC_AT(mu, i - 1) * J[j] * VEC_AT(mu, j - 1) * prod;
                K[i]++;
                K[j]++;

                if (J[j] >= 2) {
                    K[i]--;
                    K[j] -= 2;
                    prod = 1.0;
                    for (m = d; m >= 1; m--)
                        prod *= w[m][K[m]];
                    sum += I[i] * VEC_AT(mu, i - 1) * 0.5 * J[j] * (J[j] - 1) * prod;
                    K[i]++;
                    K[j] += 2;
                }

                for (k = j + 1; k <= d; k++)
                    if (J[k] >= 1) {
                        K[i]--;
                        K[j]--;
                        K[k]--;
                        prod = 1.0;
                        for (m = d; m >= 1; m--)
                            prod *= w[m][K[m]];
                        sum += I[i] * VEC_AT(mu, i - 1) * J[j] * J[k] * MAT_AT(Gamma, j - 1, k - 1) * prod;
                        K[i]++;
                        K[j]++;
                        K[k]++;
                    }

                if (I[i] >= 2) {
                    K[i] -= 2;
                    K[j]--;
                    prod = 1.0;
                    for (m = d; m >= 1; m--)
                        prod *= w[m][K[m]];
                    sum += 0.5 * I[i] * (I[i] - 1) * J[j] * VEC_AT(mu, j - 1) * prod;
                    K[i] += 2;
                    K[j]++;

                    if (J[j] >= 2) {
                        K[i] -= 2;
                        K[j] -= 2;
                        prod = 1.0;
                        for (m = d; m >= 1; m--)
                            prod *= w[m][K[m]];
                        sum += 0.5 * I[i] * (I[i] - 1) * 0.5 * J[j] * (J[j] - 1) * prod;
                        K[i] += 2;
                        K[j] += 2;
                    }

                    for (k = j + 1; k <= d; k++)
                        if (J[k] >= 1) {
                            K[i] -= 2;
                            K[j]--;
                            K[k]--;
                            prod = 1.0;
                            for (m = d; m >= 1; m--)
                                prod *= w[m][K[m]];
                            sum += 0.5 * I[i] * (I[i] - 1) * J[j] * J[k] * MAT_AT(Gamma, j - 1, k - 1) * prod;
                            K[i] += 2;
                            K[j]++;
                            K[k]++;
                        }
                }

                for (l = i + 1; l <= d; l++)
                    if (I[l] >= 1) {
                        K[i]--;
                        K[l]--;
                        K[j]--;
                        prod = 1.0;
                        for (m = d; m >= 1; m--)
                            prod *= w[m][K[m]];
                        sum += I[i] * I[l] * MAT_AT(Gamma, i - 1, l - 1) * J[j] * VEC_AT(mu, j - 1) * prod;
                        K[i]++;
                        K[l]++;
                        K[j]++;

                        if (J[j] >= 2) {
                            K[i]--;
                            K[l]--;
                            K[j] -= 2;
                            prod = 1.0;
                            for (m = d; m >= 1; m--)
                                prod *= w[m][K[m]];
                            sum += I[i] * I[l] * MAT_AT(Gamma, i - 1, l - 1) * 0.5 * J[j] * (J[j] - 1) * prod;
                            K[i]++;
                            K[l]++;
                            K[j] += 2;
                        }

                        for (k = j + 1; k <= d; k++)
                            if (J[k] >= 1) {
                                K[i]--;
                                K[l]--;
                                K[j]--;
                                K[k]--;
                                prod = 1.0;
                                for (m = d; m >= 1; m--)
                                    prod *= w[m][K[m]];
                                sum += I[i] * I[l] * MAT_AT(Gamma, i - 1, l - 1) * J[j] * J[k] * MAT_AT(Gamma, j - 1, k - 1) * prod;
                                K[i]++;
                                K[l]++;
                                K[j]++;
                                K[k]++;
                            }
                    }
            }

    /* Boundary part */
    for (l = d; l >= 1; l--) {
        if (I[l] == 1) {
            if (J[l] == 1) {
                for (m = d, prod = 1.0; m >= 1; m--)
                    prod *= w[m][K[m]];
                prod /= w[l][K[l]];
                sum += 0.5 * MAT_AT(R, l - 1, l - 1) * MAT_AT(R, l - 1, l - 1) * prod;
            } else if (J[l] == 0)
                for (j = d; j >= 1; j--)
                    if (J[j] >= 1) {
                        K[j]--;
                        for (m = d, prod = 1.0; m >= 1; m--)
                            prod *= w[m][K[m]];
                        prod /= w[l][K[l]];
                        sum += 0.5 * MAT_AT(R, l - 1, l - 1) * J[j] * MAT_AT(R, j - 1, l - 1) * prod;
                        K[j]++;
                    }
        } else if (I[l] == 0) {
            if (J[l] == 1) {
                for (i = d; i >= 1; i--)
                    if (I[i] >= 1) {
                        K[i]--;
                        for (m = d, prod = 1.0; m >= 1; m--)
                            prod *= w[m][K[m]];
                        prod /= w[l][K[l]];
                        sum += 0.5 * I[i] * MAT_AT(R, i - 1, l - 1) * MAT_AT(R, l - 1, l - 1) * prod;
                        K[i]++;
                    }
            } else if (J[l] == 0) {
                for (i = d; i >= 1; i--)
                    if (I[i] >= 1)
                        for (j = d; j >= 1; j--)
                            if (J[j] >= 1) {
                                K[i]--;
                                K[j]--;
                                for (m = d, prod = 1.0; m >= 1; m--)
                                    prod *= w[m][K[m]];
                                prod /= w[l][K[l]];
                                sum += 0.5 * I[i] * MAT_AT(R, i - 1, l - 1) * J[j] * MAT_AT(R, j - 1, l - 1) * prod;
                                K[i]++;
                                K[j]++;
                            }
            }
        }
    }
    return (sum);
}

#ifndef ANSI_C
int get_dimension(input_fp)
     FILE *input_fp;
#else
int get_dimension(FILE *input_fp)
#endif
{
    int d;
    if (fscanf(input_fp, "%d", &d) != 1)
        Bneterror("d should be a positive integer");
    return d;
}

#ifndef ANSI_C
int get_degree(input_fp)
     FILE *input_fp;
#else
int get_degree(FILE *input_fp)
#endif
{
    int n;

    if (fscanf(input_fp, "%d", &n) != 1)
        Bneterror("n should be a positive integer");
    return n;
}

#ifndef ANSI_C
int try_get_degree(input_fp, d)
     FILE *input_fp;
     int d;
#else
int try_get_degree(FILE *input_fp, int d)
#endif
{
    int n;
    int def = (d <= 3) ? 5 : (d <= 10) ? 4 : 3;

    if (fscanf(input_fp, "%d", &n) == 1)
        return n;

    /* Not found in file - prompt user */
    char buf[256];
    fprintf(stderr, "  Polynomial degree [%d]: ", def);
    if (!fgets(buf, sizeof(buf), stdin) || buf[0] == '\n')
        return def;
    n = atoi(buf);
    return (n > 0) ? n : def;
}

void Bneterror(text)
     char *text;
{
    /* Fatal errors must return non-zero so wrapper scripts (Run
     * Comparison, test.sh, SBD's popen recovery) can detect failure.
     * Pre-fix: exit(0) made every fatal error look like success. */
    (void)fprintf(stderr, "Fatal error occured ......\n");
    (void)fprintf(stderr, "%s\n", text);
    (void)fprintf(stderr, "Leaving system now ......\n");
    exit(2);
}

int **imatrix(nrl, nrh, ncl, nch)
     int nrl, nrh, ncl, nch;
{
    int i;
    int **m;

    m = (int **)malloc((unsigned)(nrh - nrl + 1) * sizeof(int *));
    if (!m)
        Bneterror("allocation failure 1 in imatrix()");
    m -= nrl;

    for (i = nrl; i <= nrh; i++) {
        m[i] = (int *)malloc((unsigned)(nch - ncl + 1) * sizeof(int));
        if (!m[i])
            Bneterror("allocation failure 2 in imatrix()");
        m[i] -= ncl;
    }
    return m;
}

int *ivector(nl, nh)
     int nl, nh;
{
    int *v;

    v = (int *)malloc((unsigned)(nh - nl + 1) * sizeof(int));
    if (!v)
        Bneterror("allocation failure in ivector()");
    return v - nl;
}

real *dvector(nl, nh)
     int nl, nh;
{
    real *v;

    v = (real *)malloc((unsigned)(nh - nl + 1) * sizeof(real));
    if (!v)
        Bneterror("allocation failure in dvector()");
    return v - nl;
}

real *cvector(nl, nh)
     int nl, nh;
{
    real *v;

    v = (real *)calloc((unsigned)(nh - nl + 1), sizeof(real));
    if (!v)
        Bneterror("allocation failure in cvector()");
    return v - nl;
}

void free_dmatrix(m, nrl, nrh, ncl)
     real **m;
     int nrl, nrh, ncl;
{
    int i;

    for (i = nrh; i >= nrl; i--)
        free((char *)(m[i] + ncl));
    free((char *)(m + nrl));
}

void free_dvector(v, nl, nh)
     double *v;
     int nl, nh;
{
    free((char *)(v + nl));
}

void gaxpy_cholesky(A, n)
     real **A;
     int n;
{
    int i, j, k;
    real tmp;
    real **Ai, **Aj;

    tmp = (real)sqrt((double)A[1][1]);
    for (i = n, Ai = A + n; i >= 1; i--, Ai--)
        (*Ai)[1] /= tmp;

    for (j = 2, Aj = A + 2; j <= n; j++, Aj++) {
        for (k = j - 1; k >= 1; k--)
            (*Aj)[j] -= (*Aj)[k] * (*Aj)[k];
        tmp = (real)sqrt((double)(*Aj)[j]);
        (*Aj)[j] /= tmp;
        for (i = j + 1, Ai = A + j + 1; i <= n; i++, Ai++) {
            for (k = j - 1; k >= 1; k--)
                (*Ai)[j] -= (*Ai)[k] * (*Aj)[k];
            (*Ai)[j] /= tmp;
        }
    }
}

/* Forward substitution for lower triangular system */
void fwsub(L, b, n)
     real **L;
     real *b;
     int n;
{
    int i, j;
    for (i = 1; i <= n; i++) {
        for (j = 1; j < i; j++)
            b[i] -= L[i][j] * b[j];
        b[i] /= L[i][i];
    }
}

/* Backward substitution for upper triangular system (L^T) */
void bksub(L, b, n)
     real **L;
     real *b;
     int n;
{
    int i, j;
    for (i = n; i >= 1; i--) {
        for (j = i + 1; j <= n; j++)
            b[i] -= L[j][i] * b[j];
        b[i] /= L[i][i];
    }
}

/* dmatrix and cmatrix for compatibility */
real **dmatrix(nrl, nrh, ncl, nch)
     int nrl, nrh, ncl, nch;
{
    int i;
    real **m;

    m = (real **)malloc((unsigned)(nrh - nrl + 1) * sizeof(real *));
    if (!m)
        Bneterror("allocation failure 1 in dmatrix()");
    m -= nrl;

    for (i = nrl; i <= nrh; i++) {
        m[i] = (real *)malloc((unsigned)(nch - ncl + 1) * sizeof(real));
        if (!m[i])
            Bneterror("allocation failure 2 in dmatrix()");
        m[i] -= ncl;
    }
    return m;
}

real **cmatrix(nrl, nrh, ncl, nch)
     int nrl, nrh, ncl, nch;
{
    int i;
    real **m;

    m = (real **)malloc((unsigned)(nrh - nrl + 1) * sizeof(real *));
    if (!m)
        Bneterror("allocation failure 1 in cmatrix()");
    m -= nrl;

    for (i = nrl; i <= nrh; i++) {
        m[i] = (real *)calloc((unsigned)(nch - ncl + 1), sizeof(real));
        if (!m[i])
            Bneterror("allocation failure 2 in cmatrix()");
        m[i] -= ncl;
    }
    return m;
}
