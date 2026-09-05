/*
 * srbm_solver.c - Main SRBM solver implementation
 *
 * Implementation of Dai & Harrison (1991) SRBM algorithm in C
 * Uses OpenMP for parallelization and Apple Accelerate for BLAS/LAPACK
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <pthread.h>
#include "../../common/bnet_memcheck.h"

#ifdef __APPLE__
#include <Accelerate/Accelerate.h>
#else
#include <cblas.h>
#include <lapacke.h>
#endif

#ifdef _OPENMP
#include <omp.h>
#endif

#include "srbm_types.h"
#include "srbm_solver.h"

/* Set by main.c */
extern int g_compact;
extern int g_use_legendre;

#define TOLERANCE 1e-14

/* Unified Qnet progress protocol (-P PATH).
 * `srbm_progress_path` is set by main.c on -P; tick() is also called
 * from gram_matrix.c (the visible loops live there). */
char  srbm_progress_path[1024] = "";
static FILE *srbm_progress_fp = NULL;
static pthread_mutex_t srbm_progress_lock = PTHREAD_MUTEX_INITIALIZER;

void srbm_progress_open(long total) {
    if (!srbm_progress_path[0]) return;
    srbm_progress_fp = fopen(srbm_progress_path, "wb");
    if (!srbm_progress_fp) return;
    fprintf(srbm_progress_fp, "%ld\n", total);
    fflush(srbm_progress_fp);
}
void srbm_progress_tick(void) {
    if (!srbm_progress_fp) return;
    pthread_mutex_lock(&srbm_progress_lock);
    fputc('.', srbm_progress_fp);
    fflush(srbm_progress_fp);
    pthread_mutex_unlock(&srbm_progress_lock);
}
void srbm_progress_close(void) {
    if (srbm_progress_fp) {
        fclose(srbm_progress_fp);
        srbm_progress_fp = NULL;
    }
}

/* ============================================================================
 * Power table initialization
 * ============================================================================ */

void init_power_table(PowerTable *pt, const double *a_vec, int n_dim, int max_exp) {
    pt->n_dim = n_dim;
    pt->max_exp = max_exp;
    for (int d = 0; d < n_dim; d++) {
        double a_pow = 1.0;
        for (int e = 0; e <= max_exp; e++) {
            pt->raw[d][e] = a_pow;
            pt->div[d][e] = a_pow * a_vec[d] / (e + 1);
            a_pow *= a_vec[d];
        }
    }
}

/* Legendre-normalized power table: div[d][e] = a_d/(e+1)
 * For t-coordinate polynomials, this correctly computes
 * integrals including the Jacobian dx = a*dt */
static void init_power_table_legendre(PowerTable *pt, const double *a_vec, int n_dim, int max_exp) {
    pt->n_dim = n_dim;
    pt->max_exp = max_exp;
    for (int d = 0; d < n_dim; d++) {
        for (int e = 0; e <= max_exp; e++) {
            pt->raw[d][e] = 1.0; /* t_k = 1 at upper boundary */
            pt->div[d][e] = a_vec[d] / (e + 1);
        }
    }
}

/* ============================================================================
 * Multi-index generation
 * ============================================================================ */

/* Recursive helper to generate indices of a specific degree */
static void generate_indices_of_degree_recursive(int n_dim, int degree, int start_dim,
                                                  int *current, int **indices,
                                                  int *count, int n_dim_total) {
    if (start_dim == n_dim - 1) {
        /* Last dimension gets the remaining degree */
        current[start_dim] = degree;
        /* Copy current index to output */
        memcpy((*indices) + (*count) * n_dim_total, current, n_dim_total * sizeof(int));
        (*count)++;
        return;
    }

    for (int i = 0; i <= degree; i++) {
        current[start_dim] = i;
        generate_indices_of_degree_recursive(n_dim, degree - i, start_dim + 1,
                                             current, indices, count, n_dim_total);
    }
}

/* Count number of indices of a specific degree: C(n+k-1, k) */
static int count_indices_of_degree(int n_dim, int degree) {
    if (degree == 0) return 1;
    if (n_dim == 1) return 1;

    /* Compute binomial coefficient C(n_dim + degree - 1, degree) */
    long long result = 1;
    for (int i = 0; i < degree; i++) {
        result = result * (n_dim + i) / (i + 1);
    }
    return (int)result;
}

/* Generate all multi-indices with 1 <= |alpha| <= max_order */
int* generate_multi_indices(int n_dim, int max_order, int *n_indices) {
    /* Count total indices */
    int total = 0;
    for (int k = 1; k <= max_order; k++) {
        total += count_indices_of_degree(n_dim, k);
    }
    *n_indices = total;

    /* Allocate output array */
    int *indices = (int *)malloc(total * n_dim * sizeof(int));
    if (!indices) {
        fprintf(stderr, "Error: Failed to allocate multi-indices\n");
        return NULL;
    }

    /* Generate indices */
    int *current = (int *)calloc(n_dim, sizeof(int));
    int count = 0;

    for (int k = 1; k <= max_order; k++) {
        memset(current, 0, n_dim * sizeof(int));
        generate_indices_of_degree_recursive(n_dim, k, 0, current, &indices, &count, n_dim);
    }

    free(current);
    return indices;
}

/* ============================================================================
 * Compute A*f for monomials
 * ============================================================================ */

