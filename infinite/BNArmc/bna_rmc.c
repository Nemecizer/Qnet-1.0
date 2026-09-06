/*
 * bna_rmc.c — regenerative Monte Carlo for open Markovian queueing networks.
 *
 * The C engine for `Run > Regenerative Monte Carlo`. `regenerative_mc.py` in
 * this directory is the other one; Settings > Solvers > Solver Engine picks
 * between them, and the GUI passes the same exported document to whichever it
 * runs.
 *
 * THE CONTRACT BETWEEN THE TWO ENGINES
 *
 * The report a person reads is byte-identical. Not "agrees within the
 * confidence interval" — identical, character for character. That is
 * achievable because a regenerative simulation is a deterministic function of
 * its random stream, and `common/bnet_pyrandom.h` reproduces CPython's
 * `random.Random` exactly, down to the seeding, so the two engines visit the
 * same events in the same order and accumulate the same rewards.
 *
 * That is what makes the Settings choice honest. If the engines drew different
 * streams the user would be choosing between two samples and a disagreement
 * would be unfalsifiable; as it stands, a disagreement is a bug in one of them
 * and `tests/test_engine_parity.sh` names it.
 *
 * Two departures, both measured, both deliberate, and both enforced rather
 * than hand-waved by that test:
 *
 *   1. In the 17-significant-digit machine records, `ci_half_width`, `ci_low`
 *      and `ci_high` agree only to about 1.7e-12 relative. Those three are the
 *      only values that pass through a Student-t quantile, and CPython ships
 *      its OWN lgamma (a Lanczos approximation) rather than calling the
 *      platform's; measured, the two lgammas differ by up to 1.6e-15 relative,
 *      and the quantile's 100-step bisection amplifies that. It is orders of
 *      magnitude below the Monte Carlo standard error those fields qualify,
 *      and it does not reach the six decimals the report prints — which is why
 *      the report is identical anyway.
 *
 *   2. `stopping.maximum_wall_seconds` stops a run by elapsed time, and this
 *      engine is about 250x faster, so a document whose run is cut short by
 *      that safeguard stops at a different cycle in each engine. That is the
 *      safeguard working at two speeds, not a disagreement about the method.
 *      Every other stopping rule — cycles, events, simulated time, the
 *      sequential precision target — is deterministic and agrees exactly.
 *
 * Consequences worth knowing before editing:
 *   - Arithmetic order is load-bearing. Where the Python uses math.fsum this
 *     file uses bnet_fsum (Shewchuk exact summation), and where it accumulates
 *     with += this file does too, in the same order.
 *   - The event list is built in the same order (external events first, in
 *     class-major order, then service events by node), because the selection
 *     scan walks it in order and a reordering would pick a different event for
 *     the same uniform draw.
 *   - Output formatting is %.6f / %.17g to match Python's f"{x:.6f}" and
 *     format(x, ".17g").
 *
 * Speed is the point. Measured on this machine over a two-node two-class
 * network: 200,000 cycles in 10.10 s under Python and 0.04 s here, a factor of
 * 252. A regenerative confidence interval narrows as 1/sqrt(cycles), so the
 * same wall-clock budget buys roughly sixteen times the precision.
 */

#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "../../common/bnet_json.h"
#include "../../common/bnet_pyrandom.h"
#include "../../common/bnet_fsum.h"
#include "../../common/bnet_memcheck.h"

#define RMC_OK               0
#define RMC_INVALID_INPUT    1
#define RMC_STABILITY        2
#define RMC_CYCLE_LIMIT      3
#define RMC_INTERNAL         4

static const char *rmc_error_code_name(int kind)
{
    switch (kind) {
    case RMC_INVALID_INPUT: return "invalid_input";
    case RMC_STABILITY:     return "stability_check_failed";
    case RMC_CYCLE_LIMIT:   return "cycle_safeguard_exceeded";
    default:                return "simulation_error";
    }
}

/* One error slot for the whole program: every failure path fills it and
 * returns, and main prints it in the same shape the Python prints. */
static int  g_error_kind = RMC_OK;
static char g_error_message[512];

static int fail(int kind, const char *format, ...)
{
    va_list args;
    if (g_error_kind == RMC_OK) {          /* keep the first failure */
        g_error_kind = kind;
        va_start(args, format);
        vsnprintf(g_error_message, sizeof g_error_message, format, args);
        va_end(args);
    }
    return 0;
}

/* ------------------------------------------------------------------ model */

typedef struct {
    char   id[128];
    int    servers;
    double service_rate;
    int    capacity;            /* -1 for an infinite buffer */
} rmc_node;

typedef struct {
    char    id[128];
    double *external_rates;     /* [node_count] */
    double *routing;            /* [node_count * node_count], row-major by source */
} rmc_class;

typedef struct {
    double confidence;
    double absolute_half_width;
    double relative_half_width;
    char **monitored_metrics;
    int    monitored_count;
    int    minimum_cycles;
    double minimum_effective_cycles;
    int    minimum_positive_cycles;
    int    check_every_cycles;
    long   maximum_cycles;
    long   maximum_events;
    double maximum_simulated_time;
    double maximum_cycle_time;
    long   maximum_events_per_cycle;
    double maximum_wall_seconds;
} rmc_stopping;

typedef struct {
    int    enabled;             /* 0 = "none", 1 = importance_sampling_mm1k */
    double arrival_rate_multiplier;
    double service_rate_multiplier;
} rmc_rare_event;

typedef struct {
    char           name[256];
    rmc_node      *nodes;
    int            node_count;
    rmc_class     *classes;
    int            class_count;
    int           *initial_jobs;       /* [node_count * class_count] */
    unsigned long long base_seed;
    unsigned long long stream;
    rmc_stopping   stopping;
    rmc_rare_event rare_event;
    double        *traffic_rates;      /* [class_count * node_count] */
    double        *offered_loads;      /* [node_count] */
    int            finite_buffers;
} rmc_model;

/* ------------------------------------------------- reward slots and metrics */

/*
 * The Python keeps per-cycle rewards in a dict keyed by strings like
 * "area.node_class.cpu.batch". Building the same strings per event in C would
 * cost more than the simulation, so every key a model can produce is
 * enumerated once at model-build time and the simulator indexes a dense array.
 * The names are still built and kept, because the metric definitions refer to
 * rewards by name exactly as the Python does and resolving them by string once
 * is what proves the two engines are accumulating the same quantities.
 */
typedef struct {
    char **names;
    int    count;
    int    capacity;
} rmc_slots;

static int rmc_slot_find(const rmc_slots *slots, const char *name)
{
    int i;
    for (i = 0; i < slots->count; i++) {
        if (strcmp(slots->names[i], name) == 0) return i;
    }
    return -1;
}

static int rmc_slot_intern(rmc_slots *slots, const char *name)
{
    int existing = rmc_slot_find(slots, name);
    if (existing >= 0) return existing;
    if (slots->count == slots->capacity) {
        int cap = slots->capacity ? slots->capacity * 2 : 32;
        char **grown = (char **)realloc(slots->names, (size_t)cap * sizeof *grown);
        if (!grown) { fail(RMC_INTERNAL, "out of memory interning reward slots"); return -1; }
        slots->names = grown;
        slots->capacity = cap;
    }
    slots->names[slots->count] = strdup(name);
    if (!slots->names[slots->count]) { fail(RMC_INTERNAL, "out of memory"); return -1; }
    return slots->count++;
}

typedef struct {
    char   key[320];
    char   description[320];
    int    numerator_slot;
    int    denominator_slot;
    double denominator_multiplier;
    int    has_lower_bound;
    double lower_bound;
    int    has_upper_bound;
    double upper_bound;
    int    event_probability;
} rmc_metric;

/* --------------------------------------------------------- ratio estimator */

typedef struct {
    long   cycles;
    double sum_a, sum_b, sum_a2, sum_b2, sum_ab, max_b;
    double raw_sum_y, raw_sum_d;
    long   denominator_positive_cycles;
    long   numerator_positive_cycles;
} rmc_accumulator;

/* What `RatioAccumulator.core()` returns, as a struct. */
typedef struct {
    int    available;
    double estimate;
    long   cycles;
    int    has_standard_error;
    double standard_error;
    double centered_cycle_variance_scaled;
    double effective_cycles;
    double largest_denominator_weight_fraction;
    long   denominator_positive_cycles;
    long   numerator_positive_cycles;
    double observed_numerator_total;
    double observed_denominator_total;
} rmc_core;

static void rmc_accumulator_rescale(rmc_accumulator *a, double factor)
{
    double factor2 = factor * factor;
    a->sum_a  *= factor;
    a->sum_b  *= factor;
    a->sum_a2 *= factor2;
    a->sum_b2 *= factor2;
    a->sum_ab *= factor2;
    a->max_b  *= factor;
}

static void rmc_accumulator_add(rmc_accumulator *a, double weight,
                                double numerator, double denominator)
{
    double x = weight * numerator;
    double y = weight * denominator;
    a->cycles += 1;
    a->sum_a  += x;
    a->sum_b  += y;
    a->sum_a2 += x * x;
    a->sum_b2 += y * y;
    a->sum_ab += x * y;
    if (y > a->max_b) a->max_b = y;
    a->raw_sum_y += numerator;
    a->raw_sum_d += denominator;
    if (denominator > 0.0) a->denominator_positive_cycles += 1;
    if (numerator > 0.0)   a->numerator_positive_cycles += 1;
}

/* DBL_EPSILON without pulling in float.h's other names. */
#define RMC_DBL_EPSILON 2.2204460492503131e-16

static int rmc_accumulator_core(const rmc_accumulator *a, const rmc_metric *m, rmc_core *out)
{
    double estimate, effective, z_squares, roundoff, t;
    memset(out, 0, sizeof *out);
    out->cycles = a->cycles;
    out->observed_numerator_total = a->raw_sum_y;
    out->observed_denominator_total = a->raw_sum_d;
    if (a->cycles < 1 || a->sum_b <= 0.0) {
        out->available = 0;
        return 1;
    }
    estimate = a->sum_a / a->sum_b;
    effective = (a->sum_b2 > 0.0) ? (a->sum_b * a->sum_b / a->sum_b2) : 0.0;
    z_squares = a->sum_a2 - 2.0 * estimate * a->sum_ab + estimate * estimate * a->sum_b2;
    roundoff = 1.0;
    t = fabs(a->sum_a2);                       if (t > roundoff) roundoff = t;
    t = fabs(2.0 * estimate * a->sum_ab);      if (t > roundoff) roundoff = t;
    t = fabs(estimate * estimate * a->sum_b2); if (t > roundoff) roundoff = t;
    roundoff *= 128.0 * RMC_DBL_EPSILON;
    if (z_squares < 0.0 && fabs(z_squares) <= roundoff) z_squares = 0.0;
    if (z_squares < 0.0) {
        return fail(RMC_INTERNAL, "negative regenerative variance for metric %s", m->key);
    }
    out->available = 1;
    out->estimate = estimate;
    out->effective_cycles = effective;
    out->largest_denominator_weight_fraction = a->max_b / a->sum_b;
    out->denominator_positive_cycles = a->denominator_positive_cycles;
    out->numerator_positive_cycles = a->numerator_positive_cycles;
    if (a->cycles >= 2) {
        out->has_standard_error = 1;
        out->standard_error = sqrt((double)a->cycles * z_squares / (double)(a->cycles - 1)) / a->sum_b;
        out->centered_cycle_variance_scaled = z_squares / (double)(a->cycles - 1);
    }
    return 1;
}

/* --------------------------------------------------------- Student t tools */

/* Lentz continued fraction for the incomplete beta, iteration for iteration
 * the same as the Python's `_continued_fraction_beta`. */
static int rmc_beta_cf(double a, double b, double x, double *out)
{
    const int maximum_iterations = 300;
    const double epsilon = 3.0e-14;
    /* sys.float_info.min / epsilon */
    const double tiny = 2.2250738585072014e-308 / 3.0e-14;
    double qab = a + b, qap = a + 1.0, qam = a - 1.0;
    double c = 1.0, d, result, aa, delta;
    int iteration;
    d = 1.0 - qab * x / qap;
    if (fabs(d) < tiny) d = tiny;
    d = 1.0 / d;
    result = d;
    for (iteration = 1; iteration <= maximum_iterations; iteration++) {
        double m2 = 2.0 * iteration;
        aa = iteration * (b - iteration) * x / ((qam + m2) * (a + m2));
        d = 1.0 + aa * d;
        if (fabs(d) < tiny) d = tiny;
        c = 1.0 + aa / c;
        if (fabs(c) < tiny) c = tiny;
        d = 1.0 / d;
        result *= d * c;
        aa = -(a + iteration) * (qab + iteration) * x / ((a + m2) * (qap + m2));
        d = 1.0 + aa * d;
        if (fabs(d) < tiny) d = tiny;
        c = 1.0 + aa / c;
        if (fabs(c) < tiny) c = tiny;
        d = 1.0 / d;
        delta = d * c;
        result *= delta;
        if (fabs(delta - 1.0) <= epsilon) { *out = result; return 1; }
    }
    return fail(RMC_INTERNAL, "incomplete-beta continued fraction did not converge");
}

static int rmc_regularized_incomplete_beta(double a, double b, double x, double *out)
{
    double front, cf;
    if (a <= 0.0 || b <= 0.0 || !(x >= 0.0 && x <= 1.0)) {
        return fail(RMC_INVALID_INPUT, "invalid incomplete-beta arguments");
    }
    if (x == 0.0) { *out = 0.0; return 1; }
    if (x == 1.0) { *out = 1.0; return 1; }
    front = exp(lgamma(a + b) - lgamma(a) - lgamma(b) + a * log(x) + b * log1p(-x));
    if (x < (a + 1.0) / (a + b + 2.0)) {
        if (!rmc_beta_cf(a, b, x, &cf)) return 0;
        *out = front * cf / a;
        return 1;
    }
    if (!rmc_beta_cf(b, a, 1.0 - x, &cf)) return 0;
    *out = 1.0 - front * cf / b;
    return 1;
}

static int rmc_student_t_cdf(double value, long degrees_freedom, double *out)
{
    double x, tail_twice;
    if (degrees_freedom <= 0) {
        return fail(RMC_INVALID_INPUT, "Student t degrees of freedom must be positive");
    }
    if (value == 0.0) { *out = 0.5; return 1; }
    x = (double)degrees_freedom / ((double)degrees_freedom + value * value);
    if (!rmc_regularized_incomplete_beta((double)degrees_freedom / 2.0, 0.5, x, &tail_twice)) return 0;
    *out = (value > 0.0) ? (1.0 - 0.5 * tail_twice) : (0.5 * tail_twice);
    return 1;
}

/* Bisection to 100 halvings, matching the Python quantile exactly: the same
 * bracket search, the same fixed iteration count, the same midpoint return. */
