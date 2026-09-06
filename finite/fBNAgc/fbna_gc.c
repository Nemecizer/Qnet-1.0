/*
 * fbna_gc.c — exact stationary distribution of a finite, multiclass, loss
 * queueing network, by sparse uniformized power iteration.
 *
 * The C engine for `Run > Exact Sparse CTMC`. `solver.py` in this directory is
 * the other one; Settings > Solvers > Solver Engine picks between them under
 * "Markovian CTMC", the row it shares with the adaptive truncated CTMC because
 * the two run the same kernel.
 *
 * THE CONTRACT BETWEEN THE TWO ENGINES
 *
 * Byte-identical output for a document that solves, and the same exit status
 * and message for one that does not. `tests/test_engine_parity.sh` diffs the
 * whole of stdout.
 *
 * Unlike the QBD and the truncated CTMC, nothing in this solver uses
 * `math.fsum` — every accumulation in `solver.py` is a plain `+=` or a plain
 * `sum()`. So this engine accumulates plainly too, in the same order, and pays
 * none of the exact-summation cost the QBD engine does. That is why it keeps
 * the full interpreter gap where the QBD engine keeps about a sixth of it.
 *
 * WHAT IS DELICATE HERE IS THE STATE ORDER, NOT THE ARITHMETIC
 *
 * A state is a tuple of ORDERED queues — position matters, because the first
 * `servers` customers in a queue are the ones in service and their classes
 * decide the rates. The Python enumerates states breadth-first from empty and
 * assigns each new state the next index, and the order in which new states are
 * DISCOVERED is the iteration order of the `dict` that `transition_rates`
 * returns, which is Python's insertion order. Index assignment therefore
 * depends on the order events are generated in, and every downstream number is
 * indexed by it.
 *
 * So this file reproduces that order exactly: events are generated
 * external-arrivals-first, then station by station, then service position by
 * position, then route by route; each target is appended on FIRST occurrence
 * and its rate accumulated in place on later ones; and only then is the row
 * sorted by index, as the Python sorts it. A different generation order would
 * still give a correct stationary distribution, on a differently numbered state
 * space, and every row of the report would move.
 *
 * Speed: measured on a two-station two-class loss network at capacity 7
 * (60,929 states, 402 iterations), 8.80 s under Python and 0.10 s here.
 */

#include <limits.h>
#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../../common/bnet_json.h"
#include "../../common/bnet_memcheck.h"

#define GC_OK          0
#define GC_CONFIG      1
#define GC_STATE_LIMIT 2
#define GC_CONVERGENCE 3

static int  g_error_kind = GC_OK;
static char g_error_message[768];

static int fail(int kind, const char *format, ...)
{
    va_list args;
    if (g_error_kind == GC_OK) {
        g_error_kind = kind;
        va_start(args, format);
        vsnprintf(g_error_message, sizeof g_error_message, format, args);
        va_end(args);
    }
    return 0;
}

/* ---------------------------------------------------------------- model */

#define GC_MAX_ID 128

typedef struct {
    char    id[GC_MAX_ID];
    int     servers;
    int     capacity;
    double *service_rates;      /* [class_count] */
    char   *has_service_rate;   /* [class_count]; None in the Python */
} gc_station;

typedef struct {
    int    station;
    int    customer_class;
    double rate;
} gc_arrival;

/* `station < 0` is the exit route (Route(None, None, p)). */
typedef struct {
    int    station;
    int    customer_class;
    double probability;
} gc_route;

typedef struct {
    int       has_rule;
    gc_route *routes;
    int       count;
} gc_route_set;

typedef struct {
    char          name[256];
    char        (*class_ids)[GC_MAX_ID];
    int           class_count;
    gc_station   *stations;
    int           station_count;
    gc_arrival   *arrivals;
    int           arrival_count;
    gc_route_set *routing;      /* [station_count * class_count] */
    double        tolerance;
    long          max_iterations;
    long          max_states;
    double        uniformization_slack;
} gc_model;

/* `model.routes(station, class)`: the declared rule, or a single exit route. */
static const gc_route_set *gc_routes(const gc_model *model, int station, int customer_class)
{
    static const gc_route exit_route = { -1, -1, 1.0 };
    static const gc_route_set default_set = { 1, (gc_route *)&exit_route, 1 };
    const gc_route_set *set = &model->routing[(size_t)station * model->class_count + customer_class];
    return set->has_rule ? set : &default_set;
}

static int gc_service_rate(const gc_model *model, int station, int customer_class, double *out)
{
    if (!model->stations[station].has_service_rate[customer_class]) {
        return fail(GC_CONFIG, "no service rate for class '%s' at station '%s'",
                    model->class_ids[customer_class], model->stations[station].id);
    }
    *out = model->stations[station].service_rates[customer_class];
    return 1;
}

/* ---------------------------------------------------------------- states */

/*
 * A state is stored as a canonical byte string: for each station in order, one
 * length byte followed by that many class bytes. Compact, comparable with
 * memcmp, and hashable as-is. Class and station counts are bounded well below
 * 255 by the state-space limit long before the encoding could overflow, and
 * `gc_check_encoding_limits` refuses the input that would.
 */
typedef struct {
    unsigned char *bytes;       /* arena of encoded states, back to back */
    size_t         used;
    size_t         capacity;
    size_t        *offset;      /* [count] into bytes */
    long           count;
    long           allocated;
    /* Open-addressed index: hash -> state index, or -1. */
    long          *table;
    size_t         mask;
} gc_state_set;

static uint64_t gc_hash(const unsigned char *bytes, size_t length)
{
    uint64_t hash = 1469598103934665603ULL;         /* FNV-1a */
    size_t i;
    for (i = 0; i < length; i++) {
        hash ^= bytes[i];
        hash *= 1099511628211ULL;
    }
    return hash;
}

static int gc_state_set_init(gc_state_set *set, size_t initial_slots)
{
    size_t slots = 1024;
    while (slots < initial_slots * 2) slots *= 2;
    memset(set, 0, sizeof *set);
    set->capacity = 65536;
    set->bytes = (unsigned char *)malloc(set->capacity);
    set->allocated = 1024;
    set->offset = (size_t *)malloc((size_t)set->allocated * sizeof(size_t));
    set->table = (long *)malloc(slots * sizeof(long));
    if (!set->bytes || !set->offset || !set->table) {
        return fail(GC_STATE_LIMIT, "out of memory preparing the state space");
    }
    memset(set->table, 0xFF, slots * sizeof(long));     /* all -1 */
    set->mask = slots - 1;
    return 1;
}

static void gc_state_set_free(gc_state_set *set)
{
    free(set->bytes); free(set->offset); free(set->table);
    memset(set, 0, sizeof *set);
}

static size_t gc_state_length(const gc_model *model, const unsigned char *state)
{
    size_t length = 0;
    int i;
    for (i = 0; i < model->station_count; i++) length += 1 + state[length];
    return length;
}

static int gc_table_grow(gc_state_set *set, const gc_model *model)
{
    size_t slots = (set->mask + 1) * 2, i;
    long *table = (long *)malloc(slots * sizeof(long));
    if (!table) return fail(GC_STATE_LIMIT, "out of memory growing the state index");
    memset(table, 0xFF, slots * sizeof(long));
    for (i = 0; i < set->mask + 1; i++) {
        long index = set->table[i];
        size_t slot;
        if (index < 0) continue;
        slot = (size_t)gc_hash(set->bytes + set->offset[index],
                               gc_state_length(model, set->bytes + set->offset[index]))
             & (slots - 1);
        while (table[slot] >= 0) slot = (slot + 1) & (slots - 1);
        table[slot] = index;
    }
    free(set->table);
    set->table = table;
    set->mask = slots - 1;
    return 1;
}

/* Returns the index of `state`, adding it if new. `*added` reports which. */
static long gc_intern_state(gc_state_set *set, const gc_model *model,
                            const unsigned char *state, size_t length, int *added)
{
    size_t slot = (size_t)gc_hash(state, length) & set->mask;
    *added = 0;
    while (set->table[slot] >= 0) {
        long index = set->table[slot];
        const unsigned char *existing = set->bytes + set->offset[index];
        if (gc_state_length(model, existing) == length
            && memcmp(existing, state, length) == 0) {
            return index;
        }
        slot = (slot + 1) & set->mask;
    }
    if (set->count == set->allocated) {
        long allocated = set->allocated * 2;
        size_t *offset = (size_t *)realloc(set->offset, (size_t)allocated * sizeof(size_t));
        if (!offset) { fail(GC_STATE_LIMIT, "out of memory storing states"); return -1; }
        set->offset = offset;
        set->allocated = allocated;
    }
    while (set->used + length > set->capacity) {
        size_t capacity = set->capacity * 2;
        unsigned char *bytes = (unsigned char *)realloc(set->bytes, capacity);
        if (!bytes) { fail(GC_STATE_LIMIT, "out of memory storing states"); return -1; }
        set->bytes = bytes;
        set->capacity = capacity;
    }
    memcpy(set->bytes + set->used, state, length);
    set->offset[set->count] = set->used;
    set->used += length;
    set->table[slot] = set->count;
    *added = 1;
    set->count++;
    if ((size_t)set->count * 2 > set->mask + 1) {
        if (!gc_table_grow(set, model)) return -1;
    }
    return set->count - 1;
}

/* Queue helpers over the encoded form. `station_offset` is filled once. */
static void gc_station_offsets(const gc_model *model, const unsigned char *state, size_t *offsets)
{
    size_t position = 0;
    int i;
    for (i = 0; i < model->station_count; i++) {
        offsets[i] = position;
        position += 1 + state[position];
    }
}

