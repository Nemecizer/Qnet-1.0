/*
 * bna_qna.c  --  QNA (Queueing Network Analyzer) after Whitt (1983)
 *
 * Parametric-decomposition method for open queueing networks.
 * Each node is analyzed as an independent GI/G/m queue using
 * two parameters per process: rate and squared coefficient of
 * variation (SCV).
 *
 * Usage:  bna_qna <input_file> [-c]
 *         -c  compact output (E[X_i] values only, for comparison mode)
 *
 * Build:  gcc -Wall -O2 -ansi -pedantic -o bna_qna bna_qna.c -lm
 *
 * Reference:
 *   W. Whitt, "The Queueing Network Analyzer," Bell System Technical
 *   Journal, Vol. 62, No. 9, pp. 2779-2815, November 1983.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "../../common/bnet_memcheck.h"

#define MAX_NODES 64
#define LINE_BUF  4096

/* ── Network data ─────────────────────────────────────────────── */

static int    n;                          /* number of nodes          */
static int    m[MAX_NODES];               /* servers per node         */
static double lambda0[MAX_NODES];         /* external arrival rate    */
static double ca0_sq[MAX_NODES];          /* external arrival SCV     */
static double tau[MAX_NODES];             /* mean service time        */
static double cs_sq[MAX_NODES];           /* service time SCV         */
static double Q[MAX_NODES][MAX_NODES];    /* routing matrix           */

/* ── After feedback elimination ───────────────────────────────── */

static double tau_t[MAX_NODES];           /* transformed tau          */
static double cs_t[MAX_NODES];            /* transformed service SCV  */
static double Qt[MAX_NODES][MAX_NODES];   /* transformed routing      */
static double qii_orig[MAX_NODES];        /* original self-loop probs */

/* ── Traffic solution ─────────────────────────────────────────── */

static double lam[MAX_NODES];             /* total arrival rate       */
static double rho[MAX_NODES];             /* utilization              */

/* ── Variability solution ─────────────────────────────────────── */

static double ca_sq[MAX_NODES];           /* arrival SCV              */

/* ── Congestion measures ──────────────────────────────────────── */

static double EW[MAX_NODES];              /* mean waiting time        */
static double EN[MAX_NODES];              /* mean number in system    */
static double ET[MAX_NODES];              /* mean sojourn time        */
static double Pwgt0[MAX_NODES];           /* P(wait > 0)             */

/* ── Compact output flag ──────────────────────────────────────── */

static int compact = 0;

/* ── Customer class data (optional) ──────────────────────────── */

static int    num_cust_classes = 0;   /* K; 0 = feature off        */
static double cc_tau[MAX_NODES];      /* workload-to-queue factor   */
static double cc_alpha_total[MAX_NODES]; /* total throughput / stn  */
static double cc_mueff[MAX_NODES];    /* effective service rate/stn  */
static double cc_lambda[MAX_NODES];   /* ext arrival rate / class    */
static double cc_alpha[MAX_NODES][MAX_NODES]; /* alpha[k][i]        */
static double cc_mu[MAX_NODES][MAX_NODES];    /* mu[k][i]           */

/* Bitran-Tirupati 1988 / Whitt 1988 per-class variability data
 * (parsed from QNA file when the Swift exporter emits them). When
 * `cc_have_perclass_var` is 1, solve_variability dispatches to the
 * K·n × K·n per-class solver instead of the n × n single-class one. */
static int    cc_have_perclass_var = 0;
static double cc_cs[MAX_NODES][MAX_NODES];        /* per-class service SCV [k][i] */
static double cc_lambda_ext[MAX_NODES][MAX_NODES];/* per-class external arrival per station [k][i] */
static double *cc_routing = NULL;                 /* heap-alloc K·n × K·n */
static double cc_ca_perclass[MAX_NODES][MAX_NODES]; /* per-class arrival SCV [k][i] (output) */

/* ── Per-class congestion measures ───────────────────────────── */

static double EW_total[MAX_NODES];    /* mean total queue time / cls */
static double ET_total[MAX_NODES];    /* mean total sojourn / cls    */
static double EN_total[MAX_NODES];    /* mean number in system / cls */

/* ================================================================
 *  Input parser
 * ================================================================ */