static int rmc_student_t_quantile(double probability, long degrees_freedom, double *out)
{
    double lower = 0.0, upper = 1.0, cdf;
    int i;
    if (!(probability > 0.0 && probability < 1.0)) {
        return fail(RMC_INVALID_INPUT, "Student t probability must be strictly between zero and one");
    }
    if (probability == 0.5) { *out = 0.0; return 1; }
    if (probability < 0.5) {
        double positive;
        if (!rmc_student_t_quantile(1.0 - probability, degrees_freedom, &positive)) return 0;
        *out = -positive;
        return 1;
    }
    for (;;) {
        if (!rmc_student_t_cdf(upper, degrees_freedom, &cdf)) return 0;
        if (!(cdf < probability)) break;
        upper *= 2.0;
        if (upper > 1.0e12) { *out = HUGE_VAL; return 1; }
    }
    for (i = 0; i < 100; i++) {
        double middle = (lower + upper) / 2.0;
        if (!rmc_student_t_cdf(middle, degrees_freedom, &cdf)) return 0;
        if (cdf < probability) lower = middle; else upper = middle;
    }
    *out = (lower + upper) / 2.0;
    return 1;
}

/* ------------------------------------------------------ traffic equations */

/* Dense scaled-partial-pivot solve, the same pivot rule and the same exact
 * back-substitution sum as the Python's `_solve_linear`. */
static int rmc_solve_linear(double *matrix, double *rhs, int n, double *answer)
{
    double *aug = NULL, *scales = NULL;
    int i, j, column, row, ok = 1;
    if (n <= 0) return fail(RMC_INVALID_INPUT, "traffic equation is not square");
    aug = (double *)malloc((size_t)n * (size_t)(n + 1) * sizeof *aug);
    scales = (double *)malloc((size_t)n * sizeof *scales);
    if (!aug || !scales) { free(aug); free(scales); return fail(RMC_INTERNAL, "out of memory"); }
    for (i = 0; i < n; i++) {
        double biggest = 0.0;
        for (j = 0; j < n; j++) {
            double v = matrix[i * n + j];
            aug[i * (n + 1) + j] = v;
            if (fabs(v) > biggest) biggest = fabs(v);
        }
        aug[i * (n + 1) + n] = rhs[i];
        scales[i] = biggest;
        if (biggest == 0.0) ok = 0;
    }
    if (!ok) {
        free(aug); free(scales);
        return fail(RMC_INVALID_INPUT, "routing matrix has a closed class (singular traffic equations)");
    }
    for (column = 0; column < n; column++) {
        int pivot = column;
        double best = fabs(aug[column * (n + 1) + column]) / scales[column];
        double floor_value, pivot_value;
        for (row = column + 1; row < n; row++) {
            double candidate = fabs(aug[row * (n + 1) + column]) / scales[row];
            if (candidate > best) { best = candidate; pivot = row; }
        }
        floor_value = 16.0 * RMC_DBL_EPSILON * (double)n * scales[pivot];
        if (fabs(aug[pivot * (n + 1) + column]) <= floor_value) {
            free(aug); free(scales);
            return fail(RMC_INVALID_INPUT,
                        "routing matrix has a closed or numerically singular class");
        }
        if (pivot != column) {
            for (j = 0; j <= n; j++) {
                double t = aug[column * (n + 1) + j];
                aug[column * (n + 1) + j] = aug[pivot * (n + 1) + j];
                aug[pivot * (n + 1) + j] = t;
            }
            { double t = scales[column]; scales[column] = scales[pivot]; scales[pivot] = t; }
        }
        pivot_value = aug[column * (n + 1) + column];
        for (row = column + 1; row < n; row++) {
            double factor = aug[row * (n + 1) + column] / pivot_value;
            aug[row * (n + 1) + column] = 0.0;
            for (j = column + 1; j <= n; j++) {
                aug[row * (n + 1) + j] -= factor * aug[column * (n + 1) + j];
            }
        }
    }
    for (row = n - 1; row >= 0; row--) {
        bnet_fsum tail;
        double remainder;
        bnet_fsum_init(&tail);
        for (j = row + 1; j < n; j++) bnet_fsum_add(&tail, aug[row * (n + 1) + j] * answer[j]);
        remainder = aug[row * (n + 1) + n] - bnet_fsum_value(&tail);
        answer[row] = remainder / aug[row * (n + 1) + row];
    }
    free(aug); free(scales);
    return 1;
}

/* Reachability of an exit from every node, by the same fixed point. */
static int rmc_all_nodes_reach_exit(const rmc_class *customer, int n)
{
    char *can_exit = (char *)calloc((size_t)n, 1);
    int changed = 1, source, destination, total = 0;
    if (!can_exit) { fail(RMC_INTERNAL, "out of memory"); return 0; }
    for (source = 0; source < n; source++) {
        double row_sum = bnet_fsum_array(customer->routing + (size_t)source * n, n);
        if (row_sum < 1.0 - 1.0e-14) can_exit[source] = 1;
    }
    while (changed) {
        changed = 0;
        for (source = 0; source < n; source++) {
            if (can_exit[source]) continue;
            for (destination = 0; destination < n; destination++) {
                if (customer->routing[(size_t)source * n + destination] > 0.0 && can_exit[destination]) {
                    can_exit[source] = 1;
                    changed = 1;
                    break;
                }
            }
        }
    }
    for (source = 0; source < n; source++) total += can_exit[source] ? 1 : 0;
    free(can_exit);
    return total == n;
}

static int rmc_traffic_rates(const rmc_class *customer, int n, double *rates)
{
    double *equations = (double *)malloc((size_t)n * (size_t)n * sizeof *equations);
    double tolerance, biggest = 0.0, smallest, residual = 0.0;
    int i, j;
    if (!equations) return fail(RMC_INTERNAL, "out of memory");
    for (i = 0; i < n; i++) {
        for (j = 0; j < n; j++) {
            equations[i * n + j] = (i == j ? 1.0 : 0.0) - customer->routing[(size_t)j * n + i];
        }
    }
    if (!rmc_solve_linear(equations, customer->external_rates, n, rates)) { free(equations); return 0; }
    free(equations);
    for (i = 0; i < n; i++) if (rates[i] > biggest) biggest = rates[i];
    tolerance = 2.0e-11 * (biggest > 1.0 ? biggest : 1.0);
    smallest = rates[0];
    for (i = 1; i < n; i++) if (rates[i] < smallest) smallest = rates[i];
    if (smallest < -tolerance) {
        return fail(RMC_INVALID_INPUT,
                    "traffic equations for class '%s' produced a negative rate", customer->id);
    }
    for (i = 0; i < n; i++) if (rates[i] < 0.0) rates[i] = 0.0;
    for (i = 0; i < n; i++) {
        bnet_fsum feed;
        double value;
        bnet_fsum_init(&feed);
        for (j = 0; j < n; j++) bnet_fsum_add(&feed, rates[j] * customer->routing[(size_t)j * n + i]);
        value = fabs(rates[i] - customer->external_rates[i] - bnet_fsum_value(&feed));
        if (value > residual) residual = value;
    }
    if (residual > tolerance) {
        return fail(RMC_INVALID_INPUT,
                    "traffic equations for class '%s' are ill-conditioned", customer->id);
    }
    return 1;
}

/* Python's repr(float): the fewest digits that read back as the same double.
 * Used wherever a value is quoted back to the reader, so the two engines word
 * an error the same way instead of one saying 1.4 and the other
 * 1.3999999999999999. */
static const char *rmc_repr(char *buffer, size_t size, double value)
{
    int precision;
    if (!isfinite(value)) { snprintf(buffer, size, "%s", value > 0 ? "inf" : (value < 0 ? "-inf" : "nan")); return buffer; }
    for (precision = 1; precision <= 17; precision++) {
        snprintf(buffer, size, "%.*g", precision, value);
        if (strtod(buffer, NULL) == value) break;
    }
    return buffer;
}

/* --------------------------------------------------------------- parsing */

/* The Python refuses unknown keys rather than ignoring them, because a
 * misspelled option that is silently dropped is a wrong answer with no
 * warning. Same rule here, same message. */
static int rmc_check_unknown(const bnet_json *d, int object, const char *const *allowed,
                             int allowed_count, const char *path)
{
    const char *unknown[32];
    int unknown_count = 0, child, i, j;
    char joined[512];
    size_t used = 0;
    if (object == BNET_JSON_NONE) return 1;
    for (child = d->nodes[object].first; child != BNET_JSON_NONE; child = d->nodes[child].next) {
        const char *key = bnet_json_key_of(d, child);
        int known = 0;
        if (!key) continue;
        for (i = 0; i < allowed_count; i++) {
            if (strcmp(key, allowed[i]) == 0) { known = 1; break; }
        }
        if (!known && unknown_count < (int)(sizeof unknown / sizeof unknown[0])) {
            unknown[unknown_count++] = key;
        }
    }
    if (unknown_count == 0) return 1;
    /* Sorted and comma-joined, as the Python's `_check_unknown` reports them:
     * the message is part of what the two engines have to agree on. */
    for (i = 1; i < unknown_count; i++) {
        const char *pivot = unknown[i];
        for (j = i - 1; j >= 0 && strcmp(unknown[j], pivot) > 0; j--) unknown[j + 1] = unknown[j];
        unknown[j + 1] = pivot;
    }
    joined[0] = '\0';
    for (i = 0; i < unknown_count; i++) {
        int written = snprintf(joined + used, sizeof joined - used, "%s%s",
                               i ? ", " : "", unknown[i]);
        if (written < 0 || (size_t)written >= sizeof joined - used) break;
        used += (size_t)written;
    }
    return fail(RMC_INVALID_INPUT, "%s contains unknown field(s): %s", path, joined);
}

static int rmc_is_mapping(const bnet_json *d, int node, const char *path)
{
    if (node == BNET_JSON_NONE) return 1;                 /* absent -> {} */
    if (bnet_json_type_of(d, node) != BNET_JSON_OBJECT) {
        return fail(RMC_INVALID_INPUT, "%s must be a JSON object", path);
    }
    return 1;
}

static int rmc_finite_float(const bnet_json *d, int node, const char *path, double *out)
{
    double v;
    if (!bnet_json_number(d, node, &v)) return fail(RMC_INVALID_INPUT, "%s must be a number", path);
    if (!isfinite(v)) return fail(RMC_INVALID_INPUT, "%s must be finite", path);
    *out = v;
    return 1;
}

static int rmc_positive_float(const bnet_json *d, int node, const char *path, double *out)
{
    if (!rmc_finite_float(d, node, path, out)) return 0;
    if (!(*out > 0.0)) return fail(RMC_INVALID_INPUT, "%s must be positive", path);
    return 1;
}

static int rmc_nonnegative_float(const bnet_json *d, int node, const char *path, double *out)
{
    if (!rmc_finite_float(d, node, path, out)) return 0;
    if (*out < 0.0) return fail(RMC_INVALID_INPUT, "%s must be nonnegative", path);
    return 1;
}

/* JSON has one number type, so "must be an integer" is a value test, not a
 * type test: 3.0 is an integer, 3.5 is not. */
static int rmc_integer(const bnet_json *d, int node, const char *path, double *out)
{
    if (!rmc_finite_float(d, node, path, out)) return 0;
    if (*out != floor(*out)) return fail(RMC_INVALID_INPUT, "%s must be an integer", path);
    return 1;
}

static int rmc_positive_int(const bnet_json *d, int node, const char *path, long *out)
{
    double v;
    if (!rmc_integer(d, node, path, &v)) return 0;
    if (v < 1.0) return fail(RMC_INVALID_INPUT, "%s must be a positive integer", path);
    *out = (long)v;
    return 1;
}

static int rmc_nonnegative_int(const bnet_json *d, int node, const char *path, long *out)
{
    double v;
    if (!rmc_integer(d, node, path, &v)) return 0;
    if (v < 0.0) return fail(RMC_INVALID_INPUT, "%s must be a nonnegative integer", path);
    *out = (long)v;
    return 1;
}

static int rmc_copy_id(char *destination, size_t size, const char *source, const char *path)
{
    if (!source || !*source) return fail(RMC_INVALID_INPUT, "%s must be a nonempty string", path);
    if (strlen(source) >= size) return fail(RMC_INVALID_INPUT, "%s is too long", path);
    strcpy(destination, source);
    return 1;
}

static int rmc_node_index(const rmc_model *model, const char *id)
{
    int i;
    for (i = 0; i < model->node_count; i++) if (strcmp(model->nodes[i].id, id) == 0) return i;
    return -1;
}

static int rmc_class_index(const rmc_model *model, const char *id)
{
    int i;
    for (i = 0; i < model->class_count; i++) if (strcmp(model->classes[i].id, id) == 0) return i;
    return -1;
}

static int rmc_parse_nodes(const bnet_json *d, int root, rmc_model *model)
{
    static const char *allowed[] = { "id", "servers", "service_rate", "capacity" };
    int nodes_node = bnet_json_member(d, root, "nodes");
    int count, i, finite_seen = 0, infinite_seen = 0;
    if (bnet_json_type_of(d, nodes_node) != BNET_JSON_ARRAY || bnet_json_count(d, nodes_node) == 0) {
        return fail(RMC_INVALID_INPUT, "nodes must be a nonempty array");
    }
    count = bnet_json_count(d, nodes_node);
    model->nodes = (rmc_node *)calloc((size_t)count, sizeof *model->nodes);
    if (!model->nodes) return fail(RMC_INTERNAL, "out of memory");
    model->node_count = count;
    for (i = 0; i < count; i++) {
        int item = bnet_json_at(d, nodes_node, i);
        char path[64];
        long servers;
        int capacity_node;
        snprintf(path, sizeof path, "nodes[%d]", i);
        if (bnet_json_type_of(d, item) != BNET_JSON_OBJECT) {
            return fail(RMC_INVALID_INPUT, "%s must be a JSON object", path);
        }
        if (!rmc_check_unknown(d, item, allowed, 4, path)) return 0;
        {
            char id_path[80];
            snprintf(id_path, sizeof id_path, "%s.id", path);
            if (!rmc_copy_id(model->nodes[i].id, sizeof model->nodes[i].id,
                             bnet_json_string(d, bnet_json_member(d, item, "id")), id_path)) return 0;
        }
        if (rmc_node_index(model, model->nodes[i].id) != i) {
            /* rmc_node_index scans from 0, so an earlier match means a duplicate. */
            return fail(RMC_INVALID_INPUT, "duplicate node id '%s'", model->nodes[i].id);
        }
        {
            int servers_node = bnet_json_member(d, item, "servers");
            char servers_path[80];
            snprintf(servers_path, sizeof servers_path, "%s.servers", path);
            if (servers_node == BNET_JSON_NONE) servers = 1;
            else if (!rmc_positive_int(d, servers_node, servers_path, &servers)) return 0;
            model->nodes[i].servers = (int)servers;
        }
        {
            char rate_path[80];
            snprintf(rate_path, sizeof rate_path, "%s.service_rate", path);
            if (!rmc_positive_float(d, bnet_json_member(d, item, "service_rate"), rate_path,
                                    &model->nodes[i].service_rate)) return 0;
        }
        capacity_node = bnet_json_member(d, item, "capacity");
        if (capacity_node == BNET_JSON_NONE || bnet_json_is_null(d, capacity_node)) {
            model->nodes[i].capacity = -1;
            infinite_seen = 1;
        } else {
            long capacity;
            char capacity_path[80];
            snprintf(capacity_path, sizeof capacity_path, "%s.capacity", path);
            if (!rmc_positive_int(d, capacity_node, capacity_path, &capacity)) return 0;
            if (capacity < servers) {
                return fail(RMC_INVALID_INPUT, "%s.capacity must be at least servers", path);
            }
            model->nodes[i].capacity = (int)capacity;
            finite_seen = 1;
        }
    }
    if (finite_seen && infinite_seen) {
        return fail(RMC_INVALID_INPUT,
                    "mixed finite- and infinite-buffer nodes are outside the supported class");
    }
    model->finite_buffers = finite_seen;
    return 1;
}

