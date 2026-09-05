/*
 * BNA/FM Algorithm - Common Implementation
 *
 * Contains: input parsing, sparse matrix operations (SuiteSparse),
 * linear solvers, and Hermite basis function evaluation.
 */

#include "bna_fm.h"
#include <omp.h>
#define ACCELERATE_NEW_LAPACK
#include <Accelerate/Accelerate.h>

/* ============================================================
 * Input File Parser
 * ============================================================ */

int parse_input_file(const char *filename, BNAParams *params) {
    FILE *fp = fopen(filename, "r");
    if (!fp) {
        fprintf(stderr, "Error: Cannot open file %s\n", filename);
        return -1;
    }

    /* Read dimension */
    if (fscanf(fp, "%d", &params->K) != 1) {
        fprintf(stderr, "Error: Cannot read dimension K\n");
        fclose(fp);
        return -1;
    }

    if (params->K > MAX_DIM) {
        fprintf(stderr, "Error: Dimension %d exceeds MAX_DIM=%d\n", params->K, MAX_DIM);
        fclose(fp);
        return -1;
    }

    int K = params->K;

    /* Read drift vector */
    for (int i = 0; i < K; i++) {
        if (fscanf(fp, "%lf", &params->theta[i]) != 1) {
            fprintf(stderr, "Error: Cannot read theta[%d]\n", i);
            fclose(fp);
            return -1;
        }
    }

    /* Read covariance matrix */
    for (int i = 0; i < K; i++) {
        for (int j = 0; j < K; j++) {
            if (fscanf(fp, "%lf", &params->Gamma[i][j]) != 1) {
                fprintf(stderr, "Error: Cannot read Gamma[%d][%d]\n", i, j);
                fclose(fp);
                return -1;
            }
        }
    }

    /* Read reflection matrix R (K x 2K) */
    for (int i = 0; i < K; i++) {
        for (int j = 0; j < 2*K; j++) {
            if (fscanf(fp, "%lf", &params->R[i][j]) != 1) {
                fprintf(stderr, "Error: Cannot read R[%d][%d]\n", i, j);
                fclose(fp);
                return -1;
            }
        }
    }

    /* Read hypercube dimensions a_vec; set lb=0, ub=a_vec */
    for (int i = 0; i < K; i++) {
        if (fscanf(fp, "%lf", &params->ub[i]) != 1) {
            fprintf(stderr, "Error: Cannot read a_vec[%d]\n", i);
            fclose(fp);
            return -1;
        }
        params->lb[i] = 0.0;
    }

    /* Read mesh sizes (optional) */
    int have_mesh = 1;
    for (int i = 0; i < K; i++) {
        if (fscanf(fp, "%d", &params->mesh_n[i]) != 1) {
            have_mesh = 0;
            break;
        }
    }

    if (!have_mesh) {
        /* Set sentinel: mesh_n[0] == 0 signals caller to prompt */
        for (int i = 0; i < K; i++) {
            params->mesh_n[i] = 0;
            params->h[i] = 0.0;
        }
    } else {
        /* Compute element sizes */
        for (int i = 0; i < K; i++) {
            params->h[i] = (params->ub[i] - params->lb[i]) / params->mesh_n[i];
        }
    }

    /* Read service rates (optional, for throughput computation) */
    params->has_service_rates = 0;
    {
        int got_all = 1;
        for (int i = 0; i < K; i++) {
            if (fscanf(fp, "%lf", &params->service_rates[i]) != 1) {
                got_all = 0;
                break;
            }
        }
        if (got_all) params->has_service_rates = 1;
    }

    /* Read customer class data (optional) */
    params->cc_num_classes = 0;
    {
        char keyword[64] = {0};
        int Kcc = 0;
        if (fscanf(fp, " %63s %d", keyword, &Kcc) == 2
            && strcmp(keyword, "customer_classes") == 0
            && Kcc > 0 && Kcc <= CC_MAX) {
            params->cc_num_classes = Kcc;

            /* alpha_total per station */
            for (int i = 0; i < K; i++)
                fscanf(fp, "%lf", &params->cc_alpha_total[i]);

            /* lambda_k per class */
            for (int k = 0; k < Kcc; k++)
                fscanf(fp, "%lf", &params->cc_lambda[k]);

            /* alpha[k][i] — per-class throughput (Kcc rows x K cols) */
            for (int k = 0; k < Kcc; k++)
                for (int i = 0; i < K; i++)
                    fscanf(fp, "%lf", &params->cc_alpha[k][i]);

            /* mu[k][i] — per-class service rate (Kcc rows x K cols) */
            for (int k = 0; k < Kcc; k++)
                for (int i = 0; i < K; i++)
                    fscanf(fp, "%lf", &params->cc_mu[k][i]);
        }
    }

    fclose(fp);

    return 0;
}

