/*
 * BNA/FM Algorithm - Gaussian Quadrature Version (SuiteSparse + OpenMP)
 *
 * Brownian Network Analyzer with Finite Element Method
 * using 5-point Gauss-Legendre quadrature for integration.
 * Uses SuiteSparse (UMFPACK) for sparse linear system solving.
 * Parallelized with OpenMP for multi-core CPUs.
 *
 * Based on: Shen, Chen, Dai, Dai (2000)
 *
 * Usage: ./bna_fm_gauss input_file
 */

#include "bna_fm.h"
#include <time.h>
#include <pthread.h>
#include <omp.h>
#include "../../common/bnet_memcheck.h"

int g_compact = 0;

/* Unified Qnet progress protocol (-P PATH).
 * Header `<total>\n` + one '.' byte per completed mesh element. */
static char  g_progress_path[1024] = "";
static FILE *g_progress_fp = NULL;
static pthread_mutex_t g_progress_lock = PTHREAD_MUTEX_INITIALIZER;

static void progress_open(long total) {
    if (!g_progress_path[0]) return;
    g_progress_fp = fopen(g_progress_path, "wb");
    if (!g_progress_fp) return;
    fprintf(g_progress_fp, "%ld\n", total);
    fflush(g_progress_fp);
}
static void progress_tick(void) {
    if (!g_progress_fp) return;
    pthread_mutex_lock(&g_progress_lock);
    fputc('.', g_progress_fp);
    fflush(g_progress_fp);
    pthread_mutex_unlock(&g_progress_lock);
}
static void progress_close(void) {
    if (g_progress_fp) {
        fclose(g_progress_fp);
        g_progress_fp = NULL;
    }
}

/* ============================================================
 * Gauss-Legendre Quadrature
 * ============================================================ */

/* 4-point Gauss-Legendre exactly integrates polynomials up to degree 7.
 * Our integrand is L(f_i)·L(f_j) with f_i cubic Hermite, so the integrand
 * has max degree 6 per 1-D coordinate — 4-point is the minimum-safe choice
 * and is exact (no approximation error vs. the previous 5-point rule). */
#define N_GAUSS 4

static double gauss_points[N_GAUSS];
static double gauss_weights[N_GAUSS];

static void init_gauss_legendre(void) {
    /* 4-point Gauss-Legendre on [-1, 1]
     *   points:  ±sqrt((3 - 2·sqrt(6/5))/7), ±sqrt((3 + 2·sqrt(6/5))/7)
     *   weights: (18 ± sqrt(30)) / 36                                   */
    double p_inner = sqrt((3.0 - 2.0 * sqrt(6.0/5.0)) / 7.0);   /* ≈ 0.33998 */
    double p_outer = sqrt((3.0 + 2.0 * sqrt(6.0/5.0)) / 7.0);   /* ≈ 0.86114 */
    double w_inner = (18.0 + sqrt(30.0)) / 36.0;                /* ≈ 0.65215 */
    double w_outer = (18.0 - sqrt(30.0)) / 36.0;                /* ≈ 0.34785 */

    gauss_points[0] = -p_outer;
    gauss_points[1] = -p_inner;
    gauss_points[2] =  p_inner;
    gauss_points[3] =  p_outer;

    gauss_weights[0] = w_outer;
    gauss_weights[1] = w_inner;
    gauss_weights[2] = w_inner;
    gauss_weights[3] = w_outer;
}

/* ============================================================
 * Element Basis Functions
 * ============================================================ */

typedef struct {
    int node[MAX_DIM];
    int r[MAX_DIM];
    int global_idx;
} LocalBasis;

static int get_element_basis_funcs(int K, const int *mesh_n, const int *el,
                                   LocalBasis *basis) {
    int n_corners = ipow(2, K);
    int n_types = ipow(2, K);
    int idx = 0;

    for (int c = 0; c < n_corners; c++) {
        /* Compute corner node indices */
        int node[MAX_DIM];
        for (int j = 0; j < K; j++) {
            if (c & (1 << j)) {
                node[j] = el[j] + 1;  /* Upper corner (1-based) */
            } else {
                node[j] = el[j];      /* Lower corner */
            }
        }

        /* Each node has 2^K basis functions (phi/psi combinations) */
        for (int t = 0; t < n_types; t++) {
            int r[MAX_DIM];
            for (int j = 0; j < K; j++) {
                r[j] = (t >> j) & 1;
            }

            for (int j = 0; j < K; j++) {
                basis[idx].node[j] = node[j];
                basis[idx].r[j] = r[j];
            }
            basis[idx].global_idx = node_to_global_idx(node, r, K, mesh_n);
            idx++;
        }
    }

    return idx;
}