static int rmc_parse_classes(const bnet_json *d, int root, rmc_model *model)
{
    static const char *allowed[] = { "id", "external_arrival_rates", "routing" };
    int classes_node = bnet_json_member(d, root, "classes");
    int count, i, n = model->node_count;
    bnet_fsum total_external;
    if (bnet_json_type_of(d, classes_node) != BNET_JSON_ARRAY || bnet_json_count(d, classes_node) == 0) {
        return fail(RMC_INVALID_INPUT, "classes must be a nonempty array");
    }
    count = bnet_json_count(d, classes_node);
    model->classes = (rmc_class *)calloc((size_t)count, sizeof *model->classes);
    if (!model->classes) return fail(RMC_INTERNAL, "out of memory");
    model->class_count = count;
    bnet_fsum_init(&total_external);
    for (i = 0; i < count; i++) {
        int item = bnet_json_at(d, classes_node, i);
        int external_node, routing_node, member, source;
        char path[64];
        snprintf(path, sizeof path, "classes[%d]", i);
        if (bnet_json_type_of(d, item) != BNET_JSON_OBJECT) {
            return fail(RMC_INVALID_INPUT, "%s must be a JSON object", path);
        }
        if (!rmc_check_unknown(d, item, allowed, 3, path)) return 0;
        {
            char id_path[80];
            snprintf(id_path, sizeof id_path, "%s.id", path);
            if (!rmc_copy_id(model->classes[i].id, sizeof model->classes[i].id,
                             bnet_json_string(d, bnet_json_member(d, item, "id")), id_path)) return 0;
        }
        if (rmc_class_index(model, model->classes[i].id) != i) {
            return fail(RMC_INVALID_INPUT, "duplicate class id '%s'", model->classes[i].id);
        }
        model->classes[i].external_rates = (double *)calloc((size_t)n, sizeof(double));
        model->classes[i].routing = (double *)calloc((size_t)n * (size_t)n, sizeof(double));
        if (!model->classes[i].external_rates || !model->classes[i].routing) {
            return fail(RMC_INTERNAL, "out of memory");
        }

        external_node = bnet_json_member(d, item, "external_arrival_rates");
        {
            char external_path[96];
            snprintf(external_path, sizeof external_path, "%s.external_arrival_rates", path);
            if (!rmc_is_mapping(d, external_node, external_path)) return 0;
        }
        for (member = (external_node == BNET_JSON_NONE ? BNET_JSON_NONE : d->nodes[external_node].first);
             member != BNET_JSON_NONE; member = d->nodes[member].next) {
            const char *key = bnet_json_key_of(d, member);
            int index = rmc_node_index(model, key);
            char rate_path[192];
            if (index < 0) {
                return fail(RMC_INVALID_INPUT,
                            "%s.external_arrival_rates names unknown nodes: %s", path, key);
            }
            snprintf(rate_path, sizeof rate_path, "%s.external_arrival_rates.%s", path, key);
            if (!rmc_nonnegative_float(d, member, rate_path,
                                       &model->classes[i].external_rates[index])) return 0;
        }

        routing_node = bnet_json_member(d, item, "routing");
        {
            char routing_path[96];
            snprintf(routing_path, sizeof routing_path, "%s.routing", path);
            if (!rmc_is_mapping(d, routing_node, routing_path)) return 0;
        }
        for (member = (routing_node == BNET_JSON_NONE ? BNET_JSON_NONE : d->nodes[routing_node].first);
             member != BNET_JSON_NONE; member = d->nodes[member].next) {
            if (rmc_node_index(model, bnet_json_key_of(d, member)) < 0) {
                return fail(RMC_INVALID_INPUT, "%s.routing names unknown source nodes: %s",
                            path, bnet_json_key_of(d, member));
            }
        }
        for (source = 0; source < n; source++) {
            int row_node = bnet_json_member(d, routing_node, model->nodes[source].id);
            int destination_member;
            double row_sum;
            char row_path[192];
            snprintf(row_path, sizeof row_path, "%s.routing.%s", path, model->nodes[source].id);
            if (!rmc_is_mapping(d, row_node, row_path)) return 0;
            for (destination_member = (row_node == BNET_JSON_NONE ? BNET_JSON_NONE : d->nodes[row_node].first);
                 destination_member != BNET_JSON_NONE;
                 destination_member = d->nodes[destination_member].next) {
                const char *key = bnet_json_key_of(d, destination_member);
                int index = rmc_node_index(model, key);
                double probability;
                char probability_path[320];
                if (index < 0) {
                    return fail(RMC_INVALID_INPUT, "%s names unknown destinations: %s", row_path, key);
                }
                snprintf(probability_path, sizeof probability_path, "%s.%s", row_path, key);
                if (!rmc_nonnegative_float(d, destination_member, probability_path, &probability)) return 0;
                if (probability > 1.0) {
                    return fail(RMC_INVALID_INPUT, "routing probabilities cannot exceed one");
                }
                model->classes[i].routing[(size_t)source * n + index] = probability;
            }
            row_sum = bnet_fsum_array(model->classes[i].routing + (size_t)source * n, n);
            if (row_sum > 1.0 + 1.0e-12) {
                char shown[64];
                return fail(RMC_INVALID_INPUT,
                            "routing row for class '%s' at node '%s' sums to %s, greater than one",
                            model->classes[i].id, model->nodes[source].id,
                            rmc_repr(shown, sizeof shown, row_sum));
            }
            if (row_sum > 1.0) {
                int j;
                for (j = 0; j < n; j++) model->classes[i].routing[(size_t)source * n + j] /= row_sum;
            }
        }
        if (!rmc_all_nodes_reach_exit(&model->classes[i], n)) {
            if (g_error_kind != RMC_OK) return 0;
            return fail(RMC_INVALID_INPUT,
                        "every node in class '%s' routing must have a path to exit",
                        model->classes[i].id);
        }
        { int j; for (j = 0; j < n; j++) bnet_fsum_add(&total_external, model->classes[i].external_rates[j]); }
    }
    if (bnet_fsum_value(&total_external) <= 0.0) {
        return fail(RMC_INVALID_INPUT, "at least one positive external arrival rate is required");
    }
    return 1;
}

static int rmc_parse_initial_jobs(const bnet_json *d, int root, rmc_model *model)
{
    int initial_node = bnet_json_member(d, root, "initial_jobs");
    int member, node_index;
    int n = model->node_count, k = model->class_count;
    model->initial_jobs = (int *)calloc((size_t)n * (size_t)k, sizeof(int));
    if (!model->initial_jobs) return fail(RMC_INTERNAL, "out of memory");
    if (!rmc_is_mapping(d, initial_node, "initial_jobs")) return 0;
    for (member = (initial_node == BNET_JSON_NONE ? BNET_JSON_NONE : d->nodes[initial_node].first);
         member != BNET_JSON_NONE; member = d->nodes[member].next) {
        const char *node_id = bnet_json_key_of(d, member);
        int index = rmc_node_index(model, node_id);
        int class_member;
        char path[192];
        if (index < 0) return fail(RMC_INVALID_INPUT, "initial_jobs names unknown nodes: %s", node_id);
        snprintf(path, sizeof path, "initial_jobs.%s", node_id);
        if (!rmc_is_mapping(d, member, path)) return 0;
        for (class_member = d->nodes[member].first; class_member != BNET_JSON_NONE;
             class_member = d->nodes[class_member].next) {
            const char *class_id = bnet_json_key_of(d, class_member);
            int class_position = rmc_class_index(model, class_id);
            long count;
            char count_path[320];
            if (class_position < 0) {
                return fail(RMC_INVALID_INPUT, "initial_jobs.%s names unknown classes: %s",
                            node_id, class_id);
            }
            snprintf(count_path, sizeof count_path, "initial_jobs.%s.%s", node_id, class_id);
            if (!rmc_nonnegative_int(d, class_member, count_path, &count)) return 0;
            model->initial_jobs[(size_t)index * k + class_position] = (int)count;
        }
    }
    for (node_index = 0; node_index < n; node_index++) {
        int total = 0, class_position;
        for (class_position = 0; class_position < k; class_position++) {
            total += model->initial_jobs[(size_t)node_index * k + class_position];
        }
        if (model->nodes[node_index].capacity >= 0 && total > model->nodes[node_index].capacity) {
            return fail(RMC_INVALID_INPUT, "initial_jobs at node '%s' exceed its capacity",
                        model->nodes[node_index].id);
        }
    }
    return 1;
}

static int rmc_parse_stopping(const bnet_json *d, int root, rmc_model *model)
{
    static const char *allowed[] = {
        "confidence", "absolute_half_width", "relative_half_width", "monitored_metrics",
        "minimum_cycles", "minimum_effective_cycles", "minimum_positive_cycles",
        "check_every_cycles", "maximum_cycles", "maximum_events", "maximum_simulated_time",
        "maximum_cycle_time", "maximum_events_per_cycle", "maximum_wall_seconds"
    };
    int stop = bnet_json_member(d, root, "stopping");
    rmc_stopping *s = &model->stopping;
    int member, monitored, i, j;
    long value;
    if (!rmc_is_mapping(d, stop, "stopping")) return 0;
    if (!rmc_check_unknown(d, stop, allowed, 14, "stopping")) return 0;

    member = bnet_json_member(d, stop, "confidence");
    s->confidence = 0.95;
    if (member != BNET_JSON_NONE && !rmc_finite_float(d, member, "stopping.confidence", &s->confidence)) return 0;
    if (!(s->confidence > 0.5 && s->confidence < 1.0)) {
        return fail(RMC_INVALID_INPUT, "stopping.confidence must be between 0.5 and 1");
    }
    member = bnet_json_member(d, stop, "absolute_half_width");
    s->absolute_half_width = 0.02;
    if (member != BNET_JSON_NONE &&
        !rmc_nonnegative_float(d, member, "stopping.absolute_half_width", &s->absolute_half_width)) return 0;
    member = bnet_json_member(d, stop, "relative_half_width");
    s->relative_half_width = 0.05;
    if (member != BNET_JSON_NONE &&
        !rmc_nonnegative_float(d, member, "stopping.relative_half_width", &s->relative_half_width)) return 0;
    if (s->absolute_half_width == 0.0 && s->relative_half_width == 0.0) {
        return fail(RMC_INVALID_INPUT, "at least one stopping half-width target must be positive");
    }

    monitored = bnet_json_member(d, stop, "monitored_metrics");
    if (monitored == BNET_JSON_NONE) {
        s->monitored_count = 1;
        s->monitored_metrics = (char **)calloc(1, sizeof(char *));
        if (!s->monitored_metrics) return fail(RMC_INTERNAL, "out of memory");
        s->monitored_metrics[0] = strdup("mean_number_in_system");
        if (!s->monitored_metrics[0]) return fail(RMC_INTERNAL, "out of memory");
    } else {
        int count = bnet_json_count(d, monitored);
        if (bnet_json_type_of(d, monitored) != BNET_JSON_ARRAY || count == 0) {
            return fail(RMC_INVALID_INPUT,
                        "stopping.monitored_metrics must be a nonempty array of unique strings");
        }
        s->monitored_metrics = (char **)calloc((size_t)count, sizeof(char *));
        if (!s->monitored_metrics) return fail(RMC_INTERNAL, "out of memory");
        s->monitored_count = count;
        for (i = 0; i < count; i++) {
            const char *text = bnet_json_string(d, bnet_json_at(d, monitored, i));
            if (!text || !*text) {
                return fail(RMC_INVALID_INPUT,
                            "stopping.monitored_metrics must be a nonempty array of unique strings");
            }
            for (j = 0; j < i; j++) {
                if (strcmp(s->monitored_metrics[j], text) == 0) {
                    return fail(RMC_INVALID_INPUT,
                                "stopping.monitored_metrics must be a nonempty array of unique strings");
                }
            }
            s->monitored_metrics[i] = strdup(text);
            if (!s->monitored_metrics[i]) return fail(RMC_INTERNAL, "out of memory");
        }
    }

    member = bnet_json_member(d, stop, "minimum_cycles");
    value = 200;
    if (member != BNET_JSON_NONE && !rmc_positive_int(d, member, "stopping.minimum_cycles", &value)) return 0;
    if (value < 30) {
        return fail(RMC_INVALID_INPUT,
                    "stopping.minimum_cycles must be at least 30 for the regenerative t interval");
    }
    s->minimum_cycles = (int)value;

    member = bnet_json_member(d, stop, "minimum_effective_cycles");
    s->minimum_effective_cycles = 30.0;
    if (member != BNET_JSON_NONE &&
        !rmc_positive_float(d, member, "stopping.minimum_effective_cycles", &s->minimum_effective_cycles)) return 0;
    if (s->minimum_effective_cycles > (double)s->minimum_cycles) {
        return fail(RMC_INVALID_INPUT, "minimum_effective_cycles cannot exceed minimum_cycles");
    }

    member = bnet_json_member(d, stop, "minimum_positive_cycles");
    value = 5;
    if (member != BNET_JSON_NONE && !rmc_positive_int(d, member, "stopping.minimum_positive_cycles", &value)) return 0;
    s->minimum_positive_cycles = (int)value;

    member = bnet_json_member(d, stop, "check_every_cycles");
    value = 50;
    if (member != BNET_JSON_NONE && !rmc_positive_int(d, member, "stopping.check_every_cycles", &value)) return 0;
    s->check_every_cycles = (int)value;

    member = bnet_json_member(d, stop, "maximum_cycles");
    value = 100000;
    if (member != BNET_JSON_NONE && !rmc_positive_int(d, member, "stopping.maximum_cycles", &value)) return 0;
    if (value < s->minimum_cycles) {
        return fail(RMC_INVALID_INPUT, "stopping.maximum_cycles cannot be less than minimum_cycles");
    }
    s->maximum_cycles = value;

    member = bnet_json_member(d, stop, "maximum_events");
    value = 10000000;
    if (member != BNET_JSON_NONE && !rmc_positive_int(d, member, "stopping.maximum_events", &value)) return 0;
    s->maximum_events = value;

    member = bnet_json_member(d, stop, "maximum_simulated_time");
    s->maximum_simulated_time = 1.0e9;
    if (member != BNET_JSON_NONE &&
        !rmc_positive_float(d, member, "stopping.maximum_simulated_time", &s->maximum_simulated_time)) return 0;

    member = bnet_json_member(d, stop, "maximum_cycle_time");
    s->maximum_cycle_time = 1.0e7;
    if (member != BNET_JSON_NONE &&
        !rmc_positive_float(d, member, "stopping.maximum_cycle_time", &s->maximum_cycle_time)) return 0;

    member = bnet_json_member(d, stop, "maximum_events_per_cycle");
    value = 2000000;
    if (member != BNET_JSON_NONE &&
        !rmc_positive_int(d, member, "stopping.maximum_events_per_cycle", &value)) return 0;
    s->maximum_events_per_cycle = value;

    member = bnet_json_member(d, stop, "maximum_wall_seconds");
    s->maximum_wall_seconds = 120.0;
    if (member != BNET_JSON_NONE &&
        !rmc_positive_float(d, member, "stopping.maximum_wall_seconds", &s->maximum_wall_seconds)) return 0;
    return 1;
}