void print_params(const BNAParams *params) {
    int K = params->K;

    printf("Dimension K = %d\n", K);

    printf("Mesh size: [");
    for (int i = 0; i < K; i++) {
        printf("%d%s", params->mesh_n[i], i < K-1 ? ", " : "]\n");
    }

    printf("Drift theta: [");
    for (int i = 0; i < K; i++) {
        printf("%.4f%s", params->theta[i], i < K-1 ? ", " : "]\n");
    }

    printf("Covariance matrix Gamma:\n");
    for (int i = 0; i < K; i++) {
        printf("  ");
        for (int j = 0; j < K; j++) {
            printf("%8.4f ", params->Gamma[i][j]);
        }
        printf("\n");
    }

    printf("Reflection matrix R:\n");
    for (int i = 0; i < K; i++) {
        printf("  ");
        for (int j = 0; j < 2*K; j++) {
            printf("%6.2f ", params->R[i][j]);
        }
        printf("\n");
    }
}

/* ============================================================
 * Sparse Triplet (COO) Operations
 * ============================================================ */

SparseTriplet* sparse_triplet_create(int nrows, int ncols, int initial_capacity) {
    SparseTriplet *mat = (SparseTriplet*)malloc(sizeof(SparseTriplet));
    mat->row = (int*)malloc(initial_capacity * sizeof(int));
    mat->col = (int*)malloc(initial_capacity * sizeof(int));
    mat->val = (double*)malloc(initial_capacity * sizeof(double));
    mat->nnz = 0;
    mat->capacity = initial_capacity;
    mat->nrows = nrows;
    mat->ncols = ncols;
    mat->dedup = 0;
    mat->hash_idx = NULL;
    mat->hash_size = 0;
    return mat;
}

void sparse_triplet_free(SparseTriplet *mat) {
    if (mat) {
        free(mat->row);
        free(mat->col);
        free(mat->val);
        free(mat->hash_idx);
        free(mat);
    }
}

/* Hash a (row, col) pair into the table. Knuth-style multiplicative hash
 * with two odd primes — gives good distribution for FEM index pairs. */
static inline uint64_t st_hash(int row, int col) {
    uint64_t h = (uint64_t)(uint32_t)row * 2654435761ULL
               ^ (uint64_t)(uint32_t)col * 0x9E3779B97F4A7C15ULL;
    h ^= h >> 33;
    h *= 0xff51afd7ed558ccdULL;
    h ^= h >> 33;
    return h;
}

/* Round n up to next power of 2 (minimum 64). */
static int st_next_pow2(int n) {
    int p = 64;
    while (p < n) p <<= 1;
    return p;
}

/* Rehash into a new table of size new_size. Caller has already alloc'd
 * the new array (zero-init not required — we memset to 0xFF for -1). */
static void st_rehash(SparseTriplet *mat, int *new_idx, int new_size) {
    memset(new_idx, 0xFF, (size_t)new_size * sizeof(int));
    int mask = new_size - 1;
    for (int i = 0; i < mat->nnz; i++) {
        uint64_t h = st_hash(mat->row[i], mat->col[i]);
        int slot = (int)(h & (uint64_t)mask);
        while (new_idx[slot] != -1) slot = (slot + 1) & mask;
        new_idx[slot] = i;
    }
    free(mat->hash_idx);
    mat->hash_idx = new_idx;
    mat->hash_size = new_size;
}

void sparse_triplet_enable_dedup(SparseTriplet *mat, int expected_unique) {
    if (mat->dedup) return;  /* already enabled */
    int hs = st_next_pow2(expected_unique * 2);  /* load factor 0.5 */
    mat->hash_idx = (int*)malloc((size_t)hs * sizeof(int));
    memset(mat->hash_idx, 0xFF, (size_t)hs * sizeof(int));
    mat->hash_size = hs;
    mat->dedup = 1;
    /* If entries were already added in append mode, rehash them in. */
    if (mat->nnz > 0) {
        int mask = hs - 1;
        for (int i = 0; i < mat->nnz; i++) {
            uint64_t h = st_hash(mat->row[i], mat->col[i]);
            int slot = (int)(h & (uint64_t)mask);
            while (mat->hash_idx[slot] != -1) {
                if (mat->row[mat->hash_idx[slot]] == mat->row[i] &&
                    mat->col[mat->hash_idx[slot]] == mat->col[i]) {
                    /* Rare: duplicates from append-mode era. Merge. */
                    mat->val[mat->hash_idx[slot]] += mat->val[i];
                    mat->row[i] = -1;  /* mark for compaction */
                    break;
                }
                slot = (slot + 1) & mask;
            }
            if (mat->row[i] != -1)
                mat->hash_idx[slot] = i;
        }
        /* Compact out merged entries. */
        int w = 0;
        for (int i = 0; i < mat->nnz; i++) {
            if (mat->row[i] == -1) continue;
            if (w != i) {
                mat->row[w] = mat->row[i];
                mat->col[w] = mat->col[i];
                mat->val[w] = mat->val[i];
            }
            w++;
        }
        if (w != mat->nnz) {
            mat->nnz = w;
            /* Rebuild hash to reflect the new positions. */
            int *fresh = (int*)malloc((size_t)hs * sizeof(int));
            st_rehash(mat, fresh, hs);
        }
    }
}