/* Read next non-blank, non-comment line into buf.  Returns 1 on
   success, 0 on EOF. */
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
        fprintf(stderr, "bna_qna: cannot open '%s'\n", filename);
        exit(1);
    }

    /* n */
    if (!next_line(fp, buf, LINE_BUF)) goto bad;
    if (sscanf(buf, "%d", &n) != 1 || n < 1 || n > MAX_NODES) {
        fprintf(stderr, "bna_qna: invalid n = %d (max %d)\n", n, MAX_NODES);
        exit(1);
    }

    /* m_j */
    if (!next_line(fp, buf, LINE_BUF)) goto bad;
    {
        char *tok = strtok(buf, " \t\n\r");
        for (i = 0; i < n; i++) {
            if (!tok) goto bad;
            m[i] = atoi(tok);
            if (m[i] < 1) m[i] = 1;
            tok = strtok(NULL, " \t\n\r");
        }
    }

    /* lambda0_j */
    if (!next_line(fp, buf, LINE_BUF)) goto bad;
    {
        char *tok = strtok(buf, " \t\n\r");
        for (i = 0; i < n; i++) {
            if (!tok) goto bad;
            lambda0[i] = atof(tok);
            tok = strtok(NULL, " \t\n\r");
        }
    }

    /* ca0^2 */
    if (!next_line(fp, buf, LINE_BUF)) goto bad;
    {
        char *tok = strtok(buf, " \t\n\r");
        for (i = 0; i < n; i++) {
            if (!tok) goto bad;
            ca0_sq[i] = atof(tok);
            tok = strtok(NULL, " \t\n\r");
        }
    }

    /* tau_j */
    if (!next_line(fp, buf, LINE_BUF)) goto bad;
    {
        char *tok = strtok(buf, " \t\n\r");
        for (i = 0; i < n; i++) {
            if (!tok) goto bad;
            tau[i] = atof(tok);
            tok = strtok(NULL, " \t\n\r");
        }
    }

    /* cs^2 */
    if (!next_line(fp, buf, LINE_BUF)) goto bad;
    {
        char *tok = strtok(buf, " \t\n\r");
        for (i = 0; i < n; i++) {
            if (!tok) goto bad;
            cs_sq[i] = atof(tok);
            tok = strtok(NULL, " \t\n\r");
        }
    }

    /* Q matrix (n rows) */
    for (i = 0; i < n; i++) {
        char *tok;
        if (!next_line(fp, buf, LINE_BUF)) goto bad;
        tok = strtok(buf, " \t\n\r");
        for (j = 0; j < n; j++) {
            if (!tok) goto bad;
            Q[i][j] = atof(tok);
            tok = strtok(NULL, " \t\n\r");
        }
    }

    /* ── Optional customer class data ─────────────────────────── */
    if (next_line(fp, buf, LINE_BUF)) {
        if (sscanf(buf, "customer_classes %d", &num_cust_classes) == 1
            && num_cust_classes > 0) {
            int K = num_cust_classes, k;

            /* tau (workload-to-queue factor) */
            if (!next_line(fp, buf, LINE_BUF)) goto bad_cc;
            {
                char *tok = strtok(buf, " \t\n\r");
                for (i = 0; i < n; i++) {
                    if (!tok) goto bad_cc;
                    cc_tau[i] = atof(tok);
                    tok = strtok(NULL, " \t\n\r");
                }
            }

            /* alpha_total (total throughput per station) */
            if (!next_line(fp, buf, LINE_BUF)) goto bad_cc;
            {
                char *tok = strtok(buf, " \t\n\r");
                for (i = 0; i < n; i++) {
                    if (!tok) goto bad_cc;
                    cc_alpha_total[i] = atof(tok);
                    tok = strtok(NULL, " \t\n\r");
                }
            }

            /* mueff (effective service rate per station) */
            if (!next_line(fp, buf, LINE_BUF)) goto bad_cc;
            {
                char *tok = strtok(buf, " \t\n\r");
                for (i = 0; i < n; i++) {
                    if (!tok) goto bad_cc;
                    cc_mueff[i] = atof(tok);
                    tok = strtok(NULL, " \t\n\r");
                }
            }

            /* lambda_k (external arrival rate per class) */
            if (!next_line(fp, buf, LINE_BUF)) goto bad_cc;
            {
                char *tok = strtok(buf, " \t\n\r");
                for (k = 0; k < K; k++) {
                    if (!tok) goto bad_cc;
                    cc_lambda[k] = atof(tok);
                    tok = strtok(NULL, " \t\n\r");
                }
            }

            /* alpha_ki (per-class throughput: K rows x d cols) */
            for (k = 0; k < K; k++) {
                char *tok;
                if (!next_line(fp, buf, LINE_BUF)) goto bad_cc;
                tok = strtok(buf, " \t\n\r");
                for (i = 0; i < n; i++) {
                    if (!tok) goto bad_cc;
                    cc_alpha[k][i] = atof(tok);
                    tok = strtok(NULL, " \t\n\r");
                }
            }

            /* mu_ki (per-class service rate: K rows x d cols) */
            for (k = 0; k < K; k++) {
                char *tok;
                if (!next_line(fp, buf, LINE_BUF)) goto bad_cc;
                tok = strtok(buf, " \t\n\r");
                for (i = 0; i < n; i++) {
                    if (!tok) goto bad_cc;
                    cc_mu[k][i] = atof(tok);
                    tok = strtok(NULL, " \t\n\r");
                }
            }

            /* Optional per-class variability data (Bitran-Tirupati /
             * Whitt 1988). All three blocks must be present together. */
            cc_have_perclass_var = 0;
            if (next_line(fp, buf, LINE_BUF)) {
                /* Parse cs[k][i] (K rows x d cols) */
                int parsed_cs = 1;
                for (k = 0; k < K; k++) {
                    if (k > 0 && !next_line(fp, buf, LINE_BUF)) { parsed_cs = 0; break; }
                    char *tok = strtok(buf, " \t\n\r");
                    for (i = 0; i < n; i++) {
                        if (!tok) { parsed_cs = 0; break; }
                        cc_cs[k][i] = atof(tok);
                        tok = strtok(NULL, " \t\n\r");
                    }
                    if (!parsed_cs) break;
                }
                if (parsed_cs) {
                    /* lambda_ext[k][i] */
                    int parsed_le = 1;
                    for (k = 0; k < K; k++) {
                        if (!next_line(fp, buf, LINE_BUF)) { parsed_le = 0; break; }
                        char *tok = strtok(buf, " \t\n\r");
                        for (i = 0; i < n; i++) {
                            if (!tok) { parsed_le = 0; break; }
                            cc_lambda_ext[k][i] = atof(tok);
                            tok = strtok(NULL, " \t\n\r");
                        }
                        if (!parsed_le) break;
                    }
                    if (parsed_le) {
                        /* P_ex[N][N] where N = K*n */
                        int N = K * n;
                        cc_routing = (double *)calloc((size_t)N * (size_t)N, sizeof(double));
                        if (!cc_routing) {
                            fprintf(stderr, "bna_qna: out of memory for per-class routing\n");
                            num_cust_classes = K;  /* keep aggregate data */
                        } else {
                            int parsed_pex = 1;
                            for (int row = 0; row < N; row++) {
                                if (!next_line(fp, buf, LINE_BUF)) { parsed_pex = 0; break; }
                                char *tok = strtok(buf, " \t\n\r");
                                for (int col = 0; col < N; col++) {
                                    if (!tok) { parsed_pex = 0; break; }
                                    cc_routing[(size_t)row * (size_t)N + (size_t)col] = atof(tok);
                                    tok = strtok(NULL, " \t\n\r");
                                }
                                if (!parsed_pex) break;
                            }
                            if (parsed_pex) cc_have_perclass_var = 1;
                            else { free(cc_routing); cc_routing = NULL; }
                        }
                    }
                }
            }
        } else {
            num_cust_classes = 0;
        }
    }

    fclose(fp);
    return;