static int rmc_parse_rare_event(const bnet_json *d, int root, rmc_model *model)
{
    static const char *allowed[] = { "method", "arrival_rate_multiplier", "service_rate_multiplier" };
    int rare = bnet_json_member(d, root, "rare_event");
    const char *method;
    if (!rmc_is_mapping(d, rare, "rare_event")) return 0;
    if (!rmc_check_unknown(d, rare, allowed, 3, "rare_event")) return 0;
    method = bnet_json_string_or(d, bnet_json_member(d, rare, "method"), "none");
    if (strcmp(method, "none") != 0 && strcmp(method, "importance_sampling_mm1k") != 0) {
        return fail(RMC_INVALID_INPUT, "rare_event.method must be 'none' or 'importance_sampling_mm1k'");
    }
    model->rare_event.enabled = (strcmp(method, "none") != 0);
    model->rare_event.arrival_rate_multiplier = 1.0;
    model->rare_event.service_rate_multiplier = 1.0;
    if (!model->rare_event.enabled) {
        if (bnet_json_member(d, rare, "arrival_rate_multiplier") != BNET_JSON_NONE ||
            bnet_json_member(d, rare, "service_rate_multiplier") != BNET_JSON_NONE) {
            return fail(RMC_INVALID_INPUT,
                        "rare-event rate multipliers are valid only with importance_sampling_mm1k");
        }
        return 1;
    }
    if (!rmc_positive_float(d, bnet_json_member(d, rare, "arrival_rate_multiplier"),
                            "rare_event.arrival_rate_multiplier",
                            &model->rare_event.arrival_rate_multiplier)) return 0;
    if (!rmc_positive_float(d, bnet_json_member(d, rare, "service_rate_multiplier"),
                            "rare_event.service_rate_multiplier",
                            &model->rare_event.service_rate_multiplier)) return 0;
    if (model->node_count != 1 || model->class_count != 1) {
        return fail(RMC_INVALID_INPUT, "importance_sampling_mm1k requires exactly one node and one class");
    }
    if (model->nodes[0].servers != 1 || model->nodes[0].capacity < 0) {
        return fail(RMC_INVALID_INPUT, "importance_sampling_mm1k requires a finite-buffer M/M/1/K node");
    }
    if (model->classes[0].routing[0] != 0.0) {
        return fail(RMC_INVALID_INPUT, "importance_sampling_mm1k does not permit feedback routing");
    }
    if (model->classes[0].external_rates[0] <= 0.0) {
        return fail(RMC_INVALID_INPUT, "importance_sampling_mm1k requires a positive arrival rate");
    }
    return 1;
}

static int rmc_parse_model(const bnet_json *d, rmc_model *model)
{
    static const char *allowed[] = {
        "schema_version", "process", "name", "nodes", "classes",
        "initial_jobs", "random", "stopping", "rare_event"
    };
    static const char *random_allowed[] = { "base_seed", "stream" };
    int root = d->root, random_node, member;
    const char *process, *name;
    double schema;
    int c, n;

    memset(model, 0, sizeof *model);
    if (bnet_json_type_of(d, root) != BNET_JSON_OBJECT) {
        return fail(RMC_INVALID_INPUT, "the JSON root must be an object");
    }
    if (!rmc_check_unknown(d, root, allowed, 9, "root")) return 0;
    schema = bnet_json_number_or(d, bnet_json_member(d, root, "schema_version"), 1.0);
    if (schema != 1.0) return fail(RMC_INVALID_INPUT, "only schema_version 1 is supported");
    process = bnet_json_string_or(d, bnet_json_member(d, root, "process"),
                                  "open_markovian_queueing_network");
    if (strcmp(process, "open_markovian_queueing_network") != 0) {
        return fail(RMC_INVALID_INPUT, "process must be 'open_markovian_queueing_network'");
    }
    name = bnet_json_string_or(d, bnet_json_member(d, root, "name"), "open Markovian queueing network");
    {
        const char *scan = name;
        while (*scan == ' ' || *scan == '\t' || *scan == '\n' || *scan == '\r') scan++;
        if (!*scan) return fail(RMC_INVALID_INPUT, "name must be a nonempty string");
    }
    if (strlen(name) >= sizeof model->name) return fail(RMC_INVALID_INPUT, "name is too long");
    strcpy(model->name, name);

    if (!rmc_parse_nodes(d, root, model)) return 0;
    if (!rmc_parse_classes(d, root, model)) return 0;
    if (!rmc_parse_initial_jobs(d, root, model)) return 0;

    random_node = bnet_json_member(d, root, "random");
    if (!rmc_is_mapping(d, random_node, "random")) return 0;
    if (!rmc_check_unknown(d, random_node, random_allowed, 2, "random")) return 0;
    model->base_seed = 20260904ULL;
    model->stream = 0ULL;
    member = bnet_json_member(d, random_node, "base_seed");
    if (member != BNET_JSON_NONE) {
        long v;
        if (!rmc_nonnegative_int(d, member, "random.base_seed", &v)) return 0;
        model->base_seed = (unsigned long long)v;
    }
    member = bnet_json_member(d, random_node, "stream");
    if (member != BNET_JSON_NONE) {
        long v;
        if (!rmc_nonnegative_int(d, member, "random.stream", &v)) return 0;
        model->stream = (unsigned long long)v;
    }

    if (!rmc_parse_stopping(d, root, model)) return 0;
    if (!rmc_parse_rare_event(d, root, model)) return 0;

    n = model->node_count;
    model->traffic_rates = (double *)calloc((size_t)model->class_count * (size_t)n, sizeof(double));
    model->offered_loads = (double *)calloc((size_t)n, sizeof(double));
    if (!model->traffic_rates || !model->offered_loads) return fail(RMC_INTERNAL, "out of memory");
    for (c = 0; c < model->class_count; c++) {
        if (!rmc_traffic_rates(&model->classes[c], n, model->traffic_rates + (size_t)c * n)) return 0;
    }
    {
        int node_index;
        for (node_index = 0; node_index < n; node_index++) {
            bnet_fsum total;
            bnet_fsum_init(&total);
            for (c = 0; c < model->class_count; c++) {
                bnet_fsum_add(&total, model->traffic_rates[(size_t)c * n + node_index]);
            }
            model->offered_loads[node_index] = bnet_fsum_value(&total)
                / (model->nodes[node_index].servers * model->nodes[node_index].service_rate);
        }
    }
    if (!model->finite_buffers) {
        int node_index;
        for (node_index = 0; node_index < n; node_index++) {
            if (model->offered_loads[node_index] >= 1.0 - 1.0e-12) {
                return fail(RMC_STABILITY, "infinite-buffer network fails the Jackson load condition");
            }
        }
    }
    return 1;
}

/* -------------------------------------------------------- metric catalogue */

typedef struct {
    rmc_metric *items;
    int         count;
    int         capacity;
} rmc_metric_list;

static rmc_metric *rmc_metric_push(rmc_metric_list *list)
{
    if (list->count == list->capacity) {
        int cap = list->capacity ? list->capacity * 2 : 32;
        rmc_metric *grown = (rmc_metric *)realloc(list->items, (size_t)cap * sizeof *grown);
        if (!grown) { fail(RMC_INTERNAL, "out of memory"); return NULL; }
        list->items = grown;
        list->capacity = cap;
    }
    memset(&list->items[list->count], 0, sizeof list->items[list->count]);
    return &list->items[list->count++];
}

/* One metric, with its reward slots interned as a side effect. Bounds follow
 * the Python's defaults: lower 0.0 always, upper only where named. */
static int rmc_add_metric(rmc_metric_list *list, rmc_slots *slots,
                          const char *key, const char *description,
                          const char *numerator, const char *denominator,
                          double denominator_multiplier,
                          int has_upper, double upper, int event_probability)
{
    rmc_metric *m = rmc_metric_push(list);
    if (!m) return 0;
    if (strlen(key) >= sizeof m->key || strlen(description) >= sizeof m->description) {
        return fail(RMC_INVALID_INPUT, "a node or class identifier is too long for the metric catalogue");
    }
    strcpy(m->key, key);
    strcpy(m->description, description);
    m->numerator_slot = rmc_slot_intern(slots, numerator);
    m->denominator_slot = rmc_slot_intern(slots, denominator);
    if (m->numerator_slot < 0 || m->denominator_slot < 0) return 0;
    m->denominator_multiplier = denominator_multiplier;
    m->has_lower_bound = 1;
    m->lower_bound = 0.0;
    m->has_upper_bound = has_upper;
    m->upper_bound = upper;
    m->event_probability = event_probability;
    return 1;
}

/* The catalogue, in the SAME ORDER as metric_definitions() in the Python. The
 * order is observable: the human report walks it, and the machine records are
 * written in it. */
static int rmc_build_metrics(const rmc_model *model, rmc_metric_list *list, rmc_slots *slots)
{
    char key[320], description[320], numerator[320], denominator[320];
    int node_index, class_index;

    if (rmc_slot_intern(slots, "time") != 0) {
        return fail(RMC_INTERNAL, "the time reward must be slot zero");
    }

#define ADD(k, desc, num, den, mult, hi_flag, hi, prob) \
    do { if (!rmc_add_metric(list, slots, (k), (desc), (num), (den), (mult), (hi_flag), (hi), (prob))) return 0; } while (0)

    ADD("mean_number_in_system", "time-average jobs in the complete network",
        "area.system", "time", 1.0, 0, 0.0, 0);
    ADD("external_offered_rate", "external arrival attempts per unit time",
        "count.external.offered", "time", 1.0, 0, 0.0, 0);
    ADD("external_accepted_rate", "accepted external arrivals per unit time",
        "count.external.accepted", "time", 1.0, 0, 0.0, 0);
    ADD("external_blocking_rate", "blocked external arrivals per unit time",
        "count.external.blocked", "time", 1.0, 0, 0.0, 0);
    ADD("external_blocking_probability", "blocked fraction of external arrival attempts",
        "count.external.blocked", "count.external.offered", 1.0, 1, 1.0, 1);
    ADD("routed_blocking_probability", "blocked fraction of internal routing attempts",
        "count.routed.blocked", "count.routed.offered", 1.0, 1, 1.0, 1);
    ADD("departure_rate",
        "accepted jobs leaving by normal exit or routed-arrival loss per unit time",
        "count.departure", "time", 1.0, 0, 0.0, 0);
    ADD("normal_exit_rate", "jobs taking a normal post-service network exit per unit time",
        "count.exit", "time", 1.0, 0, 0.0, 0);
    ADD("routed_loss_rate", "jobs lost on arrival to a full routed destination per unit time",
        "count.routed.blocked", "time", 1.0, 0, 0.0, 0);

    for (node_index = 0; node_index < model->node_count; node_index++) {
        const char *id = model->nodes[node_index].id;
        snprintf(key, sizeof key, "mean_number_at_node:%s", id);
        snprintf(description, sizeof description, "time-average jobs at node %s", id);
        snprintf(numerator, sizeof numerator, "area.node.%s", id);
        ADD(key, description, numerator, "time", 1.0, 0, 0.0, 0);

        snprintf(key, sizeof key, "mean_queue_at_node:%s", id);
        snprintf(description, sizeof description, "time-average waiting jobs at node %s", id);
        snprintf(numerator, sizeof numerator, "area.queue.%s", id);
        ADD(key, description, numerator, "time", 1.0, 0, 0.0, 0);

        snprintf(key, sizeof key, "utilization:%s", id);
        snprintf(description, sizeof description, "mean busy fraction of the %d server(s) at node %s",
                 model->nodes[node_index].servers, id);
        snprintf(numerator, sizeof numerator, "area.busy.%s", id);
        ADD(key, description, numerator, "time", (double)model->nodes[node_index].servers, 1, 1.0, 0);

        snprintf(key, sizeof key, "service_completion_rate:%s", id);
        snprintf(description, sizeof description, "service completions at node %s per unit time", id);
        snprintf(numerator, sizeof numerator, "count.service.%s", id);
        ADD(key, description, numerator, "time", 1.0, 0, 0.0, 0);
    }

    for (class_index = 0; class_index < model->class_count; class_index++) {
        const char *class_id = model->classes[class_index].id;

        snprintf(key, sizeof key, "mean_number_class:%s", class_id);
        snprintf(description, sizeof description, "time-average class %s jobs in the network", class_id);
        snprintf(numerator, sizeof numerator, "area.class.%s", class_id);
        ADD(key, description, numerator, "time", 1.0, 0, 0.0, 0);

        snprintf(key, sizeof key, "external_offered_rate_class:%s", class_id);
        snprintf(description, sizeof description, "class %s external arrival attempts per unit time", class_id);
        snprintf(numerator, sizeof numerator, "count.external.offered.class.%s", class_id);
        ADD(key, description, numerator, "time", 1.0, 0, 0.0, 0);

        snprintf(key, sizeof key, "external_accepted_rate_class:%s", class_id);
        snprintf(description, sizeof description, "accepted class %s external arrivals per unit time", class_id);
        snprintf(numerator, sizeof numerator, "count.external.accepted.class.%s", class_id);
        ADD(key, description, numerator, "time", 1.0, 0, 0.0, 0);

        snprintf(key, sizeof key, "external_blocking_rate_class:%s", class_id);
        snprintf(description, sizeof description, "blocked class %s external arrivals per unit time", class_id);
        snprintf(numerator, sizeof numerator, "count.external.blocked.class.%s", class_id);
        ADD(key, description, numerator, "time", 1.0, 0, 0.0, 0);

        snprintf(key, sizeof key, "external_blocking_probability_class:%s", class_id);
        snprintf(description, sizeof description, "blocked fraction of class %s external arrivals", class_id);
        snprintf(numerator, sizeof numerator, "count.external.blocked.class.%s", class_id);
        snprintf(denominator, sizeof denominator, "count.external.offered.class.%s", class_id);
        ADD(key, description, numerator, denominator, 1.0, 1, 1.0, 1);

        snprintf(key, sizeof key, "departure_rate_class:%s", class_id);
        snprintf(description, sizeof description,
                 "accepted class %s jobs leaving by exit or routed loss per unit time", class_id);
        snprintf(numerator, sizeof numerator, "count.departure.class.%s", class_id);
        ADD(key, description, numerator, "time", 1.0, 0, 0.0, 0);

        snprintf(key, sizeof key, "normal_exit_rate_class:%s", class_id);
        snprintf(description, sizeof description, "class %s normal post-service exits per unit time", class_id);
        snprintf(numerator, sizeof numerator, "count.exit.class.%s", class_id);
        ADD(key, description, numerator, "time", 1.0, 0, 0.0, 0);

        for (node_index = 0; node_index < model->node_count; node_index++) {
            const char *node_id = model->nodes[node_index].id;
            snprintf(key, sizeof key, "mean_number:%s:%s", node_id, class_id);
            snprintf(description, sizeof description, "time-average class %s jobs at node %s",
                     class_id, node_id);
            snprintf(numerator, sizeof numerator, "area.node_class.%s.%s", node_id, class_id);
            ADD(key, description, numerator, "time", 1.0, 0, 0.0, 0);
        }
    }
#undef ADD
    return 1;
}