void sparse_triplet_add(SparseTriplet *mat, int row, int col, double val) {
    if (mat->dedup) {
        /* Look up (row, col) in hash; sum into existing if found. */
        int mask = mat->hash_size - 1;
        uint64_t h = st_hash(row, col);
        int slot = (int)(h & (uint64_t)mask);
        while (mat->hash_idx[slot] != -1) {
            int idx = mat->hash_idx[slot];
            if (mat->row[idx] == row && mat->col[idx] == col) {
                mat->val[idx] += val;
                return;
            }
            slot = (slot + 1) & mask;
        }
        /* New entry — append to arrays, record in hash. */
        if (mat->nnz >= mat->capacity) {
            mat->capacity *= 2;
            mat->row = (int*)realloc(mat->row, mat->capacity * sizeof(int));
            mat->col = (int*)realloc(mat->col, mat->capacity * sizeof(int));
            mat->val = (double*)realloc(mat->val, mat->capacity * sizeof(double));
        }
        mat->row[mat->nnz] = row;
        mat->col[mat->nnz] = col;
        mat->val[mat->nnz] = val;
        mat->hash_idx[slot] = mat->nnz;
        mat->nnz++;
        /* Rehash if load factor exceeds 0.5 (keeps probe chains short). */
        if (mat->nnz * 2 > mat->hash_size) {
            int new_size = mat->hash_size * 2;
            int *new_idx = (int*)malloc((size_t)new_size * sizeof(int));
            st_rehash(mat, new_idx, new_size);
        }
        return;
    }
    /* Append-only legacy path. */
    if (mat->nnz >= mat->capacity) {
        mat->capacity *= 2;
        mat->row = (int*)realloc(mat->row, mat->capacity * sizeof(int));
        mat->col = (int*)realloc(mat->col, mat->capacity * sizeof(int));
        mat->val = (double*)realloc(mat->val, mat->capacity * sizeof(double));
    }
    mat->row[mat->nnz] = row;
    mat->col[mat->nnz] = col;
    mat->val[mat->nnz] = val;
    mat->nnz++;
}

/* ============================================================
 * CHOLMOD Sparse Matrix Conversion
 * ============================================================ */

cholmod_sparse* triplet_to_cholmod(SparseTriplet *triplet, cholmod_common *c) {
    /* Create CHOLMOD triplet */
    cholmod_triplet *T = cholmod_allocate_triplet(
        triplet->nrows,
        triplet->ncols,
        triplet->nnz,
        0,              /* stype = 0: unsymmetric */
        CHOLMOD_REAL,
        c
    );

    if (!T) {
        fprintf(stderr, "Error: Failed to allocate CHOLMOD triplet\n");
        return NULL;
    }

    /* Copy data */
    int *Ti = (int*)T->i;
    int *Tj = (int*)T->j;
    double *Tx = (double*)T->x;

    for (int k = 0; k < triplet->nnz; k++) {
        Ti[k] = triplet->row[k];
        Tj[k] = triplet->col[k];
        Tx[k] = triplet->val[k];
    }
    T->nnz = triplet->nnz;

    /* Convert to sparse (CSC format) - this also sums duplicates */
    cholmod_sparse *A = cholmod_triplet_to_sparse(T, triplet->nnz, c);

    cholmod_free_triplet(&T, c);

    return A;
}

/* ============================================================
 * Linear Solvers using SuiteSparse
 * ============================================================ */

int umfpack_solve(cholmod_sparse *A, double *b, double *x, cholmod_common *c) {
    /*
     * Solve Ax = b using UMFPACK (LU factorization)
     * This handles general (possibly singular) sparse matrices.
     */
    (void)c;  /* Unused but kept for API consistency */

    int n = (int)A->nrow;

    /* Get CSC format arrays from CHOLMOD */
    int *Ap = (int*)A->p;
    int *Ai = (int*)A->i;
    double *Ax = (double*)A->x;

    /* UMFPACK symbolic analysis */
    void *Symbolic, *Numeric;
    double Info[UMFPACK_INFO], Control[UMFPACK_CONTROL];

    umfpack_di_defaults(Control);
    Control[UMFPACK_PRL] = 1;  /* Print level */

    int status = umfpack_di_symbolic(n, n, Ap, Ai, Ax, &Symbolic, Control, Info);
    if (status != UMFPACK_OK) {
        fprintf(stderr, "UMFPACK symbolic failed: %d\n", status);
        return -1;
    }

    /* Numeric factorization */
    status = umfpack_di_numeric(Ap, Ai, Ax, Symbolic, &Numeric, Control, Info);
    umfpack_di_free_symbolic(&Symbolic);

    if (status != UMFPACK_OK) {
        fprintf(stderr, "UMFPACK numeric failed: %d\n", status);
        if (status == UMFPACK_WARNING_singular_matrix) {
            fprintf(stderr, "  Matrix is singular, using pseudo-solution\n");
        } else {
            return -1;
        }
    }

    /* Solve */
    status = umfpack_di_solve(UMFPACK_A, Ap, Ai, Ax, x, b, Numeric, Control, Info);
    umfpack_di_free_numeric(&Numeric);

    if (status != UMFPACK_OK) {
        fprintf(stderr, "UMFPACK solve failed: %d\n", status);
        return -1;
    }

    if (!g_compact)
        printf("  UMFPACK: solved in %.4f seconds\n", Info[UMFPACK_SOLVE_TIME]);

    return 0;
}

