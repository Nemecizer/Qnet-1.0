/*
 * main.c — fBNAlp CLI entry point. Solves an SRBM in the rectangle
 * [0, b_1] × … × [0, b_d] via the LP / polynomial-test-function method
 * (Saure-Glynn-Zeevi extended to bounded boxes).
 *
 *   ./fBNAlp_solver --input file.in [--solver highs|glpk|cplex]
 *                   [--output prefix] [--moments k] [--list-solvers] [-c]
 */
#include "srbm_types.h"
#include "srbm_params.h"
#include "srbm_grid.h"
#include "srbm_index.h"
#include "srbm_basis.h"
#include "srbm_eval.h"
#include "srbm_build.h"
#include "srbm_solve.h"
#include "srbm_output.h"
#include "srbm_mem.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>

static int compact_mode = 0;
static int saved_stdout_fd = -1;

static void compact_suppress_stdout(void)
{
    fflush(stdout);
    saved_stdout_fd = dup(STDOUT_FILENO);
    int devnull = open("/dev/null", O_WRONLY);
    dup2(devnull, STDOUT_FILENO);
    close(devnull);
}

static void compact_restore_stdout(void)
{
    fflush(stdout);
    dup2(saved_stdout_fd, STDOUT_FILENO);
    close(saved_stdout_fd);
    saved_stdout_fd = -1;
}

