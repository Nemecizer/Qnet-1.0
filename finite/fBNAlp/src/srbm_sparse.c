/*
 * srbm_sparse.c – COO triplet accumulator → CSC converter.
 */
#include "srbm_sparse.h"
#include "srbm_mem.h"
#include <string.h>

void srbm_coo_init(srbm_coo_t *coo, int nrows, int ncols, int initial_cap)
{
    coo->nrows    = nrows;
    coo->ncols    = ncols;
    coo->nnz      = 0;
    coo->capacity = (initial_cap > 64) ? initial_cap : 64;
    coo->row = (int *)   srbm_malloc((size_t)coo->capacity * sizeof(int));
    coo->col = (int *)   srbm_malloc((size_t)coo->capacity * sizeof(int));
    coo->val = (double *)srbm_malloc((size_t)coo->capacity * sizeof(double));
}

void srbm_coo_push(srbm_coo_t *coo, int row, int col, double val)
{
    if (coo->nnz >= coo->capacity) {
        coo->capacity *= 2;
        coo->row = (int *)   srbm_realloc(coo->row, (size_t)coo->capacity * sizeof(int));
        coo->col = (int *)   srbm_realloc(coo->col, (size_t)coo->capacity * sizeof(int));
        coo->val = (double *)srbm_realloc(coo->val, (size_t)coo->capacity * sizeof(double));
    }
    coo->row[coo->nnz] = row;
    coo->col[coo->nnz] = col;
    coo->val[coo->nnz] = val;
    coo->nnz++;
}

/* Simple counting sort by column to build CSC.
 * Duplicates with same (row, col) are summed. */
void srbm_coo_to_csc(const srbm_coo_t *coo,
                     int *col_start, int *row_idx, double *vals)
{
    int ncols = coo->ncols;
    int nnz   = coo->nnz;

    /* Count entries per column */
    memset(col_start, 0, ((size_t)ncols + 1) * sizeof(int));
    for (int k = 0; k < nnz; k++)
        col_start[coo->col[k] + 1]++;

    /* Prefix sum */
    for (int c = 0; c < ncols; c++)
        col_start[c + 1] += col_start[c];

    /* Scatter into CSC arrays using a work copy of col_start */
    int *pos = (int *)srbm_malloc((size_t)ncols * sizeof(int));
    memcpy(pos, col_start, (size_t)ncols * sizeof(int));

    for (int k = 0; k < nnz; k++) {
        int c = coo->col[k];
        int p = pos[c]++;
        row_idx[p] = coo->row[k];
        vals[p]    = coo->val[k];
    }

    srbm_free(pos);

    /* Sort rows within each column and sum duplicates */
    for (int c = 0; c < ncols; c++) {
        int start = col_start[c];
        int end   = col_start[c + 1];
        /* Insertion sort (columns are typically short) */
        for (int i = start + 1; i < end; i++) {
            int   ri = row_idx[i];
            double vi = vals[i];
            int j = i - 1;
            while (j >= start && row_idx[j] > ri) {
                row_idx[j + 1] = row_idx[j];
                vals[j + 1]    = vals[j];
                j--;
            }
            row_idx[j + 1] = ri;
            vals[j + 1]    = vi;
        }
        /* Sum duplicates */
        int w = start;
        for (int i = start; i < end; i++) {
            if (w > start && row_idx[i] == row_idx[w - 1]) {
                vals[w - 1] += vals[i];
            } else {
                row_idx[w] = row_idx[i];
                vals[w]    = vals[i];
                w++;
            }
        }
        /* Shift remainder if duplicates were merged */
        if (w < end) {
            int removed = end - w;
            /* Shift all subsequent data left by 'removed' */
            int total_after = col_start[ncols] - end;
            if (total_after > 0) {
                memmove(&row_idx[w], &row_idx[end], total_after * sizeof(int));
                memmove(&vals[w],    &vals[end],    total_after * sizeof(double));
            }
            /* Update col_start for all subsequent columns */
            for (int cc = c + 1; cc <= ncols; cc++)
                col_start[cc] -= removed;
        }
    }
}

void srbm_coo_free(srbm_coo_t *coo)
{
    srbm_free(coo->row);
    srbm_free(coo->col);
    srbm_free(coo->val);
    coo->row = NULL;
    coo->col = NULL;
    coo->val = NULL;
    coo->nnz = 0;
    coo->capacity = 0;
}