int cholmod_solve_system(cholmod_sparse *A, double *b, double *x, cholmod_common *c) {
    /*
     * Solve Ax = b for a symmetric positive semi-definite FEM matrix.
     *
     * Strategy (matches what was empirically fastest AND accurate across
     * d=3 and d=4 at moderate meshes):
     *   1. Build A_reg = A + reg·max|diag(A)|·I with a very small reg so
     *      we barely touch the spectrum but lift the constants null
     *      eigenvalue away from 0.
     *   2. Try supernodal LL' — dense-BLAS-backed, highly parallel; with
     *      this reg it succeeds on every case where CHOLMOD's
     *      symbolic phase succeeds.
     *   3. If supernodal rejects the matrix as NOT_POSDEF, fall back to
     *      simplicial LDL' on the same A_reg — slower but robust on
     *      near-semi-definite problems.
     *   4. Finally solve with the chosen factorization and copy out x.
     */
    int n = (int)A->nrow;

    cholmod_dense *b_dense = cholmod_allocate_dense(n, 1, n, CHOLMOD_REAL, c);
    memcpy(b_dense->x, b, n * sizeof(double));

    /* Tikhonov regularization: build A_reg = A + reg·(max|diag|)·I.  The
     * scale factor matches the matrix magnitude so ε·I actually perturbs
     * the near-zero eigenvalue (the constants null space) enough for
     * supernodal LL' to succeed, without meaningfully changing the other
     * eigenvalues.  reg = 1e-8 shifts the null eigenvalue by roughly
     * 1e-8·||A||_∞; recovered E[X] values change by ≪ 1 part in 10^6 —
     * well below the FEM discretization error. */
    double max_diag = 0.0;
    {
        int    *Ap = (int*)   A->p;
        int    *Ai = (int*)   A->i;
        double *Ax = (double*)A->x;
        for (int j = 0; j < n; j++) {
            for (int p = Ap[j]; p < Ap[j+1]; p++) {
                if (Ai[p] == j) {
                    double v = fabs(Ax[p]);
                    if (v > max_diag) max_diag = v;
                    break;
                }
            }
        }
    }
    if (max_diag <= 0.0) max_diag = 1.0;

    /* Small regularization just big enough to shift the constant-null
     * eigenvalue away from 0 while barely touching any non-null eigenvalue.
     * This matrix has a tiny smallest non-null eigenvalue — larger reg
     * values noticeably perturb the recovered density, so keep it small
     * and let the fallback path (simplicial LDL') handle cases where
     * supernodal LL' still rejects the matrix. */
    double reg = 1e-12 * max_diag;
    cholmod_sparse *eye = cholmod_speye(n, n, CHOLMOD_REAL, c);
    double alpha[2] = {1.0, 0.0};
    double beta[2]  = {reg, 0.0};
    cholmod_sparse *A_reg = cholmod_add(A, eye, alpha, beta, 1, 0, c);
    cholmod_free_sparse(&eye, c);
    if (!A_reg) {
        fprintf(stderr, "CHOLMOD regularization (add) failed\n");
        cholmod_free_dense(&b_dense, c);
        return -1;
    }
    A_reg->stype = -1;  /* use lower triangle; matrix is symmetric */

    /* Supernodal LL' — uses dense BLAS on supernode blocks, ~10-50× faster
     * than simplicial LDL' at the d=4, n=10 scale.  Requires strict PD,
     * which is why we added the scaled regularization above. */
    int saved_supernodal = c->supernodal;
    int saved_final_ll   = c->final_ll;
    int saved_nmethods   = c->nmethods;
    int saved_ordering0  = (c->nmethods > 0) ? c->method[0].ordering : 0;
    c->supernodal = CHOLMOD_SUPERNODAL;
    c->final_ll   = 1;
    /* Force AMD (approximate minimum-degree) — the CHOLMOD default tries
     * several orderings and occasionally fails the analysis entirely at
     * large sizes on machines without METIS linked, which manifests as
     * cholmod_analyze() returning NULL. Locking in a single ordering that
     * we know works keeps the factorization reliable at d=4, n=10. */
    c->nmethods = 1;
    c->method[0].ordering = CHOLMOD_AMD;

    cholmod_factor *L = cholmod_analyze(A_reg, c);
    if (!L) {
        fprintf(stderr, "CHOLMOD analyze failed\n");
        cholmod_free_sparse(&A_reg, c);
        cholmod_free_dense(&b_dense, c);
        c->supernodal = saved_supernodal;
        c->final_ll   = saved_final_ll;
        c->nmethods   = saved_nmethods;
        if (saved_nmethods > 0) c->method[0].ordering = saved_ordering0;
        return -1;
    }

    cholmod_factorize(A_reg, L, c);
    if (c->status == CHOLMOD_NOT_POSDEF) {
        /* Supernodal LL' still failed — try simplicial LDL' which is more
         * robust but slower. */
        if (!g_compact)
            printf("  Supernodal LL' failed, falling back to simplicial LDL'...\n");
        cholmod_free_factor(&L, c);
        c->supernodal = CHOLMOD_SIMPLICIAL;
        c->final_ll   = 0;
        L = cholmod_analyze(A_reg, c);
        cholmod_factorize(A_reg, L, c);
    }

    if (c->status == CHOLMOD_NOT_POSDEF) {
        fprintf(stderr, "CHOLMOD factorization failed (supernodal LL' and simplicial LDL')\n");
        cholmod_free_factor(&L, c);
        cholmod_free_sparse(&A_reg, c);
        cholmod_free_dense(&b_dense, c);
        c->supernodal = saved_supernodal;
        c->final_ll   = saved_final_ll;
        c->nmethods   = saved_nmethods;
        if (saved_nmethods > 0) c->method[0].ordering = saved_ordering0;
        return -1;
    }

    cholmod_dense *x_dense = cholmod_solve(CHOLMOD_A, L, b_dense, c);
    if (!x_dense) {
        fprintf(stderr, "CHOLMOD solve failed\n");
        cholmod_free_factor(&L, c);
        cholmod_free_sparse(&A_reg, c);
        cholmod_free_dense(&b_dense, c);
        c->supernodal = saved_supernodal;
        c->final_ll   = saved_final_ll;
        c->nmethods   = saved_nmethods;
        if (saved_nmethods > 0) c->method[0].ordering = saved_ordering0;
        return -1;
    }

    memcpy(x, x_dense->x, n * sizeof(double));

    cholmod_free_factor(&L, c);
    cholmod_free_sparse(&A_reg, c);
    cholmod_free_dense(&b_dense, c);
    cholmod_free_dense(&x_dense, c);
    c->supernodal = saved_supernodal;
    c->final_ll   = saved_final_ll;
    c->nmethods   = saved_nmethods;
    if (saved_nmethods > 0) c->method[0].ordering = saved_ordering0;

    return 0;
}

