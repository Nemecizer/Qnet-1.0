/*
 * jackson_sim.c - Discrete Event Simulation of Multi-Class Jackson Networks
 *
 * This program simulates a generalized multi-class Jackson network with
 * infinite buffers and collects performance statistics.
 *
 * Compile: gcc -o jackson_sim jackson_sim.c -lm
 * Usage:   ./jackson_sim input_file [options]
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <float.h>
#include <unistd.h>
#include <fcntl.h>
#include <pthread.h>

#ifdef _OPENMP
#include <omp.h>
#endif

#define QNET_RNG_IMPLEMENTATION
#include "../../common/rng.h"

/* Compact output mode (-c flag) */
static int compact_mode = 0;
static int saved_stdout_fd = -1;

/* Unified progress protocol shared with all Qnet solvers (-P PATH).
 *   First line of progress file = decimal total + '\n'; each completed
 *   unit appends one '.' byte. The wrapping shell parses the header
 *   for the denominator and uses (file_size - header_len) for the
 *   numerator. pthread_mutex protects against torn writes between
 *   OpenMP threads. */
static char progress_file_path[1024] = "";
static FILE *progress_fp = NULL;
static pthread_mutex_t progress_lock = PTHREAD_MUTEX_INITIALIZER;

static void progress_open(long total) {
    if (!progress_file_path[0]) return;
    progress_fp = fopen(progress_file_path, "wb");
    if (!progress_fp) return;
    fprintf(progress_fp, "%ld\n", total);
    fflush(progress_fp);
}

static void progress_tick(void) {
    if (!progress_fp) return;
    pthread_mutex_lock(&progress_lock);
    fputc('.', progress_fp);
    fflush(progress_fp);
    pthread_mutex_unlock(&progress_lock);
}

static void progress_close(void) {
    if (progress_fp) {
        fclose(progress_fp);
        progress_fp = NULL;
    }
}

static void compact_suppress_stdout(void) {
    int devnull;
    fflush(stdout);
    saved_stdout_fd = dup(STDOUT_FILENO);
    devnull = open("/dev/null", O_WRONLY);
    dup2(devnull, STDOUT_FILENO);
    close(devnull);
}

static void compact_restore_stdout(void) {
    fflush(stdout);
    dup2(saved_stdout_fd, STDOUT_FILENO);
    close(saved_stdout_fd);
    saved_stdout_fd = -1;
}

/* ============================================================================
 * CONSTANTS AND CONFIGURATION
 * ============================================================================ */

#define MAX_STATIONS     100
#define MAX_CLASSES      100
#define MAX_LINE_LEN     1024
#define INITIAL_HEAP_CAP 10000
#define RUN_VALUES_COLS  (3*MAX_CLASSES + 3*MAX_STATIONS + MAX_CLASSES*MAX_STATIONS + 3*MAX_CLASSES + MAX_STATIONS)

/* Distribution types */
typedef enum {
    DIST_NONE = 0,
    DIST_EXPONENTIAL,
    DIST_ERLANG,
    DIST_GAMMA,
    DIST_UNIFORM,
    DIST_DETERMINISTIC,
    DIST_HYPEREXP2,      /* 2-phase hyperexponential */
    DIST_LOGNORMAL,
    DIST_WEIBULL,
    DIST_PARETO
} DistType;

/* Event types */
typedef enum {
    EVENT_ARRIVAL = 0,
    EVENT_DEPARTURE
} EventType;

/* ============================================================================
 * DATA STRUCTURES
 * ============================================================================ */

/* Distribution specification */
typedef struct {
    DistType type;
    double param1;    /* Primary parameter (e.g., rate, mean) */
    double param2;    /* Secondary parameter (e.g., shape, variance) */
    double param3;    /* Tertiary parameter (for complex distributions) */
} Distribution;

/* Customer in the system */
typedef struct Customer {
    int id;                      /* Unique customer ID */
    int class_id;                /* Customer class */
    int original_class_id;       /* Class at system entry (for customer-class tracking) */
    double arrival_time;         /* Time entered system */
    double queue_entry_time;     /* Time entered current queue */
    double total_queue_time;     /* Accumulated queue time across all station visits */
    struct Customer *next;       /* Next in queue */
} Customer;

/* Station queue */
typedef struct {
    Customer *head;
    Customer *tail;
    int length;
} Queue;

/* Station in the network */
typedef struct {
    int id;
    Queue queue;
    int busy;                    /* Is server busy? */
    Customer *in_service;        /* Customer being served */
    double service_start_time;
} Station;

/* Event in the event list */
typedef struct {
    EventType type;
    double time;
    int class_id;        /* For arrivals: class of arriving customer */
    int station_id;      /* Station where event occurs */
    Customer *customer;  /* For departures: customer completing service */
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
    Distribution arrival_dist;     /* External arrival distribution */
    int arrival_station;           /* Station where external arrivals enter */
    double routing[MAX_CLASSES];   /* Routing probabilities to other classes */
    Distribution service_dist;     /* Service time distribution */
    int constituency_station;      /* Station where this class is served */
} Class;

/* Network configuration */
typedef struct {
    int num_stations;
    int num_classes;
    int num_customer_classes;  /* True customer classes (K); 0 = feature off */
    Station stations[MAX_STATIONS];
    Class classes[MAX_CLASSES];
} Network;

