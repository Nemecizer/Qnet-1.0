/*
 * bna_sbd.c  --  SBD (Sequential Bottleneck Decomposition)
 *                after Dai, Nguyen & Reiman (1994)
 *
 * Hybrid decomposition / heavy-traffic method for generalized
 * Jackson networks.  Stations are partitioned into ordered
 * subnetworks and each is analyzed via a Reflected Brownian
 * Motion (RBM).
 *
 * Usage:  bna_sbd <input_file> [-c] [-n degree] [-p "partition"]
 *         -c           compact output
 *         -n degree    polynomial degree for bnet (default 5)
 *         -p "2,3|1"   manual partition (groups separated by |)
 *
 * Build:  gcc -Wall -O2 -ansi -pedantic -o bna_sbd bna_sbd.c -lm
 *
 * Reference:
 *   J. G. Dai, V. Nguyen, and M. I. Reiman, "Sequential Bottleneck
 *   Decomposition: An Approximation Method for Generalized Jackson
 *   Networks," Operations Research, Vol. 42, No. 1, pp. 119-136,
 *   January-February 1994.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <unistd.h>
#include <sys/wait.h>
#include "../../common/bnet_memcheck.h"

#define MAX_NODES  64
#define MAX_GROUPS 64
#define LINE_BUF   4096
#define BNET_BUF   4096

/* ── Network data ─────────────────────────────────────────────── */

static int    n;                          /* number of stations (J)    */
static int    servers[MAX_NODES];         /* servers per node (all 1)  */
static double alpha[MAX_NODES];           /* external arrival rate     */
static double ca_sq[MAX_NODES];           /* external arrival SCV      */
static double tau[MAX_NODES];             /* mean service time         */
static double cs_sq[MAX_NODES];           /* service time SCV          */
static double P[MAX_NODES][MAX_NODES];    /* routing matrix            */

/* ── Traffic solution ─────────────────────────────────────────── */

static double lambda[MAX_NODES];          /* total arrival rate        */
static double rho[MAX_NODES];             /* utilization = lambda*tau  */

/* ── Partition ────────────────────────────────────────────────── */

static int    num_groups;
static int    group_size[MAX_GROUPS];
static int    group[MAX_GROUPS][MAX_NODES]; /* group[g][k] = station index */
static int    station_group[MAX_NODES];     /* which group a station is in */

/* ── Results ──────────────────────────────────────────────────── */

static double EW[MAX_NODES];              /* mean waiting time         */
static double ET[MAX_NODES];              /* mean sojourn time         */
static double EN[MAX_NODES];              /* mean number in system     */
static double rho_hat[MAX_NODES];         /* modified utilization      */

/* ── Options ──────────────────────────────────────────────────── */

static int    compact = 0;
static int    poly_degree = 5;
static char   manual_partition[LINE_BUF] = "";
static int    fallback_used = 0;

/* Path to bnet binary, resolved at startup. Search order in main():
 *   1. $BNET_BIN env var, if set
 *   2. dirname(argv[0])/../BNAsm/bnet  (works for any cwd when both
 *      bna_sbd and bnet live in their canonical directory layout)
 *   3. ../BNAsm/bnet  (legacy fallback for cwd = BNAsbd)
 * The previous hard-coded "../BNAsm/bnet" only resolved when the
 * caller's cwd was BNAsbd, so Run Comparison (cwd = temp dir) silently
 * fell back to the 1-D RBM approximation. */
static char   bnet_bin[1024] = "../BNAsm/bnet";

/* ================================================================
 *  Input parser  (same format as bna_qna.c)
 * ================================================================ */

static int next_line(FILE *fp, char *buf, int size)
{
    while (fgets(buf, size, fp)) {
        char *p = buf;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '#' || *p == '\n' || *p == '\r' || *p == '\0')
            continue;
        return 1;
    }
    return 0;
}

static void parse_input(const char *filename)
{
    FILE *fp;
    char buf[LINE_BUF];
    int i, j;

    fp = fopen(filename, "r");
    if (!fp) {
        fprintf(stderr, "bna_sbd: cannot open '%s'\n", filename);
        exit(1);
    }

    /* n */
    if (!next_line(fp, buf, LINE_BUF)) goto bad;
    if (sscanf(buf, "%d", &n) != 1 || n < 1 || n > MAX_NODES) {
        fprintf(stderr, "bna_sbd: invalid n = %d (max %d)\n", n, MAX_NODES);
        exit(1);
    }

    /* servers per node */
    if (!next_line(fp, buf, LINE_BUF)) goto bad;
    {
        char *tok = strtok(buf, " \t\n\r");
        for (i = 0; i < n; i++) {
            if (!tok) goto bad;
            servers[i] = atoi(tok);
            if (servers[i] < 1) servers[i] = 1;
            tok = strtok(NULL, " \t\n\r");
        }
    }

    /* alpha (external arrival rates) */
    if (!next_line(fp, buf, LINE_BUF)) goto bad;
    {
        char *tok = strtok(buf, " \t\n\r");
        for (i = 0; i < n; i++) {
            if (!tok) goto bad;
            alpha[i] = atof(tok);
            tok = strtok(NULL, " \t\n\r");
        }
    }

    /* ca^2 (external arrival SCVs) */
    if (!next_line(fp, buf, LINE_BUF)) goto bad;
    {
        char *tok = strtok(buf, " \t\n\r");
        for (i = 0; i < n; i++) {
            if (!tok) goto bad;
            ca_sq[i] = atof(tok);
            tok = strtok(NULL, " \t\n\r");
        }
    }

    /* tau (mean service times) */
    if (!next_line(fp, buf, LINE_BUF)) goto bad;
    {
        char *tok = strtok(buf, " \t\n\r");
        for (i = 0; i < n; i++) {
            if (!tok) goto bad;
            tau[i] = atof(tok);
            tok = strtok(NULL, " \t\n\r");
        }
    }

    /* cs^2 (service time SCVs) */
    if (!next_line(fp, buf, LINE_BUF)) goto bad;
    {
        char *tok = strtok(buf, " \t\n\r");
        for (i = 0; i < n; i++) {
            if (!tok) goto bad;
            cs_sq[i] = atof(tok);
            tok = strtok(NULL, " \t\n\r");
        }
    }

    /* P matrix (n rows) */
    for (i = 0; i < n; i++) {
        char *tok;
        if (!next_line(fp, buf, LINE_BUF)) goto bad;
        tok = strtok(buf, " \t\n\r");
        for (j = 0; j < n; j++) {
            if (!tok) goto bad;
            P[i][j] = atof(tok);
            tok = strtok(NULL, " \t\n\r");
        }
    }

    fclose(fp);
    return;

bad:
    fprintf(stderr, "bna_sbd: premature end of input in '%s'\n", filename);
    fclose(fp);
    exit(1);
}

