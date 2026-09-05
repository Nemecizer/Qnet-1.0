/*
 * stats.c - Statistics accumulators and confidence intervals
 */

#include "stats.h"
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>

/* Compute the expected value (mean) of a distribution. */
static double dist_expected(const Distribution *d)
{
    switch (d->type) {
    case DIST_EXPONENTIAL: return 1.0 / d->params[0];
    case DIST_GAMMA:       return d->params[0] * d->params[1];
    case DIST_UNIFORM:     return (d->params[0] + d->params[1]) / 2.0;
    case DIST_CONSTANT:    return d->params[0];
    case DIST_WEIBULL:     return d->params[1] * tgamma(1.0 + 1.0 / d->params[0]);
    case DIST_ERLANG:      return d->params[0] / d->params[1];
    case DIST_LOGNORMAL:   return exp(d->params[0] + d->params[1] * d->params[1] / 2.0);
    case DIST_PARETO:      return (d->params[0] > 1.0)
                                  ? d->params[0] * d->params[1] / (d->params[0] - 1.0)
                                  : 1e30;
    case DIST_POISSON:     return d->params[0];
    }
    return 1.0;
}

/* t_{n-1, 0.975} critical values for 95% CI, n = 2..30. */
static const double t_crit[] = {
    /* n=2  */  12.706, /*  3 */  4.303, /*  4 */  3.182, /*  5 */  2.776,
    /*  6  */   2.571, /*  7 */  2.447, /*  8 */  2.365, /*  9 */  2.306,
    /* 10  */   2.262, /* 11 */  2.228, /* 12 */  2.201, /* 13 */  2.179,
    /* 14  */   2.160, /* 15 */  2.145, /* 16 */  2.131, /* 17 */  2.120,
    /* 18  */   2.110, /* 19 */  2.101, /* 20 */  2.093, /* 21 */  2.086,
    /* 22  */   2.080, /* 23 */  2.074, /* 24 */  2.069, /* 25 */  2.064,
    /* 26  */   2.060, /* 27 */  2.056, /* 28 */  2.052, /* 29 */  2.048,
    /* 30  */   2.045
};

static double get_t_crit(int n)
{
    if (n < 2)   return 0.0;
    if (n <= 30) return t_crit[n - 2];
    return 1.96;  /* large-sample normal approximation */
}

void stats_confidence(const double *data, int n, double *mean_out, double *hw_out)
{
    if (n < 1) {
        *mean_out = 0.0;
        *hw_out   = 0.0;
        return;
    }

    double sum = 0.0;
    for (int i = 0; i < n; i++)
        sum += data[i];
    double mean = sum / n;

    if (n < 2) {
        *mean_out = mean;
        *hw_out   = 0.0;
        return;
    }

    double ss = 0.0;
    for (int i = 0; i < n; i++) {
        double diff = data[i] - mean;
        ss += diff * diff;
    }
    double var = ss / (n - 1);
    double se  = sqrt(var / n);

    *mean_out = mean;
    *hw_out   = get_t_crit(n) * se;
}

/* Per-call deadlock summary used by every output mode. Returns the
 * number of deadlocked replications so callers can decide whether to
 * suppress further reporting (we still print the partial averages
 * because they're computed over the pre-deadlock observation window). */
static int report_deadlocks(const RunResult *runs, int n_runs)
{
    int n_dead = 0;
    double earliest = 0.0;
    for (int r = 0; r < n_runs; r++) {
        if (runs[r].deadlocked) {
            if (n_dead == 0 || runs[r].deadlock_time < earliest)
                earliest = runs[r].deadlock_time;
            n_dead++;
        }
    }
    if (n_dead > 0) {
        fprintf(stderr,
            "\nWARNING: BAS deadlock detected in %d / %d replication(s).\n"
            "  Earliest deadlock at sim_time = %.4f.\n"
            "  All servers became blocked-after-service, so no future\n"
            "  service completion can ever fire. The reported averages\n"
            "  reflect the SATURATED FROZEN STATE (every buffer at\n"
            "  capacity, throughput = 0) — not a steady-state estimate.\n"
            "  This usually means the network is unstable under FCFS+BAS\n"
            "  (e.g., Kumar-Seidman 1990 reentrant pathology). Try -l (loss\n"
            "  mode) or -e (external loss + BAS) for a meaningful comparison\n"
            "  with the SRBM analytical solvers.\n\n",
            n_dead, n_runs, earliest);
    }
    return n_dead;
}