bad_cc:
    fprintf(stderr, "bna_qna: incomplete customer class data in '%s'\n", filename);
    num_cust_classes = 0;
    fclose(fp);
    return;

bad:
    fprintf(stderr, "bna_qna: premature end of input in '%s'\n", filename);
    fclose(fp);
    exit(1);
}

/* ================================================================
 *  Step 1: Eliminate immediate feedback  (Section III)
 * ================================================================ */

static void eliminate_feedback(void)
{
    int i, j;

    for (i = 0; i < n; i++) {
        qii_orig[i] = Q[i][i];

        if (Q[i][i] > 0.0) {
            double f = Q[i][i];
            tau_t[i]  = tau[i] / (1.0 - f);
            cs_t[i]   = f + (1.0 - f) * cs_sq[i];

            for (j = 0; j < n; j++) {
                if (j == i)
                    Qt[i][j] = 0.0;
                else
                    Qt[i][j] = Q[i][j] / (1.0 - f);
            }
        } else {
            tau_t[i] = tau[i];
            cs_t[i]  = cs_sq[i];
            for (j = 0; j < n; j++)
                Qt[i][j] = Q[i][j];
        }
    }
}

/* ================================================================
 *  Step 2: Traffic-rate equations  (eq. 18-19)
 *
 *  Solve  (I - Qt^T) * lam = lambda0  via Gaussian elimination
 * ================================================================ */

static void solve_traffic_rates(void)
{
    double A[MAX_NODES][MAX_NODES];
    double b[MAX_NODES];
    int i, j, col, row, maxRow;
    double maxVal, factor, pivot;

    /* Build A = I - Qt^T */
    for (i = 0; i < n; i++) {
        for (j = 0; j < n; j++) {
            A[i][j] = (i == j ? 1.0 : 0.0) - Qt[j][i];
        }
        b[i] = lambda0[i];
    }

    /* Forward elimination with partial pivoting */
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
            fprintf(stderr, "bna_qna: singular traffic-rate matrix\n");
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
        lam[i] = b[i];
        for (j = i + 1; j < n; j++)
            lam[i] -= A[i][j] * lam[j];
        lam[i] /= A[i][i];
    }

    /* Compute utilizations */
    for (i = 0; i < n; i++) {
        rho[i] = lam[i] * tau_t[i] / (double)m[i];
        if (rho[i] >= 1.0) {
            fprintf(stderr, "bna_qna: node %d overloaded (rho = %.6f >= 1)\n",
                    i + 1, rho[i]);
            exit(1);
        }
    }
}

/* ================================================================
 *  Dai-Vande Vate (2000) global-stability check for 2-station
 *  multi-class networks. Theorem 4.3 / eq. (1.16):
 *
 *    sum_{(i,k) in C_A} m^i_k / (1 - sum_{(i,k) in F_A} m^i_k)
 *  + sum_{(i,k) in C_B} m^i_k / (1 - sum_{(i,k) in F_B} m^i_k)  <=  1
 *
 *  for every push start F and virtual station C in the subnetwork
 *  outside F. If violated for any (F, C), there exists a static
 *  buffer-priority discipline under which queue length diverges
 *  even though every per-station rho < 1.
 *
 *  Implementation: BNAqna's per-class arrays (cc_alpha, cc_mu,
 *  cc_lambda) carry the per-(class, station) load; the QNA file
 *  doesn't carry the full visit chain so we enumerate F over all
 *  subsets of "first-visit" classes (cc_lambda > 0) and C over all
 *  non-empty subsets of "later" classes (cc_lambda == 0). This
 *  over-enumerates compared to Defs. 4.1/4.2 (some candidate Cs may
 *  not be valid virtual stations) — but a non-virtual-station C that
 *  fails the inequality cannot prove instability, so we only warn
 *  when a violation is found AND the candidate looks structurally
 *  like a Kumar-Seidman/Bramson re-entrant pattern.
 *
 *  Reference: J. G. Dai & J. H. Vande Vate, "The Stability of Two-
 *  Station Multitype Fluid Networks," Op. Res. 48(5):721-744, 2000.
 * ================================================================ */
