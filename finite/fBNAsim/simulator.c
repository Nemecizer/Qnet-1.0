/*
 * simulator.c - Core discrete event simulation engine (fBNAsim)
 *
 * Finite-buffer generalized Jackson network with Blocking-After-Service.
 * Supports multiple customer classes (K) and multiple servers per station (c_i).
 *
 * Buffer convention: buffer_size[i] is the waiting room capacity IN FRONT
 * of station i (separate from the servers).  A station can hold at most
 * buffer_size[i] + servers[i] customers (buffer waiting + servers).
 *
 * Multi-server: each station has servers[i] identical parallel servers.
 * servers_busy tracks actively serving; servers_blocked tracks servers
 * blocked on downstream.  Idle servers = servers[i] - busy - blocked.
 *
 * Blocking-After-Service (BAS):
 *   When a customer finishes service at station i and the destination
 *   station j cannot accept it, the server at station i becomes BLOCKED.
 *   The customer remains, occupying that server.  When a slot opens at j,
 *   the transfer occurs inline (no separate unblock event needed).
 *
 * Multi-class: K independent arrival streams.  Each class has its own
 * arrival distribution, per-station service distributions, and routing
 * matrix.
 *
 * Parallelization:
 *   Each replication is independent (own RNG seed, own state).
 *     PARALLEL_NONE   — sequential loop
 *     PARALLEL_OPENMP — OpenMP parallel for (requires -fopenmp)
 *     PARALLEL_GCD    — Apple Grand Central Dispatch (dispatch_apply_f)
 */

#include "simulator.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <pthread.h>

#ifdef _OPENMP
#include <omp.h>
#endif

#ifdef __APPLE__
#include <dispatch/dispatch.h>
#endif

/* ================================================================== */
/* Replication progress reporting                                     */
/* ================================================================== */
/* Unified progress protocol shared with all Qnet solvers:
 *   - First line of progress file is the total count, written as
 *     decimal ASCII followed by '\n'.
 *   - Then exactly one '.' byte is appended per completed unit
 *     (here: per replication; for other solvers: per basis function,
 *     per mesh element, etc.).
 *   - Locking is via pthread_mutex so it works uniformly for OpenMP
 *     threads and GCD worker threads.
 * The Swift shell wrapper reads the header for the denominator and
 * uses (file_size - header_len) for the numerator. */
static FILE *g_progress_fp = NULL;
static pthread_mutex_t g_progress_lock = PTHREAD_MUTEX_INITIALIZER;

