/*
 * jackson_sim_finite.c - Discrete Event Simulation of Multi-Class Jackson Networks
 *                        with Finite Buffers, Blocking, and Starvation
 *
 * This program simulates a generalized multi-class Jackson network with
 * finite buffers and various blocking protocols.
 *
 * Blocking Protocols Supported:
 *   BAS (Blocking After Service)  - Server blocks after service if downstream full
 *   BBS (Blocking Before Service) - Cannot start service if downstream full
 *   RS  (Rejection/Loss)          - Customers rejected when buffer full
 *
 * Compile: gcc -o jackson_sim_finite jackson_sim_finite.c -lm
 * Usage:   ./jackson_sim_finite input_file [options]
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <float.h>

#ifdef _OPENMP
#include <omp.h>
#endif

#define QNET_RNG_IMPLEMENTATION
#include "../../common/rng.h"

/* ============================================================================
 * CONSTANTS AND CONFIGURATION
 * ============================================================================ */

#define MAX_STATIONS     100
#define MAX_CLASSES      100
#define MAX_LINE_LEN     1024
#define INITIAL_HEAP_CAP 10000
#define INFINITE_BUFFER  -1

/* Distribution types */
typedef enum {
    DIST_NONE = 0,
    DIST_EXPONENTIAL,
    DIST_ERLANG,
    DIST_GAMMA,
    DIST_UNIFORM,
    DIST_DETERMINISTIC,
    DIST_HYPEREXP2,
    DIST_LOGNORMAL,
    DIST_WEIBULL,
    DIST_PARETO
} DistType;

/* Blocking protocols */
typedef enum {
    BLOCKING_BAS = 0,    /* Blocking After Service (manufacturing) */
    BLOCKING_BBS,        /* Blocking Before Service (communication) */
    BLOCKING_RS          /* Rejection/Loss (call center) */
} BlockingProtocol;

/* Event types */
typedef enum {
    EVENT_ARRIVAL = 0,
    EVENT_DEPARTURE,
    EVENT_UNBLOCK        /* Server unblocked, can now move customer */
} EventType;

/* Server states */
typedef enum {
    SERVER_IDLE = 0,
    SERVER_BUSY,
    SERVER_BLOCKED       /* Finished service, waiting for downstream space */
} ServerState;

/* ============================================================================
 * DATA STRUCTURES
 * ============================================================================ */

/* Distribution specification */
typedef struct {
    DistType type;
    double param1;
    double param2;
    double param3;
} Distribution;

/* Customer in the system */
typedef struct Customer {
    int id;
    int class_id;
    int original_class;          /* Class when entered system */
    double arrival_time;         /* Time entered system */
    double queue_entry_time;     /* Time entered current queue */
    struct Customer *next;
} Customer;

/* Station queue */
typedef struct {
    Customer *head;
    Customer *tail;
    int length;
} Queue;

/* Blocked server info (for tracking which servers are blocked waiting) */
typedef struct BlockedServer {
    int station_id;
    Customer *customer;          /* Customer waiting to move */
    int target_class;            /* Class customer will become */
    double block_start_time;
    struct BlockedServer *next;
} BlockedServer;

/* List of blocked servers waiting for a station */
typedef struct {
    BlockedServer *head;
    BlockedServer *tail;
    int count;
} BlockedList;

/* Station in the network */
typedef struct {
    int id;
    Queue queue;
    ServerState state;
    Customer *in_service;
    double service_start_time;
    int buffer_capacity;         /* -1 for infinite */
    BlockedList blocked_waiting; /* Servers blocked waiting for this station */

    /* For BBS: track if we're waiting for downstream */
    int waiting_for_downstream;
    int downstream_station;
} Station;

/* Event in the event list */
typedef struct {
    EventType type;
    double time;
    int class_id;
    int station_id;
    Customer *customer;
    int target_class;            /* For unblock events */
} Event;

/* Event heap (priority queue) */
typedef struct {
    Event *events;
    int size;
    int capacity;
} EventHeap;

/* Class definition */
typedef struct {
    int id;
    Distribution arrival_dist;
    int arrival_station;
    double routing[MAX_CLASSES];
    Distribution service_dist;
    int constituency_station;
} Class;

/* Network configuration */
typedef struct {
    int num_stations;
    int num_classes;
    Station stations[MAX_STATIONS];
    Class classes[MAX_CLASSES];
    BlockingProtocol blocking_protocol;
    int default_buffer_capacity;
} Network;

/* Statistics for a single run */
typedef struct {
    /* Per class statistics */
    double total_queue_time[MAX_CLASSES];
    double total_sojourn_time[MAX_CLASSES];
    int customers_served[MAX_CLASSES];
    int customers_completed[MAX_CLASSES];
    int customers_arrived[MAX_CLASSES];
    int customers_rejected[MAX_CLASSES];     /* For RS protocol */

    /* Per station statistics */
    double total_queue_time_station[MAX_STATIONS];
    int customers_at_station[MAX_STATIONS];
    double busy_time[MAX_STATIONS];
    double blocked_time[MAX_STATIONS];       /* Time spent blocked */
    double starved_time[MAX_STATIONS];       /* Time spent starved (idle with empty queue) */
    int blocking_events[MAX_STATIONS];       /* Number of blocking events */

    /* Per class-station statistics */
    double queue_time_class_station[MAX_CLASSES][MAX_STATIONS];
    int count_class_station[MAX_CLASSES][MAX_STATIONS];

    /* System-wide */
    int total_customers_in_system;
    double total_time_all_blocked;           /* Any server blocked */
} RunStats;

/* Simulation parameters */
typedef struct {
    double warmup_time;
    double run_length;
    int num_replications;
    unsigned long seed;
    char output_mcn_file[256];
    int verbose;
} SimParams;

/* Aggregate statistics across runs */
typedef struct {
    double mean_queue_time[MAX_CLASSES];
    double var_queue_time[MAX_CLASSES];
    double mean_sojourn_time[MAX_CLASSES];
    double var_sojourn_time[MAX_CLASSES];
    double mean_throughput[MAX_CLASSES];
    double var_throughput[MAX_CLASSES];
    double mean_rejection_rate[MAX_CLASSES];
    double var_rejection_rate[MAX_CLASSES];

    double mean_queue_time_station[MAX_STATIONS];
    double var_queue_time_station[MAX_STATIONS];
    double mean_utilization[MAX_STATIONS];
    double var_utilization[MAX_STATIONS];
    double mean_blocking_prob[MAX_STATIONS];
    double var_blocking_prob[MAX_STATIONS];
    double mean_starvation_prob[MAX_STATIONS];
    double var_starvation_prob[MAX_STATIONS];

    double mean_queue_time_cs[MAX_CLASSES][MAX_STATIONS];
    double var_queue_time_cs[MAX_CLASSES][MAX_STATIONS];
} AggregateStats;

/* ============================================================================
 * GLOBAL VARIABLES
 * ============================================================================ */

static Network network;
static SimParams sim_params;
static EventHeap event_heap;
static double current_time;
static int next_customer_id;
static int warmup_complete;
static double last_state_change_time;  /* For time-weighted statistics */

/* Random number generator state (xoshiro256** — see common/rng.h) */
static RNG rng_state;

/* OpenMP: replicate per-thread network / event-heap / RNG state. See
 * jackson_sim.c for the detailed rationale. `sim_params` stays shared. */
#ifdef _OPENMP
#pragma omp threadprivate(network, event_heap, current_time, next_customer_id, warmup_complete, last_state_change_time, rng_state)
#endif

/* ============================================================================
 * RANDOM NUMBER GENERATION (same as before)
 * ============================================================================ */

void rng_init(unsigned long seed) {
    rng_seed(&rng_state, (uint64_t)seed);
}

double rng_uniform(void) {
    return rng_next_double(&rng_state);
}

double rng_uniform_range(double a, double b) {
    return a + (b - a) * rng_uniform();
}

double rng_exponential(double lambda) {
    double u;
    do { u = rng_uniform(); } while (u == 0.0);
    return -log(u) / lambda;
}

double rng_erlang(int k, double lambda) {
    double sum = 0.0;
    int i;
    for (i = 0; i < k; i++) sum += rng_exponential(lambda);
    return sum;
}

double rng_gamma(double shape, double scale) {
    double d, c, x, v, u;
    if (shape < 1.0) {
        return rng_gamma(1.0 + shape, scale) * pow(rng_uniform(), 1.0 / shape);
    }
    d = shape - 1.0/3.0;
    c = 1.0 / sqrt(9.0 * d);
    while (1) {
        do {
            double u1 = rng_uniform();
            double u2 = rng_uniform();
            x = sqrt(-2.0 * log(u1)) * cos(2.0 * M_PI * u2);
            v = 1.0 + c * x;
        } while (v <= 0.0);
        v = v * v * v;
        u = rng_uniform();
        if (u < 1.0 - 0.0331 * (x * x) * (x * x)) return d * v * scale;
        if (log(u) < 0.5 * x * x + d * (1.0 - v + log(v))) return d * v * scale;
    }
}