static int get_face_basis_funcs(int K, const int *mesh_n, const int *fel,
                                int face_dim, int is_lower, LocalBasis *basis) {
    int fixed_node = is_lower ? 1 : mesh_n[face_dim] + 1;
    int n_face_corners = ipow(2, K - 1);
    int n_types = ipow(2, K);
    int idx = 0;

    for (int c = 0; c < n_face_corners; c++) {
        int node[MAX_DIM];
        int bit_pos = 0;
        for (int j = 0; j < K; j++) {
            if (j == face_dim) {
                node[j] = fixed_node;
            } else {
                if (c & (1 << bit_pos)) {
                    node[j] = fel[j] + 1;
                } else {
                    node[j] = fel[j];
                }
                bit_pos++;
            }
        }

        for (int t = 0; t < n_types; t++) {
            int r[MAX_DIM];
            for (int j = 0; j < K; j++) {
                r[j] = (t >> j) & 1;
            }

            for (int j = 0; j < K; j++) {
                basis[idx].node[j] = node[j];
                basis[idx].r[j] = r[j];
            }
            basis[idx].global_idx = node_to_global_idx(node, r, K, mesh_n);
            idx++;
        }
    }

    return idx;
}

/* ============================================================
 * Multi-index Generation
 * ============================================================ */

static void idx_to_multi(int idx, const int *sizes, int K, int *multi) {
    for (int j = 0; j < K; j++) {
        multi[j] = idx % sizes[j];
        idx /= sizes[j];
    }
}

/* ============================================================
 * FEM System Assembly (OpenMP Parallelized)
 * ============================================================ */

