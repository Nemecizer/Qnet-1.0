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
 * Uses SuiteSparse/CXSparse for Cholesky factorization and matrix-vector
 * multiplication.
 *
 * Usage: rbm_mlmc <input_file> <gamma> <epsilon> [seed]
 *
 * Input file format (text):
 *   Line 1: d (dimension)
 *   Next line: mu_1 mu_2 ... mu_d
 *   Next d lines: Sigma (covariance matrix, row by row)
 *   Next d lines: R (reflection matrix, row by row)
 *   Lines starting with # are comments. Blank lines are skipped.
 *
 * Output: estimated E[Y_i(infinity)] for each dimension i.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <cs.h>

/* ========================================================================== */
/* Random number generation: Box-Muller with drand48                          */
/* ========================================================================== */

static int    g_has_spare = 0;
static double g_spare     = 0.0;

static double randn(void)
{
    if (g_has_spare) {
        g_has_spare = 0;
        return g_spare;
    }
    g_has_spare = 1;
    double u, v, s;
    do {
        u = 2.0 * drand48() - 1.0;
        v = 2.0 * drand48() - 1.0;
        s = u * u + v * v;
    } while (s >= 1.0 || s == 0.0);
    s = sqrt(-2.0 * log(s) / s);
    g_spare = v * s;
    return u * s;
}

/* ========================================================================== */
/* Input file parser                                                          */
/* ========================================================================== */

/* Read the next non-comment, non-blank line from f into buf. Returns 1 on
   success, 0 on EOF. */
static int next_line(FILE *f, char *buf, int bufsize)
{
    while (fgets(buf, bufsize, f)) {
        /* skip comments and blank lines */
        char *p = buf;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '#' || *p == '\n' || *p == '\r' || *p == '\0') continue;
        return 1;
    }
    return 0;
}

static void parse_input(const char *filename, int *d_out, double **mu_out,
                         double **Sigma_out, double **R_out)
{
    FILE *f = fopen(filename, "r");
    if (!f) { fprintf(stderr, "Cannot open %s\n", filename); exit(1); }

    char buf[65536];
    int d;

    /* dimension */
    if (!next_line(f, buf, sizeof(buf))) { fprintf(stderr, "Missing dimension\n"); exit(1); }
    d = atoi(buf);
    if (d <= 0) { fprintf(stderr, "Invalid dimension %d\n", d); exit(1); }

    double *mu    = (double *)calloc(d, sizeof(double));
    double *Sigma = (double *)calloc(d * d, sizeof(double));
    double *R     = (double *)calloc(d * d, sizeof(double));

    /* drift vector */
    if (!next_line(f, buf, sizeof(buf))) { fprintf(stderr, "Missing mu\n"); exit(1); }
    {
        char *p = buf;
        for (int i = 0; i < d; i++) {
            mu[i] = strtod(p, &p);
        }
    }

    /* covariance matrix */
    for (int i = 0; i < d; i++) {
        if (!next_line(f, buf, sizeof(buf))) {
            fprintf(stderr, "Missing Sigma row %d\n", i);
            exit(1);
        }
        char *p = buf;
        for (int j = 0; j < d; j++) {
            Sigma[i * d + j] = strtod(p, &p);
        }
    }

    /* reflection matrix */
    for (int i = 0; i < d; i++) {
        if (!next_line(f, buf, sizeof(buf))) {
            fprintf(stderr, "Missing R row %d\n", i);
            exit(1);
        }
        char *p = buf;
        for (int j = 0; j < d; j++) {
            R[i * d + j] = strtod(p, &p);
        }
    }

    fclose(f);
    *d_out     = d;
    *mu_out    = mu;
    *Sigma_out = Sigma;
    *R_out     = R;
}

/* ========================================================================== */
/* CXSparse Cholesky: compute L such that LL^T = Sigma                        */
/* ========================================================================== */

static cs_di *compute_cholesky_factor(int d, const double *Sigma)
{
    /* Build upper-triangular Sigma in CXSparse triplet format */
    cs_di *T = cs_di_spalloc(d, d, d * (d + 1) / 2, 1, 1);
    if (!T) { fprintf(stderr, "cs_di_spalloc failed\n"); exit(1); }

    for (int j = 0; j < d; j++) {
        for (int i = 0; i <= j; i++) {
            cs_di_entry(T, i, j, Sigma[i * d + j]);
        }
    }

    cs_di *A = cs_di_compress(T);
    cs_di_spfree(T);
    if (!A) { fprintf(stderr, "cs_di_compress failed\n"); exit(1); }

    /* Symbolic Cholesky (natural ordering, order=0) */
    cs_dis *S = cs_di_schol(0, A);
    if (!S) { fprintf(stderr, "cs_di_schol failed\n"); exit(1); }

    /* Numeric Cholesky */
    cs_din *N = cs_di_chol(A, S);
    if (!N) { fprintf(stderr, "cs_di_chol failed (Sigma not positive definite?)\n"); exit(1); }

    /* Extract L (make a copy since we'll free N) */
    cs_di *L = N->L;
    N->L = NULL;   /* prevent cs_di_nfree from freeing L */

    cs_di_nfree(N);
    cs_di_sfree(S);
    cs_di_spfree(A);

    return L;
}

