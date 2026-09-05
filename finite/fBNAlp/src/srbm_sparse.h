#ifndef SRBM_SPARSE_H
#define SRBM_SPARSE_H

#include <stddef.h>

/* COO (coordinate) triplet accumulator → CSC converter.
 * Build by appending triplets, then convert to CSC. */

typedef struct {
    int     nrows;
    int     ncols;
    int     nnz;        /* current number of stored triplets */
    int     capacity;   /* allocated capacity */
    int    *row;        /* row indices [capacity] */
    int    *col;        /* col indices [capacity] */
    double *val;        /* values [capacity] */
} srbm_coo_t;

/* Initialize a COO accumulator. initial_cap is hint for pre-allocation. */
void srbm_coo_init(srbm_coo_t *coo, int nrows, int ncols, int initial_cap);

/* Append a single triplet. Grows if needed. */
void srbm_coo_push(srbm_coo_t *coo, int row, int col, double val);

/* Convert COO to CSC arrays.  The caller-allocated arrays must have:
 *   col_start[ncols+1], row_idx[nnz], vals[nnz].
 * Triplets with duplicate (row,col) are summed. */
void srbm_coo_to_csc(const srbm_coo_t *coo,
                     int *col_start, int *row_idx, double *vals);

void srbm_coo_free(srbm_coo_t *coo);

#endif /* SRBM_SPARSE_H */
