/*
 * fBNAsim - Finite-Buffer Network Simulator
 *
 * Discrete event simulation for generalized Jackson queueing networks
 * with finite buffers and Blocking-After-Service (BAS).
 * Supports multiple customer classes and multiple servers per station.
 *
 * Usage: fBNAsim -f <network_file> [options]
 *
 *   -f <file>   Input network file (required)
 *   -s <seed>   RNG seed (default: 12345)
 *   -n <runs>   Number of replications (default: 30)
 *   -T <time>   Simulation time per replication (default: 500000)
 *   -w <time>   Warmup period to discard (default: 50000)
 *   -o          Parallelize with OpenMP (requires make OPENMP=1)
 *   -a          Parallelize with Apple Grand Central Dispatch
 *   -l          Loss mode (discard customers when buffer full, no BAS blocking)
 *   -e          External loss + BAS (lose external arrivals, BAS for internal)
 *   -v          Verbose per-replication output
 *   -h          Print this help message
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "parser.h"
#include "simulator.h"
#include "stats.h"
#include "../../common/bnet_memcheck.h"

#ifdef _OPENMP
#include <omp.h>
#endif

static const char *dist_name(DistType t)
{
    switch (t) {
    case DIST_EXPONENTIAL: return "Exponential";
    case DIST_GAMMA:       return "Gamma";
    case DIST_UNIFORM:     return "Uniform";
    case DIST_CONSTANT:    return "Constant";
    case DIST_WEIBULL:     return "Weibull";
    case DIST_ERLANG:      return "Erlang";
    case DIST_LOGNORMAL:   return "Lognormal";
    case DIST_PARETO:      return "Pareto";
    case DIST_POISSON:     return "Poisson";
    }
    return "?";
}

static void print_dist(const Distribution *d)
{
    printf("%s(", dist_name(d->type));
    switch (d->type) {
    case DIST_EXPONENTIAL: printf("rate=%.4g",  d->params[0]); break;
    case DIST_GAMMA:       printf("shape=%.4g, scale=%.4g", d->params[0], d->params[1]); break;
    case DIST_UNIFORM:     printf("min=%.4g, max=%.4g",     d->params[0], d->params[1]); break;
    case DIST_CONSTANT:    printf("value=%.4g", d->params[0]); break;
    case DIST_WEIBULL:     printf("shape=%.4g, scale=%.4g", d->params[0], d->params[1]); break;
    case DIST_ERLANG:      printf("k=%d, rate=%.4g", (int)d->params[0], d->params[1]); break;
    case DIST_LOGNORMAL:   printf("mu=%.4g, sigma=%.4g",    d->params[0], d->params[1]); break;
    case DIST_PARETO:      printf("shape=%.4g, scale=%.4g", d->params[0], d->params[1]); break;
    case DIST_POISSON:     printf("lambda=%.4g", d->params[0]); break;
    }
    printf(")");
}

static const char *parallel_label(ParallelMode m)
{
    switch (m) {
    case PARALLEL_NONE:   return "sequential";
    case PARALLEL_OPENMP: return "OpenMP";
    case PARALLEL_GCD:    return "Apple GCD";
    }
    return "?";
}

static void usage(const char *prog)
{
    fprintf(stderr,
        "fBNAsim - Finite-Buffer Network Simulator\n"
        "\n"
        "Usage: %s -f <network_file> [options]\n"
        "\n"
        "  -f <file>   Input network file (required)\n"
        "  -s <seed>   RNG seed (default: 12345)\n"
        "  -n <runs>   Number of replications (default: 30)\n"
        "  -T <time>   Simulation time per replication (default: 500000)\n"
        "  -w <time>   Warmup period to discard (default: 50000)\n"
        "  -o          Parallelize with OpenMP (default when built with OpenMP)\n"
        "  -a          Parallelize with Apple Grand Central Dispatch\n"
        "  -S          Force sequential (disable parallelism)\n"
        "  -l          Loss mode (discard on full buffer, no BAS blocking)\n"
        "  -e          External loss + BAS (lose external arrivals, BAS for internal)\n"
        "  -v          Verbose per-replication output\n"
        "  -P <file>   Progress file: append one byte per completed replication\n"
        "  -h          Print this help message\n",
        prog);
}

int main(int argc, char **argv)
{
    const char *input_file = NULL;
    SimConfig config;
    config.base_seed   = 12345;
    config.num_runs    = 30;
    config.sim_time    = 500000.0;
    config.warmup_time = 50000.0;
    config.verbose     = 0;
#ifdef _OPENMP
    config.parallel    = PARALLEL_OPENMP;     /* OpenMP on by default */