static void build_fem_system(const BNAParams *params, SparseTriplet *A, double *y) {
    int K = params->K;
    int n_elem = prod_int(params->mesh_n, K);
    int n_gp_total = ipow(N_GAUSS, K);
    int max_local = ipow(2, K) * ipow(2, K);
    int n_basis = get_n_basis(K, params->mesh_n);

    int n_threads = omp_get_max_threads();
    if (!g_compact) {
        printf("  Using %d OpenMP threads\n", n_threads);
        printf("  Processing %d elements for volume integrals...\n", n_elem);
    }

    /* Open the unified progress file. Total = n_elem (one tick per
     * completed element). The downstream CHOLMOD solve is opaque;
     * the Swift wrapper switches to a spinner appended to the full
     * bar after this loop completes. */
    progress_open((long)n_elem);

    /* Pre-compute Gauss sizes array */
    int gauss_sizes[MAX_DIM];
    for (int j = 0; j < K; j++) gauss_sizes[j] = N_GAUSS;

    /* Create thread-local triplet storage with dedup-on-insert. The
     * cubic-Hermite local matrices have shared basis indices across
     * neighbouring elements, so without dedup each (i, j) entry would
     * be appended ~16/threads times. Dedup collapses that into one
     * entry with a summed value, cutting per-thread RAM by ~50× at
     * K=4 (and shrinking the conversion-to-CHOLMOD pass by the same
     * factor downstream). */
    SparseTriplet **thread_triplets = (SparseTriplet**)malloc(n_threads * sizeof(SparseTriplet*));
    for (int t = 0; t < n_threads; t++) {
        /* Per-thread expected unique entries: each thread sees
         * (n_elem / n_threads) elements, each contributing max_local
         * basis funcs; unique (i, j) pairs ≈ basis_funcs_in_thread².
         * Bound by total basis funcs squared. */
        int per_thread_elem = n_elem / n_threads + 1;
        int approx_unique = per_thread_elem * max_local;
        if (approx_unique > n_basis) approx_unique = n_basis;
        approx_unique = approx_unique * 16;  /* slack for inter-element overlap */
        if (approx_unique > n_basis * 32) approx_unique = n_basis * 32;
        int initial_capacity = approx_unique > 1024 ? approx_unique : 1024;
        thread_triplets[t] = sparse_triplet_create(n_basis, n_basis, initial_capacity);
        sparse_triplet_enable_dedup(thread_triplets[t], approx_unique);
    }

    /* Thread-local y vectors */
    double **thread_y = (double**)malloc(n_threads * sizeof(double*));
    for (int t = 0; t < n_threads; t++) {
        thread_y[t] = (double*)calloc(n_basis, sizeof(double));
    }

    /* Parallel loop over elements */
    #pragma omp parallel
    {
        int tid = omp_get_thread_num();
        SparseTriplet *my_triplet = thread_triplets[tid];
        double *my_y = thread_y[tid];

        /* Thread-local work arrays */
        LocalBasis *basis = (LocalBasis*)malloc(max_local * sizeof(LocalBasis));
        double *Lf_vals = (double*)malloc(max_local * sizeof(double));
        double *A_local = (double*)malloc(max_local * max_local * sizeof(double));
        double *y_local = (double*)malloc(max_local * sizeof(double));

        #pragma omp for schedule(dynamic, 4)
        for (int e = 0; e < n_elem; e++) {
            /* Convert linear index to element multi-index (1-based) */
            int el[MAX_DIM];
            idx_to_multi(e, params->mesh_n, K, el);
            for (int j = 0; j < K; j++) el[j] += 1;  /* 1-based */

            /* Element bounds */
            double el_lb[MAX_DIM], el_ub[MAX_DIM];
            for (int j = 0; j < K; j++) {
                el_lb[j] = params->lb[j] + (el[j] - 1) * params->h[j];
                el_ub[j] = el_lb[j] + params->h[j];
            }

            /* Get local basis functions */
            int n_local = get_element_basis_funcs(K, params->mesh_n, el, basis);

            /* Initialize local matrices */
            memset(A_local, 0, n_local * n_local * sizeof(double));
            memset(y_local, 0, n_local * sizeof(double));

            /* Gauss quadrature */
            for (int g = 0; g < n_gp_total; g++) {
                /* Get quadrature point and weight */
                int gidx[MAX_DIM];
                idx_to_multi(g, gauss_sizes, K, gidx);

                double x[MAX_DIM];
                double w = 1.0;
                for (int j = 0; j < K; j++) {
                    /* Map [-1, 1] to [el_lb, el_ub] */
                    x[j] = el_lb[j] + (gauss_points[gidx[j]] + 1.0) / 2.0 * params->h[j];
                    w *= gauss_weights[gidx[j]] * params->h[j] / 2.0;
                }

                /* Evaluate Lf for all local basis functions */
                for (int i = 0; i < n_local; i++) {
                    Lf_vals[i] = eval_Lf_at_x(x, basis[i].node, basis[i].r, params);
                }

                /* Accumulate contributions */
                for (int i = 0; i < n_local; i++) {
                    y_local[i] += w * Lf_vals[i];
                    for (int j = 0; j < n_local; j++) {
                        A_local[i * n_local + j] += w * Lf_vals[i] * Lf_vals[j];
                    }
                }
            }

            /* Assemble into thread-local storage */
            for (int i = 0; i < n_local; i++) {
                int gi = basis[i].global_idx;
                my_y[gi] += y_local[i];
                for (int j = 0; j < n_local; j++) {
                    int gj = basis[j].global_idx;
                    sparse_triplet_add(my_triplet, gi, gj, A_local[i * n_local + j]);
                }
            }

            progress_tick();
        }

        free(basis);
        free(Lf_vals);
        free(A_local);
        free(y_local);
    }

    progress_close();

    /* Merge thread-local results into global.
     * Previously this was an O(total_nnz) sparse_triplet_add() loop — one
     * function call (with capacity-check branch) per triplet. At d=4 that's
     * ~650M calls. Replacing with a single realloc to the exact total
     * capacity plus three memcpy's per thread gives a large speedup and
     * lets the compiler/runtime vectorize the copy. */
    size_t total_add = 0;
    for (int t = 0; t < n_threads; t++) {
        total_add += (size_t)thread_triplets[t]->nnz;
    }
    size_t new_nnz = (size_t)A->nnz + total_add;
    if ((size_t)A->capacity < new_nnz) {
        A->capacity = (int)new_nnz;
        A->row = (int*)   realloc(A->row, A->capacity * sizeof(int));
        A->col = (int*)   realloc(A->col, A->capacity * sizeof(int));
        A->val = (double*)realloc(A->val, A->capacity * sizeof(double));
    }
    for (int t = 0; t < n_threads; t++) {
        SparseTriplet *src = thread_triplets[t];
        if (src->nnz > 0) {
            memcpy(A->row + A->nnz, src->row, src->nnz * sizeof(int));
            memcpy(A->col + A->nnz, src->col, src->nnz * sizeof(int));
            memcpy(A->val + A->nnz, src->val, src->nnz * sizeof(double));
            A->nnz += src->nnz;
        }
        sparse_triplet_free(src);

        for (int i = 0; i < n_basis; i++) {
            y[i] += thread_y[t][i];
        }
        free(thread_y[t]);
    }
    free(thread_triplets);
    free(thread_y);

    /* Boundary integrals */
    if (!g_compact)
        printf("  Processing boundary integrals...\n");

    if (K > 1) {
        int n_gp_face = ipow(N_GAUSS, K - 1);

        /* Allocate per-face, per-thread triplet buffers up front so we can
         * process every face inside a single `#pragma omp parallel` region
         * and avoid 2*K thread fork/join cycles. */
        SparseTriplet ***all_face_triplets =
            (SparseTriplet***)malloc(2 * K * sizeof(SparseTriplet**));
        int n_face_elem_per_face[2 * MAX_DIM];
        int face_mesh_all[2 * MAX_DIM][MAX_DIM];
        for (int face = 0; face < 2 * K; face++) {
            int face_dim = face < K ? face : face - K;
            for (int j = 0; j < K; j++) {
                face_mesh_all[face][j] = (j == face_dim) ? 1 : params->mesh_n[j];
            }
            n_face_elem_per_face[face] = prod_int(face_mesh_all[face], K);

            all_face_triplets[face] =
                (SparseTriplet**)malloc(n_threads * sizeof(SparseTriplet*));
            for (int t = 0; t < n_threads; t++) {
                int per_thread_face = n_face_elem_per_face[face] / n_threads + 1;
                int approx_unique = per_thread_face * max_local;
                if (approx_unique > n_basis) approx_unique = n_basis;
                approx_unique *= 16;  /* slack for shared boundary basis funcs */
                if (approx_unique > n_basis * 32) approx_unique = n_basis * 32;
                int cap = approx_unique > 1024 ? approx_unique : 1024;
                all_face_triplets[face][t] =
                    sparse_triplet_create(n_basis, n_basis, cap);
                sparse_triplet_enable_dedup(all_face_triplets[face][t],
                                            approx_unique);
            }
        }

        /* Single parallel region spans all boundary faces. Each face gets an
         * `#pragma omp for` with an implicit barrier, so thread pool startup
         * and teardown happens just once per boundary phase. */
        #pragma omp parallel
        {
            int tid = omp_get_thread_num();
            LocalBasis *basis = (LocalBasis*)malloc(max_local * sizeof(LocalBasis));
            double *A_local =
                (double*)malloc(max_local * max_local * sizeof(double));

            for (int face = 0; face < 2 * K; face++) {
                int face_dim = face < K ? face : face - K;
                double face_val = face < K
                    ? params->lb[face_dim]
                    : params->ub[face_dim];
                int is_lower = face < K;

                double v_k[MAX_DIM];
                for (int j = 0; j < K; j++) {
                    v_k[j] = params->R[j][face];
                }

                int *face_mesh = face_mesh_all[face];
                int n_face_elem = n_face_elem_per_face[face];
                SparseTriplet *my_triplet = all_face_triplets[face][tid];

                #pragma omp for schedule(dynamic, 4)
                for (int fe = 0; fe < n_face_elem; fe++) {
                    int fel[MAX_DIM];
                    idx_to_multi(fe, face_mesh, K, fel);
                    for (int j = 0; j < K; j++) fel[j] += 1;
                    fel[face_dim] = 1;

                    /* Get face basis functions */
                    int n_local = get_face_basis_funcs(K, params->mesh_n, fel,
                                                       face_dim, is_lower, basis);

                    memset(A_local, 0, n_local * n_local * sizeof(double));

                    /* Face element bounds */
                    double fel_lb[MAX_DIM];
                    for (int j = 0; j < K; j++) {
                        fel_lb[j] = params->lb[j] + (fel[j] - 1) * params->h[j];
                    }

                    /* Gauss quadrature on face */
                    for (int g = 0; g < n_gp_face; g++) {
                        int gidx[MAX_DIM];
                        int gi = g;
                        for (int j = 0; j < K; j++) {
                            if (j != face_dim) {
                                gidx[j] = gi % N_GAUSS;
                                gi /= N_GAUSS;
                            }
                        }

                        double x[MAX_DIM];
                        double w = 1.0;
                        for (int j = 0; j < K; j++) {
                            if (j == face_dim) {
                                x[j] = face_val;
                            } else {
                                x[j] = fel_lb[j] + (gauss_points[gidx[j]] + 1.0) / 2.0 * params->h[j];
                                w *= gauss_weights[gidx[j]] * params->h[j] / 2.0;
                            }
                        }

                        /* Evaluate D_k f = v_k' * grad(f) for all local basis */
                        double Df_vals[256];  /* Max local basis */
                        for (int i = 0; i < n_local; i++) {
                            double grad_f[MAX_DIM];
                            eval_grad_f_at_x(x, basis[i].node, basis[i].r, params, grad_f);
                            Df_vals[i] = 0.0;
                            for (int j = 0; j < K; j++) {
                                Df_vals[i] += v_k[j] * grad_f[j];
                            }
                        }

                        /* Accumulate */
                        for (int i = 0; i < n_local; i++) {
                            for (int j = 0; j < n_local; j++) {
                                A_local[i * n_local + j] += w * Df_vals[i] * Df_vals[j];
                            }
                        }
                    }

                    /* Assemble */
                    for (int i = 0; i < n_local; i++) {
                        int gi = basis[i].global_idx;
                        for (int j = 0; j < n_local; j++) {
                            int gj = basis[j].global_idx;
                            sparse_triplet_add(my_triplet, gi, gj, A_local[i * n_local + j]);
                        }
                    }
                }
                /* Implicit barrier at end of `omp for` — all threads finish
                 * this face before any advances to the next one. */
            }

            free(basis);
            free(A_local);
        }

        /* Bulk-merge every (face, thread) buffer into the global triplet —
         * single realloc to exact total capacity + three memcpys per buffer,
         * replacing 2*K independent merge loops that each called
         * sparse_triplet_add() per entry. */
        size_t total_add = 0;
        for (int face = 0; face < 2 * K; face++) {
            for (int t = 0; t < n_threads; t++) {
                total_add += (size_t)all_face_triplets[face][t]->nnz;
            }
        }
        size_t new_nnz = (size_t)A->nnz + total_add;
        if ((size_t)A->capacity < new_nnz) {
            A->capacity = (int)new_nnz;
            A->row = (int*)   realloc(A->row, A->capacity * sizeof(int));
            A->col = (int*)   realloc(A->col, A->capacity * sizeof(int));
            A->val = (double*)realloc(A->val, A->capacity * sizeof(double));
        }
        for (int face = 0; face < 2 * K; face++) {
            for (int t = 0; t < n_threads; t++) {
                SparseTriplet *src = all_face_triplets[face][t];
                if (src->nnz > 0) {
                    memcpy(A->row + A->nnz, src->row, src->nnz * sizeof(int));
                    memcpy(A->col + A->nnz, src->col, src->nnz * sizeof(int));
                    memcpy(A->val + A->nnz, src->val, src->nnz * sizeof(double));
                    A->nnz += src->nnz;
                }
                sparse_triplet_free(src);
            }
            free(all_face_triplets[face]);
        }
        free(all_face_triplets);
    }
}