static int rmc_metric_position(const rmc_metric_list *list, const char *key)
{
    int i;
    for (i = 0; i < list->count; i++) if (strcmp(list->items[i].key, key) == 0) return i;
    return -1;
}

/* ---------------------------------------------------------------- simulator */

typedef struct {
    int    kind;                /* 0 external, 1 service */
    int    node;
    int    class_index;         /* external only */
    double original_rate;
    double proposal_rate;
} rmc_event;

typedef struct {
    const rmc_model *model;
    const rmc_metric_list *metrics;
    const rmc_slots *slots;

    unsigned long long time_seed, choice_seed;
    bnet_pyrandom time_rng, choice_rng;

    int   **queues;             /* [node][position] = class index, FCFS order */
    int    *queue_length;
    int    *queue_capacity;
    int    *counts;             /* [node * class_count + class] */
    long    total_jobs;

    int     initial_state_was_regeneration;
    int     collecting;
    double  segment_start;
    double *cycle_values;       /* [slot_count] */
    double  cycle_log_weight;
    long    cycle_events;
    long    events;
    double  time;
    double  delayed_time;
    int     discarded_incomplete_cycle;

    rmc_accumulator *accumulators;      /* [metric count] */
    long    estimator_cycles;
    int     have_log_weight_scale;
    double  log_weight_scale;
    double  sum_weight, sum_weight2, max_weight;
    double  minimum_log_weight, maximum_log_weight;

    /* cycle duration running moments */
    long    duration_count;
    double  duration_mean, duration_m2, duration_min, duration_max;

    double  collected_time;
    long    looks;
    int     have_precision;
    long    precision_look;
    double  precision_look_alpha;
    int     precision_target_met;

    time_t  start_wall;

    /* precomputed slots */
    int  slot_area_system;
    int *slot_area_node, *slot_area_queue, *slot_area_busy, *slot_count_service;
    int *slot_area_node_class;          /* [node * class_count + class] */
    int *slot_area_class;
    int  slot_ext_offered, slot_ext_accepted, slot_ext_blocked;
    int *slot_ext_offered_class, *slot_ext_accepted_class, *slot_ext_blocked_class;
    int  slot_routed_offered, slot_routed_accepted, slot_routed_blocked;
    int  slot_departure, slot_exit;
    int *slot_departure_class, *slot_exit_class;

    rmc_event *events_buffer;
    int        events_capacity;
} rmc_simulator;

/* WALL time, not CPU time: `maximum_wall_seconds` is a promise to the person
 * waiting, and clock() would let a run that spent its budget blocked on I/O
 * continue. time()/difftime() is the ANSI C way to get it; one-second
 * resolution is ample for a safeguard whose smallest sane setting is seconds. */
static double rmc_wall_seconds(time_t start)
{
    return difftime(time(NULL), start);
}

static int rmc_lookup(const rmc_slots *slots, const char *name)
{
    int index = rmc_slot_find(slots, name);
    if (index < 0) fail(RMC_INTERNAL, "reward slot '%s' was never interned", name);
    return index;
}

static int rmc_simulator_init(rmc_simulator *sim, const rmc_model *model,
                              const rmc_metric_list *metrics, const rmc_slots *slots)
{
    int n = model->node_count, k = model->class_count, i, c;
    char name[320];
    memset(sim, 0, sizeof *sim);
    sim->model = model;
    sim->metrics = metrics;
    sim->slots = slots;
    sim->time_seed   = bnet_derive_seed(model->base_seed, model->stream, 0x54494D45ULL);
    sim->choice_seed = bnet_derive_seed(model->base_seed, model->stream, 0x43484F49ULL);
    bnet_pyrandom_seed_u64(&sim->time_rng, sim->time_seed);
    bnet_pyrandom_seed_u64(&sim->choice_rng, sim->choice_seed);

    sim->queues = (int **)calloc((size_t)n, sizeof(int *));
    sim->queue_length = (int *)calloc((size_t)n, sizeof(int));
    sim->queue_capacity = (int *)calloc((size_t)n, sizeof(int));
    sim->counts = (int *)calloc((size_t)n * (size_t)k, sizeof(int));
    sim->cycle_values = (double *)calloc((size_t)slots->count, sizeof(double));
    sim->accumulators = (rmc_accumulator *)calloc((size_t)metrics->count, sizeof(rmc_accumulator));
    if (!sim->queues || !sim->queue_length || !sim->queue_capacity || !sim->counts ||
        !sim->cycle_values || !sim->accumulators) return fail(RMC_INTERNAL, "out of memory");

    for (i = 0; i < n; i++) {
        int initial_total = 0;
        for (c = 0; c < k; c++) initial_total += model->initial_jobs[(size_t)i * k + c];
        sim->queue_capacity[i] = initial_total > 16 ? initial_total : 16;
        sim->queues[i] = (int *)malloc((size_t)sim->queue_capacity[i] * sizeof(int));
        if (!sim->queues[i]) return fail(RMC_INTERNAL, "out of memory");
        for (c = 0; c < k; c++) {
            int count = model->initial_jobs[(size_t)i * k + c], j;
            for (j = 0; j < count; j++) sim->queues[i][sim->queue_length[i]++] = c;
            sim->counts[(size_t)i * k + c] = count;
        }
        sim->total_jobs += sim->queue_length[i];
    }
    sim->initial_state_was_regeneration = (sim->total_jobs == 0);
    sim->collecting = sim->initial_state_was_regeneration;
    sim->minimum_log_weight = HUGE_VAL;
    sim->maximum_log_weight = -HUGE_VAL;
    sim->duration_min = HUGE_VAL;
    sim->duration_max = 0.0;
    sim->start_wall = time(NULL);

    sim->slot_area_node = (int *)calloc((size_t)n, sizeof(int));
    sim->slot_area_queue = (int *)calloc((size_t)n, sizeof(int));
    sim->slot_area_busy = (int *)calloc((size_t)n, sizeof(int));
    sim->slot_count_service = (int *)calloc((size_t)n, sizeof(int));
    sim->slot_area_node_class = (int *)calloc((size_t)n * (size_t)k, sizeof(int));
    sim->slot_area_class = (int *)calloc((size_t)k, sizeof(int));
    sim->slot_ext_offered_class = (int *)calloc((size_t)k, sizeof(int));
    sim->slot_ext_accepted_class = (int *)calloc((size_t)k, sizeof(int));
    sim->slot_ext_blocked_class = (int *)calloc((size_t)k, sizeof(int));
    sim->slot_departure_class = (int *)calloc((size_t)k, sizeof(int));
    sim->slot_exit_class = (int *)calloc((size_t)k, sizeof(int));
    if (!sim->slot_area_node || !sim->slot_area_queue || !sim->slot_area_busy ||
        !sim->slot_count_service || !sim->slot_area_node_class || !sim->slot_area_class ||
        !sim->slot_ext_offered_class || !sim->slot_ext_accepted_class ||
        !sim->slot_ext_blocked_class || !sim->slot_departure_class || !sim->slot_exit_class) {
        return fail(RMC_INTERNAL, "out of memory");
    }

    /* Every reward the simulator writes must already exist as a slot, because
     * the metric catalogue interned it. A miss is a catalogue/simulator
     * disagreement and is reported rather than silently dropped — that is the
     * failure mode a dict-of-strings hides. */
    sim->slot_area_system     = rmc_lookup(slots, "area.system");
    sim->slot_ext_offered     = rmc_lookup(slots, "count.external.offered");
    sim->slot_ext_accepted    = rmc_lookup(slots, "count.external.accepted");
    sim->slot_ext_blocked     = rmc_lookup(slots, "count.external.blocked");
    sim->slot_routed_offered  = rmc_lookup(slots, "count.routed.offered");
    sim->slot_routed_accepted = rmc_slot_find(slots, "count.routed.accepted");
    sim->slot_routed_blocked  = rmc_lookup(slots, "count.routed.blocked");
    sim->slot_departure       = rmc_lookup(slots, "count.departure");
    sim->slot_exit            = rmc_lookup(slots, "count.exit");
    for (i = 0; i < n; i++) {
        snprintf(name, sizeof name, "area.node.%s", model->nodes[i].id);
        sim->slot_area_node[i] = rmc_lookup(slots, name);
        snprintf(name, sizeof name, "area.queue.%s", model->nodes[i].id);
        sim->slot_area_queue[i] = rmc_lookup(slots, name);
        snprintf(name, sizeof name, "area.busy.%s", model->nodes[i].id);
        sim->slot_area_busy[i] = rmc_lookup(slots, name);
        snprintf(name, sizeof name, "count.service.%s", model->nodes[i].id);
        sim->slot_count_service[i] = rmc_lookup(slots, name);
        for (c = 0; c < k; c++) {
            snprintf(name, sizeof name, "area.node_class.%s.%s",
                     model->nodes[i].id, model->classes[c].id);
            sim->slot_area_node_class[(size_t)i * k + c] = rmc_lookup(slots, name);
        }
    }
    for (c = 0; c < k; c++) {
        snprintf(name, sizeof name, "area.class.%s", model->classes[c].id);
        sim->slot_area_class[c] = rmc_lookup(slots, name);
        snprintf(name, sizeof name, "count.external.offered.class.%s", model->classes[c].id);
        sim->slot_ext_offered_class[c] = rmc_lookup(slots, name);
        snprintf(name, sizeof name, "count.external.accepted.class.%s", model->classes[c].id);
        sim->slot_ext_accepted_class[c] = rmc_lookup(slots, name);
        snprintf(name, sizeof name, "count.external.blocked.class.%s", model->classes[c].id);
        sim->slot_ext_blocked_class[c] = rmc_lookup(slots, name);
        snprintf(name, sizeof name, "count.departure.class.%s", model->classes[c].id);
        sim->slot_departure_class[c] = rmc_lookup(slots, name);
        snprintf(name, sizeof name, "count.exit.class.%s", model->classes[c].id);
        sim->slot_exit_class[c] = rmc_lookup(slots, name);
    }
    if (g_error_kind != RMC_OK) return 0;

    sim->events_capacity = n * k + n + 8;
    sim->events_buffer = (rmc_event *)calloc((size_t)sim->events_capacity, sizeof(rmc_event));
    if (!sim->events_buffer) return fail(RMC_INTERNAL, "out of memory");
    return 1;
}

/* `count.routed.accepted` is written by the simulator but no metric names it,
 * so it is the one reward that may be absent from the catalogue. Writing to
 * slot -1 must be a no-op rather than a stray store. */
static void rmc_increment(rmc_simulator *sim, int slot, double amount)
{
    if (sim->collecting && slot >= 0) sim->cycle_values[slot] += amount;
}

static void rmc_accrue(rmc_simulator *sim, double duration)
{
    const rmc_model *model = sim->model;
    int n = model->node_count, k = model->class_count, node_index, class_index;
    if (!sim->collecting) return;
    sim->cycle_values[0] += duration;                       /* slot 0 is "time" */
    sim->cycle_values[sim->slot_area_system] += (double)sim->total_jobs * duration;
    for (node_index = 0; node_index < n; node_index++) {
        int queue_length = sim->queue_length[node_index];
        int servers = model->nodes[node_index].servers;
        int busy = queue_length < servers ? queue_length : servers;
        int waiting = queue_length - servers;
        if (waiting < 0) waiting = 0;
        sim->cycle_values[sim->slot_area_node[node_index]]  += queue_length * duration;
        sim->cycle_values[sim->slot_area_queue[node_index]] += waiting * duration;
        sim->cycle_values[sim->slot_area_busy[node_index]]  += busy * duration;
        for (class_index = 0; class_index < k; class_index++) {
            sim->cycle_values[sim->slot_area_node_class[(size_t)node_index * k + class_index]]
                += sim->counts[(size_t)node_index * k + class_index] * duration;
        }
    }
    for (class_index = 0; class_index < k; class_index++) {
        long class_count = 0;
        for (node_index = 0; node_index < n; node_index++) {
            class_count += sim->counts[(size_t)node_index * k + class_index];
        }
        sim->cycle_values[sim->slot_area_class[class_index]] += (double)class_count * duration;
    }
}

static int rmc_accept(rmc_simulator *sim, int node_index, int class_index)
{
    const rmc_node *node = &sim->model->nodes[node_index];
    int k = sim->model->class_count;
    if (node->capacity >= 0 && sim->queue_length[node_index] >= node->capacity) return 0;
    if (sim->queue_length[node_index] == sim->queue_capacity[node_index]) {
        int cap = sim->queue_capacity[node_index] * 2;
        int *grown = (int *)realloc(sim->queues[node_index], (size_t)cap * sizeof(int));
        if (!grown) { fail(RMC_INTERNAL, "out of memory growing a queue"); return 0; }
        sim->queues[node_index] = grown;
        sim->queue_capacity[node_index] = cap;
    }
    sim->queues[node_index][sim->queue_length[node_index]++] = class_index;
    sim->counts[(size_t)node_index * k + class_index] += 1;
    sim->total_jobs += 1;
    return 1;
}

static void rmc_route(rmc_simulator *sim, int source, int class_index)
{
    const rmc_class *customer = &sim->model->classes[class_index];
    int n = sim->model->node_count, destination;
    double draw = bnet_pyrandom_double(&sim->choice_rng);
    double cumulative = 0.0;
    for (destination = 0; destination < n; destination++) {
        cumulative += customer->routing[(size_t)source * n + destination];
        if (draw < cumulative) {
            rmc_increment(sim, sim->slot_routed_offered, 1.0);
            if (rmc_accept(sim, destination, class_index)) {
                rmc_increment(sim, sim->slot_routed_accepted, 1.0);
            } else {
                rmc_increment(sim, sim->slot_routed_blocked, 1.0);
                rmc_increment(sim, sim->slot_departure, 1.0);
                rmc_increment(sim, sim->slot_departure_class[class_index], 1.0);
            }
            return;
        }
    }
    rmc_increment(sim, sim->slot_departure, 1.0);
    rmc_increment(sim, sim->slot_departure_class[class_index], 1.0);
    rmc_increment(sim, sim->slot_exit, 1.0);
    rmc_increment(sim, sim->slot_exit_class[class_index], 1.0);
}