/* ============================================================
 * Conjugate Gradient Solver (for large problems)
 * Using Apple Accelerate framework for optimized BLAS operations
 * ============================================================ */

/* Convert CHOLMOD CSC sparse matrix to Accelerate sparse matrix format */
static sparse_matrix_double cholmod_to_accelerate_sparse(cholmod_sparse *A) {
    size_t n = A->nrow;
    int *Ap = (int*)A->p;
    int *Ai = (int*)A->i;
    double *Ax = (double*)A->x;

    /* Create Accelerate sparse matrix */
    sparse_matrix_double M = sparse_matrix_create_double((sparse_dimension)n, (sparse_dimension)n);

    /* Insert column by column (CHOLMOD uses CSC format) */
    for (size_t j = 0; j < n; j++) {
        int col_start = Ap[j];
        int col_end = Ap[j+1];
        int col_nnz = col_end - col_start;

        if (col_nnz > 0) {
            /* Convert int indices to sparse_index */
            sparse_index *indices = (sparse_index*)malloc(col_nnz * sizeof(sparse_index));
            for (int k = 0; k < col_nnz; k++) {
                indices[k] = (sparse_index)Ai[col_start + k];
            }
            sparse_insert_col_double(M, (sparse_index)j, col_nnz,
                                     Ax + col_start, indices);
            free(indices);
        }
    }

    /* Commit to optimize internal structure for multiplication */
    sparse_commit(M);

    return M;
}

/* Sparse matrix-vector product using Accelerate: y = A * x */
static void spmv_accelerate(sparse_matrix_double M, const double *x, double *y, size_t n) {
    /* Initialize y to zero */
    memset(y, 0, n * sizeof(double));

    /* y = 1.0 * A * x (using raw pointer API with stride 1) */
    sparse_matrix_vector_product_dense_double(CblasNoTrans, 1.0, M, x, 1, y, 1);
    (void)n;  /* Unused, matrix knows its size */
}

/* Dot product using Accelerate BLAS */
static double dot_product(const double *a, const double *b, int n) {
    return cblas_ddot(n, a, 1, b, 1);
}

/* Diagonal preconditioner: extract diagonal of A */
static void get_diagonal(cholmod_sparse *A, double *diag) {
    size_t n = A->nrow;
    int *Ap = (int*)A->p;
    int *Ai = (int*)A->i;
    double *Ax = (double*)A->x;

    /* Initialize with small value to avoid division by zero */
    for (size_t i = 0; i < n; i++) {
        diag[i] = 1e-10;
    }

    /* Find diagonal elements */
    for (size_t j = 0; j < n; j++) {
        for (int p = Ap[j]; p < Ap[j+1]; p++) {
            if ((size_t)Ai[p] == j) {
                diag[j] = fabs(Ax[p]) > 1e-14 ? Ax[p] : 1e-10;
                break;
            }
        }
    }
}