/* ============================================================
 * Compute Stationary Mean (OpenMP Parallelized)
 *
 * SEMANTICS (must match fBNAsm and fBNAsim):
 *   x_k is the SRBM state variable on [0, ub[k]]. Per Dai-Harrison
 *   heavy-traffic theory, x_k represents TOTAL station occupancy
 *   (buffer customers + the customer in service). The reflection
 *   at x_k = 0 represents server idle time, which only makes sense
 *   if x_k counts the in-service customer. The simulator reports
 *   E[X_k] as (avg_buffer + utilization) — total occupancy —
 *   matching this convention. Sojourn = q[k] / Gamma_k is therefore
 *   the mean TOTAL time at station k (wait + service).
 * ============================================================ */

static void compute_stationary_mean(const double *u, const BNAParams *params,
                                    double *q, double *kappa_out) {
    int K = params->K;
    int n_elem = prod_int(params->mesh_n, K);
    int n_gp_total = ipow(N_GAUSS, K);
    int max_local = ipow(2, K) * ipow(2, K);

    /* Pre-compute Gauss sizes array */
    int gauss_sizes[MAX_DIM];
    for (int j = 0; j < K; j++) gauss_sizes[j] = N_GAUSS;

    /* Compute integral of 1 and Σ u_i Lf_i over domain */
    double integral_one = prod_double(params->h, K) * n_elem;
    double integral_Lf = 0.0;

    #pragma omp parallel reduction(+:integral_Lf)
    {
        LocalBasis *basis = (LocalBasis*)malloc(max_local * sizeof(LocalBasis));

        #pragma omp for schedule(dynamic, 4)
        for (int e = 0; e < n_elem; e++) {
            int el[MAX_DIM];
            idx_to_multi(e, params->mesh_n, K, el);
            for (int j = 0; j < K; j++) el[j] += 1;

            double el_lb[MAX_DIM];
            for (int j = 0; j < K; j++) {
                el_lb[j] = params->lb[j] + (el[j] - 1) * params->h[j];
            }

            int n_local = get_element_basis_funcs(K, params->mesh_n, el, basis);

            for (int g = 0; g < n_gp_total; g++) {
                int gidx[MAX_DIM];
                idx_to_multi(g, gauss_sizes, K, gidx);

                double x[MAX_DIM];
                double w = 1.0;
                for (int j = 0; j < K; j++) {
                    x[j] = el_lb[j] + (gauss_points[gidx[j]] + 1.0) / 2.0 * params->h[j];
                    w *= gauss_weights[gidx[j]] * params->h[j] / 2.0;
                }

                double sum_uLf = 0.0;
                for (int i = 0; i < n_local; i++) {
                    double Lf_val = eval_Lf_at_x(x, basis[i].node, basis[i].r, params);
                    sum_uLf += u[basis[i].global_idx] * Lf_val;
                }

                integral_Lf += w * sum_uLf;
            }
        }

        free(basis);
    }

    double kappa = 1.0 / (integral_one - integral_Lf);
    if (!g_compact)
        printf("  Normalization constant kappa = %.6e\n", kappa);
    *kappa_out = kappa;

    /* Compute mean */
    memset(q, 0, K * sizeof(double));

    #pragma omp parallel
    {
        double q_thread[MAX_DIM] = {0};
        LocalBasis *basis = (LocalBasis*)malloc(max_local * sizeof(LocalBasis));

        #pragma omp for schedule(dynamic, 4)
        for (int e = 0; e < n_elem; e++) {
            int el[MAX_DIM];
            idx_to_multi(e, params->mesh_n, K, el);
            for (int j = 0; j < K; j++) el[j] += 1;

            double el_lb[MAX_DIM];
            for (int j = 0; j < K; j++) {
                el_lb[j] = params->lb[j] + (el[j] - 1) * params->h[j];
            }

            int n_local = get_element_basis_funcs(K, params->mesh_n, el, basis);

            for (int g = 0; g < n_gp_total; g++) {
                int gidx[MAX_DIM];
                idx_to_multi(g, gauss_sizes, K, gidx);

                double x[MAX_DIM];
                double w = 1.0;
                for (int j = 0; j < K; j++) {
                    x[j] = el_lb[j] + (gauss_points[gidx[j]] + 1.0) / 2.0 * params->h[j];
                    w *= gauss_weights[gidx[j]] * params->h[j] / 2.0;
                }

                double sum_uLf = 0.0;
                for (int i = 0; i < n_local; i++) {
                    double Lf_val = eval_Lf_at_x(x, basis[i].node, basis[i].r, params);
                    sum_uLf += u[basis[i].global_idx] * Lf_val;
                }

                double p0_val = kappa * (1.0 - sum_uLf);
                for (int j = 0; j < K; j++) {
                    q_thread[j] += w * x[j] * p0_val;
                }
            }
        }

        free(basis);

        /* Combine thread results */
        #pragma omp critical
        {
            for (int j = 0; j < K; j++) {
                q[j] += q_thread[j];
            }
        }
    }
}