/* ================================================================
 *  Solve traffic equations:  lambda = (I - P')^{-1} alpha
 *  via Gaussian elimination with partial pivoting
 * ================================================================ */

static void solve_traffic(void)
{
    double A[MAX_NODES][MAX_NODES];
    double b[MAX_NODES];
    int i, j, col, row, maxRow;
    double maxVal, factor, pivot;

    /* Build A = I - P' */
    for (i = 0; i < n; i++) {
        for (j = 0; j < n; j++)
            A[i][j] = (i == j ? 1.0 : 0.0) - P[j][i];
        b[i] = alpha[i];
    }

    /* Forward elimination */
    for (col = 0; col < n; col++) {
        maxVal = fabs(A[col][col]);
        maxRow = col;
        for (row = col + 1; row < n; row++) {
            if (fabs(A[row][col]) > maxVal) {
                maxVal = fabs(A[row][col]);
                maxRow = row;
            }
        }
        if (maxRow != col) {
            for (j = 0; j < n; j++) {
                double tmp = A[col][j];
                A[col][j] = A[maxRow][j];
                A[maxRow][j] = tmp;
            }
            { double tmp = b[col]; b[col] = b[maxRow]; b[maxRow] = tmp; }
        }
        pivot = A[col][col];
        if (fabs(pivot) < 1e-15) {
            fprintf(stderr, "bna_sbd: singular traffic-rate matrix\n");
            exit(1);
        }
        for (row = col + 1; row < n; row++) {
            factor = A[row][col] / pivot;
            for (j = col; j < n; j++)
                A[row][j] -= factor * A[col][j];
            b[row] -= factor * b[col];
        }
    }

    /* Back substitution */
    for (i = n - 1; i >= 0; i--) {
        lambda[i] = b[i];
        for (j = i + 1; j < n; j++)
            lambda[i] -= A[i][j] * lambda[j];
        lambda[i] /= A[i][i];
    }

    /* Compute utilizations */
    for (i = 0; i < n; i++) {
        rho[i] = lambda[i] * tau[i];
        if (rho[i] >= 1.0) {
            fprintf(stderr, "bna_sbd: station %d overloaded (rho = %.6f)\n",
                    i + 1, rho[i]);
            exit(1);
        }
    }
}

/* ================================================================
 *  Partition stations into ordered subnetworks
 * ================================================================ */

static void parse_manual_partition(void)
{
    /* Format: "2,3|1" means S1={2,3}, S2={1} (1-indexed) */
    char buf[LINE_BUF];
    char *grp, *tok;
    int g, k;

    strncpy(buf, manual_partition, LINE_BUF - 1);
    buf[LINE_BUF - 1] = '\0';

    num_groups = 0;
    for (g = 0; g < MAX_GROUPS; g++)
        group_size[g] = 0;

    grp = strtok(buf, "|");
    while (grp && num_groups < MAX_GROUPS) {
        g = num_groups++;
        /* Parse comma-separated station numbers within this group */
        /* Need a second tokenizer - use manual parsing */
        {
            char grp_copy[LINE_BUF];
            strncpy(grp_copy, grp, LINE_BUF - 1);
            grp_copy[LINE_BUF - 1] = '\0';
            tok = grp_copy;
            while (*tok) {
                int stn;
                while (*tok == ' ' || *tok == '\t') tok++;
                if (*tok == '\0') break;
                stn = atoi(tok) - 1;  /* convert to 0-indexed */
                if (stn >= 0 && stn < n) {
                    k = group_size[g]++;
                    group[g][k] = stn;
                    station_group[stn] = g;
                }
                while (*tok && *tok != ',') tok++;
                if (*tok == ',') tok++;
            }
        }
        grp = strtok(NULL, "|");
    }
}