double rng_lognormal(double mu, double sigma) {
    double u1 = rng_uniform();
    double u2 = rng_uniform();
    double z = sqrt(-2.0 * log(u1)) * cos(2.0 * M_PI * u2);
    return exp(mu + sigma * z);
}

double rng_weibull(double shape, double scale) {
    double u;
    do { u = rng_uniform(); } while (u == 0.0);
    return scale * pow(-log(u), 1.0 / shape);
}

double rng_pareto(double shape, double scale) {
    double u;
    do { u = rng_uniform(); } while (u == 0.0);
    return scale / pow(u, 1.0 / shape);
}

double rng_hyperexp2(double p, double lambda1, double lambda2) {
    if (rng_uniform() < p) return rng_exponential(lambda1);
    else return rng_exponential(lambda2);
}

double generate_from_dist(Distribution *dist) {
    switch (dist->type) {
        case DIST_NONE: return -1.0;
        case DIST_EXPONENTIAL: return rng_exponential(dist->param1);
        case DIST_ERLANG: return rng_erlang((int)dist->param1, dist->param2);
        case DIST_GAMMA: return rng_gamma(dist->param1, dist->param2);
        case DIST_UNIFORM: return rng_uniform_range(dist->param1, dist->param2);
        case DIST_DETERMINISTIC: return dist->param1;
        case DIST_HYPEREXP2: return rng_hyperexp2(dist->param1, dist->param2, dist->param3);
        case DIST_LOGNORMAL: return rng_lognormal(dist->param1, dist->param2);
        case DIST_WEIBULL: return rng_weibull(dist->param1, dist->param2);
        case DIST_PARETO: return rng_pareto(dist->param1, dist->param2);
        default: return 1.0;
    }
}

double dist_mean(Distribution *dist) {
    switch (dist->type) {
        case DIST_NONE: return 0.0;
        case DIST_EXPONENTIAL: return 1.0 / dist->param1;
        case DIST_ERLANG: return dist->param1 / dist->param2;
        case DIST_GAMMA: return dist->param1 * dist->param2;
        case DIST_UNIFORM: return (dist->param1 + dist->param2) / 2.0;
        case DIST_DETERMINISTIC: return dist->param1;
        case DIST_HYPEREXP2: {
            double p = dist->param1;
            return p / dist->param2 + (1.0 - p) / dist->param3;
        }
        case DIST_LOGNORMAL: return exp(dist->param1 + dist->param2 * dist->param2 / 2.0);
        case DIST_WEIBULL: return dist->param2 * tgamma(1.0 + 1.0 / dist->param1);
        case DIST_PARETO:
            if (dist->param1 > 1.0) return dist->param1 * dist->param2 / (dist->param1 - 1.0);
            return INFINITY;
        default: return 1.0;
    }
}

double dist_scv(Distribution *dist) {
    double mean, var;
    switch (dist->type) {
        case DIST_NONE: return 0.0;
        case DIST_EXPONENTIAL: return 1.0;
        case DIST_ERLANG: return 1.0 / dist->param1;
        case DIST_GAMMA: return 1.0 / dist->param1;
        case DIST_UNIFORM:
            mean = (dist->param1 + dist->param2) / 2.0;
            var = (dist->param2 - dist->param1) * (dist->param2 - dist->param1) / 12.0;
            return var / (mean * mean);
        case DIST_DETERMINISTIC: return 0.0;
        case DIST_HYPEREXP2: {
            double p = dist->param1;
            double l1 = dist->param2;
            double l2 = dist->param3;
            double m1 = 1.0/l1, m2 = 1.0/l2;
            double e2;
            mean = p*m1 + (1.0-p)*m2;
            e2 = 2.0*(p/(l1*l1) + (1.0-p)/(l2*l2));
            var = e2 - mean*mean;
            return var / (mean * mean);
        }
        case DIST_LOGNORMAL: {
            double sigma2 = dist->param2 * dist->param2;
            return exp(sigma2) - 1.0;
        }
        case DIST_WEIBULL: {
            double k = dist->param1;
            double g1 = tgamma(1.0 + 1.0/k);
            double g2 = tgamma(1.0 + 2.0/k);
            return g2/(g1*g1) - 1.0;
        }
        case DIST_PARETO:
            if (dist->param1 > 2.0) {
                double a = dist->param1;
                return 1.0 / (a * (a - 2.0) / ((a - 1.0) * (a - 1.0)));
            }
            return INFINITY;
        default: return 1.0;
    }
}

/* ============================================================================
 * EVENT HEAP OPERATIONS
 * ============================================================================ */

void heap_init(EventHeap *h) {
    h->capacity = INITIAL_HEAP_CAP;
    h->size = 0;
    h->events = (Event *)malloc(h->capacity * sizeof(Event));
    if (!h->events) {
        fprintf(stderr, "Error: Failed to allocate event heap\n");
        exit(1);
    }
}

void heap_free(EventHeap *h) {
    free(h->events);
    h->events = NULL;
    h->size = 0;
    h->capacity = 0;
}

void heap_push(EventHeap *h, Event e) {
    int i, parent;
    if (h->size >= h->capacity) {
        h->capacity *= 2;
        h->events = (Event *)realloc(h->events, h->capacity * sizeof(Event));
        if (!h->events) {
            fprintf(stderr, "Error: Failed to expand event heap\n");
            exit(1);
        }
    }
    i = h->size++;
    while (i > 0) {
        parent = (i - 1) / 2;
        if (h->events[parent].time <= e.time) break;
        h->events[i] = h->events[parent];
        i = parent;
    }
    h->events[i] = e;
}

Event heap_pop(EventHeap *h) {
    Event result, last;
    int i, child;
    if (h->size == 0) {
        fprintf(stderr, "Error: Attempted to pop from empty heap\n");
        exit(1);
    }
    result = h->events[0];
    last = h->events[--h->size];
    if (h->size > 0) {
        i = 0;
        while ((child = 2*i + 1) < h->size) {
            if (child + 1 < h->size && h->events[child + 1].time < h->events[child].time)
                child++;
            if (last.time <= h->events[child].time) break;
            h->events[i] = h->events[child];
            i = child;
        }
        h->events[i] = last;
    }
    return result;
}

int heap_empty(EventHeap *h) {
    return h->size == 0;
}

/* ============================================================================
 * QUEUE AND BLOCKED LIST OPERATIONS
 * ============================================================================ */

void queue_init(Queue *q) {
    q->head = q->tail = NULL;
    q->length = 0;
}

void queue_enqueue(Queue *q, Customer *c) {
    c->next = NULL;
    if (q->tail) q->tail->next = c;
    else q->head = c;
    q->tail = c;
    q->length++;
}

Customer *queue_dequeue(Queue *q) {
    Customer *c;
    if (!q->head) return NULL;
    c = q->head;
    q->head = c->next;
    if (!q->head) q->tail = NULL;
    q->length--;
    c->next = NULL;
    return c;
}

int queue_is_empty(Queue *q) {
    return q->head == NULL;
}

void queue_clear(Queue *q) {
    Customer *c;
    while ((c = queue_dequeue(q)) != NULL) free(c);
}

void blocked_list_init(BlockedList *bl) {
    bl->head = bl->tail = NULL;
    bl->count = 0;
}

void blocked_list_add(BlockedList *bl, int station_id, Customer *c, int target_class) {
    BlockedServer *bs = (BlockedServer *)malloc(sizeof(BlockedServer));
    if (!bs) {
        fprintf(stderr, "Error: Failed to allocate blocked server\n");
        exit(1);
    }
    bs->station_id = station_id;
    bs->customer = c;
    bs->target_class = target_class;
    bs->block_start_time = current_time;
    bs->next = NULL;

    if (bl->tail) bl->tail->next = bs;
    else bl->head = bs;
    bl->tail = bs;
    bl->count++;
}

BlockedServer *blocked_list_remove_first(BlockedList *bl) {
    BlockedServer *bs;
    if (!bl->head) return NULL;
    bs = bl->head;
    bl->head = bs->next;
    if (!bl->head) bl->tail = NULL;
    bl->count--;
    bs->next = NULL;
    return bs;
}

void blocked_list_clear(BlockedList *bl) {
    BlockedServer *bs;
    while ((bs = blocked_list_remove_first(bl)) != NULL) {
        /* Don't free bs->customer here - it's also referenced by the
         * blocked station's in_service and will be freed there */
        free(bs);
    }
}

/* ============================================================================
 * BUFFER AND BLOCKING UTILITIES
 * ============================================================================ */

