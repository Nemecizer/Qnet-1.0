/*
 * stats.h - Statistics accumulators and confidence intervals
 */

#ifndef STATS_H
#define STATS_H

#include "parser.h"

/* Per-replication results. */
typedef struct {
    double throughput;                       /* departures / observation_time */
    double loss_rate;                        /* lost / total_arrivals */
    double avg_buffer[MAX_STATIONS];         /* time-avg buffer occupancy */
    double utilization[MAX_STATIONS];        /* fraction of time busy/blocked */
    double avg_sojourn;                      /* mean time in system */
    double station_throughput[MAX_STATIONS];  /* per-station completions / obs_time */
    double station_loss_rate[MAX_STATIONS];   /* per-station losses / obs_time */
    int    K;                                /* number of customer classes */
    double class_queue[MAX_CLASSES][MAX_STATIONS]; /* per-class mean queue length */
    int    deadlocked;                       /* 1 if BAS deadlock was detected */
    double deadlock_time;                    /* sim time at first deadlock */
} RunResult;

/* Compute mean and 95% confidence interval half-width for an array. */
void stats_confidence(const double *data, int n, double *mean_out, double *hw_out);

/* Print the final summary table. */
void stats_print_summary(const RunResult *runs, int n_runs, int d);

/* Print compact output: algorithm name and E[X_k] values only. */
void stats_print_compact(const RunResult *runs, int n_runs, int d);

/* Print GUI output: rho_k, Gamma_k, sojourn_k, E[X_k], plus customer class stats. */
void stats_print_gui(const RunResult *runs, int n_runs, int d, const Network *net);

#endif /* STATS_H */