void compute_Af(const int *alpha, const SRBMParams *params, AfFunction *af) {
    int n_dim = params->n_dim;
    const double *Gamma = params->Gamma;
    const double *mu = params->mu;
    const double *R = params->R;
    const double *a_vec = params->a_vec;

    /* Precompute powers of a_vec for upper boundary evaluation */
    double a_powers[MAX_DIM][MAX_POLY_ORDER + 2];
    for (int d = 0; d < n_dim; d++) {
        a_powers[d][0] = 1.0;
        for (int e = 1; e <= params->n_approx + 1; e++)
            a_powers[d][e] = a_powers[d][e-1] * a_vec[d];
    }

    /* ---- Interior: Lf = (1/2) sum_ij Gamma_ij d^2f/dx_i dx_j + sum_i mu_i df/dx_i ---- */

    int new_exp[MAX_DIM];

    /* Second derivative terms */
    for (int i = 0; i < n_dim; i++) {
        for (int j = 0; j < n_dim; j++) {
            double Gij = Gamma[i * n_dim + j];
            if (fabs(Gij) < TOLERANCE) continue;

            if (i == j) {
                /* d^2f/dx_i^2 = alpha_i * (alpha_i - 1) * x^{alpha - 2*e_i} */
                if (alpha[i] >= 2) {
                    memcpy(new_exp, alpha, n_dim * sizeof(int));
                    new_exp[i] -= 2;
                    double coeff = 0.5 * Gij * alpha[i] * (alpha[i] - 1);
                    poly_add_term(&af->interior, coeff, new_exp);
                }
            } else {
                /* d^2f/dx_i dx_j = alpha_i * alpha_j * x^{alpha - e_i - e_j} */
                if (alpha[i] >= 1 && alpha[j] >= 1) {
                    memcpy(new_exp, alpha, n_dim * sizeof(int));
                    new_exp[i] -= 1;
                    new_exp[j] -= 1;
                    double coeff = 0.5 * Gij * alpha[i] * alpha[j];
                    poly_add_term(&af->interior, coeff, new_exp);
                }
            }
        }
    }

    /* First derivative terms */
    for (int i = 0; i < n_dim; i++) {
        if (fabs(mu[i]) < TOLERANCE || alpha[i] < 1) continue;
        memcpy(new_exp, alpha, n_dim * sizeof(int));
        new_exp[i] -= 1;
        double coeff = mu[i] * alpha[i];
        poly_add_term(&af->interior, coeff, new_exp);
    }

    poly_consolidate(&af->interior);

    /* ---- Boundary operators: D_face f = v_face . grad(f) ---- */

    for (int face = 0; face < 2 * n_dim; face++) {
        int k = face / 2;  /* Which dimension is fixed */
        int is_lower = (face % 2 == 0);  /* x_k = 0 or x_k = a_k */

        /* Note: reflection vector is accessed via R[i * 2 * n_dim + face] below */

        /* D_face f = sum_i v_i * df/dx_i evaluated at boundary */
        for (int i = 0; i < n_dim; i++) {
            double vi = R[i * 2 * n_dim + face];  /* R[i, face] in row-major */
            if (fabs(vi) < TOLERANCE || alpha[i] < 1) continue;

            /* df/dx_i = alpha_i * x^{alpha - e_i} */
            memcpy(new_exp, alpha, n_dim * sizeof(int));
            new_exp[i] -= 1;

            double coeff;
            if (is_lower) {
                /* At x_k = 0: x_k^{new_exp[k]} = 0 unless new_exp[k] = 0 */
                if (new_exp[k] != 0) continue;
                coeff = vi * alpha[i];
            } else {
                /* At x_k = a_k */
                coeff = vi * alpha[i] * a_powers[k][new_exp[k]];
            }

            /* Create boundary exponent (remove the k-th dimension) */
            int boundary_exp[MAX_DIM];
            int idx = 0;
            for (int d = 0; d < n_dim; d++) {
                if (d != k) {
                    boundary_exp[idx++] = new_exp[d];
                }
            }

            poly_add_term(&af->boundaries[face], coeff, boundary_exp);
        }

        poly_consolidate(&af->boundaries[face]);
    }
}

/* ============================================================================
 * Shifted Legendre polynomial coefficient table
 * ============================================================================ */

void legendre_table_init(LegendreTable *table, int max_order) {
    table->max_order = max_order;
    memset(table->coeffs, 0, sizeof(table->coeffs));

    /* P_tilde_0(t) = 1 */
    table->coeffs[0 * (MAX_POLY_ORDER+1) + 0] = 1.0;

    if (max_order == 0) return;

    /* P_tilde_1(t) = 2t - 1 */
    table->coeffs[1 * (MAX_POLY_ORDER+1) + 0] = -1.0;
    table->coeffs[1 * (MAX_POLY_ORDER+1) + 1] =  2.0;

    /* Recurrence: P_n(t) = ((2n-1)(2t-1)*P_{n-1}(t) - (n-1)*P_{n-2}(t)) / n */
    for (int n = 2; n <= max_order; n++) {
        double *cur  = &table->coeffs[n * (MAX_POLY_ORDER+1)];
        double *prev = &table->coeffs[(n-1) * (MAX_POLY_ORDER+1)];
        double *prev2 = &table->coeffs[(n-2) * (MAX_POLY_ORDER+1)];

        double scale1 = (2.0*n - 1.0) / n;
        double scale2 = (double)(n - 1) / n;

        for (int k = 0; k <= n; k++) {
            double val = 0.0;
            /* From (2t-1) * P_{n-1}: 2t*c_{k-1} - c_k */
            if (k >= 1 && k-1 <= n-1)
                val += scale1 * 2.0 * prev[k-1];
            if (k <= n-1)
                val -= scale1 * prev[k];
            /* Subtract (n-1)/n * P_{n-2} */
            if (k <= n-2)
                val -= scale2 * prev2[k];
            cur[k] = val;
        }
    }
}