/* Get current occupancy of a station (queue + in service + blocked customer) */
int get_station_occupancy(Station *stn) {
    int count = stn->queue.length;
    if (stn->state == SERVER_BUSY || stn->state == SERVER_BLOCKED) {
        count++;  /* Customer in service or blocked */
    }
    return count;
}

/* Check if station can accept a new customer */
int can_accept_customer(Station *stn) {
    if (stn->buffer_capacity == INFINITE_BUFFER) return 1;
    return get_station_occupancy(stn) < stn->buffer_capacity;
}

/* Check if station buffer is full */
int is_buffer_full(Station *stn) {
    if (stn->buffer_capacity == INFINITE_BUFFER) return 0;
    return get_station_occupancy(stn) >= stn->buffer_capacity;
}

/* ============================================================================
 * INPUT PARSING
 * ============================================================================ */

int parse_distribution(char *str, Distribution *dist) {
    char type_str[64];
    int n;

    dist->type = DIST_NONE;
    dist->param1 = dist->param2 = dist->param3 = 0.0;

    if (sscanf(str, "%63s%n", type_str, &n) != 1) return 0;

    if (strcmp(type_str, "none") == 0) {
        dist->type = DIST_NONE;
        return 1;
    }
    else if (strcmp(type_str, "exponential") == 0 || strcmp(type_str, "exp") == 0) {
        dist->type = DIST_EXPONENTIAL;
        if (sscanf(str + n, "%lf", &dist->param1) != 1) {
            fprintf(stderr, "Error: exponential requires rate parameter\n");
            return 0;
        }
        return 1;
    }
    else if (strcmp(type_str, "erlang") == 0) {
        dist->type = DIST_ERLANG;
        if (sscanf(str + n, "%lf %lf", &dist->param1, &dist->param2) != 2) {
            fprintf(stderr, "Error: erlang requires shape and rate parameters\n");
            return 0;
        }
        return 1;
    }
    else if (strcmp(type_str, "gamma") == 0) {
        dist->type = DIST_GAMMA;
        if (sscanf(str + n, "%lf %lf", &dist->param1, &dist->param2) != 2) {
            fprintf(stderr, "Error: gamma requires shape and scale parameters\n");
            return 0;
        }
        return 1;
    }
    else if (strcmp(type_str, "uniform") == 0) {
        dist->type = DIST_UNIFORM;
        if (sscanf(str + n, "%lf %lf", &dist->param1, &dist->param2) != 2) {
            fprintf(stderr, "Error: uniform requires min and max parameters\n");
            return 0;
        }
        return 1;
    }
    else if (strcmp(type_str, "deterministic") == 0 || strcmp(type_str, "const") == 0) {
        dist->type = DIST_DETERMINISTIC;
        if (sscanf(str + n, "%lf", &dist->param1) != 1) {
            fprintf(stderr, "Error: deterministic requires value parameter\n");
            return 0;
        }
        return 1;
    }
    else if (strcmp(type_str, "hyperexp2") == 0 || strcmp(type_str, "hyperexp") == 0) {
        dist->type = DIST_HYPEREXP2;
        if (sscanf(str + n, "%lf %lf %lf", &dist->param1, &dist->param2, &dist->param3) != 3) {
            fprintf(stderr, "Error: hyperexp2 requires p, lambda1, lambda2 parameters\n");
            return 0;
        }
        return 1;
    }
    else if (strcmp(type_str, "lognormal") == 0) {
        dist->type = DIST_LOGNORMAL;
        if (sscanf(str + n, "%lf %lf", &dist->param1, &dist->param2) != 2) {
            fprintf(stderr, "Error: lognormal requires mu and sigma parameters\n");
            return 0;
        }
        return 1;
    }
    else if (strcmp(type_str, "weibull") == 0) {
        dist->type = DIST_WEIBULL;
        if (sscanf(str + n, "%lf %lf", &dist->param1, &dist->param2) != 2) {
            fprintf(stderr, "Error: weibull requires shape and scale parameters\n");
            return 0;
        }
        return 1;
    }
    else if (strcmp(type_str, "pareto") == 0) {
        dist->type = DIST_PARETO;
        if (sscanf(str + n, "%lf %lf", &dist->param1, &dist->param2) != 2) {
            fprintf(stderr, "Error: pareto requires shape and scale parameters\n");
            return 0;
        }
        return 1;
    }
    else {
        fprintf(stderr, "Error: Unknown distribution type '%s'\n", type_str);
        return 0;
    }
}

int parse_input_file(const char *filename) {
    FILE *fp;
    char line[MAX_LINE_LEN];
    char key[64], value[MAX_LINE_LEN];
    int current_class = -1;
    int i, j;

    /* Initialize defaults */
    sim_params.warmup_time = 1000.0;
    sim_params.run_length = 10000.0;
    sim_params.num_replications = 10;
    sim_params.seed = (unsigned long)time(NULL);
    sim_params.output_mcn_file[0] = '\0';
    sim_params.verbose = 0;

    network.num_stations = 0;
    network.num_classes = 0;
    network.blocking_protocol = BLOCKING_BAS;
    network.default_buffer_capacity = INFINITE_BUFFER;

    for (i = 0; i < MAX_CLASSES; i++) {
        network.classes[i].id = i;
        network.classes[i].arrival_dist.type = DIST_NONE;
        network.classes[i].arrival_station = 0;
        network.classes[i].service_dist.type = DIST_EXPONENTIAL;
        network.classes[i].service_dist.param1 = 1.0;
        network.classes[i].constituency_station = 0;
        for (j = 0; j < MAX_CLASSES; j++) {
            network.classes[i].routing[j] = 0.0;
        }
    }

    fp = fopen(filename, "r");
    if (!fp) {
        fprintf(stderr, "Error: Cannot open input file '%s'\n", filename);
        return 0;
    }

    while (fgets(line, sizeof(line), fp)) {
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '#' || *p == '\n' || *p == '\0') continue;
        {
            char *nl = strchr(p, '\n');
            if (nl) *nl = '\0';
        }

        if (sscanf(p, "%63s", key) != 1) continue;
        {
            char *vp = p + strlen(key);
            while (*vp == ' ' || *vp == '\t' || *vp == ':' || *vp == '=') vp++;
            strncpy(value, vp, sizeof(value) - 1);
            value[sizeof(value) - 1] = '\0';
        }

        /* Global parameters */
        if (strcmp(key, "stations") == 0) {
            network.num_stations = atoi(value);
            for (i = 0; i < network.num_stations; i++) {
                network.stations[i].id = i;
                queue_init(&network.stations[i].queue);
                network.stations[i].state = SERVER_IDLE;
                network.stations[i].in_service = NULL;
                network.stations[i].buffer_capacity = network.default_buffer_capacity;
                blocked_list_init(&network.stations[i].blocked_waiting);
                network.stations[i].waiting_for_downstream = 0;
            }
        }
        else if (strcmp(key, "classes") == 0) {
            network.num_classes = atoi(value);
        }
        else if (strcmp(key, "warmup") == 0 || strcmp(key, "warmup_time") == 0) {
            sim_params.warmup_time = atof(value);
        }
        else if (strcmp(key, "run_length") == 0 || strcmp(key, "runtime") == 0) {
            sim_params.run_length = atof(value);
        }
        else if (strcmp(key, "replications") == 0 || strcmp(key, "runs") == 0) {
            sim_params.num_replications = atoi(value);
        }
        else if (strcmp(key, "seed") == 0) {
            sim_params.seed = (unsigned long)atol(value);
        }
        else if (strcmp(key, "mcn_output") == 0 || strcmp(key, "output_mcn") == 0) {
            strncpy(sim_params.output_mcn_file, value, sizeof(sim_params.output_mcn_file) - 1);
        }
        else if (strcmp(key, "verbose") == 0) {
            sim_params.verbose = atoi(value);
        }
        else if (strcmp(key, "blocking") == 0 || strcmp(key, "blocking_protocol") == 0) {
            if (strcmp(value, "BAS") == 0 || strcmp(value, "bas") == 0) {
                network.blocking_protocol = BLOCKING_BAS;
            } else if (strcmp(value, "BBS") == 0 || strcmp(value, "bbs") == 0) {
                network.blocking_protocol = BLOCKING_BBS;
            } else if (strcmp(value, "RS") == 0 || strcmp(value, "rs") == 0 ||
                       strcmp(value, "rejection") == 0 || strcmp(value, "loss") == 0) {
                network.blocking_protocol = BLOCKING_RS;
            } else {
                fprintf(stderr, "Warning: Unknown blocking protocol '%s', using BAS\n", value);
            }
        }
        else if (strcmp(key, "default_buffer") == 0 || strcmp(key, "buffer_capacity") == 0) {
            if (strcmp(value, "infinite") == 0 || strcmp(value, "inf") == 0) {
                network.default_buffer_capacity = INFINITE_BUFFER;
            } else {
                network.default_buffer_capacity = atoi(value);
            }
            /* Update all stations */
            for (i = 0; i < network.num_stations; i++) {
                network.stations[i].buffer_capacity = network.default_buffer_capacity;
            }
        }
        /* Class definition start */
        else if (strcmp(key, "class") == 0) {
            current_class = atoi(value);
            if (current_class < 0 || current_class >= MAX_CLASSES) {
                fprintf(stderr, "Error: Invalid class number %d\n", current_class);
                fclose(fp);
                return 0;
            }
        }
        else if (strcmp(key, "end_class") == 0) {
            current_class = -1;
        }
        /* Station definition for buffer capacity */
        else if (strcmp(key, "station_buffer") == 0) {
            int stn_id, cap;
            if (sscanf(value, "%d %d", &stn_id, &cap) == 2) {
                if (stn_id >= 0 && stn_id < network.num_stations) {
                    network.stations[stn_id].buffer_capacity = cap;
                }
            }
        }
        /* Class-specific parameters */
        else if (current_class >= 0) {
            if (strcmp(key, "arrival") == 0 || strcmp(key, "external_arrival") == 0) {
                if (!parse_distribution(value, &network.classes[current_class].arrival_dist)) {
                    fclose(fp);
                    return 0;
                }
            }
            else if (strcmp(key, "arrival_station") == 0 || strcmp(key, "starting_station") == 0) {
                network.classes[current_class].arrival_station = atoi(value);
            }
            else if (strcmp(key, "station") == 0 || strcmp(key, "constituency") == 0) {
                network.classes[current_class].constituency_station = atoi(value);
            }
            else if (strcmp(key, "service") == 0) {
                if (!parse_distribution(value, &network.classes[current_class].service_dist)) {
                    fclose(fp);
                    return 0;
                }
            }
            else if (strcmp(key, "routing") == 0) {
                char *tok = value;
                int idx = 0;
                while (idx < MAX_CLASSES) {
                    double prob;
                    int n;
                    if (sscanf(tok, "%lf%n", &prob, &n) != 1) break;
                    network.classes[current_class].routing[idx++] = prob;
                    tok += n;
                    while (*tok == ' ' || *tok == '\t' || *tok == ',') tok++;
                }
            }
        }
    }

    fclose(fp);

    if (network.num_stations <= 0) {
        fprintf(stderr, "Error: Number of stations must be positive\n");
        return 0;
    }
    if (network.num_classes <= 0) {
        fprintf(stderr, "Error: Number of classes must be positive\n");
        return 0;
    }

    return 1;
}