int cg_solve(cholmod_sparse *A, double *b, double *x, cholmod_common *c,
             double tol, int max_iter) {
    /*
     * Preconditioned Conjugate Gradient solver
     * Uses diagonal (Jacobi) preconditioner
     * For symmetric positive semi-definite matrices
     * Optimized with Apple Accelerate framework
     */
    (void)c;  /* Unused */

    size_t n = A->nrow;
    int n_int = (int)n;

    double *r = (double*)malloc(n * sizeof(double));
    double *z = (double*)malloc(n * sizeof(double));
    double *p = (double*)malloc(n * sizeof(double));
    double *Ap_vec = (double*)malloc(n * sizeof(double));
    double *diag = (double*)malloc(n * sizeof(double));

    /* Convert CHOLMOD sparse matrix to Accelerate format (one-time cost) */
    sparse_matrix_double M = cholmod_to_accelerate_sparse(A);

    /* Get diagonal preconditioner */
    get_diagonal(A, diag);

    /* Initial guess: x = 0 */
    memset(x, 0, n * sizeof(double));

    /* r = b - A*x = b (since x = 0) */
    cblas_dcopy(n_int, b, 1, r, 1);

    /* z = M^{-1} * r (diagonal preconditioning): z[i] = r[i] / diag[i] */
    vDSP_vdivD(diag, 1, r, 1, z, 1, n);

    /* p = z */
    cblas_dcopy(n_int, z, 1, p, 1);

    double rz_old = dot_product(r, z, n_int);
    double b_norm = cblas_dnrm2(n_int, b, 1);
    if (b_norm < 1e-14) b_norm = 1.0;

    int iter;
    double residual = 0.0;
    for (iter = 0; iter < max_iter; iter++) {
        /* Ap = A * p */
        spmv_accelerate(M, p, Ap_vec, n);

        /* alpha = (r'*z) / (p'*Ap) */
        double pAp = dot_product(p, Ap_vec, n_int);
        if (fabs(pAp) < 1e-30) {
            if (!g_compact)
                printf("  CG: breakdown at iteration %d (pAp = %.2e)\n", iter, pAp);
            break;
        }
        double alpha = rz_old / pAp;

        /* x = x + alpha * p */
        cblas_daxpy(n_int, alpha, p, 1, x, 1);

        /* r = r - alpha * Ap */
        cblas_daxpy(n_int, -alpha, Ap_vec, 1, r, 1);

        /* Check convergence using BLAS norm */
        residual = cblas_dnrm2(n_int, r, 1) / b_norm;
        if (residual < tol) {
            iter++;
            break;
        }

        /* z = M^{-1} * r: z[i] = r[i] / diag[i] */
        vDSP_vdivD(diag, 1, r, 1, z, 1, n);

        double rz_new = dot_product(r, z, n_int);

        /* beta = (r_new'*z_new) / (r_old'*z_old) */
        double beta = rz_new / rz_old;

        /* p = z + beta * p  -->  p = beta*p; p += z */
        cblas_dscal(n_int, beta, p, 1);
        cblas_daxpy(n_int, 1.0, z, 1, p, 1);

        rz_old = rz_new;

        /* Progress report every 1000 iterations */
        if ((iter + 1) % 1000 == 0) {
            if (!g_compact)
                printf("  CG: iter %d, residual = %.6e\n", iter + 1, residual);
        }
    }

    if (!g_compact)
        printf("  CG: converged in %d iterations, residual = %.6e\n", iter, residual);

    /* Cleanup */
    sparse_matrix_destroy(M);
    free(r);
    free(z);
    free(p);
    free(Ap_vec);
    free(diag);

    return (residual < tol * 10) ? 0 : -1;  /* Allow some tolerance slack */
}

int smart_solve(cholmod_sparse *A, double *b, double *x, cholmod_common *c) {
    /*
     * The FEM matrix assembled by build_fem_system() is a sum of symmetric
     * rank-1 outer products — `Lf_i*Lf_j` in the volume integrals,
     * `Df_i*Df_j` on each boundary face — so it is symmetric positive
     * (semi-)definite.
     *
     * Default dispatch: CHOLMOD supernodal Cholesky first, fall back to
     * UMFPACK LU if Cholesky fails (mildly indefinite matrix), then
     * Jacobi-preconditioned CG as a last resort. CHOLMOD has empirically
     * been the fastest path on every tested case — including mesh=8 K=4
     * (78 s CHOLMOD vs 200 s PCG with 3100 iterations).
     *
     * BNA_FM_SOLVER env var overrides the dispatch:
     *   "cholmod" → CHOLMOD direct (default)
     *   "cg"      → preconditioned CG first
     *   (unset)   → CHOLMOD direct
     */
    size_t nnz = cholmod_nnz(A, c);
    size_t n = A->nrow;
    const char *forced = getenv("BNA_FM_SOLVER");
    int prefer_cg = (forced && strcmp(forced, "cg") == 0) ? 1 : 0;

    if (prefer_cg) {
        if (!g_compact)
            printf("  Solving with preconditioned CG (n=%zu, nnz=%zu, large system)...\n",
                   n, nnz);
        double tol = 1e-8;
        int max_iter = (int)n < 100000 ? (int)n : 100000;
        int status = cg_solve(A, b, x, c, tol, max_iter);
        if (status == 0) return 0;
        if (!g_compact)
            printf("  CG did not converge — falling back to CHOLMOD direct solve...\n");
    }

    if (!g_compact)
        printf("  Solving with CHOLMOD supernodal Cholesky (n=%zu, nnz=%zu)...\n",
               n, nnz);

    int status = cholmod_solve_system(A, b, x, c);
    if (status == 0) return 0;

    /* Cholesky failed — either the matrix is slightly indefinite or a
     * numerical issue tripped the factorization.  Restore stype to the
     * unsymmetric setting that UMFPACK expects and try its LU. */
    if (!g_compact)
        printf("  CHOLMOD failed, falling back to UMFPACK LU...\n");
    A->stype = 0;
    status = umfpack_solve(A, b, x, c);
    if (status == 0) return 0;

    /* Direct solvers both failed — last-resort CG with looser tolerance. */
    if (!g_compact)
        printf("  UMFPACK failed, falling back to preconditioned CG...\n");
    double tol = 1e-10;
    int max_iter = (int)n < 100000 ? (int)n : 100000;
    return cg_solve(A, b, x, c, tol, max_iter);
}

