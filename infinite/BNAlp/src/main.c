/*
 * main.c – CLI entry point for SRBM LP solver.
 *
 * Usage:
 *   ./srbm_lp --input example1.txt [--solver cplex|glpk|highs]
 *             [--output prefix] [--moments k] [--list-solvers] [-c]
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
#include "srbm_linalg.h"
#include "srbm_mem.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>

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

    /* Parse command-line arguments */
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--input") == 0 && i + 1 < argc) {
            input_file = argv[++i];
        } else if (strcmp(argv[i], "--solver") == 0 && i + 1 < argc) {
            solver_name = argv[++i];
        } else if (strcmp(argv[i], "--output") == 0 && i + 1 < argc) {
            output_prefix = argv[++i];
        } else if (strcmp(argv[i], "--moments") == 0 && i + 1 < argc) {
            max_moments = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--list-solvers") == 0) {
            srbm_solver_list();
            return 0;
        } else if (strcmp(argv[i], "-c") == 0) {
            compact_mode = 1;
        } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            usage(argv[0]);
            return 0;
        } else {
            fprintf(stderr, "Unknown option: %s\n", argv[i]);
            usage(argv[0]);
            return 1;
        }
    }

    if (!input_file) {
        fprintf(stderr, "Error: --input FILE is required\n");
        usage(argv[0]);
        return 1;
    }

    /* ------------------------------------------------------------------ */
    /* Step 1: Parse input file                                           */
    /* ------------------------------------------------------------------ */
    double t0 = walltime();
    srbm_params_t params;
    if (srbm_params_read(input_file, &params) != 0)
        return 1;

    /* Apply command-line overrides */
    if (solver_name) strncpy(params.solver, solver_name, 31);
    if (output_prefix) strncpy(params.output_prefix, output_prefix, 255);
    if (max_moments > 0) params.max_moments = max_moments;

    if (srbm_params_validate(&params) != 0)
        return 1;

    /* In compact mode, suppress all stdout until means */
    if (compact_mode) {
        compact_suppress_stdout();
    }

    srbm_params_print(&params);

    int d = params.d;
    int n = params.n;
    int m = params.m;

    /* ------------------------------------------------------------------ */
    /* Step 2: Compute grid spacing mu_grid if not specified               */
    /*   In Rungraph.m / Alg.m:  mu is passed directly; grid uses mu/4.   */
    /*   The user specifies mu_grid directly in the input file.            */
    /*   If all zeros, compute as -2*R^{-1}*mu / 4 as default.            */
    /* ------------------------------------------------------------------ */
    int mu_grid_zero = 1;
    for (int i = 0; i < d; i++) {
        if (params.mu_grid[i] != 0.0) { mu_grid_zero = 0; break; }
    }

    /* Pack matrices into contiguous d x d arrays (row-major) for computation */
    double *R_dense  = (double *)srbm_malloc(d * d * sizeof(double));
    double *G_dense  = (double *)srbm_malloc(d * d * sizeof(double));
    double *M_vec    = (double *)srbm_malloc(d * sizeof(double));
    double *mu_grid  = (double *)srbm_malloc(d * sizeof(double));

    for (int i = 0; i < d; i++) {
        M_vec[i] = params.mu[i];
        mu_grid[i] = params.mu_grid[i];
        for (int j = 0; j < d; j++) {
            R_dense[i * d + j] = params.R[i * SRBM_MAX_DIM + j];
            G_dense[i * d + j] = params.sigma[i * SRBM_MAX_DIM + j];
        }
    }

    if (mu_grid_zero) {
        /* Compute rho = -2 * R^{-1} * mu.
         * mu_grid is set to rho (the rate parameter); the /4 factor for
         * ExpGrid is applied below together with user-specified values.
         * Use LAPACK solve: R * rho = -2 * mu  →  rho = R \ (-2 * mu) */
        double *Rcopy = (double *)srbm_malloc(d * d * sizeof(double));
        double *rhs   = (double *)srbm_malloc(d * sizeof(double));

        /* LAPACK needs column-major; transpose R_dense (row-major) to column-major */
        for (int i = 0; i < d; i++) {
            rhs[i] = -2.0 * M_vec[i];
            for (int j = 0; j < d; j++)
                Rcopy[j * d + i] = R_dense[i * d + j];
        }
        srbm_linalg_solve(d, 1, Rcopy, rhs);

        for (int i = 0; i < d; i++) {
            mu_grid[i] = rhs[i];   /* rho_i; the /4 is applied below */
            if (mu_grid[i] <= 0.0) {
                fprintf(stderr, "Warning: computed rho[%d] = %.4f <= 0, using 1.0\n",
                        i, mu_grid[i]);
                mu_grid[i] = 1.0;
            }
        }
        printf("  Auto rho      =");
        for (int i = 0; i < d; i++) printf(" %.4f", mu_grid[i]);
        printf("\n");

        srbm_free(Rcopy);
        srbm_free(rhs);
    }

    /* Apply the /4 factor only to auto-computed rho, as in MATLAB Alg.m:
     * ExpGrid(d,n,mu/4).  User-specified grid_spacing is used as-is. */
    if (mu_grid_zero) {
        for (int i = 0; i < d; i++)
            mu_grid[i] /= 4.0;
    }

    printf("  Effective grid_spacing%s =", mu_grid_zero ? " (rho/4)" : "");
    for (int i = 0; i < d; i++) printf(" %.4f", mu_grid[i]);
    printf("\n");

    double t_parse = walltime() - t0;
    printf("\n[Parse] %.3f s\n", t_parse);

    /* ------------------------------------------------------------------ */
    /* Step 3: Set tightness bounds K                                     */
    /* ------------------------------------------------------------------ */
    double *K = (double *)srbm_malloc((2 * d + 1) * sizeof(double));
    if (params.K_user) {
        for (int i = 0; i < 2 * d + 1; i++)
            K[i] = params.K[i];
        /* If user set K to 0, use loose bounds */
        int all_zero = 1;
        for (int i = 0; i < 2 * d + 1; i++)
            if (K[i] != 0.0) { all_zero = 0; break; }
        if (all_zero) {
            for (int i = 0; i < 2 * d + 1; i++)
                K[i] = 100000.0;
        }
    } else {
        for (int i = 0; i < 2 * d + 1; i++)
            K[i] = 100000.0;
    }

    /* ------------------------------------------------------------------ */
    /* Step 4: Generate grid                                              */
    /* ------------------------------------------------------------------ */
    double t1 = walltime();
    srbm_grid_t grid;
    srbm_grid_build(d, n, params.grid_type, mu_grid, &grid);
    double t_grid = walltime() - t1;
    printf("[Grid]  %d points, %.3f s\n", grid.npoints, t_grid);

    for (int k = 0; k < d; k++)
        printf("  Face %d boundary: %d points\n", k + 1, grid.bdy_count[k]);

    /* ------------------------------------------------------------------ */
    /* Step 5: Enumerate multi-indices                                    */
    /* ------------------------------------------------------------------ */
    t1 = walltime();
    srbm_index_t idx;
    srbm_index_build(d, m, &idx);
    double t_idx = walltime() - t1;
    printf("[Index] %d basis functions, %.3f s\n", idx.n_basis, t_idx);

    /* ------------------------------------------------------------------ */
    /* Step 6: Compute BAR coefficients                                   */
    /* ------------------------------------------------------------------ */
    t1 = walltime();
    srbm_basis_t bas;
    srbm_basis_build(&idx, G_dense, M_vec, R_dense, d, m, &bas);
    double t_basis = walltime() - t1;
    printf("[Basis] %.3f s\n", t_basis);

    /* ------------------------------------------------------------------ */
    /* Step 7: Evaluate interior terms                                    */
    /* ------------------------------------------------------------------ */
    t1 = walltime();
    double *V = (double *)srbm_malloc((size_t)grid.npoints * idx.n_basis * sizeof(double));
    srbm_eval_interior(&idx, &bas, &grid, V);
    double t_val = walltime() - t1;
    printf("[Eval interior] %.3f s\n", t_val);

    /* ------------------------------------------------------------------ */
    /* Step 8: Evaluate boundary terms                                    */
    /* ------------------------------------------------------------------ */
    t1 = walltime();
    double *D_arrays[SRBM_MAX_DIM];
    for (int k = 0; k < d; k++) {
        D_arrays[k] = (double *)srbm_malloc(
            (size_t)grid.bdy_count[k] * idx.n_basis * sizeof(double));
    }
    srbm_eval_boundary(&idx, &bas, &grid, D_arrays);
    double t_bdy = walltime() - t1;
    printf("[Eval boundary] %.3f s\n", t_bdy);

    /* ------------------------------------------------------------------ */
    /* Step 8b: Monomial normalization (optional, opt-in)                 */
    /*                                                                    */
    /*   Test function f_i has multi-index (p_1, ..., p_d).               */
    /*   Define L_k = max grid value on coord k, and scale                */
    /*       c_i = 1 / prod_k L_k^{p_k}.                                  */
    /*   Replacing f_i by f_i / (prod L^p) scales the BAR row by c_i.     */
    /*                                                                    */
    /*   Without this, high-degree rows have magnitudes ~L^m ~ 1e9 for    */
    /*   m=10 and dominate u*, making the LP ill-conditioned.  With it,   */
    /*   every row has magnitude O(|p|).  Empirically: fixes CPLEX        */
    /*   m>=8 failures and GLPK m>=10 singularities; however it changes   */
    /*   the LP vertex for degenerate (u*=0) cases so moments can shift.  */
    /*   Disabled by default; enable via `basis_normalize 1` in input.    */
    /* ------------------------------------------------------------------ */
    if (params.basis_normalize) {
        double Lcoord[SRBM_MAX_DIM];
        for (int c = 0; c < d; c++) {
            double lmax = 0.0;
            for (int j = 0; j < grid.npoints; j++) {
                double v = grid.P[j * d + c];
                if (v > lmax) lmax = v;
            }
            Lcoord[c] = (lmax > 0.0) ? lmax : 1.0;
        }
        printf("[Normalize] L =");
        for (int c = 0; c < d; c++) printf(" %.4f", Lcoord[c]);
        printf("\n");

        int nb = idx.n_basis;
        for (int i = 0; i < nb; i++) {
            /* c_i = 1 / prod_k L_k^{I(i,k)} */
            double ci = 1.0;
            for (int c = 0; c < d; c++) {
                int p = idx.I[i * (d + 1) + c];
                for (int q = 0; q < p; q++) ci /= Lcoord[c];
            }
            if (ci == 1.0) continue;
            /* Scale column i of V */
            for (int p = 0; p < grid.npoints; p++)
                V[p * nb + i] *= ci;
            /* Scale column i of every boundary D[k] */
            for (int k = 0; k < d; k++) {
                int nbdy = grid.bdy_count[k];
                for (int b = 0; b < nbdy; b++)
                    D_arrays[k][b * nb + i] *= ci;
            }
        }
    }

    /* ------------------------------------------------------------------ */
    /* Step 9: Build LP                                                   */
    /* ------------------------------------------------------------------ */
    t1 = walltime();
    srbm_lp_t lp;
    srbm_build_lp(V, D_arrays, &grid, d, idx.n_basis, K,
                  params.smoothness_weight, params.n, params.grid_type, &lp);
    double t_build = walltime() - t1;
    printf("[Build LP] %d rows, %d cols, %d nnz, %.3f s\n",
           lp.nrows, lp.ncols, lp.nnz, t_build);

    /* Free evaluation arrays (no longer needed) */
    srbm_free(V);
    for (int k = 0; k < d; k++)
        srbm_free(D_arrays[k]);

    /* ------------------------------------------------------------------ */
    /* Step 10: Solve LP                                                  */
    /* ------------------------------------------------------------------ */
    const srbm_solver_backend_t *backend = NULL;
    if (params.solver[0])
        backend = srbm_solver_get(params.solver);
    if (!backend)
        backend = srbm_solver_default();
    if (!backend) {
        fprintf(stderr, "No LP solver available! Compile with -DHAVE_CPLEX, -DHAVE_GLPK, or -DHAVE_HIGHS\n");
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

    /* ------------------------------------------------------------------ */
    /* Step 11-12: Compute moments                                        */
    /* ------------------------------------------------------------------ */
    int mk = params.max_moments;
    double *EM = (double *)srbm_malloc(mk * d * sizeof(double));
    srbm_moments(sol.lambda, grid.P, grid.npoints, d, mk, EM);
    srbm_print_moments(EM, mk, d);

    /* ------------------------------------------------------------------ */
    /* Step 13: Extract and smooth marginals                              */
    /* ------------------------------------------------------------------ */
    double *ez[SRBM_MAX_DIM], *epx[SRBM_MAX_DIM], *spx[SRBM_MAX_DIM];
    int counts[SRBM_MAX_DIM];
    srbm_marginals(sol.lambda, grid.P, grid.npoints, n, d, ez, epx, counts);
    srbm_smooth_marginals(epx, d, counts, spx);

    /* ------------------------------------------------------------------ */
    /* Step 14: Write output                                              */
    /* ------------------------------------------------------------------ */
    printf("\nOutput files:\n");
    srbm_write_marginals_csv(params.output_prefix, ez, spx, d, counts);
    srbm_write_distribution_csv(params.output_prefix, sol.lambda, grid.P,
                                grid.npoints, d);

    double t_total = walltime() - t0;
    printf("\n[Total] %.3f s\n", t_total);

    /* Restore stdout if compact mode was active */
    if (compact_mode) {
        compact_restore_stdout();
        printf("LP Method (BNAlp)\n");
        printf("=================\n");
    }

    /* Means (first-order moments): always printed last */
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
    srbm_free(G_dense);
    srbm_free(M_vec);
    srbm_free(mu_grid);
    srbm_free(K);

    return 0;
}
