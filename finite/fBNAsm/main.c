/*
 * main.c - SRBM solver main program
 *
 * Implementation of Dai & Harrison (1991) SRBM algorithm
 *
 * Usage: srbm_solver <input_file>
 *
 * Outputs to stdout:
 *   q1 = E[X_1]
 *   q2 = E[X_2]
 *   ...
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifdef _OPENMP
#include <omp.h>
#endif

#include "srbm_types.h"
#include "srbm_solver.h"

/* External function from input_parser.c */
extern void print_params(const SRBMParams *params);

void print_usage(const char *prog_name) {
    fprintf(stderr, "SRBM Solver - Stationary Distribution of Reflected Brownian Motion\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "Usage: %s <input_file> [-v] [-g] [-L]\n", prog_name);
    fprintf(stderr, "\n");
    fprintf(stderr, "Options:\n");
    fprintf(stderr, "  -v    Verbose mode (print additional information to stderr)\n");
#ifdef USE_SUITESPARSE
    fprintf(stderr, "  -g    Use Gram-Schmidt solver instead of SuiteSparse (default)\n");
#else
    fprintf(stderr, "  -g    [No effect - SuiteSparse not compiled in, using Gram-Schmidt]\n");
#endif
    fprintf(stderr, "  -L    Use Legendre polynomial basis (better conditioning at high degree)\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "Input file format (positional, blank lines ignored):\n");
    fprintf(stderr, "  d                     # Number of dimensions\n");
    fprintf(stderr, "  mu_1 ... mu_d         # Drift vector\n");
    fprintf(stderr, "  Gamma (d x d)         # Covariance matrix rows\n");
    fprintf(stderr, "  R (d x 2d)            # Reflection matrix rows\n");
    fprintf(stderr, "  a_1 ... a_d           # Hypercube dimensions\n");
    fprintf(stderr, "  degree                # Polynomial degree (optional)\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "Output (stdout):\n");
    fprintf(stderr, "  q1 = E[X_1]\n");
    fprintf(stderr, "  q2 = E[X_2]\n");
    fprintf(stderr, "  ...\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "Reference: Dai & Harrison, Ann. Appl. Prob. 1(1), 1991, pp. 16-35\n");
}

/* Global flags (shared with srbm_solver.c) */
int g_compact = 0;
int g_gui_mode = 0;
int g_use_legendre = 0;

/* Progress file path (set by -P PATH; consumed by srbm_solver.c). */
extern char srbm_progress_path[1024];

int main(int argc, char *argv[]) {
    if (argc < 2) {
        print_usage(argv[0]);
        return 1;
    }

    /* Parse command line arguments */
    const char *input_file = NULL;
    int verbose = 0;
    int use_gramschmidt = 0;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-c") == 0) {
            g_compact = 1;
        } else if (strcmp(argv[i], "-G") == 0) {
            g_gui_mode = 1;
        } else if (strcmp(argv[i], "-v") == 0) {
            verbose = 1;
        } else if (strcmp(argv[i], "-g") == 0) {
            use_gramschmidt = 1;
        } else if (strcmp(argv[i], "-L") == 0) {
            g_use_legendre = 1;
        } else if (strcmp(argv[i], "-P") == 0 && i + 1 < argc) {
            strncpy(srbm_progress_path, argv[++i], sizeof(srbm_progress_path) - 1);
            srbm_progress_path[sizeof(srbm_progress_path) - 1] = '\0';
        } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            print_usage(argv[0]);
            return 0;
        } else if (argv[i][0] != '-') {
            input_file = argv[i];
        }
    }

    if (!input_file) {
        fprintf(stderr, "Error: No input file specified\n");
        print_usage(argv[0]);
        return 1;
    }

    /* Note: -g flag has no effect if SuiteSparse not compiled in */
#ifndef USE_SUITESPARSE
    (void)use_gramschmidt;  /* Suppress unused warning when SuiteSparse not available */
#endif

    /* Report OpenMP configuration */
    #ifdef _OPENMP
    if (verbose) {
        fprintf(stderr, "OpenMP enabled: %d threads available\n", omp_get_max_threads());
    }
    #else
    if (verbose) {
        fprintf(stderr, "OpenMP not enabled (single-threaded execution)\n");
    }
    #endif

    /* Parse input file */
    SRBMParams params;
    if (parse_input_file(input_file, &params) != 0) {
        return 1;
    }

    /* If degree was not in the input file, prompt the user */
    if (params.n_approx == 0) {
        fprintf(stderr, "Enter polynomial degree: ");
        fflush(stderr);
        if (scanf("%d", &params.n_approx) != 1 || params.n_approx <= 0) {
            fprintf(stderr, "Error: Invalid degree\n");
            return 1;
        }
    }

    if (verbose) {
        print_params(&params);
        if (g_use_legendre)
            fprintf(stderr, "Using Legendre polynomial basis\n");
    }

    /* Allocate result structure */
    SRBMResult result;
    memset(&result, 0, sizeof(SRBMResult));

    /* Time the solver */
    clock_t start_time = clock();

    /* Run solver */
    int status;
#ifdef USE_SUITESPARSE
    if (use_gramschmidt) {
        if (verbose) {
            fprintf(stderr, "Using Gram-Schmidt solver\n");
        }
        status = srbm_solve(&params, &result);
    } else {
        if (verbose) {
            fprintf(stderr, "Using SuiteSparse-optimized solver (default)\n");
        }
        status = srbm_solve_suitesparse(&params, &result);
    }
#else
    if (verbose) {
        fprintf(stderr, "Using Gram-Schmidt solver (SuiteSparse not compiled in)\n");
    }
    status = srbm_solve(&params, &result);
#endif

    clock_t end_time = clock();
    double elapsed = (double)(end_time - start_time) / CLOCKS_PER_SEC;

    if (status != 0) {
        fprintf(stderr, "Error: Solver failed\n");
        params_free(&params);
        result_free(&result);
        return 1;
    }

    if (verbose) {
        fprintf(stderr, "Computation time: %.3f seconds\n", elapsed);
        fprintf(stderr, "Basis dimension: %d\n", result.basis_dim);
        fprintf(stderr, "Normalization constant alpha: %.6f\n", result.alpha);
        fprintf(stderr, "\n");

        fprintf(stderr, "Boundary measures delta_i:\n");
        for (int face = 0; face < 2 * params.n_dim; face++) {
            int k = face / 2;
            const char *type = (face % 2 == 0) ? "lower" : "upper";
            fprintf(stderr, "  delta(x_%d=%s) = %.6f\n", k + 1, type, result.delta[face]);
        }
        fprintf(stderr, "\n");
    }

    if (g_gui_mode) {
        printf("Spectral Method\n");
        printf("==================\n\n");

        /* Compute per-station throughput.
         *
         * Γ_i = μ_eff_i − δ_lower_i is the spectral estimate of the
         * served rate. Two physical bounds:
         *   (a) capacity:    Γ_i ≤ μ_eff_i           (single-server)
         *   (b) conservation: Γ_i ≤ α_i = drift_i + capacity_i
         * Bound (b) is the tighter one in stable systems and catches
         * "throughput exceeds offered load" — a steady-state mass
         * conservation violation that the SRBM solver doesn't enforce
         * directly and that produces ρ > 0.95 reports at modestly-
         * loaded upstream stations of saturated tandems. Clip to both. */
        double gamma_sta[MAX_DIM];
        for (int i = 0; i < params.n_dim; i++) {
            if (!params.has_service_rates) { gamma_sta[i] = 0.0; continue; }
            double g = params.service_rates[i] - result.delta[2 * i];
            double alpha_i = params.mu[i] + params.service_rates[i];
            if (g < 0) g = 0;
            if (g > params.service_rates[i]) g = params.service_rates[i];
            if (alpha_i > 0 && g > alpha_i) g = alpha_i;
            gamma_sta[i] = g;
        }

        if (params.has_service_rates) {
            for (int i = 0; i < params.n_dim; i++) {
                double rho_i = (params.service_rates[i] > 1e-12)
                    ? gamma_sta[i] / params.service_rates[i] : 0.0;
                printf("rho_%d = %.6f\n", i + 1, rho_i);
            }
            printf("\n");
            for (int i = 0; i < params.n_dim; i++)
                printf("Gamma_%d = %.6f\n", i + 1, gamma_sta[i]);
            printf("\n");
            for (int i = 0; i < params.n_dim; i++) {
                double sojourn = (gamma_sta[i] > 1e-12) ? result.q[i] / gamma_sta[i] : 0.0;
                printf("sojourn_%d = %.6f\n", i + 1, sojourn);
            }
            printf("\n");
        }

        {
            int w = 1;
            for (int t = params.n_dim; t >= 10; t /= 10) w++;
            for (int i = 0; i < params.n_dim; i++)
                printf("E[X_%0*d] = %.6f\n", w, i + 1, result.q[i]);
        }
        printf("\n");

        /* Per-class statistics */
        if (params.cc_num_classes > 0 && params.has_service_rates) {
            int K = params.cc_num_classes;
            int d = params.n_dim;

            /* E[W_i] = sojourn_i - 1/mueff_i  (wait = sojourn - service) */
            double ew_sta[MAX_DIM];
            for (int i = 0; i < d; i++) {
                double sojourn_i = (gamma_sta[i] > 1e-12) ? result.q[i] / gamma_sta[i] : 0.0;
                ew_sta[i] = sojourn_i - 1.0 / params.service_rates[i];
                if (ew_sta[i] < 0) ew_sta[i] = 0;
            }

            for (int k = 0; k < K; k++) {
                if (params.cc_lambda[k] < 1e-15) {
                    printf("W_total(class %d) = 0.000000\n", k + 1);
                    continue;
                }
                double w_total = 0.0;
                for (int i = 0; i < d; i++) {
                    double visit = params.cc_alpha[k][i] / params.cc_lambda[k];
                    w_total += visit * ew_sta[i];
                }
                printf("W_total(class %d) = %.6f\n", k + 1, w_total);
            }
            printf("\n");

            for (int k = 0; k < K; k++) {
                if (params.cc_lambda[k] < 1e-15) {
                    printf("T_total(class %d) = 0.000000\n", k + 1);
                    continue;
                }
                double t_total = 0.0;
                for (int i = 0; i < d; i++) {
                    double visit = params.cc_alpha[k][i] / params.cc_lambda[k];
                    t_total += visit * (ew_sta[i] + 1.0 / params.cc_mu[k][i]);
                }
                printf("T_total(class %d) = %.6f\n", k + 1, t_total);
            }
            printf("\n");

            for (int k = 0; k < K; k++) {
                double t_total = 0.0;
                if (params.cc_lambda[k] >= 1e-15) {
                    for (int i = 0; i < d; i++) {
                        double visit = params.cc_alpha[k][i] / params.cc_lambda[k];
                        t_total += visit * (ew_sta[i] + 1.0 / params.cc_mu[k][i]);
                    }
                }
                double n_total = params.cc_lambda[k] * t_total;
                printf("N_total(class %d) = %.6f\n", k + 1, n_total);
            }
            printf("\n");
        }
    } else if (g_compact) {
        printf("Spectral Method\n");
        printf("==================\n");
        {
            int w = 1;
            for (int t = params.n_dim; t >= 10; t /= 10) w++;
            for (int k = 0; k < params.n_dim; k++) {
                printf("E[X_%0*d] = %.6f\n", w, k + 1, result.q[k]);
            }
        }
        printf("\n");
    } else {
        /* Print throughput if service rates available. Clipped to
         * [0, min(μ_eff_k, α_k)] to suppress unphysical reports at
         * near-saturated stations (see -G branch above for rationale). */
        if (params.has_service_rates) {
            printf("\n");
            for (int k = 0; k < params.n_dim; k++) {
                /* delta is interleaved: delta[2k] = lower, delta[2k+1] = upper */
                double gamma_k = params.service_rates[k] - result.delta[2 * k];
                double alpha_k = params.mu[k] + params.service_rates[k];
                if (gamma_k < 0) gamma_k = 0;
                if (gamma_k > params.service_rates[k]) gamma_k = params.service_rates[k];
                if (alpha_k > 0 && gamma_k > alpha_k) gamma_k = alpha_k;
                printf("Gamma_%d = %.6f\n", k + 1, gamma_k);
            }
        }

        /* Print expected values last so they are always visible at the bottom */
        printf("\n");
        {
            int w = 1;
            for (int t = params.n_dim; t >= 10; t /= 10) w++;
            for (int k = 0; k < params.n_dim; k++) {
                printf("E[X_%0*d] = %.6f\n", w, k + 1, result.q[k]);
            }
        }
    }

    /* Cleanup */
    params_free(&params);
    result_free(&result);

    return 0;
}