static void rmc_execute_event(rmc_simulator *sim, const rmc_event *event)
{
    const rmc_model *model = sim->model;
    int k = model->class_count;
    if (sim->collecting && model->rare_event.enabled) {
        sim->cycle_log_weight += log(event->original_rate / event->proposal_rate);
    }
    if (event->kind == 0) {
        int class_index = event->class_index;
        rmc_increment(sim, sim->slot_ext_offered, 1.0);
        rmc_increment(sim, sim->slot_ext_offered_class[class_index], 1.0);
        if (rmc_accept(sim, event->node, class_index)) {
            rmc_increment(sim, sim->slot_ext_accepted, 1.0);
            rmc_increment(sim, sim->slot_ext_accepted_class[class_index], 1.0);
        } else {
            rmc_increment(sim, sim->slot_ext_blocked, 1.0);
            rmc_increment(sim, sim->slot_ext_blocked_class[class_index], 1.0);
        }
        return;
    }
    {
        int node_index = event->node;
        int servers = model->nodes[node_index].servers;
        int length = sim->queue_length[node_index];
        int busy = length < servers ? length : servers;
        int completion_index = (int)(bnet_pyrandom_double(&sim->choice_rng) * busy);
        int class_index;
        if (completion_index > busy - 1) completion_index = busy - 1;
        class_index = sim->queues[node_index][completion_index];
        memmove(sim->queues[node_index] + completion_index,
                sim->queues[node_index] + completion_index + 1,
                (size_t)(length - completion_index - 1) * sizeof(int));
        sim->queue_length[node_index] -= 1;
        sim->counts[(size_t)node_index * k + class_index] -= 1;
        sim->total_jobs -= 1;
        rmc_increment(sim, sim->slot_count_service[node_index], 1.0);
        rmc_route(sim, node_index, class_index);
    }
}

/* The importance-sampling weights are held relative to the largest log weight
 * seen so far; a new maximum rescales every accumulated statistic. Without it
 * a long run under a shifted measure overflows exp(). */
static int rmc_add_cycle(rmc_simulator *sim)
{
    double log_weight = sim->cycle_log_weight, weight;
    int i;
    if (!isfinite(log_weight)) return fail(RMC_INTERNAL, "a cycle likelihood ratio is non-finite");
    if (!sim->have_log_weight_scale) {
        sim->have_log_weight_scale = 1;
        sim->log_weight_scale = log_weight;
    } else if (log_weight > sim->log_weight_scale) {
        double factor = exp(sim->log_weight_scale - log_weight);
        double factor2 = factor * factor;
        for (i = 0; i < sim->metrics->count; i++) rmc_accumulator_rescale(&sim->accumulators[i], factor);
        sim->sum_weight  *= factor;
        sim->sum_weight2 *= factor2;
        sim->max_weight  *= factor;
        sim->log_weight_scale = log_weight;
    }
    weight = exp(log_weight - sim->log_weight_scale);
    sim->estimator_cycles += 1;
    sim->sum_weight  += weight;
    sim->sum_weight2 += weight * weight;
    if (weight > sim->max_weight) sim->max_weight = weight;
    if (log_weight < sim->minimum_log_weight) sim->minimum_log_weight = log_weight;
    if (log_weight > sim->maximum_log_weight) sim->maximum_log_weight = log_weight;
    for (i = 0; i < sim->metrics->count; i++) {
        const rmc_metric *m = &sim->metrics->items[i];
        double numerator = sim->cycle_values[m->numerator_slot];
        double denominator = sim->cycle_values[m->denominator_slot] * m->denominator_multiplier;
        rmc_accumulator_add(&sim->accumulators[i], weight, numerator, denominator);
    }
    return 1;
}

/* Alpha is spent over metrics and over looks as alpha / (m * L * (L + 1)),
 * which is summable, so the sequential procedure keeps its nominal coverage
 * however many times it peeks. */
static int rmc_precision_check(rmc_simulator *sim, int *all_met_out)
{
    const rmc_stopping *options = &sim->model->stopping;
    double overall_alpha, look_alpha;
    int index, all_met = 1;
    *all_met_out = 0;
    if (sim->estimator_cycles < options->minimum_cycles) return 1;
    sim->looks += 1;
    overall_alpha = 1.0 - options->confidence;
    look_alpha = overall_alpha / ((double)options->monitored_count * (double)sim->looks
                                  * (double)(sim->looks + 1));
    for (index = 0; index < options->monitored_count; index++) {
        int position = rmc_metric_position(sim->metrics, options->monitored_metrics[index]);
        const rmc_metric *m;
        rmc_accumulator *a;
        rmc_core core;
        int met = 0;
        if (position < 0) return fail(RMC_INTERNAL, "monitored metric vanished from the catalogue");
        m = &sim->metrics->items[position];
        a = &sim->accumulators[position];
        if (!rmc_accumulator_core(a, m, &core)) return 0;
        if (core.available && core.has_standard_error) {
            double probability = 1.0 - look_alpha / 2.0;
            double critical = 0.0, half_width = HUGE_VAL, target;
            int have_half_width = 0;
            if (probability < 1.0) {
                if (!rmc_student_t_quantile(probability, a->cycles - 1, &critical)) return 0;
                half_width = critical * core.standard_error;
                have_half_width = 1;
            }
            target = options->absolute_half_width;
            if (options->relative_half_width * fabs(core.estimate) > target) {
                target = options->relative_half_width * fabs(core.estimate);
            }
            met = have_half_width && isfinite(half_width) && half_width <= target
                  && core.effective_cycles >= options->minimum_effective_cycles
                  && (!m->event_probability
                      || core.numerator_positive_cycles >= options->minimum_positive_cycles)
                  && core.centered_cycle_variance_scaled > 0.0;
        }
        if (!met) all_met = 0;
    }
    sim->have_precision = 1;
    sim->precision_look = sim->looks;
    sim->precision_look_alpha = look_alpha;
    sim->precision_target_met = all_met;
    *all_met_out = all_met;
    return 1;
}

static void rmc_duration_add(rmc_simulator *sim, double value)
{
    double delta;
    sim->duration_count += 1;
    delta = value - sim->duration_mean;
    sim->duration_mean += delta / (double)sim->duration_count;
    sim->duration_m2 += delta * (value - sim->duration_mean);
    if (value < sim->duration_min) sim->duration_min = value;
    if (value > sim->duration_max) sim->duration_max = value;
}

static int rmc_finalize_cycle(rmc_simulator *sim, int *precision_met)
{
    const rmc_stopping *options = &sim->model->stopping;
    double duration = sim->time - sim->segment_start;
    int check_due;
    *precision_met = 0;
    if (duration <= 0.0) return fail(RMC_INTERNAL, "a regenerative cycle had nonpositive duration");
    if (!rmc_add_cycle(sim)) return 0;
    rmc_duration_add(sim, duration);
    sim->collected_time += duration;
    check_due = sim->estimator_cycles >= options->minimum_cycles
        && (((sim->estimator_cycles - options->minimum_cycles) % options->check_every_cycles) == 0
            || sim->estimator_cycles >= options->maximum_cycles);
    if (check_due) {
        if (!rmc_precision_check(sim, precision_met)) return 0;
    }
    sim->segment_start = sim->time;
    memset(sim->cycle_values, 0, (size_t)sim->slots->count * sizeof(double));
    sim->cycle_log_weight = 0.0;
    sim->cycle_events = 0;
    return 1;
}

/* Stopping reasons, in the spelling the Python reports. */
static const char *const RMC_REASON_MAX_CYCLES   = "maximum_cycles";
static const char *const RMC_REASON_MAX_EVENTS   = "maximum_events";
static const char *const RMC_REASON_MAX_TIME     = "maximum_simulated_time";
static const char *const RMC_REASON_MAX_WALL     = "maximum_wall_seconds";
static const char *const RMC_REASON_PRECISION    = "precision_target_met";

static int rmc_run(rmc_simulator *sim, const char **reason_out, int *precision_met_out)
{
    const rmc_model *model = sim->model;
    const rmc_stopping *options = &model->stopping;
    int n = model->node_count, k = model->class_count;
    const char *reason = RMC_REASON_MAX_CYCLES;
    int precision_met = 0;
    /* Wall-clock is consulted every 4096 events rather than every event:
     * clock() is a syscall-grade cost next to one event here, and at the C
     * engine's rate it would be a measurable fraction of the run. The check
     * granularity is far finer than any plausible deadline. */
    const long wall_check_interval = 4096;
    long wall_countdown = wall_check_interval;

    for (;;) {
        int count = 0, node_index, class_index, selected;
        double original_total = 0.0, proposal_total = 0.0, uniform, duration, draw, cumulative;

        if (sim->estimator_cycles >= options->maximum_cycles) { reason = RMC_REASON_MAX_CYCLES; break; }
        if (sim->events >= options->maximum_events) {
            reason = RMC_REASON_MAX_EVENTS;
            sim->discarded_incomplete_cycle = sim->collecting;
            break;
        }
        if (sim->time >= options->maximum_simulated_time) {
            reason = RMC_REASON_MAX_TIME;
            sim->discarded_incomplete_cycle = sim->collecting;
            break;
        }
        if (--wall_countdown <= 0) {
            wall_countdown = wall_check_interval;
            if (rmc_wall_seconds(sim->start_wall) >= options->maximum_wall_seconds) {
                reason = RMC_REASON_MAX_WALL;
                sim->discarded_incomplete_cycle = sim->collecting;
                break;
            }
        }

        /* External events first, class-major, then one service event per busy
         * node — the order the Python builds them in, because the selection
         * scan below depends on it. */
        for (class_index = 0; class_index < k; class_index++) {
            for (node_index = 0; node_index < n; node_index++) {
                double original = model->classes[class_index].external_rates[node_index];
                double proposal;
                if (!(original > 0.0)) continue;
                proposal = model->rare_event.enabled
                    ? original * model->rare_event.arrival_rate_multiplier : original;
                sim->events_buffer[count].kind = 0;
                sim->events_buffer[count].node = node_index;
                sim->events_buffer[count].class_index = class_index;
                sim->events_buffer[count].original_rate = original;
                sim->events_buffer[count].proposal_rate = proposal;
                count++;
                original_total += original;
                proposal_total += proposal;
            }
        }
        for (node_index = 0; node_index < n; node_index++) {
            int servers = model->nodes[node_index].servers;
            int length = sim->queue_length[node_index];
            int busy = length < servers ? length : servers;
            double original, proposal;
            if (!busy) continue;
            original = busy * model->nodes[node_index].service_rate;
            proposal = busy * (model->rare_event.enabled
                               ? model->nodes[node_index].service_rate
                                 * model->rare_event.service_rate_multiplier
                               : model->nodes[node_index].service_rate);
            sim->events_buffer[count].kind = 1;
            sim->events_buffer[count].node = node_index;
            sim->events_buffer[count].class_index = -1;
            sim->events_buffer[count].original_rate = original;
            sim->events_buffer[count].proposal_rate = proposal;
            count++;
            original_total += original;
            proposal_total += proposal;
        }
        if (proposal_total <= 0.0 || count == 0) {
            return fail(RMC_INTERNAL, "the event calendar is empty");
        }

        uniform = bnet_pyrandom_double(&sim->time_rng);
        while (uniform == 0.0) uniform = bnet_pyrandom_double(&sim->time_rng);
        duration = -log1p(-uniform) / proposal_total;
        if (sim->time + duration > options->maximum_simulated_time) {
            reason = RMC_REASON_MAX_TIME;
            sim->discarded_incomplete_cycle = sim->collecting;
            break;
        }
        if (sim->time + duration - sim->segment_start > options->maximum_cycle_time) {
            return fail(RMC_CYCLE_LIMIT,
                        "%s exceeded stopping.maximum_cycle_time; it was not truncated or used",
                        sim->collecting ? "complete_cycle" : "delayed_first_cycle");
        }

        rmc_accrue(sim, duration);
        if (sim->collecting && model->rare_event.enabled) {
            sim->cycle_log_weight += (proposal_total - original_total) * duration;
        }
        sim->time += duration;

        draw = bnet_pyrandom_double(&sim->choice_rng) * proposal_total;
        cumulative = 0.0;
        selected = count - 1;
        {
            int i;
            for (i = 0; i < count; i++) {
                cumulative += sim->events_buffer[i].proposal_rate;
                if (draw < cumulative) { selected = i; break; }
            }
        }
        rmc_execute_event(sim, &sim->events_buffer[selected]);
        if (g_error_kind != RMC_OK) return 0;
        sim->events += 1;
        sim->cycle_events += 1;
        if (sim->cycle_events > options->maximum_events_per_cycle) {
            return fail(RMC_CYCLE_LIMIT,
                        "%s exceeded stopping.maximum_events_per_cycle; it was not used",
                        sim->collecting ? "complete_cycle" : "delayed_first_cycle");
        }

        if (sim->total_jobs == 0) {
            if (sim->collecting) {
                int met = 0;
                if (!rmc_finalize_cycle(sim, &met)) return 0;
                if (met) { reason = RMC_REASON_PRECISION; precision_met = 1; break; }
            } else {
                sim->delayed_time = sim->time;
                sim->collecting = 1;
                sim->segment_start = sim->time;
                memset(sim->cycle_values, 0, (size_t)sim->slots->count * sizeof(double));
                sim->cycle_log_weight = 0.0;
                sim->cycle_events = 0;
            }
        }
    }
    *reason_out = reason;
    *precision_met_out = precision_met;
    return 1;
}

/* ------------------------------------------------------------------ output */

/*
 * Column widths in the Python report are CHARACTER counts (f"{s:<14}"), and
 * printf's %-14s counts BYTES. Node and class identifiers come from the user's
 * canvas and may be non-ASCII, so the two would drift apart on exactly the
 * documents where alignment matters most. These helpers count UTF-8 code
 * points, which is what Python is counting.
 */
static int rmc_display_width(const char *s)
{
    int width = 0;
    while (*s) { if ((*s & 0xC0) != 0x80) width++; s++; }
    return width;
}

static void rmc_pad_left(char *out, size_t size, const char *text, int width)
{
    int pad = width - rmc_display_width(text);
    size_t used = 0;
    if (pad < 0) pad = 0;
    while (pad-- > 0 && used + 1 < size) out[used++] = ' ';
    snprintf(out + used, size - used, "%s", text);
}

static void rmc_pad_right(char *out, size_t size, const char *text, int width)
{
    int pad;
    snprintf(out, size, "%s", text);
    pad = width - rmc_display_width(text);
    { size_t used = strlen(out);
      while (pad-- > 0 && used + 1 < size) out[used++] = ' ';
      out[used] = '\0'; }
}

/* `_fmt` in the Python: a fixed fraction length, or "-" for an absent or
 * non-finite value. Fixed on purpose — the GUI rewrites every number to the
 * user's decimal setting without padding, so only a column of uniform width
 * survives as a column. */