static void partition_stations(void)
{
    int sorted[MAX_NODES];
    int i, j, g;
    double group_min_rho;

    if (manual_partition[0] != '\0') {
        parse_manual_partition();
        return;
    }

    /* Sort stations by rho (ascending) - insertion sort */
    for (i = 0; i < n; i++) sorted[i] = i;
    for (i = 1; i < n; i++) {
        int key = sorted[i];
        double key_rho = rho[key];
        j = i - 1;
        while (j >= 0 && rho[sorted[j]] > key_rho) {
            sorted[j + 1] = sorted[j];
            j--;
        }
        sorted[j + 1] = key;
    }

    /* Group by proximity: new group when ratio > 1.5 or size > 5 */
    num_groups = 0;
    for (i = 0; i < n; i++) {
        int stn = sorted[i];
        if (num_groups == 0) {
            g = num_groups++;
            group_size[g] = 0;
            group[g][group_size[g]++] = stn;
            station_group[stn] = g;
            group_min_rho = rho[stn];
        } else {
            g = num_groups - 1;
            if (group_size[g] >= 5 ||
                (group_min_rho > 1e-10 && rho[stn] / group_min_rho > 1.5)) {
                g = num_groups++;
                group_size[g] = 0;
                group[g][group_size[g]++] = stn;
                station_group[stn] = g;
                group_min_rho = rho[stn];
            } else {
                group[g][group_size[g]++] = stn;
                station_group[stn] = g;
            }
        }
    }
}

/* ================================================================
 *  Linear algebra helpers
 * ================================================================ */

/* Solve A*x = b in-place (A is dim x dim row-major flat, b is rhs,
   result in b). Uses Gaussian elimination with partial pivoting. */
static void gauss_solve_flat(int dim, double *A, double *b)
{
    #define G_A(i,j) A[(size_t)(i) * (size_t)dim + (size_t)(j)]
    int col, row, j, maxRow;
    double maxVal, factor, pivot;

    for (col = 0; col < dim; col++) {
        maxVal = fabs(G_A(col, col));
        maxRow = col;
        for (row = col + 1; row < dim; row++) {
            if (fabs(G_A(row, col)) > maxVal) {
                maxVal = fabs(G_A(row, col));
                maxRow = row;
            }
        }
        if (maxRow != col) {
            for (j = 0; j < dim; j++) {
                double tmp = G_A(col, j);
                G_A(col, j) = G_A(maxRow, j);
                G_A(maxRow, j) = tmp;
            }
            { double tmp = b[col]; b[col] = b[maxRow]; b[maxRow] = tmp; }
        }
        pivot = G_A(col, col);
        if (fabs(pivot) < 1e-15) {
            fprintf(stderr, "bna_sbd: singular matrix in gauss_solve\n");
            exit(EXIT_FAILURE);
        }
        for (row = col + 1; row < dim; row++) {
            factor = G_A(row, col) / pivot;
            for (j = col; j < dim; j++)
                G_A(row, j) -= factor * G_A(col, j);
            b[row] -= factor * b[col];
        }
    }

    for (col = dim - 1; col >= 0; col--) {
        for (j = col + 1; j < dim; j++)
            b[col] -= G_A(col, j) * b[j];
        b[col] /= G_A(col, col);
    }
    #undef G_A
}

/* Invert a dim x dim matrix M (flat row-major), result in Minv (flat
   row-major). Uses Gauss-Jordan elimination with partial pivoting.
   Internal workspace W is heap-allocated so dim can be arbitrary
   (pre-fix: stack-allocated W[MAX_NODES][2*MAX_NODES] segfaulted at
   MAX_NODES > 512). */
static void invert_matrix_flat(int dim, const double *M, double *Minv)
{
    int i, j, col, maxRow;
    double maxVal, pivot, factor;
    double *W = (double *)malloc((size_t)dim * (size_t)(2 * dim) * sizeof(double));
    if (!W) {
        fprintf(stderr, "bna_sbd: out of memory in invert_matrix (dim=%d)\n", dim);
        exit(EXIT_FAILURE);
    }
    #define WW(i,j) W[(size_t)(i) * (size_t)(2 * dim) + (size_t)(j)]

    /* Augment [M | I] */
    for (i = 0; i < dim; i++) {
        for (j = 0; j < dim; j++) {
            WW(i, j) = M[(size_t)i * (size_t)dim + (size_t)j];
            WW(i, dim + j) = (i == j) ? 1.0 : 0.0;
        }
    }

    /* Forward elimination */
    for (col = 0; col < dim; col++) {
        maxVal = fabs(WW(col, col));
        maxRow = col;
        for (i = col + 1; i < dim; i++) {
            if (fabs(WW(i, col)) > maxVal) {
                maxVal = fabs(WW(i, col));
                maxRow = i;
            }
        }
        if (maxRow != col) {
            for (j = 0; j < 2 * dim; j++) {
                double tmp = WW(col, j);
                WW(col, j) = WW(maxRow, j);
                WW(maxRow, j) = tmp;
            }
        }
        pivot = WW(col, col);
        if (fabs(pivot) < 1e-15) {
            fprintf(stderr, "bna_sbd: singular matrix in invert_matrix\n");
            free(W);
            exit(EXIT_FAILURE);
        }
        for (j = 0; j < 2 * dim; j++)
            WW(col, j) /= pivot;
        for (i = 0; i < dim; i++) {
            if (i != col) {
                factor = WW(i, col);
                for (j = 0; j < 2 * dim; j++)
                    WW(i, j) -= factor * WW(col, j);
            }
        }
    }

    /* Extract inverse */
    for (i = 0; i < dim; i++)
        for (j = 0; j < dim; j++)
            Minv[(size_t)i * (size_t)dim + (size_t)j] = WW(i, dim + j);

    free(W);
    #undef WW
}

