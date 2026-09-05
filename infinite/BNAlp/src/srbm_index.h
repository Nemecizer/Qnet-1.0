#ifndef SRBM_INDEX_H
#define SRBM_INDEX_H

#include "srbm_types.h"

/* Enumerate multi-indices for polynomial basis of degree <= m in d variables.
 * Faithful translation of Indexing.m.
 *
 * Sets:
 *   idx->I   : [n_basis * (d+1)] array — columns 0..d-1 are variable exponents,
 *              column d is the "total degree" of the basis function.
 *   idx->N   : [m+1] cumulative counts  N[k] = #{basis functions of degree <= k}
 *   idx->n_basis = N[m]
 */
void srbm_index_build(int d, int m, srbm_index_t *idx);
void srbm_index_free(srbm_index_t *idx);

#endif /* SRBM_INDEX_H */