void stats_print_summary(const RunResult *runs, int n_runs, int d)
{
    double mean, hw;
    double *tmp = (double *)malloc(sizeof(double) * (size_t)n_runs);
    int K = (n_runs > 0) ? runs[0].K : 1;

    report_deadlocks(runs, n_runs);

    printf("\n--- Results (95%% CI, %d replications) ---\n\n", n_runs);

    /* Throughput */
    for (int r = 0; r < n_runs; r++) tmp[r] = runs[r].throughput;
    stats_confidence(tmp, n_runs, &mean, &hw);
    printf("Throughput:          %10.4f +/- %.4f\n", mean, hw);

    /* Loss rate */
    for (int r = 0; r < n_runs; r++) tmp[r] = runs[r].loss_rate;
    stats_confidence(tmp, n_runs, &mean, &hw);
    printf("Loss rate:           %10.4f +/- %.4f\n", mean, hw);

    /* Avg sojourn */
    for (int r = 0; r < n_runs; r++) tmp[r] = runs[r].avg_sojourn;
    stats_confidence(tmp, n_runs, &mean, &hw);
    printf("Avg sojourn time:    %10.4f +/- %.4f\n", mean, hw);

    printf("\n");
    printf("  Station   Utilization              Avg Queue Length          Avg Buffer Occupancy\n");
    printf("  -------   -------------------------  -------------------------  -------------------------\n");

    for (int i = 0; i < d; i++) {
        double u_mean, u_hw, b_mean, b_hw, q_mean, q_hw;

        for (int r = 0; r < n_runs; r++) tmp[r] = runs[r].utilization[i];
        stats_confidence(tmp, n_runs, &u_mean, &u_hw);

        for (int r = 0; r < n_runs; r++) tmp[r] = runs[r].avg_buffer[i];
        stats_confidence(tmp, n_runs, &b_mean, &b_hw);

        for (int r = 0; r < n_runs; r++)
            tmp[r] = runs[r].avg_buffer[i] + runs[r].utilization[i];
        stats_confidence(tmp, n_runs, &q_mean, &q_hw);

        printf("  S%-6d   %8.4f +/- %-8.4f    %8.4f +/- %-8.4f    %8.4f +/- %-8.4f\n",
               i + 1, u_mean, u_hw, q_mean, q_hw, b_mean, b_hw);
    }

    /* Per-station throughput */
    printf("\n");
    printf("  Station   Throughput                Loss Rate\n");
    printf("  -------   -------------------------  -------------------------\n");

    for (int i = 0; i < d; i++) {
        double t_mean, t_hw, l_mean, l_hw;

        for (int r = 0; r < n_runs; r++) tmp[r] = runs[r].station_throughput[i];
        stats_confidence(tmp, n_runs, &t_mean, &t_hw);

        for (int r = 0; r < n_runs; r++) tmp[r] = runs[r].station_loss_rate[i];
        stats_confidence(tmp, n_runs, &l_mean, &l_hw);

        printf("  S%-6d   %8.4f +/- %-8.4f    %8.4f +/- %-8.4f\n",
               i + 1, t_mean, t_hw, l_mean, l_hw);
    }

    /* Per-class queue lengths (only when K > 1).
     *
     * NOTE: class_queue[k][i] accumulates (buffer + server) occupancy,
     * i.e. it INCLUDES the customer currently in service. This differs
     * from the per-station "Avg Buffer Occupancy" column above, which
     * is buffer-only. Labels make this explicit. */
    if (K > 1) {
        printf("\n--- Mean Total Occupancy by Customer Class (queue + in-service) ---\n\n");

        /* Header */
        printf("          ");
        for (int k = 0; k < K; k++)
            printf("  Class %-4d   ", k + 1);
        printf("\n");

        for (int i = 0; i < d; i++) {
            printf("  S%-6d", i + 1);
            for (int k = 0; k < K; k++) {
                double cq_mean, cq_hw;
                for (int r = 0; r < n_runs; r++)
                    tmp[r] = runs[r].class_queue[k][i];
                stats_confidence(tmp, n_runs, &cq_mean, &cq_hw);
                printf("  %8.4f     ", cq_mean);
            }
            printf("\n");
        }
    }

    /* Print Gamma_k (per-station throughput) and E[X_k] last.
     * E[X_k] = mean buffer occupancy only (not including customers in
     * service), matching the SRBM's state variable definition where
     * X_i ∈ [0, a_i] is the buffer content. */
    printf("\n");
    for (int i = 0; i < d; i++) {
        double t_mean, t_hw;
        for (int r = 0; r < n_runs; r++) tmp[r] = runs[r].station_throughput[i];
        stats_confidence(tmp, n_runs, &t_mean, &t_hw);
        printf("Gamma_%d = %.6f\n", i + 1, t_mean);
    }

    printf("\n");
    /* E[X_k] = total occupancy (buffer + in-service), matching SRBM/FEM. */
    {
        int w = 1;
        for (int t = d; t >= 10; t /= 10) w++;
        for (int i = 0; i < d; i++) {
            double q_mean, q_hw;
            for (int r = 0; r < n_runs; r++)
                tmp[r] = runs[r].avg_buffer[i] + runs[r].utilization[i];
            stats_confidence(tmp, n_runs, &q_mean, &q_hw);
            printf("E[X_%0*d] = %.6f\t(%.6f)\n", w, i + 1, q_mean, q_hw);
        }
    }

    printf("\n");
    free(tmp);
}