/* ================================================================
 *  Run bnet for a multi-station subnetwork
 *
 *  Writes RBM parameters to a temp file, calls bnet -v 0,
 *  and parses E[Q_j] values from stdout.
 * ================================================================ */

static int run_bnet(int dim, double mu[], const double *Omega,
                    const double *R, double EQ[])
{
    char tmpname[256];
    FILE *fp;
    char buf[BNET_BUF];
    char cmd[2304];
    FILE *pp;
    int i, j, count, child_status;

    /* Write temp input file */
    snprintf(tmpname, sizeof(tmpname), "/tmp/bna_sbd_%d.in", (int)getpid());
    fp = fopen(tmpname, "w");
    if (!fp) {
        fprintf(stderr, "bna_sbd: cannot create temp file '%s'\n", tmpname);
        return -1;
    }

    fprintf(fp, "%d\n\n", dim);

    /* Drift vector mu */
    for (i = 0; i < dim; i++)
        fprintf(fp, "  %.15e", mu[i]);
    fprintf(fp, "\n\n");

    /* Covariance matrix Omega (flat, dim×dim row-major) */
    for (i = 0; i < dim; i++) {
        for (j = 0; j < dim; j++)
            fprintf(fp, "  %.15e", Omega[(size_t)i * (size_t)dim + (size_t)j]);
        fprintf(fp, "\n");
    }
    fprintf(fp, "\n");

    /* Reflection matrix R (flat, dim×dim row-major) */
    for (i = 0; i < dim; i++) {
        for (j = 0; j < dim; j++)
            fprintf(fp, "  %.15e", R[(size_t)i * (size_t)dim + (size_t)j]);
        fprintf(fp, "\n");
    }
    fprintf(fp, "\n");

    /* Polynomial degree */
    fprintf(fp, "%d\n", poly_degree);

    fclose(fp);

    /* Invoke bnet (path resolved by main() into bnet_bin) */
    if (strchr(bnet_bin, '"') != NULL || strchr(tmpname, '"') != NULL) {
        fprintf(stderr, "bna_sbd: unsafe quote in bnet or temporary-file path\n");
        remove(tmpname);
        return -1;
    }
    if (snprintf(cmd, sizeof(cmd), "\"%s\" -v 0 \"%s\"",
                 bnet_bin, tmpname) >= (int)sizeof(cmd)) {
        fprintf(stderr, "bna_sbd: bnet command path is too long\n");
        remove(tmpname);
        return -1;
    }
    pp = popen(cmd, "r");
    if (!pp) {
        fprintf(stderr, "bna_sbd: cannot run bnet\n");
        remove(tmpname);
        return -1;
    }

    /* Parse E[Q_j] = value lines */
    count = 0;
    while (fgets(buf, BNET_BUF, pp) && count < dim) {
        double val;
        if (sscanf(buf, "E[Q_%*d] = %lf", &val) == 1) {
            EQ[count++] = val;
        }
    }

    child_status = pclose(pp);
    remove(tmpname);

    if (child_status == -1) {
        fprintf(stderr, "bna_sbd: could not collect bnet exit status\n");
        return -1;
    }
    if (!WIFEXITED(child_status) || WEXITSTATUS(child_status) != 0) {
        if (WIFEXITED(child_status))
            fprintf(stderr, "bna_sbd: bnet exited with status %d\n",
                    WEXITSTATUS(child_status));
        else
            fprintf(stderr, "bna_sbd: bnet terminated abnormally\n");
        return -1;
    }

    if (count != dim) {
        fprintf(stderr, "bna_sbd: bnet returned %d values, expected %d\n",
                count, dim);
        return -1;
    }

    return 0;
}

/* ================================================================
 *  Solve one subnetwork  (Section 2.2 of the paper)
 *
 *  gn = group index for the "balanced" subnetwork B = S_n
 *  U = union of all groups with index < gn  (underloaded)
 *  O = union of all groups with index > gn  (overloaded)
 * ================================================================ */