static void check_stability_dai_vande_vate(void)
{
    /* Only meaningful if the QNA file carries multi-class data and
     * has exactly 2 stations. The Dai-Vande Vate result is specific
     * to two-station networks; >2 stations need Bertsimas-Gamarnik-
     * Tsitsiklis 2001 piecewise-linear Lyapunov LPs (not implemented). */
    if (n != 2 || num_cust_classes < 2) return;

    /* Per-class: which station, mean service time (load contribution
     * = throughput / mu, since lambda is folded into cc_alpha). */
    int    stn[MAX_NODES];
    double mload[MAX_NODES];   /* load contribution at the visited station */
    int    is_first[MAX_NODES];
    int    n_first = 0, n_later = 0;
    int    first_idx[MAX_NODES], later_idx[MAX_NODES];

    /* The QNA file collapses (type, excursion) into a flat class list and
     * doesn't preserve the visit chain. Our enumeration is sound only
     * when each class visits exactly one station (single-visit-per-class
     * networks like Kumar-Seidman / Lu-Kumar after the bnet exporter's
     * relabel-on-link gives each excursion its own class id). When a
     * single class visits multiple stations (Bramson94 c=3 reuses class
     * labels across visits), we'd need the full visit chain to obey
     * Definition 4.1 rule 3 — without it we'd over-warn. Skip cleanly. */
    for (int k = 0; k < num_cust_classes; k++) {
        is_first[k] = (cc_lambda[k] > 1e-12);
        stn[k] = -1;
        mload[k] = 0.0;
        int visits = 0;
        for (int i = 0; i < n; i++) {
            if (cc_alpha[k][i] > 1e-12 && cc_mu[k][i] > 1e-12) {
                stn[k] = i;
                mload[k] = cc_alpha[k][i] / cc_mu[k][i];
                visits++;
            }
        }
        if (visits > 1) {
            fprintf(stderr,
                "bna_qna: stability check skipped — class %d visits %d "
                "stations (multi-visit). Use BGT-2001 LP or run sim with\n"
                "  --validate-stability for networks of this shape.\n",
                k + 1, visits);
            return;
        }
        if (stn[k] < 0) continue;
        if (is_first[k]) first_idx[n_first++] = k;
        else             later_idx[n_later++] = k;
    }

    if (n_later == 0) return;  /* no re-entrant classes — can't trip the bound */

    /* Cap at 2^20 combinations to bound the search; for larger
     * networks we'd need an LP (Bertsimas-Gamarnik-Tsitsiklis). */
    if (n_first > 20 || n_later > 20) {
        fprintf(stderr,
            "bna_qna: stability check skipped (>20 first or later classes); "
            "use BGT-2001 LP for large networks.\n");
        return;
    }

    double worst_lhs = 0.0;
    int    worst_F = 0, worst_C = 0;

    for (int Fmask = 0; Fmask < (1 << n_first); Fmask++) {
        double mF[2] = {0.0, 0.0};
        for (int j = 0; j < n_first; j++) {
            if (Fmask & (1 << j)) {
                int k = first_idx[j];
                mF[stn[k]] += mload[k];
            }
        }
        /* If F itself overloads a station, the formula's denominator
         * is non-positive — skip (the per-station rho check above
         * would have already caught this regime). */
        if (mF[0] >= 1.0 - 1e-9 || mF[1] >= 1.0 - 1e-9) continue;

        for (int Cmask = 1; Cmask < (1 << n_later); Cmask++) {
            double mC[2] = {0.0, 0.0};
            for (int j = 0; j < n_later; j++) {
                if (Cmask & (1 << j)) {
                    int k = later_idx[j];
                    mC[stn[k]] += mload[k];
                }
            }
            double lhs = mC[0] / (1.0 - mF[0]) + mC[1] / (1.0 - mF[1]);
            if (lhs > worst_lhs) {
                worst_lhs = lhs;
                worst_F = Fmask;
                worst_C = Cmask;
            }
        }
    }

    if (worst_lhs <= 1.0 + 1e-6) return;  /* globally stable */

    /* Format the offending (F, C) for the warning. */
    fprintf(stderr,
        "\nWARNING: Dai-Vande Vate (2000) global-stability condition violated.\n"
        "  Worst (F, C) gives LHS = %.4f > 1 (Theorem 4.3, eq. 1.16).\n"
        "  Push start F = { ", worst_lhs);
    int any = 0;
    for (int j = 0; j < n_first; j++) {
        if (worst_F & (1 << j)) {
            fprintf(stderr, "%sclass %d (S%d, m=%.4f)",
                    any ? ", " : "", first_idx[j] + 1, stn[first_idx[j]] + 1,
                    mload[first_idx[j]]);
            any = 1;
        }
    }
    fprintf(stderr, "%s}\n  Virtual station C = { ", any ? " " : "");
    any = 0;
    for (int j = 0; j < n_later; j++) {
        if (worst_C & (1 << j)) {
            fprintf(stderr, "%sclass %d (S%d, m=%.4f)",
                    any ? ", " : "", later_idx[j] + 1, stn[later_idx[j]] + 1,
                    mload[later_idx[j]]);
            any = 1;
        }
    }
    fprintf(stderr,
        " }\n"
        "  Per-station rho < 1 at both stations, but there exists a non-idling\n"
        "  buffer-priority discipline under which queue length diverges to\n"
        "  infinity. The QNA point estimate below assumes FIFO stability and\n"
        "  may be optimistic on the corresponding bnet sim.\n"
        "  Reference: Dai & Vande Vate, Op. Res. 48(5):721-744, 2000.\n\n");
}

/* ================================================================
 *  Step 3: Traffic variability equations  (eq. 24-43)
 *
 *  Solve  (I - B) * ca^2 = a
 * ================================================================ */

/* ================================================================
 *  Bitran-Tirupati 1988 / Whitt 1988 per-class variability solver.
 *
 *  Generalises the n × n single-class fixed-point of Whitt 1983
 *  (eq. 24-43, the version `solve_variability_aggregate` below) to a
 *  K·n × K·n system over (class, station) pairs. The fix is the
 *  documented root cause of QNA's 20-25% sojourn-estimate gap on
 *  Lu-Kumar / Kumar-Seidman networks: when two classes visit the
 *  same station with very different per-class service variances, the
 *  aggregated cs_t[i] used by the single-class system loses the
 *  per-class structure that propagates through the feedback loop.
 *
 *  System (per Whitt 1983 eq. 38, generalised):
 *    c²_a,(k,j) = a_(k,j) + sum_(k',i') B_((k',i'),(k,j)) c²_a,(k',i')
 *
 *    p0_(k,j) = lambda_ext[k][j] / alpha[k][j]
 *    p_((k',i'),(k,j)) = alpha[k'][i'] * P_ex[(k'*n+i'),(k*n+j)] / alpha[k][j]
 *    nu_(k,j) = 1 / (p0² + sum p²)
 *    w_(k,j) = 1 / (1 + 4(1-rho_j)²(nu_(k,j) - 1))
 *    a_(k,j) = 1 + w * { p0(ca0² - 1)
 *               + sum p_((k',i'),(k,j)) * P_ex_... * [rho_i'² - 1 + rho_i'²/√m_i' (cs[k'][i'] - 1)] }
 *    B_((k',i'),(k,j)) = w_(k,j) * p_((k',i'),(k,j)) * P_ex_... * (1 - rho_i'²)
 *
 *  The aggregate per-station ca_sq[j] used by compute_congestion is
 *  then a throughput-weighted mixture of c²_a,(k,j).
 *
 *  References: Bitran & Tirupati, "Multiproduct queueing networks
 *  with deterministic routing," Mgmt. Sci. 34:75-100, 1988; Whitt,
 *  "Approximations for networks of GI/G/m queues with class-dependent
 *  service times," Performance Evaluation 8(3), 1988.
 * ================================================================ */