/* ============================================================================
 * Compute A*f for Legendre basis functions
 * ============================================================================ */

void compute_Af_legendre(const int *alpha, const SRBMParams *params,
                         const LegendreTable *table, AfFunction *af) {
    int n_dim = params->n_dim;
    const double *Gamma = params->Gamma;
    const double *mu = params->mu;
    const double *R = params->R;
    const double *a_vec = params->a_vec;

    /* All polynomials are stored in normalized t-coordinates: t_j = x_j / a_j.
     * The Legendre product is f(t) = prod_j P_tilde_{alpha_j}(t_j).
     * Chain rule: d/dx_i = (1/a_i) d/dt_i
     *
     * Interior operator in t-coords:
     *   Lf = (1/2) sum_ij Gamma_ij/(a_i*a_j) * d^2f/dt_i dt_j
     *      + sum_i mu_i/a_i * df/dt_i
     *
     * Boundary at t_k=0: term vanishes unless exponent of t_k is 0
     * Boundary at t_k=1: all powers of 1 equal 1 (no large a^n factors!)
     *
     * D_face f = sum_i v_i * df/dx_i = sum_i v_i/a_i * df/dt_i
     */

    /* Iterate over all monomial terms in the Legendre product expansion.
     * Each term: term_coeff * t_1^{k_0} * ... * t_d^{k_{d-1}}
     * where term_coeff = prod_j legendre_coeff(alpha_j, k_j) */
    int k_idx[MAX_DIM];
    memset(k_idx, 0, n_dim * sizeof(int));
    int new_exp[MAX_DIM];

    for (;;) {
        /* Coefficient: pure Legendre coefficients (no 1/a scaling needed in t-coords) */
        double term_coeff = 1.0;
        for (int d = 0; d < n_dim; d++)
            term_coeff *= legendre_coeff(table, alpha[d], k_idx[d]);

        if (fabs(term_coeff) >= TOLERANCE) {
            /* Second derivatives: (1/2) sum_ij Gamma_ij/(a_i*a_j) * d^2/dt_i dt_j */
            for (int i = 0; i < n_dim; i++) {
                for (int j = 0; j < n_dim; j++) {
                    double Gij = Gamma[i * n_dim + j];
                    if (fabs(Gij) < TOLERANCE) continue;

                    if (i == j) {
                        if (k_idx[i] >= 2) {
                            memcpy(new_exp, k_idx, n_dim * sizeof(int));
                            new_exp[i] -= 2;
                            double coeff = term_coeff * 0.5 * Gij / (a_vec[i] * a_vec[j])
                                         * k_idx[i] * (k_idx[i] - 1);
                            poly_add_term(&af->interior, coeff, new_exp);
                        }
                    } else {
                        if (k_idx[i] >= 1 && k_idx[j] >= 1) {
                            memcpy(new_exp, k_idx, n_dim * sizeof(int));
                            new_exp[i] -= 1;
                            new_exp[j] -= 1;
                            double coeff = term_coeff * 0.5 * Gij / (a_vec[i] * a_vec[j])
                                         * k_idx[i] * k_idx[j];
                            poly_add_term(&af->interior, coeff, new_exp);
                        }
                    }
                }
            }

            /* First derivatives: sum_i mu_i/a_i * d/dt_i */
            for (int i = 0; i < n_dim; i++) {
                if (fabs(mu[i]) < TOLERANCE || k_idx[i] < 1) continue;
                memcpy(new_exp, k_idx, n_dim * sizeof(int));
                new_exp[i] -= 1;
                double coeff = term_coeff * (mu[i] / a_vec[i]) * k_idx[i];
                poly_add_term(&af->interior, coeff, new_exp);
            }

            /* Boundary operators: D_face f = sum_i v_i/a_i * df/dt_i at boundary */
            for (int face = 0; face < 2 * n_dim; face++) {
                int bnd_k = face / 2;
                int is_lower = (face % 2 == 0);

                for (int i = 0; i < n_dim; i++) {
                    double vi = R[i * 2 * n_dim + face];
                    if (fabs(vi) < TOLERANCE || k_idx[i] < 1) continue;

                    memcpy(new_exp, k_idx, n_dim * sizeof(int));
                    new_exp[i] -= 1;

                    double coeff;
                    if (is_lower) {
                        /* At t_k = 0: vanishes unless exponent of t_k is 0 */
                        if (new_exp[bnd_k] != 0) continue;
                        coeff = term_coeff * (vi / a_vec[i]) * k_idx[i];
                    } else {
                        /* At t_k = 1: 1^{new_exp[k]} = 1 always */
                        coeff = term_coeff * (vi / a_vec[i]) * k_idx[i];
                    }

                    int boundary_exp[MAX_DIM];
                    int idx = 0;
                    for (int d = 0; d < n_dim; d++) {
                        if (d != bnd_k)
                            boundary_exp[idx++] = new_exp[d];
                    }

                    poly_add_term(&af->boundaries[face], coeff, boundary_exp);
                }
            }
        }

        /* Advance multi-index iterator */
        int carry = 1;
        for (int d = n_dim - 1; d >= 0 && carry; d--) {
            k_idx[d]++;
            if (k_idx[d] > alpha[d]) {
                k_idx[d] = 0;
            } else {
                carry = 0;
            }
        }
        if (carry) break;
    }

    /* Consolidate all polynomials to merge like terms */
    poly_consolidate(&af->interior);
    for (int face = 0; face < 2 * n_dim; face++)
        poly_consolidate(&af->boundaries[face]);
}