/* ------------------------------------------------------------ enumeration */

typedef struct {
    long   *targets;            /* row-major, indexed by row_start */
    double *rates;
    long   *row_start;          /* [count + 1] */
    double *leaving_rates;      /* [count] */
    long    count;
    long    off_diagonal_count;
} gc_chain;

static void gc_chain_free(gc_chain *chain)
{
    free(chain->targets); free(chain->rates); free(chain->row_start);
    free(chain->leaving_rates);
    memset(chain, 0, sizeof *chain);
}

/* The scratch row: encoded target states in DISCOVERY order with accumulated
 * rates, before indices are known. Sized for the worst case one state can
 * produce — one arrival per (station, class), plus, per server position, one
 * route per destination.
 *
 * States in one row have DIFFERENT LENGTHS: a departure removes a customer and
 * shortens the encoding by a byte, while a routed completion keeps it the same.
 * So the length is stored beside each entry and compared first. Comparing only
 * the caller's byte count would let a shorter state match a longer one that
 * happens to begin with the same bytes — and it does happen, because a
 * departure from the last station produces exactly a prefix of the pre-event
 * encoding.
 */
typedef struct {
    unsigned char *states;      /* [capacity * state_bytes] */
    size_t        *lengths;
    double        *rates;
    int            count;
    int            capacity;
    size_t         state_bytes;
} gc_row_buffer;

static int gc_row_add(gc_row_buffer *row, const unsigned char *state, size_t length, double rate)
{
    int i;
    for (i = 0; i < row->count; i++) {
        if (row->lengths[i] == length
            && memcmp(row->states + (size_t)i * row->state_bytes, state, length) == 0) {
            row->rates[i] += rate;
            return 1;
        }
    }
    if (row->count == row->capacity) return fail(GC_STATE_LIMIT, "internal: transition row overflow");
    memcpy(row->states + (size_t)row->count * row->state_bytes, state, length);
    row->lengths[row->count] = length;
    row->rates[row->count] = rate;
    row->count++;
    return 1;
}

/* True when the encoded state equals the one the events are leaving. */
static int gc_same_state(const unsigned char *a, size_t a_length,
                         const unsigned char *b, size_t b_length)
{
    return a_length == b_length && memcmp(a, b, a_length) == 0;
}

/*
 * All positive-rate state changes out of `state`, in the Python's generation
 * order. Lost arrivals and other events that leave the state unchanged are
 * rewards, not generator entries, and are omitted here exactly as there.
 */
static int gc_transition_rates(const gc_model *model, const unsigned char *state,
                               size_t state_length, size_t *offsets,
                               unsigned char *scratch, gc_row_buffer *row)
{
    int arrival_index, source_station, position;
    row->count = 0;
    gc_station_offsets(model, state, offsets);

    /* Emit one candidate transition, applying the Python's `add`: skip a
     * nonpositive rate and skip a target equal to the source. */
#define GC_EMIT(target_length, rate_value)                                              \
    do {                                                                                \
        double rate_ = (rate_value);                                                    \
        size_t length_ = (target_length);                                               \
        if (rate_ > 0.0 && !gc_same_state(scratch, length_, state, state_length)) {      \
            if (!gc_row_add(row, scratch, length_, rate_)) return 0;                     \
        }                                                                               \
    } while (0)

    for (arrival_index = 0; arrival_index < model->arrival_count; arrival_index++) {
        const gc_arrival *arrival = &model->arrivals[arrival_index];
        size_t base = offsets[arrival->station];
        int queue_length = state[base];
        if (queue_length >= model->stations[arrival->station].capacity) continue;
        /* Append the class at the end of that station's queue; every later
         * station's bytes shift right by one. */
        memcpy(scratch, state, base + 1 + (size_t)queue_length);
        scratch[base] = (unsigned char)(queue_length + 1);
        scratch[base + 1 + queue_length] = (unsigned char)arrival->customer_class;
        memcpy(scratch + base + 1 + queue_length + 1,
               state + base + 1 + queue_length,
               state_length - (base + 1 + (size_t)queue_length));
        GC_EMIT(state_length + 1, arrival->rate);
    }

    for (source_station = 0; source_station < model->station_count; source_station++) {
        size_t source_base = offsets[source_station];
        int queue_length = state[source_base];
        int servers = model->stations[source_station].servers;
        int in_service = queue_length < servers ? queue_length : servers;
        for (position = 0; position < in_service; position++) {
            int source_class = state[source_base + 1 + position];
            const gc_route_set *routes;
            double service_rate;
            unsigned char *departure = row->states + (size_t)row->capacity * row->state_bytes;
            size_t departure_length = state_length - 1;
            size_t *departure_offsets = offsets + model->station_count;
            int route_index;
            if (!gc_service_rate(model, source_station, source_class, &service_rate)) return 0;

            /* The state after the completion, before routing. */
            memcpy(departure, state, source_base + 1 + (size_t)position);
            departure[source_base] = (unsigned char)(queue_length - 1);
            memcpy(departure + source_base + 1 + position,
                   state + source_base + 1 + position + 1,
                   state_length - (source_base + 1 + (size_t)position + 1));
            gc_station_offsets(model, departure, departure_offsets);

            routes = gc_routes(model, source_station, source_class);
            for (route_index = 0; route_index < routes->count; route_index++) {
                const gc_route *route = &routes->routes[route_index];
                double event_rate = service_rate * route->probability;
                if (route->station < 0) {
                    memcpy(scratch, departure, departure_length);
                    GC_EMIT(departure_length, event_rate);
                    continue;
                }
                {
                    int destination_station = route->station;
                    int destination_class = route->customer_class;
                    size_t destination_base = departure_offsets[destination_station];
                    int destination_length = departure[destination_base];
                    if (destination_length >= model->stations[destination_station].capacity) {
                        /* The completion happened; the routed customer is lost. */
                        memcpy(scratch, departure, departure_length);
                        GC_EMIT(departure_length, event_rate);
                        continue;
                    }
                    memcpy(scratch, departure, destination_base + 1 + (size_t)destination_length);
                    scratch[destination_base] = (unsigned char)(destination_length + 1);
                    scratch[destination_base + 1 + destination_length] =
                        (unsigned char)destination_class;
                    memcpy(scratch + destination_base + 1 + destination_length + 1,
                           departure + destination_base + 1 + destination_length,
                           departure_length - (destination_base + 1 + (size_t)destination_length));
                    GC_EMIT(departure_length + 1, event_rate);
                }
            }
        }
    }
#undef GC_EMIT
    return 1;
}

/* Breadth-first enumeration from the empty network, assigning indices in
 * discovery order — see the note at the top of this file for why that order is
 * observable and must match the Python's. */