/* ============================================================
 * Compute Boundary Measures (delta)
 * ============================================================
 *
 * The boundary measure for face k is:
 *   delta_k = -kappa * sum_i u_i * integral_{F_k} D_k f_i(x) dsigma(x)
 *
 * where D_k f_i(x) = v_k . grad(f_i)(x) is the directional derivative
 * in the reflection direction v_k = R[:,k].
 *
 * Face ordering: faces 0..K-1 are lower faces (x_k = 0),
 *                faces K..2K-1 are upper faces (x_k = a_k).
 */

static void compute_boundary_measures(const double *u, const BNAParams *params,
                                      double kappa, double *delta) {
    int K = params->K;
    int max_local = ipow(2, K) * ipow(2, K);

    for (int face = 0; face < 2 * K; face++) {
        int face_dim = face < K ? face : face - K;
        int is_lower = face < K;
        double face_val = is_lower ? params->lb[face_dim] : params->ub[face_dim];

        /* Reflection direction for this face */
        double v_k[MAX_DIM];
        for (int j = 0; j < K; j++) {
            v_k[j] = params->R[j][face];
        }

        /* Face mesh */
        int face_mesh[MAX_DIM];
        for (int j = 0; j < K; j++) {
            face_mesh[j] = (j == face_dim) ? 1 : params->mesh_n[j];
        }
        int n_face_elem = prod_int(face_mesh, K);

        int n_gp_face = ipow(N_GAUSS, K - 1);

        double face_integral = 0.0;

        #pragma omp parallel reduction(+:face_integral)
        {
            LocalBasis *basis = (LocalBasis*)malloc(max_local * sizeof(LocalBasis));

            #pragma omp for schedule(dynamic, 4)
            for (int fe = 0; fe < n_face_elem; fe++) {
                int fel[MAX_DIM];
                idx_to_multi(fe, face_mesh, K, fel);
                for (int j = 0; j < K; j++) fel[j] += 1;
                fel[face_dim] = 1;

                /* Get face basis functions */
                int n_local = get_face_basis_funcs(K, params->mesh_n, fel,
                                                   face_dim, is_lower, basis);

                /* Face element bounds */
                double fel_lb[MAX_DIM];
                for (int j = 0; j < K; j++) {
                    fel_lb[j] = params->lb[j] + (fel[j] - 1) * params->h[j];
                }

                /* (K-1)-dimensional Gauss quadrature on the face */
                for (int g = 0; g < n_gp_face; g++) {
                    int gidx[MAX_DIM];
                    int gi = g;
                    for (int j = 0; j < K; j++) {
                        if (j != face_dim) {
                            gidx[j] = gi % N_GAUSS;
                            gi /= N_GAUSS;
                        }
                    }

                    double x[MAX_DIM];
                    double w = 1.0;
                    for (int j = 0; j < K; j++) {
                        if (j == face_dim) {
                            x[j] = face_val;
                        } else {
                            x[j] = fel_lb[j] + (gauss_points[gidx[j]] + 1.0) / 2.0 * params->h[j];
                            w *= gauss_weights[gidx[j]] * params->h[j] / 2.0;
                        }
                    }

                    /* Evaluate sum u_i * D_k f_i(x) = sum u_i * (v_k . grad f_i(x)) */
                    double sum_uDf = 0.0;
                    for (int i = 0; i < n_local; i++) {
                        double grad_f[MAX_DIM];
                        eval_grad_f_at_x(x, basis[i].node, basis[i].r, params, grad_f);
                        double Df_val = 0.0;
                        for (int j = 0; j < K; j++) {
                            Df_val += v_k[j] * grad_f[j];
                        }
                        sum_uDf += u[basis[i].global_idx] * Df_val;
                    }

                    face_integral += w * sum_uDf;
                }
            }

            free(basis);
        }

        delta[face] = -kappa * face_integral;
    }
}