/* ============================================================================
 * Inner product computation
 * ============================================================================ */

/* Compute integral of polynomial over hypercube (power-table accelerated) */
static double integrate_polynomial(const Polynomial *p, const PowerTable *pt) {
    double result = 0.0;

    for (int i = 0; i < p->n_terms; i++) {
        double term_val = p->terms[i].coeff;
        for (int d = 0; d < pt->n_dim; d++) {
            int exp = p->terms[i].exponents[d];
            term_val *= pt->div[d][exp];
        }
        result += term_val;
    }

    return result;
}

/* Compute integral of product of two polynomials over hypercube */
static double integrate_product(const Polynomial *p, const Polynomial *q,
                               const PowerTable *pt) {
    double result = 0.0;

    for (int i = 0; i < p->n_terms; i++) {
        for (int j = 0; j < q->n_terms; j++) {
            double term_val = p->terms[i].coeff * q->terms[j].coeff;
            for (int d = 0; d < pt->n_dim; d++) {
                int exp_sum = p->terms[i].exponents[d] + q->terms[j].exponents[d];
                term_val *= pt->div[d][exp_sum];
            }
            result += term_val;
        }
    }

    return result;
}

double inner_product(const AfFunction *f, const AfFunction *g,
                     const PowerTable *pt, const PowerTable *pt_bnd) {
    double ip = 0.0;
    int n_dim = pt->n_dim;

    /* Interior contribution */
    ip += integrate_product(&f->interior, &g->interior, pt);

    /* Boundary contributions */
    for (int face = 0; face < 2 * n_dim; face++) {
        int k = face / 2;
        int n_dim_boundary = n_dim - 1;

        if (n_dim_boundary > 0) {
            ip += integrate_product(&f->boundaries[face], &g->boundaries[face],
                                   &pt_bnd[k]);
        } else {
            /* 1D case: boundary is a point, just multiply coefficients */
            if (f->boundaries[face].n_terms > 0 && g->boundaries[face].n_terms > 0) {
                double f_val = 0, g_val = 0;
                for (int i = 0; i < f->boundaries[face].n_terms; i++) {
                    f_val += f->boundaries[face].terms[i].coeff;
                }
                for (int i = 0; i < g->boundaries[face].n_terms; i++) {
                    g_val += g->boundaries[face].terms[i].coeff;
                }
                ip += f_val * g_val;
            }
        }
    }

    return ip;
}

/* ============================================================================
 * Gram-Schmidt orthogonalization (parallelized)
 * ============================================================================ */

void gram_schmidt(AfFunction *Af_list, int n_basis,
                  const PowerTable *pt, const PowerTable *pt_bnd,
                  AfFunction *ortho_basis) {

    for (int i = 0; i < n_basis; i++) {
        if (i % 50 == 0 && i > 0 && !g_compact) {
            fprintf(stderr, "  Gram-Schmidt: processing basis %d/%d\n", i, n_basis);
        }

        /* Start with Af_i */
        af_copy(&ortho_basis[i], &Af_list[i]);

        /* Subtract projections onto previous orthonormal vectors */
        /* Use Modified Gram-Schmidt with re-orthogonalization for better numerical stability */
        for (int pass = 0; pass < 2; pass++) {  /* Two passes for re-orthogonalization */
            for (int j = 0; j < i; j++) {
                double ip = inner_product(&ortho_basis[i], &ortho_basis[j], pt, pt_bnd);
                if (fabs(ip) > TOLERANCE) {
                    af_subtract_scaled(&ortho_basis[i], &ortho_basis[i], &ortho_basis[j], ip);
                }
            }
        }

        /* Normalize */
        double norm_sq = inner_product(&ortho_basis[i], &ortho_basis[i], pt, pt_bnd);
        if (norm_sq > TOLERANCE) {
            af_scale(&ortho_basis[i], 1.0 / sqrt(norm_sq));
        }
    }
}

/* ============================================================================
 * Main solver
 * ============================================================================ */