static int gc_enumerate_chain(const gc_model *model, gc_state_set *set, gc_chain *chain)
{
    long limit = model->max_states;
    long head = 0;
    size_t state_bytes, *offsets = NULL;
    unsigned char *empty = NULL, *scratch = NULL;
    gc_row_buffer row;
    long *sorted_index = NULL;
    long capacity = 0, transition_capacity = 0;
    int i, added;

    memset(chain, 0, sizeof *chain);
    memset(&row, 0, sizeof row);
    if (limit < 1) return fail(GC_CONFIG, "max_states must be >= 1");

    /* Worst-case encoded length: one length byte per station plus one class
     * byte per unit of capacity. Plus one, because an arrival lengthens the
     * encoding by a byte before the capacity check rejects it. */
    state_bytes = (size_t)model->station_count;
    for (i = 0; i < model->station_count; i++) state_bytes += (size_t)model->stations[i].capacity;
    state_bytes += 2;

    /* Two blocks of station offsets: the state's, and the post-completion
     * state's, which gc_transition_rates takes from the tail of the same array. */
    offsets = (size_t *)malloc((size_t)model->station_count * 2 * sizeof(size_t));
    empty = (unsigned char *)calloc(state_bytes, 1);
    scratch = (unsigned char *)calloc(state_bytes, 1);
    row.capacity = model->arrival_count
                 + model->station_count * model->class_count * (model->station_count + 1) + 8;
    row.state_bytes = state_bytes;
    /* One slot past `capacity` is scratch space for the post-completion state. */
    row.states = (unsigned char *)malloc((size_t)(row.capacity + 1) * state_bytes);
    row.lengths = (size_t *)malloc((size_t)row.capacity * sizeof(size_t));
    row.rates = (double *)malloc((size_t)row.capacity * sizeof(double));
    sorted_index = (long *)malloc((size_t)row.capacity * sizeof(long));
    if (!offsets || !empty || !scratch || !row.states || !row.lengths || !row.rates || !sorted_index) {
        fail(GC_STATE_LIMIT, "out of memory preparing the enumeration");
        goto done;
    }

    if (!gc_state_set_init(set, 1024)) goto done;
    /* The empty state: every station's length byte is zero. */
    { size_t position = 0;
      for (i = 0; i < model->station_count; i++) empty[position++] = 0; }
    if (gc_intern_state(set, model, empty, (size_t)model->station_count, &added) < 0) goto done;

    chain->row_start = (long *)malloc(1025 * sizeof(long));
    chain->leaving_rates = (double *)malloc(1024 * sizeof(double));
    capacity = 1024;
    if (!chain->row_start || !chain->leaving_rates) {
        fail(GC_STATE_LIMIT, "out of memory preparing the chain");
        goto done;
    }

    while (head < set->count) {
        const unsigned char *state;
        size_t state_length;
        int entry, k, m;
        double leaving = 0.0;

        if (head + 1 >= capacity) {
            long grown = capacity * 2;
            long *row_start = (long *)realloc(chain->row_start, (size_t)(grown + 1) * sizeof(long));
            double *leaving_rates = (double *)realloc(chain->leaving_rates,
                                                      (size_t)grown * sizeof(double));
            if (!row_start || !leaving_rates) {
                free(row_start); free(leaving_rates);
                fail(GC_STATE_LIMIT, "out of memory growing the chain");
                goto done;
            }
            chain->row_start = row_start;
            chain->leaving_rates = leaving_rates;
            capacity = grown;
        }
        state = set->bytes + set->offset[head];
        state_length = gc_state_length(model, state);
        if (!gc_transition_rates(model, state, state_length, offsets, scratch, &row)) goto done;

        /* Index the row, allocating new states in discovery order. */
        for (entry = 0; entry < row.count; entry++) {
            long index = gc_intern_state(set, model,
                                         row.states + (size_t)entry * state_bytes,
                                         row.lengths[entry], &added);
            if (index < 0) goto done;
            if (added && set->count > limit) {
                fail(GC_STATE_LIMIT,
                     "reachable state count exceeds max_states=%ld; increase the "
                     "limit deliberately or reduce capacities/classes", limit);
                goto done;
            }
            sorted_index[entry] = index;
        }
        /* `indexed_row.sort(key=item[0])` — insertion sort; rows are tiny. */
        for (k = 1; k < row.count; k++) {
            long key_index = sorted_index[k];
            double key_rate = row.rates[k];
            for (m = k - 1; m >= 0 && sorted_index[m] > key_index; m--) {
                sorted_index[m + 1] = sorted_index[m];
                row.rates[m + 1] = row.rates[m];
            }
            sorted_index[m + 1] = key_index;
            row.rates[m + 1] = key_rate;
        }

        chain->row_start[head] = chain->off_diagonal_count;
        {
            long needed = chain->off_diagonal_count + row.count;
            if (needed > transition_capacity) {
                long grown = transition_capacity ? transition_capacity * 2 : 4096;
                long *targets;
                double *rates;
                while (grown < needed) grown *= 2;
                targets = (long *)realloc(chain->targets, (size_t)grown * sizeof(long));
                rates = (double *)realloc(chain->rates, (size_t)grown * sizeof(double));
                if (!targets || !rates) {
                    free(targets); free(rates);
                    fail(GC_STATE_LIMIT, "out of memory growing the transition table");
                    goto done;
                }
                chain->targets = targets;
                chain->rates = rates;
                transition_capacity = grown;
            }
        }
        for (entry = 0; entry < row.count; entry++) {
            chain->targets[chain->off_diagonal_count + entry] = sorted_index[entry];
            chain->rates[chain->off_diagonal_count + entry] = row.rates[entry];
            /* `sum(rate for _, rate in row)` — a plain left-to-right sum over
             * the SORTED row, which is what the Python computes. */
            leaving += row.rates[entry];
        }
        chain->off_diagonal_count += row.count;
        chain->leaving_rates[head] = leaving;
        head++;
    }
    chain->count = set->count;
    chain->row_start[chain->count] = chain->off_diagonal_count;

done:
    free(offsets); free(empty); free(scratch);
    free(row.states); free(row.lengths); free(row.rates); free(sorted_index);
    if (g_error_kind != GC_OK) { gc_chain_free(chain); return 0; }
    return 1;
}

/* --------------------------------------------------- stationary solution */

typedef struct {
    double *probabilities;
    long    iterations;
    int     converged;
    double  l1_step;
    double  generator_residual_l1;
    double  uniformization_rate;
} gc_solution;

/* ||pi Q||_1 without materialising Q. Plain accumulation and a plain sum, as
 * in the Python. */
static double gc_generator_residual_l1(const gc_chain *chain, const double *probabilities,
                                       double *scratch)
{
    long source, k;
    double total = 0.0;
    memset(scratch, 0, (size_t)chain->count * sizeof(double));
    for (source = 0; source < chain->count; source++) {
        double mass = probabilities[source];
        if (mass == 0.0) continue;
        scratch[source] -= mass * chain->leaving_rates[source];
        for (k = chain->row_start[source]; k < chain->row_start[source + 1]; k++) {
            scratch[chain->targets[k]] += mass * chain->rates[k];
        }
    }
    for (source = 0; source < chain->count; source++) total += fabs(scratch[source]);
    return total;
}

static int gc_solve_stationary(const gc_model *model, const gc_chain *chain, gc_solution *out)
{
    long count = chain->count, i, iteration;
    double maximum_leaving_rate = 0.0, uniformization_rate, last_step = HUGE_VAL;
    double *probabilities, *next, *scratch;

    memset(out, 0, sizeof *out);
    if (model->tolerance <= 0.0 || !isfinite(model->tolerance)) {
        return fail(GC_CONFIG, "tolerance must be positive and finite");
    }
    if (model->max_iterations < 1) return fail(GC_CONFIG, "max_iterations must be >= 1");
    if (model->uniformization_slack <= 0.0 || !isfinite(model->uniformization_slack)) {
        return fail(GC_CONFIG, "uniformization_slack must be positive and finite");
    }
    if (count == 0) return fail(GC_CONFIG, "chain has no states");

    probabilities = (double *)calloc((size_t)count, sizeof(double));
    next = (double *)calloc((size_t)count, sizeof(double));
    scratch = (double *)calloc((size_t)count, sizeof(double));
    if (!probabilities || !next || !scratch) {
        free(probabilities); free(next); free(scratch);
        return fail(GC_STATE_LIMIT, "out of memory solving the chain");
    }
    for (i = 0; i < count; i++) {
        if (chain->leaving_rates[i] > maximum_leaving_rate) {
            maximum_leaving_rate = chain->leaving_rates[i];
        }
    }
    if (maximum_leaving_rate == 0.0) {
        probabilities[0] = 1.0;
        out->probabilities = probabilities;
        out->converged = 1;
        free(next); free(scratch);
        return 1;
    }
    uniformization_rate = maximum_leaving_rate * (1.0 + model->uniformization_slack);
    probabilities[0] = 1.0;

    for (iteration = 1; iteration <= model->max_iterations; iteration++) {
        double total = 0.0, step = 0.0;
        long source, k;
        memset(next, 0, (size_t)count * sizeof(double));
        for (source = 0; source < count; source++) {
            double mass = probabilities[source], self_probability, scale;
            if (mass == 0.0) continue;
            self_probability = 1.0 - chain->leaving_rates[source] / uniformization_rate;
            next[source] += mass * self_probability;
            scale = mass / uniformization_rate;
            for (k = chain->row_start[source]; k < chain->row_start[source + 1]; k++) {
                next[chain->targets[k]] += scale * chain->rates[k];
            }
        }
        for (i = 0; i < count; i++) total += next[i];
        if (!isfinite(total) || total <= 0.0) {
            free(probabilities); free(next); free(scratch);
            return fail(GC_CONVERGENCE, "stationary iteration produced invalid probability mass");
        }
        if (fabs(total - 1.0) > 1.0e-14) {
            double inverse_total = 1.0 / total;
            for (i = 0; i < count; i++) next[i] *= inverse_total;
        }
        for (i = 0; i < count; i++) step += fabs(next[i] - probabilities[i]);
        last_step = step;
        memcpy(probabilities, next, (size_t)count * sizeof(double));
        if (last_step <= model->tolerance) {
            out->probabilities = probabilities;
            out->iterations = iteration;
            out->converged = 1;
            out->l1_step = last_step;
            out->generator_residual_l1 = gc_generator_residual_l1(chain, probabilities, scratch);
            out->uniformization_rate = uniformization_rate;
            free(next); free(scratch);
            return 1;
        }
    }
    out->probabilities = probabilities;
    out->iterations = model->max_iterations;
    out->converged = 0;
    out->l1_step = last_step;
    out->generator_residual_l1 = gc_generator_residual_l1(chain, probabilities, scratch);
    out->uniformization_rate = uniformization_rate;
    free(next); free(scratch);
    return 1;
}

/* -------------------------------------------------------------- measures */

typedef struct {
    double *mean_number;            /* [station * class] */
    double *mean_in_service;
    double *mean_waiting;
    double *completions;
    double *external_attempts;
    double *external_accepted;
    double *external_lost;
    double *internal_attempts;
    double *internal_accepted;
    double *internal_lost;
    double *exits;
    double *probability_full;       /* [station] */
    double *probability_empty;
    double  maximum_class_balance_residual;
    double  mean_total_number;
    double  total_external_attempts;
    double  total_external_accepted;
    double  total_external_lost;
    double  total_internal_lost;
    double  total_exit_rate;
    double  population_flow_residual;
    double  external_loss_probability;
    int     has_external_loss_probability;
} gc_measures;

static void gc_measures_free(gc_measures *m)
{
    free(m->mean_number); free(m->mean_in_service); free(m->mean_waiting);
    free(m->completions); free(m->external_attempts); free(m->external_accepted);
    free(m->external_lost); free(m->internal_attempts); free(m->internal_accepted);
    free(m->internal_lost); free(m->exits);
    free(m->probability_full); free(m->probability_empty);
    memset(m, 0, sizeof *m);
}