static int solve_variability_per_class(void)
{
    int K = num_cust_classes;
    int N = K * n;
    if (N == 0 || cc_routing == NULL) return 0;

    /* Cap to avoid MAX_NODES²-sized blowups. */
    if (K > MAX_NODES || N > 256) {
        fprintf(stderr,
            "bna_qna: per-class variability skipped (K*n=%d > 256); "
            "falling back to single-class.\n", N);
        return 0;
    }

    double *p     = (double *)calloc((size_t)N * (size_t)N, sizeof(double)); /* prop[(k',i'),(k,j)] */
    double *Bmat  = (double *)calloc((size_t)N * (size_t)N, sizeof(double));
    double *Amat  = (double *)calloc((size_t)N * (size_t)N, sizeof(double));
    double *avec  = (double *)calloc((size_t)N, sizeof(double));
    double *rhsv  = (double *)calloc((size_t)N, sizeof(double));
    if (!p || !Bmat || !Amat || !avec || !rhsv) {
        free(p); free(Bmat); free(Amat); free(avec); free(rhsv);
        return 0;
    }

    #define IDX(kk, ii)  ((kk) * n + (ii))
    #define PE(r, c)     cc_routing[(size_t)(r) * (size_t)N + (size_t)(c)]
    #define PP(r, c)     p         [(size_t)(r) * (size_t)N + (size_t)(c)]
    #define BB(r, c)     Bmat      [(size_t)(r) * (size_t)N + (size_t)(c)]
    #define AA(r, c)     Amat      [(size_t)(r) * (size_t)N + (size_t)(c)]

    /* Inflow proportions p[(k',i'),(k,j)] = alpha[k'][i'] * P_ex / alpha[k][j].
     * External proportion p0[(k,j)] = lambda_ext[k][j] / alpha[k][j]. */
    for (int k = 0; k < K; k++) {
        for (int j = 0; j < n; j++) {
            double a_kj = cc_alpha[k][j];
            if (a_kj < 1e-15) continue;
            int idx_kj = IDX(k, j);
            for (int kp = 0; kp < K; kp++) {
                for (int ip = 0; ip < n; ip++) {
                    double a_kp_ip = cc_alpha[kp][ip];
                    if (a_kp_ip < 1e-15) continue;
                    int idx_kp_ip = IDX(kp, ip);
                    PP(idx_kp_ip, idx_kj) = a_kp_ip * PE(idx_kp_ip, idx_kj) / a_kj;
                }
            }
        }
    }

    /* Build a_(k,j) and B[(k',i'),(k,j)]. */
    for (int k = 0; k < K; k++) {
        for (int j = 0; j < n; j++) {
            double a_kj = cc_alpha[k][j];
            if (a_kj < 1e-15) continue;
            int idx_kj = IDX(k, j);
            double p0 = cc_lambda_ext[k][j] / a_kj;

            /* nu_(k,j): inverse of sum-of-squares of inflow proportions */
            double sum_sq = p0 * p0;
            for (int kp = 0; kp < K; kp++)
                for (int ip = 0; ip < n; ip++)
                    sum_sq += PP(IDX(kp, ip), idx_kj) * PP(IDX(kp, ip), idx_kj);
            double nu = (sum_sq > 1e-15) ? 1.0 / sum_sq : 1.0;

            /* w_(k,j) at the station's overall rho */
            double rho_j = rho[j];
            double w_denom = 1.0 + 4.0 * (1.0 - rho_j) * (1.0 - rho_j) * (nu - 1.0);
            double w_kj = (w_denom > 1e-15) ? 1.0 / w_denom : 1.0;

            /* sum_a: external + per-(k',i') internal contributions */
            double sum_a = p0 * (1.0 - 1.0);  /* external SCV defaults to 1 (Poisson) */
            for (int kp = 0; kp < K; kp++) {
                for (int ip = 0; ip < n; ip++) {
                    double pij = PP(IDX(kp, ip), idx_kj);
                    double qij = PE(IDX(kp, ip), idx_kj);
                    if (pij < 1e-15 || qij < 1e-15) continue;
                    double rho_sq = rho[ip] * rho[ip];
                    double cs = cc_cs[kp][ip];
                    if (cs < 0.2) cs = 0.2;
                    sum_a += pij * qij *
                        (rho_sq - 1.0 + rho_sq / sqrt((double)m[ip]) * (cs - 1.0));

                    BB(IDX(kp, ip), idx_kj) = w_kj * pij * qij * (1.0 - rho_sq);
                }
            }
            avec[idx_kj] = 1.0 + w_kj * sum_a;
        }
    }

    /* Solve (I - B^T) * c²_a = a via Gaussian elimination */
    for (int i = 0; i < N; i++) {
        for (int j = 0; j < N; j++)
            AA(i, j) = (i == j ? 1.0 : 0.0) - BB(j, i);
        rhsv[i] = avec[i];
    }
    for (int col = 0; col < N; col++) {
        double maxVal = fabs(AA(col, col));
        int maxRow = col;
        for (int row = col + 1; row < N; row++) {
            if (fabs(AA(row, col)) > maxVal) {
                maxVal = fabs(AA(row, col));
                maxRow = row;
            }
        }
        if (maxRow != col) {
            for (int j = 0; j < N; j++) {
                double t = AA(col, j); AA(col, j) = AA(maxRow, j); AA(maxRow, j) = t;
            }
            double t = rhsv[col]; rhsv[col] = rhsv[maxRow]; rhsv[maxRow] = t;
        }
        double pivot = AA(col, col);
        if (fabs(pivot) < 1e-15) {
            free(p); free(Bmat); free(Amat); free(avec); free(rhsv);
            return 0;
        }
        for (int row = col + 1; row < N; row++) {
            double factor = AA(row, col) / pivot;
            for (int j = col; j < N; j++)
                AA(row, j) -= factor * AA(col, j);
            rhsv[row] -= factor * rhsv[col];
        }
    }
    for (int i = N - 1; i >= 0; i--) {
        double s = rhsv[i];
        for (int j = i + 1; j < N; j++) s -= AA(i, j) * rhsv[j];
        rhsv[i] = s / AA(i, i);
    }

    /* Distribute per-class arrival SCVs and aggregate to per-station. */
    for (int k = 0; k < K; k++)
        for (int j = 0; j < n; j++)
            cc_ca_perclass[k][j] = (cc_alpha[k][j] > 1e-15) ? rhsv[IDX(k, j)] : 1.0;

    for (int j = 0; j < n; j++) {
        if (lam[j] < 1e-15) { ca_sq[j] = 1.0; continue; }
        double agg = 0.0;
        for (int k = 0; k < K; k++)
            agg += (cc_alpha[k][j] / lam[j]) * cc_ca_perclass[k][j];
        ca_sq[j] = agg;
    }

    free(p); free(Bmat); free(Amat); free(avec); free(rhsv);
    #undef IDX
    #undef PE
    #undef PP
    #undef BB
    #undef AA
    return 1;
}