int srbm_solve(const SRBMParams *params, SRBMResult *result) {
    int n_dim = params->n_dim;

    if (!g_compact)
        fprintf(stderr, "SRBM solver: n=%d dimensions, order=%d\n",
                n_dim, params->n_approx);

    /* Validate reflection matrix */
    int has_warnings = 0;
    for (int k = 0; k < n_dim; k++) {
        int face_lower = 2 * k;
        int face_upper = 2 * k + 1;
        double v_k_lower = params->R[k * 2 * n_dim + face_lower];
        double v_k_upper = params->R[k * 2 * n_dim + face_upper];

        /* Check that lower boundary pushes in +x_k direction */
        if (v_k_lower <= 0) {
            fprintf(stderr, "WARNING: Face x_%d=0 has non-positive normal component (R[%d,%d]=%.2f)\n",
                    k + 1, k, face_lower, v_k_lower);
            fprintf(stderr, "         This is a skew reflection - algorithm may not converge properly.\n");
            has_warnings = 1;
        }
        /* Check that upper boundary pushes in -x_k direction */
        if (v_k_upper >= 0) {
            fprintf(stderr, "WARNING: Face x_%d=a_%d has non-negative normal component (R[%d,%d]=%.2f)\n",
                    k + 1, k + 1, k, face_upper, v_k_upper);
            fprintf(stderr, "         This is a skew reflection - algorithm may not converge properly.\n");
            has_warnings = 1;
        }
    }
    if (has_warnings) {
        fprintf(stderr, "\n");
    }

    /* Generate multi-indices */
    int n_basis;
    int *multi_indices = generate_multi_indices(n_dim, params->n_approx, &n_basis);
    if (!multi_indices) {
        return -1;
    }
    if (!g_compact)
        fprintf(stderr, "Basis dimension: %d\n", n_basis);
    result->basis_dim = n_basis;

    /* Memory guardrail: the dominant downstream allocation is the
       Gram matrix (n_basis x n_basis dense doubles). Catch oversize
       configurations before the OS thrashes. */
    {
        uint64_t bytes = (uint64_t) n_basis * (uint64_t) n_basis
                       * (uint64_t) sizeof(double);
        bnet_memcheck_alloc(bytes,
            "SRBM finite-buffer Gram matrix",
            "reduce polynomial-approximation order (n_approx) or "
            "network dimension (d); basis dimension grows as "
            "C(n_approx+d, d)");
    }

    /* Allocate Af list */
    AfFunction *Af_list = (AfFunction *)malloc(n_basis * sizeof(AfFunction));
    if (!Af_list) {
        free(multi_indices);
        return -1;
    }

    /* Compute all A*f_alpha (parallelized) */
    if (!g_compact)
        fprintf(stderr, "Computing A*f basis functions%s...\n",
                g_use_legendre ? " (Legendre basis)" : "");

    LegendreTable leg_table;
    if (g_use_legendre)
        legendre_table_init(&leg_table, params->n_approx);

    #pragma omp parallel for schedule(dynamic)
    for (int i = 0; i < n_basis; i++) {
        af_init(&Af_list[i], n_dim);
        if (g_use_legendre)
            compute_Af_legendre(multi_indices + i * n_dim, params, &leg_table, &Af_list[i]);
        else
            compute_Af(multi_indices + i * n_dim, params, &Af_list[i]);
    }

    /* Build power tables */
    int max_exp = 2 * params->n_approx + 1;
    PowerTable pt_interior;
    if (g_use_legendre)
        init_power_table_legendre(&pt_interior, params->a_vec, n_dim, max_exp);
    else
        init_power_table(&pt_interior, params->a_vec, n_dim, max_exp);

    PowerTable pt_bnd[MAX_DIM];
    for (int k = 0; k < n_dim; k++) {
        double a_bnd[MAX_DIM];
        int bi = 0;
        for (int d = 0; d < n_dim; d++) {
            if (d != k) a_bnd[bi++] = params->a_vec[d];
        }
        if (n_dim > 1) {
            if (g_use_legendre)
                init_power_table_legendre(&pt_bnd[k], a_bnd, n_dim - 1, max_exp);
            else
                init_power_table(&pt_bnd[k], a_bnd, n_dim - 1, max_exp);
        }
    }

    /* Create phi_0 = 1 in interior, 0 on boundary */
    AfFunction phi0;
    af_init(&phi0, n_dim);
    int zero_exp[MAX_DIM] = {0};
    poly_add_term(&phi0.interior, 1.0, zero_exp);

    /* Gram-Schmidt orthogonalization */
    if (!g_compact)
        fprintf(stderr, "Performing Gram-Schmidt orthogonalization...\n");
    AfFunction *ortho_basis = (AfFunction *)malloc(n_basis * sizeof(AfFunction));
    for (int i = 0; i < n_basis; i++) {
        af_init(&ortho_basis[i], n_dim);
    }

    gram_schmidt(Af_list, n_basis, &pt_interior, pt_bnd, ortho_basis);

    /* Compute projection coefficients a_i = (phi_0, phi_i) */
    double *proj_coeffs = (double *)malloc(n_basis * sizeof(double));

    #pragma omp parallel for
    for (int i = 0; i < n_basis; i++) {
        proj_coeffs[i] = inner_product(&phi0, &ortho_basis[i], &pt_interior, pt_bnd);
    }

    /* Compute normalization constant alpha (interior integral only) */
    double alpha = 1.0;
    for (int d = 0; d < n_dim; d++) {
        alpha *= params->a_vec[d];  /* Volume of hypercube */
    }

    for (int i = 0; i < n_basis; i++) {
        double int_phi_i = integrate_polynomial(&ortho_basis[i].interior, &pt_interior);
        alpha -= proj_coeffs[i] * int_phi_i;
    }
    result->alpha = alpha;
    if (!g_compact)
        fprintf(stderr, "Solver complete. alpha = %f\n", alpha);

    /* Compute expected values q_k = E[X_k].
     *
     * SEMANTICS — IMPORTANT (must match fBNAsim):
     *   x_k is the SRBM state variable on [0, a_k]. Per Dai-Harrison's
     *   heavy-traffic theory, x_k represents the TOTAL occupancy at
     *   station k — buffer customers PLUS the customer in service.
     *   The lower-boundary local time delta(x_k=0) is the cumulative
     *   server idle time; this only makes physical sense when x_k
     *   counts the in-service customer (else x_k=0 would be ambiguous
     *   between "buffer empty, server idle" and "buffer empty, server
     *   busy"). The drift formula theta = alpha - c (arrival minus
     *   service rate) likewise assumes the server is busy whenever
     *   x_k > 0, which only holds when x_k tracks total occupancy.
     *
     *   The GUI exporter sets a_k = bufferSize[k], where bufferSize
     *   is the GUI's notion of TOTAL station capacity (buffer waiting
     *   slots + server slot). For a single-server station, bufferSize
     *   = waiting_room + 1; the simulator subtracts 1 to recover the
     *   waiting-room-only buffer_size it parses internally.
     *
     *   To make sim output comparable, fBNAsim/stats.c reports E[X_k]
     *   as (avg_buffer + utilization) — i.e., total occupancy — in
     *   stats_print_gui / stats_print_compact / the trailing block of
     *   stats_print_summary. Per-station sojourn = q[k] / Gamma_k is
     *   therefore TOTAL time at station k (wait + service), which
     *   matches what fBNAsim's stats_print_gui now prints under the
     *   same label.
     */
    result->q = (double *)malloc(n_dim * sizeof(double));

    for (int k = 0; k < n_dim; k++) {
        /* Integral of x_k over hypercube = (a_k^2/2) * prod(a_j for j != k) */
        double int_xk_phi0 = pt_interior.div[k][1]; /* a_k^2/2 */
        for (int d = 0; d < n_dim; d++) {
            if (d != k) int_xk_phi0 *= params->a_vec[d];
        }

        double int_xk_proj = 0.0;
        for (int i = 0; i < n_basis; i++) {
            /* Integral of x_k * phi_i over interior */
            double term = 0.0;
            const Polynomial *p = &ortho_basis[i].interior;
            for (int t = 0; t < p->n_terms; t++) {
                double val = p->terms[t].coeff;
                for (int d = 0; d < n_dim; d++) {
                    int exp = p->terms[t].exponents[d];
                    if (d == k) exp++;  /* Multiply by x_k */
                    val *= pt_interior.div[d][exp];
                }
                term += val;
            }
            int_xk_proj += proj_coeffs[i] * term;
        }

        double q_k = (int_xk_phi0 - int_xk_proj) / alpha;
        /* In Legendre t-coords, integrals give E[t_k]; multiply by a_k for E[x_k] */
        if (g_use_legendre) q_k *= params->a_vec[k];
        result->q[k] = q_k;
    }

    /* Compute boundary measures delta_i */
    result->delta = (double *)malloc(2 * n_dim * sizeof(double));

    for (int face = 0; face < 2 * n_dim; face++) {
        int k = face / 2;
        int n_dim_boundary = n_dim - 1;

        double delta_face = 0.0;
        for (int i = 0; i < n_basis; i++) {
            double int_val;
            if (n_dim_boundary > 0) {
                int_val = integrate_polynomial(&ortho_basis[i].boundaries[face],
                                              &pt_bnd[k]);
            } else {
                /* 1D case */
                int_val = 0;
                for (int t = 0; t < ortho_basis[i].boundaries[face].n_terms; t++) {
                    int_val += ortho_basis[i].boundaries[face].terms[t].coeff;
                }
            }
            delta_face -= proj_coeffs[i] * int_val;
        }
        result->delta[face] = delta_face / alpha;
    }

    /* Cleanup */
    free(multi_indices);
    free(proj_coeffs);
    af_free(&phi0);

    for (int i = 0; i < n_basis; i++) {
        af_free(&Af_list[i]);
        af_free(&ortho_basis[i]);
    }
    free(Af_list);
    free(ortho_basis);

    return 0;
}