static int gc_compute_measures(const gc_model *model, const gc_state_set *set,
                               const gc_chain *chain, const gc_solution *solution,
                               gc_measures *out)
{
    int stations = model->station_count, classes = model->class_count;
    size_t grid = (size_t)stations * (size_t)classes;
    size_t *offsets = (size_t *)malloc((size_t)stations * sizeof(size_t));
    long index;
    int s, c;

    memset(out, 0, sizeof *out);
#define GC_GRID(field) out->field = (double *)calloc(grid, sizeof(double))
    GC_GRID(mean_number); GC_GRID(mean_in_service); GC_GRID(mean_waiting);
    GC_GRID(completions); GC_GRID(external_attempts); GC_GRID(external_accepted);
    GC_GRID(external_lost); GC_GRID(internal_attempts); GC_GRID(internal_accepted);
    GC_GRID(internal_lost); GC_GRID(exits);
#undef GC_GRID
    out->probability_full = (double *)calloc((size_t)stations, sizeof(double));
    out->probability_empty = (double *)calloc((size_t)stations, sizeof(double));
    if (!offsets || !out->mean_number || !out->exits || !out->probability_full
        || !out->probability_empty) {
        free(offsets);
        return fail(GC_STATE_LIMIT, "out of memory computing measures");
    }

    for (index = 0; index < chain->count; index++) {
        const unsigned char *state = set->bytes + set->offset[index];
        double probability = solution->probabilities[index];
        int arrival_index, source_station, position;
        if (probability == 0.0) continue;
        gc_station_offsets(model, state, offsets);

        for (s = 0; s < stations; s++) {
            int queue_length = state[offsets[s]];
            if (queue_length == 0) out->probability_empty[s] += probability;
            if (queue_length == model->stations[s].capacity) out->probability_full[s] += probability;
            for (position = 0; position < queue_length; position++) {
                int customer_class = state[offsets[s] + 1 + position];
                out->mean_number[(size_t)s * classes + customer_class] += probability;
                if (position < model->stations[s].servers) {
                    out->mean_in_service[(size_t)s * classes + customer_class] += probability;
                } else {
                    out->mean_waiting[(size_t)s * classes + customer_class] += probability;
                }
            }
        }
        for (arrival_index = 0; arrival_index < model->arrival_count; arrival_index++) {
            const gc_arrival *arrival = &model->arrivals[arrival_index];
            double event_rate = probability * arrival->rate;
            size_t slot = (size_t)arrival->station * classes + arrival->customer_class;
            out->external_attempts[slot] += event_rate;
            if (state[offsets[arrival->station]] < model->stations[arrival->station].capacity) {
                out->external_accepted[slot] += event_rate;
            } else {
                out->external_lost[slot] += event_rate;
            }
        }
        for (source_station = 0; source_station < stations; source_station++) {
            int queue_length = state[offsets[source_station]];
            int servers = model->stations[source_station].servers;
            int in_service = queue_length < servers ? queue_length : servers;
            for (position = 0; position < in_service; position++) {
                int source_class = state[offsets[source_station] + 1 + position];
                const gc_route_set *routes = gc_routes(model, source_station, source_class);
                double service_rate, base_rate;
                int route_index;
                if (!gc_service_rate(model, source_station, source_class, &service_rate)) {
                    free(offsets);
                    return 0;
                }
                base_rate = probability * service_rate;
                out->completions[(size_t)source_station * classes + source_class] += base_rate;
                for (route_index = 0; route_index < routes->count; route_index++) {
                    const gc_route *route = &routes->routes[route_index];
                    double event_rate = base_rate * route->probability;
                    int destination_station, destination_class, length_after;
                    if (route->station < 0) {
                        out->exits[(size_t)source_station * classes + source_class] += event_rate;
                        continue;
                    }
                    destination_station = route->station;
                    destination_class = route->customer_class;
                    out->internal_attempts[(size_t)destination_station * classes
                                           + destination_class] += event_rate;
                    length_after = state[offsets[destination_station]];
                    if (destination_station == source_station) length_after -= 1;
                    if (length_after < model->stations[destination_station].capacity) {
                        out->internal_accepted[(size_t)destination_station * classes
                                               + destination_class] += event_rate;
                    } else {
                        out->internal_lost[(size_t)destination_station * classes
                                           + destination_class] += event_rate;
                    }
                }
            }
        }
    }
    free(offsets);

    /* The aggregates, in the Python's summation order: per station over
     * classes, then over stations. Plain sums throughout. */
    for (s = 0; s < stations; s++) {
        for (c = 0; c < classes; c++) {
            size_t slot = (size_t)s * classes + c;
            double accepted = out->external_accepted[slot] + out->internal_accepted[slot];
            double residual = fabs(accepted - out->completions[slot]);
            if (residual > out->maximum_class_balance_residual) {
                out->maximum_class_balance_residual = residual;
            }
        }
    }
    {
        double total_internal_lost = 0.0;
        for (s = 0; s < stations; s++) {
            double row_mean = 0.0, row_external_attempts = 0.0, row_external_accepted = 0.0;
            double row_external_lost = 0.0, row_internal_lost = 0.0, row_exit = 0.0;
            for (c = 0; c < classes; c++) {
                size_t slot = (size_t)s * classes + c;
                row_mean += out->mean_number[slot];
                row_external_attempts += out->external_attempts[slot];
                row_external_accepted += out->external_accepted[slot];
                row_external_lost += out->external_lost[slot];
                row_internal_lost += out->internal_lost[slot];
                row_exit += out->exits[slot];
            }
            out->mean_total_number += row_mean;
            out->total_external_attempts += row_external_attempts;
            out->total_external_accepted += row_external_accepted;
            out->total_external_lost += row_external_lost;
            total_internal_lost += row_internal_lost;
            out->total_exit_rate += row_exit;
        }
        out->total_internal_lost = total_internal_lost;
    }
    out->population_flow_residual = out->total_external_accepted
                                  - (out->total_exit_rate + out->total_internal_lost);
    if (out->total_external_attempts > 0.0) {
        out->has_external_loss_probability = 1;
        out->external_loss_probability = out->total_external_lost / out->total_external_attempts;
    }
    return 1;
}

/* --------------------------------------------------------------- parsing */

/* `_check_keys`: sorted, comma-joined, and the plural agrees, because the
 * message is part of what the two engines must say alike. */
static int gc_check_keys(const bnet_json *d, int object, const char *const *allowed,
                         int allowed_count, const char *context)
{
    const char *unknown[32];
    int count = 0, child, i, j;
    char joined[512];
    size_t used = 0;
    if (object == BNET_JSON_NONE) return 1;
    for (child = d->nodes[object].first; child != BNET_JSON_NONE; child = d->nodes[child].next) {
        const char *key = bnet_json_key_of(d, child);
        int known = 0;
        if (!key) continue;
        for (i = 0; i < allowed_count; i++) if (strcmp(key, allowed[i]) == 0) { known = 1; break; }
        if (!known && count < (int)(sizeof unknown / sizeof unknown[0])) unknown[count++] = key;
    }
    if (count == 0) return 1;
    for (i = 1; i < count; i++) {
        const char *pivot = unknown[i];
        for (j = i - 1; j >= 0 && strcmp(unknown[j], pivot) > 0; j--) unknown[j + 1] = unknown[j];
        unknown[j + 1] = pivot;
    }
    joined[0] = '\0';
    for (i = 0; i < count; i++) {
        int written = snprintf(joined + used, sizeof joined - used, "%s%s", i ? ", " : "", unknown[i]);
        if (written < 0 || (size_t)written >= sizeof joined - used) break;
        used += (size_t)written;
    }
    return fail(GC_CONFIG, "%s has unknown field%s: %s", context, count != 1 ? "s" : "", joined);
}

/* `_nonempty_string`, including the .strip(). */
static int gc_nonempty_string(const bnet_json *d, int node, const char *context,
                              char *out, size_t size)
{
    const char *text = bnet_json_string(d, node);
    const char *start, *end;
    size_t length;
    if (!text) return fail(GC_CONFIG, "%s must be a non-empty string", context);
    start = text;
    while (*start == ' ' || *start == '\t' || *start == '\n' || *start == '\r') start++;
    end = start + strlen(start);
    while (end > start && (end[-1] == ' ' || end[-1] == '\t' || end[-1] == '\n' || end[-1] == '\r')) end--;
    length = (size_t)(end - start);
    if (length == 0) return fail(GC_CONFIG, "%s must be a non-empty string", context);
    if (length >= size) return fail(GC_CONFIG, "%s is too long", context);
    memcpy(out, start, length);
    out[length] = '\0';
    return 1;
}

static int gc_integer(const bnet_json *d, int node, const char *context, long minimum, long *out)
{
    double value;
    if (!bnet_json_number(d, node, &value) || !isfinite(value) || value != floor(value)
        || value < (double)minimum) {
        return fail(GC_CONFIG, "%s must be an integer >= %ld", context, minimum);
    }
    *out = (long)value;
    return 1;
}

static int gc_positive_number(const bnet_json *d, int node, const char *context, double *out)
{
    if (!bnet_json_number(d, node, out) || !isfinite(*out) || *out <= 0.0) {
        return fail(GC_CONFIG, "%s must be a positive finite number", context);
    }
    return 1;
}

static int gc_probability(const bnet_json *d, int node, const char *context, double *out)
{
    if (!bnet_json_number(d, node, out) || !isfinite(*out) || *out <= 0.0 || *out > 1.0) {
        return fail(GC_CONFIG, "%s must be a probability in (0, 1]", context);
    }
    return 1;
}

static int gc_class_index(const gc_model *model, const char *id)
{
    int i;
    for (i = 0; i < model->class_count; i++) if (strcmp(model->class_ids[i], id) == 0) return i;
    return -1;
}

static int gc_station_index(const gc_model *model, const char *id)
{
    int i;
    for (i = 0; i < model->station_count; i++) if (strcmp(model->stations[i].id, id) == 0) return i;
    return -1;
}

