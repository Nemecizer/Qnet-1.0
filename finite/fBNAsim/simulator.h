/*
 * simulator.h - Core discrete event simulation engine
 *
 * Simulates a finite-buffer generalized Jackson network with
 * Blocking-After-Service (BAS) semantics.
 */

#ifndef SIMULATOR_H
#define SIMULATOR_H

#include "parser.h"
#include "rng.h"
#include "distributions.h"
#include "event_queue.h"
#include "stats.h"

#include <stdint.h>

typedef enum {
    PARALLEL_NONE,
    PARALLEL_OPENMP,
    PARALLEL_GCD
} ParallelMode;

typedef struct {
    double sim_time;        /* total simulation time per replication */
    double warmup_time;     /* warmup period to discard */
    int    num_runs;        /* number of independent replications */
    uint64_t base_seed;     /* initial RNG seed */
    int    verbose;         /* verbose per-replication output */
    ParallelMode parallel;  /* parallelization strategy */
    int    loss_mode;       /* 1 = loss network (discard on full), 0 = BAS blocking */
    int    external_loss;   /* 1 = lose external arrivals at full station (BAS for internal) */
    int    compact;         /* 1 = compact output (algorithm name + E[X_k] only) */
    int    gui_mode;        /* 1 = GUI output (rho, Gamma, sojourn, E[X_k]) */
    const char *progress_file; /* if non-NULL/non-empty, append one byte per
                                  completed replication (under a critical
                                  section); the wrapping shell renders a
                                  progress bar by polling the file size */
} SimConfig;

/* Run all replications with antithetic pairing.
 * results must have space for config->num_runs entries.
 * Pairs are averaged; *effective_runs = num_runs/2.
 * Returns wall-clock elapsed time in seconds. */
double sim_run_all(const Network *net, const SimConfig *config,
                   RunResult *results, int *effective_runs);

#endif /* SIMULATOR_H */