/* ============================================================
 * Main
 * ============================================================ */

int main(int argc, char *argv[]) {
    /* Scan for -c/-G flags and find input file */
    int compact = 0;
    int gui_mode = 0;
    const char *input_file = NULL;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-c") == 0) {
            compact = 1;
        } else if (strcmp(argv[i], "-G") == 0) {
            gui_mode = 1;
        } else if (strcmp(argv[i], "-P") == 0 && i + 1 < argc) {
            strncpy(g_progress_path, argv[++i], sizeof(g_progress_path) - 1);
            g_progress_path[sizeof(g_progress_path) - 1] = '\0';
        } else if (argv[i][0] != '-') {
            input_file = argv[i];
        }
    }

    if (!input_file) {
        fprintf(stderr, "Usage: %s input_file [-c]\n", argv[0]);
        return 1;
    }

    if (gui_mode) compact = 1;
    g_compact = compact;

    if (!compact)
        printf("=== BNA/FM Algorithm (Gaussian Quadrature + SuiteSparse + OpenMP) ===\n");

    /* Parse input file */
    BNAParams params;
    if (parse_input_file(input_file, &params) != 0) {
        return 1;
    }

    /* If mesh_n was not in the input file, prompt the user */
    if (params.mesh_n[0] == 0) {
        printf("Enter mesh sizes per dimension (%d values): ", params.K);
        fflush(stdout);
        for (int i = 0; i < params.K; i++) {
            if (scanf("%d", &params.mesh_n[i]) != 1 || params.mesh_n[i] <= 0) {
                fprintf(stderr, "Error: Invalid mesh size\n");
                return 1;
            }
        }
        for (int i = 0; i < params.K; i++) {
            params.h[i] = (params.ub[i] - params.lb[i]) / params.mesh_n[i];
        }
    }

    if (!compact)
        print_params(&params);

    int n_basis = get_n_basis(params.K, params.mesh_n);
    if (!compact)
        printf("Number of basis functions: %d\n", n_basis);

    /* Memory guardrail. n_basis = prod(mesh_n[i]+1) * 2^K — grows
       polynomially in mesh_n and exponentially in K. The downstream
       pipeline allocates O(n_basis) dense vectors plus a sparse
       triplet of capacity 100*n_basis (12 B per entry on disk =
       ~1.2 KB * n_basis), so the dominant footprint is roughly
       2 KB * n_basis. Bail before that allocation if it would push
       past half of physical RAM. */
    {
        uint64_t bytes = (uint64_t) n_basis * (uint64_t) 2048;
        bnet_memcheck_alloc(bytes,
            "FE Gauss-Legendre system",
            "reduce mesh_n (per-dimension grid) or K (network dimension); "
            "n_basis grows as prod(mesh_n[i]+1) * 2^K");
    }

    /* Initialize Gauss quadrature */
    init_gauss_legendre();

    /* Initialize CHOLMOD */
    cholmod_common c;
    cholmod_start(&c);

    /* Build system */
    if (!compact)
        printf("Building system matrix...\n");
    double start = omp_get_wtime();

    SparseTriplet *A_triplet = sparse_triplet_create(n_basis, n_basis, n_basis * 100);
    double *y = (double*)calloc(n_basis, sizeof(double));

    double t_pre_build = omp_get_wtime();
    build_fem_system(&params, A_triplet, y);
    if (!compact)
        printf("  [build_fem_system took %.2f s]\n",
               omp_get_wtime() - t_pre_build);

    /* Convert to CHOLMOD sparse */
    double t_pre_conv = omp_get_wtime();
    cholmod_sparse *A = triplet_to_cholmod(A_triplet, &c);
    sparse_triplet_free(A_triplet);
    if (!compact)
        printf("  [triplet->CHOLMOD conversion took %.2f s]\n",
               omp_get_wtime() - t_pre_conv);

    if (!compact)
        printf("System matrix built. nnz = %ld\n", (long)cholmod_nnz(A, &c));

    /* Solve linear system. CHOLMOD's supernodal solve is silent and
     * can dominate wall time for large meshes (e.g., ~80 s on the 4d3c
     * example with mesh=8, n_basis≈10^5, nnz≈10^8). Show a heads-up so
     * the user doesn't think the program is hung — the prior version
     * printed "Solving..." once and then sat silent for 1+ minutes. */
    if (!compact) {
        printf("Solving linear system...\n");
        if ((long)n_basis * (long)cholmod_nnz(A, &c) > 1000000000L) {
            printf("  (large system — CHOLMOD will be silent for a while)\n");
            fflush(stdout);
        }
    }
    double *u = (double*)calloc(n_basis, sizeof(double));

    double t_pre_solve = omp_get_wtime();
    int solve_rc = smart_solve(A, y, u, &c);
    if (!compact)
        printf("  [linear solve took %.2f s]\n", omp_get_wtime() - t_pre_solve);
    if (solve_rc != 0) {
        fprintf(stderr, "Solver failed\n");
        cholmod_free_sparse(&A, &c);
        cholmod_finish(&c);
        free(y);
        free(u);
        return 1;
    }

    /* Compute mean */
    if (!compact)
        printf("Computing stationary mean...\n");
    double q[MAX_DIM], kappa;
    double t_pre_mean = omp_get_wtime();
    compute_stationary_mean(u, &params, q, &kappa);
    if (!compact)
        printf("  [stationary mean took %.2f s]\n", omp_get_wtime() - t_pre_mean);

    /* Compute boundary measures */
    if (!compact)
        printf("Computing boundary measures...\n");
    double delta[2 * MAX_DIM];
    double t_pre_bnd = omp_get_wtime();
    compute_boundary_measures(u, &params, kappa, delta);
    if (!compact)
        printf("  [boundary measures took %.2f s]\n", omp_get_wtime() - t_pre_bnd);

    double elapsed = omp_get_wtime() - start;

    if (gui_mode) {
        printf("Finite Element Method (Gauss-Legendre)\n");
        printf("==================\n\n");

        /* Compute per-station throughput. Clip to [0, min(μ_eff, α)]
         * so basis-truncation noise at near-saturated stations can't
         * produce Γ > capacity OR Γ > offered load — both unphysical.
         * Matches the same clip in fBNAsm / fBNAlp. */
        double gamma_sta[MAX_DIM];
        for (int i = 0; i < params.K; i++) {
            if (!params.has_service_rates) { gamma_sta[i] = 0.0; continue; }
            double g = params.service_rates[i] - delta[i];
            double alpha_i = params.theta[i] + params.service_rates[i];
            if (g < 0) g = 0;
            if (g > params.service_rates[i]) g = params.service_rates[i];
            if (alpha_i > 0 && g > alpha_i) g = alpha_i;
            gamma_sta[i] = g;
        }

        if (params.has_service_rates) {
            for (int i = 0; i < params.K; i++) {
                double rho_i = (params.service_rates[i] > 1e-12)
                    ? gamma_sta[i] / params.service_rates[i] : 0.0;
                printf("rho_%d = %.6f\n", i + 1, rho_i);
            }
            printf("\n");
            for (int i = 0; i < params.K; i++)
                printf("Gamma_%d = %.6f\n", i + 1, gamma_sta[i]);
            printf("\n");
            for (int i = 0; i < params.K; i++) {
                double sojourn = (gamma_sta[i] > 1e-12) ? q[i] / gamma_sta[i] : 0.0;
                printf("sojourn_%d = %.6f\n", i + 1, sojourn);
            }
            printf("\n");
        }

        {
            int w = 1;
            for (int t = params.K; t >= 10; t /= 10) w++;
            for (int i = 0; i < params.K; i++)
                printf("E[X_%0*d] = %.6f\n", w, i + 1, q[i]);
        }
        printf("\n");

        /* Per-class statistics */
        if (params.cc_num_classes > 0 && params.has_service_rates) {
            int Kcc = params.cc_num_classes;
            int d = params.K;

            double ew_sta[MAX_DIM];
            for (int i = 0; i < d; i++) {
                double sojourn_i = (gamma_sta[i] > 1e-12) ? q[i] / gamma_sta[i] : 0.0;
                ew_sta[i] = sojourn_i - 1.0 / params.service_rates[i];
                if (ew_sta[i] < 0) ew_sta[i] = 0;
            }

            for (int k = 0; k < Kcc; k++) {
                if (params.cc_lambda[k] < 1e-15) {
                    printf("W_total(class %d) = 0.000000\n", k + 1);
                    continue;
                }
                double w_total = 0.0;
                for (int i = 0; i < d; i++) {
                    double visit = params.cc_alpha[k][i] / params.cc_lambda[k];
                    w_total += visit * ew_sta[i];
                }
                printf("W_total(class %d) = %.6f\n", k + 1, w_total);
            }
            printf("\n");

            for (int k = 0; k < Kcc; k++) {
                if (params.cc_lambda[k] < 1e-15) {
                    printf("T_total(class %d) = 0.000000\n", k + 1);
                    continue;
                }
                double t_total = 0.0;
                for (int i = 0; i < d; i++) {
                    double visit = params.cc_alpha[k][i] / params.cc_lambda[k];
                    t_total += visit * (ew_sta[i] + 1.0 / params.cc_mu[k][i]);
                }
                printf("T_total(class %d) = %.6f\n", k + 1, t_total);
            }
            printf("\n");

            for (int k = 0; k < Kcc; k++) {
                double t_total = 0.0;
                if (params.cc_lambda[k] >= 1e-15) {
                    for (int i = 0; i < d; i++) {
                        double visit = params.cc_alpha[k][i] / params.cc_lambda[k];
                        t_total += visit * (ew_sta[i] + 1.0 / params.cc_mu[k][i]);
                    }
                }
                printf("N_total(class %d) = %.6f\n", k + 1, params.cc_lambda[k] * t_total);
            }
            printf("\n");
        }
    } else if (compact) {
        printf("Finite Element Method (Gauss-Legendre)\n");
        printf("==================\n");
        {
            int w = 1;
            for (int t = params.K; t >= 10; t /= 10) w++;
            for (int i = 0; i < params.K; i++) {
                printf("E[X_%0*d] = %.6f\n", w, i + 1, q[i]);
            }
        }
        printf("\n");
    } else {
        /* Display results — print E[X_k] last so they are always visible */
        printf("\n=== Results ===\n");

        printf("Boundary measures (delta):\n");
        for (int face = 0; face < 2 * params.K; face++) {
            int dim = face < params.K ? face : face - params.K;
            const char *type = face < params.K ? "lower" : "upper";
            printf("  delta(x_%d=%s) = %.6f\n", dim + 1, type, delta[face]);
        }

        printf("\nTotal time: %.2f seconds\n", elapsed);

        /* Print throughput if service rates available. Clipped to
         * [0, min(μ_eff, α)] to suppress unphysical artifacts. */
        if (params.has_service_rates) {
            printf("\n");
            for (int i = 0; i < params.K; i++) {
                /* delta grouped: delta[i] = lower face of dim i */
                double gamma_k = params.service_rates[i] - delta[i];
                double alpha_i = params.theta[i] + params.service_rates[i];
                if (gamma_k < 0) gamma_k = 0;
                if (gamma_k > params.service_rates[i]) gamma_k = params.service_rates[i];
                if (alpha_i > 0 && gamma_k > alpha_i) gamma_k = alpha_i;
                printf("Gamma_%d = %.6f\n", i + 1, gamma_k);
            }
        }

        printf("\n");
        {
            int w = 1;
            for (int t = params.K; t >= 10; t /= 10) w++;
            for (int i = 0; i < params.K; i++) {
                printf("E[X_%0*d] = %.6f\n", w, i + 1, q[i]);
            }
        }
    }

    /* Cleanup */
    cholmod_free_sparse(&A, &c);
    cholmod_finish(&c);
    free(y);
    free(u);

    return 0;
}