static void solve_subnetwork(int gn)
{
    int B[MAX_NODES], nB = 0;   /* balanced stations (indices into global) */
    int U[MAX_NODES], nU = 0;   /* underloaded stations                   */
    int O[MAX_NODES], nO = 0;   /* overloaded stations                    */
    int is_B[MAX_NODES], is_U[MAX_NODES], is_O[MAX_NODES];

    /* Modified routing and arrival parameters. The three n×n matrices are
     * heap-allocated to remove the MAX_NODES²-on-stack pressure that
     * segfaulted at MAX_NODES > ~512 (pre-fix). Indexed via the flat
     * macros below. The smaller per-subnetwork arrays (size nB ≤ ~5)
     * stay on the stack since they're tiny. */
    {
        /* Three n×n + a transient ImPt n×n + (later) a 2n×n inversion
         * workspace inside invert_matrix_flat. Budget the worst case so
         * the user gets a clean error before we start malloc'ing. */
        uint64_t nn = (uint64_t)n * (uint64_t)n * sizeof(double);
        bnet_memcheck_alloc(6 * nn,
            "SBD per-subnetwork n×n scratch",
            "reduce the number of stations or run with more RAM");
    }
    double *Ptilde = (double *)malloc((size_t)n * (size_t)n * sizeof(double));
    double *Qtilde = (double *)malloc((size_t)n * (size_t)n * sizeof(double));
    double *Phat   = (double *)malloc((size_t)n * (size_t)n * sizeof(double));
    if (!Ptilde || !Qtilde || !Phat) {
        fprintf(stderr, "bna_sbd: out of memory in solve_subnetwork (n=%d)\n", n);
        exit(EXIT_FAILURE);
    }
    #define PT(i,j)  Ptilde[(size_t)(i) * (size_t)n + (size_t)(j)]
    #define QT(i,j)  Qtilde[(size_t)(i) * (size_t)n + (size_t)(j)]
    #define PH(i,j)  Phat  [(size_t)(i) * (size_t)n + (size_t)(j)]

    double alpha_hat[MAX_NODES];          /* modified arrivals (sized by n) */
    double lambda_hat[MAX_NODES];         /* modified throughputs (sized by n) */

    /* RBM parameters: actual size is nB × nB / nB-vec, but we don't yet
     * know nB at this point. Allocate after classification, sized to
     * group_size ≤ 5 in practice. Heap-alloc keeps the function frame
     * small even when MAX_NODES is large. Indexed via the M_/V_ macros
     * below using nB as stride. */
    double *Ghat  = NULL;
    double *Omega = NULL;
    double *Rhat  = NULL;
    double *mu_rbm = NULL;
    double *EQ    = NULL;
    #define GH(i,j) Ghat [(size_t)(i) * (size_t)nB + (size_t)(j)]
    #define OM(i,j) Omega[(size_t)(i) * (size_t)nB + (size_t)(j)]
    #define RH(i,j) Rhat [(size_t)(i) * (size_t)nB + (size_t)(j)]
    #define SBD_FREE_ALL() do {                                       \
        free(Ptilde); free(Qtilde); free(Phat);                       \
        free(Ghat); free(Omega); free(Rhat); free(mu_rbm); free(EQ);  \
    } while (0)

    int i, j, k, ii, jj;

    /* ── Classify stations ─────────────────────────────────── */

    memset(is_B, 0, sizeof(is_B));
    memset(is_U, 0, sizeof(is_U));
    memset(is_O, 0, sizeof(is_O));

    for (i = 0; i < n; i++) {
        int g = station_group[i];
        if (g < gn) {
            U[nU++] = i;
            is_U[i] = 1;
        } else if (g == gn) {
            B[nB++] = i;
            is_B[i] = 1;
        } else {
            O[nO++] = i;
            is_O[i] = 1;
        }
    }

    /* nB now known — allocate the per-subnetwork (nB × nB) RBM matrices.
     * Allocate at least 1 element so a degenerate empty group doesn't
     * call malloc(0). */
    {
        size_t nbsq = (size_t)(nB ? nB : 1) * (size_t)(nB ? nB : 1);
        size_t nbv  = (size_t)(nB ? nB : 1);
        Ghat   = (double *)calloc(nbsq, sizeof(double));
        Omega  = (double *)calloc(nbsq, sizeof(double));
        Rhat   = (double *)calloc(nbsq, sizeof(double));
        mu_rbm = (double *)calloc(nbv,  sizeof(double));
        EQ     = (double *)calloc(nbv,  sizeof(double));
        if (!Ghat || !Omega || !Rhat || !mu_rbm || !EQ) {
            fprintf(stderr,
                "bna_sbd: out of memory in solve_subnetwork (nB=%d)\n", nB);
            exit(EXIT_FAILURE);
        }
    }

    /* ── Build Ptilde: routing from U only (eq 30) ──────────── */
    /* Ptilde_{ij} = P_{ij} if i in U, 0 otherwise (for ALL j) */

    for (i = 0; i < n; i++)
        for (j = 0; j < n; j++)
            PT(i, j) = is_U[i] ? P[i][j] : 0.0;

    /* ── Build Qtilde = (I - Ptilde)^{-1}  (eq 31) ────────── */
    {
        double *ImPt = (double *)malloc((size_t)n * (size_t)n * sizeof(double));
        if (!ImPt) {
            fprintf(stderr, "bna_sbd: out of memory (ImPt n=%d)\n", n);
            exit(EXIT_FAILURE);
        }
        for (i = 0; i < n; i++)
            for (j = 0; j < n; j++)
                ImPt[(size_t)i * (size_t)n + (size_t)j] =
                    (i == j ? 1.0 : 0.0) - PT(i, j);
        invert_matrix_flat(n, ImPt, Qtilde);
        free(ImPt);
    }

    /* ── Build Phat_BB: modified routing within B  (eq 32) ──── */
    /* Phat_{ij} = P_{ij} + sum_{k in U} P_{ik} * Qtilde_{kj}
       for i,j in B */

    for (ii = 0; ii < nB; ii++) {
        i = B[ii];
        for (jj = 0; jj < nB; jj++) {
            j = B[jj];
            PH(i, j) = P[i][j];
            for (k = 0; k < nU; k++)
                PH(i, j) += P[i][U[k]] * QT(U[k], j);
        }
    }

    /* Also need Phat_{lj} for l in O, j in B (for arrivals from O) */
    for (ii = 0; ii < nO; ii++) {
        i = O[ii];
        for (jj = 0; jj < nB; jj++) {
            j = B[jj];
            PH(i, j) = P[i][j];
            for (k = 0; k < nU; k++)
                PH(i, j) += P[i][U[k]] * QT(U[k], j);
        }
    }

    /* ── Build alpha_hat: modified arrivals  (eq 40) ──────── */
    /* alpha_hat_j = alpha_j + sum_{k in U} Qtilde_{kj}*alpha_k
                    + sum_{l in O} Phat_{lj}*lambda_l
       for j in B */

    for (jj = 0; jj < nB; jj++) {
        j = B[jj];
        alpha_hat[j] = alpha[j];
        for (k = 0; k < nU; k++)
            alpha_hat[j] += QT(U[k], j) * alpha[U[k]];
        for (k = 0; k < nO; k++)
            alpha_hat[j] += PH(O[k], j) * lambda[O[k]];
    }

    /* ── Solve modified traffic:  lambda_hat = (I - Phat'_BB)^{-1} alpha_hat ── */
    {
        size_t nbsq = (size_t)(nB ? nB : 1) * (size_t)(nB ? nB : 1);
        double *A = (double *)malloc(nbsq * sizeof(double));
        double *b = (double *)malloc((size_t)(nB ? nB : 1) * sizeof(double));
        if (!A || !b) {
            fprintf(stderr, "bna_sbd: out of memory (traffic solve nB=%d)\n", nB);
            exit(EXIT_FAILURE);
        }

        for (ii = 0; ii < nB; ii++) {
            for (jj = 0; jj < nB; jj++)
                A[(size_t)ii * (size_t)nB + (size_t)jj] =
                    (ii == jj ? 1.0 : 0.0) - PH(B[jj], B[ii]);
            b[ii] = alpha_hat[B[ii]];
        }

        gauss_solve_flat(nB, A, b);

        for (ii = 0; ii < nB; ii++) {
            lambda_hat[B[ii]] = b[ii];
            rho_hat[B[ii]] = b[ii] * tau[B[ii]];
        }
        free(A);
        free(b);
    }

    /* ── Special case: |B| = 1  (1-D RBM analytic solution) ── */

    if (nB == 1) {
        int s = B[0];
        double rh = rho_hat[s];

        /* Build Ghat for 1D case (eq 47 diagonal) */
        double Gii = 0.0;

        /* External arrival contribution */
        Gii += alpha[s] * ca_sq[s];

        /* Service variability: lambda_hat * cs^2 * (1 - 2*Phat_ii) */
        Gii += lambda_hat[s] * cs_sq[s] * (1.0 - 2.0 * PH(s, s));

        /* Underloaded contributions */
        for (k = 0; k < nU; k++) {
            int u = U[k];
            double Qki = QT(u, s);
            Gii += alpha[u] * Qki * (Qki * ca_sq[u] + 1.0 - Qki);
        }

        /* Overloaded contributions */
        for (k = 0; k < nO; k++) {
            int o = O[k];
            double Pli = PH(o, s);
            Gii += lambda[o] * Pli * (Pli * cs_sq[o] + 1.0 - Pli);
        }

        /* Balanced contributions (from self, since |B|=1) */
        {
            double Pli = PH(s, s);
            Gii += lambda_hat[s] * Pli * (Pli * cs_sq[s] + 1.0 - Pli);
        }

        /* RBM parameters for 1D:
           R_hat = tau_s * (1 - Phat_ss) / tau_s = 1 - Phat_ss  (simplified)
           Actually: R = T_B (I - Phat'_BB) T_B^{-1}
           For 1D: R = tau_s * (1 - Phat_ss) * (1/tau_s) = 1 - Phat_ss
           mu = R * (rho_hat - 1)
           Omega = tau_s^2 * Gii */
        {
            double R1 = 1.0 - PH(s, s);
            double mu1 = R1 * (rh - 1.0);
            double Omega1 = tau[s] * tau[s] * Gii;

            /* E[W*] = Omega / (-2 * mu) for 1-D RBM */
            if (mu1 < -1e-15) {
                EW[s] = Omega1 / (-2.0 * mu1);
            } else {
                /* Shouldn't happen if rho < 1 */
                fprintf(stderr, "bna_sbd: warning: non-negative drift at "
                        "station %d (mu=%.6e)\n", s + 1, mu1);
                EW[s] = 0.0;
            }
        }

        SBD_FREE_ALL();
        return;
    }

    /* ── Multi-station subnetwork: build Ghat matrix (eq 47) ── */

    for (ii = 0; ii < nB; ii++) {
        i = B[ii];
        for (jj = 0; jj < nB; jj++) {
            j = B[jj];

            if (ii == jj) {
                /* Diagonal: eq (47) i = j */
                double val = 0.0;

                /* alpha_i * ca^2_{a,i} */
                val += alpha[i] * ca_sq[i];

                /* lambda_hat_i * cs^2_{s,i} * (1 - 2*Phat_{ii}) */
                val += lambda_hat[i] * cs_sq[i] * (1.0 - 2.0 * PH(i, i));

                /* sum_{k in U} alpha_k * Qtilde_{ki} * (Qtilde_{ki}*ca^2_{a,k} + 1 - Qtilde_{ki}) */
                for (k = 0; k < nU; k++) {
                    int u = U[k];
                    double Qki = QT(u, i);
                    val += alpha[u] * Qki * (Qki * ca_sq[u] + 1.0 - Qki);
                }

                /* sum_{l in O} lambda_l * Phat_{li} * (Phat_{li}*cs^2_{s,l} + 1 - Phat_{li}) */
                for (k = 0; k < nO; k++) {
                    int o = O[k];
                    double Pli = PH(o, i);
                    val += lambda[o] * Pli * (Pli * cs_sq[o] + 1.0 - Pli);
                }

                /* sum_{l in B} lambda_hat_l * Phat_{li} * (Phat_{li}*cs^2_{s,l} + 1 - Phat_{li}) */
                for (k = 0; k < nB; k++) {
                    int b = B[k];
                    double Pli = PH(b, i);
                    val += lambda_hat[b] * Pli * (Pli * cs_sq[b] + 1.0 - Pli);
                }

                GH(ii, jj) = val;
            } else {
                /* Off-diagonal: eq (47) i != j */
                double val = 0.0;

                /* -lambda_hat_i * cs^2_{s,i} * Phat_{ij} */
                val -= lambda_hat[i] * cs_sq[i] * PH(i, j);

                /* -lambda_hat_j * cs^2_{s,j} * Phat_{ji} */
                val -= lambda_hat[j] * cs_sq[j] * PH(j, i);

                /* -sum_{k in U} alpha_k * (1 - ca^2_{a,k}) * Qtilde_{ki} * Qtilde_{kj} */
                for (k = 0; k < nU; k++) {
                    int u = U[k];
                    val -= alpha[u] * (1.0 - ca_sq[u]) *
                           QT(u, i) * QT(u, j);
                }

                /* -sum_{l in O} lambda_l * (1 - cs^2_{s,l}) * Phat_{li} * Phat_{lj} */
                for (k = 0; k < nO; k++) {
                    int o = O[k];
                    val -= lambda[o] * (1.0 - cs_sq[o]) *
                           PH(o, i) * PH(o, j);
                }

                /* -sum_{l in B} lambda_hat_l * (1 - cs^2_{s,l}) * Phat_{li} * Phat_{lj} */
                for (k = 0; k < nB; k++) {
                    int b = B[k];
                    val -= lambda_hat[b] * (1.0 - cs_sq[b]) *
                           PH(b, i) * PH(b, j);
                }

                GH(ii, jj) = val;
            }
        }
    }

    /* ── Build RBM parameters  (eq 49) ───────────────────────── */
    /* R_hat = T_B (I - Phat'_BB) T_B^{-1}
       mu_hat = R_hat (rho_hat - e)
       Omega_hat = T_B G_hat T_B'                                */

    /* R_hat[ii][jj] = tau[B[ii]] * ((ii==jj ? 1 : 0) - PH(B[jj], B[ii])) / tau[B[jj]] */
    for (ii = 0; ii < nB; ii++) {
        for (jj = 0; jj < nB; jj++) {
            double delta = (ii == jj) ? 1.0 : 0.0;
            RH(ii, jj) = tau[B[ii]] * (delta - PH(B[jj], B[ii])) / tau[B[jj]];
        }
    }

    /* mu = R_hat * (rho_hat - e) */
    for (ii = 0; ii < nB; ii++) {
        mu_rbm[ii] = 0.0;
        for (jj = 0; jj < nB; jj++)
            mu_rbm[ii] += RH(ii, jj) * (rho_hat[B[jj]] - 1.0);
    }

    /* Omega = T_B * Ghat * T_B'  where T_B = diag(tau[B[0]], ...) */
    for (ii = 0; ii < nB; ii++) {
        for (jj = 0; jj < nB; jj++) {
            OM(ii, jj) = tau[B[ii]] * GH(ii, jj) * tau[B[jj]];
        }
    }

    /* ── Call bnet to solve the |B|-dimensional RBM ──────────── */

    if (run_bnet(nB, mu_rbm, Omega, Rhat, EQ) != 0) {
        fallback_used = 1;
        fprintf(stderr, "bna_sbd: bnet failed for subnetwork %d "
                "(stations", gn + 1);
        for (ii = 0; ii < nB; ii++)
            fprintf(stderr, " %d", B[ii] + 1);
        fprintf(stderr, ")\n");
        /* Fall back to 1-D approximation for each station */
        for (ii = 0; ii < nB; ii++) {
            int s = B[ii];
            double rh = rho_hat[s];
            if (rh < 1.0 - 1e-10) {
                /* Use QNET-style approximation: Gii * tau^2 / (-2 * mu_i) */
                double R1 = 1.0 - PH(s, s);
                double mu1 = R1 * (rh - 1.0);
                double Om1 = tau[s] * tau[s] * GH(ii, ii);
                EW[s] = (mu1 < -1e-15) ? Om1 / (-2.0 * mu1) : 0.0;
            } else {
                EW[s] = 0.0;
            }
        }
        SBD_FREE_ALL();
        return;
    }

    /* Store results: E[Q_j] from bnet = E[W*_j] (steady-state workload) */
    for (ii = 0; ii < nB; ii++)
        EW[B[ii]] = EQ[ii];
    SBD_FREE_ALL();
}

