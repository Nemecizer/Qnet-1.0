/*
 * qmc.h - Quasi Monte Carlo Integration Library
 *
 * ANSI C (C99) implementation based on the C++ code by Dirk Nuyens (2012).
 * Implements lattice rules for nonperiodic smooth integrands.
 *
 * References:
 *   - Dick, Nuyens, Pillichshammer: Lattice rules for nonperiodic smooth
 *     integrands
 *   - Hickernell, Kritzer, Kuo, Nuyens: Weighted compound integration rules
 *     with higher order convergence for all N
 *     (Numerical Algorithms, 59(2):161-183, 2012)
 *   - Cools, Kuo, Nuyens: Constructing embedded lattice rules for
 *     multivariate integration (SIAM J. Sci. Comput.)
 */
#ifndef QMC_H
#define QMC_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ========================================================================
 * Integrand function type
 * ======================================================================== */

/*
 * User-provided integrand function.
 *   x:         array of s coordinates in [0, 1)
 *   s:         number of dimensions
 *   user_data: arbitrary user context pointer
 *   Returns:   function value at x
 */
typedef double (*qmc_integrand_fn)(const double *x, size_t s, void *user_data);

/* ========================================================================
 * Lattice rule integration (base-2 lattice sequences)
 * ======================================================================== */

/*
 * Standard lattice rule integration.
 *
 * Evaluates the integral using a base-2 lattice sequence with the given
 * generating vector z.  At each level v (0..m), uses n = 2^v quadrature
 * points (odd indices only).
 *
 * Parameters:
 *   s         number of dimensions
 *   fun       integrand function pointer
 *   user_data passed to fun on each call
 *   z         generating vector (array of at least s unsigned ints)
 *   m         max level (0 <= m <= 20)
 *   acc       output: array of (m+1) doubles (partial sum per level)
 *   T_usecs   output: array of (m+1) timing values in microseconds;
 *             may be NULL if timing is not needed
 *
 * Returns: 0 on success, -1 on error (bad parameters or allocation failure)
 */
int qmc_latq_base2(size_t s, qmc_integrand_fn fun, void *user_data,
                    const unsigned int *z, unsigned int m,
                    double *acc, long long *T_usecs);

/*
 * Tent-transformed lattice rule integration.
 *
 * Same interface as qmc_latq_base2.
 * Applies the baker's (tent) transformation: x -> 1 - |2x - 1|.
 */
int qmc_lattentq_base2(size_t s, qmc_integrand_fn fun, void *user_data,
                        const unsigned int *z, unsigned int m,
                        double *acc, long long *T_usecs);

/*
 * Symmetrized lattice rule integration.
 *
 * Same interface as qmc_latq_base2.
 *
 * NOTE: This method creates 2^s symmetrized copies per lattice point,
 * so it is only practical for small s (say s <= 30).  The caller should
 * typically reduce m by (s-1) before calling, as the original code does.
 */
int qmc_latsymq_base2(size_t s, qmc_integrand_fn fun, void *user_data,
                       const unsigned int *z, unsigned int m,
                       double *acc, long long *T_usecs);

/*
 * Combine level accumulators into a single quadrature estimate.
 *
 * Given the per-level partial sums produced by any integration method
 * above, this combines them as:
 *     Q = acc[0]/2^m + acc[1]/2^(m-1) + ... + acc[m-1]/2 + acc[m]
 *
 * Parameters:
 *   acc  array of (m+1) level accumulators
 *   m    max level
 *
 * Returns: the combined quadrature estimate Q
 */
double qmc_combine_levels(const double *acc, unsigned int m);

/* ========================================================================
 * Lattice sequence generator (radical inverse ordering)
 * ======================================================================== */

#define QMC_SEQ_S_MAX  250
#define QMC_SEQ_N_MAX  (1 << 20)   /* 2^20 ~ 1 million points */

typedef struct {
    uint32_t k;                     /* current index into the sequence */
    double   phi_k;                 /* radical inverse (base 2) of k   */
    size_t   s;                     /* current dimensionality          */
    double   x[QMC_SEQ_S_MAX];     /* current lattice point           */
} qmc_lattice_seq_t;

/*
 * Initialize a lattice sequence.
 *   seq  pointer to caller-allocated sequence struct
 *   s    dimensionality (1..250; pass 0 to use maximum 250)
 *   k    starting index (usually 0)
 * Returns: 0 on success, -1 if s > 250
 */
int qmc_lattice_seq_init(qmc_lattice_seq_t *seq, size_t s, uint32_t k);

/*
 * Advance to the next point in the sequence.
 * The new point is stored in seq->x[0..seq->s-1].
 * Returns: 0 on success, -1 if sequence is exhausted (k >= 2^20)
 */
int qmc_lattice_seq_next(qmc_lattice_seq_t *seq);

/*
 * Update the dimensionality.
 * If increased, recalculates the current point for the new dimensions.
 * Returns: 0 on success, -1 if s is 0 or > 250
 */
int qmc_lattice_seq_set_dim(qmc_lattice_seq_t *seq, size_t s);

/*
 * Get the current dimensionality.
 */
size_t qmc_lattice_seq_get_dim(const qmc_lattice_seq_t *seq);

/* ========================================================================
 * Utility functions
 * ======================================================================== */

/*
 * Compute the radical inverse in base 2 of a 32-bit unsigned integer.
 * Returns a value in [0, 1).
 */
double qmc_radical_inverse_base2(uint32_t k);

/* ========================================================================
 * Built-in generating vectors
 * ======================================================================== */

/*
 * 10-dimensional generating vector for lattice rules (smoothness 3).
 * From Hickernell, Kritzer, Kuo, Nuyens (Numerical Algorithms, 2012).
 */
extern const unsigned int qmc_z10[10];

/*
 * 250-dimensional generating vector for lattice sequences.
 * From Cools, Kuo, Nuyens (SIAM J. Sci. Comput.).
 * These are doubles because they are used with the radical inverse
 * function (phi_k * z[j] mod 1) rather than integer modular arithmetic.
 */
extern const double qmc_z250_ckn[QMC_SEQ_S_MAX];

#ifdef __cplusplus
}
#endif

#endif /* QMC_H */
