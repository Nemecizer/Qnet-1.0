/*
 * gram_matrix.h - Gram matrix operations for SRBM solver
 *
 * Provides efficient parallel construction of Gram matrices
 * with monomial integral caching.
 */

#ifndef GRAM_MATRIX_H
#define GRAM_MATRIX_H

#ifdef USE_SUITESPARSE

#include <cholmod.h>
#include "srbm_types.h"
#include "suitesparse_wrapper.h"

/*
 * Monomial Integral Cache
 *
 * For polynomials of degree up to max_order, the product of two terms
 * has degree up to 2*max_order. We cache all integrals of monomials
 * x^alpha over the hypercube [0,a_1] x ... x [0,a_n].
 *
 * Integral of x^alpha = prod_d (a_d^(alpha_d + 1) / (alpha_d + 1))
 */
typedef struct {
    double *cache;              /* Precomputed integrals */
    int *strides;               /* Strides for converting exponent tuple to index */
    int max_degree;             /* Maximum degree per dimension (2 * n_approx) */
    int n_dim;                  /* Number of dimensions */
    int total_size;             /* Total cache size */
    int normalized;             /* If 1, integrals use a_d/(e+1) instead of a_d^(e+1)/(e+1) */
} MonomialIntegralCache;

/* Initialize integral cache for all monomials up to given max degree
 * max_degree should be 2 * n_approx to handle products
 * If normalized=1, uses Legendre-normalized formula: prod(a_d/(e_d+1))
 * instead of standard monomial formula: prod(a_d^(e_d+1)/(e_d+1))
 */
MonomialIntegralCache* integral_cache_init(int n_dim, int max_degree, const double *a_vec,
                                           int normalized);

/* Free integral cache */
void integral_cache_free(MonomialIntegralCache *cache);

/* Get cached integral of monomial x^exponents over hypercube
 * Returns integral value, or computes it if not cached
 */
double integral_cache_get(const MonomialIntegralCache *cache,
                          const int *exponents);

/*
 * Boundary integral cache - for reduced dimension boundaries
 * Each face k has dimension n_dim-1 (excludes dimension k)
 */
typedef struct {
    MonomialIntegralCache **face_caches;  /* Array of 2*n_dim caches */
    int n_dim;
    int n_faces;
} BoundaryIntegralCache;

/* Initialize boundary caches */
BoundaryIntegralCache* boundary_cache_init(int n_dim, int max_degree, const double *a_vec,
                                           int normalized);

/* Free boundary caches */
void boundary_cache_free(BoundaryIntegralCache *cache);

/* Get cached integral for a specific boundary face */
double boundary_cache_get(const BoundaryIntegralCache *cache, int face,
                          const int *exponents);

/*
 * Gram Matrix Construction
 */

/* Build Gram matrix G[i,j] = <Af_i, Af_j> in parallel
 * G is symmetric, only upper triangle is computed and mirrored
 */
int build_gram_matrix(AfFunction *Af_list, int n_basis,
                      const double *a_vec, int n_dim,
                      const MonomialIntegralCache *interior_cache,
                      const BoundaryIntegralCache *boundary_cache,
                      cholmod_dense *G);

/*
 * Cached inner product operations
 */

/* Compute inner product using cached integrals */
double inner_product_cached(const AfFunction *f, const AfFunction *g,
                            const MonomialIntegralCache *interior_cache,
                            const BoundaryIntegralCache *boundary_cache,
                            int n_dim);

/* Integrate polynomial over hypercube using cache */
double integrate_polynomial_cached(const Polynomial *p,
                                   const MonomialIntegralCache *cache);

/* Integrate product of two polynomials using cache */
double integrate_product_cached(const Polynomial *p, const Polynomial *q,
                                const MonomialIntegralCache *cache);

/*
 * Projection coefficient computations
 */

/* Compute projection vector b[i] = <phi_0, Af_i> where phi_0 = 1
 * This is just the integral of Af_i over the hypercube
 */
int compute_projection_vector(AfFunction *Af_list, int n_basis,
                              const MonomialIntegralCache *cache,
                              cholmod_dense *b);

/* Compute integral of x_k * polynomial for expected value computation */
double integrate_xk_times_polynomial_cached(const Polynomial *p, int k,
                                            const MonomialIntegralCache *cache,
                                            int n_dim);

#endif /* USE_SUITESPARSE */

#endif /* GRAM_MATRIX_H */