static const char *rmc_fmt(char *buffer, size_t size, int available, double value, int digits)
{
    if (!available || !isfinite(value)) { snprintf(buffer, size, "-"); return buffer; }
    snprintf(buffer, size, "%.*f", digits, value);
    return buffer;
}

/* `_human_number`: the parser-facing token, at 17 significant digits. */
static const char *rmc_human_number(char *buffer, size_t size, int available, double value)
{
    if (!available || !isfinite(value)) { snprintf(buffer, size, "NA"); return buffer; }
    snprintf(buffer, size, "%.17g", value);
    return buffer;
}

/* urllib.parse.quote(text, safe='') — unreserved characters pass, everything
 * else becomes %XX. The machine records depend on this exactly: a node id with
 * a space or a slash must not break the one-record-per-line grammar. */
static void rmc_percent_encode(char *out, size_t size, const char *text)
{
    static const char *hex = "0123456789ABCDEF";
    size_t used = 0;
    for (; *text && used + 4 < size; text++) {
        unsigned char c = (unsigned char)*text;
        int unreserved = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
                       || (c >= '0' && c <= '9')
                       || c == '_' || c == '.' || c == '-' || c == '~';
        if (unreserved) {
            out[used++] = (char)c;
        } else {
            out[used++] = '%';
            out[used++] = hex[c >> 4];
            out[used++] = hex[c & 0x0F];
        }
    }
    out[used] = '\0';
}

/* The confidence interval a completed run reports, from `RatioAccumulator.summary`. */
typedef struct {
    int    available;
    double estimate;
    int    has_standard_error;
    double standard_error;
    double effective_cycles;
    long   numerator_positive_cycles;
    int    has_interval;
    double confidence;
    double critical_value;
    double half_width;
    double low, high;
} rmc_summary;

static int rmc_summarize(const rmc_accumulator *a, const rmc_metric *m,
                         double confidence, rmc_summary *out)
{
    rmc_core core;
    memset(out, 0, sizeof *out);
    if (!rmc_accumulator_core(a, m, &core)) return 0;
    out->available = core.available;
    if (!core.available) return 1;
    out->estimate = core.estimate;
    out->has_standard_error = core.has_standard_error;
    out->standard_error = core.standard_error;
    out->effective_cycles = core.effective_cycles;
    out->numerator_positive_cycles = core.numerator_positive_cycles;
    if (!core.has_standard_error) return 1;
    {
        double critical, half_width, low, high;
        if (!rmc_student_t_quantile(0.5 + confidence / 2.0, a->cycles - 1, &critical)) return 0;
        half_width = critical * core.standard_error;
        low = core.estimate - half_width;
        high = core.estimate + half_width;
        if (m->has_lower_bound && low < m->lower_bound) low = m->lower_bound;
        if (m->has_upper_bound && high > m->upper_bound) high = m->upper_bound;
        out->has_interval = 1;
        out->confidence = confidence;
        out->critical_value = critical;
        out->half_width = half_width;
        out->low = low;
        out->high = high;
    }
    return 1;
}

/* ------------------------------------------------------- analytic benchmark */

typedef struct {
    int    available;
    char   model[32];
    int    has_capacity;
    int    capacity;
    double arrival_rate, service_rate, traffic_intensity;
    double mean_number_in_system, utilization;
    double external_blocking_probability, departure_rate;
} rmc_benchmark;

static void rmc_analytic_benchmark(const rmc_model *model, rmc_benchmark *out)
{
    const rmc_node *node;
    const rmc_class *customer;
    double arrival, service, rho, log_rho;
    int capacity, i;
    memset(out, 0, sizeof *out);
    if (model->node_count != 1 || model->class_count != 1) return;
    node = &model->nodes[0];
    customer = &model->classes[0];
    if (node->servers != 1) return;
    for (i = 0; i < model->node_count; i++) if (customer->routing[i] != 0.0) return;
    arrival = customer->external_rates[0];
    service = node->service_rate;
    rho = arrival / service;
    if (node->capacity < 0) {
        if (rho >= 1.0) return;
        out->available = 1;
        strcpy(out->model, "M/M/1");
        out->arrival_rate = arrival;
        out->service_rate = service;
        out->traffic_intensity = rho;
        out->mean_number_in_system = rho / (1.0 - rho);
        out->utilization = rho;
        out->external_blocking_probability = 0.0;
        out->departure_rate = arrival;
        return;
    }
    capacity = node->capacity;
    log_rho = log(rho);
    out->available = 1;
    strcpy(out->model, "M/M/1/K");
    out->has_capacity = 1;
    out->capacity = capacity;
    out->arrival_rate = arrival;
    out->service_rate = service;
    out->traffic_intensity = rho;
    if (log_rho == 0.0) {
        double full_probability = 1.0 / (capacity + 1);
        out->mean_number_in_system = capacity / 2.0;
        out->external_blocking_probability = full_probability;
        out->utilization = 1.0 - full_probability;
        out->departure_rate = arrival * (1.0 - full_probability);
        return;
    }
    {
        /* Written in |log rho| so both the light- and heavy-traffic ends stay
         * away from cancellation; the Python does the same and the two must
         * land on the same double. */
        double magnitude = fabs(log_rho);
        double edge_probability = -expm1(-magnitude) / -expm1(-(capacity + 1) * magnitude);
        double opposite_edge = edge_probability * exp(-capacity * magnitude);
        double span = (capacity + 1) * magnitude;
        double mean_from_heavy_edge;
        double empty_probability, full_probability, mean_number;
        if (span < 1.0e-5) {
            mean_from_heavy_edge = capacity / 2.0
                - magnitude * capacity * (capacity + 2) / 12.0;
        } else {
            double first_term = (magnitude > 700.0) ? 0.0 : 1.0 / expm1(magnitude);
            double second_term = (span > 700.0) ? 0.0 : (capacity + 1) / expm1(span);
            mean_from_heavy_edge = first_term - second_term;
        }
        if (log_rho < 0.0) {
            empty_probability = edge_probability;
            full_probability = opposite_edge;
            mean_number = mean_from_heavy_edge;
        } else {
            full_probability = edge_probability;
            empty_probability = opposite_edge;
            mean_number = capacity - mean_from_heavy_edge;
        }
        out->mean_number_in_system = mean_number;
        out->utilization = 1.0 - empty_probability;
        out->external_blocking_probability = full_probability;
        out->departure_rate = arrival * (1.0 - full_probability);
    }
}

/* ------------------------------------------------------------ human report */

static const rmc_summary *rmc_find_summary(const rmc_metric_list *metrics,
                                           const rmc_summary *summaries, const char *key)
{
    int position = rmc_metric_position(metrics, key);
    return position < 0 ? NULL : &summaries[position];
}

static void rmc_print_ci_row(const char *label, const rmc_summary *summary)
{
    char elided[512], quantity[512], estimate[64], error[64], span[128], padded_span[160], effective[64];
    char scratch[64];
    if (!summary || !summary->available) return;
    /* Node and class ids are user-supplied and can be long. Letting one run
     * past its column shifts every number to its right, which is exactly the
     * ragged output the report exists to avoid. Elide instead — at 33
     * characters, as the Python does. */
    if (rmc_display_width(label) > 33) {
        int kept = 0;
        size_t used = 0;
        const char *scan = label;
        while (*scan && kept < 32) {
            size_t length = 1;
            while (scan[length] && (scan[length] & 0xC0) == 0x80) length++;
            if (used + length + 4 >= sizeof elided) break;
            memcpy(elided + used, scan, length);
            used += length;
            scan += length;
            kept++;
        }
        memcpy(elided + used, "\xe2\x80\xa6", 3);          /* U+2026 HORIZONTAL ELLIPSIS */
        elided[used + 3] = '\0';
        label = elided;
    }
    rmc_pad_right(quantity, sizeof quantity, label, 34);
    rmc_pad_left(estimate, sizeof estimate,
                 rmc_fmt(scratch, sizeof scratch, 1, summary->estimate, 6), 13);
    rmc_pad_left(error, sizeof error,
                 rmc_fmt(scratch, sizeof scratch, summary->has_standard_error,
                         summary->standard_error, 6), 12);
    if (summary->has_interval) {
        char lo[64], hi[64];
        snprintf(span, sizeof span, "[%s, %s]",
                 rmc_fmt(lo, sizeof lo, 1, summary->low, 6),
                 rmc_fmt(hi, sizeof hi, 1, summary->high, 6));
    } else {
        snprintf(span, sizeof span, "-");
    }
    rmc_pad_left(padded_span, sizeof padded_span, span, 26);
    rmc_pad_left(effective, sizeof effective,
                 rmc_fmt(scratch, sizeof scratch, 1, summary->effective_cycles, 1), 13);
    printf("%s%s%s%s%s\n", quantity, estimate, error, padded_span, effective);
}

static void rmc_print_human(const rmc_model *model, const rmc_simulator *sim,
                            const rmc_metric_list *metrics, const rmc_summary *summaries,
                            const rmc_benchmark *benchmark,
                            const char *stopping_reason, int precision_met)
{
    char key[384], label[512], line[1024];
    char header[128], ci_header[160];
    int node_index, class_index, i;
    int machine_written = 0;

    printf("Regenerative Monte Carlo\n");
    printf("Model layer: queueing process (simulation)\n");
    printf("Evidence: regenerative ratio confidence intervals; asymptotic, not "
           "finite-sample, and they describe sampling error only\n");
    printf("Model: %s\n", model->name);
    printf("\n");
    printf("Complete empty-to-empty cycles: %ld\n", sim->estimator_cycles);
    printf("Stopping reason: %s\n", stopping_reason);
    printf("Precision target met: %s\n", precision_met ? "yes" : "no");
    printf("\n");

    /* Per-node table */
    {
        char c1[32], c2[32], c3[32], c4[32], c0[32];
        rmc_pad_right(c0, sizeof c0, "Node", 14);
        rmc_pad_left(c1, sizeof c1, "E[N]", 13);
        rmc_pad_left(c2, sizeof c2, "E[Q]", 13);
        rmc_pad_left(c3, sizeof c3, "utilisation", 13);
        rmc_pad_left(c4, sizeof c4, "throughput", 13);
        snprintf(header, sizeof header, "%s%s%s%s%s", c0, c1, c2, c3, c4);
    }
    printf("%s\n", header);
    for (i = 0; i < (int)strlen(header); i++) putchar('-');
    putchar('\n');
    for (node_index = 0; node_index < model->node_count; node_index++) {
        const char *node_id = model->nodes[node_index].id;
        static const char *const prefixes[4] = {
            "mean_number_at_node", "mean_queue_at_node", "utilization", "service_completion_rate"
        };
        char columns[4][64], padded[4][64], name[64];
        int column;
        for (column = 0; column < 4; column++) {
            const rmc_summary *summary;
            snprintf(key, sizeof key, "%s:%s", prefixes[column], node_id);
            summary = rmc_find_summary(metrics, summaries, key);
            rmc_fmt(columns[column], sizeof columns[column],
                    summary && summary->available, summary ? summary->estimate : 0.0, 6);
            rmc_pad_left(padded[column], sizeof padded[column], columns[column], 13);
        }
        rmc_pad_right(name, sizeof name, node_id, 14);
        snprintf(line, sizeof line, "%s%s%s%s%s", name, padded[0], padded[1], padded[2], padded[3]);
        printf("%s\n", line);
    }
    printf("\n");

    /* Confidence-interval table */
    {
        char c0[64], c1[32], c2[32], c3[64], c4[32];
        rmc_pad_right(c0, sizeof c0, "Quantity", 34);
        rmc_pad_left(c1, sizeof c1, "estimate", 13);
        rmc_pad_left(c2, sizeof c2, "std error", 12);
        rmc_pad_left(c3, sizeof c3, "95% interval", 26);
        rmc_pad_left(c4, sizeof c4, "eff. cycles", 13);
        snprintf(ci_header, sizeof ci_header, "%s%s%s%s%s", c0, c1, c2, c3, c4);
    }
    printf("%s\n", ci_header);
    for (i = 0; i < (int)strlen(ci_header); i++) putchar('-');
    putchar('\n');
    rmc_print_ci_row("Mean number in system",
                     rmc_find_summary(metrics, summaries, "mean_number_in_system"));
    rmc_print_ci_row("External blocking probability",
                     rmc_find_summary(metrics, summaries, "external_blocking_probability"));
    rmc_print_ci_row("Departure rate",
                     rmc_find_summary(metrics, summaries, "departure_rate"));
    for (node_index = 0; node_index < model->node_count; node_index++) {
        const char *node_id = model->nodes[node_index].id;
        snprintf(label, sizeof label, "E[N] at %s", node_id);
        snprintf(key, sizeof key, "mean_number_at_node:%s", node_id);
        rmc_print_ci_row(label, rmc_find_summary(metrics, summaries, key));
        snprintf(label, sizeof label, "utilisation at %s", node_id);
        snprintf(key, sizeof key, "utilization:%s", node_id);
        rmc_print_ci_row(label, rmc_find_summary(metrics, summaries, key));
        for (class_index = 0; class_index < model->class_count; class_index++) {
            const char *class_id = model->classes[class_index].id;
            snprintf(label, sizeof label, "E[N] at %s, class %s", node_id, class_id);
            snprintf(key, sizeof key, "mean_number:%s:%s", node_id, class_id);
            rmc_print_ci_row(label, rmc_find_summary(metrics, summaries, key));
        }
    }
    printf("\n");

    if (benchmark->available) printf("Analytic check available: %s\n", benchmark->model);
    if (model->rare_event.enabled) {
        double effective = (sim->estimator_cycles && sim->sum_weight2 > 0.0)
            ? sim->sum_weight * sim->sum_weight / sim->sum_weight2 : 0.0;
        printf("Importance-sampling weight ESS: %.1f of %ld cycles\n",
               effective, sim->estimator_cycles);
    }
    printf("Uncertainty uses complete regenerative cycles, not individual events.\n");

    /* Machine records, last and unchanged: ResultOutputParser and the CSV
     * export read these out of the tee'd archive, and the GUI's display filter
     * withholds them from the screen. */
    for (node_index = 0; node_index < model->node_count; node_index++) {
        const char *node_id = model->nodes[node_index].id;
        static const char *const prefixes[4] = {
            "mean_number_at_node", "mean_queue_at_node", "utilization", "service_completion_rate"
        };
        static const char *const tokens[4] = {
            "mean_number", "mean_queue", "utilization", "service_completion_rate"
        };
        int column;
        char encoded_node[512], encoded_class[512];
        rmc_percent_encode(encoded_node, sizeof encoded_node, node_id);
        for (column = 0; column < 4; column++) {
            const rmc_summary *summary;
            char estimate[64], error[64], confidence[64], low[64], high[64], half[64], effective[64];
            snprintf(key, sizeof key, "%s:%s", prefixes[column], node_id);
            summary = rmc_find_summary(metrics, summaries, key);
            if (!summary || !summary->available) continue;
            if (!machine_written) { printf("\n"); machine_written = 1; }
            printf("QNET_NODE_METRIC_V1 node_id=%s metric=%s class_id=- estimate=%s "
                   "standard_error=%s ci_confidence=%s ci_low=%s ci_high=%s "
                   "ci_half_width=%s effective_cycles=%s\n",
                   encoded_node, tokens[column],
                   rmc_human_number(estimate, sizeof estimate, 1, summary->estimate),
                   rmc_human_number(error, sizeof error, summary->has_standard_error, summary->standard_error),
                   rmc_human_number(confidence, sizeof confidence, summary->has_interval, summary->confidence),
                   rmc_human_number(low, sizeof low, summary->has_interval, summary->low),
                   rmc_human_number(high, sizeof high, summary->has_interval, summary->high),
                   rmc_human_number(half, sizeof half, summary->has_interval, summary->half_width),
                   rmc_human_number(effective, sizeof effective, 1, summary->effective_cycles));
        }
        for (class_index = 0; class_index < model->class_count; class_index++) {
            const char *class_id = model->classes[class_index].id;
            const rmc_summary *summary;
            char estimate[64], error[64], confidence[64], low[64], high[64], half[64], effective[64];
            snprintf(key, sizeof key, "mean_number:%s:%s", node_id, class_id);
            summary = rmc_find_summary(metrics, summaries, key);
            if (!summary || !summary->available) continue;
            rmc_percent_encode(encoded_class, sizeof encoded_class, class_id);
            if (!machine_written) { printf("\n"); machine_written = 1; }
            printf("QNET_NODE_METRIC_V1 node_id=%s metric=mean_number_class class_id=%s estimate=%s "
                   "standard_error=%s ci_confidence=%s ci_low=%s ci_high=%s "
                   "ci_half_width=%s effective_cycles=%s\n",
                   encoded_node, encoded_class,
                   rmc_human_number(estimate, sizeof estimate, 1, summary->estimate),
                   rmc_human_number(error, sizeof error, summary->has_standard_error, summary->standard_error),
                   rmc_human_number(confidence, sizeof confidence, summary->has_interval, summary->confidence),
                   rmc_human_number(low, sizeof low, summary->has_interval, summary->low),
                   rmc_human_number(high, sizeof high, summary->has_interval, summary->high),
                   rmc_human_number(half, sizeof half, summary->has_interval, summary->half_width),
                   rmc_human_number(effective, sizeof effective, 1, summary->effective_cycles));
        }
    }
}