void stats_print_compact(const RunResult *runs, int n_runs, int d)
{
    double *tmp = (double *)malloc(sizeof(double) * (size_t)n_runs);

    report_deadlocks(runs, n_runs);

    printf("Monte Carlo Simulation\n");
    printf("==================\n");

    /* E[X_k] = total occupancy (buffer + in-service); see stats_print_gui
     * for the full rationale on why buffer-only would mismatch SRBM/FEM. */
    {
        int w = 1;
        for (int t = d; t >= 10; t /= 10) w++;
        for (int i = 0; i < d; i++) {
            double q_mean, q_hw;
            for (int r = 0; r < n_runs; r++)
                tmp[r] = runs[r].avg_buffer[i] + runs[r].utilization[i];
            stats_confidence(tmp, n_runs, &q_mean, &q_hw);
            printf("E[X_%0*d] = %.6f\t(%.6f)\n", w, i + 1, q_mean, q_hw);
        }
    }

    printf("\n");
    free(tmp);
}

void stats_print_gui(const RunResult *runs, int n_runs, int d, const Network *net)
{
    double *tmp = (double *)malloc(sizeof(double) * (size_t)n_runs);
    double mean, hw;

    report_deadlocks(runs, n_runs);

    printf("Monte Carlo Simulation\n");
    printf("==================\n\n");

    /* Utilization (rho_k) */
    for (int i = 0; i < d; i++) {
        for (int r = 0; r < n_runs; r++) tmp[r] = runs[r].utilization[i];
        stats_confidence(tmp, n_runs, &mean, &hw);
        printf("rho_%d = %.6f\t(%.6f)\n", i + 1, mean, hw);
    }

    printf("\n");

    /* Throughput (Gamma_k) */
    for (int i = 0; i < d; i++) {
        for (int r = 0; r < n_runs; r++) tmp[r] = runs[r].station_throughput[i];
        stats_confidence(tmp, n_runs, &mean, &hw);
        printf("Gamma_%d = %.6f\t(%.6f)\n", i + 1, mean, hw);
    }

    printf("\n");

    /* Sojourn time per station via Little's law: sojourn_k = E[X_k] / Gamma_k,
     * where E[X_k] is TOTAL station occupancy (buffer + customer in service),
     * matching the SRBM/FEM convention. This yields the mean TOTAL TIME at
     * station k (waiting + service), not just the wait. SRBM/FEM's sojourn
     * formula (q[i]/Gamma_i with q[i] = total occupancy) computes the same
     * quantity, so the two methods are now directly comparable.
     *
     * Note: the human-readable summary table above still shows separate
     * "Avg Buffer Occupancy" and "Avg Queue Length" columns; this block
     * only feeds the awk-parsed -G output and the analytical comparison. */
    for (int i = 0; i < d; i++) {
        double q_mean, q_hw, t_mean, t_hw;
        for (int r = 0; r < n_runs; r++)
            tmp[r] = runs[r].avg_buffer[i] + runs[r].utilization[i];
        stats_confidence(tmp, n_runs, &q_mean, &q_hw);
        for (int r = 0; r < n_runs; r++) tmp[r] = runs[r].station_throughput[i];
        stats_confidence(tmp, n_runs, &t_mean, &t_hw);
        double sojourn = (t_mean > 1e-12) ? q_mean / t_mean : 0.0;
        /* Approximate CI via delta method */
        double sojourn_hw = (t_mean > 1e-12) ? sojourn * sqrt((q_hw*q_hw)/(q_mean*q_mean + 1e-30) + (t_hw*t_hw)/(t_mean*t_mean)) : 0.0;
        printf("sojourn_%d = %.6f\t(%.6f)\n", i + 1, sojourn, sojourn_hw);
    }

    printf("\n");

    /* E[X_k] = mean TOTAL station occupancy (buffer + customer in service),
     * matching the SRBM/FEM state variable. The simulator's class_queue
     * accumulator uses the same convention (buffer + servers), so the per-
     * station E[X_k] sum equals the per-class N_total sum (mass conservation
     * at the network level). Reporting buffer-only here would create a
     * Σρ_i offset versus SRBM/FEM and make the comparison meaningless. */
    {
        int w = 1;
        for (int t = d; t >= 10; t /= 10) w++;
        for (int i = 0; i < d; i++) {
            for (int r = 0; r < n_runs; r++)
                tmp[r] = runs[r].avg_buffer[i] + runs[r].utilization[i];
            stats_confidence(tmp, n_runs, &mean, &hw);
            printf("E[X_%0*d] = %.6f\t(%.6f)\n", w, i + 1, mean, hw);
        }
    }

    printf("\n");

    /* ── Customer class statistics ── */
    int K = (n_runs > 0) ? runs[0].K : 0;
    if (K > 0 && net != NULL) {
        /* Compute arrival rates from interarrival distributions */
        double lambda[MAX_CLASSES];
        for (int k = 0; k < K; k++) {
            double ia_mean = dist_expected(&net->arrival_dist[k]);
            lambda[k] = (ia_mean > 1e-15) ? 1.0 / ia_mean : 0.0;
        }

        /* Solve traffic equations for visit rates (alpha_k[i]):
         * alpha_k[i] = lambda_k * delta(i,0) + sum_j alpha_k[j] * P_k[j][i]
         * All external arrivals enter at station 0. */
        double alpha[MAX_CLASSES][MAX_STATIONS];
        for (int k = 0; k < K; k++) {
            if (lambda[k] < 1e-15) {
                memset(alpha[k], 0, sizeof(double) * (size_t)d);
                continue;
            }
            double prev[MAX_STATIONS];
            for (int i = 0; i < d; i++)
                alpha[k][i] = lambda[k];
            for (int iter = 0; iter < 1000; iter++) {
                memcpy(prev, alpha[k], sizeof(double) * (size_t)d);
                for (int i = 0; i < d; i++) {
                    alpha[k][i] = (i == 0) ? lambda[k] : 0.0;
                    for (int j = 0; j < d; j++)
                        alpha[k][i] += prev[j] * net->routing[k][j][i];
                }
                double maxdiff = 0.0;
                for (int i = 0; i < d; i++) {
                    double diff = fabs(alpha[k][i] - prev[i]);
                    if (diff > maxdiff) maxdiff = diff;
                }
                if (maxdiff < 1e-12) break;
            }
        }

        /* Per-class output semantics (matches what SRBM/FEM print under the
         * same labels; do not compare against per-station E[X_i] directly):
         *
         *   N_total(class k) = total class-k customers in network averaged
         *                      over time, INCLUDING the in-service customer
         *                      (sum of class_queue[k][i] over i, where
         *                      class_queue accumulates buffer + servers).
         *   T_total(class k) = N_total(k) / lambda_k        (Little's law)
         *   W_total(class k) = T_total(k) - sum of expected service times
         *                      visited along class-k's mean route (i.e.
         *                      mean WAIT in queue, no service contribution).
         *
         * Therefore: W_total + sum(visit_i / mu_{k,i}) = T_total. The
         * numbers are mutually consistent; just don't conflate N_total
         * with the per-station E[X_k] (buffer-only) printed earlier. */
        double n_mean_k[MAX_CLASSES], n_hw_k[MAX_CLASSES];
        for (int k = 0; k < K; k++) {
            for (int r = 0; r < n_runs; r++) {
                double n_tot = 0.0;
                for (int i = 0; i < d; i++)
                    n_tot += runs[r].class_queue[k][i];
                tmp[r] = n_tot;
            }
            stats_confidence(tmp, n_runs, &n_mean_k[k], &n_hw_k[k]);
        }

        /* W_total(class k) = T_total - expected_service */
        for (int k = 0; k < K; k++) {
            if (lambda[k] < 1e-15) {
                printf("W_total(class %d) = 0.000000\t(0.000000)\n", k + 1);
                continue;
            }
            double t_mean = n_mean_k[k] / lambda[k];
            double t_hw   = n_hw_k[k] / lambda[k];
            double exp_svc = 0.0;
            for (int i = 0; i < d; i++) {
                double visit = alpha[k][i] / lambda[k];
                exp_svc += visit * dist_expected(&net->service_dist[i][k]);
            }
            double w = t_mean - exp_svc;
            if (w < 0) w = 0;
            printf("W_total(class %d) = %.6f\t(%.6f)\n", k + 1, w, t_hw);
        }
        printf("\n");

        /* T_total(class k) = N_total / lambda_k (Little's law) */
        for (int k = 0; k < K; k++) {
            if (lambda[k] < 1e-15) {
                printf("T_total(class %d) = 0.000000\t(0.000000)\n", k + 1);
                continue;
            }
            printf("T_total(class %d) = %.6f\t(%.6f)\n", k + 1,
                   n_mean_k[k] / lambda[k], n_hw_k[k] / lambda[k]);
        }
        printf("\n");

        /* N_total(class k) */
        for (int k = 0; k < K; k++) {
            printf("N_total(class %d) = %.6f\t(%.6f)\n", k + 1,
                   n_mean_k[k], n_hw_k[k]);
        }
        printf("\n");
    }

    free(tmp);
}