/* ============================================================================
 * SIMULATION ENGINE
 * ============================================================================ */

void schedule_arrival(int class_id, double time) {
    Event e;
    e.type = EVENT_ARRIVAL;
    e.time = time;
    e.class_id = class_id;
    e.station_id = network.classes[class_id].constituency_station;
    e.customer = NULL;
    e.target_class = -1;
    heap_push(&event_heap, e);
}

void schedule_departure(int station_id, Customer *c, double time) {
    Event e;
    e.type = EVENT_DEPARTURE;
    e.time = time;
    e.class_id = c->class_id;
    e.station_id = station_id;
    e.customer = c;
    e.target_class = -1;
    heap_push(&event_heap, e);
}

void schedule_unblock(int station_id, Customer *c, int target_class, double time) {
    Event e;
    e.type = EVENT_UNBLOCK;
    e.time = time;
    e.class_id = c->class_id;
    e.station_id = station_id;
    e.customer = c;
    e.target_class = target_class;
    heap_push(&event_heap, e);
}

/* Try to start service at a station */
void try_start_service(Station *stn, RunStats *stats);

/* Move customer to next station (returns 1 if successful, 0 if blocked/rejected) */
int move_customer_to_station(Customer *c, int target_class, int from_station,
                             RunStats *stats);

/* Check for and unblock servers waiting for this station */
void check_unblock_waiting_servers(Station *stn, RunStats *stats);

void sim_init(void) {
    int i;

    current_time = 0.0;
    next_customer_id = 0;
    warmup_complete = 0;
    last_state_change_time = 0.0;

    heap_init(&event_heap);

    for (i = 0; i < network.num_stations; i++) {
        queue_init(&network.stations[i].queue);
        network.stations[i].state = SERVER_IDLE;
        network.stations[i].in_service = NULL;
        network.stations[i].service_start_time = 0.0;
        blocked_list_init(&network.stations[i].blocked_waiting);
        network.stations[i].waiting_for_downstream = 0;
    }

    for (i = 0; i < network.num_classes; i++) {
        if (network.classes[i].arrival_dist.type != DIST_NONE) {
            double interarrival = generate_from_dist(&network.classes[i].arrival_dist);
            schedule_arrival(i, interarrival);
        }
    }
}

void sim_cleanup(void) {
    int i;
    for (i = 0; i < network.num_stations; i++) {
        queue_clear(&network.stations[i].queue);
        blocked_list_clear(&network.stations[i].blocked_waiting);
        if (network.stations[i].in_service) {
            free(network.stations[i].in_service);
            network.stations[i].in_service = NULL;
        }
    }
    heap_free(&event_heap);
}

/* Determine next class for a customer based on routing */
int determine_next_class(Class *cls) {
    double u = rng_uniform();
    double cumulative = 0.0;
    int i;

    for (i = 0; i < network.num_classes; i++) {
        cumulative += cls->routing[i];
        if (u < cumulative) {
            return i;
        }
    }
    return -1;  /* Leave system */
}

/* Try to start service at a station if possible */
void try_start_service(Station *stn, RunStats *stats) {
    Customer *c;
    Class *cls;
    double service_time;
    int target_station;
    int can_start;
    int i;

    if (stn->state != SERVER_IDLE) return;
    if (queue_is_empty(&stn->queue)) return;

    /* For BBS: check if downstream is available before starting */
    if (network.blocking_protocol == BLOCKING_BBS) {
        /* Peek at customer and determine likely destination */
        c = stn->queue.head;
        cls = &network.classes[c->class_id];

        /* Check all possible destinations */
        can_start = 1;
        for (i = 0; i < network.num_classes; i++) {
            if (cls->routing[i] > 0) {
                target_station = network.classes[i].constituency_station;
                if (is_buffer_full(&network.stations[target_station])) {
                    can_start = 0;
                    stn->waiting_for_downstream = 1;
                    stn->downstream_station = target_station;
                    break;
                }
            }
        }
        if (!can_start) return;
    }

    c = queue_dequeue(&stn->queue);
    cls = &network.classes[c->class_id];

    service_time = generate_from_dist(&cls->service_dist);

    stn->state = SERVER_BUSY;
    stn->in_service = c;
    stn->service_start_time = current_time;

    schedule_departure(stn->id, c, current_time + service_time);
}

/* Move customer to next station */
int move_customer_to_station(Customer *c, int target_class, int from_station,
                             RunStats *stats) {
    Class *target_cls = &network.classes[target_class];
    Station *target_stn = &network.stations[target_cls->constituency_station];

    /* Check if target can accept customer */
    if (!can_accept_customer(target_stn)) {
        return 0;  /* Cannot move */
    }

    /* Update customer */
    c->class_id = target_class;
    c->queue_entry_time = current_time;

    /* Add to target station */
    if (target_stn->state == SERVER_IDLE) {
        /* Start service immediately */
        Class *cls = &network.classes[c->class_id];
        double service_time = generate_from_dist(&cls->service_dist);

        target_stn->state = SERVER_BUSY;
        target_stn->in_service = c;
        target_stn->service_start_time = current_time;

        schedule_departure(target_cls->constituency_station, c, current_time + service_time);
    } else {
        queue_enqueue(&target_stn->queue, c);
    }

    return 1;  /* Success */
}

/* Check if any servers are blocked waiting for this station and unblock them */
void check_unblock_waiting_servers(Station *stn, RunStats *stats) {
    BlockedServer *bs;
    Station *blocked_stn;

    /* Check blocked list for this station */
    while (can_accept_customer(stn) && stn->blocked_waiting.count > 0) {
        bs = blocked_list_remove_first(&stn->blocked_waiting);
        if (!bs) break;

        blocked_stn = &network.stations[bs->station_id];

        /* Record blocking time */
        if (warmup_complete) {
            stats->blocked_time[bs->station_id] += current_time - bs->block_start_time;
        }

        /* Move the blocked customer */
        if (move_customer_to_station(bs->customer, bs->target_class, bs->station_id, stats)) {
            /* Unblock the server */
            blocked_stn->state = SERVER_IDLE;
            blocked_stn->in_service = NULL;

            /* Try to start next service at the unblocked station */
            try_start_service(blocked_stn, stats);
        }

        free(bs);
    }

    /* For BBS: check if any station was waiting for downstream */
    if (network.blocking_protocol == BLOCKING_BBS) {
        int i;
        for (i = 0; i < network.num_stations; i++) {
            Station *s = &network.stations[i];
            if (s->waiting_for_downstream && s->downstream_station == stn->id) {
                if (can_accept_customer(stn)) {
                    s->waiting_for_downstream = 0;
                    try_start_service(s, stats);
                }
            }
        }
    }
}