/* ================================================================
 *  Compute sojourn times and network total
 * ================================================================ */

static void compute_sojourn(void)
{
    int i;
    for (i = 0; i < n; i++) {
        ET[i] = tau[i] + EW[i];
        EN[i] = lambda[i] * ET[i];  /* Little's law: E[N] = lambda * E[T] */
    }
}

/* ================================================================
 *  Output
 * ================================================================ */

static void print_results(void)
{
    int i, g;
    double total_lambda0 = 0.0;
    double total_EN = 0.0;
    double total_sojourn = 0.0;

    printf("SBD (Sequential Bottleneck Decomposition)\n");
    printf("==========================================\n\n");

    /* Print partition */
    printf("Partition:");
    for (g = 0; g < num_groups; g++) {
        printf(" S%d={", g + 1);
        for (i = 0; i < group_size[g]; i++) {
            if (i > 0) printf(",");
            printf("%d", group[g][i] + 1);
        }
        printf("}");
    }
    printf("\n\n");

    printf("%-6s%-11s%-13s%-13s%-13s%-11s\n",
           "Node", "Util(rho)", "E[W]", "E[N]", "E[T]", "rho_hat");

    for (i = 0; i < n; i++) {
        printf("%-6d%-11.4f%-13.6f%-13.6f%-13.6f%-11.4f\n",
               i + 1, rho[i], EW[i], EN[i], ET[i], rho_hat[i]);
        total_EN += EN[i];
    }

    for (i = 0; i < n; i++)
        total_lambda0 += alpha[i];

    for (i = 0; i < n; i++)
        total_sojourn += lambda[i] * ET[i];
    if (total_lambda0 > 1e-15)
        total_sojourn /= total_lambda0;

    printf("\nNetwork Totals:\n");
    printf("  External arrival rate: %f\n", total_lambda0);
    printf("  Total E[N]: %f\n", total_EN);
    if (total_lambda0 > 1e-15)
        printf("  Mean sojourn time E[T]: %f\n", total_sojourn);

    printf("\n");
    {
        int w = 1;
        for (int t = n; t >= 10; t /= 10) w++;
        for (i = 0; i < n; i++)
            printf("E[Q_%0*d] = %f\n", w, i + 1, EN[i]);
    }
    printf("\n");
}