/* -------------------------------------------------------------- JSON output */

/*
 * The JSON carries the same VALUES as the Python's, but is not promised to be
 * byte-identical to it: Python's json module writes floats with repr()'s
 * shortest round-trip digits and sorts keys, and reproducing both exactly in C
 * would be a second formatter to keep in step for no gain. The parity test
 * therefore compares the human output byte for byte (that is what the GUI
 * shows) and the JSON by parsing both and comparing numbers exactly.
 *
 * Shortest round-trip is still used for the numbers here, because a 17-digit
 * 0.10000000000000001 in a document a person may read is noise.
 */
static void rmc_json_number(FILE *out, double value)
{
    char buffer[64];
    if (!isfinite(value)) { fprintf(out, "null"); return; }
    fprintf(out, "%s", rmc_repr(buffer, sizeof buffer, value));
}

static void rmc_json_string(FILE *out, const char *text)
{
    fputc('"', out);
    for (; *text; text++) {
        unsigned char c = (unsigned char)*text;
        switch (c) {
        case '"':  fputs("\\\"", out); break;
        case '\\': fputs("\\\\", out); break;
        case '\n': fputs("\\n", out); break;
        case '\r': fputs("\\r", out); break;
        case '\t': fputs("\\t", out); break;
        default:
            if (c < 0x20) fprintf(out, "\\u%04x", c);
            else fputc((char)c, out);
        }
    }
    fputc('"', out);
}

static void rmc_json_optional(FILE *out, int available, double value)
{
    if (!available || !isfinite(value)) fprintf(out, "null");
    else rmc_json_number(out, value);
}

static void rmc_write_json(FILE *out, const rmc_model *model, const rmc_simulator *sim,
                           const rmc_metric_list *metrics, const rmc_summary *summaries,
                           const rmc_benchmark *benchmark,
                           const char *stopping_reason, int precision_met)
{
    int i;
    fprintf(out, "{\n  \"schema_version\": 1,\n");
    fprintf(out, "  \"process\": \"open_markovian_queueing_network\",\n");
    fprintf(out, "  \"status\": \"ok\",\n");
    fprintf(out, "  \"engine\": \"c\",\n");
    fprintf(out, "  \"model\": {\"name\": "); rmc_json_string(out, model->name);
    fprintf(out, ", \"node_count\": %d, \"class_count\": %d, \"node_ids\": [",
            model->node_count, model->class_count);
    for (i = 0; i < model->node_count; i++) {
        if (i) fprintf(out, ", ");
        rmc_json_string(out, model->nodes[i].id);
    }
    fprintf(out, "], \"class_ids\": [");
    for (i = 0; i < model->class_count; i++) {
        if (i) fprintf(out, ", ");
        rmc_json_string(out, model->classes[i].id);
    }
    fprintf(out, "], \"buffer_mode\": \"%s\"},\n",
            model->finite_buffers ? "finite_loss_on_arrival" : "infinite");
    fprintf(out, "  \"random\": {\"base_seed\": %llu, \"stream\": %llu, \"time_seed\": %llu, "
                 "\"choice_seed\": %llu},\n",
            model->base_seed, model->stream, sim->time_seed, sim->choice_seed);
    fprintf(out, "  \"regeneration\": {\"initial_state_was_regeneration\": %s, "
                 "\"delayed_time\": ", sim->initial_state_was_regeneration ? "true" : "false");
    rmc_json_number(out, sim->delayed_time);
    fprintf(out, ", \"complete_cycles\": %ld, \"proposal_simulated_time\": ", sim->estimator_cycles);
    rmc_json_number(out, sim->time);
    fprintf(out, ", \"proposal_collected_cycle_time\": ");
    rmc_json_number(out, sim->collected_time);
    fprintf(out, ", \"events\": %ld, \"incomplete_final_cycle_discarded\": %s},\n",
            sim->events, sim->discarded_incomplete_cycle ? "true" : "false");
    fprintf(out, "  \"precision\": {\"target_met\": %s, \"stopping_reason\": ",
            precision_met ? "true" : "false");
    rmc_json_string(out, stopping_reason);
    fprintf(out, ", \"look\": %ld, \"overall_confidence\": ", sim->have_precision ? sim->precision_look : 0L);
    rmc_json_number(out, model->stopping.confidence);
    fprintf(out, "},\n  \"estimates\": {\n");
    for (i = 0; i < metrics->count; i++) {
        const rmc_summary *s = &summaries[i];
        fprintf(out, "    ");
        rmc_json_string(out, metrics->items[i].key);
        fprintf(out, ": {\"available\": %s", s->available ? "true" : "false");
        if (s->available) {
            fprintf(out, ", \"estimate\": "); rmc_json_number(out, s->estimate);
            fprintf(out, ", \"standard_error\": ");
            rmc_json_optional(out, s->has_standard_error, s->standard_error);
            fprintf(out, ", \"effective_cycles\": "); rmc_json_number(out, s->effective_cycles);
            if (s->has_interval) {
                fprintf(out, ", \"confidence_interval\": {\"confidence\": ");
                rmc_json_number(out, s->confidence);
                fprintf(out, ", \"half_width\": "); rmc_json_number(out, s->half_width);
                fprintf(out, ", \"low\": "); rmc_json_number(out, s->low);
                fprintf(out, ", \"high\": "); rmc_json_number(out, s->high);
                fprintf(out, "}");
            } else {
                fprintf(out, ", \"confidence_interval\": null");
            }
        }
        fprintf(out, "}%s\n", i + 1 < metrics->count ? "," : "");
    }
    fprintf(out, "  },\n  \"analytic_benchmark\": ");
    if (!benchmark->available) {
        fprintf(out, "null");
    } else {
        fprintf(out, "{\"model\": "); rmc_json_string(out, benchmark->model);
        fprintf(out, ", \"traffic_intensity\": "); rmc_json_number(out, benchmark->traffic_intensity);
        fprintf(out, ", \"mean_number_in_system\": ");
        rmc_json_number(out, benchmark->mean_number_in_system);
        fprintf(out, ", \"utilization\": "); rmc_json_number(out, benchmark->utilization);
        fprintf(out, ", \"external_blocking_probability\": ");
        rmc_json_number(out, benchmark->external_blocking_probability);
        fprintf(out, ", \"departure_rate\": "); rmc_json_number(out, benchmark->departure_rate);
        fprintf(out, "}");
    }
    fprintf(out, "\n}\n");
}

/* ---------------------------------------------------------------- lifetime */

static void rmc_model_free(rmc_model *model)
{
    int i;
    for (i = 0; i < model->class_count; i++) {
        free(model->classes[i].external_rates);
        free(model->classes[i].routing);
    }
    free(model->classes);
    free(model->nodes);
    free(model->initial_jobs);
    free(model->traffic_rates);
    free(model->offered_loads);
    for (i = 0; i < model->stopping.monitored_count; i++) free(model->stopping.monitored_metrics[i]);
    free(model->stopping.monitored_metrics);
    memset(model, 0, sizeof *model);
}

static void rmc_simulator_free(rmc_simulator *sim)
{
    int i;
    if (sim->queues) {
        for (i = 0; i < sim->model->node_count; i++) free(sim->queues[i]);
        free(sim->queues);
    }
    free(sim->queue_length); free(sim->queue_capacity); free(sim->counts);
    free(sim->cycle_values); free(sim->accumulators); free(sim->events_buffer);
    free(sim->slot_area_node); free(sim->slot_area_queue); free(sim->slot_area_busy);
    free(sim->slot_count_service); free(sim->slot_area_node_class); free(sim->slot_area_class);
    free(sim->slot_ext_offered_class); free(sim->slot_ext_accepted_class);
    free(sim->slot_ext_blocked_class); free(sim->slot_departure_class); free(sim->slot_exit_class);
}

static void rmc_slots_free(rmc_slots *slots)
{
    int i;
    for (i = 0; i < slots->count; i++) free(slots->names[i]);
    free(slots->names);
}

static void usage(FILE *out, const char *program)
{
    fprintf(out,
        "usage: %s <model.json|-> [--json] [-o FILE]\n"
        "\n"
        "Regenerative Monte Carlo for open Markovian queueing networks (C engine).\n"
        "Reads the same document regenerative_mc.py reads and, apart from the\n"
        "wall-clock safeguard, prints byte-identical output.\n"
        "\n"
        "  --json        write the structured result instead of the report\n"
        "  -o FILE       write the structured result to FILE\n"
        "  --version     print the engine identity and exit\n", program);
}

int main(int argc, char **argv)
{
    const char *path = NULL, *output_path = NULL;
    int want_json = 0, i;
    bnet_json document;
    rmc_model model;
    rmc_metric_list metrics;
    rmc_slots slots;
    rmc_simulator sim;
    rmc_summary *summaries = NULL;
    rmc_benchmark benchmark;
    const char *stopping_reason = "maximum_cycles";
    int precision_met = 0;
    int exit_code = 0;

    memset(&metrics, 0, sizeof metrics);
    memset(&slots, 0, sizeof slots);
    memset(&model, 0, sizeof model);
    memset(&sim, 0, sizeof sim);

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--json") == 0) { want_json = 1; }
        else if (strcmp(argv[i], "--compact") == 0) { want_json = 1; }
        else if (strcmp(argv[i], "--version") == 0) {
            printf("bna_rmc (Qnet regenerative Monte Carlo, C engine) 1.0.0\n");
            return 0;
        }
        else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            usage(stdout, argv[0]);
            return 0;
        }
        else if (strcmp(argv[i], "-o") == 0 || strcmp(argv[i], "--output") == 0) {
            if (++i >= argc) { fprintf(stderr, "%s: -o needs a path\n", argv[0]); return 2; }
            output_path = argv[i];
        }
        /* The GUI's loadability probe starts the binary only to prove its
         * dynamic dependencies resolve; reaching main is the whole test. */
        else if (strcmp(argv[i], "--qnet-loadability-probe") == 0) { return 0; }
        else if (argv[i][0] == '-' && argv[i][1] != '\0' && strcmp(argv[i], "-") != 0) {
            fprintf(stderr, "%s: unknown option %s\n", argv[0], argv[i]);
            usage(stderr, argv[0]);
            return 2;
        }
        else if (!path) { path = argv[i]; }
        else { fprintf(stderr, "%s: unexpected argument %s\n", argv[0], argv[i]); return 2; }
    }
    if (!path) { usage(stderr, argv[0]); return 2; }

    if (!bnet_json_parse_file(&document, path)) {
        fprintf(stderr, "Simulation error [invalid_input]: %s\n", document.error);
        bnet_json_free(&document);
        return 2;
    }
    if (!rmc_parse_model(&document, &model)) goto failed;
    if (!rmc_build_metrics(&model, &metrics, &slots)) goto failed;
    for (i = 0; i < model.stopping.monitored_count; i++) {
        if (rmc_metric_position(&metrics, model.stopping.monitored_metrics[i]) < 0) {
            fail(RMC_INVALID_INPUT, "stopping.monitored_metrics contains unknown metric(s): %s",
                 model.stopping.monitored_metrics[i]);
            goto failed;
        }
    }
    if (!rmc_simulator_init(&sim, &model, &metrics, &slots)) goto failed;
    if (!rmc_run(&sim, &stopping_reason, &precision_met)) goto failed;

    summaries = (rmc_summary *)calloc((size_t)metrics.count, sizeof *summaries);
    if (!summaries) { fail(RMC_INTERNAL, "out of memory"); goto failed; }
    for (i = 0; i < metrics.count; i++) {
        if (!rmc_summarize(&sim.accumulators[i], &metrics.items[i],
                           model.stopping.confidence, &summaries[i])) goto failed;
    }
    rmc_analytic_benchmark(&model, &benchmark);

    if (output_path) {
        FILE *out = fopen(output_path, "w");
        if (!out) {
            fprintf(stderr, "cannot write output file '%s'\n", output_path);
            exit_code = 2;
            goto done;
        }
        rmc_write_json(out, &model, &sim, &metrics, summaries, &benchmark,
                       stopping_reason, precision_met);
        fclose(out);
    }
    if (want_json) {
        rmc_write_json(stdout, &model, &sim, &metrics, summaries, &benchmark,
                       stopping_reason, precision_met);
    } else if (!output_path) {
        rmc_print_human(&model, &sim, &metrics, summaries, &benchmark,
                        stopping_reason, precision_met);
    }
    goto done;

failed:
    fprintf(stderr, "Simulation error [%s]: %s\n",
            rmc_error_code_name(g_error_kind), g_error_message);
    exit_code = 2;

done:
    free(summaries);
    rmc_simulator_free(&sim);
    rmc_slots_free(&slots);
    free(metrics.items);
    rmc_model_free(&model);
    bnet_json_free(&document);
    return exit_code;
}