static void gc_model_free(gc_model *model)
{
    int i;
    for (i = 0; i < model->station_count; i++) {
        free(model->stations[i].service_rates);
        free(model->stations[i].has_service_rate);
    }
    free(model->stations);
    free(model->class_ids);
    free(model->arrivals);
    if (model->routing) {
        size_t k, total = (size_t)model->station_count * (size_t)model->class_count;
        for (k = 0; k < total; k++) free(model->routing[k].routes);
        free(model->routing);
    }
    memset(model, 0, sizeof *model);
}

static int gc_parse_model(const bnet_json *d, gc_model *model)
{
    static const char *root_keys[] = {
        "schema_version", "name", "description", "blocking", "service_discipline",
        "classes", "stations", "external_arrivals", "routing", "solver"
    };
    static const char *station_keys[] = { "id", "servers", "capacity", "service_rates" };
    static const char *arrival_keys[] = { "station", "class", "rate" };
    static const char *rule_keys[] = { "from_station", "from_class", "destinations" };
    static const char *destination_keys[] = { "station", "class", "exit", "probability" };
    static const char *solver_keys[] = { "tolerance", "max_iterations", "max_states",
                                         "uniformization_slack" };
    static const char *required[] = { "schema_version", "name", "classes", "stations",
                                      "external_arrivals" };
    int root = d->root, classes_node, stations_node, arrivals_node, routing_node, solver_node;
    int i, j, index;
    long version;

    memset(model, 0, sizeof *model);
    if (bnet_json_type_of(d, root) != BNET_JSON_OBJECT) {
        return fail(GC_CONFIG, "document must be a JSON object");
    }
    if (!gc_check_keys(d, root, root_keys, 10, "document")) return 0;
    for (i = 0; i < 5; i++) {
        if (bnet_json_member(d, root, required[i]) == BNET_JSON_NONE) {
            return fail(GC_CONFIG, "document is missing required field '%s'", required[i]);
        }
    }
    if (!gc_integer(d, bnet_json_member(d, root, "schema_version"), "schema_version", 1, &version)) return 0;
    if (version != 1) return fail(GC_CONFIG, "schema_version must be 1");
    {
        int description = bnet_json_member(d, root, "description");
        if (description != BNET_JSON_NONE && !bnet_json_string(d, description)) {
            return fail(GC_CONFIG, "description must be a string");
        }
    }
    {
        const char *blocking = bnet_json_string_or(d, bnet_json_member(d, root, "blocking"), "loss");
        const char *discipline = bnet_json_string_or(d, bnet_json_member(d, root, "service_discipline"), "fcfs");
        if (strcmp(blocking, "loss") != 0) {
            return fail(GC_CONFIG,
                        "blocking='%s' is not supported by generic_ctmc; use 'loss'. "
                        "The existing finite/fBNActmc tandem solver handles BAS models.", blocking);
        }
        if (strcmp(discipline, "fcfs") != 0) {
            return fail(GC_CONFIG,
                        "service_discipline='%s' is not supported; generic_ctmc uses 'fcfs'",
                        discipline);
        }
    }
    if (!gc_nonempty_string(d, bnet_json_member(d, root, "name"), "name",
                            model->name, sizeof model->name)) return 0;

    classes_node = bnet_json_member(d, root, "classes");
    if (bnet_json_type_of(d, classes_node) != BNET_JSON_ARRAY) {
        return fail(GC_CONFIG, "classes must be a JSON array");
    }
    model->class_count = bnet_json_count(d, classes_node);
    if (model->class_count == 0) return fail(GC_CONFIG, "classes must contain at least one class id");
    model->class_ids = (char (*)[GC_MAX_ID])calloc((size_t)model->class_count, GC_MAX_ID);
    if (!model->class_ids) return fail(GC_CONFIG, "out of memory");
    for (i = 0; i < model->class_count; i++) {
        char context[64];
        snprintf(context, sizeof context, "classes[%d]", i);
        if (!gc_nonempty_string(d, bnet_json_at(d, classes_node, i), context,
                                model->class_ids[i], GC_MAX_ID)) return 0;
    }
    for (i = 0; i < model->class_count; i++) {
        for (j = i + 1; j < model->class_count; j++) {
            if (strcmp(model->class_ids[i], model->class_ids[j]) == 0) {
                return fail(GC_CONFIG, "class ids must be unique");
            }
        }
    }

    stations_node = bnet_json_member(d, root, "stations");
    if (bnet_json_type_of(d, stations_node) != BNET_JSON_ARRAY) {
        return fail(GC_CONFIG, "stations must be a JSON array");
    }
    model->station_count = bnet_json_count(d, stations_node);
    if (model->station_count == 0) return fail(GC_CONFIG, "stations must contain at least one station");
    model->stations = (gc_station *)calloc((size_t)model->station_count, sizeof(gc_station));
    if (!model->stations) return fail(GC_CONFIG, "out of memory");
    for (i = 0; i < model->station_count; i++) {
        int item = bnet_json_at(d, stations_node, i), rates_node, member;
        char context[64], field[160];
        long servers, capacity;
        snprintf(context, sizeof context, "stations[%d]", i);
        if (bnet_json_type_of(d, item) != BNET_JSON_OBJECT) {
            return fail(GC_CONFIG, "%s must be a JSON object", context);
        }
        if (!gc_check_keys(d, item, station_keys, 4, context)) return 0;
        snprintf(field, sizeof field, "%s.id", context);
        if (!gc_nonempty_string(d, bnet_json_member(d, item, "id"), field,
                                model->stations[i].id, GC_MAX_ID)) return 0;
        if (gc_station_index(model, model->stations[i].id) != i) {
            return fail(GC_CONFIG, "station ids must be unique: '%s'", model->stations[i].id);
        }
        snprintf(field, sizeof field, "%s.servers", context);
        if (!gc_integer(d, bnet_json_member(d, item, "servers"), field, 1, &servers)) return 0;
        snprintf(field, sizeof field, "%s.capacity", context);
        if (!gc_integer(d, bnet_json_member(d, item, "capacity"), field, 1, &capacity)) return 0;
        if (servers > capacity) {
            return fail(GC_CONFIG, "%s.servers cannot exceed total in-system capacity", context);
        }
        model->stations[i].servers = (int)servers;
        model->stations[i].capacity = (int)capacity;
        model->stations[i].service_rates = (double *)calloc((size_t)model->class_count, sizeof(double));
        model->stations[i].has_service_rate = (char *)calloc((size_t)model->class_count, 1);
        if (!model->stations[i].service_rates || !model->stations[i].has_service_rate) {
            return fail(GC_CONFIG, "out of memory");
        }
        rates_node = bnet_json_member(d, item, "service_rates");
        snprintf(field, sizeof field, "%s.service_rates", context);
        if (bnet_json_type_of(d, rates_node) != BNET_JSON_OBJECT) {
            return fail(GC_CONFIG, "%s must be a JSON object", field);
        }
        if (bnet_json_count(d, rates_node) == 0) {
            return fail(GC_CONFIG, "%s.service_rates cannot be empty", context);
        }
        /* Unknown classes are reported sorted and joined, as the Python does. */
        {
            const char *unknown[32];
            int unknown_count = 0, k, m;
            for (member = d->nodes[rates_node].first; member != BNET_JSON_NONE;
                 member = d->nodes[member].next) {
                const char *key = bnet_json_key_of(d, member);
                if (gc_class_index(model, key) < 0
                    && unknown_count < (int)(sizeof unknown / sizeof unknown[0])) {
                    unknown[unknown_count++] = key;
                }
            }
            if (unknown_count) {
                char joined[512];
                size_t used = 0;
                for (k = 1; k < unknown_count; k++) {
                    const char *pivot = unknown[k];
                    for (m = k - 1; m >= 0 && strcmp(unknown[m], pivot) > 0; m--) {
                        unknown[m + 1] = unknown[m];
                    }
                    unknown[m + 1] = pivot;
                }
                joined[0] = '\0';
                for (k = 0; k < unknown_count; k++) {
                    int written = snprintf(joined + used, sizeof joined - used,
                                           "%s%s", k ? ", " : "", unknown[k]);
                    if (written < 0 || (size_t)written >= sizeof joined - used) break;
                    used += (size_t)written;
                }
                return fail(GC_CONFIG, "%s.service_rates refers to unknown classes: %s",
                            context, joined);
            }
        }
        for (member = d->nodes[rates_node].first; member != BNET_JSON_NONE;
             member = d->nodes[member].next) {
            const char *key = bnet_json_key_of(d, member);
            int class_position = gc_class_index(model, key);
            char rate_field[320];
            snprintf(rate_field, sizeof rate_field, "%s.service_rates.%s", context, key);
            if (!gc_positive_number(d, member, rate_field,
                                    &model->stations[i].service_rates[class_position])) return 0;
            model->stations[i].has_service_rate[class_position] = 1;
        }
    }

    arrivals_node = bnet_json_member(d, root, "external_arrivals");
    if (bnet_json_type_of(d, arrivals_node) != BNET_JSON_ARRAY) {
        return fail(GC_CONFIG, "external_arrivals must be a JSON array");
    }
    model->arrival_count = bnet_json_count(d, arrivals_node);
    model->arrivals = (gc_arrival *)calloc((size_t)(model->arrival_count ? model->arrival_count : 1),
                                           sizeof(gc_arrival));
    if (!model->arrivals) return fail(GC_CONFIG, "out of memory");
    for (i = 0; i < model->arrival_count; i++) {
        int item = bnet_json_at(d, arrivals_node, i);
        char context[64], field[160], station_id[GC_MAX_ID], class_id[GC_MAX_ID];
        int station_position, class_position;
        snprintf(context, sizeof context, "external_arrivals[%d]", i);
        if (bnet_json_type_of(d, item) != BNET_JSON_OBJECT) {
            return fail(GC_CONFIG, "%s must be a JSON object", context);
        }
        if (!gc_check_keys(d, item, arrival_keys, 3, context)) return 0;
        snprintf(field, sizeof field, "%s.station", context);
        if (!gc_nonempty_string(d, bnet_json_member(d, item, "station"), field,
                                station_id, sizeof station_id)) return 0;
        snprintf(field, sizeof field, "%s.class", context);
        if (!gc_nonempty_string(d, bnet_json_member(d, item, "class"), field,
                                class_id, sizeof class_id)) return 0;
        station_position = gc_station_index(model, station_id);
        class_position = gc_class_index(model, class_id);
        if (station_position < 0) {
            return fail(GC_CONFIG, "%s refers to unknown station '%s'", context, station_id);
        }
        if (class_position < 0) {
            return fail(GC_CONFIG, "%s refers to unknown class '%s'", context, class_id);
        }
        snprintf(field, sizeof field, "%s.rate", context);
        if (!gc_positive_number(d, bnet_json_member(d, item, "rate"), field,
                                &model->arrivals[i].rate)) return 0;
        if (!model->stations[station_position].has_service_rate[class_position]) {
            return fail(GC_CONFIG,
                        "%s targets class '%s' at station '%s', but no service rate is defined",
                        context, class_id, station_id);
        }
        model->arrivals[i].station = station_position;
        model->arrivals[i].customer_class = class_position;
    }

    model->routing = (gc_route_set *)calloc((size_t)model->station_count * (size_t)model->class_count,
                                            sizeof(gc_route_set));
    if (!model->routing) return fail(GC_CONFIG, "out of memory");
    routing_node = bnet_json_member(d, root, "routing");
    if (routing_node != BNET_JSON_NONE && bnet_json_type_of(d, routing_node) != BNET_JSON_ARRAY) {
        return fail(GC_CONFIG, "routing must be a JSON array");
    }
    for (index = 0; index < bnet_json_count(d, routing_node); index++) {
        int item = bnet_json_at(d, routing_node, index), destinations, dest_index;
        char context[64], field[160], from_station_id[GC_MAX_ID], from_class_id[GC_MAX_ID];
        int from_station, from_class, count;
        gc_route_set *set;
        double total_probability = 0.0, remainder;
        snprintf(context, sizeof context, "routing[%d]", index);
        if (bnet_json_type_of(d, item) != BNET_JSON_OBJECT) {
            return fail(GC_CONFIG, "%s must be a JSON object", context);
        }
        if (!gc_check_keys(d, item, rule_keys, 3, context)) return 0;
        snprintf(field, sizeof field, "%s.from_station", context);
        if (!gc_nonempty_string(d, bnet_json_member(d, item, "from_station"), field,
                                from_station_id, sizeof from_station_id)) return 0;
        snprintf(field, sizeof field, "%s.from_class", context);
        if (!gc_nonempty_string(d, bnet_json_member(d, item, "from_class"), field,
                                from_class_id, sizeof from_class_id)) return 0;
        from_station = gc_station_index(model, from_station_id);
        from_class = gc_class_index(model, from_class_id);
        if (from_station < 0) {
            return fail(GC_CONFIG, "%s refers to unknown source station '%s'", context, from_station_id);
        }
        if (from_class < 0) {
            return fail(GC_CONFIG, "%s refers to unknown source class '%s'", context, from_class_id);
        }
        set = &model->routing[(size_t)from_station * model->class_count + from_class];
        if (set->has_rule) {
            return fail(GC_CONFIG, "duplicate routing rule for class '%s' at station '%s'",
                        from_class_id, from_station_id);
        }
        if (!model->stations[from_station].has_service_rate[from_class]) {
            return fail(GC_CONFIG, "routing source class '%s' at station '%s' has no service rate",
                        from_class_id, from_station_id);
        }
        destinations = bnet_json_member(d, item, "destinations");
        snprintf(field, sizeof field, "%s.destinations", context);
        if (bnet_json_type_of(d, destinations) != BNET_JSON_ARRAY) {
            return fail(GC_CONFIG, "%s must be a JSON array", field);
        }
        count = bnet_json_count(d, destinations);
        if (count == 0) return fail(GC_CONFIG, "%s.destinations cannot be empty", context);
        set->routes = (gc_route *)calloc((size_t)count + 1, sizeof(gc_route));
        if (!set->routes) return fail(GC_CONFIG, "out of memory");
        set->has_rule = 1;
        for (dest_index = 0; dest_index < count; dest_index++) {
            int destination = bnet_json_at(d, destinations, dest_index);
            char dest_context[128], dest_field[256];
            double probability;
            int is_exit, exit_node;
            snprintf(dest_context, sizeof dest_context, "%s.destinations[%d]", context, dest_index);
            if (bnet_json_type_of(d, destination) != BNET_JSON_OBJECT) {
                return fail(GC_CONFIG, "%s must be a JSON object", dest_context);
            }
            if (!gc_check_keys(d, destination, destination_keys, 4, dest_context)) return 0;
            snprintf(dest_field, sizeof dest_field, "%s.probability", dest_context);
            if (!gc_probability(d, bnet_json_member(d, destination, "probability"),
                                dest_field, &probability)) return 0;
            exit_node = bnet_json_member(d, destination, "exit");
            if (exit_node != BNET_JSON_NONE && bnet_json_type_of(d, exit_node) != BNET_JSON_BOOL) {
                return fail(GC_CONFIG, "%s.exit must be a boolean", dest_context);
            }
            is_exit = bnet_json_bool_or(d, exit_node, 0);
            if (is_exit) {
                int k;
                if (bnet_json_member(d, destination, "station") != BNET_JSON_NONE
                    || bnet_json_member(d, destination, "class") != BNET_JSON_NONE) {
                    return fail(GC_CONFIG, "%s cannot combine exit=true with station/class",
                                dest_context);
                }
                for (k = 0; k < set->count; k++) {
                    if (set->routes[k].station < 0) {
                        return fail(GC_CONFIG, "%s contains a duplicate exit destination", context);
                    }
                }
                set->routes[set->count].station = -1;
                set->routes[set->count].customer_class = -1;
                set->routes[set->count].probability = probability;
                set->count++;
            } else {
                char destination_station_id[GC_MAX_ID], destination_class_id[GC_MAX_ID];
                int destination_station, destination_class, k;
                if (exit_node != BNET_JSON_NONE) {
                    return fail(GC_CONFIG,
                                "%s.exit may only be supplied as true for an exit destination",
                                dest_context);
                }
                snprintf(dest_field, sizeof dest_field, "%s.station", dest_context);
                if (!gc_nonempty_string(d, bnet_json_member(d, destination, "station"), dest_field,
                                        destination_station_id, GC_MAX_ID)) return 0;
                snprintf(dest_field, sizeof dest_field, "%s.class", dest_context);
                if (bnet_json_member(d, destination, "class") == BNET_JSON_NONE) {
                    strcpy(destination_class_id, from_class_id);
                } else if (!gc_nonempty_string(d, bnet_json_member(d, destination, "class"),
                                               dest_field, destination_class_id, GC_MAX_ID)) {
                    return 0;
                }
                destination_station = gc_station_index(model, destination_station_id);
                destination_class = gc_class_index(model, destination_class_id);
                if (destination_station < 0) {
                    return fail(GC_CONFIG, "%s refers to unknown station '%s'",
                                dest_context, destination_station_id);
                }
                if (destination_class < 0) {
                    return fail(GC_CONFIG, "%s refers to unknown class '%s'",
                                dest_context, destination_class_id);
                }
                if (!model->stations[destination_station].has_service_rate[destination_class]) {
                    return fail(GC_CONFIG,
                                "%s targets class '%s' at station '%s', but no service rate is defined",
                                dest_context, destination_class_id, destination_station_id);
                }
                for (k = 0; k < set->count; k++) {
                    if (set->routes[k].station == destination_station
                        && set->routes[k].customer_class == destination_class) {
                        return fail(GC_CONFIG,
                                    "%s contains duplicate destination class '%s' at station '%s'",
                                    context, destination_class_id, destination_station_id);
                    }
                }
                set->routes[set->count].station = destination_station;
                set->routes[set->count].customer_class = destination_class;
                set->routes[set->count].probability = probability;
                set->count++;
            }
            total_probability += probability;
        }
        if (total_probability > 1.0 + 1.0e-12) {
            return fail(GC_CONFIG, "%s routing probabilities sum to %.17g, which exceeds 1",
                        context, total_probability);
        }
        if (total_probability > 1.0) {
            int k;
            for (k = 0; k < set->count; k++) set->routes[k].probability /= total_probability;
            total_probability = 1.0;
        }
        remainder = 1.0 - total_probability;
        if (remainder > 1.0e-15) {
            set->routes[set->count].station = -1;
            set->routes[set->count].customer_class = -1;
            set->routes[set->count].probability = remainder;
            set->count++;
        }
    }

    solver_node = bnet_json_member(d, root, "solver");
    if (solver_node != BNET_JSON_NONE && bnet_json_type_of(d, solver_node) != BNET_JSON_OBJECT) {
        return fail(GC_CONFIG, "solver must be a JSON object");
    }
    if (!gc_check_keys(d, solver_node, solver_keys, 4, "solver")) return 0;
    model->tolerance = 1.0e-12;
    model->max_iterations = 200000;
    model->max_states = 200000;
    model->uniformization_slack = 0.05;
    {
        int member = bnet_json_member(d, solver_node, "tolerance");
        if (member != BNET_JSON_NONE
            && !gc_positive_number(d, member, "solver.tolerance", &model->tolerance)) return 0;
        member = bnet_json_member(d, solver_node, "max_iterations");
        if (member != BNET_JSON_NONE
            && !gc_integer(d, member, "solver.max_iterations", 1, &model->max_iterations)) return 0;
        member = bnet_json_member(d, solver_node, "max_states");
        if (member != BNET_JSON_NONE
            && !gc_integer(d, member, "solver.max_states", 1, &model->max_states)) return 0;
        member = bnet_json_member(d, solver_node, "uniformization_slack");
        if (member != BNET_JSON_NONE
            && !gc_positive_number(d, member, "solver.uniformization_slack",
                                   &model->uniformization_slack)) return 0;
    }
    if (model->uniformization_slack > 10.0) {
        return fail(GC_CONFIG, "solver.uniformization_slack must be <= 10");
    }

    /* Openness: every (station, class) pair reachable from an external stream
     * must be able to reach an exit, or the stationary distribution would not
     * be unique. Same two fixed points as the Python, and the same message,
     * with the trapped pairs sorted as labels. */
    {
        size_t pairs = (size_t)model->station_count * (size_t)model->class_count;
        char *reachable = (char *)calloc(pairs, 1);
        char *can_exit = (char *)calloc(pairs, 1);
        int changed = 1;
        size_t k;
        if (!reachable || !can_exit) { free(reachable); free(can_exit); return fail(GC_CONFIG, "out of memory"); }
        for (i = 0; i < model->arrival_count; i++) {
            reachable[(size_t)model->arrivals[i].station * model->class_count
                      + model->arrivals[i].customer_class] = 1;
        }
        while (changed) {
            changed = 0;
            for (k = 0; k < pairs; k++) {
                const gc_route_set *set;
                int r;
                if (!reachable[k]) continue;
                set = gc_routes(model, (int)(k / model->class_count), (int)(k % model->class_count));
                for (r = 0; r < set->count; r++) {
                    size_t target;
                    if (set->routes[r].station < 0) continue;
                    target = (size_t)set->routes[r].station * model->class_count
                           + set->routes[r].customer_class;
                    if (!reachable[target]) { reachable[target] = 1; changed = 1; }
                }
            }
        }
        for (k = 0; k < pairs; k++) {
            const gc_route_set *set;
            int r;
            if (!reachable[k]) continue;
            set = gc_routes(model, (int)(k / model->class_count), (int)(k % model->class_count));
            for (r = 0; r < set->count; r++) {
                if (set->routes[r].station < 0) { can_exit[k] = 1; break; }
            }
        }
        changed = 1;
        while (changed) {
            changed = 0;
            for (k = 0; k < pairs; k++) {
                const gc_route_set *set;
                int r;
                if (!reachable[k] || can_exit[k]) continue;
                set = gc_routes(model, (int)(k / model->class_count), (int)(k % model->class_count));
                for (r = 0; r < set->count; r++) {
                    size_t target;
                    if (set->routes[r].station < 0) continue;
                    target = (size_t)set->routes[r].station * model->class_count
                           + set->routes[r].customer_class;
                    if (can_exit[target]) { can_exit[k] = 1; changed = 1; break; }
                }
            }
        }
        {
            char labels[1024];
            size_t used = 0;
            int trapped = 0;
            char (*sorted_labels)[GC_MAX_ID * 2 + 2] = NULL;
            int label_count = 0, a, b;
            for (k = 0; k < pairs; k++) if (reachable[k] && !can_exit[k]) trapped++;
            if (trapped) {
                sorted_labels = malloc((size_t)trapped * (GC_MAX_ID * 2 + 2));
                if (!sorted_labels) { free(reachable); free(can_exit); return fail(GC_CONFIG, "out of memory"); }
                for (k = 0; k < pairs; k++) {
                    if (!reachable[k] || can_exit[k]) continue;
                    snprintf(sorted_labels[label_count], GC_MAX_ID * 2 + 2, "%s/%s",
                             model->stations[k / model->class_count].id,
                             model->class_ids[k % model->class_count]);
                    label_count++;
                }
                for (a = 1; a < label_count; a++) {
                    char pivot[GC_MAX_ID * 2 + 2];
                    strcpy(pivot, sorted_labels[a]);
                    for (b = a - 1; b >= 0 && strcmp(sorted_labels[b], pivot) > 0; b--) {
                        strcpy(sorted_labels[b + 1], sorted_labels[b]);
                    }
                    strcpy(sorted_labels[b + 1], pivot);
                }
                labels[0] = '\0';
                for (a = 0; a < label_count; a++) {
                    int written = snprintf(labels + used, sizeof labels - used, "%s%s",
                                           a ? ", " : "", sorted_labels[a]);
                    if (written < 0 || (size_t)written >= sizeof labels - used) break;
                    used += (size_t)written;
                }
                free(sorted_labels); free(reachable); free(can_exit);
                return fail(GC_CONFIG,
                            "network is not open: reachable station/class pair%s %s cannot "
                            "reach an exit; the stationary distribution would not be unique",
                            label_count != 1 ? "s" : "", labels);
            }
        }
        free(reachable); free(can_exit);
    }
    return 1;
}