static void progress_open(const char *path, long total) {
    if (!path || !path[0]) return;
    g_progress_fp = fopen(path, "wb");
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

/* ================================================================== */
/* Per-station state                                                  */
/* ================================================================== */

/* Small FIFO queue for customers waiting in the buffer. */
typedef struct {
    int    *ids;
    int    *classes;
    double *entry_times;
    int     head, tail, count, capacity;
} WaitQueue;

static void wq_init(WaitQueue *q, int cap)
{
    q->capacity = cap + 1;
    q->ids         = (int *)   calloc((size_t)q->capacity, sizeof(int));
    q->classes     = (int *)   calloc((size_t)q->capacity, sizeof(int));
    q->entry_times = (double *)calloc((size_t)q->capacity, sizeof(double));
    q->head = q->tail = q->count = 0;
}

static void wq_free(WaitQueue *q)
{
    free(q->ids);
    free(q->classes);
    free(q->entry_times);
}

static void wq_push(WaitQueue *q, int id, int cls, double et)
{
    q->ids[q->tail]         = id;
    q->classes[q->tail]     = cls;
    q->entry_times[q->tail] = et;
    q->tail = (q->tail + 1) % q->capacity;
    q->count++;
}

static void wq_pop(WaitQueue *q, int *id, int *cls, double *et)
{
    *id  = q->ids[q->head];
    *cls = q->classes[q->head];
    *et  = q->entry_times[q->head];
    q->head = (q->head + 1) % q->capacity;
    q->count--;
}

/* FIFO queue of station indices blocked on a given buffer. */
typedef struct {
    int data[MAX_STATIONS];
    int head, tail, count;
} BlockedQueue;

static void bq_init(BlockedQueue *bq)
{
    bq->head = bq->tail = bq->count = 0;
}

static void bq_push(BlockedQueue *bq, int station)
{
    bq->data[bq->tail] = station;
    bq->tail = (bq->tail + 1) % MAX_STATIONS;
    bq->count++;
}

static int bq_pop(BlockedQueue *bq)
{
    int v = bq->data[bq->head];
    bq->head = (bq->head + 1) % MAX_STATIONS;
    bq->count--;
    return v;
}

/* Info about one blocked server. */
typedef struct {
    int    dest;
    int    cust_id;
    int    cust_class;
    double entry_time;
} BlockedInfo;

#define MAX_BLOCKED MAX_STATIONS

typedef struct {
    int          num_servers;
    int          servers_busy;
    int          servers_blocked;
    int          buffer_count;
    int          buffer_capacity;
    WaitQueue    queue;
    BlockedQueue blocked_on_me;  /* stations blocked waiting for space here */

    /* Blocked server list (unordered array for scan-by-dest removal) */
    BlockedInfo  blk[MAX_BLOCKED];
    int          blk_count;
} StationState;

/* Add a blocked entry. */
static void blk_add(StationState *st, int dest, int cid, int cls, double et)
{
    st->blk[st->blk_count].dest       = dest;
    st->blk[st->blk_count].cust_id    = cid;
    st->blk[st->blk_count].cust_class = cls;
    st->blk[st->blk_count].entry_time = et;
    st->blk_count++;
}

/* Find and remove the first blocked entry with the given dest.
 * Returns the removed entry via *out. Returns 1 if found, 0 if not. */
static int blk_remove_by_dest(StationState *st, int dest, BlockedInfo *out)
{
    for (int idx = 0; idx < st->blk_count; idx++) {
        if (st->blk[idx].dest == dest) {
            *out = st->blk[idx];
            st->blk[idx] = st->blk[st->blk_count - 1];
            st->blk_count--;
            return 1;
        }
    }
    return 0;
}

/* ================================================================== */
/* Simulation state for one replication                               */
/* ================================================================== */

typedef struct {
    const Network  *net;
    const SimConfig *config;

    StationState stations[MAX_STATIONS];
    EventQueue   eq;
    RNG          rng;
    NormalState   ns;

    double       clock;
    int          next_customer_id;

    /* Accumulators (post-warmup only) */
    double buffer_area[MAX_STATIONS];
    double busy_area[MAX_STATIONS];
    double last_acc_time;

    long   departures;
    long   arrivals_total;
    long   arrivals_lost;
    double sojourn_sum;
    long   sojourn_count;
    int    past_warmup;

    long   station_completions[MAX_STATIONS];
    long   station_losses[MAX_STATIONS];

    /* Per-class area tracking */
    int    class_buffer_count[MAX_CLASSES][MAX_STATIONS];
    int    class_server_count[MAX_CLASSES][MAX_STATIONS];
    double class_queue_area[MAX_CLASSES][MAX_STATIONS];

    /* Outside queue for manufacturing blocking (BAS mode), one per class:
     * External arrivals that find their class's entry station full wait
     * outside and enter when space opens at that station. Per-class FIFO,
     * independent across classes. Only used in non-loss mode. */
    WaitQueue outside[MAX_CLASSES];
} SimState;

/* ================================================================== */
/* Helpers                                                            */
/* ================================================================== */

static int can_accept(const SimState *sim, int j)
{
    const StationState *st = &sim->stations[j];
    int idle = st->num_servers - st->servers_busy - st->servers_blocked;
    if (idle > 0)
        return 1;
    return st->buffer_count < st->buffer_capacity;
}

static int has_idle_server(const SimState *sim, int j)
{
    const StationState *st = &sim->stations[j];
    return (st->num_servers - st->servers_busy - st->servers_blocked) > 0;
}

/* Detect total BAS deadlock: no server is currently performing service
 * (so no future service-complete event can fire) AND at least one server
 * is BAS-blocked. Future arrivals can only fill outside queues or be
 * lost; without a service completion, no blocked server will ever
 * unblock, so the simulator is permanently stuck.
 *
 * This catches the classic Kumar-Seidman finite-buffer reentrant
 * pathology — both stations end up holding each other's outbound
 * customers with their buffers full. Without this check the simulator
 * silently sits at avg = (B + 1) and throughput = 0 for the entire
 * remaining sim_time, which is easy to misread as "saturated under
 * heavy load" when it's actually frozen. */
static int is_deadlocked(const SimState *sim)
{
    int total_busy = 0, total_blocked = 0;
    for (int i = 0; i < sim->net->d; i++) {
        total_busy    += sim->stations[i].servers_busy;
        total_blocked += sim->stations[i].servers_blocked;
    }
    return (total_busy == 0 && total_blocked > 0);
}

static void update_areas(SimState *sim, double new_time)
{
    if (!sim->past_warmup) {
        if (new_time >= sim->config->warmup_time) {
            sim->past_warmup  = 1;
            sim->last_acc_time = sim->config->warmup_time;
            sim->departures    = 0;
            sim->arrivals_total = 0;
            sim->arrivals_lost = 0;
            sim->sojourn_sum   = 0.0;
            sim->sojourn_count = 0;
            memset(sim->buffer_area, 0, sizeof(sim->buffer_area));
            memset(sim->busy_area,   0, sizeof(sim->busy_area));
            memset(sim->station_completions, 0, sizeof(sim->station_completions));
            memset(sim->station_losses, 0, sizeof(sim->station_losses));
            memset(sim->class_queue_area, 0, sizeof(sim->class_queue_area));
        } else {
            return;
        }
    }

    double dt = new_time - sim->last_acc_time;
    if (dt <= 0.0)
        return;

    for (int i = 0; i < sim->net->d; i++) {
        sim->buffer_area[i] += sim->stations[i].buffer_count * dt;
        sim->busy_area[i]   += (sim->stations[i].servers_busy +
                                sim->stations[i].servers_blocked) * dt;
    }

    for (int k = 0; k < sim->net->K; k++) {
        for (int i = 0; i < sim->net->d; i++) {
            sim->class_queue_area[k][i] +=
                (sim->class_buffer_count[k][i] +
                 sim->class_server_count[k][i]) * dt;
        }
    }

    sim->last_acc_time = new_time;
}

static int route_customer(SimState *sim, int from, int cls)
{
    double u = rng_next_double(&sim->rng);
    double cum = 0.0;
    for (int j = 0; j < sim->net->d; j++) {
        cum += sim->net->routing[cls][from][j];
        if (u < cum)
            return j;
    }
    return -1;
}

static void schedule_arrival(SimState *sim, int cls)
{
    double iat = dist_sample(&sim->net->arrival_dist[cls], &sim->rng, &sim->ns);
    Event e;
    e.time           = sim->clock + iat;
    e.type           = EVENT_ARRIVAL;
    /* Per-class entry station from network (parser defaults this to 0
     * when the optional "# arrival_stations" section is absent, so old
     * input files keep working). */
    e.station        = sim->net->arrival_station[cls];
    e.customer_id    = sim->next_customer_id++;
    e.customer_class = cls;
    e.entry_time     = e.time;
    eq_push(&sim->eq, e);
}

static void begin_service(SimState *sim, int i, int cid, int cls, double et)
{
    sim->stations[i].servers_busy++;
    sim->class_server_count[cls][i]++;

    double stime = dist_sample(&sim->net->service_dist[i][cls],
                               &sim->rng, &sim->ns);
    Event se;
    se.time           = sim->clock + stime;
    se.type           = EVENT_SERVICE_COMPLETE;
    se.station        = i;
    se.customer_id    = cid;
    se.customer_class = cls;
    se.entry_time     = et;
    eq_push(&sim->eq, se);
}

/* Forward declaration — start_next_service and try_unblock are mutually
 * recursive (try_unblock may free a server which calls start_next_service
 * which may complete and call try_unblock on a different station). */
static void try_unblock(SimState *sim, int i);

static void start_next_service(SimState *sim, int i)
{
    StationState *st = &sim->stations[i];
    int idle = st->num_servers - st->servers_busy - st->servers_blocked;

    while (idle > 0 && st->queue.count > 0) {
        int cid, cls;
        double et;
        wq_pop(&st->queue, &cid, &cls, &et);
        st->buffer_count--;
        sim->class_buffer_count[cls][i]--;

        begin_service(sim, i, cid, cls, et);
        idle--;
    }
}

/* When a slot frees up at station i (either buffer or server),
 * check if any station blocked on i can now transfer its customer. */
static void try_unblock(SimState *sim, int i)
{
    BlockedQueue *bq = &sim->stations[i].blocked_on_me;

    while (bq->count > 0 && can_accept(sim, i)) {
        int k = bq_pop(bq);  /* source station that was blocked */
        StationState *src = &sim->stations[k];

        /* Find the blocked entry at station k that was waiting for station i */
        BlockedInfo bi;
        if (!blk_remove_by_dest(src, i, &bi))
            continue;  /* shouldn't happen */

        /* Unblock the server at station k */
        src->servers_blocked--;
        sim->class_server_count[bi.cust_class][k]--;

        /* Transfer customer to station i */
        if (has_idle_server(sim, i)) {
            begin_service(sim, i, bi.cust_id, bi.cust_class, bi.entry_time);
        } else {
            sim->stations[i].buffer_count++;
            sim->class_buffer_count[bi.cust_class][i]++;
            wq_push(&sim->stations[i].queue,
                    bi.cust_id, bi.cust_class, bi.entry_time);
        }

        /* The freed server at station k can now serve a queued customer */
        start_next_service(sim, k);

        /* Freeing a server at k may unblock someone waiting for k */
        try_unblock(sim, k);
    }
}

/* When space opens anywhere, drain each class's outside FIFO into its
 * own entry station while there is room. Per-class independence: a
 * class whose entry station is still full does not block other classes
 * whose entry stations have space. */
static void try_admit_outside(SimState *sim)
{
    int K = sim->net->K;
    for (int cls = 0; cls < K; cls++) {
        WaitQueue *oq = &sim->outside[cls];
        int entry = sim->net->arrival_station[cls];
        while (oq->count > 0 && can_accept(sim, entry)) {
            int cid, c2;
            double et;
            wq_pop(oq, &cid, &c2, &et);

            if (has_idle_server(sim, entry)) {
                begin_service(sim, entry, cid, c2, et);
            } else {
                sim->stations[entry].buffer_count++;
                sim->class_buffer_count[c2][entry]++;
                wq_push(&sim->stations[entry].queue, cid, c2, et);
            }
        }
    }
}

/* ================================================================== */
/* Event handlers                                                     */
/* ================================================================== */

static void handle_arrival(SimState *sim, const Event *e)
{
    int cls   = e->customer_class;
    int entry = e->station;          /* per-class entry station, set in schedule_arrival */

    if (sim->past_warmup)
        sim->arrivals_total++;

    schedule_arrival(sim, cls);

    if (can_accept(sim, entry)) {
        if (has_idle_server(sim, entry)) {
            begin_service(sim, entry, e->customer_id, cls, e->entry_time);
        } else {
            StationState *st = &sim->stations[entry];
            st->buffer_count++;
            sim->class_buffer_count[cls][entry]++;
            wq_push(&st->queue, e->customer_id, cls, e->entry_time);
        }
    } else if (sim->config->loss_mode || sim->config->external_loss) {
        /* Loss mode or external-loss hybrid: discard external arrival */
        if (sim->past_warmup) {
            sim->arrivals_lost++;
            sim->station_losses[entry]++;
        }
    } else {
        /* Manufacturing blocking: hold customer in this class's
         * outside queue. Each class drains independently when its
         * own entry station has room. */
        wq_push(&sim->outside[cls], e->customer_id, cls, e->entry_time);
    }
}

static void handle_service_complete(SimState *sim, const Event *e)
{
    int i   = e->station;
    int cls = e->customer_class;

    /* Server finishes */
    sim->stations[i].servers_busy--;
    sim->class_server_count[cls][i]--;

    if (sim->past_warmup)
        sim->station_completions[i]++;

    int dest = route_customer(sim, i, cls);

    if (dest < 0) {
        /* Customer exits. */
        if (sim->past_warmup) {
            sim->departures++;
            if (e->entry_time >= sim->config->warmup_time) {
                sim->sojourn_sum += sim->clock - e->entry_time;
                sim->sojourn_count++;
            }
        }
        start_next_service(sim, i);
        try_unblock(sim, i);

    } else if (dest == i) {
        /* Self-loop */
        begin_service(sim, i, e->customer_id, cls, e->entry_time);

    } else if (can_accept(sim, dest)) {
        /* Transfer succeeds */
        if (has_idle_server(sim, dest)) {
            begin_service(sim, dest, e->customer_id, cls, e->entry_time);
        } else {
            sim->stations[dest].buffer_count++;
            sim->class_buffer_count[cls][dest]++;
            wq_push(&sim->stations[dest].queue,
                    e->customer_id, cls, e->entry_time);
        }
        start_next_service(sim, i);
        try_unblock(sim, i);

    } else if (sim->config->loss_mode) {
        /* Loss mode: discard */
        if (sim->past_warmup)
            sim->station_losses[dest]++;
        start_next_service(sim, i);
        try_unblock(sim, i);

    } else {
        /* BAS blocking */
        StationState *st = &sim->stations[i];
        st->servers_blocked++;
        sim->class_server_count[cls][i]++;  /* customer still occupies server */

        blk_add(st, dest, e->customer_id, cls, e->entry_time);
        bq_push(&sim->stations[dest].blocked_on_me, i);
    }
}

/* ================================================================== */
/* Single replication                                                 */
/* ================================================================== */

static void run_one(const Network *net, const SimConfig *config,
                    uint64_t seed, int antithetic, RunResult *result)
{
    SimState sim;
    memset(&sim, 0, sizeof(sim));
    sim.net    = net;
    sim.config = config;

    rng_seed(&sim.rng, seed);
    sim.rng.antithetic = antithetic;
    sim.ns.has_spare = 0;

    eq_init(&sim.eq, 1024);

    for (int i = 0; i < net->d; i++) {
        sim.stations[i].num_servers      = net->servers[i];
        sim.stations[i].servers_busy     = 0;
        sim.stations[i].servers_blocked  = 0;
        sim.stations[i].buffer_count     = 0;
        sim.stations[i].buffer_capacity  = net->buffer_size[i];
        sim.stations[i].blk_count        = 0;
        wq_init(&sim.stations[i].queue, net->buffer_size[i]);
        bq_init(&sim.stations[i].blocked_on_me);
    }

    /* Per-class outside queues — only the classes the network actually
     * declares (net->K) are initialized; the rest stay zero/unused. */
    for (int k = 0; k < net->K; k++)
        wq_init(&sim.outside[k], 4096);

    sim.clock            = 0.0;
    sim.next_customer_id = 0;
    sim.past_warmup      = (config->warmup_time <= 0.0);
    sim.last_acc_time    = 0.0;

    int deadlocked = 0;
    double deadlock_time = 0.0;

    /* Schedule first arrival for each class */
    for (int k = 0; k < net->K; k++)
        schedule_arrival(&sim, k);

    /* ── Main event loop ─────────────────────────────────────── */
    while (!eq_is_empty(&sim.eq)) {
        Event e = eq_pop(&sim.eq);
        if (e.time > config->sim_time)
            break;

        update_areas(&sim, e.time);
        sim.clock = e.time;

        switch (e.type) {
        case EVENT_ARRIVAL:
            handle_arrival(&sim, &e);
            break;
        case EVENT_SERVICE_COMPLETE:
            handle_service_complete(&sim, &e);
            break;
        case EVENT_UNBLOCK:
            /* Unblocking is now handled inline in try_unblock.
             * This case should not occur. */
            break;
        }

        /* After any event, drain whichever class outside queues now have
         * room at their entry station (manufacturing blocking for
         * external arrivals). Cheap to call even when all queues are
         * empty, and avoids the bookkeeping of tracking which classes
         * have outside customers. */
        if (!config->loss_mode)
            try_admit_outside(&sim);

        /* Catch BAS deadlock: nothing is being serviced AND something
         * is blocked → no future service completion will ever fire, so
         * the network is frozen. Once detected, the per-station
         * buffer/server counts cannot change for the rest of the run
         * (only outside-queue admits can happen, and those never
         * unblock anyone). So we jump-forward the time integrals to
         * sim_time using the current frozen state and then bail out
         * of the event loop — that gives the user the same time-
         * average they'd see if we kept simulating, but in O(1)
         * instead of waiting for sim_time to elapse one arrival at
         * a time. The deadlocked flag still surfaces in the warning. */
        if (!config->loss_mode && is_deadlocked(&sim)) {
            deadlocked = 1;
            deadlock_time = sim.clock;
            update_areas(&sim, config->sim_time);
            break;
        }
    }

    if (!deadlocked)
        update_areas(&sim, config->sim_time);

    /* ── Compute per-replication results ──────────────────────── */
    /* obs_time spans warmup→sim_time regardless of whether we hit
     * deadlock — when deadlocked, the integrals were jumped forward to
     * sim_time with the frozen state in the loop above, so the time-
     * average correctly reflects "system stuck at saturated state".
     * The deadlocked flag is what tells the caller this is a stuck
     * state, not a steady-state estimate. */
    double obs_time = config->sim_time - config->warmup_time;
    if (obs_time <= 0.0) obs_time = 1.0;

    result->deadlocked    = deadlocked;
    result->deadlock_time = deadlock_time;
    result->K          = net->K;
    result->throughput  = (double)sim.departures / obs_time;
    result->loss_rate   = (sim.arrivals_total > 0)
        ? (double)sim.arrivals_lost / (double)sim.arrivals_total
        : 0.0;
    result->avg_sojourn = (sim.sojourn_count > 0)
        ? sim.sojourn_sum / (double)sim.sojourn_count
        : 0.0;

    for (int i = 0; i < net->d; i++) {
        result->avg_buffer[i]  = sim.buffer_area[i] / obs_time;
        result->utilization[i] = sim.busy_area[i]   / obs_time;
        result->station_throughput[i] = (double)sim.station_completions[i] / obs_time;
        result->station_loss_rate[i]  = (double)sim.station_losses[i] / obs_time;
    }

    for (int k = 0; k < net->K; k++) {
        for (int i = 0; i < net->d; i++) {
            result->class_queue[k][i] = sim.class_queue_area[k][i] / obs_time;
        }
    }

    eq_free(&sim.eq);
    for (int i = 0; i < net->d; i++)
        wq_free(&sim.stations[i].queue);
    for (int k = 0; k < net->K; k++)
        wq_free(&sim.outside[k]);
}

/* ================================================================== */
/* Wall-clock timer                                                   */
/* ================================================================== */

static double wall_time(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec * 1e-6;
}

/* ================================================================== */
/* GCD support (Apple only)                                           */
/* ================================================================== */

/* Average a pair of RunResults into dst. */
static void average_results(const RunResult *a, const RunResult *b,
                            RunResult *dst, int d, int K)
{
    dst->throughput = 0.5 * (a->throughput + b->throughput);
    dst->loss_rate  = 0.5 * (a->loss_rate  + b->loss_rate);
    dst->avg_sojourn = 0.5 * (a->avg_sojourn + b->avg_sojourn);
    dst->K = K;

    for (int i = 0; i < d; i++) {
        dst->avg_buffer[i]  = 0.5 * (a->avg_buffer[i]  + b->avg_buffer[i]);
        dst->utilization[i] = 0.5 * (a->utilization[i] + b->utilization[i]);
        dst->station_throughput[i] = 0.5 * (a->station_throughput[i] + b->station_throughput[i]);
        dst->station_loss_rate[i]  = 0.5 * (a->station_loss_rate[i]  + b->station_loss_rate[i]);
    }

    for (int k = 0; k < K; k++)
        for (int i = 0; i < d; i++)
            dst->class_queue[k][i] = 0.5 * (a->class_queue[k][i] + b->class_queue[k][i]);

    /* Deadlock is not averaged — if either replication of an antithetic
     * pair deadlocked, the pair is flagged. The reported deadlock_time
     * is the earlier of the two so the warning surfaces the worst case. */
    dst->deadlocked = a->deadlocked || b->deadlocked;
    if (a->deadlocked && b->deadlocked)
        dst->deadlock_time = (a->deadlock_time < b->deadlock_time)
            ? a->deadlock_time : b->deadlock_time;
    else if (a->deadlocked)
        dst->deadlock_time = a->deadlock_time;
    else if (b->deadlocked)
        dst->deadlock_time = b->deadlock_time;
    else
        dst->deadlock_time = 0.0;
}

#ifdef __APPLE__

typedef struct {
    const Network   *net;
    const SimConfig *config;
    RunResult       *results;
} GCDContext;

static void gcd_run_one(void *ctx_ptr, size_t r)
{
    GCDContext *ctx = (GCDContext *)ctx_ptr;
    uint64_t seed = ctx->config->base_seed + (uint64_t)(r / 2);
    int anti = (r % 2 == 1);
    run_one(ctx->net, ctx->config, seed, anti, &ctx->results[r]);
    progress_tick();
}

#endif /* __APPLE__ */

/* ================================================================== */
/* Public interface                                                   */
/* ================================================================== */

double sim_run_all(const Network *net, const SimConfig *config,
                   RunResult *results, int *effective_runs)
{
    double t0 = wall_time();

    /* Ensure even number of runs for antithetic pairing */
    int num_runs = config->num_runs;
    if (num_runs % 2 != 0) num_runs++;

    /* Allocate raw (unpaired) results */
    RunResult *raw = (RunResult *)calloc((size_t)num_runs, sizeof(RunResult));
    if (!raw) {
        fprintf(stderr, "Error: out of memory for raw results\n");
        *effective_runs = 0;
        return 0.0;
    }

    progress_open(config->progress_file, num_runs);

    switch (config->parallel) {

    case PARALLEL_NONE:
        for (int r = 0; r < num_runs; r++) {
            uint64_t seed = config->base_seed + (uint64_t)(r / 2);
            int anti = (r % 2 == 1);
            run_one(net, config, seed, anti, &raw[r]);
            progress_tick();
            if (config->verbose) {
                printf("  Run %2d/%d%s: throughput=%.4f  loss=%.4f  sojourn=%.4f",
                       r + 1, num_runs,
                       anti ? " (anti)" : "       ",
                       raw[r].throughput,
                       raw[r].loss_rate,
                       raw[r].avg_sojourn);
                for (int i = 0; i < net->d; i++)
                    printf("  u%d=%.4f", i + 1, raw[r].utilization[i]);
                printf("\n");
            }
        }
        break;

    case PARALLEL_OPENMP:
#ifdef _OPENMP
        if (!config->compact && !config->gui_mode)
            printf("  [OpenMP] Using %d threads\n", omp_get_max_threads());

        #pragma omp parallel for schedule(dynamic)
        for (int r = 0; r < num_runs; r++) {
            uint64_t seed = config->base_seed + (uint64_t)(r / 2);
            int anti = (r % 2 == 1);
            run_one(net, config, seed, anti, &raw[r]);
            progress_tick();
        }

        if (config->verbose) {
            for (int r = 0; r < num_runs; r++) {
                printf("  Run %2d/%d%s: throughput=%.4f  loss=%.4f  sojourn=%.4f",
                       r + 1, num_runs,
                       (r % 2 == 1) ? " (anti)" : "       ",
                       raw[r].throughput,
                       raw[r].loss_rate,
                       raw[r].avg_sojourn);
                for (int i = 0; i < net->d; i++)
                    printf("  u%d=%.4f", i + 1, raw[r].utilization[i]);
                printf("\n");
            }
        }
#else
        fprintf(stderr, "Error: not compiled with OpenMP support.\n");
        fprintf(stderr, "  Recompile with: make clean && make OPENMP=1\n");
        exit(1);
#endif
        break;

    case PARALLEL_GCD:
#ifdef __APPLE__
        if (!config->compact && !config->gui_mode)
            printf("  [GCD] Dispatching %d replications across system thread pool\n",
                   num_runs);
        {
            GCDContext ctx;
            ctx.net     = net;
            ctx.config  = config;
            ctx.results = raw;

            dispatch_apply_f((size_t)num_runs,
                             dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
                             &ctx,
                             gcd_run_one);
        }

        if (config->verbose) {
            for (int r = 0; r < num_runs; r++) {
                printf("  Run %2d/%d%s: throughput=%.4f  loss=%.4f  sojourn=%.4f",
                       r + 1, num_runs,
                       (r % 2 == 1) ? " (anti)" : "       ",
                       raw[r].throughput,
                       raw[r].loss_rate,
                       raw[r].avg_sojourn);
                for (int i = 0; i < net->d; i++)
                    printf("  u%d=%.4f", i + 1, raw[r].utilization[i]);
                printf("\n");
            }
        }
#else
        fprintf(stderr, "Error: GCD is only available on Apple platforms.\n");
        exit(1);
#endif
        break;
    }

    progress_close();

    /* Average antithetic pairs into results[] */
    int n_pairs = num_runs / 2;
    for (int p = 0; p < n_pairs; p++) {
        average_results(&raw[2*p], &raw[2*p + 1], &results[p], net->d, net->K);
    }
    *effective_runs = n_pairs;

    free(raw);

    double t1 = wall_time();
    return t1 - t0;
}