/* ============================================================
 * Hermite Basis Functions
 * ============================================================ */

double phi_func(double xi) {
    /* φ(ξ) = (|ξ| - 1)² (2|ξ| + 1) */
    double ax = fabs(xi);
    double t = ax - 1.0;
    return t * t * (2.0 * ax + 1.0);
}

double psi_func(double xi) {
    /* ψ(ξ) = ξ(|ξ| - 1)² */
    double ax = fabs(xi);
    double t = ax - 1.0;
    return xi * t * t;
}

double phi_deriv1(double xi) {
    /* d/dξ φ = 6ξ(ξ-1) for ξ≥0, 6ξ(-ξ-1) for ξ<0 */
    if (xi >= 0) {
        return 6.0 * xi * (xi - 1.0);
    } else {
        return 6.0 * xi * (-xi - 1.0);
    }
}

double psi_deriv1(double xi) {
    /* d/dξ ψ = (ξ-1)(3ξ-1) for ξ≥0, (-ξ-1)(-3ξ-1) for ξ<0 */
    if (xi >= 0) {
        return (xi - 1.0) * (3.0 * xi - 1.0);
    } else {
        return (-xi - 1.0) * (-3.0 * xi - 1.0);
    }
}

double phi_deriv2(double xi) {
    /* d²/dξ² φ = 12ξ-6 for ξ≥0, -12ξ-6 for ξ<0 */
    if (xi >= 0) {
        return 12.0 * xi - 6.0;
    } else {
        return -12.0 * xi - 6.0;
    }
}

double psi_deriv2(double xi) {
    /* d²/dξ² ψ = 6ξ-4 for ξ≥0, 6ξ+4 for ξ<0 */
    if (xi >= 0) {
        return 6.0 * xi - 4.0;
    } else {
        return 6.0 * xi + 4.0;
    }
}

double hermite_1d(double x, double y, int r, int node_idx, int n, double hj) {
    double val = 0.0;

    /* Left interval [y-h, y] */
    if (node_idx > 1 && x >= y - hj - TOL && x <= y + TOL) {
        double xi = (x - y) / hj;
        if (r == 0) {
            val = phi_func(xi);
        } else {
            val = hj * psi_func(xi);
        }
        return val;
    }

    /* Right interval [y, y+h] */
    if (node_idx <= n && x >= y - TOL && x <= y + hj + TOL) {
        double xi = (x - y) / hj;
        if (r == 0) {
            val = phi_func(xi);
        } else {
            val = hj * psi_func(xi);
        }
    }

    return val;
}

double hermite_1d_deriv1(double x, double y, int r, int node_idx, int n, double hj) {
    double val = 0.0;

    /* Left interval */
    if (node_idx > 1 && x >= y - hj - TOL && x <= y + TOL) {
        double xi = (x - y) / hj;
        if (r == 0) {
            val = phi_deriv1(xi) / hj;
        } else {
            val = psi_deriv1(xi);  /* hj cancels */
        }
        return val;
    }

    /* Right interval */
    if (node_idx <= n && x >= y - TOL && x <= y + hj + TOL) {
        double xi = (x - y) / hj;
        if (r == 0) {
            val = phi_deriv1(xi) / hj;
        } else {
            val = psi_deriv1(xi);
        }
    }

    return val;
}

double hermite_1d_deriv2(double x, double y, int r, int node_idx, int n, double hj) {
    double val = 0.0;

    /* Left interval */
    if (node_idx > 1 && x >= y - hj - TOL && x <= y + TOL) {
        double xi = (x - y) / hj;
        if (r == 0) {
            val = phi_deriv2(xi) / (hj * hj);
        } else {
            val = psi_deriv2(xi) / hj;
        }
        return val;
    }

    /* Right interval */
    if (node_idx <= n && x >= y - TOL && x <= y + hj + TOL) {
        double xi = (x - y) / hj;
        if (r == 0) {
            val = phi_deriv2(xi) / (hj * hj);
        } else {
            val = psi_deriv2(xi) / hj;
        }
    }

    return val;
}

/* ============================================================
 * FEM Utility Functions
 * ============================================================ */