static void print_compact(void)
{
    int i;
    printf("SBD (BNAsbd)\n");
    printf("=================\n");

    for (i = 0; i < n; i++)
        printf("rho_%d = %f\n", i + 1, rho[i]);
    printf("\n");

    /* Per-station throughput and sojourn — lambda[i] is the total
     * (effective) arrival rate solved from the traffic equations,
     * ET[i] is the per-visit mean sojourn time. Emitted in the
     * standard Gamma_k / sojourn_k format for the comparison parser. */
    for (i = 0; i < n; i++)
        printf("Gamma_%d = %f\n", i + 1, lambda[i]);
    printf("\n");

    for (i = 0; i < n; i++)
        printf("sojourn_%d = %f\n", i + 1, ET[i]);
    printf("\n");

    {
        int w = 1;
        for (int t = n; t >= 10; t /= 10) w++;
        for (i = 0; i < n; i++)
            printf("E[Q_%0*d] = %f\n", w, i + 1, EN[i]);
    }
    printf("\n");
}

/* ================================================================
 *  Main
 * ================================================================ */

int main(int argc, char *argv[])
{
    int i, g;
    const char *filename = NULL;

    /* Resolve bnet binary path before parsing args. Order: env var,
     * argv[0]-based discovery, then legacy ../BNAsm/bnet fallback. */
    {
        const char *env = getenv("BNET_BIN");
        if (env && env[0]) {
            strncpy(bnet_bin, env, sizeof(bnet_bin) - 1);
            bnet_bin[sizeof(bnet_bin) - 1] = '\0';
        } else if (argv[0] && argv[0][0]) {
            /* dirname(argv[0]) + "/../BNAsm/bnet" */
            char a0[1024];
            strncpy(a0, argv[0], sizeof(a0) - 1);
            a0[sizeof(a0) - 1] = '\0';
            char *slash = strrchr(a0, '/');
            if (slash) {
                *slash = '\0';
                snprintf(bnet_bin, sizeof(bnet_bin),
                         "%s/../BNAsm/bnet", a0);
                /* If that doesn't exist either, leave bnet_bin as the
                 * default ../BNAsm/bnet so behavior is unchanged for
                 * users invoking from BNAsbd directly. */
                if (access(bnet_bin, X_OK) != 0) {
                    strncpy(bnet_bin, "../BNAsm/bnet", sizeof(bnet_bin));
                }
            }
        }
    }

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-c") == 0) {
            compact = 1;
        } else if (strcmp(argv[i], "-n") == 0 && i + 1 < argc) {
            poly_degree = atoi(argv[++i]);
            if (poly_degree < 1) poly_degree = 5;
        } else if (strcmp(argv[i], "-p") == 0 && i + 1 < argc) {
            strncpy(manual_partition, argv[++i], LINE_BUF - 1);
            manual_partition[LINE_BUF - 1] = '\0';
        } else if (argv[i][0] != '-') {
            filename = argv[i];
        } else {
            fprintf(stderr, "bna_sbd: unknown option '%s'\n", argv[i]);
            fprintf(stderr, "Usage: bna_sbd <input_file> [-c] [-n degree] "
                    "[-p partition]\n");
            return 1;
        }
    }

    if (!filename) {
        fprintf(stderr, "Usage: bna_sbd <input_file> [-c] [-n degree] "
                "[-p partition]\n");
        return 1;
    }

    parse_input(filename);
    solve_traffic();
    partition_stations();

    /* Initialize results to zero */
    for (i = 0; i < n; i++) {
        EW[i] = 0.0;
        ET[i] = 0.0;
        EN[i] = 0.0;
        rho_hat[i] = rho[i];
    }

    /* Solve each subnetwork (lowest rho group first) */
    for (g = 0; g < num_groups; g++)
        solve_subnetwork(g);

    compute_sojourn();

    if (compact)
        print_compact();
    else
        print_results();

    printf("QNET_SBD_STATUS_V1 fallback_used=%s\n",
           fallback_used ? "yes" : "no");

    return 0;
}