#else
    config.parallel    = PARALLEL_NONE;
#endif
    config.loss_mode      = 0;
    config.external_loss  = 0;
    config.compact        = 0;
    config.gui_mode       = 0;
    config.progress_file  = NULL;

    /* ── Parse command line ──────────────────────────────────── */
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-f") == 0 && i + 1 < argc) {
            input_file = argv[++i];
        } else if (strcmp(argv[i], "-s") == 0 && i + 1 < argc) {
            config.base_seed = (uint64_t)strtoull(argv[++i], NULL, 10);
        } else if (strcmp(argv[i], "-n") == 0 && i + 1 < argc) {
            config.num_runs = atoi(argv[++i]);
        } else if (strcmp(argv[i], "-T") == 0 && i + 1 < argc) {
            config.sim_time = atof(argv[++i]);
        } else if (strcmp(argv[i], "-w") == 0 && i + 1 < argc) {
            config.warmup_time = atof(argv[++i]);
        } else if (strcmp(argv[i], "-o") == 0) {
            config.parallel = PARALLEL_OPENMP;
        } else if (strcmp(argv[i], "-a") == 0) {
            config.parallel = PARALLEL_GCD;
        } else if (strcmp(argv[i], "-S") == 0) {
            config.parallel = PARALLEL_NONE;
        } else if (strcmp(argv[i], "-l") == 0) {
            config.loss_mode = 1;
        } else if (strcmp(argv[i], "-e") == 0) {
            config.external_loss = 1;
        } else if (strcmp(argv[i], "-c") == 0) {
            config.compact = 1;
        } else if (strcmp(argv[i], "-G") == 0) {
            config.gui_mode = 1;
        } else if (strcmp(argv[i], "-v") == 0) {
            config.verbose = 1;
        } else if (strcmp(argv[i], "-P") == 0 && i + 1 < argc) {
            config.progress_file = argv[++i];
        } else if (strcmp(argv[i], "-h") == 0) {
            usage(argv[0]);
            return 0;
        } else {
            fprintf(stderr, "Unknown option: %s\n", argv[i]);
            usage(argv[0]);
            return 1;
        }
    }

    if (!input_file) {
        fprintf(stderr, "Error: -f <network_file> is required.\n\n");
        usage(argv[0]);
        return 1;
    }

    if (config.num_runs < 1) {
        fprintf(stderr, "Error: number of runs must be >= 1\n");
        return 1;
    }
    if (config.warmup_time >= config.sim_time) {
        fprintf(stderr, "Error: warmup time (%.1f) must be less than "
                "simulation time (%.1f)\n",
                config.warmup_time, config.sim_time);
        return 1;
    }

    /* ── Parse network file ──────────────────────────────────── */
    Network net;
    if (parse_network_file(input_file, &net) != 0) {
        return 1;
    }

    /* ── Print summary ───────────────────────────────────────── */
    if (!config.compact && !config.gui_mode) {
        printf("===== fBNAsim: Finite-Buffer Network Simulator =====\n\n");
        printf("Input file:    %s\n", input_file);
        printf("Dimension:     %d stations\n", net.d);
        if (net.K > 1)
            printf("Classes:       %d\n", net.K);
        printf("Replications:  %d\n", config.num_runs);
        printf("Sim time:      %.0f  (warmup: %.0f)\n",
               config.sim_time, config.warmup_time);
        printf("Seed:          %llu\n", (unsigned long long)config.base_seed);
        printf("Parallel:      %s\n", parallel_label(config.parallel));
        printf("Blocking:      %s\n",
               config.loss_mode ? "Loss (discard)" :
               config.external_loss ? "BAS + external loss" : "BAS");

        /* Arrivals */
        if (net.K == 1) {
            printf("\nArrival:       ");
            print_dist(&net.arrival_dist[0]);
            printf("\n");
        } else {
            printf("\nArrivals:\n");
            for (int k = 0; k < net.K; k++) {
                printf("  Class %d:  ", k + 1);
                print_dist(&net.arrival_dist[k]);
                printf("\n");
            }
        }

        /* Servers per station (only if any > 1) */
        {
            int any_multi = 0;
            for (int i = 0; i < net.d; i++)
                if (net.servers[i] > 1) { any_multi = 1; break; }
            if (any_multi) {
                printf("Servers:       [");
                for (int i = 0; i < net.d; i++)
                    printf("%s%d", i ? ", " : "", net.servers[i]);
                printf("]\n");
            }
        }

        printf("Buffers:       [");
        for (int i = 0; i < net.d; i++)
            printf("%s%d", i ? ", " : "", net.buffer_size[i]);
        printf("]\n");

        /* Service distributions */
        if (net.K == 1) {
            printf("Service:       ");
            for (int i = 0; i < net.d; i++) {
                printf("S%d=", i + 1);
                print_dist(&net.service_dist[i][0]);
                if (i + 1 < net.d) printf(", ");
            }
            printf("\n");
        } else {
            printf("Service:\n");
            for (int i = 0; i < net.d; i++) {
                for (int k = 0; k < net.K; k++) {
                    printf("  S%d/C%d=", i + 1, k + 1);
                    print_dist(&net.service_dist[i][k]);
                    if (k + 1 < net.K) printf(", ");
                }
                printf("\n");
            }
        }

        /* Routing matrices */
        for (int k = 0; k < net.K; k++) {
            if (net.K > 1)
                printf("Routing (class %d):\n", k + 1);
            else
                printf("Routing:\n");
            for (int i = 0; i < net.d; i++) {
                printf("  S%d -> ", i + 1);
                double row_sum = 0;
                int first = 1;
                for (int j = 0; j < net.d; j++) {
                    if (net.routing[k][i][j] > 0) {
                        if (!first) printf(", ");
                        printf("S%d(%.4f)", j + 1, net.routing[k][i][j]);
                        first = 0;
                        row_sum += net.routing[k][i][j];
                    }
                }
                double exit_prob = 1.0 - row_sum;
                if (exit_prob > 1e-9) {
                    if (!first) printf(", ");
                    printf("exit(%.4f)", exit_prob);
                }
                printf("\n");
            }
        }
    }

    /* ── Run simulation ──────────────────────────────────────── */
    /* Same reasoning as the infinite engine: num_runs is user-supplied and
       unbounded; the event queue scales with jobs in system instead. */
    bnet_memcheck_alloc((uint64_t) config.num_runs * (uint64_t) sizeof(RunResult),
        "finite-buffer simulation run results",
        "reduce the replication count (-n)");
    RunResult *results = (RunResult *)calloc((size_t)config.num_runs,
                                            sizeof(RunResult));
    if (!results) {
        fprintf(stderr, "Error: out of memory\n");
        return 1;
    }

    if (!config.compact && !config.gui_mode) {
        printf("\nRunning %d replications (%s)...\n",
               config.num_runs, parallel_label(config.parallel));
    }

    int effective_runs;
    double elapsed = sim_run_all(&net, &config, results, &effective_runs);

    /* ── Print results (E[X_k] printed last by stats_print_summary) ── */
    if (config.gui_mode) {
        stats_print_gui(results, effective_runs, net.d, &net);
    } else if (config.compact) {
        stats_print_compact(results, effective_runs, net.d);
    } else {
        printf("Elapsed time:  %.3f seconds (%s)\n",
               elapsed, parallel_label(config.parallel));
        printf("Antithetic:    %d pairs from %d runs\n",
               effective_runs, config.num_runs + (config.num_runs % 2));
        stats_print_summary(results, effective_runs, net.d);
    }

    free(results);
    return 0;
}