static double walltime(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static void usage(const char *prog)
{
    fprintf(stderr,
        "Usage: %s --input FILE [OPTIONS]\n"
        "\nOptions:\n"
        "  --input FILE       Input parameter file (required)\n"
        "  --solver NAME      LP solver: cplex, glpk, highs (default: first available)\n"
        "  --output PREFIX    Output file prefix (default: srbm_out)\n"
        "  --moments K        Compute up to K-th moment (default: 4)\n"
        "  --list-solvers     List available solvers and exit\n"
        "  -c                 Compact output (algorithm name + means only)\n"
        "  --help             Show this message\n",
        prog);
}

int main(int argc, char *argv[])
{
    const char *input_file = NULL;
    const char *solver_name = NULL;
    const char *output_prefix = NULL;
    int max_moments = -1;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--input") == 0 && i + 1 < argc)
            input_file = argv[++i];
        else if (strcmp(argv[i], "--solver") == 0 && i + 1 < argc)
            solver_name = argv[++i];
        else if (strcmp(argv[i], "--output") == 0 && i + 1 < argc)
            output_prefix = argv[++i];
        else if (strcmp(argv[i], "--moments") == 0 && i + 1 < argc)
            max_moments = atoi(argv[++i]);
        else if (strcmp(argv[i], "--list-solvers") == 0) {
            srbm_solver_list();
            return 0;
        } else if (strcmp(argv[i], "-c") == 0) compact_mode = 1;
        else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            usage(argv[0]); return 0;
        } else {
            fprintf(stderr, "Unknown option: %s\n", argv[i]);
            usage(argv[0]); return 1;
        }
    }

    if (!input_file) {
        fprintf(stderr, "Error: --input FILE is required\n");
        usage(argv[0]); return 1;
    }

    /* Step 1: parse input */
    double t0 = walltime();
    srbm_params_t params;
    if (srbm_params_read(input_file, &params) != 0) return 1;

    if (solver_name)   strncpy(params.solver, solver_name, 31);
    if (output_prefix) strncpy(params.output_prefix, output_prefix, 255);
    if (max_moments > 0) params.max_moments = max_moments;

    if (srbm_params_validate(&params) != 0) return 1;

    if (compact_mode) compact_suppress_stdout();
    srbm_params_print(&params);

    int d = params.d;
    int n = params.n;
    int m = params.m;

    /* Step 2: pack matrices for downstream code (dense d×d row-major). */
    double *R_dense   = (double *)srbm_malloc(d * d * sizeof(double));
    double *Rp_dense  = (double *)srbm_malloc(d * d * sizeof(double));
    double *G_dense   = (double *)srbm_malloc(d * d * sizeof(double));
    double *M_vec     = (double *)srbm_malloc(d * sizeof(double));
    double *b_upper   = (double *)srbm_malloc(d * sizeof(double));

    for (int i = 0; i < d; i++) {
        M_vec[i]   = params.mu[i];
        b_upper[i] = params.b_upper[i];
        for (int j = 0; j < d; j++) {
            R_dense[i * d + j] = params.R[i * SRBM_MAX_DIM + j];
            G_dense[i * d + j] = params.sigma[i * SRBM_MAX_DIM + j];
            if (params.R_full_2d)
                Rp_dense[i * d + j] = params.R_plus[i * SRBM_MAX_DIM + j];
            else
                Rp_dense[i * d + j] = -R_dense[i * d + j];
        }
    }
    if (!params.R_full_2d && !compact_mode) {
        /* Make the silent inference visible — users supplying skew
         * reflections need to know R_plus was synthesized as -R rather
         * than read from the file. Override with `reflection_form
         * full_2d` (or `grouped` / `interleaved`). */
        fprintf(stderr,
            "[note] R_plus auto-synthesized as -R (manufacturing blocking "
            "convention). Supply `reflection_form full_2d` to override.\n");
    }

    double t_parse = walltime() - t0;
    printf("\n[Parse] %.3f s\n", t_parse);

    /* Step 3: tightness vector. K is length 4d+1. If user-empty, default
     * to a uniformly loose 100000 — same heuristic as orthant BNAlp. */
    int K_len = 4 * d + 1;
    double *K = (double *)srbm_malloc(K_len * sizeof(double));
    if (params.K_user) {
        for (int i = 0; i < K_len; i++) K[i] = params.K[i];
        int all_zero = 1;
        for (int i = 0; i < K_len; i++) if (K[i] != 0.0) { all_zero = 0; break; }
        if (all_zero) for (int i = 0; i < K_len; i++) K[i] = 100000.0;
    } else {
        for (int i = 0; i < K_len; i++) K[i] = 100000.0;
    }

    /* Step 4: grid */
    double t1 = walltime();
    srbm_grid_t grid;
    srbm_grid_build(d, n, params.grid_type, b_upper, &grid);
    double t_grid = walltime() - t1;
    printf("[Grid]  %d points, %.3f s\n", grid.npoints, t_grid);
    for (int k = 0; k < d; k++) {
        printf("  Face %d: lower=%d upper=%d\n", k + 1,
               grid.bdy_minus_count[k], grid.bdy_plus_count[k]);
    }

    /* Step 5: multi-indices */
    t1 = walltime();
    srbm_index_t idx;
    srbm_index_build(d, m, &idx);
    double t_idx = walltime() - t1;
    printf("[Index] %d basis functions, %.3f s\n", idx.n_basis, t_idx);

    /* Step 6: BAR coefficients */
    t1 = walltime();
    srbm_basis_t bas;
    srbm_basis_build(&idx, G_dense, M_vec, R_dense, Rp_dense, d, m, &bas);
    double t_basis = walltime() - t1;
    printf("[Basis] %.3f s\n", t_basis);

    /* Step 7: interior eval */
    t1 = walltime();
    double *V = (double *)srbm_malloc(
        (size_t)grid.npoints * idx.n_basis * sizeof(double));
    srbm_eval_interior(&idx, &bas, &grid, V);
    double t_val = walltime() - t1;
    printf("[Eval interior] %.3f s\n", t_val);

    /* Step 8: boundary eval (both lower and upper faces) */
    t1 = walltime();
    double *D_minus[SRBM_MAX_DIM];
    double *D_plus[SRBM_MAX_DIM];
    for (int k = 0; k < d; k++) {
        D_minus[k] = (double *)srbm_malloc(
            (size_t)grid.bdy_minus_count[k] * idx.n_basis * sizeof(double));
        D_plus[k]  = (double *)srbm_malloc(
            (size_t)grid.bdy_plus_count[k]  * idx.n_basis * sizeof(double));
    }
    srbm_eval_boundary(&idx, &bas, &grid, D_minus, D_plus);
    double t_bdy = walltime() - t1;
    printf("[Eval boundary] %.3f s\n", t_bdy);

    /* Step 8b: optional monomial normalization (carry-over from BNAlp).
     * Scales each row i of V, D_minus and D_plus by 1 / prod_k L_k^{αᵢ,k}
     * with L_k = b_upper[k]. */
    if (params.basis_normalize) {
        printf("[Normalize] L =");
        for (int c = 0; c < d; c++) printf(" %.4f", b_upper[c]);
        printf("\n");

        int nb = idx.n_basis;
        for (int i = 0; i < nb; i++) {
            double ci = 1.0;
            for (int c = 0; c < d; c++) {
                int p = idx.I[i * (d + 1) + c];
                double Lc = (b_upper[c] > 0.0) ? b_upper[c] : 1.0;
                for (int q = 0; q < p; q++) ci /= Lc;
            }
            if (ci == 1.0) continue;
            for (int p = 0; p < grid.npoints; p++) V[p * nb + i] *= ci;
            for (int k = 0; k < d; k++) {
                int nbm = grid.bdy_minus_count[k];
                for (int b = 0; b < nbm; b++) D_minus[k][b * nb + i] *= ci;
                int nbp = grid.bdy_plus_count[k];
                for (int b = 0; b < nbp; b++) D_plus[k][b * nb + i] *= ci;
            }
        }
    }

    /* Step 9: build LP */
    t1 = walltime();
    srbm_lp_t lp;
    srbm_build_lp(V, D_minus, D_plus, &grid, d, idx.n_basis, K,
                  params.smoothness_weight, params.n, params.grid_type, &lp);
    double t_build = walltime() - t1;
    printf("[Build LP] %d rows, %d cols, %d nnz, %.3f s\n",
           lp.nrows, lp.ncols, lp.nnz, t_build);

    srbm_free(V);
    for (int k = 0; k < d; k++) {
        srbm_free(D_minus[k]);
        srbm_free(D_plus[k]);
    }

    /* Step 10: solve */
    const srbm_solver_backend_t *backend = NULL;
    if (params.solver[0]) backend = srbm_solver_get(params.solver);
    if (!backend) backend = srbm_solver_default();
    if (!backend) {
        fprintf(stderr,
                "No LP solver available! Compile with -DHAVE_HIGHS, -DHAVE_GLPK, or -DHAVE_CPLEX\n");
        srbm_solver_list();
        return 1;
    }

    printf("[Solve] Using solver: %s\n", backend->name);
    if (backend->init() != 0) return 1;

    t1 = walltime();
    srbm_solution_t sol;
    memset(&sol, 0, sizeof(sol));
    int solve_status = backend->solve(&lp, &sol);
    double t_solve = walltime() - t1;

    if (solve_status != 0) {
        fprintf(stderr, "LP solve failed!\n");
        backend->cleanup();
        return 1;
    }
    printf("[Solve] Optimal u* = %.10e, %.3f s\n", sol.obj_val, t_solve);

    backend->cleanup();
    srbm_lp_free(&lp);

    /* Step 11: moments + means */
    int mk = params.max_moments;
    double *EM = (double *)srbm_malloc(mk * d * sizeof(double));
    srbm_moments(sol.lambda, grid.P, grid.npoints, d, mk, EM);
    srbm_print_moments(EM, mk, d);

    /* Step 12: marginals */
    double *ez[SRBM_MAX_DIM], *epx[SRBM_MAX_DIM], *spx[SRBM_MAX_DIM];
    int counts[SRBM_MAX_DIM];
    srbm_marginals(sol.lambda, grid.P, grid.npoints, n, d, ez, epx, counts);
    srbm_smooth_marginals(epx, d, counts, spx);

    /* Step 13: write output */
    printf("\nOutput files:\n");
    srbm_write_marginals_csv(params.output_prefix, ez, spx, d, counts);
    srbm_write_distribution_csv(params.output_prefix, sol.lambda, grid.P,
                                grid.npoints, d);

    double t_total = walltime() - t0;
    printf("\n[Total] %.3f s\n", t_total);

    if (compact_mode) {
        compact_restore_stdout();
        printf("Finite LP Method (fBNAlp)\n");
        printf("=========================\n");
    }

    /* When the user supplies per-station service rates we can also report
     * effective utilisation, throughput and sojourn — the same metrics the
     * spectral and FEM solvers print. The lower-face boundary measure
     * δ⁻_k is the LP's representation of fraction-of-time-server-idle, so
     *     Gamma_k    = μ_eff_k − δ⁻_k     (effective throughput)
     *     rho_k      = Gamma_k / μ_eff_k  (effective utilisation)
     *     sojourn_k  = E[X_k] / Gamma_k   (Little's law). */
    if (params.has_service_rates) {
        double delta_minus[SRBM_MAX_DIM];
        for (int k = 0; k < d; k++) {
            double s = 0.0;
            for (int b = 0; b < sol.n_minus[k]; b++) s += sol.gamma_minus[k][b];
            delta_minus[k] = s;
        }
        /* Throughput = μ_eff − δ⁻. Two physical bounds:
         *   (a) Γ ≤ μ_eff (capacity)
         *   (b) Γ ≤ α = drift + capacity (steady-state mass conservation)
         * Bound (b) is the tighter one in stable systems and catches
         * "throughput exceeds offered load" artifacts that the LP fit
         * doesn't suppress directly. Same clipping in fBNAsm / FEM. */
        double gamma_arr[SRBM_MAX_DIM];
        for (int k = 0; k < d; k++) {
            double g = params.service_rates[k] - delta_minus[k];
            double alpha_k = params.mu[k] + params.service_rates[k];
            if (g < 0) g = 0;
            if (g > params.service_rates[k]) g = params.service_rates[k];
            if (alpha_k > 0 && g > alpha_k) g = alpha_k;
            gamma_arr[k] = g;
        }
        for (int k = 0; k < d; k++) {
            double mu = params.service_rates[k];
            double rho = (mu > 1e-12) ? gamma_arr[k] / mu : 0.0;
            printf("rho_%d = %.6f\n", k + 1, rho);
        }
        for (int k = 0; k < d; k++) {
            printf("Gamma_%d = %.6f\n", k + 1, gamma_arr[k]);
        }
        for (int k = 0; k < d; k++) {
            double soj = (gamma_arr[k] > 1e-12) ? EM[0 * d + k] / gamma_arr[k] : 0.0;
            printf("sojourn_%d = %.6f\n", k + 1, soj);
        }
    }

    /* First-order moments: always last so the AWK summarizer used by Qnet
     * can pick them up regardless of compact-mode setting. */
    for (int j = 0; j < d; j++)
        printf("E[X_%d] = %.6f\n", j + 1, EM[0 * d + j]);

    /* Cleanup */
    srbm_free(EM);
    srbm_marginals_free(ez, epx, spx, d);
    srbm_solution_free(&sol);
    srbm_grid_free(&grid);
    srbm_index_free(&idx);
    srbm_basis_free(&bas);
    srbm_free(R_dense);
    srbm_free(Rp_dense);
    srbm_free(G_dense);
    srbm_free(M_vec);
    srbm_free(b_upper);
    srbm_free(K);

    return 0;
}