/* ========================================================================== */
/* Dense Gaussian elimination with partial pivoting: solve A*x = b            */
/* A is n x n row-major, b is n-vector. Solution overwrites b.                */
/* A is MODIFIED in place.                                                    */
/* ========================================================================== */

static void dense_solve(int n, double *A, double *b)
{
    for (int k = 0; k < n; k++) {
        /* partial pivoting */
        int pivot = k;
        double maxval = fabs(A[k * n + k]);
        for (int i = k + 1; i < n; i++) {
            double v = fabs(A[i * n + k]);
            if (v > maxval) { maxval = v; pivot = i; }
        }
        if (pivot != k) {
            for (int j = k; j < n; j++) {
                double tmp = A[k * n + j];
                A[k * n + j] = A[pivot * n + j];
                A[pivot * n + j] = tmp;
            }
            double tmp = b[k]; b[k] = b[pivot]; b[pivot] = tmp;
        }
        /* eliminate */
        double diag = A[k * n + k];
        if (fabs(diag) < 1e-30) {
            fprintf(stderr, "Warning: near-singular matrix in LCP solve\n");
            continue;
        }
        for (int i = k + 1; i < n; i++) {
            double factor = A[i * n + k] / diag;
            for (int j = k + 1; j < n; j++) {
                A[i * n + j] -= factor * A[k * n + j];
            }
            b[i] -= factor * b[k];
        }
    }
    /* back substitution */
    for (int k = n - 1; k >= 0; k--) {
        for (int j = k + 1; j < n; j++) {
            b[k] -= A[k * n + j] * b[j];
        }
        b[k] /= A[k * n + k];
    }
}

/* ========================================================================== */
/* Skorokhod problem solver: Algorithm A.1 from the paper                     */
/*                                                                            */
/* Given R (d x d, dense row-major) and x (d-vector), compute y >= 0          */
/* such that y = x + R * L with L >= 0 and complementarity.                  */
/* ========================================================================== */

static void solve_lcp(int d, const double *R, const double *x, double *y,
                       /* workspace (pre-allocated): */
                       int *B_idx, double *R_BB, double *rhs, double *L_B)
{
    static const double e = 1e-8;

    /* y = x */
    memcpy(y, x, d * sizeof(double));

    for (int iter = 0; iter < 100; iter++) {
        /* check if all y_i >= -e */
        int neg_found = 0;
        for (int i = 0; i < d; i++) {
            if (y[i] < -e) { neg_found = 1; break; }
        }
        if (!neg_found) break;

        /* B = {i : y_i < e} */
        int nb = 0;
        for (int i = 0; i < d; i++) {
            if (y[i] < e) B_idx[nb++] = i;
        }
        if (nb == 0) break;

        /* Extract R_{B,B} and rhs = -x_B */
        for (int i = 0; i < nb; i++) {
            rhs[i] = -x[B_idx[i]];
            for (int j = 0; j < nb; j++) {
                R_BB[i * nb + j] = R[B_idx[i] * d + B_idx[j]];
            }
        }

        /* Solve R_{B,B} * L_B = -x_B */
        memcpy(L_B, rhs, nb * sizeof(double));
        dense_solve(nb, R_BB, L_B);

        /* y = x + R_{.,B} * L_B */
        memcpy(y, x, d * sizeof(double));
        for (int j = 0; j < nb; j++) {
            int col = B_idx[j];
            double lval = L_B[j];
            for (int i = 0; i < d; i++) {
                y[i] += R[i * d + col] * lval;
            }
        }
    }

    /* clamp small negatives to zero */
    for (int i = 0; i < d; i++) {
        if (y[i] < 0.0) y[i] = 0.0;
    }
}

/* ========================================================================== */
/* Draw level M from {0, 1, ..., L-1} with P(M=m) = K(gamma) * gamma^m       */
/* ========================================================================== */

static int draw_level(double gamma, int L)
{
    double U = drand48();
    double gammaL = pow(gamma, L);
    double val = 1.0 - U * (1.0 - gammaL);
    if (val <= 0.0) return L - 1;
    int m = (int)ceil(log(val) / log(gamma)) - 1;
    if (m < 0) m = 0;
    if (m >= L) m = L - 1;
    return m;
}