/* Process arrival event */
void process_arrival(Event *e, RunStats *stats) {
    Customer *c;
    Class *cls;
    Station *stn;
    int station_id;

    cls = &network.classes[e->class_id];
    station_id = cls->constituency_station;
    stn = &network.stations[station_id];

    /* Schedule next external arrival */
    if (cls->arrival_dist.type != DIST_NONE) {
        double interarrival = generate_from_dist(&cls->arrival_dist);
        schedule_arrival(e->class_id, current_time + interarrival);
    }

    /* Check buffer capacity (for RS protocol or finite buffers) */
    if (!can_accept_customer(stn)) {
        if (network.blocking_protocol == BLOCKING_RS) {
            /* Reject customer */
            if (warmup_complete) {
                stats->customers_rejected[e->class_id]++;
            }
            return;
        }
        /* For BAS/BBS with external arrivals to full buffer, also reject */
        if (warmup_complete) {
            stats->customers_rejected[e->class_id]++;
        }
        return;
    }

    /* Create new customer */
    c = (Customer *)malloc(sizeof(Customer));
    if (!c) {
        fprintf(stderr, "Error: Failed to allocate customer\n");
        exit(1);
    }
    c->id = next_customer_id++;
    c->class_id = e->class_id;
    c->original_class = e->class_id;
    c->arrival_time = current_time;
    c->queue_entry_time = current_time;
    c->next = NULL;

    if (warmup_complete) {
        stats->customers_arrived[e->class_id]++;
    }

    /* If server is idle, start service immediately */
    if (stn->state == SERVER_IDLE) {
        double service_time = generate_from_dist(&cls->service_dist);
        stn->state = SERVER_BUSY;
        stn->in_service = c;
        stn->service_start_time = current_time;
        schedule_departure(station_id, c, current_time + service_time);
    } else {
        queue_enqueue(&stn->queue, c);
    }
}

/* Process departure event */
void process_departure(Event *e, RunStats *stats) {
    Customer *c = e->customer;
    Class *cls = &network.classes[c->class_id];
    Station *stn = &network.stations[e->station_id];
    double queue_time, service_time, sojourn_time;
    int next_class;

    /* Calculate times */
    queue_time = stn->service_start_time - c->queue_entry_time;
    service_time = current_time - stn->service_start_time;
    sojourn_time = queue_time + service_time;

    /* Record statistics */
    if (warmup_complete) {
        stats->total_queue_time[c->class_id] += queue_time;
        stats->total_sojourn_time[c->class_id] += sojourn_time;
        stats->customers_served[c->class_id]++;
        stats->queue_time_class_station[c->class_id][e->station_id] += queue_time;
        stats->count_class_station[c->class_id][e->station_id]++;
        stats->total_queue_time_station[e->station_id] += queue_time;
        stats->customers_at_station[e->station_id]++;
        stats->busy_time[e->station_id] += service_time;
    }

    /* Determine next class */
    next_class = determine_next_class(cls);

    if (next_class < 0) {
        /* Customer leaves system */
        if (warmup_complete) {
            stats->customers_completed[c->class_id]++;
        }
        free(c);

        /* Server becomes idle */
        stn->state = SERVER_IDLE;
        stn->in_service = NULL;

        /* Try to start next customer */
        try_start_service(stn, stats);

        /* Check if anyone was waiting for space here */
        check_unblock_waiting_servers(stn, stats);
    } else {
        /* Try to move to next station */
        Class *next_cls = &network.classes[next_class];
        Station *next_stn = &network.stations[next_cls->constituency_station];

        if (can_accept_customer(next_stn)) {
            /* Move successful */
            if (move_customer_to_station(c, next_class, e->station_id, stats)) {
                stn->state = SERVER_IDLE;
                stn->in_service = NULL;
                try_start_service(stn, stats);
                check_unblock_waiting_servers(stn, stats);
            }
        } else {
            /* Blocking occurs */
            if (network.blocking_protocol == BLOCKING_RS) {
                /* Reject - customer is lost */
                if (warmup_complete) {
                    stats->customers_rejected[next_class]++;
                }
                free(c);
                stn->state = SERVER_IDLE;
                stn->in_service = NULL;
                try_start_service(stn, stats);
                check_unblock_waiting_servers(stn, stats);
            } else {
                /* BAS: Block the server */
                stn->state = SERVER_BLOCKED;
                /* Add to blocked list of target station */
                blocked_list_add(&next_stn->blocked_waiting, e->station_id, c, next_class);

                if (warmup_complete) {
                    stats->blocking_events[e->station_id]++;
                }
            }
        }
    }
}

/* Process unblock event (for BBS mostly) */
void process_unblock(Event *e, RunStats *stats) {
    Station *stn = &network.stations[e->station_id];

    if (stn->state == SERVER_BLOCKED && stn->in_service == e->customer) {
        /* Try to move customer now */
        Class *next_cls = &network.classes[e->target_class];
        Station *next_stn = &network.stations[next_cls->constituency_station];

        if (can_accept_customer(next_stn)) {
            if (move_customer_to_station(e->customer, e->target_class, e->station_id, stats)) {
                stn->state = SERVER_IDLE;
                stn->in_service = NULL;
                try_start_service(stn, stats);
            }
        }
    }
}

void init_run_stats(RunStats *stats) {
    int i, j;
    for (i = 0; i < MAX_CLASSES; i++) {
        stats->total_queue_time[i] = 0.0;
        stats->total_sojourn_time[i] = 0.0;
        stats->customers_served[i] = 0;
        stats->customers_completed[i] = 0;
        stats->customers_arrived[i] = 0;
        stats->customers_rejected[i] = 0;
    }
    for (i = 0; i < MAX_STATIONS; i++) {
        stats->total_queue_time_station[i] = 0.0;
        stats->customers_at_station[i] = 0;
        stats->busy_time[i] = 0.0;
        stats->blocked_time[i] = 0.0;
        stats->starved_time[i] = 0.0;
        stats->blocking_events[i] = 0;
    }
    for (i = 0; i < MAX_CLASSES; i++) {
        for (j = 0; j < MAX_STATIONS; j++) {
            stats->queue_time_class_station[i][j] = 0.0;
            stats->count_class_station[i][j] = 0;
        }
    }
    stats->total_customers_in_system = 0;
    stats->total_time_all_blocked = 0.0;
}

void run_simulation(RunStats *stats) {
    Event e;
    double total_time = sim_params.warmup_time + sim_params.run_length;

    sim_init();
    init_run_stats(stats);

    while (!heap_empty(&event_heap)) {
        e = heap_pop(&event_heap);

        if (e.time > total_time) break;

        current_time = e.time;

        if (!warmup_complete && current_time >= sim_params.warmup_time) {
            warmup_complete = 1;
            init_run_stats(stats);
            last_state_change_time = current_time;
        }

        switch (e.type) {
            case EVENT_ARRIVAL:
                process_arrival(&e, stats);
                break;
            case EVENT_DEPARTURE:
                process_departure(&e, stats);
                break;
            case EVENT_UNBLOCK:
                process_unblock(&e, stats);
                break;
        }
    }

    /* Calculate final starvation times */
    if (warmup_complete) {
        int i;
        for (i = 0; i < network.num_stations; i++) {
            Station *stn = &network.stations[i];
            if (stn->state == SERVER_IDLE && queue_is_empty(&stn->queue)) {
                /* Currently starved - add remaining time */
                /* This is approximate - ideally track start of starvation */
            }
        }
    }

    sim_cleanup();
}

/* ============================================================================
 * STATISTICS AND OUTPUT
 * ============================================================================ */

void init_aggregate_stats(AggregateStats *agg) {
    int i, j;
    for (i = 0; i < MAX_CLASSES; i++) {
        agg->mean_queue_time[i] = 0.0;
        agg->var_queue_time[i] = 0.0;
        agg->mean_sojourn_time[i] = 0.0;
        agg->var_sojourn_time[i] = 0.0;
        agg->mean_throughput[i] = 0.0;
        agg->var_throughput[i] = 0.0;
        agg->mean_rejection_rate[i] = 0.0;
        agg->var_rejection_rate[i] = 0.0;
    }
    for (i = 0; i < MAX_STATIONS; i++) {
        agg->mean_queue_time_station[i] = 0.0;
        agg->var_queue_time_station[i] = 0.0;
        agg->mean_utilization[i] = 0.0;
        agg->var_utilization[i] = 0.0;
        agg->mean_blocking_prob[i] = 0.0;
        agg->var_blocking_prob[i] = 0.0;
        agg->mean_starvation_prob[i] = 0.0;
        agg->var_starvation_prob[i] = 0.0;
    }
    for (i = 0; i < MAX_CLASSES; i++) {
        for (j = 0; j < MAX_STATIONS; j++) {
            agg->mean_queue_time_cs[i][j] = 0.0;
            agg->var_queue_time_cs[i][j] = 0.0;
        }
    }
}