int node_to_global_idx(const int *node, const int *r, int K, const int *mesh_n) {
    /* Formula (22): i = 2^K * Σ i_k * Π_{l<k}(n_l+1) + Σ 2^{k-1} r_k */

    /* Node contribution */
    int node_part = 0;
    int prod_term = 1;
    for (int k = 0; k < K; k++) {
        node_part += (node[k] - 1) * prod_term;  /* 1-based node indices */
        prod_term *= (mesh_n[k] + 1);
    }
    node_part *= ipow(2, K);

    /* r contribution */
    int r_part = 0;
    for (int k = 0; k < K; k++) {
        r_part += r[k] * ipow(2, k);
    }

    return node_part + r_part;  /* 0-based global index */
}

int get_n_basis(int K, const int *mesh_n) {
    int n_nodes = 1;
    for (int i = 0; i < K; i++) {
        n_nodes *= (mesh_n[i] + 1);
    }
    return n_nodes * ipow(2, K);
}

double eval_Lf_at_x(const double *x, const int *node, const int *r,
                    const BNAParams *params) {
    /* Lf = (1/2) Σ Γ_{jk} ∂²f/∂x_j∂x_k + Σ θ_j ∂f/∂x_j
     *
     * Pre-compute 1D basis values h0[j], h1[j], h2[j] once per dimension,
     * then assemble products.  This reduces O(K^3) hermite evaluations to O(K).
     */
    int K = params->K;
    double h0[MAX_DIM], h1[MAX_DIM], h2[MAX_DIM];

    for (int j = 0; j < K; j++) {
        double yj = params->lb[j] + (node[j] - 1) * params->h[j];
        h0[j] = hermite_1d       (x[j], yj, r[j], node[j], params->mesh_n[j], params->h[j]);
        h1[j] = hermite_1d_deriv1(x[j], yj, r[j], node[j], params->mesh_n[j], params->h[j]);
        h2[j] = hermite_1d_deriv2(x[j], yj, r[j], node[j], params->mesh_n[j], params->h[j]);
    }

    /* Compute full product Π h0[l] and prefix/suffix products for "product-except-one" */
    double full_prod = 1.0;
    for (int j = 0; j < K; j++)
        full_prod *= h0[j];

    double Lf = 0.0;

    /* First-order terms: ∂f/∂x_j = h1[j] * Π_{l≠j} h0[l] */
    for (int j = 0; j < K; j++) {
        if (fabs(params->theta[j]) < TOL) continue;
        double prod_except_j = (fabs(h0[j]) > TOL) ? full_prod / h0[j] : 0.0;
        /* Safe fallback: recompute if h0[j] is near zero */
        if (fabs(h0[j]) <= TOL) {
            prod_except_j = 1.0;
            for (int l = 0; l < K; l++)
                if (l != j) prod_except_j *= h0[l];
        }
        Lf += params->theta[j] * h1[j] * prod_except_j;
    }

    /* Second-order terms: ∂²f/∂x_j∂x_k */
    for (int j = 0; j < K; j++) {
        for (int k = 0; k < K; k++) {
            double Gjk = params->Gamma[j][k];
            if (fabs(Gjk) < TOL) continue;

            double d2f;
            if (j == k) {
                /* ∂²f/∂x_j² = h2[j] * Π_{l≠j} h0[l] */
                double prod_except_j = (fabs(h0[j]) > TOL) ? full_prod / h0[j] : 0.0;
                if (fabs(h0[j]) <= TOL) {
                    prod_except_j = 1.0;
                    for (int l = 0; l < K; l++)
                        if (l != j) prod_except_j *= h0[l];
                }
                d2f = h2[j] * prod_except_j;
            } else {
                /* ∂²f/∂x_j∂x_k = h1[j] * h1[k] * Π_{l≠j,k} h0[l] */
                double prod_except_jk;
                if (fabs(h0[j]) > TOL && fabs(h0[k]) > TOL) {
                    prod_except_jk = full_prod / (h0[j] * h0[k]);
                } else {
                    prod_except_jk = 1.0;
                    for (int l = 0; l < K; l++)
                        if (l != j && l != k) prod_except_jk *= h0[l];
                }
                d2f = h1[j] * h1[k] * prod_except_jk;
            }

            Lf += 0.5 * Gjk * d2f;
        }
    }

    return Lf;
}

void eval_grad_f_at_x(const double *x, const int *node, const int *r,
                      const BNAParams *params, double *grad) {
    int K = params->K;
    double h0[MAX_DIM], h1[MAX_DIM];

    for (int j = 0; j < K; j++) {
        double yj = params->lb[j] + (node[j] - 1) * params->h[j];
        h0[j] = hermite_1d       (x[j], yj, r[j], node[j], params->mesh_n[j], params->h[j]);
        h1[j] = hermite_1d_deriv1(x[j], yj, r[j], node[j], params->mesh_n[j], params->h[j]);
    }

    double full_prod = 1.0;
    for (int j = 0; j < K; j++)
        full_prod *= h0[j];

    for (int j = 0; j < K; j++) {
        double prod_except_j = (fabs(h0[j]) > TOL) ? full_prod / h0[j] : 0.0;
        if (fabs(h0[j]) <= TOL) {
            prod_except_j = 1.0;
            for (int l = 0; l < K; l++)
                if (l != j) prod_except_j *= h0[l];
        }
        grad[j] = h1[j] * prod_except_j;
    }
}