/* ============================================================================
 * SuiteSparse-based solver (parallel Gram matrix + Cholesky)
 * ============================================================================ */

#ifdef USE_SUITESPARSE

#include "suitesparse_wrapper.h"
#include "gram_matrix.h"

int srbm_solve_suitesparse(const SRBMParams *params, SRBMResult *result) {
    int n_dim = params->n_dim;
    int status = 0;

    /* Initialize SuiteSparse */
    if (ss_init() != 0) {
        fprintf(stderr, "Error: Failed to initialize SuiteSparse\n");
        return -1;
    }

    if (!g_compact) {
        fprintf(stderr, "SRBM solver (SuiteSparse): n=%d dimensions, order=%d\n",
                n_dim, params->n_approx);
        fprintf(stderr, "Using %d threads for parallel operations\n", ss_get_num_threads());
    }

    /* Validate reflection matrix */
    int has_warnings = 0;
    for (int k = 0; k < n_dim; k++) {
        int face_lower = 2 * k;
        int face_upper = 2 * k + 1;
        double v_k_lower = params->R[k * 2 * n_dim + face_lower];
        double v_k_upper = params->R[k * 2 * n_dim + face_upper];

        if (v_k_lower <= 0) {
            fprintf(stderr, "WARNING: Face x_%d=0 has non-positive normal component (R[%d,%d]=%.2f)\n",
                    k + 1, k, face_lower, v_k_lower);
            has_warnings = 1;
        }
        if (v_k_upper >= 0) {
            fprintf(stderr, "WARNING: Face x_%d=a_%d has non-negative normal component (R[%d,%d]=%.2f)\n",
                    k + 1, k + 1, k, face_upper, v_k_upper);
            has_warnings = 1;
        }
    }
    if (has_warnings) fprintf(stderr, "\n");

    /* Generate multi-indices */
    int n_basis;
    int *multi_indices = generate_multi_indices(n_dim, params->n_approx, &n_basis);
    if (!multi_indices) {
        return -1;
    }
    if (!g_compact)
        fprintf(stderr, "Basis dimension: %d\n", n_basis);
    result->basis_dim = n_basis;

    /* Memory guardrail: the dominant downstream allocation is the
       Gram matrix (n_basis x n_basis dense doubles). Catch oversize
       configurations before the OS thrashes. */
    {
        uint64_t bytes = (uint64_t) n_basis * (uint64_t) n_basis
                       * (uint64_t) sizeof(double);
        bnet_memcheck_alloc(bytes,
            "SRBM finite-buffer Gram matrix",
            "reduce polynomial-approximation order (n_approx) or "
            "network dimension (d); basis dimension grows as "
            "C(n_approx+d, d)");
    }

    /* Allocate Af list */
    AfFunction *Af_list = (AfFunction *)malloc(n_basis * sizeof(AfFunction));
    if (!Af_list) {
        free(multi_indices);
        return -1;
    }

    /* Open the unified progress file. Total = 3 * n_basis covering the
     * three visible parallel loops (Af compute + Gram matrix rows +
     * projection coefficients). The downstream Cholesky solve is
     * opaque; the Swift wrapper continues animating a spinner appended
     * to the full bar until the binary exits. */
    srbm_progress_open((long)(3 * n_basis));

    /* Compute all A*f_alpha (parallelized) */
    if (!g_compact)
        fprintf(stderr, "Computing A*f basis functions%s...\n",
                g_use_legendre ? " (Legendre basis)" : "");

    LegendreTable leg_table_ss;
    if (g_use_legendre)
        legendre_table_init(&leg_table_ss, params->n_approx);

    #pragma omp parallel for schedule(dynamic)
    for (int i = 0; i < n_basis; i++) {
        af_init(&Af_list[i], n_dim);
        if (g_use_legendre)
            compute_Af_legendre(multi_indices + i * n_dim, params, &leg_table_ss, &Af_list[i]);
        else
            compute_Af(multi_indices + i * n_dim, params, &Af_list[i]);
        srbm_progress_tick();
    }

    /* Initialize integral caches */
    if (!g_compact)
        fprintf(stderr, "Initializing integral caches...\n");
    int max_degree = 2 * params->n_approx;  /* Products can have double the degree */

    MonomialIntegralCache *interior_cache = integral_cache_init(n_dim, max_degree, params->a_vec,
                                                               g_use_legendre);
    if (!interior_cache) {
        fprintf(stderr, "Error: Failed to allocate interior integral cache\n");
        status = -1;
        goto cleanup_af;
    }

    BoundaryIntegralCache *boundary_cache = NULL;
    if (n_dim > 1) {
        boundary_cache = boundary_cache_init(n_dim, max_degree, params->a_vec,
                                               g_use_legendre);
        if (!boundary_cache) {
            fprintf(stderr, "Error: Failed to allocate boundary integral cache\n");
            status = -1;
            goto cleanup_interior_cache;
        }
    }

    /* Allocate Gram matrix */
    if (!g_compact)
        fprintf(stderr, "Building Gram matrix (%d x %d)...\n", n_basis, n_basis);
    cholmod_dense *G = ss_alloc_dense(n_basis, n_basis);
    if (!G) {
        status = -1;
        goto cleanup_boundary_cache;
    }

    /* Build Gram matrix in parallel */
    if (build_gram_matrix(Af_list, n_basis, params->a_vec, n_dim,
                          interior_cache, boundary_cache, G) != 0) {
        status = -1;
        goto cleanup_gram;
    }

    /* Cholesky factorization */
    if (!g_compact)
        fprintf(stderr, "Computing Cholesky factorization...\n");
    cholmod_dense *L = NULL;
    if (ss_cholesky_dense(G, &L) != 0) {
        fprintf(stderr, "Error: Cholesky factorization failed\n");
        status = -1;
        goto cleanup_gram;
    }

    /* Check condition number */
    double cond = ss_estimate_condition(L);
    if (cond > 1e12) {
        fprintf(stderr, "WARNING: High condition number estimate: %.2e\n", cond);
        fprintf(stderr, "         Results may be numerically unstable\n");
    }

    /* Compute projection vector b[i] = <phi_0, Af_i> */
    if (!g_compact)
        fprintf(stderr, "Computing projection coefficients...\n");
    cholmod_dense *b = ss_alloc_dense(n_basis, 1);
    if (!b) {
        status = -1;
        goto cleanup_chol;
    }

    if (compute_projection_vector(Af_list, n_basis, interior_cache, b) != 0) {
        status = -1;
        goto cleanup_b;
    }

    /* Bar reaches 100% here. Downstream Cholesky solve is opaque;
     * the wrapper switches to a spinner appended to the full bar. */
    srbm_progress_close();

    /* Solve for orthonormal projection coefficients: c = L^{-T} * L^{-1} * b */
    cholmod_dense *c = ss_alloc_dense(n_basis, 1);
    if (!c) {
        status = -1;
        goto cleanup_b;
    }

    if (ss_solve_cholesky(L, b, c) != 0) {
        status = -1;
        goto cleanup_c;
    }

    double *proj_coeffs = ss_dense_data(c);

    /* Compute normalization constant alpha (interior integral only) */
    double alpha = 1.0;
    for (int d = 0; d < n_dim; d++) {
        alpha *= params->a_vec[d];  /* Volume of hypercube */
    }

    for (int i = 0; i < n_basis; i++) {
        double int_Af_i = integrate_polynomial_cached(&Af_list[i].interior, interior_cache);
        alpha -= proj_coeffs[i] * int_Af_i;
    }
    result->alpha = alpha;
    if (!g_compact)
        fprintf(stderr, "Solver complete. alpha = %f\n", alpha);

    /* Compute expected values q_k = E[X_k] */
    result->q = (double *)malloc(n_dim * sizeof(double));
    if (!result->q) {
        status = -1;
        goto cleanup_c;
    }

    for (int k = 0; k < n_dim; k++) {
        /* Integral of x_k (or t_k in Legendre mode) weighted by phi_0=1 */
        double int_xk_phi0;
        if (g_use_legendre) {
            /* Legendre t-coords: integral of t_k over domain = a_k/2 * prod(a_j for j!=k) */
            int_xk_phi0 = params->a_vec[k] / 2.0;
        } else {
            /* Monomial x-coords: integral of x_k over domain = a_k^2/2 */
            int_xk_phi0 = pow(params->a_vec[k], 2) / 2.0;
        }
        for (int d = 0; d < n_dim; d++) {
            if (d != k) int_xk_phi0 *= params->a_vec[d];
        }

        double int_xk_proj = 0.0;
        #pragma omp parallel for reduction(+:int_xk_proj)
        for (int i = 0; i < n_basis; i++) {
            double term = integrate_xk_times_polynomial_cached(
                &Af_list[i].interior, k, interior_cache, n_dim);
            int_xk_proj += proj_coeffs[i] * term;
        }

        double q_k = (int_xk_phi0 - int_xk_proj) / alpha;
        /* In Legendre t-coords, integrals give E[t_k]; multiply by a_k for E[x_k] */
        if (g_use_legendre) q_k *= params->a_vec[k];
        result->q[k] = q_k;
    }

    /* Compute boundary measures delta_i */
    result->delta = (double *)malloc(2 * n_dim * sizeof(double));
    if (!result->delta) {
        free(result->q);
        result->q = NULL;
        status = -1;
        goto cleanup_c;
    }

    for (int face = 0; face < 2 * n_dim; face++) {
        double delta_face = 0.0;

        if (n_dim > 1) {
            MonomialIntegralCache *face_cache = boundary_cache->face_caches[face];

            #pragma omp parallel for reduction(-:delta_face)
            for (int i = 0; i < n_basis; i++) {
                double int_val = integrate_polynomial_cached(
                    &Af_list[i].boundaries[face], face_cache);
                delta_face -= proj_coeffs[i] * int_val;
            }
        } else {
            /* 1D case */
            for (int i = 0; i < n_basis; i++) {
                double int_val = 0;
                for (int t = 0; t < Af_list[i].boundaries[face].n_terms; t++) {
                    int_val += Af_list[i].boundaries[face].terms[t].coeff;
                }
                delta_face -= proj_coeffs[i] * int_val;
            }
        }
        result->delta[face] = delta_face / alpha;
    }

    /* Cleanup */
cleanup_c:
    ss_free_dense(&c);
cleanup_b:
    ss_free_dense(&b);
cleanup_chol:
    ss_free_dense(&L);
cleanup_gram:
    ss_free_dense(&G);
cleanup_boundary_cache:
    if (boundary_cache) boundary_cache_free(boundary_cache);
cleanup_interior_cache:
    integral_cache_free(interior_cache);
cleanup_af:
    for (int i = 0; i < n_basis; i++) {
        af_free(&Af_list[i]);
    }
    free(Af_list);
    free(multi_indices);

    return status;
}