void compute_aggregate_stats(double **run_values, int num_runs, int num_metrics,
                             AggregateStats *agg) {
    int i, j, r;
    int idx;
    double sum, sum_sq, mean, var;
    int nc = network.num_classes;
    int ns = network.num_stations;

    /* Layout of run_values:
     * [0..nc-1]: queue time per class
     * [nc..2nc-1]: sojourn time per class
     * [2nc..3nc-1]: throughput per class
     * [3nc..4nc-1]: rejection rate per class
     * [4nc..4nc+ns-1]: queue time per station
     * [4nc+ns..4nc+2ns-1]: utilization per station
     * [4nc+2ns..4nc+3ns-1]: blocking prob per station
     * [4nc+3ns..4nc+4ns-1]: (reserved for starvation)
     * [4nc+4ns..]: class-station queue times
     */

    for (i = 0; i < nc; i++) {
        /* Queue time */
        idx = i;
        sum = sum_sq = 0.0;
        for (r = 0; r < num_runs; r++) {
            sum += run_values[r][idx];
            sum_sq += run_values[r][idx] * run_values[r][idx];
        }
        mean = sum / num_runs;
        var = (num_runs > 1) ? (sum_sq - sum * sum / num_runs) / (num_runs - 1) : 0;
        if (var < 0) var = 0;
        agg->mean_queue_time[i] = mean;
        agg->var_queue_time[i] = var;

        /* Sojourn time */
        idx = nc + i;
        sum = sum_sq = 0.0;
        for (r = 0; r < num_runs; r++) {
            sum += run_values[r][idx];
            sum_sq += run_values[r][idx] * run_values[r][idx];
        }
        mean = sum / num_runs;
        var = (num_runs > 1) ? (sum_sq - sum * sum / num_runs) / (num_runs - 1) : 0;
        if (var < 0) var = 0;
        agg->mean_sojourn_time[i] = mean;
        agg->var_sojourn_time[i] = var;

        /* Throughput */
        idx = 2 * nc + i;
        sum = sum_sq = 0.0;
        for (r = 0; r < num_runs; r++) {
            sum += run_values[r][idx];
            sum_sq += run_values[r][idx] * run_values[r][idx];
        }
        mean = sum / num_runs;
        var = (num_runs > 1) ? (sum_sq - sum * sum / num_runs) / (num_runs - 1) : 0;
        if (var < 0) var = 0;
        agg->mean_throughput[i] = mean;
        agg->var_throughput[i] = var;

        /* Rejection rate */
        idx = 3 * nc + i;
        sum = sum_sq = 0.0;
        for (r = 0; r < num_runs; r++) {
            sum += run_values[r][idx];
            sum_sq += run_values[r][idx] * run_values[r][idx];
        }
        mean = sum / num_runs;
        var = (num_runs > 1) ? (sum_sq - sum * sum / num_runs) / (num_runs - 1) : 0;
        if (var < 0) var = 0;
        agg->mean_rejection_rate[i] = mean;
        agg->var_rejection_rate[i] = var;
    }

    for (i = 0; i < ns; i++) {
        /* Queue time at station */
        idx = 4 * nc + i;
        sum = sum_sq = 0.0;
        for (r = 0; r < num_runs; r++) {
            sum += run_values[r][idx];
            sum_sq += run_values[r][idx] * run_values[r][idx];
        }
        mean = sum / num_runs;
        var = (num_runs > 1) ? (sum_sq - sum * sum / num_runs) / (num_runs - 1) : 0;
        if (var < 0) var = 0;
        agg->mean_queue_time_station[i] = mean;
        agg->var_queue_time_station[i] = var;

        /* Utilization */
        idx = 4 * nc + ns + i;
        sum = sum_sq = 0.0;
        for (r = 0; r < num_runs; r++) {
            sum += run_values[r][idx];
            sum_sq += run_values[r][idx] * run_values[r][idx];
        }
        mean = sum / num_runs;
        var = (num_runs > 1) ? (sum_sq - sum * sum / num_runs) / (num_runs - 1) : 0;
        if (var < 0) var = 0;
        agg->mean_utilization[i] = mean;
        agg->var_utilization[i] = var;

        /* Blocking probability */
        idx = 4 * nc + 2 * ns + i;
        sum = sum_sq = 0.0;
        for (r = 0; r < num_runs; r++) {
            sum += run_values[r][idx];
            sum_sq += run_values[r][idx] * run_values[r][idx];
        }
        mean = sum / num_runs;
        var = (num_runs > 1) ? (sum_sq - sum * sum / num_runs) / (num_runs - 1) : 0;
        if (var < 0) var = 0;
        agg->mean_blocking_prob[i] = mean;
        agg->var_blocking_prob[i] = var;
    }

    /* Class-station queue times */
    for (i = 0; i < nc; i++) {
        for (j = 0; j < ns; j++) {
            idx = 4 * nc + 3 * ns + i * ns + j;
            sum = sum_sq = 0.0;
            for (r = 0; r < num_runs; r++) {
                sum += run_values[r][idx];
                sum_sq += run_values[r][idx] * run_values[r][idx];
            }
            mean = sum / num_runs;
            var = (num_runs > 1) ? (sum_sq - sum * sum / num_runs) / (num_runs - 1) : 0;
            if (var < 0) var = 0;
            agg->mean_queue_time_cs[i][j] = mean;
            agg->var_queue_time_cs[i][j] = var;
        }
    }
}

/* Student-t critical values t_{n-1, 0.975}, n = 2..30, for a 95 % interval.
 * Mirrors finite/fBNAsim/stats.c so the two simulators label the same number
 * the same way. The previous constant 2.0 was described as an "approximate t
 * critical value", but it is the large-sample NORMAL value rounded up: at the
 * replication counts this GUI actually runs (5, 10, 30) it understates the
 * half-width by 39 %, 13 % and 2 %, so the interval printed as 95 % covered
 * less than that. ResultOutputParser stores these as a 95 % interval, and the
 * label is now true rather than approximately true. */
static const double jackson_t_crit_table[] = {
    /* n=2  */  12.706, /*  3 */  4.303, /*  4 */  3.182, /*  5 */  2.776,
    /*  6  */   2.571, /*  7 */  2.447, /*  8 */  2.365, /*  9 */  2.306,
    /* 10  */   2.262, /* 11 */  2.228, /* 12 */  2.201, /* 13 */  2.179,
    /* 14  */   2.160, /* 15 */  2.145, /* 16 */  2.131, /* 17 */  2.120,
    /* 18  */   2.110, /* 19 */  2.101, /* 20 */  2.093, /* 21 */  2.086,
    /* 22  */   2.080, /* 23 */  2.074, /* 24 */  2.069, /* 25 */  2.064,
    /* 26  */   2.060, /* 27 */  2.056, /* 28 */  2.052, /* 29 */  2.048,
    /* 30  */   2.045
};

/* Half-width of the 95 % confidence interval for a replication mean, given the
 * across-replication SAMPLE variance (the aggregator divides by n-1, which is
 * what makes a t interval the right one) and the number of replications.
 * A single replication has no sampling distribution, so it reports 0 rather
 * than the infinity a division by n-1 = 0 would otherwise carry into print. */
static double jackson_ci_half_width(double variance, int n)
{
    double critical;
    if (n < 2 || !(variance > 0.0)) return 0.0;
    critical = (n <= 30) ? jackson_t_crit_table[n - 2] : 1.96;
    return critical * sqrt(variance / n);
}