/* Statistics for a single run */
typedef struct {
    /* Per class statistics */
    double total_queue_time[MAX_CLASSES];
    double total_sojourn_time[MAX_CLASSES];  /* Queue + service at this class */
    int customers_served[MAX_CLASSES];       /* Completed service at this class */
    int customers_completed[MAX_CLASSES];    /* Left system from this class */
    int customers_arrived[MAX_CLASSES];

    /* Per station statistics */
    double total_queue_time_station[MAX_STATIONS];
    int customers_at_station[MAX_STATIONS];
    double busy_time[MAX_STATIONS];

    /* Per class-station statistics (queue time) */
    double queue_time_class_station[MAX_CLASSES][MAX_STATIONS];
    int count_class_station[MAX_CLASSES][MAX_STATIONS];

    /* Per customer-class statistics (aggregated across K×d sim classes) */
    double total_network_sojourn[MAX_CLASSES];  /* Sum of sojourn times of exited customers */
    double total_network_queue[MAX_CLASSES];    /* Sum of queue times of exited customers */
    int network_departures[MAX_CLASSES];        /* Count of exited customers per customer class */
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
    /* Mean queue times per class */
    double mean_queue_time[MAX_CLASSES];
    double var_queue_time[MAX_CLASSES];

    /* Mean system times per class */
    double mean_system_time[MAX_CLASSES];
    double var_system_time[MAX_CLASSES];

    /* Throughput per class */
    double mean_throughput[MAX_CLASSES];
    double var_throughput[MAX_CLASSES];

    /* Mean queue times per station */
    double mean_queue_time_station[MAX_STATIONS];
    double var_queue_time_station[MAX_STATIONS];

    /* Utilization per station */
    double mean_utilization[MAX_STATIONS];
    double var_utilization[MAX_STATIONS];

    /* Mean number of customers at station (queue length) */
    double mean_queue_length[MAX_STATIONS];
    double var_queue_length[MAX_STATIONS];

    /* Per-station throughput (customers completing service per unit time)
     * — needed to emit the standard Gamma_k / sojourn_k lines that the
     * other infinite solvers (bnet, bna_qna, bna_sbd) print. Sojourn is
     * derived in the print block via Little's Law. */
    double mean_throughput_station[MAX_STATIONS];
    double var_throughput_station[MAX_STATIONS];

    /* Queue time by class and station */
    double mean_queue_time_cs[MAX_CLASSES][MAX_STATIONS];
    double var_queue_time_cs[MAX_CLASSES][MAX_STATIONS];

    /* Per customer-class statistics (aggregated from K×d sim classes) */
    double mean_cust_sojourn[MAX_CLASSES];
    double var_cust_sojourn[MAX_CLASSES];
    double mean_cust_queue[MAX_CLASSES];
    double var_cust_queue[MAX_CLASSES];
    double mean_cust_throughput[MAX_CLASSES];
    double var_cust_throughput[MAX_CLASSES];
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

/* Random number generator state (linear congruential) */
static RNG rng_state;

/* OpenMP parallelization of the replication loop:
 *   `network`, `event_heap`, and the per-replication scalar state are made
 *   threadprivate so each worker thread has its own copy. `sim_params` is
 *   read-only after argv/input-file parsing, so it stays shared. At the
 *   start of the parallel region we `copyin(network)` to broadcast the
 *   master's parsed network into every worker's threadprivate copy.
 *   Each replication seeds its own RNG via rng_init(seed+r) for
 *   reproducibility and thread-independence. */
#ifdef _OPENMP
#pragma omp threadprivate(network, event_heap, current_time, next_customer_id, warmup_complete, rng_state)
#endif

/* ============================================================================
 * RANDOM NUMBER GENERATION
 * ============================================================================ */

/* Initialize RNG (xoshiro256** seeded via SplitMix64; period 2^256-1) */
void rng_init(unsigned long seed) {
    rng_seed(&rng_state, (uint64_t)seed);
}

/* Generate uniform random number in (0, 1) */
double rng_uniform(void) {
    return rng_next_double(&rng_state);
}

/* Generate uniform random number in [a, b) */
double rng_uniform_range(double a, double b) {
    return a + (b - a) * rng_uniform();
}

/* Generate exponential random variate with rate lambda */
double rng_exponential(double lambda) {
    double u;
    do {
        u = rng_uniform();
    } while (u == 0.0);
    return -log(u) / lambda;
}

/* Generate Erlang random variate (shape k, rate lambda) */
double rng_erlang(int k, double lambda) {
    double sum = 0.0;
    int i;
    for (i = 0; i < k; i++) {
        sum += rng_exponential(lambda);
    }
    return sum;
}

/* Generate gamma random variate using Marsaglia and Tsang's method */
double rng_gamma(double shape, double scale) {
    double d, c, x, v, u;

    if (shape < 1.0) {
        /* Use Ahrens-Dieter method for shape < 1 */
        return rng_gamma(1.0 + shape, scale) * pow(rng_uniform(), 1.0 / shape);
    }

    d = shape - 1.0/3.0;
    c = 1.0 / sqrt(9.0 * d);

    while (1) {
        do {
            /* Box-Muller for standard normal */
            double u1 = rng_uniform();
            double u2 = rng_uniform();
            x = sqrt(-2.0 * log(u1)) * cos(2.0 * M_PI * u2);
            v = 1.0 + c * x;
        } while (v <= 0.0);

        v = v * v * v;
        u = rng_uniform();

        if (u < 1.0 - 0.0331 * (x * x) * (x * x)) {
            return d * v * scale;
        }

        if (log(u) < 0.5 * x * x + d * (1.0 - v + log(v))) {
            return d * v * scale;
        }
    }
}

/* Generate lognormal random variate */
double rng_lognormal(double mu, double sigma) {
    double u1 = rng_uniform();
    double u2 = rng_uniform();
    double z = sqrt(-2.0 * log(u1)) * cos(2.0 * M_PI * u2);
    return exp(mu + sigma * z);
}

/* Generate Weibull random variate */
double rng_weibull(double shape, double scale) {
    double u;
    do {
        u = rng_uniform();
    } while (u == 0.0);
    return scale * pow(-log(u), 1.0 / shape);
}

/* Generate Pareto random variate */
double rng_pareto(double shape, double scale) {
    double u;
    do {
        u = rng_uniform();
    } while (u == 0.0);
    return scale / pow(u, 1.0 / shape);
}

/* Generate 2-phase hyperexponential */
double rng_hyperexp2(double p, double lambda1, double lambda2) {
    if (rng_uniform() < p) {
        return rng_exponential(lambda1);
    } else {
        return rng_exponential(lambda2);
    }
}

/* Generate random variate from distribution */
double generate_from_dist(Distribution *dist) {
    switch (dist->type) {
        case DIST_NONE:
            return -1.0;  /* No distribution - invalid */

        case DIST_EXPONENTIAL:
            /* param1 = rate (lambda) */
            return rng_exponential(dist->param1);

        case DIST_ERLANG:
            /* param1 = shape (k), param2 = rate (lambda) */
            return rng_erlang((int)dist->param1, dist->param2);

        case DIST_GAMMA:
            /* param1 = shape (alpha), param2 = scale (beta) */
            return rng_gamma(dist->param1, dist->param2);

        case DIST_UNIFORM:
            /* param1 = min, param2 = max */
            return rng_uniform_range(dist->param1, dist->param2);

        case DIST_DETERMINISTIC:
            /* param1 = constant value */
            return dist->param1;

        case DIST_HYPEREXP2:
            /* param1 = p, param2 = lambda1, param3 = lambda2 */
            return rng_hyperexp2(dist->param1, dist->param2, dist->param3);

        case DIST_LOGNORMAL:
            /* param1 = mu (log-mean), param2 = sigma (log-std) */
            return rng_lognormal(dist->param1, dist->param2);

        case DIST_WEIBULL:
            /* param1 = shape, param2 = scale */
            return rng_weibull(dist->param1, dist->param2);

        case DIST_PARETO:
            /* param1 = shape, param2 = scale (min value) */
            return rng_pareto(dist->param1, dist->param2);

        default:
            fprintf(stderr, "Error: Unknown distribution type %d\n", dist->type);
            return 1.0;
    }
}

/* Calculate mean of distribution */
double dist_mean(Distribution *dist) {
    switch (dist->type) {
        case DIST_NONE:
            return 0.0;
        case DIST_EXPONENTIAL:
            return 1.0 / dist->param1;
        case DIST_ERLANG:
            return dist->param1 / dist->param2;
        case DIST_GAMMA:
            return dist->param1 * dist->param2;
        case DIST_UNIFORM:
            return (dist->param1 + dist->param2) / 2.0;
        case DIST_DETERMINISTIC:
            return dist->param1;
        case DIST_HYPEREXP2: {
            double p = dist->param1;
            return p / dist->param2 + (1.0 - p) / dist->param3;
        }
        case DIST_LOGNORMAL:
            return exp(dist->param1 + dist->param2 * dist->param2 / 2.0);
        case DIST_WEIBULL:
            return dist->param2 * tgamma(1.0 + 1.0 / dist->param1);
        case DIST_PARETO:
            if (dist->param1 > 1.0)
                return dist->param1 * dist->param2 / (dist->param1 - 1.0);
            return INFINITY;
        default:
            return 1.0;
    }
}

/* Calculate SCV (squared coefficient of variation) of distribution */
double dist_scv(Distribution *dist) {
    double mean, var;

    switch (dist->type) {
        case DIST_NONE:
            return 0.0;

        case DIST_EXPONENTIAL:
            return 1.0;  /* SCV of exponential is always 1 */

        case DIST_ERLANG:
            return 1.0 / dist->param1;  /* SCV = 1/k */

        case DIST_GAMMA:
            return 1.0 / dist->param1;  /* SCV = 1/alpha */

        case DIST_UNIFORM:
            mean = (dist->param1 + dist->param2) / 2.0;
            var = (dist->param2 - dist->param1) * (dist->param2 - dist->param1) / 12.0;
            return var / (mean * mean);

        case DIST_DETERMINISTIC:
            return 0.0;  /* No variance */

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

        default:
            return 1.0;
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

    /* Expand if needed */
    if (h->size >= h->capacity) {
        h->capacity *= 2;
        h->events = (Event *)realloc(h->events, h->capacity * sizeof(Event));
        if (!h->events) {
            fprintf(stderr, "Error: Failed to expand event heap\n");
            exit(1);
        }
    }

    /* Add at end and bubble up */
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
            /* Find smaller child */
            if (child + 1 < h->size &&
                h->events[child + 1].time < h->events[child].time) {
                child++;
            }
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
 * QUEUE OPERATIONS
 * ============================================================================ */

void queue_init(Queue *q) {
    q->head = q->tail = NULL;
    q->length = 0;
}

void queue_enqueue(Queue *q, Customer *c) {
    c->next = NULL;
    if (q->tail) {
        q->tail->next = c;
    } else {
        q->head = c;
    }
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
    while ((c = queue_dequeue(q)) != NULL) {
        free(c);
    }
}

/* ============================================================================
 * INPUT PARSING
 * ============================================================================ */

/* Parse distribution from string */
int parse_distribution(char *str, Distribution *dist) {
    char type_str[64];
    int n;

    /* Default */
    dist->type = DIST_NONE;
    dist->param1 = dist->param2 = dist->param3 = 0.0;

    if (sscanf(str, "%63s%n", type_str, &n) != 1) {
        return 0;
    }

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

/* Parse input file */
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
    network.num_customer_classes = 0;

    /* Initialize all classes */
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

        /* Skip leading whitespace */
        while (*p == ' ' || *p == '\t') p++;

        /* Skip comments and empty lines */
        if (*p == '#' || *p == '\n' || *p == '\0') continue;

        /* Remove trailing newline */
        {
            char *nl = strchr(p, '\n');
            if (nl) *nl = '\0';
        }

        /* Parse key-value pairs */
        if (sscanf(p, "%63s", key) != 1) continue;

        /* Get value after key */
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
                network.stations[i].busy = 0;
                network.stations[i].in_service = NULL;
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
        else if (strcmp(key, "customer_classes") == 0) {
            network.num_customer_classes = atoi(value);
        }
        else if (strcmp(key, "verbose") == 0) {
            sim_params.verbose = atoi(value);
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
                /* Parse routing probabilities */
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

    /* Validate */
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

/* Schedule an arrival event */
void schedule_arrival(int class_id, double time) {
    Event e;
    e.type = EVENT_ARRIVAL;
    e.time = time;
    e.class_id = class_id;
    e.station_id = network.classes[class_id].constituency_station;
    e.customer = NULL;
    heap_push(&event_heap, e);
}

/* Schedule a departure event */
void schedule_departure(int station_id, Customer *c, double time) {
    Event e;
    e.type = EVENT_DEPARTURE;
    e.time = time;
    e.class_id = c->class_id;
    e.station_id = station_id;
    e.customer = c;
    heap_push(&event_heap, e);
}

/* Initialize simulation */
void sim_init(void) {
    int i;

    current_time = 0.0;
    next_customer_id = 0;
    warmup_complete = 0;

    heap_init(&event_heap);

    /* Initialize stations */
    for (i = 0; i < network.num_stations; i++) {
        queue_init(&network.stations[i].queue);
        network.stations[i].busy = 0;
        network.stations[i].in_service = NULL;
        network.stations[i].service_start_time = 0.0;
    }

    /* Schedule initial arrivals for each class with external arrivals */
    for (i = 0; i < network.num_classes; i++) {
        if (network.classes[i].arrival_dist.type != DIST_NONE) {
            double interarrival = generate_from_dist(&network.classes[i].arrival_dist);
            schedule_arrival(i, interarrival);
        }
    }
}

/* Clean up simulation */
void sim_cleanup(void) {
    int i;

    for (i = 0; i < network.num_stations; i++) {
        queue_clear(&network.stations[i].queue);
        if (network.stations[i].in_service) {
            free(network.stations[i].in_service);
            network.stations[i].in_service = NULL;
        }
    }

    heap_free(&event_heap);
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

    /* Create new customer */
    c = (Customer *)malloc(sizeof(Customer));
    if (!c) {
        fprintf(stderr, "Error: Failed to allocate customer\n");
        exit(1);
    }
    c->id = next_customer_id++;
    c->class_id = e->class_id;
    c->original_class_id = e->class_id;
    c->arrival_time = current_time;
    c->queue_entry_time = current_time;
    c->total_queue_time = 0.0;
    c->next = NULL;

    /* Record arrival if past warmup */
    if (warmup_complete) {
        stats->customers_arrived[e->class_id]++;
    }

    /* Schedule next external arrival for this class */
    if (cls->arrival_dist.type != DIST_NONE) {
        double interarrival = generate_from_dist(&cls->arrival_dist);
        schedule_arrival(e->class_id, current_time + interarrival);
    }

    /* If server is idle, start service immediately */
    if (!stn->busy) {
        double service_time = generate_from_dist(&cls->service_dist);
        stn->busy = 1;
        stn->in_service = c;
        stn->service_start_time = current_time;
        schedule_departure(station_id, c, current_time + service_time);
    } else {
        /* Join queue */
        queue_enqueue(&stn->queue, c);
    }
}

/* Process departure event */
void process_departure(Event *e, RunStats *stats) {
    Customer *c = e->customer;
    Class *cls = &network.classes[c->class_id];
    Station *stn = &network.stations[e->station_id];
    double queue_time;
    int next_class;
    double u;
    double cumulative;
    int i;

    /* Calculate queue time (excluding service) */
    queue_time = stn->service_start_time - c->queue_entry_time;

    /* Record statistics if past warmup */
    if (warmup_complete) {
        double service_time = current_time - stn->service_start_time;
        double sojourn_time = queue_time + service_time;

        stats->total_queue_time[c->class_id] += queue_time;
        stats->total_sojourn_time[c->class_id] += sojourn_time;
        stats->customers_served[c->class_id]++;
        stats->queue_time_class_station[c->class_id][e->station_id] += queue_time;
        stats->count_class_station[c->class_id][e->station_id]++;
        stats->total_queue_time_station[e->station_id] += queue_time;
        stats->customers_at_station[e->station_id]++;
        stats->busy_time[e->station_id] += service_time;

        /* Accumulate queue time on customer for customer-class tracking */
        c->total_queue_time += queue_time;
    }

    /* Determine next class based on routing probabilities */
    u = rng_uniform();
    cumulative = 0.0;
    next_class = -1;  /* -1 means leave system */

    for (i = 0; i < network.num_classes; i++) {
        cumulative += cls->routing[i];
        if (u < cumulative) {
            next_class = i;
            break;
        }
    }

    /* Route customer */
    if (next_class >= 0) {
        /* Move to next class (possibly at different station) */
        Class *next_cls = &network.classes[next_class];
        Station *next_stn = &network.stations[next_cls->constituency_station];

        c->class_id = next_class;
        c->queue_entry_time = current_time;

        if (!next_stn->busy) {
            double service_time = generate_from_dist(&next_cls->service_dist);
            next_stn->busy = 1;
            next_stn->in_service = c;
            next_stn->service_start_time = current_time;
            schedule_departure(next_cls->constituency_station, c, current_time + service_time);
        } else {
            queue_enqueue(&next_stn->queue, c);
        }
    } else {
        /* Customer leaves system */
        if (warmup_complete) {
            stats->customers_completed[e->class_id]++;

            /* Record per-customer-class stats if feature is active */
            if (network.num_customer_classes > 0) {
                int k = c->original_class_id / network.num_stations;
                stats->total_network_sojourn[k] += current_time - c->arrival_time;
                stats->total_network_queue[k] += c->total_queue_time;
                stats->network_departures[k]++;
            }
        }
        free(c);
    }

    /* Start serving next customer in queue, if any */
    stn->in_service = NULL;
    stn->busy = 0;

    if (!queue_is_empty(&stn->queue)) {
        Customer *next_c = queue_dequeue(&stn->queue);
        Class *next_cls = &network.classes[next_c->class_id];
        double service_time = generate_from_dist(&next_cls->service_dist);

        stn->busy = 1;
        stn->in_service = next_c;
        stn->service_start_time = current_time;
        schedule_departure(e->station_id, next_c, current_time + service_time);
    }
}

/* Initialize run statistics */
void init_run_stats(RunStats *stats) {
    int i, j;
    for (i = 0; i < MAX_CLASSES; i++) {
        stats->total_queue_time[i] = 0.0;
        stats->total_sojourn_time[i] = 0.0;
        stats->customers_served[i] = 0;
        stats->customers_completed[i] = 0;
        stats->customers_arrived[i] = 0;
        stats->total_network_sojourn[i] = 0.0;
        stats->total_network_queue[i] = 0.0;
        stats->network_departures[i] = 0;
    }
    for (i = 0; i < MAX_STATIONS; i++) {
        stats->total_queue_time_station[i] = 0.0;
        stats->customers_at_station[i] = 0;
        stats->busy_time[i] = 0.0;
    }
    for (i = 0; i < MAX_CLASSES; i++) {
        for (j = 0; j < MAX_STATIONS; j++) {
            stats->queue_time_class_station[i][j] = 0.0;
            stats->count_class_station[i][j] = 0;
        }
    }
}

/* Run a single simulation replication */
void run_simulation(RunStats *stats) {
    Event e;
    double total_time = sim_params.warmup_time + sim_params.run_length;

    sim_init();
    init_run_stats(stats);

    while (!heap_empty(&event_heap)) {
        e = heap_pop(&event_heap);

        if (e.time > total_time) break;

        current_time = e.time;

        /* Check if warmup is complete */
        if (!warmup_complete && current_time >= sim_params.warmup_time) {
            warmup_complete = 1;
            init_run_stats(stats);  /* Reset statistics */
        }

        if (e.type == EVENT_ARRIVAL) {
            process_arrival(&e, stats);
        } else {
            process_departure(&e, stats);
        }
    }

    sim_cleanup();
}

/* ============================================================================
 * STATISTICS AND OUTPUT
 * ============================================================================ */

/* Initialize aggregate statistics */
void init_aggregate_stats(AggregateStats *agg) {
    int i, j;
    for (i = 0; i < MAX_CLASSES; i++) {
        agg->mean_queue_time[i] = 0.0;
        agg->var_queue_time[i] = 0.0;
        agg->mean_system_time[i] = 0.0;
        agg->var_system_time[i] = 0.0;
        agg->mean_throughput[i] = 0.0;
        agg->var_throughput[i] = 0.0;
        agg->mean_cust_sojourn[i] = 0.0;
        agg->var_cust_sojourn[i] = 0.0;
        agg->mean_cust_queue[i] = 0.0;
        agg->var_cust_queue[i] = 0.0;
        agg->mean_cust_throughput[i] = 0.0;
        agg->var_cust_throughput[i] = 0.0;
    }
    for (i = 0; i < MAX_STATIONS; i++) {
        agg->mean_queue_time_station[i] = 0.0;
        agg->var_queue_time_station[i] = 0.0;
        agg->mean_utilization[i] = 0.0;
        agg->var_utilization[i] = 0.0;
        agg->mean_queue_length[i] = 0.0;
        agg->var_queue_length[i] = 0.0;
        agg->mean_throughput_station[i] = 0.0;
        agg->var_throughput_station[i] = 0.0;
    }
    for (i = 0; i < MAX_CLASSES; i++) {
        for (j = 0; j < MAX_STATIONS; j++) {
            agg->mean_queue_time_cs[i][j] = 0.0;
            agg->var_queue_time_cs[i][j] = 0.0;
        }
    }
}

/* Compute aggregate statistics from run data */
void compute_aggregate_stats(double run_values[][RUN_VALUES_COLS],
                             int num_runs, AggregateStats *agg) {
    int i, j, r;
    int idx;
    double sum, sum_sq, mean, var;
    int nc = network.num_classes;
    int ns = network.num_stations;

    /* Per-class statistics */
    for (i = 0; i < nc; i++) {
        /* Queue time */
        idx = i;
        sum = sum_sq = 0.0;
        for (r = 0; r < num_runs; r++) {
            sum += run_values[r][idx];
            sum_sq += run_values[r][idx] * run_values[r][idx];
        }
        mean = sum / num_runs;
        var = (sum_sq - sum * sum / num_runs) / (num_runs - 1);
        if (var < 0) var = 0;
        agg->mean_queue_time[i] = mean;
        agg->var_queue_time[i] = var;

        /* System time */
        idx = nc + i;
        sum = sum_sq = 0.0;
        for (r = 0; r < num_runs; r++) {
            sum += run_values[r][idx];
            sum_sq += run_values[r][idx] * run_values[r][idx];
        }
        mean = sum / num_runs;
        var = (sum_sq - sum * sum / num_runs) / (num_runs - 1);
        if (var < 0) var = 0;
        agg->mean_system_time[i] = mean;
        agg->var_system_time[i] = var;

        /* Throughput */
        idx = 2 * nc + i;
        sum = sum_sq = 0.0;
        for (r = 0; r < num_runs; r++) {
            sum += run_values[r][idx];
            sum_sq += run_values[r][idx] * run_values[r][idx];
        }
        mean = sum / num_runs;
        var = (sum_sq - sum * sum / num_runs) / (num_runs - 1);
        if (var < 0) var = 0;
        agg->mean_throughput[i] = mean;
        agg->var_throughput[i] = var;
    }

    /* Per-station statistics */
    for (i = 0; i < ns; i++) {
        /* Queue time at station */
        idx = 3 * nc + i;
        sum = sum_sq = 0.0;
        for (r = 0; r < num_runs; r++) {
            sum += run_values[r][idx];
            sum_sq += run_values[r][idx] * run_values[r][idx];
        }
        mean = sum / num_runs;
        var = (sum_sq - sum * sum / num_runs) / (num_runs - 1);
        if (var < 0) var = 0;
        agg->mean_queue_time_station[i] = mean;
        agg->var_queue_time_station[i] = var;

        /* Utilization */
        idx = 3 * nc + ns + i;
        sum = sum_sq = 0.0;
        for (r = 0; r < num_runs; r++) {
            sum += run_values[r][idx];
            sum_sq += run_values[r][idx] * run_values[r][idx];
        }
        mean = sum / num_runs;
        var = (sum_sq - sum * sum / num_runs) / (num_runs - 1);
        if (var < 0) var = 0;
        agg->mean_utilization[i] = mean;
        agg->var_utilization[i] = var;

        /* Queue length (mean number of customers at station) */
        idx = 3 * nc + 2 * ns + i;
        sum = sum_sq = 0.0;
        for (r = 0; r < num_runs; r++) {
            sum += run_values[r][idx];
            sum_sq += run_values[r][idx] * run_values[r][idx];
        }
        mean = sum / num_runs;
        var = (sum_sq - sum * sum / num_runs) / (num_runs - 1);
        if (var < 0) var = 0;
        agg->mean_queue_length[i] = mean;
        agg->var_queue_length[i] = var;

        /* Per-station throughput (departures per unit time). Stored at
         * a fixed offset past the customer-class section. */
        idx = 3 * nc + 3 * ns + nc * ns + 3 * MAX_CLASSES + i;
        sum = sum_sq = 0.0;
        for (r = 0; r < num_runs; r++) {
            sum += run_values[r][idx];
            sum_sq += run_values[r][idx] * run_values[r][idx];
        }
        mean = sum / num_runs;
        var = (num_runs > 1)
            ? (sum_sq - sum * sum / num_runs) / (num_runs - 1)
            : 0.0;
        if (var < 0) var = 0;
        agg->mean_throughput_station[i] = mean;
        agg->var_throughput_station[i] = var;
    }

    /* Per class-station queue times */
    for (i = 0; i < nc; i++) {
        for (j = 0; j < ns; j++) {
            idx = 3 * nc + 3 * ns + i * ns + j;
            sum = sum_sq = 0.0;
            for (r = 0; r < num_runs; r++) {
                sum += run_values[r][idx];
                sum_sq += run_values[r][idx] * run_values[r][idx];
            }
            mean = sum / num_runs;
            var = (sum_sq - sum * sum / num_runs) / (num_runs - 1);
            if (var < 0) var = 0;
            agg->mean_queue_time_cs[i][j] = mean;
            agg->var_queue_time_cs[i][j] = var;
        }
    }

    /* Per customer-class statistics */
    if (network.num_customer_classes > 0) {
        int nk = network.num_customer_classes;
        int base = 3 * nc + 3 * ns + nc * ns;

        for (i = 0; i < nk; i++) {
            /* Mean network sojourn time */
            idx = base + i;
            sum = sum_sq = 0.0;
            for (r = 0; r < num_runs; r++) {
                sum += run_values[r][idx];
                sum_sq += run_values[r][idx] * run_values[r][idx];
            }
            mean = sum / num_runs;
            var = (sum_sq - sum * sum / num_runs) / (num_runs - 1);
            if (var < 0) var = 0;
            agg->mean_cust_sojourn[i] = mean;
            agg->var_cust_sojourn[i] = var;

            /* Mean network queue time */
            idx = base + nk + i;
            sum = sum_sq = 0.0;
            for (r = 0; r < num_runs; r++) {
                sum += run_values[r][idx];
                sum_sq += run_values[r][idx] * run_values[r][idx];
            }
            mean = sum / num_runs;
            var = (sum_sq - sum * sum / num_runs) / (num_runs - 1);
            if (var < 0) var = 0;
            agg->mean_cust_queue[i] = mean;
            agg->var_cust_queue[i] = var;

            /* Throughput */
            idx = base + 2 * nk + i;
            sum = sum_sq = 0.0;
            for (r = 0; r < num_runs; r++) {
                sum += run_values[r][idx];
                sum_sq += run_values[r][idx] * run_values[r][idx];
            }
            mean = sum / num_runs;
            var = (sum_sq - sum * sum / num_runs) / (num_runs - 1);
            if (var < 0) var = 0;
            agg->mean_cust_throughput[i] = mean;
            agg->var_cust_throughput[i] = var;
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

/* Print simulation results */
void print_results(AggregateStats *agg) {
    int i, j;
    double ci95;  /* 95% confidence interval half-width */

    printf("\n");
    printf("===============================================================================\n");
    printf("                     MULTI-CLASS JACKSON NETWORK SIMULATION RESULTS\n");
    printf("===============================================================================\n\n");

    printf("Simulation Parameters:\n");
    printf("  Warmup time:    %.2f\n", sim_params.warmup_time);
    printf("  Run length:     %.2f\n", sim_params.run_length);
    printf("  Replications:   %d\n", sim_params.num_replications);
    printf("  Random seed:    %lu\n", sim_params.seed);
    printf("\n");

    printf("Network Configuration:\n");
    printf("  Stations:       %d\n", network.num_stations);
    printf("  Classes:        %d\n", network.num_classes);
    printf("\n");

    /* Per-class results */
    printf("-------------------------------------------------------------------------------\n");
    printf("PER-CLASS STATISTICS\n");
    printf("-------------------------------------------------------------------------------\n\n");

    printf("%-8s %15s %15s %15s %15s\n",
           "Class", "Mean Queue", "95% CI", "Mean Sojourn", "Throughput");
    printf("%-8s %15s %15s %15s %15s\n",
           "", "Time", "Half-Width", "Time", "(exits/time)");
    printf("-------------------------------------------------------------------------------\n");

    for (i = 0; i < network.num_classes; i++) {
        ci95 = jackson_ci_half_width(agg->var_queue_time[i], sim_params.num_replications);
        printf("%-8d %15.6f %15.6f %15.6f %15.6f\n",
               i, agg->mean_queue_time[i], ci95,
               agg->mean_system_time[i], agg->mean_throughput[i]);
    }
    printf("\n");

    /* Per-station results */
    printf("-------------------------------------------------------------------------------\n");
    printf("PER-STATION STATISTICS\n");
    printf("-------------------------------------------------------------------------------\n\n");

    printf("%-8s %15s %15s %15s %15s\n",
           "Station", "Mean Queue", "95% CI", "Utilization", "95% CI");
    printf("%-8s %15s %15s %15s %15s\n",
           "", "Time", "Half-Width", "", "Half-Width");
    printf("-------------------------------------------------------------------------------\n");

    for (i = 0; i < network.num_stations; i++) {
        double ci_queue = jackson_ci_half_width(
            agg->var_queue_time_station[i], sim_params.num_replications);
        double ci_util = jackson_ci_half_width(
            agg->var_utilization[i], sim_params.num_replications);
        printf("%-8d %15.6f %15.6f %15.6f %15.6f\n",
               i, agg->mean_queue_time_station[i], ci_queue,
               agg->mean_utilization[i], ci_util);
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

    /* Customer class statistics (aggregated from K×d sim classes) */
    if (network.num_customer_classes > 0) {
        int k;
        int nk = network.num_customer_classes;
        int d = network.num_stations;

        printf("-------------------------------------------------------------------------------\n");
        printf("CUSTOMER CLASS STATISTICS (Aggregated from %dx%d sim classes)\n", nk, d);
        printf("-------------------------------------------------------------------------------\n\n");

        printf("%-10s %15s %15s %15s %15s\n",
               "Customer", "Mean Queue", "95% CI", "Mean Sojourn", "Throughput");
        printf("%-10s %15s %15s %15s %15s\n",
               "Class", "Time (total)", "Half-Width", "Time (total)", "(exits/time)");
        printf("-------------------------------------------------------------------------------\n");

        for (k = 0; k < nk; k++) {
            double ci_q = jackson_ci_half_width(
                agg->var_cust_queue[k], sim_params.num_replications);
            printf("%-10d %15.6f %15.6f %15.6f %15.6f\n",
                   k + 1, agg->mean_cust_queue[k], ci_q,
                   agg->mean_cust_sojourn[k], agg->mean_cust_throughput[k]);
        }
        printf("\n");

        /* Per-station breakdown for each customer class */
        printf("%-10s", "Cust.Class");
        for (j = 0; j < d; j++) {
            printf(" %12s%d", "Station ", j + 1);
        }
        printf("\n");
        printf("-------------------------------------------------------------------------------\n");

        for (k = 0; k < nk; k++) {
            printf("%-10d", k + 1);
            for (j = 0; j < d; j++) {
                /* Sim class index for customer class k at station j */
                int sim_class = k * d + j;
                printf(" %13.6f", agg->mean_queue_time_cs[sim_class][j]);
            }
            printf("\n");
        }
        printf("\n");
    }
}

/* Write MCN format output file */
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

    /* Write header: number of stations and classes */
    fprintf(fp, "%d\n", d);
    fprintf(fp, "%d\n", c);

    /* For each class, write:
     * - alpha: exogenous arrival rate (rate, not mean interarrival)
     * - sca: SCV of interarrival time
     * - tau: mean service time
     * - scs: SCV of service time
     * - constituency station (1-indexed)
     * - routing probabilities
     */
    for (i = 0; i < c; i++) {
        Class *cls = &network.classes[i];
        double alpha, sca, tau, scs;

        /* Arrival rate and SCV */
        if (cls->arrival_dist.type != DIST_NONE) {
            alpha = 1.0 / dist_mean(&cls->arrival_dist);
            sca = dist_scv(&cls->arrival_dist);
        } else {
            alpha = 0.0;
            sca = 0.0;
        }

        /* Service time mean and SCV */
        tau = dist_mean(&cls->service_dist);
        scs = dist_scv(&cls->service_dist);

        fprintf(fp, "%.6f\n", alpha);
        fprintf(fp, "%.6f\n", sca);
        fprintf(fp, "%.6f\n", tau);
        fprintf(fp, "%.6f\n", scs);
        fprintf(fp, "%d\n", cls->constituency_station + 1);  /* 1-indexed */

        /* Routing probabilities */
        for (j = 0; j < c; j++) {
            fprintf(fp, "%.6f", cls->routing[j]);
            if (j < c - 1) fprintf(fp, " ");
        }
        fprintf(fp, "\n");
    }

    /* Approximation degree */
    fprintf(fp, "5\n");

    fclose(fp);
    printf("MCN format output written to '%s'\n", filename);
}

/* Write detailed simulation results to file */
void write_results_file(const char *base_filename, AggregateStats *agg) {
    FILE *fp;
    char filename[512];
    int i, j;

    snprintf(filename, sizeof(filename), "%s_results.txt", base_filename);

    fp = fopen(filename, "w");
    if (!fp) {
        fprintf(stderr, "Warning: Cannot open results file '%s'\n", filename);
        return;
    }

    fprintf(fp, "# Multi-Class Jackson Network Simulation Results\n");
    fprintf(fp, "# Generated by jackson_sim\n\n");

    fprintf(fp, "# Simulation Parameters\n");
    fprintf(fp, "warmup_time: %.2f\n", sim_params.warmup_time);
    fprintf(fp, "run_length: %.2f\n", sim_params.run_length);
    fprintf(fp, "replications: %d\n", sim_params.num_replications);
    fprintf(fp, "seed: %lu\n\n", sim_params.seed);

    fprintf(fp, "# Network Configuration\n");
    fprintf(fp, "stations: %d\n", network.num_stations);
    fprintf(fp, "classes: %d\n\n", network.num_classes);

    fprintf(fp, "# Per-Class Results\n");
    fprintf(fp, "# class mean_queue_time var_queue_time mean_system_time var_system_time throughput var_throughput\n");
    for (i = 0; i < network.num_classes; i++) {
        fprintf(fp, "%d %.6f %.6f %.6f %.6f %.6f %.6f\n",
                i, agg->mean_queue_time[i], agg->var_queue_time[i],
                agg->mean_system_time[i], agg->var_system_time[i],
                agg->mean_throughput[i], agg->var_throughput[i]);
    }
    fprintf(fp, "\n");

    fprintf(fp, "# Per-Station Results\n");
    fprintf(fp, "# station mean_queue_time var_queue_time mean_utilization var_utilization\n");
    for (i = 0; i < network.num_stations; i++) {
        fprintf(fp, "%d %.6f %.6f %.6f %.6f\n",
                i, agg->mean_queue_time_station[i], agg->var_queue_time_station[i],
                agg->mean_utilization[i], agg->var_utilization[i]);
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

    /* Per customer-class results */
    if (network.num_customer_classes > 0) {
        int k;
        int nk = network.num_customer_classes;
        fprintf(fp, "\n# Per Customer-Class Results (aggregated from %dx%d sim classes)\n",
                nk, network.num_stations);
        fprintf(fp, "# customer_class mean_queue_time var_queue_time mean_sojourn_time var_sojourn_time throughput var_throughput\n");
        for (k = 0; k < nk; k++) {
            fprintf(fp, "%d %.6f %.6f %.6f %.6f %.6f %.6f\n",
                    k, agg->mean_cust_queue[k], agg->var_cust_queue[k],
                    agg->mean_cust_sojourn[k], agg->var_cust_sojourn[k],
                    agg->mean_cust_throughput[k], agg->var_cust_throughput[k]);
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
    printf("Discrete event simulation of multi-class Jackson networks.\n\n");
    printf("Options:\n");
    printf("  -c             Compact output (algorithm name + means only)\n");
    printf("  -w <time>      Warmup time (override input file)\n");
    printf("  -r <time>      Run length (override input file)\n");
    printf("  -n <count>     Number of replications (override input file)\n");
    printf("  -s <seed>      Random seed (override input file)\n");
    printf("  -m <file>      MCN format output file (override input file)\n");
    printf("  -v             Verbose mode\n");
    printf("  -P <file>      Progress file: append one byte per completed replication\n");
    printf("  -h             Show this help message\n\n");
    printf("Input file format:\n");
    printf("  stations <n>             Number of stations\n");
    printf("  classes <n>              Number of customer classes\n");
    printf("  warmup <time>            Warmup time before collecting statistics\n");
    printf("  run_length <time>        Simulation run length\n");
    printf("  replications <n>         Number of independent replications\n");
    printf("  seed <n>                 Random number generator seed\n");
    printf("  mcn_output <file>        Output file in MCN format\n\n");
    printf("  class <id>               Start class definition (0-indexed)\n");
    printf("    arrival <dist>         External arrival distribution\n");
    printf("    station <id>           Constituency station (0-indexed)\n");
    printf("    service <dist>         Service time distribution\n");
    printf("    routing <p0> <p1> ...  Routing probabilities to other classes\n");
    printf("  end_class                End class definition\n\n");
    printf("Distribution formats:\n");
    printf("  exponential <rate>           Exponential with given rate\n");
    printf("  erlang <k> <rate>            Erlang-k with given rate\n");
    printf("  gamma <shape> <scale>        Gamma distribution\n");
    printf("  uniform <min> <max>          Uniform distribution\n");
    printf("  deterministic <value>        Constant value\n");
    printf("  hyperexp2 <p> <l1> <l2>      2-phase hyperexponential\n");
    printf("  lognormal <mu> <sigma>       Log-normal distribution\n");
    printf("  weibull <shape> <scale>      Weibull distribution\n");
    printf("  pareto <shape> <scale>       Pareto distribution\n");
    printf("  none                         No arrivals (for internal classes)\n");
}

int main(int argc, char *argv[]) {
    int i, r;
    char *input_file = NULL;
    AggregateStats agg_stats;
    double (*run_values)[RUN_VALUES_COLS];
    int nc, ns;
    char base_filename[256];
    char *dot;

    /* Parse command line arguments — save CLI overrides to apply after
       input file parsing (which would otherwise overwrite them). */
    double cli_warmup = -1;
    double cli_run_length = -1;
    int    cli_replications = -1;
    unsigned long cli_seed = 0;
    int    cli_seed_set = 0;
    char   cli_mcn_file[256] = "";

    for (i = 1; i < argc; i++) {
        if (argv[i][0] == '-') {
            switch (argv[i][1]) {
                case 'h':
                    print_usage(argv[0]);
                    return 0;
                case 'c':
                    compact_mode = 1;
                    break;
                case 'w':
                    if (++i < argc) cli_warmup = atof(argv[i]);
                    break;
                case 'r':
                    if (++i < argc) cli_run_length = atof(argv[i]);
                    break;
                case 'n':
                    if (++i < argc) cli_replications = atoi(argv[i]);
                    break;
                case 's':
                    if (++i < argc) { cli_seed = (unsigned long)atol(argv[i]); cli_seed_set = 1; }
                    break;
                case 'm':
                    if (++i < argc) strncpy(cli_mcn_file, argv[i],
                                           sizeof(cli_mcn_file) - 1);
                    break;
                case 'v':
                    sim_params.verbose = 1;
                    break;
                case 'P':
                    if (++i < argc) strncpy(progress_file_path, argv[i],
                                           sizeof(progress_file_path) - 1);
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

    /* Parse input file */
    if (!parse_input_file(input_file)) {
        return 1;
    }

    /* Apply CLI overrides (take precedence over input file) */
    if (cli_warmup >= 0)       sim_params.warmup_time = cli_warmup;
    if (cli_run_length >= 0)   sim_params.run_length = cli_run_length;
    if (cli_replications >= 0) sim_params.num_replications = cli_replications;
    if (cli_seed_set)          sim_params.seed = cli_seed;
    if (cli_mcn_file[0])       strncpy(sim_params.output_mcn_file, cli_mcn_file,
                                       sizeof(sim_params.output_mcn_file) - 1);

    /* In compact mode, suppress stdout */
    if (compact_mode) {
        compact_suppress_stdout();
    }

    printf("Multi-Class Jackson Network Simulator\n");
    printf("======================================\n\n");
    printf("Loading network from: %s\n", input_file);
    printf("Stations: %d, Classes: %d\n", network.num_stations, network.num_classes);
    printf("Running %d replications...\n\n", sim_params.num_replications);

    /* Allocate storage for run values */
    nc = network.num_classes;
    ns = network.num_stations;
    run_values = (double (*)[RUN_VALUES_COLS])
                 malloc(sim_params.num_replications * sizeof(*run_values));
    if (!run_values) {
        fprintf(stderr, "Error: Failed to allocate run values array\n");
        return 1;
    }

    /* Run replications — parallelized across threads with OpenMP when
       compiled with -fopenmp. Each thread operates on its own threadprivate
       copy of the network / event heap / RNG state (see declarations above),
       so replications are fully independent. */
#ifdef _OPENMP
    if (!compact_mode) {
        printf("[OpenMP] Using %d threads\n\n", omp_get_max_threads());
    }
#endif

    rng_init(sim_params.seed);  /* master thread seed (per-rep reseed below) */

    progress_open((long)sim_params.num_replications);

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

            /* Independent RNG stream per replication (thread-safe because
               `rng_state` is threadprivate). */
            rng_init(sim_params.seed + (unsigned long)r);

            run_simulation(&local_stats);

            /* Store run results */
            for (ii = 0; ii < nc; ii++) {
                /* Mean queue time per class (uses customers_served) */
                run_values[r][ii] = (local_stats.customers_served[ii] > 0) ?
                    local_stats.total_queue_time[ii] / local_stats.customers_served[ii] : 0.0;

                /* Mean sojourn time per class (queue + service at this class) */
                run_values[r][nc + ii] = (local_stats.customers_served[ii] > 0) ?
                    local_stats.total_sojourn_time[ii] / local_stats.customers_served[ii] : 0.0;

                /* Throughput per class (customers leaving system from this class) */
                run_values[r][2*nc + ii] = local_stats.customers_completed[ii] / sim_params.run_length;
            }

            for (ii = 0; ii < ns; ii++) {
                /* Mean queue time at station */
                run_values[r][3*nc + ii] = (local_stats.customers_at_station[ii] > 0) ?
                    local_stats.total_queue_time_station[ii] / local_stats.customers_at_station[ii] : 0.0;

                /* Utilization at station */
                run_values[r][3*nc + ns + ii] = local_stats.busy_time[ii] / sim_params.run_length;
            }

            /* Mean queue length (number of customers) at station:
               E[Q_i] = (total_wait + total_service) / run_length */
            for (ii = 0; ii < ns; ii++) {
                run_values[r][3*nc + 2*ns + ii] =
                    (local_stats.total_queue_time_station[ii] + local_stats.busy_time[ii])
                    / sim_params.run_length;
            }

            /* Queue time by class and station */
            for (ii = 0; ii < nc; ii++) {
                for (jj = 0; jj < ns; jj++) {
                    idx_l = 3*nc + 3*ns + ii*ns + jj;
                    run_values[r][idx_l] = (local_stats.count_class_station[ii][jj] > 0) ?
                        local_stats.queue_time_class_station[ii][jj] / local_stats.count_class_station[ii][jj] : 0.0;
                }
            }

            /* Per-customer-class statistics */
            if (network.num_customer_classes > 0) {
                int nk = network.num_customer_classes;
                int base = 3*nc + 3*ns + nc*ns;
                for (ii = 0; ii < nk; ii++) {
                    run_values[r][base + ii] = (local_stats.network_departures[ii] > 0) ?
                        local_stats.total_network_sojourn[ii] / local_stats.network_departures[ii] : 0.0;
                    run_values[r][base + nk + ii] = (local_stats.network_departures[ii] > 0) ?
                        local_stats.total_network_queue[ii] / local_stats.network_departures[ii] : 0.0;
                    run_values[r][base + 2*nk + ii] =
                        local_stats.network_departures[ii] / sim_params.run_length;
                }
            }

            /* Per-station throughput. Stored at a fixed offset past the
             * customer-class section (using MAX_CLASSES instead of nk so
             * the offset doesn't depend on whether num_customer_classes
             * is set), so the existing index math is unaffected. */
            {
                int tp_base = 3*nc + 3*ns + nc*ns + 3*MAX_CLASSES;
                for (ii = 0; ii < ns; ii++) {
                    run_values[r][tp_base + ii] =
                        local_stats.customers_at_station[ii] / sim_params.run_length;
                }
            }

            progress_tick();
        }
    }

    progress_close();

    /* Compute aggregate statistics */
    init_aggregate_stats(&agg_stats);
    compute_aggregate_stats(run_values, sim_params.num_replications, &agg_stats);

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

    /* Restore stdout if compact mode was active */
    if (compact_mode) {
        compact_restore_stdout();
        printf("Jackson Simulation (BNAsim)\n");
        printf("=================\n");
    }

    /* ── Standardized output (same format as BNAqna and BNAsm) ─── */

    if (!compact_mode && network.num_customer_classes > 0) {
        int k;
        int nk = network.num_customer_classes;
        int nrep = sim_params.num_replications;
        double total_lambda0 = 0.0, total_EN = 0.0;
        for (k = 0; k < nk; k++)
            total_lambda0 += agg_stats.mean_cust_throughput[k];
        for (i = 0; i < network.num_stations; i++)
            total_EN += agg_stats.mean_queue_length[i];
        printf("\nNetwork Totals:\n");
        printf("  External arrival rate: %f\n", total_lambda0);
        printf("  Total E[N]: %f\n", total_EN);
        if (total_lambda0 > 1e-15)
            printf("  Mean sojourn time E[T]: %f\n", total_EN / total_lambda0);

        printf("\nCUSTOMER CLASS STATISTICS\n");
        printf("=========================\n");
        for (k = 0; k < nk; k++) {
            double en = agg_stats.mean_cust_throughput[k]
                      * agg_stats.mean_cust_sojourn[k];
            double ci_w = jackson_ci_half_width(agg_stats.var_cust_queue[k], nrep);
            double ci_t = jackson_ci_half_width(agg_stats.var_cust_sojourn[k], nrep);
            printf("\nClass %d:\n", k + 1);
            printf("  Mean queue time (total):   %f  +/- %.4f\n",
                   agg_stats.mean_cust_queue[k], ci_w);
            printf("  Mean sojourn time (total): %f  +/- %.4f\n",
                   agg_stats.mean_cust_sojourn[k], ci_t);
            printf("  Mean number in system:     %f\n", en);
        }
    }

    if (compact_mode && network.num_customer_classes > 0) {
        int k;
        int nk = network.num_customer_classes;
        int nrep = sim_params.num_replications;
        for (k = 0; k < nk; k++) {
            double ci = jackson_ci_half_width(agg_stats.var_cust_queue[k], nrep);
            printf("W_total(class %d) = %f\t(%.4f)\n", k + 1,
                   agg_stats.mean_cust_queue[k], ci);
        }
        for (k = 0; k < nk; k++) {
            double ci = jackson_ci_half_width(agg_stats.var_cust_sojourn[k], nrep);
            printf("T_total(class %d) = %f\t(%.4f)\n", k + 1,
                   agg_stats.mean_cust_sojourn[k], ci);
        }
        printf("\n");
    }

    /* Per-station utilization */
    if (compact_mode) {
        for (i = 0; i < network.num_stations; i++) {
            double ci = jackson_ci_half_width(
                agg_stats.var_utilization[i], sim_params.num_replications);
            printf("rho_%d = %f\t(%.4f)\n", i + 1,
                   agg_stats.mean_utilization[i], ci);
        }
        printf("\n");

        /* Per-station throughput (effective arrival rate) and sojourn —
         * matches the Gamma_k / sojourn_k format the bnet, bna_qna, and
         * bna_sbd solvers print. Throughput is the per-station departure
         * rate aggregated across replications; sojourn is E[Q_k] / Γ_k
         * by Little's Law. */
        for (i = 0; i < network.num_stations; i++) {
            double ci = jackson_ci_half_width(
                agg_stats.var_throughput_station[i], sim_params.num_replications);
            printf("Gamma_%d = %f\t(%.4f)\n", i + 1,
                   agg_stats.mean_throughput_station[i], ci);
        }
        printf("\n");

        for (i = 0; i < network.num_stations; i++) {
            double soj = (agg_stats.mean_throughput_station[i] > 1e-12)
                ? agg_stats.mean_queue_length[i] / agg_stats.mean_throughput_station[i]
                : 0.0;
            printf("sojourn_%d = %f\n", i + 1, soj);
        }
        printf("\n");

        if (network.num_customer_classes > 0) {
            int nk = network.num_customer_classes;
            int nrep = sim_params.num_replications;
            int k;
            for (k = 0; k < nk; k++) {
                double ci = jackson_ci_half_width(agg_stats.var_cust_throughput[k], nrep);
                printf("X(class %d) = %f\t(%.4f)\n", k + 1,
                       agg_stats.mean_cust_throughput[k], ci);
            }
            printf("\n");
        }
    }

    /* Per-station mean queue length: always printed last */
    printf("\n");
    {
        int w = 1;
        for (int t = network.num_stations; t >= 10; t /= 10) w++;
        for (i = 0; i < network.num_stations; i++) {
            double ci = jackson_ci_half_width(
                agg_stats.var_queue_length[i], sim_params.num_replications);
            printf("E[Q_%0*d] = %f\t(%.4f)\n", w, i + 1,
                   agg_stats.mean_queue_length[i], ci);
        }
    }
    printf("\n");

    /* Cleanup */
    free(run_values);

    return 0;
}