#endif /* USE_SUITESPARSE */

/* ============================================================================
 * Reflection matrix creation
 * ============================================================================ */

void create_reflection_matrix(int n_dim, const char *type, double *R) {
    /* Initialize to zero */
    memset(R, 0, n_dim * 2 * n_dim * sizeof(double));

    if (strcmp(type, "normal") == 0) {
        /* Normal reflection: +e_k on lower, -e_k on upper */
        for (int k = 0; k < n_dim; k++) {
            R[k * 2 * n_dim + 2*k] = 1.0;      /* v_{x_k=0} = e_k */
            R[k * 2 * n_dim + 2*k+1] = -1.0;   /* v_{x_k=a_k} = -e_k */
        }
    }
    else if (strcmp(type, "tandem") == 0) {
        /* Tandem queue reflection */
        for (int k = 0; k < n_dim; k++) {
            /* Lower face x_k = 0 */
            R[k * 2 * n_dim + 2*k] = 1.0;
            if (k > 0) {
                R[(k-1) * 2 * n_dim + 2*k] = -1.0;
            }

            /* Upper face x_k = a_k */
            R[k * 2 * n_dim + 2*k+1] = -1.0;
            if (k < n_dim - 1) {
                R[(k+1) * 2 * n_dim + 2*k+1] = 1.0;
            }
        }
    }
    else {
        /* Default to normal */
        create_reflection_matrix(n_dim, "normal", R);
    }
}