/* ---------------------------------------------------------------- output */

/* `_format_optional`: "n/a" for a ratio with a zero denominator. */
static const char *gc_optional(char *buffer, size_t size, int available, double value)
{
    if (!available) { snprintf(buffer, size, "n/a"); return buffer; }
    snprintf(buffer, size, "%.8g", value);
    return buffer;
}

/* `state_as_json` rendered the way Python's print() renders the dict it
 * returns: {'station': ['class', ...], ...}, stations in model order, single
 * quotes, ", " between entries. */
static void gc_print_state(const gc_model *model, const unsigned char *state)
{
    size_t offsets[64];
    int s, position;
    gc_station_offsets(model, state, offsets);
    putchar('{');
    for (s = 0; s < model->station_count; s++) {
        int queue_length = state[offsets[s]];
        if (s) printf(", ");
        printf("'%s': [", model->stations[s].id);
        for (position = 0; position < queue_length; position++) {
            printf("%s'%s'", position ? ", " : "",
                   model->class_ids[state[offsets[s] + 1 + position]]);
        }
        putchar(']');
    }
    putchar('}');
}

/* `sorted(..., key=probability, reverse=True)` — Python's sort is STABLE, so
 * equal probabilities keep state order. An unstable sort would list the same
 * states in a different order on a chain with symmetry, which is common here. */