/* ========================================================================== */
/* Main MLMC simulation                                                       */
/* ========================================================================== */

int main(int argc, char *argv[])
{
    if (argc < 4) {
        fprintf(stderr, "Usage: %s <input_file> <gamma> <epsilon> [seed]\n", argv[0]);
        return 1;
    }

    const char *input_file = argv[1];
    double gamma   = atof(argv[2]);
    double epsilon = atof(argv[3]);
    long   seed    = (argc >= 5) ? atol(argv[4]) : (long)time(NULL);

    if (gamma <= 0.0 || gamma >= 1.0) {
        fprintf(stderr, "gamma must be in (0,1)\n");
        return 1;
    }
    if (epsilon <= 0.0) {
        fprintf(stderr, "epsilon must be > 0\n");
        return 1;
    }

    /* Check 1/gamma is close to an integer (needed for synchronous coupling) */
    int ratio = (int)round(1.0 / gamma);
    if (fabs(ratio * gamma - 1.0) > 1e-9) {
        fprintf(stderr, "1/gamma must be a positive integer (got 1/gamma = %g)\n", 1.0 / gamma);
        return 1;
    }

    srand48(seed);
    g_has_spare = 0;

    /* Parse input */
    int d;
    double *mu, *Sigma, *R_dense;
    parse_input(input_file, &d, &mu, &Sigma, &R_dense);

    /* Compute Cholesky factor L of Sigma using CXSparse */
    cs_di *L = compute_cholesky_factor(d, Sigma);

    /* Compute MLMC parameters (Section 4 of the paper) */
    double log_d   = log((double)d);
    double T       = log_d * log_d / 2.0;
    if (T < 5.0) T = 5.0;  /* paper formula is for large d; enforce minimum */
    int    Lev     = (int)ceil((log(log_d) + 2.0 * log(1.0 / epsilon) - 2.0)
                                / log(1.0 / gamma));
    if (Lev < 1) Lev = 1;
    double gammaL  = pow(gamma, Lev);
    double Kgamma  = (1.0 - gamma) / (1.0 - gammaL);
    int    N       = (int)ceil((1.0 / Kgamma) * pow(gamma, -Lev) * Lev);

    fprintf(stderr, "Dimension d   = %d\n", d);
    fprintf(stderr, "gamma         = %g\n", gamma);
    fprintf(stderr, "epsilon       = %g\n", epsilon);
    fprintf(stderr, "seed          = %ld\n", seed);
    fprintf(stderr, "T             = %.4f\n", T);
    fprintf(stderr, "L (levels)    = %d\n", Lev);
    fprintf(stderr, "N (samples)   = %d\n", N);
    fprintf(stderr, "ratio (1/gam) = %d\n", ratio);
    fprintf(stderr, "\n");

    /* Allocate workspace */
    double *Z_sum      = (double *)calloc(d, sizeof(double));  /* accumulator */
    double *Y_fine     = (double *)malloc(d * sizeof(double));
    double *Y_coarse   = (double *)malloc(d * sizeof(double));
    double *z_vec      = (double *)malloc(d * sizeof(double));
    double *Cz         = (double *)malloc(d * sizeof(double));
    double *dx_fine    = (double *)malloc(d * sizeof(double));
    double *dx_acc     = (double *)malloc(d * sizeof(double)); /* accum for coarse */
    double *x_uncon    = (double *)malloc(d * sizeof(double));
    double *y_lcp      = (double *)malloc(d * sizeof(double));
    /* LCP workspace */
    int    *B_idx      = (int *)malloc(d * sizeof(int));
    double *R_BB       = (double *)malloc(d * d * sizeof(double));
    double *lcp_rhs    = (double *)malloc(d * sizeof(double));
    double *L_B        = (double *)malloc(d * sizeof(double));

    long long total_gaussians = 0;   /* complexity counter */

    /* Main MLMC loop */
    for (int sample = 0; sample < N; sample++) {
        /* Progress reporting */
        if (N >= 100 && sample % (N / 20) == 0) {
            fprintf(stderr, "  Sample %d / %d (%.0f%%)\n", sample, N,
                    100.0 * sample / N);
        }

        /* Step 1: Draw level M */
        int M = draw_level(gamma, Lev);

        double h_fine   = pow(gamma, M + 1);
        double h_coarse = pow(gamma, M);
        double sqrt_hf  = sqrt(h_fine);

        /* Number of fine steps in [0, T] */
        int n_phase1 = (int)round(T / h_fine);
        /* Number of coarse steps in [T, (M+1)T], duration = M*T */
        int n_coarse = (M > 0) ? (int)round((double)M * T / h_coarse) : 0;

        /* Initialize paths from y_0 = 0 */
        memset(Y_fine,   0, d * sizeof(double));
        memset(Y_coarse, 0, d * sizeof(double));

        /* Phase 1: [0, T] -- fine path only */
        for (int step = 0; step < n_phase1; step++) {
            /* Generate z ~ N(0, I_d) */
            for (int j = 0; j < d; j++) z_vec[j] = randn();
            total_gaussians += d;

            /* Cz = L * z  (using CXSparse gaxpy: Cz += L * z_vec) */
            memset(Cz, 0, d * sizeof(double));
            cs_di_gaxpy(L, z_vec, Cz);

            /* dx = mu * h_fine + sqrt(h_fine) * Cz */
            for (int j = 0; j < d; j++)
                dx_fine[j] = mu[j] * h_fine + sqrt_hf * Cz[j];

            /* unconstrained update */
            for (int j = 0; j < d; j++)
                x_uncon[j] = Y_fine[j] + dx_fine[j];

            /* Skorokhod projection */
            solve_lcp(d, R_dense, x_uncon, y_lcp, B_idx, R_BB, lcp_rhs, L_B);
            memcpy(Y_fine, y_lcp, d * sizeof(double));
        }

        /* Phase 2: [T, (M+1)T] -- fine and coarse paths coupled */
        for (int cs_step = 0; cs_step < n_coarse; cs_step++) {
            /* Accumulate fine increments over one coarse step */
            memset(dx_acc, 0, d * sizeof(double));

            for (int sub = 0; sub < ratio; sub++) {
                /* Generate z ~ N(0, I_d) */
                for (int j = 0; j < d; j++) z_vec[j] = randn();
                total_gaussians += d;

                /* Cz = L * z */
                memset(Cz, 0, d * sizeof(double));
                cs_di_gaxpy(L, z_vec, Cz);

                /* dx_fine = mu * h_fine + sqrt(h_fine) * Cz */
                for (int j = 0; j < d; j++)
                    dx_fine[j] = mu[j] * h_fine + sqrt_hf * Cz[j];

                /* Update fine path */
                for (int j = 0; j < d; j++)
                    x_uncon[j] = Y_fine[j] + dx_fine[j];
                solve_lcp(d, R_dense, x_uncon, y_lcp, B_idx, R_BB, lcp_rhs, L_B);
                memcpy(Y_fine, y_lcp, d * sizeof(double));

                /* Accumulate for coarse step */
                for (int j = 0; j < d; j++)
                    dx_acc[j] += dx_fine[j];
            }

            /* Update coarse path with accumulated increment */
            for (int j = 0; j < d; j++)
                x_uncon[j] = Y_coarse[j] + dx_acc[j];
            solve_lcp(d, R_dense, x_uncon, y_lcp, B_idx, R_BB, lcp_rhs, L_B);
            memcpy(Y_coarse, y_lcp, d * sizeof(double));
        }

        /* Step 6: compute Z_i = (1/p(M)) * (f(Y_fine) - f(Y_coarse)) + f(y_0)
         *
         * p(M) = K(gamma) * gamma^M
         * f(y) = y  (component-wise, to get average workload per dimension)
         * y_0 = 0, so f(y_0) = 0
         */
        double pM = Kgamma * pow(gamma, M);
        for (int j = 0; j < d; j++) {
            Z_sum[j] += (Y_fine[j] - Y_coarse[j]) / pM;
        }
    }

    /* Compute final estimator: Z_bar = (1/N) * Z_sum */
    printf("# Dimension: %d\n", d);
    printf("# gamma=%.4f  epsilon=%.4f  T=%.4f  L=%d  N=%d  seed=%ld\n",
           gamma, epsilon, T, Lev, N, seed);
    printf("# Total Gaussian RVs generated: %lld\n", total_gaussians);
    printf("#\n");
    printf("# Component   E[Y_i(inf)]\n");
    for (int j = 0; j < d; j++) {
        printf("  %4d        %.6f\n", j + 1, Z_sum[j] / N);
    }

    /* Also print summary: average across all components */
    double avg = 0.0;
    for (int j = 0; j < d; j++) avg += Z_sum[j] / N;
    avg /= d;
    printf("#\n");
    printf("# Average across all components: %.6f\n", avg);
    printf("# Total complexity (Gaussian RVs): %lld\n", total_gaussians);

    /* Cleanup */
    cs_di_spfree(L);
    free(Z_sum);
    free(Y_fine);    free(Y_coarse);
    free(z_vec);     free(Cz);
    free(dx_fine);   free(dx_acc);
    free(x_uncon);   free(y_lcp);
    free(B_idx);     free(R_BB);
    free(lcp_rhs);   free(L_B);
    free(mu);        free(Sigma);
    free(R_dense);

    return 0;
}