void print_results(AggregateStats *agg) {
    int i, j;
    double ci95;
    const char *blocking_str;

    switch (network.blocking_protocol) {
        case BLOCKING_BAS: blocking_str = "BAS (Blocking After Service)"; break;
        case BLOCKING_BBS: blocking_str = "BBS (Blocking Before Service)"; break;
        case BLOCKING_RS: blocking_str = "RS (Rejection/Loss)"; break;
        default: blocking_str = "Unknown"; break;
    }

    printf("\n");
    printf("===============================================================================\n");
    printf("       MULTI-CLASS JACKSON NETWORK SIMULATION (FINITE BUFFERS)\n");
    printf("===============================================================================\n\n");

    printf("Simulation Parameters:\n");
    printf("  Warmup time:        %.2f\n", sim_params.warmup_time);
    printf("  Run length:         %.2f\n", sim_params.run_length);
    printf("  Replications:       %d\n", sim_params.num_replications);
    printf("  Random seed:        %lu\n", sim_params.seed);
    printf("  Blocking protocol:  %s\n", blocking_str);
    printf("\n");

    printf("Network Configuration:\n");
    printf("  Stations:           %d\n", network.num_stations);
    printf("  Classes:            %d\n", network.num_classes);
    printf("  Buffer capacities:  ");
    for (i = 0; i < network.num_stations; i++) {
        if (network.stations[i].buffer_capacity == INFINITE_BUFFER) {
            printf("S%d=inf ", i);
        } else {
            printf("S%d=%d ", i, network.stations[i].buffer_capacity);
        }
    }
    printf("\n\n");

    /* Per-class results */
    printf("-------------------------------------------------------------------------------\n");
    printf("PER-CLASS STATISTICS\n");
    printf("-------------------------------------------------------------------------------\n\n");

    printf("%-6s %12s %12s %12s %12s %12s\n",
           "Class", "Queue Time", "Sojourn", "Throughput", "Reject Rate", "95% CI(Q)");
    printf("-------------------------------------------------------------------------------\n");

    for (i = 0; i < network.num_classes; i++) {
        ci95 = jackson_ci_half_width(agg->var_queue_time[i], sim_params.num_replications);
        printf("%-6d %12.6f %12.6f %12.6f %12.6f %12.6f\n",
               i, agg->mean_queue_time[i], agg->mean_sojourn_time[i],
               agg->mean_throughput[i], agg->mean_rejection_rate[i], ci95);
    }
    printf("\n");

    /* Per-station results */
    printf("-------------------------------------------------------------------------------\n");
    printf("PER-STATION STATISTICS\n");
    printf("-------------------------------------------------------------------------------\n\n");

    printf("%-8s %10s %12s %12s %12s %12s\n",
           "Station", "Buffer", "Queue Time", "Utilization", "Block Prob", "95% CI(U)");
    printf("-------------------------------------------------------------------------------\n");

    for (i = 0; i < network.num_stations; i++) {
        double ci_util = jackson_ci_half_width(
            agg->var_utilization[i], sim_params.num_replications);
        char buf_str[16];
        if (network.stations[i].buffer_capacity == INFINITE_BUFFER) {
            strcpy(buf_str, "inf");
        } else {
            sprintf(buf_str, "%d", network.stations[i].buffer_capacity);
        }
        printf("%-8d %10s %12.6f %12.6f %12.6f %12.6f\n",
               i, buf_str, agg->mean_queue_time_station[i],
               agg->mean_utilization[i], agg->mean_blocking_prob[i], ci_util);
    }
    printf("\n");

    /* Queue time by class and station */
    printf("-------------------------------------------------------------------------------\n");
    printf("MEAN QUEUE TIME BY CLASS AND STATION\n");
    printf("-------------------------------------------------------------------------------\n\n");

    printf("%-8s", "Class");
    for (j = 0; j < network.num_stations; j++) {
        printf(" %12s%d", "Station ", j);
    }
    printf("\n");
    printf("-------------------------------------------------------------------------------\n");

    for (i = 0; i < network.num_classes; i++) {
        printf("%-8d", i);
        for (j = 0; j < network.num_stations; j++) {
            if (network.classes[i].constituency_station == j) {
                printf(" %13.6f", agg->mean_queue_time_cs[i][j]);
            } else {
                printf(" %13s", "-");
            }
        }
        printf("\n");
    }
    printf("\n");
}

void write_mcn_output(const char *filename, AggregateStats *agg) {
    FILE *fp;
    int i, j;
    int d = network.num_stations;
    int c = network.num_classes;

    fp = fopen(filename, "w");
    if (!fp) {
        fprintf(stderr, "Warning: Cannot open MCN output file '%s'\n", filename);
        return;
    }

    fprintf(fp, "%d\n", d);
    fprintf(fp, "%d\n", c);

    for (i = 0; i < c; i++) {
        Class *cls = &network.classes[i];
        double alpha, sca, tau, scs;

        if (cls->arrival_dist.type != DIST_NONE) {
            alpha = 1.0 / dist_mean(&cls->arrival_dist);
            sca = dist_scv(&cls->arrival_dist);
        } else {
            alpha = 0.0;
            sca = 0.0;
        }

        tau = dist_mean(&cls->service_dist);
        scs = dist_scv(&cls->service_dist);

        fprintf(fp, "%.6f\n", alpha);
        fprintf(fp, "%.6f\n", sca);
        fprintf(fp, "%.6f\n", tau);
        fprintf(fp, "%.6f\n", scs);
        fprintf(fp, "%d\n", cls->constituency_station + 1);

        for (j = 0; j < c; j++) {
            fprintf(fp, "%.6f", cls->routing[j]);
            if (j < c - 1) fprintf(fp, " ");
        }
        fprintf(fp, "\n");
    }

    fprintf(fp, "5\n");

    fclose(fp);
    printf("MCN format output written to '%s'\n", filename);
}

void write_results_file(const char *base_filename, AggregateStats *agg) {
    FILE *fp;
    char filename[512];
    int i, j;
    const char *blocking_str;

    switch (network.blocking_protocol) {
        case BLOCKING_BAS: blocking_str = "BAS"; break;
        case BLOCKING_BBS: blocking_str = "BBS"; break;
        case BLOCKING_RS: blocking_str = "RS"; break;
        default: blocking_str = "Unknown"; break;
    }

    snprintf(filename, sizeof(filename), "%s_results.txt", base_filename);

    fp = fopen(filename, "w");
    if (!fp) {
        fprintf(stderr, "Warning: Cannot open results file '%s'\n", filename);
        return;
    }

    fprintf(fp, "# Multi-Class Jackson Network Simulation Results (Finite Buffers)\n");
    fprintf(fp, "# Generated by jackson_sim_finite\n\n");

    fprintf(fp, "# Simulation Parameters\n");
    fprintf(fp, "warmup_time: %.2f\n", sim_params.warmup_time);
    fprintf(fp, "run_length: %.2f\n", sim_params.run_length);
    fprintf(fp, "replications: %d\n", sim_params.num_replications);
    fprintf(fp, "seed: %lu\n", sim_params.seed);
    fprintf(fp, "blocking_protocol: %s\n\n", blocking_str);

    fprintf(fp, "# Network Configuration\n");
    fprintf(fp, "stations: %d\n", network.num_stations);
    fprintf(fp, "classes: %d\n", network.num_classes);
    fprintf(fp, "buffer_capacities:");
    for (i = 0; i < network.num_stations; i++) {
        fprintf(fp, " %d", network.stations[i].buffer_capacity);
    }
    fprintf(fp, "\n\n");

    fprintf(fp, "# Per-Class Results\n");
    fprintf(fp, "# class mean_queue_time var_queue_time mean_sojourn_time var_sojourn_time ");
    fprintf(fp, "throughput var_throughput rejection_rate var_rejection_rate\n");
    for (i = 0; i < network.num_classes; i++) {
        fprintf(fp, "%d %.6f %.6f %.6f %.6f %.6f %.6f %.6f %.6f\n",
                i, agg->mean_queue_time[i], agg->var_queue_time[i],
                agg->mean_sojourn_time[i], agg->var_sojourn_time[i],
                agg->mean_throughput[i], agg->var_throughput[i],
                agg->mean_rejection_rate[i], agg->var_rejection_rate[i]);
    }
    fprintf(fp, "\n");

    fprintf(fp, "# Per-Station Results\n");
    fprintf(fp, "# station buffer_capacity mean_queue_time var_queue_time ");
    fprintf(fp, "mean_utilization var_utilization blocking_prob var_blocking_prob\n");
    for (i = 0; i < network.num_stations; i++) {
        fprintf(fp, "%d %d %.6f %.6f %.6f %.6f %.6f %.6f\n",
                i, network.stations[i].buffer_capacity,
                agg->mean_queue_time_station[i], agg->var_queue_time_station[i],
                agg->mean_utilization[i], agg->var_utilization[i],
                agg->mean_blocking_prob[i], agg->var_blocking_prob[i]);
    }
    fprintf(fp, "\n");

    fprintf(fp, "# Queue Time by Class and Station\n");
    fprintf(fp, "# class station mean_queue_time var_queue_time\n");
    for (i = 0; i < network.num_classes; i++) {
        for (j = 0; j < network.num_stations; j++) {
            if (network.classes[i].constituency_station == j) {
                fprintf(fp, "%d %d %.6f %.6f\n",
                        i, j, agg->mean_queue_time_cs[i][j], agg->var_queue_time_cs[i][j]);
            }
        }
    }

    fclose(fp);
    printf("Detailed results written to '%s'\n", filename);
}