static void solve_variability(void)
{
    /* Per-class variability path (Bitran-Tirupati 1988 / Whitt 1988): if
     * the QNA file carries the K·n × K·n routing data, solve the
     * per-(class, station) fixed-point and aggregate per-station for
     * compute_congestion. Falls through to the single-class system
     * below if the data is absent or solving fails. */
    if (cc_have_perclass_var && solve_variability_per_class()) {
        if (!compact)
            fprintf(stderr, "bna_qna: using Bitran-Tirupati/Whitt 1988 per-class variability (K*n=%d)\n",
                    num_cust_classes * n);
        return;
    }

    /* Heap-allocate the three n×n matrices (p, B, A) sized to actual n,
     * not MAX_NODES². Pre-fix: function-local stack arrays of size
     * MAX_NODES² × 3 ≈ 100 KB at MAX_NODES=64 (fine), but ~24 MB at
     * MAX_NODES=512 (segfault on macOS's 8 MB stack). The 1D vectors
     * stay on the stack since they're tiny. */
    double p0[MAX_NODES];            /* p_{0j} = lambda0_j / lam_j       */
    double nu[MAX_NODES];
    double w[MAX_NODES];
    double a[MAX_NODES];
    double rhs[MAX_NODES];
    double *p, *B, *A;
    int i, j, col, row, maxRow;
    double maxVal, factor, pivot;

    {
        uint64_t bytes_each = (uint64_t)n * (uint64_t)n * sizeof(double);
        bnet_memcheck_alloc(3 * bytes_each,
            "QNA variability scratch (3 × n×n)",
            "reduce the number of stations or run with more RAM");
    }
    p = (double *)malloc((size_t)n * (size_t)n * sizeof(double));
    B = (double *)malloc((size_t)n * (size_t)n * sizeof(double));
    A = (double *)malloc((size_t)n * (size_t)n * sizeof(double));
    if (!p || !B || !A) {
        fprintf(stderr, "bna_qna: out of memory in solve_variability (n=%d)\n", n);
        exit(EXIT_FAILURE);
    }

    #define P(i,j) p[(size_t)(i) * (size_t)n + (size_t)(j)]
    #define B(i,j) B[(size_t)(i) * (size_t)n + (size_t)(j)]
    #define A(i,j) A[(size_t)(i) * (size_t)n + (size_t)(j)]

    /* Proportions p_{ij} and p_{0j} */
    for (j = 0; j < n; j++) {
        if (lam[j] > 1e-15) {
            p0[j] = lambda0[j] / lam[j];
            for (i = 0; i < n; i++)
                P(i, j) = lam[i] * Qt[i][j] / lam[j];
        } else {
            p0[j] = 1.0;
            for (i = 0; i < n; i++)
                P(i, j) = 0.0;
        }
    }

    /* nu_j (eq. 30) */
    for (j = 0; j < n; j++) {
        double sum_sq = p0[j] * p0[j];
        for (i = 0; i < n; i++)
            sum_sq += P(i, j) * P(i, j);
        nu[j] = (sum_sq > 1e-15) ? 1.0 / sum_sq : 1.0;
    }

    /* w_j (eq. 29) */
    for (j = 0; j < n; j++) {
        double tmp = 1.0 + 4.0 * (1.0 - rho[j]) * (1.0 - rho[j]) * (nu[j] - 1.0);
        w[j] = (tmp > 1e-15) ? 1.0 / tmp : 1.0;
    }

    /* Build B matrix and a vector */
    for (j = 0; j < n; j++) {
        /* a_j (eq. 43 simplified) */
        double sum_a = 0.0;

        /* External arrival contribution */
        sum_a += p0[j] * (ca0_sq[j] - 1.0);

        /* Internal contributions */
        for (i = 0; i < n; i++) {
            if (P(i, j) > 1e-15 && Qt[i][j] > 1e-15) {
                double rho_sq = rho[i] * rho[i];
                double cs_eff = cs_t[i];
                if (cs_eff < 0.2) cs_eff = 0.2;
                sum_a += P(i, j) * Qt[i][j] *
                         (rho_sq - 1.0 + rho_sq / sqrt((double)m[i]) * (cs_eff - 1.0));
            }
        }

        a[j] = 1.0 + w[j] * sum_a;

        /* B_{ij} (derived from eq. 43 with nu_ij=0, Qt_{ii}=0) */
        for (i = 0; i < n; i++) {
            B(i, j) = w[j] * P(i, j) * Qt[i][j] * (1.0 - rho[i] * rho[i]);
        }
    }

    /* Solve (I - B^T) * ca_sq = a via Gaussian elimination */
    for (i = 0; i < n; i++) {
        for (j = 0; j < n; j++)
            A(i, j) = (i == j ? 1.0 : 0.0) - B(j, i);
        rhs[i] = a[i];
    }

    for (col = 0; col < n; col++) {
        maxVal = fabs(A(col, col));
        maxRow = col;
        for (row = col + 1; row < n; row++) {
            if (fabs(A(row, col)) > maxVal) {
                maxVal = fabs(A(row, col));
                maxRow = row;
            }
        }
        if (maxRow != col) {
            for (j = 0; j < n; j++) {
                double tmp = A(col, j);
                A(col, j) = A(maxRow, j);
                A(maxRow, j) = tmp;
            }
            { double tmp = rhs[col]; rhs[col] = rhs[maxRow]; rhs[maxRow] = tmp; }
        }
        pivot = A(col, col);
        if (fabs(pivot) < 1e-15) {
            fprintf(stderr, "bna_qna: singular variability matrix\n");
            free(p); free(B); free(A);
            exit(EXIT_FAILURE);
        }
        for (row = col + 1; row < n; row++) {
            factor = A(row, col) / pivot;
            for (j = col; j < n; j++)
                A(row, j) -= factor * A(col, j);
            rhs[row] -= factor * rhs[col];
        }
    }

    for (i = n - 1; i >= 0; i--) {
        ca_sq[i] = rhs[i];
        for (j = i + 1; j < n; j++)
            ca_sq[i] -= A(i, j) * ca_sq[j];
        ca_sq[i] /= A(i, i);
    }

    free(p); free(B); free(A);
    #undef P
    #undef B
    #undef A
}

