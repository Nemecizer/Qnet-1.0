#ifndef SRBM_OUTPUT_H
#define SRBM_OUTPUT_H

#include "srbm_types.h"

/* Compute moments E[Z_j^k] for k=1..max_k, j=1..d.
 * EM is [max_k * d], EM[k*d + j] = E[Z_{j+1}^{k+1}].
 * Caller allocates EM. */
void srbm_moments(const double *pd, const double *P,
                  int npoints, int d, int max_k, double *EM);

/* Extract marginal densities (ETRBM.m).
 * For each coordinate j, sorts grid values and aggregates probability.
 * ez[j] and epx[j] are allocated by this function.
 * counts[j] is the number of distinct grid values for coordinate j. */
void srbm_marginals(const double *pd, const double *P,
                    int npoints, int n, int d,
                    double **ez, double **epx, int *counts);

/* Smooth marginal densities (SETRBM.m).
 * spx[j] is [counts[j]], allocated by this function. */
void srbm_smooth_marginals(double **epx, int d, const int *counts,
                           double **spx);

/* Write moments to stdout. */
void srbm_print_moments(const double *EM, int max_k, int d);

/* Write marginal distributions to CSV files.
 * Prefix is the output file prefix (e.g. "output"), files will be
 * "<prefix>_marginal_j.csv". */
void srbm_write_marginals_csv(const char *prefix, double **ez, double **spx,
                              int d, const int *counts);

/* Write interior distribution to CSV. */
void srbm_write_distribution_csv(const char *prefix, const double *pd,
                                 const double *P, int npoints, int d);

/* Free marginal arrays. */
void srbm_marginals_free(double **ez, double **epx, double **spx, int d);

#endif /* SRBM_OUTPUT_H */
