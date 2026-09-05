/*
 * BNA/FM Algorithm - CBC-QMC Version (SuiteSparse + OpenMP)
 *
 * Brownian Network Analyzer with Finite Element Method
 * using CBC (Component-by-Component) lattice rules for integration.
 * Uses SuiteSparse (UMFPACK) for sparse linear system solving.
 * Parallelized with OpenMP for multi-core CPUs.
 *
 * Based on: Shen, Chen, Dai, Dai (2000)
 * QMC integration: Cools, Kuo, Nuyens (2006)
 *
 * Usage: ./bna_fm_cbc input_file [n_qmc_points]
 */

#include "bna_fm.h"
#include "qmc.h"
#include <time.h>
#include <pthread.h>
#include <omp.h>
#include <limits.h>
#include <stdlib.h>
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
        int node[MAX_DIM];
        for (int j = 0; j < K; j++) {
            if (c & (1 << j)) {
                node[j] = el[j] + 1;
            } else {
                node[j] = el[j];
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

/* Forward declaration */
static void idx_to_multi(int idx, const int *sizes, int K, int *multi);

/* ============================================================
 * 5-point Gauss-Legendre Quadrature (for boundary measure post-processing)
 * ============================================================ */

#define N_GAUSS_BM 5

static double gauss_bm_points[N_GAUSS_BM];
static double gauss_bm_weights[N_GAUSS_BM];

static void init_gauss_bm(void) {
    double a = sqrt(5.0 - 2.0 * sqrt(10.0 / 7.0)) / 3.0;
    double b = sqrt(5.0 + 2.0 * sqrt(10.0 / 7.0)) / 3.0;
    double wa = (322.0 + 13.0 * sqrt(70.0)) / 900.0;
    double wb = (322.0 - 13.0 * sqrt(70.0)) / 900.0;

    gauss_bm_points[0] = -b;  gauss_bm_points[1] = -a;
    gauss_bm_points[2] = 0.0; gauss_bm_points[3] =  a;
    gauss_bm_points[4] =  b;

    gauss_bm_weights[0] = wb;  gauss_bm_weights[1] = wa;
    gauss_bm_weights[2] = 128.0/225.0;
    gauss_bm_weights[3] = wa;  gauss_bm_weights[4] = wb;
}

static void compute_boundary_measures(const double *u, const BNAParams *params,
                                      double kappa, double *delta) {
    int K = params->K;
    int max_local = ipow(2, K) * ipow(2, K);

    for (int face = 0; face < 2 * K; face++) {
        int face_dim = face < K ? face : face - K;
        int is_lower = face < K;
        double face_val = is_lower ? params->lb[face_dim] : params->ub[face_dim];

        double v_k[MAX_DIM];
        for (int j = 0; j < K; j++) {
            v_k[j] = params->R[j][face];
        }

        int face_mesh[MAX_DIM];
        for (int j = 0; j < K; j++) {
            face_mesh[j] = (j == face_dim) ? 1 : params->mesh_n[j];
        }
        int n_face_elem = prod_int(face_mesh, K);
        int n_gp_face = ipow(N_GAUSS_BM, K - 1);

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

                int n_local = get_face_basis_funcs(K, params->mesh_n, fel,
                                                   face_dim, is_lower, basis);

                double fel_lb[MAX_DIM];
                for (int j = 0; j < K; j++) {
                    fel_lb[j] = params->lb[j] + (fel[j] - 1) * params->h[j];
                }

                for (int g = 0; g < n_gp_face; g++) {
                    int gidx[MAX_DIM];
                    int gi = g;
                    for (int j = 0; j < K; j++) {
                        if (j != face_dim) {
                            gidx[j] = gi % N_GAUSS_BM;
                            gi /= N_GAUSS_BM;
                        }
                    }

                    double x[MAX_DIM];
                    double w = 1.0;
                    for (int j = 0; j < K; j++) {
                        if (j == face_dim) {
                            x[j] = face_val;
                        } else {
                            x[j] = fel_lb[j] + (gauss_bm_points[gidx[j]] + 1.0) / 2.0 * params->h[j];
                            w *= gauss_bm_weights[gidx[j]] * params->h[j] / 2.0;
                        }
                    }

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
 * Multi-index Generation
 * ============================================================ */

static void idx_to_multi(int idx, const int *sizes, int K, int *multi) {
    for (int j = 0; j < K; j++) {
        multi[j] = idx % sizes[j];
        idx /= sizes[j];
    }
}

/* ============================================================
 * FEM System Assembly with CBC-QMC (OpenMP Parallelized)
 * ============================================================ */

static void build_fem_system(const BNAParams *params, int n_qmc,
                             SparseTriplet *A, double *y) {
    int K = params->K;
    /* Pre-flight before the assembly loop, not after it.
     *
     * The binding constraint here is TIME, not memory: a tensor-product mesh
     * has mesh^K elements, each visiting n_qmc quadrature points and
     * (2^K)^2 local basis pairs, while the working set stays modest. Measured
     * on this family: d=3 is 7.1e6 operations and 0.27 s; d=4 is 1.4e9 and
     * about a minute; d=5 is 2.6e11 and roughly three hours. A memory budget
     * cannot see that, so it is charged against a work budget instead.
     *
     * Default 8e9 operations (~5 minutes at the measured ~2.6e7 ops/s).
     * Override with BNAFM_MAX_WORK for a deliberate long run. Refusing with
     * the numbers beats a run that cannot be told apart from a hang. */
    {
        uint64_t elements = prod_u64(params->mesh_n, K);
        uint64_t points = (uint64_t) (n_qmc > 0 ? n_qmc : 1);
        uint64_t local = 1;
        for (int lb = 0; lb < K; lb++) local *= 4ULL;   /* (2^K)^2 */
        uint64_t work = elements * points * local;

        uint64_t work_budget = 8000000000ULL;
        const char *work_env = getenv("BNAFM_MAX_WORK");
        if (work_env && *work_env) {
            long long parsed = atoll(work_env);
            if (parsed > 0) work_budget = (uint64_t) parsed;
        }
        if (work > work_budget) {
            fprintf(stderr,
                "\nERROR: finite-element assembly exceeds the work budget.\n"
                "  mesh elements    : %llu (mesh^d)\n"
                "  quadrature points: %llu per element\n"
                "  local basis pairs: %llu per point\n"
                "  estimated work   : %.3e operations\n"
                "  budget           : %.3e operations\n"
                "  suggestion       : reduce the mesh resolution or the network\n"
                "                     dimension; a tensor-product mesh costs\n"
                "                     mesh^d elements, so each added station\n"
                "                     multiplies the work by mesh * N_GAUSS * 4.\n"
                "Set BNAFM_MAX_WORK=<operations> to override.\n",
                (unsigned long long) elements, (unsigned long long) points,
                (unsigned long long) local, (double) work, (double) work_budget);
            exit(2);
        }
        if (elements > (uint64_t) INT_MAX) {
            fprintf(stderr, "Error: mesh has %llu elements, beyond this "
                    "build's %d-element index limit.\n",
                    (unsigned long long) elements, INT_MAX);
            exit(2);
        }
    }
    int n_elem = prod_int(params->mesh_n, K);
    int max_local = ipow(2, K) * ipow(2, K);
    int n_basis = get_n_basis(K, params->mesh_n);

    int n_threads = omp_get_max_threads();
    if (!g_compact) {
        printf("  Using %d OpenMP threads\n", n_threads);
        printf("  Processing %d elements for volume integrals...\n", n_elem);
    }

    /* Open the unified progress file. Total = n_elem; downstream
     * CBC LP solve is opaque so the wrapper switches to a spinner
     * appended to the full bar after this assembly completes. */
    progress_open((long)n_elem);

    /* Pre-generate all QMC points for volume integrals */
    double *qmc_pts = (double*)malloc(n_qmc * K * sizeof(double));
    {
        qmc_lattice_seq_t seq;
        qmc_lattice_seq_init(&seq, K, 0);
        for (int i = 0; i < n_qmc; i++) {
            for (int j = 0; j < K; j++) {
                qmc_pts[i * K + j] = seq.x[j];
            }
            qmc_lattice_seq_next(&seq);
        }
    }

    double vol = prod_double(params->h, K);
    double w = vol / n_qmc;

    /* Create thread-local triplet storage with dedup-on-insert.
     * Without dedup the per-thread COO buffer collects ~max_local² entries
     * per element with massive overlap between adjacent elements (cubic
     * Hermite basis sharing), inflating peak RAM and downstream
     * triplet→CHOLMOD conversion by ~50× at K=4. The hash-table dedup
     * collapses these into unique (row,col) entries on insertion. */
    SparseTriplet **thread_triplets = (SparseTriplet**)malloc(n_threads * sizeof(SparseTriplet*));
    for (int t = 0; t < n_threads; t++) {
        int per_thread_elem = n_elem / n_threads + 1;
        int approx_unique = per_thread_elem * max_local;
        if (approx_unique > n_basis) approx_unique = n_basis;
        approx_unique *= 16;
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
            int el[MAX_DIM];
            idx_to_multi(e, params->mesh_n, K, el);
            for (int j = 0; j < K; j++) el[j] += 1;

            double el_lb[MAX_DIM];
            for (int j = 0; j < K; j++) {
                el_lb[j] = params->lb[j] + (el[j] - 1) * params->h[j];
            }

            int n_local = get_element_basis_funcs(K, params->mesh_n, el, basis);

            memset(A_local, 0, n_local * n_local * sizeof(double));
            memset(y_local, 0, n_local * sizeof(double));

            /* QMC integration */
            for (int q = 0; q < n_qmc; q++) {
                double x[MAX_DIM];
                for (int j = 0; j < K; j++) {
                    x[j] = el_lb[j] + qmc_pts[q * K + j] * params->h[j];
                }

                for (int i = 0; i < n_local; i++) {
                    Lf_vals[i] = eval_Lf_at_x(x, basis[i].node, basis[i].r, params);
                }

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

    free(qmc_pts);

    /* Merge thread-local results into global */
    for (int t = 0; t < n_threads; t++) {
        SparseTriplet *src = thread_triplets[t];
        for (int k = 0; k < src->nnz; k++) {
            sparse_triplet_add(A, src->row[k], src->col[k], src->val[k]);
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
        /* Generate QMC points for face integrals */
        double *qmc_pts_face = (double*)malloc(n_qmc * (K - 1) * sizeof(double));
        {
            qmc_lattice_seq_t seq;
            qmc_lattice_seq_init(&seq, K - 1, 0);
            for (int i = 0; i < n_qmc; i++) {
                for (int j = 0; j < K - 1; j++) {
                    qmc_pts_face[i * (K - 1) + j] = seq.x[j];
                }
                qmc_lattice_seq_next(&seq);
            }
        }

        for (int face = 0; face < 2 * K; face++) {
            int face_dim = face < K ? face : face - K;
            double face_val = face < K ? params->lb[face_dim] : params->ub[face_dim];
            int is_lower = face < K;

            double v_k[MAX_DIM];
            for (int j = 0; j < K; j++) {
                v_k[j] = params->R[j][face];
            }

            int face_mesh[MAX_DIM];
            for (int j = 0; j < K; j++) {
                face_mesh[j] = (j == face_dim) ? 1 : params->mesh_n[j];
            }
            int n_face_elem = prod_int(face_mesh, K);

            double face_area = 1.0;
            for (int j = 0; j < K; j++) {
                if (j != face_dim) face_area *= params->h[j];
            }
            double wf = face_area / n_qmc;

            /* Create thread-local triplets for boundary with dedup-on-insert. */
            SparseTriplet **face_triplets = (SparseTriplet**)malloc(n_threads * sizeof(SparseTriplet*));
            for (int t = 0; t < n_threads; t++) {
                int per_thread_face = n_face_elem / n_threads + 1;
                int approx_unique = per_thread_face * max_local;
                if (approx_unique > n_basis) approx_unique = n_basis;
                approx_unique *= 16;
                if (approx_unique > n_basis * 32) approx_unique = n_basis * 32;
                int cap = approx_unique > 1024 ? approx_unique : 1024;
                face_triplets[t] = sparse_triplet_create(n_basis, n_basis, cap);
                sparse_triplet_enable_dedup(face_triplets[t], approx_unique);
            }

            #pragma omp parallel
            {
                int tid = omp_get_thread_num();
                SparseTriplet *my_triplet = face_triplets[tid];

                LocalBasis *basis = (LocalBasis*)malloc(max_local * sizeof(LocalBasis));
                double *A_local = (double*)malloc(max_local * max_local * sizeof(double));

                #pragma omp for schedule(dynamic, 4)
                for (int fe = 0; fe < n_face_elem; fe++) {
                    int fel[MAX_DIM];
                    idx_to_multi(fe, face_mesh, K, fel);
                    for (int j = 0; j < K; j++) fel[j] += 1;
                    fel[face_dim] = 1;

                    int n_local = get_face_basis_funcs(K, params->mesh_n, fel,
                                                       face_dim, is_lower, basis);

                    memset(A_local, 0, n_local * n_local * sizeof(double));

                    double fel_lb[MAX_DIM];
                    for (int j = 0; j < K; j++) {
                        fel_lb[j] = params->lb[j] + (fel[j] - 1) * params->h[j];
                    }

                    for (int q = 0; q < n_qmc; q++) {
                        double x[MAX_DIM];
                        int qidx = 0;
                        for (int j = 0; j < K; j++) {
                            if (j == face_dim) {
                                x[j] = face_val;
                            } else {
                                x[j] = fel_lb[j] + qmc_pts_face[q * (K-1) + qidx] * params->h[j];
                                qidx++;
                            }
                        }

                        double Df_vals[256];
                        for (int i = 0; i < n_local; i++) {
                            double grad_f[MAX_DIM];
                            eval_grad_f_at_x(x, basis[i].node, basis[i].r, params, grad_f);
                            Df_vals[i] = 0.0;
                            for (int j = 0; j < K; j++) {
                                Df_vals[i] += v_k[j] * grad_f[j];
                            }
                        }

                        for (int i = 0; i < n_local; i++) {
                            for (int j = 0; j < n_local; j++) {
                                A_local[i * n_local + j] += wf * Df_vals[i] * Df_vals[j];
                            }
                        }
                    }

                    for (int i = 0; i < n_local; i++) {
                        int gi = basis[i].global_idx;
                        for (int j = 0; j < n_local; j++) {
                            int gj = basis[j].global_idx;
                            sparse_triplet_add(my_triplet, gi, gj, A_local[i * n_local + j]);
                        }
                    }
                }

                free(basis);
                free(A_local);
            }

            /* Merge boundary triplets */
            for (int t = 0; t < n_threads; t++) {
                SparseTriplet *src = face_triplets[t];
                for (int k = 0; k < src->nnz; k++) {
                    sparse_triplet_add(A, src->row[k], src->col[k], src->val[k]);
                }
                sparse_triplet_free(src);
            }
            free(face_triplets);
        }

        free(qmc_pts_face);
    }
}

/* ============================================================
 * Compute Stationary Mean (OpenMP Parallelized)
 * ============================================================ */

static void compute_stationary_mean(const double *u, const BNAParams *params,
                                    int n_qmc, double *q, double *kappa_out) {
    int K = params->K;
    int n_elem = prod_int(params->mesh_n, K);
    int max_local = ipow(2, K) * ipow(2, K);

    /* Generate QMC points */
    double *qmc_pts = (double*)malloc(n_qmc * K * sizeof(double));
    {
        qmc_lattice_seq_t seq;
        qmc_lattice_seq_init(&seq, K, 0);
        for (int i = 0; i < n_qmc; i++) {
            for (int j = 0; j < K; j++) {
                qmc_pts[i * K + j] = seq.x[j];
            }
            qmc_lattice_seq_next(&seq);
        }
    }

    double vol = prod_double(params->h, K);
    double w = vol / n_qmc;

    double integral_one = vol * n_elem;
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

            for (int qi = 0; qi < n_qmc; qi++) {
                double x[MAX_DIM];
                for (int j = 0; j < K; j++) {
                    x[j] = el_lb[j] + qmc_pts[qi * K + j] * params->h[j];
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

            for (int qi = 0; qi < n_qmc; qi++) {
                double x[MAX_DIM];
                for (int j = 0; j < K; j++) {
                    x[j] = el_lb[j] + qmc_pts[qi * K + j] * params->h[j];
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

    free(qmc_pts);
}

/* ============================================================
 * Main
 * ============================================================ */

int main(int argc, char *argv[]) {
    /* Scan for -c/-G flags, input file, and optional QMC points */
    int compact = 0;
    int gui_mode = 0;
    const char *input_file = NULL;
    const char *qmc_arg = NULL;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-c") == 0) {
            compact = 1;
        } else if (strcmp(argv[i], "-G") == 0) {
            gui_mode = 1;
        } else if (strcmp(argv[i], "-P") == 0 && i + 1 < argc) {
            strncpy(g_progress_path, argv[++i], sizeof(g_progress_path) - 1);
            g_progress_path[sizeof(g_progress_path) - 1] = '\0';
        } else if (argv[i][0] != '-') {
            if (!input_file)
                input_file = argv[i];
            else
                qmc_arg = argv[i];
        }
    }

    if (!input_file) {
        fprintf(stderr, "Usage: %s input_file [n_qmc_points] [-c]\n", argv[0]);
        return 1;
    }

    int n_qmc = 256;  /* Default */
    if (qmc_arg) {
        n_qmc = atoi(qmc_arg);
        /* Round up to power of 2 */
        int pow2 = 1;
        while (pow2 < n_qmc) pow2 <<= 1;
        n_qmc = pow2;
    }

    if (gui_mode) compact = 1;
    g_compact = compact;

    if (!compact)
        printf("=== BNA/FM Algorithm (CBC-QMC + SuiteSparse + OpenMP) ===\n");
    init_gauss_bm();

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
    if (!compact) {
        printf("Number of basis functions: %d\n", n_basis);
        printf("QMC points per element: %d\n", n_qmc);
    }

    /* Memory guardrail. Same scaling as the Gauss-Legendre variant —
       O(n_basis) dense vectors plus a sparse triplet capacity of
       100*n_basis. ~2 KB per basis is a safe approximation of the
       dominant memory footprint. */
    {
        uint64_t bytes = (uint64_t) n_basis * (uint64_t) 2048;
        bnet_memcheck_alloc(bytes,
            "FE CBC-QMC system",
            "reduce mesh_n (per-dimension grid) or K (network dimension); "
            "n_basis grows as prod(mesh_n[i]+1) * 2^K");
    }

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
    build_fem_system(&params, n_qmc, A_triplet, y);
    if (!compact)
        printf("  [build_fem_system took %.2f s]\n", omp_get_wtime() - t_pre_build);

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
     * can dominate wall time for large meshes — heads up for large
     * systems so the user doesn't think the program is hung. */
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
    compute_stationary_mean(u, &params, n_qmc, q, &kappa);
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
        printf("Finite Element Method (CBC-QMC)\n");
        printf("==================\n\n");

        /* Compute per-station throughput. Clip to [0, min(μ_eff, α)]
         * so basis-truncation noise at near-saturated stations can't
         * produce Γ > capacity OR Γ > offered load. Matches the same
         * clip in fBNAsm / fBNAlp / bna_fm_gauss. */
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
        printf("Finite Element Method (CBC-QMC)\n");
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
