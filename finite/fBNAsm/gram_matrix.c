/*
 * gram_matrix.c - Gram matrix operations for SRBM solver
 *
 * Parallel construction of Gram matrices with monomial integral caching.
 */

#ifdef USE_SUITESPARSE

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#ifdef _OPENMP
#include <omp.h>
#endif

#include "gram_matrix.h"

#define TOLERANCE 1e-14

/* ============================================================================
 * Monomial Integral Cache
 * ============================================================================ */

static int compute_cache_size(int n_dim, int max_degree) {
    /* Total entries: (max_degree + 1)^n_dim */
    int size = 1;
    for (int d = 0; d < n_dim; d++) {
        size *= (max_degree + 1);
    }
    return size;
}

static int exponents_to_index(const int *exponents, const int *strides, int n_dim) {
    int index = 0;
    for (int d = 0; d < n_dim; d++) {
        index += exponents[d] * strides[d];
    }
    return index;
}

static double compute_monomial_integral(const int *exponents, const double *a_vec,
                                        int n_dim, int normalized) {
    double result = 1.0;
    if (normalized) {
        /* Legendre t-coordinate integral: prod_d (a_d / (e_d + 1))
         * This is integral of t^e over [0,a] where t_d = x_d/a_d */
        for (int d = 0; d < n_dim; d++)
            result *= a_vec[d] / (exponents[d] + 1);
    } else {
        /* Standard monomial integral: prod_d (a_d^(e_d+1) / (e_d + 1)) */
        for (int d = 0; d < n_dim; d++) {
            int e = exponents[d];
            result *= pow(a_vec[d], e + 1) / (e + 1);
        }
    }
    return result;
}

MonomialIntegralCache* integral_cache_init(int n_dim, int max_degree, const double *a_vec,
                                           int normalized) {
    MonomialIntegralCache *cache = (MonomialIntegralCache*)malloc(sizeof(MonomialIntegralCache));
    if (!cache) return NULL;

    cache->n_dim = n_dim;
    cache->max_degree = max_degree;
    cache->normalized = normalized;
    cache->total_size = compute_cache_size(n_dim, max_degree);

    /* Compute strides for index calculation */
    cache->strides = (int*)malloc(n_dim * sizeof(int));
    if (!cache->strides) {
        free(cache);
        return NULL;
    }

    cache->strides[0] = 1;
    for (int d = 1; d < n_dim; d++) {
        cache->strides[d] = cache->strides[d-1] * (max_degree + 1);
    }

    /* Allocate cache array */
    cache->cache = (double*)malloc(cache->total_size * sizeof(double));
    if (!cache->cache) {
        free(cache->strides);
        free(cache);
        return NULL;
    }

    /* Precompute all integrals */
    int *exponents = (int*)calloc(n_dim, sizeof(int));

    for (int idx = 0; idx < cache->total_size; idx++) {
        /* Convert index to exponents */
        int temp_idx = idx;
        for (int d = n_dim - 1; d >= 0; d--) {
            exponents[d] = temp_idx / cache->strides[d];
            temp_idx = temp_idx % cache->strides[d];
        }

        cache->cache[idx] = compute_monomial_integral(exponents, a_vec, n_dim, normalized);
    }

    free(exponents);
    return cache;
}

void integral_cache_free(MonomialIntegralCache *cache) {
    if (cache) {
        if (cache->cache) free(cache->cache);
        if (cache->strides) free(cache->strides);
        free(cache);
    }
}

double integral_cache_get(const MonomialIntegralCache *cache, const int *exponents) {
    /* Check bounds */
    for (int d = 0; d < cache->n_dim; d++) {
        if (exponents[d] < 0 || exponents[d] > cache->max_degree) {
            /* Out of cache range - compute directly */
            fprintf(stderr, "Warning: exponent %d exceeds cache max_degree %d\n",
                    exponents[d], cache->max_degree);
            return 0.0;  /* Should not happen with proper cache sizing */
        }
    }

    int index = exponents_to_index(exponents, cache->strides, cache->n_dim);
    return cache->cache[index];
}

/* ============================================================================
 * Boundary Integral Cache
 * ============================================================================ */

BoundaryIntegralCache* boundary_cache_init(int n_dim, int max_degree, const double *a_vec,
                                           int normalized) {
    if (n_dim < 2) return NULL;  /* 1D case doesn't need boundary cache */

    BoundaryIntegralCache *cache = (BoundaryIntegralCache*)malloc(sizeof(BoundaryIntegralCache));
    if (!cache) return NULL;

    cache->n_dim = n_dim;
    cache->n_faces = 2 * n_dim;
    cache->face_caches = (MonomialIntegralCache**)calloc(cache->n_faces, sizeof(MonomialIntegralCache*));

    if (!cache->face_caches) {
        free(cache);
        return NULL;
    }

    /* Create cache for each face */
    for (int face = 0; face < cache->n_faces; face++) {
        int k = face / 2;  /* Which dimension is fixed on this face */

        /* Create a_boundary by removing dimension k */
        double a_boundary[MAX_DIM];
        int idx = 0;
        for (int d = 0; d < n_dim; d++) {
            if (d != k) {
                a_boundary[idx++] = a_vec[d];
            }
        }

        cache->face_caches[face] = integral_cache_init(n_dim - 1, max_degree, a_boundary, normalized);
        if (!cache->face_caches[face]) {
            boundary_cache_free(cache);
            return NULL;
        }
    }

    return cache;
}

void boundary_cache_free(BoundaryIntegralCache *cache) {
    if (cache) {
        if (cache->face_caches) {
            for (int i = 0; i < cache->n_faces; i++) {
                if (cache->face_caches[i]) {
                    integral_cache_free(cache->face_caches[i]);
                }
            }
            free(cache->face_caches);
        }
        free(cache);
    }
}