/* ============================================================================
 * MAIN PROGRAM
 * ============================================================================ */

void print_usage(const char *prog_name) {
    printf("Usage: %s input_file [options]\n\n", prog_name);
    printf("Discrete event simulation of multi-class Jackson networks with finite buffers.\n\n");
    printf("Options:\n");
    printf("  -w <time>      Warmup time\n");
    printf("  -r <time>      Run length\n");
    printf("  -n <count>     Number of replications\n");
    printf("  -s <seed>      Random seed\n");
    printf("  -m <file>      MCN format output file\n");
    printf("  -b <protocol>  Blocking protocol: BAS, BBS, or RS\n");
    printf("  -c <capacity>  Default buffer capacity (or 'inf')\n");
    printf("  -v             Verbose mode\n");
    printf("  -h             Show this help message\n\n");
    printf("Blocking Protocols:\n");
    printf("  BAS  Blocking After Service - server blocks if downstream full\n");
    printf("  BBS  Blocking Before Service - service delayed if downstream full\n");
    printf("  RS   Rejection/Loss - customers rejected when buffer full\n");
}

int main(int argc, char *argv[]) {
    int i, r;
    char *input_file = NULL;
    AggregateStats agg_stats;
    double **run_values;
    int nc, ns, num_metrics;
    char base_filename[256];
    char *dot;

    /* Parse command line arguments */
    for (i = 1; i < argc; i++) {
        if (argv[i][0] == '-') {
            switch (argv[i][1]) {
                case 'h':
                    print_usage(argv[0]);
                    return 0;
                case 'w':
                    if (++i < argc) sim_params.warmup_time = atof(argv[i]);
                    break;
                case 'r':
                    if (++i < argc) sim_params.run_length = atof(argv[i]);
                    break;
                case 'n':
                    if (++i < argc) sim_params.num_replications = atoi(argv[i]);
                    break;
                case 's':
                    if (++i < argc) sim_params.seed = (unsigned long)atol(argv[i]);
                    break;
                case 'm':
                    if (++i < argc) strncpy(sim_params.output_mcn_file, argv[i],
                                           sizeof(sim_params.output_mcn_file) - 1);
                    break;
                case 'b':
                    if (++i < argc) {
                        if (strcmp(argv[i], "BAS") == 0 || strcmp(argv[i], "bas") == 0)
                            network.blocking_protocol = BLOCKING_BAS;
                        else if (strcmp(argv[i], "BBS") == 0 || strcmp(argv[i], "bbs") == 0)
                            network.blocking_protocol = BLOCKING_BBS;
                        else if (strcmp(argv[i], "RS") == 0 || strcmp(argv[i], "rs") == 0)
                            network.blocking_protocol = BLOCKING_RS;
                    }
                    break;
                case 'c':
                    if (++i < argc) {
                        if (strcmp(argv[i], "inf") == 0 || strcmp(argv[i], "infinite") == 0)
                            network.default_buffer_capacity = INFINITE_BUFFER;
                        else
                            network.default_buffer_capacity = atoi(argv[i]);
                    }
                    break;
                case 'v':
                    sim_params.verbose = 1;
                    break;
                default:
                    fprintf(stderr, "Unknown option: %s\n", argv[i]);
                    return 1;
            }
        } else {
            input_file = argv[i];
        }
    }

    if (!input_file) {
        print_usage(argv[0]);
        return 1;
    }

    if (!parse_input_file(input_file)) {
        return 1;
    }

    /* Re-apply command line overrides (they were parsed before input file) */
    for (i = 1; i < argc; i++) {
        if (argv[i][0] == '-') {
            switch (argv[i][1]) {
                case 'w':
                    if (++i < argc) sim_params.warmup_time = atof(argv[i]);
                    break;
                case 'r':
                    if (++i < argc) sim_params.run_length = atof(argv[i]);
                    break;
                case 'n':
                    if (++i < argc) sim_params.num_replications = atoi(argv[i]);
                    break;
                case 's':
                    if (++i < argc) sim_params.seed = (unsigned long)atol(argv[i]);
                    break;
                case 'v':
                    sim_params.verbose = 1;
                    break;
                default:
                    break;
            }
        }
    }

    printf("Multi-Class Jackson Network Simulator (Finite Buffers)\n");
    printf("======================================================\n\n");
    printf("Loading network from: %s\n", input_file);
    printf("Stations: %d, Classes: %d\n", network.num_stations, network.num_classes);
    printf("Blocking protocol: ");
    switch (network.blocking_protocol) {
        case BLOCKING_BAS: printf("BAS\n"); break;
        case BLOCKING_BBS: printf("BBS\n"); break;
        case BLOCKING_RS: printf("RS\n"); break;
    }
    printf("Running %d replications...\n\n", sim_params.num_replications);

    nc = network.num_classes;
    ns = network.num_stations;
    num_metrics = 4 * nc + 3 * ns + nc * ns;

    /* Allocate run values array */
    run_values = (double **)malloc(sim_params.num_replications * sizeof(double *));
    if (!run_values) {
        fprintf(stderr, "Error: Failed to allocate run values array\n");
        return 1;
    }
    for (r = 0; r < sim_params.num_replications; r++) {
        run_values[r] = (double *)malloc(num_metrics * sizeof(double));
        if (!run_values[r]) {
            fprintf(stderr, "Error: Failed to allocate run values\n");
            return 1;
        }
    }

    /* Run replications — parallelized with OpenMP across threads when
       compiled with -fopenmp. See jackson_sim.c for rationale. */
#ifdef _OPENMP
    printf("[OpenMP] Using %d threads\n\n", omp_get_max_threads());
#endif

    rng_init(sim_params.seed);

#ifdef _OPENMP
    #pragma omp parallel copyin(network)
#endif
    {
#ifdef _OPENMP
        #pragma omp for schedule(dynamic)
#endif
        for (r = 0; r < sim_params.num_replications; r++) {
            RunStats local_stats;
            int ii, jj, idx_l;

            if (sim_params.verbose) {
                printf("Replication %d/%d...\n", r + 1, sim_params.num_replications);
            }

            /* Independent RNG stream per replication. */
            rng_init(sim_params.seed + (unsigned long)r);

            run_simulation(&local_stats);

            /* Store results */
            for (ii = 0; ii < nc; ii++) {
                /* Queue time */
                run_values[r][ii] = (local_stats.customers_served[ii] > 0) ?
                    local_stats.total_queue_time[ii] / local_stats.customers_served[ii] : 0.0;

                /* Sojourn time */
                run_values[r][nc + ii] = (local_stats.customers_served[ii] > 0) ?
                    local_stats.total_sojourn_time[ii] / local_stats.customers_served[ii] : 0.0;

                /* Throughput */
                run_values[r][2*nc + ii] = local_stats.customers_completed[ii] / sim_params.run_length;

                /* Rejection rate */
                run_values[r][3*nc + ii] = local_stats.customers_rejected[ii] / sim_params.run_length;
            }

            for (ii = 0; ii < ns; ii++) {
                /* Queue time at station */
                run_values[r][4*nc + ii] = (local_stats.customers_at_station[ii] > 0) ?
                    local_stats.total_queue_time_station[ii] / local_stats.customers_at_station[ii] : 0.0;

                /* Utilization */
                run_values[r][4*nc + ns + ii] = local_stats.busy_time[ii] / sim_params.run_length;

                /* Blocking probability (time fraction) */
                run_values[r][4*nc + 2*ns + ii] = local_stats.blocked_time[ii] / sim_params.run_length;
            }

            /* Class-station queue times */
            for (ii = 0; ii < nc; ii++) {
                for (jj = 0; jj < ns; jj++) {
                    idx_l = 4*nc + 3*ns + ii*ns + jj;
                    run_values[r][idx_l] = (local_stats.count_class_station[ii][jj] > 0) ?
                        local_stats.queue_time_class_station[ii][jj] / local_stats.count_class_station[ii][jj] : 0.0;
                }
            }
        }
    }

    /* Compute aggregate statistics */
    init_aggregate_stats(&agg_stats);
    compute_aggregate_stats(run_values, sim_params.num_replications, num_metrics, &agg_stats);

    /* Print results */
    print_results(&agg_stats);

    /* Write output files */
    strncpy(base_filename, input_file, sizeof(base_filename) - 1);
    base_filename[sizeof(base_filename) - 1] = '\0';
    dot = strrchr(base_filename, '.');
    if (dot) *dot = '\0';

    write_results_file(base_filename, &agg_stats);

    if (sim_params.output_mcn_file[0] != '\0') {
        write_mcn_output(sim_params.output_mcn_file, &agg_stats);
    }

    /* Cleanup */
    for (r = 0; r < sim_params.num_replications; r++) {
        free(run_values[r]);
    }
    free(run_values);

    return 0;
}