/* ================================================================
 *  Erlang-C formula: C(m, a) where a = m * rho
 * ================================================================ */

static double erlang_c(int servers, double offered)
{
    /* C(m, a) = [a^m/m! * m/(m-a)] / [sum_{k=0}^{m-1} a^k/k!  +  a^m/m! * m/(m-a)] */
    int k;
    double sum, term, last;

    if (servers == 1)
        return offered;  /* C(1,rho) = rho */

    /* Compute a^k/k! iteratively */
    sum = 1.0;
    term = 1.0;
    for (k = 1; k < servers; k++) {
        term *= offered / (double)k;
        sum += term;
    }
    /* a^m / m! */
    last = term * offered / (double)servers;
    /* last * m/(m-a) */
    last = last * (double)servers / ((double)servers - offered);

    return last / (sum + last);
}

/* ================================================================
 *  Step 4: Congestion measures  (Section V)
 * ================================================================ */

static void compute_congestion(void)
{
    int i;

    for (i = 0; i < n; i++) {
        double ew_fb;  /* waiting time in feedback-eliminated system */

        /* KLB g-factor (Krämer-Langenbach-Belz): correction for c²_a < 1.
         * Whitt 1993 ("Approximations for the GI/G/m queue", Production
         * and Operations Management 2(2)) extended this to m > 1 with the
         * same functional form. Previously the m > 1 branch dropped the
         * factor, silently overestimating E[W] by up to 39% at low c²_a;
         * see validation/algo_review/BNAqna.md §3.1. */
        double g;
        if (ca_sq[i] < 1.0) {
            double num = -2.0 * (1.0 - rho[i]) * (1.0 - ca_sq[i]) * (1.0 - ca_sq[i]);
            double den = 3.0 * rho[i] * (ca_sq[i] + cs_t[i]);
            g = (fabs(den) > 1e-15) ? exp(num / den) : 1.0;
        } else {
            g = 1.0;
        }

        if (m[i] == 1) {
            /* GI/G/1 approximation (eq. 2, 44-45) with KLB g */
            ew_fb = tau_t[i] * rho[i] * (ca_sq[i] + cs_t[i]) * g / (2.0 * (1.0 - rho[i]));
        } else {
            /* GI/G/m approximation (eq. 70) × Whitt-1993 g */
            double offered = rho[i] * (double)m[i];   /* = lambda_i * tau_t_i */
            double ew_mmm;
            double Cm = erlang_c(m[i], offered);
            ew_mmm = Cm * tau_t[i] / ((double)m[i] * (1.0 - rho[i]));
            ew_fb = ew_mmm * (ca_sq[i] + cs_t[i]) / 2.0 * g;
        }

        /* Undo feedback: EW_orig = (1 - q_{ii}) * EW_fb */
        EW[i] = (1.0 - qii_orig[i]) * ew_fb;

        /* Sojourn: ET = tau_orig + EW */
        ET[i] = tau[i] + EW[i];

        /* Mean number in system: EN = alpha + lambda * EW_fb
           where alpha = lambda * tau_t (offered load in feedback system).
           But we want EN including service, so: EN = lam * ET, or
           equivalently EN = lam_i * tau_t_i + lam_i * ew_fb (eq. 47/69)
           then undo feedback: EN = lam_i * tau_orig_i + lam_i * EW_orig_i
                              = lam_i * ET_i */
        EN[i] = lam[i] * ET[i];

        /* Delay probability (Kraemer-Langenbach-Belz, eq. 48-49).
         * Reuses the g already computed above for the wait formula. */
        if (m[i] == 1) {
            Pwgt0[i] = rho[i] * g;
        } else {
            double offered = rho[i] * (double)m[i];
            Pwgt0[i] = erlang_c(m[i], offered) * g;
        }

        /* Clamp probability to [0,1] */
        if (Pwgt0[i] < 0.0) Pwgt0[i] = 0.0;
        if (Pwgt0[i] > 1.0) Pwgt0[i] = 1.0;
    }
}