static void gc_sort_by_probability(const double *probabilities, long *order, long count)
{
    long i, j;
    for (i = 0; i < count; i++) order[i] = i;
    for (i = 1; i < count; i++) {
        long pivot = order[i];
        double key = probabilities[pivot];
        for (j = i - 1; j >= 0 && probabilities[order[j]] < key; j--) order[j + 1] = order[j];
        order[j + 1] = pivot;
    }
}

static void gc_print_human(const gc_model *model, const gc_chain *chain,
                           const gc_solution *solution, const gc_measures *measures,
                           const gc_state_set *states, long top_states)
{
    int classes = model->class_count, s, c;
    char a[64], b[64];

    printf("Generic finite-state CTMC \xe2\x80\x94 loss on full\n");
    printf("Model: %s\n", model->name);
    printf("States: %ld  Transitions: %ld\n", chain->count, chain->off_diagonal_count);
    printf("Stationary solve: %s after %ld iterations; ||pi Q||_1=%.3e\n",
           solution->converged ? "converged" : "NOT CONVERGED",
           solution->iterations, solution->generator_residual_l1);
    printf("Network: E[N]=%.8g  external accepted=%.8g  external loss P=%s\n",
           measures->mean_total_number, measures->total_external_accepted,
           gc_optional(a, sizeof a, measures->has_external_loss_probability,
                       measures->external_loss_probability));
    printf("Flow residuals: population=%.3e  max station/class=%.3e\n",
           measures->population_flow_residual, measures->maximum_class_balance_residual);

    for (s = 0; s < model->station_count; s++) {
        double station_mean = 0.0, station_in_service = 0.0, station_completion = 0.0;
        double station_accepted = 0.0;
        for (c = 0; c < classes; c++) {
            size_t slot = (size_t)s * classes + c;
            station_mean += measures->mean_number[slot];
            station_in_service += measures->mean_in_service[slot];
            station_completion += measures->completions[slot];
        }
        /* `sum(external_accepted[s]) + sum(internal_accepted[s])`, in that
         * order — two separate row sums, then added. */
        {
            double external = 0.0, internal = 0.0;
            for (c = 0; c < classes; c++) external += measures->external_accepted[(size_t)s * classes + c];
            for (c = 0; c < classes; c++) internal += measures->internal_accepted[(size_t)s * classes + c];
            station_accepted = external + internal;
        }
        printf("Station %s: E[N]=%.8g  utilization=%.8g  P(full)=%.8g  throughput=%.8g  E[T]=%s\n",
               model->stations[s].id, station_mean,
               station_in_service / model->stations[s].servers,
               measures->probability_full[s], station_completion,
               gc_optional(a, sizeof a, station_accepted > 0.0,
                           station_accepted > 0.0 ? station_mean / station_accepted : 0.0));
        for (c = 0; c < classes; c++) {
            size_t slot = (size_t)s * classes + c;
            double accepted = measures->external_accepted[slot] + measures->internal_accepted[slot];
            if (accepted == 0.0 && measures->mean_number[slot] == 0.0) continue;
            printf("  Class %s: E[N]=%.8g  accepted=%.8g  completed=%.8g  E[T]=%s\n",
                   model->class_ids[c], measures->mean_number[slot], accepted,
                   measures->completions[slot],
                   gc_optional(b, sizeof b, accepted > 0.0,
                               accepted > 0.0 ? measures->mean_number[slot] / accepted : 0.0));
        }
    }

    if (top_states > 0) {
        long *order = (long *)malloc((size_t)chain->count * sizeof(long));
        long shown = top_states < chain->count ? top_states : chain->count, i;
        if (!order) return;
        gc_sort_by_probability(solution->probabilities, order, chain->count);
        printf("Top stationary states:\n");
        for (i = 0; i < shown; i++) {
            printf("  %.8g  ", solution->probabilities[order[i]]);
            gc_print_state(model, states->bytes + states->offset[order[i]]);
            putchar('\n');
        }
        free(order);
    }
}