double boundary_cache_get(const BoundaryIntegralCache *cache, int face,
                          const int *exponents) {
    if (!cache || !cache->face_caches[face]) return 0.0;
    return integral_cache_get(cache->face_caches[face], exponents);
}

/* ============================================================================
 * Cached Integration
 * ============================================================================ */

double integrate_polynomial_cached(const Polynomial *p,
                                   const MonomialIntegralCache *cache) {
    double result = 0.0;

    for (int i = 0; i < p->n_terms; i++) {
        double val = p->terms[i].coeff * integral_cache_get(cache, p->terms[i].exponents);
        result += val;
    }

    return result;
}

double integrate_product_cached(const Polynomial *p, const Polynomial *q,
                                const MonomialIntegralCache *cache) {
    double result = 0.0;
    int sum_exp[MAX_DIM];
    int n_dim = cache->n_dim;

    for (int i = 0; i < p->n_terms; i++) {
        for (int j = 0; j < q->n_terms; j++) {
            double coeff = p->terms[i].coeff * q->terms[j].coeff;

            if (fabs(coeff) < TOLERANCE) continue;

            /* Sum exponents */
            for (int d = 0; d < n_dim; d++) {
                sum_exp[d] = p->terms[i].exponents[d] + q->terms[j].exponents[d];
            }

            result += coeff * integral_cache_get(cache, sum_exp);
        }
    }

    return result;
}

double inner_product_cached(const AfFunction *f, const AfFunction *g,
                            const MonomialIntegralCache *interior_cache,
                            const BoundaryIntegralCache *boundary_cache,
                            int n_dim) {
    double ip = 0.0;

    /* Interior contribution */
    ip += integrate_product_cached(&f->interior, &g->interior, interior_cache);

    /* Boundary contributions */
    for (int face = 0; face < 2 * n_dim; face++) {
        if (boundary_cache && n_dim > 1) {
            MonomialIntegralCache *face_cache = boundary_cache->face_caches[face];
            ip += integrate_product_cached(&f->boundaries[face], &g->boundaries[face],
                                          face_cache);
        } else if (n_dim == 1) {
            /* 1D case: boundary is a point, just multiply coefficients */
            double f_val = 0.0, g_val = 0.0;
            for (int i = 0; i < f->boundaries[face].n_terms; i++) {
                f_val += f->boundaries[face].terms[i].coeff;
            }
            for (int i = 0; i < g->boundaries[face].n_terms; i++) {
                g_val += g->boundaries[face].terms[i].coeff;
            }
            ip += f_val * g_val;
        }
    }

    return ip;
}

double integrate_xk_times_polynomial_cached(const Polynomial *p, int k,
                                            const MonomialIntegralCache *cache,
                                            int n_dim) {
    double result = 0.0;
    int modified_exp[MAX_DIM];

    for (int i = 0; i < p->n_terms; i++) {
        double coeff = p->terms[i].coeff;
        if (fabs(coeff) < TOLERANCE) continue;

        /* Multiply by x_k means incrementing exponent k */
        memcpy(modified_exp, p->terms[i].exponents, n_dim * sizeof(int));
        modified_exp[k] += 1;

        result += coeff * integral_cache_get(cache, modified_exp);
    }

    return result;
}

/* ============================================================================
 * Gram Matrix Construction
 * ============================================================================ */

/* Forward-declared in srbm_solver.c; called once per outer iteration
 * here to drive the unified -P progress bar. No-op when -P is unset. */
extern void srbm_progress_tick(void);

int build_gram_matrix(AfFunction *Af_list, int n_basis,
                      const double *a_vec, int n_dim,
                      const MonomialIntegralCache *interior_cache,
                      const BoundaryIntegralCache *boundary_cache,
                      cholmod_dense *G) {
    (void)a_vec;  /* Integration uses cached values, a_vec was used in cache init */
    if (!Af_list || !G || !interior_cache) return -1;

    /* Gram matrix is symmetric: G[i,j] = <Af_i, Af_j>
     * Only compute upper triangle and mirror
     */

    int total_pairs = (n_basis * (n_basis + 1)) / 2;
    fprintf(stderr, "Building Gram matrix: %d basis functions, %d unique pairs\n",
            n_basis, total_pairs);

    /* Parallel construction of Gram matrix */
    /* Use dynamic scheduling since inner products may vary in cost */
#ifdef _OPENMP
    #pragma omp parallel for schedule(dynamic, 16)
#endif
    for (int i = 0; i < n_basis; i++) {
        for (int j = i; j < n_basis; j++) {
            double ip = inner_product_cached(&Af_list[i], &Af_list[j],
                                             interior_cache, boundary_cache, n_dim);

            /* Column-major storage for CHOLMOD */
            ss_dense_set(G, i, j, ip);
            if (i != j) {
                ss_dense_set(G, j, i, ip);  /* Mirror for symmetric */
            }
        }
        srbm_progress_tick();
    }

    return 0;
}

int compute_projection_vector(AfFunction *Af_list, int n_basis,
                              const MonomialIntegralCache *cache,
                              cholmod_dense *b) {
    if (!Af_list || !b || !cache) return -1;

    /* b[i] = <phi_0, Af_i> where phi_0 = 1 (constant)
     * This is just the integral of Af_i.interior over the hypercube
     */

#ifdef _OPENMP
    #pragma omp parallel for schedule(static)
#endif
    for (int i = 0; i < n_basis; i++) {
        double val = integrate_polynomial_cached(&Af_list[i].interior, cache);
        ss_dense_set(b, i, 0, val);
        srbm_progress_tick();
    }

    return 0;
}

#endif /* USE_SUITESPARSE */