/* ================================================================
 *  Per-class statistics (call after compute_congestion)
 * ================================================================ */

static void compute_class_stats(void)
{
    int k, i;
    if (num_cust_classes <= 0) return;

    for (k = 0; k < num_cust_classes; k++) {
        EW_total[k] = 0.0;
        ET_total[k] = 0.0;
        if (cc_lambda[k] < 1e-15) continue;
        for (i = 0; i < n; i++) {
            double visit_ratio = cc_alpha[k][i] / cc_lambda[k];
            EW_total[k] += visit_ratio * EW[i];
            ET_total[k] += visit_ratio * (EW[i] + 1.0 / cc_mu[k][i]);
        }
        EN_total[k] = cc_lambda[k] * ET_total[k];
    }
}

/* ================================================================
 *  Output
 * ================================================================ */

static void print_results(void)
{
    int i, k;
    double total_lambda0 = 0.0;
    double total_EN = 0.0;

    printf("QNA (Queueing Network Analyzer)\n");
    printf("================================\n\n");

    printf("%-6s%-9s%-11s%-11s%-11s%-11s%-11s%-11s\n",
           "Node", "Servers", "Util(rho)", "c2_a", "E[W]", "E[N]", "E[T]", "P(W>0)");

    for (i = 0; i < n; i++) {
        printf("%-6d%-9d%-11.4f%-11.4f%-11.6f%-11.6f%-11.6f%-11.4f\n",
               i + 1, m[i], rho[i], ca_sq[i], EW[i], EN[i], ET[i], Pwgt0[i]);
        total_EN += EN[i];
    }

    for (i = 0; i < n; i++)
        total_lambda0 += lambda0[i];

    printf("\nNetwork Totals:\n");
    printf("  External arrival rate: %f\n", total_lambda0);
    printf("  Total E[N]: %f\n", total_EN);
    if (total_lambda0 > 1e-15)
        printf("  Mean sojourn time E[T]: %f\n", total_EN / total_lambda0);

    /* Per-customer-class statistics */
    if (num_cust_classes > 0) {
        printf("\nCUSTOMER CLASS STATISTICS\n");
        printf("=========================\n");
        for (k = 0; k < num_cust_classes; k++) {
            printf("\nClass %d:\n", k + 1);
            printf("  Mean queue time (total):   %f\n", EW_total[k]);
            printf("  Mean sojourn time (total): %f\n", ET_total[k]);
            printf("  Mean number in system:     %f\n", EN_total[k]);
        }
    }

    /* Per-station mean number in queue (all customers) */
    printf("\n");
    {
        int w = 1, t;
        for (t = n; t >= 10; t /= 10) w++;
        for (i = 0; i < n; i++) {
            printf("E[Q_%0*d] = %f\n", w, i + 1, EN[i]);
        }
    }
    printf("\n");
}

static void print_compact(void)
{
    int i, k;
    printf("QNA (BNAqna)\n");
    printf("=================\n");

    if (num_cust_classes > 0) {
        for (k = 0; k < num_cust_classes; k++)
            printf("W_total(class %d) = %f\n", k + 1, EW_total[k]);
        for (k = 0; k < num_cust_classes; k++)
            printf("T_total(class %d) = %f\n", k + 1, ET_total[k]);
        printf("\n");
    }

    for (i = 0; i < n; i++)
        printf("rho_%d = %f\n", i + 1, rho[i]);
    printf("\n");

    /* Per-station throughput and sojourn — already computed during the
     * traffic-equation solve (lam[i]) and the queue-length / wait-time
     * formulas (ET[i]). Emitted in the standard Gamma_k / sojourn_k
     * format so the comparison-table parser can pick them up. */
    for (i = 0; i < n; i++)
        printf("Gamma_%d = %f\n", i + 1, lam[i]);
    printf("\n");

    for (i = 0; i < n; i++)
        printf("sojourn_%d = %f\n", i + 1, ET[i]);
    printf("\n");

    if (num_cust_classes > 0) {
        for (k = 0; k < num_cust_classes; k++)
            printf("X(class %d) = %f\n", k + 1, cc_lambda[k]);
        printf("\n");
    }

    {
        int w = 1, t;
        for (t = n; t >= 10; t /= 10) w++;
        for (i = 0; i < n; i++) {
            printf("E[Q_%0*d] = %f\n", w, i + 1, EN[i]);
        }
    }
    printf("\n");
}

/* ================================================================
 *  Main
 * ================================================================ */

int main(int argc, char *argv[])
{
    int i;
    const char *filename = NULL;

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-c") == 0) {
            compact = 1;
        } else if (argv[i][0] != '-') {
            filename = argv[i];
        } else {
            fprintf(stderr, "bna_qna: unknown option '%s'\n", argv[i]);
            fprintf(stderr, "Usage: bna_qna <input_file> [-c]\n");
            return 1;
        }
    }

    if (!filename) {
        fprintf(stderr, "Usage: bna_qna <input_file> [-c]\n");
        return 1;
    }

    parse_input(filename);
    eliminate_feedback();
    solve_traffic_rates();
    check_stability_dai_vande_vate();   /* warns on Bramson-style instability */
    solve_variability();
    compute_congestion();
    compute_class_stats();

    if (compact)
        print_compact();
    else
        print_results();

    return 0;
}