static const char *gc_repr(char *buffer, size_t size, double value)
{
    int precision;
    if (!isfinite(value)) { snprintf(buffer, size, "null"); return buffer; }
    for (precision = 1; precision <= 17; precision++) {
        snprintf(buffer, size, "%.*g", precision, value);
        if (strtod(buffer, NULL) == value) break;
    }
    return buffer;
}

static void gc_write_json(FILE *out, const gc_model *model, const gc_chain *chain,
                          const gc_solution *solution, const gc_measures *measures)
{
    char buffer[64];
    int classes = model->class_count, s, c;
    fprintf(out, "{\n  \"status\": \"ok\",\n  \"engine\": \"c\",\n");
    fprintf(out, "  \"model\": {\"name\": \"%s\"},\n", model->name);
    fprintf(out, "  \"solver\": {\"state_count\": %ld, \"off_diagonal_transition_count\": %ld, "
                 "\"converged\": %s, \"iterations\": %ld, \"generator_residual_l1\": %s},\n",
            chain->count, chain->off_diagonal_count, solution->converged ? "true" : "false",
            solution->iterations, gc_repr(buffer, sizeof buffer, solution->generator_residual_l1));
    fprintf(out, "  \"measures\": {\"network\": {\"mean_total_number\": %s",
            gc_repr(buffer, sizeof buffer, measures->mean_total_number));
    fprintf(out, ", \"external_accepted_rate\": %s",
            gc_repr(buffer, sizeof buffer, measures->total_external_accepted));
    fprintf(out, ", \"external_loss_probability\": %s",
            measures->has_external_loss_probability
                ? gc_repr(buffer, sizeof buffer, measures->external_loss_probability) : "null");
    fprintf(out, ", \"population_flow_residual\": %s",
            gc_repr(buffer, sizeof buffer, measures->population_flow_residual));
    fprintf(out, ", \"maximum_station_class_flow_residual\": %s},\n",
            gc_repr(buffer, sizeof buffer, measures->maximum_class_balance_residual));
    fprintf(out, "    \"stations\": [");
    for (s = 0; s < model->station_count; s++) {
        double station_mean = 0.0, station_in_service = 0.0;
        for (c = 0; c < classes; c++) {
            station_mean += measures->mean_number[(size_t)s * classes + c];
            station_in_service += measures->mean_in_service[(size_t)s * classes + c];
        }
        fprintf(out, "%s{\"id\": \"%s\", \"mean_number\": %s", s ? ", " : "",
                model->stations[s].id, gc_repr(buffer, sizeof buffer, station_mean));
        fprintf(out, ", \"server_utilization\": %s",
                gc_repr(buffer, sizeof buffer, station_in_service / model->stations[s].servers));
        fprintf(out, ", \"probability_full\": %s}",
                gc_repr(buffer, sizeof buffer, measures->probability_full[s]));
    }
    fprintf(out, "]}\n}\n");
}

static void usage(FILE *out, const char *program)
{
    fprintf(out,
        "usage: %s <model.json|-> [--json]\n"
        "\n"
        "Exact stationary distribution of a finite multiclass loss network by\n"
        "sparse uniformized power iteration (C engine). Reads the same document\n"
        "solver.py reads and prints byte-identical output.\n"
        "\n"
        "  --json        structured output instead of the report\n"
        "  --version     print the engine identity and exit\n", program);
}

int main(int argc, char **argv)
{
    const char *path = NULL;
    const char *output_path = NULL;
    long top_states = 0;
    int want_json = 0, i, exit_code = 0;
    /* Overrides applied after parsing, as the Python applies them: the file's
     * value is validated first and the flag replaces it. */
    int has_tolerance = 0, has_max_iterations = 0, has_max_states = 0, has_slack = 0;
    double tolerance_override = 0.0, slack_override = 0.0;
    long max_iterations_override = 0, max_states_override = 0;
    bnet_json document;
    gc_model model;
    gc_state_set states;
    gc_chain chain;
    gc_solution solution;
    gc_measures measures;

    memset(&model, 0, sizeof model);
    memset(&states, 0, sizeof states);
    memset(&chain, 0, sizeof chain);
    memset(&solution, 0, sizeof solution);
    memset(&measures, 0, sizeof measures);

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--json") == 0) want_json = 1;
        else if (strcmp(argv[i], "--include-states") == 0) { /* JSON-only in the Python */ }
        else if (strcmp(argv[i], "--top-states") == 0) {
            if (++i >= argc) { fprintf(stderr, "%s: --top-states needs a value\n", argv[0]); return 2; }
            top_states = strtol(argv[i], NULL, 10);
            if (top_states < 0) { fprintf(stderr, "error: --top-states must be >= 0\n"); return 2; }
        }
        else if (strcmp(argv[i], "--output") == 0) {
            if (++i >= argc) { fprintf(stderr, "%s: --output needs a path\n", argv[0]); return 2; }
            output_path = argv[i];
        }
        else if (strcmp(argv[i], "--tolerance") == 0) {
            if (++i >= argc) { fprintf(stderr, "%s: --tolerance needs a value\n", argv[0]); return 2; }
            tolerance_override = strtod(argv[i], NULL); has_tolerance = 1;
        }
        else if (strcmp(argv[i], "--max-iterations") == 0) {
            if (++i >= argc) { fprintf(stderr, "%s: --max-iterations needs a value\n", argv[0]); return 2; }
            max_iterations_override = strtol(argv[i], NULL, 10); has_max_iterations = 1;
        }
        else if (strcmp(argv[i], "--max-states") == 0) {
            if (++i >= argc) { fprintf(stderr, "%s: --max-states needs a value\n", argv[0]); return 2; }
            max_states_override = strtol(argv[i], NULL, 10); has_max_states = 1;
        }
        else if (strcmp(argv[i], "--uniformization-slack") == 0) {
            if (++i >= argc) { fprintf(stderr, "%s: --uniformization-slack needs a value\n", argv[0]); return 2; }
            slack_override = strtod(argv[i], NULL); has_slack = 1;
        }
        else if (strcmp(argv[i], "--version") == 0) {
            printf("fbna_gc (Qnet generic finite CTMC, C engine) 1.0.0\n");
            return 0;
        } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            usage(stdout, argv[0]);
            return 0;
        } else if (strcmp(argv[i], "--qnet-loadability-probe") == 0) {
            return 0;
        } else if (argv[i][0] == '-' && argv[i][1] != '\0' && strcmp(argv[i], "-") != 0) {
            fprintf(stderr, "%s: unknown option %s\n", argv[0], argv[i]);
            usage(stderr, argv[0]);
            return 2;
        } else if (!path) {
            path = argv[i];
        } else {
            fprintf(stderr, "%s: unexpected argument %s\n", argv[0], argv[i]);
            return 2;
        }
    }
    if (!path) { usage(stderr, argv[0]); return 2; }

    if (!bnet_json_parse_file(&document, path)) {
        fprintf(stderr, "error: %s\n", document.error);
        bnet_json_free(&document);
        return 2;
    }
    if (gc_parse_model(&document, &model)) {
        if (has_tolerance) model.tolerance = tolerance_override;
        if (has_max_iterations) model.max_iterations = max_iterations_override;
        if (has_max_states) model.max_states = max_states_override;
        if (has_slack) model.uniformization_slack = slack_override;
    }
    if (g_error_kind != GC_OK
        || !gc_enumerate_chain(&model, &states, &chain)
        || !gc_solve_stationary(&model, &chain, &solution)
        || !gc_compute_measures(&model, &states, &chain, &solution, &measures)) {
        /* `print("error: {}".format(error), file=sys.stderr)` and exit 2. */
        fprintf(stderr, "error: %s\n", g_error_message);
        exit_code = 2;
        goto done;
    }
    if (output_path) {
        FILE *out = fopen(output_path, "w");
        if (!out) {
            fprintf(stderr, "error: cannot write %s\n", output_path);
            exit_code = 2;
            goto done;
        }
        gc_write_json(out, &model, &chain, &solution, &measures);
        fclose(out);
    }
    if (want_json) gc_write_json(stdout, &model, &chain, &solution, &measures);
    else           gc_print_human(&model, &chain, &solution, &measures, &states, top_states);
    if (!solution.converged) {
        fprintf(stderr, "error: stationary iteration did not converge; increase "
                        "max_iterations or relax tolerance\n");
        exit_code = 3;
    }

done:
    gc_measures_free(&measures);
    free(solution.probabilities);
    gc_chain_free(&chain);
    gc_state_set_free(&states);
    gc_model_free(&model);
    bnet_json_free(&document);
    return exit_code;
}
