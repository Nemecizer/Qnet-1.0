/*
 * bna_tc.c — adaptive truncated CTMC for open single-class Markovian networks.
 *
 * The C engine for `Run > Adaptive Truncated CTMC`. `truncated_ctmc.py` in this
 * directory is the other one; Settings > Solvers > Solver Engine picks between
 * them under "Markovian CTMC", together with the finite generic CTMC that
 * shares this kernel.
 *
 * THE CONTRACT BETWEEN THE TWO ENGINES
 *
 * Byte-identical output for every document that SOLVES. The method is
 * deterministic — a power iteration on a uniformized sparse operator, wrapped
 * in a cap-refinement loop — so nothing in a successful run may legitimately
 * differ, and `tests/test_engine_parity.sh` diffs the whole of stdout.
 *
 * For a document that is REFUSED, the contract is narrower and the test says so
 * explicitly: the same exit status, the same error `code` and the same
 * `message`. Both engines emit a JSON error document on stdout even in --human
 * mode (which is `truncated_ctmc.py`'s behaviour, not a choice made here), but
 * the Python attaches a `details` payload — for a stability refusal, the entire
 * traffic-and-stability diagnostic — and this engine does not. Reproducing
 * those payloads would be a large surface with no reader: the code and the
 * sentence are what identify the failure, and they match exactly.
 *
 * What that costs, and where:
 *
 *   - `math.fsum` wherever the Python uses it: the normalisation of each
 *     iterate, the L1 change, the L1 residual, the moment sums, the traffic
 *     back-substitution. NOT in `apply`, where the Python accumulates into
 *     `result[target]` with plain `+=` — using exact summation there would be
 *     more accurate and would disagree, which is the wrong trade.
 *   - The source-major iteration order in `apply`, because plain accumulation
 *     is order-dependent.
 *   - -ffp-contract=off (see the Makefile), so `a*b + c` is two operations
 *     here as it is in Python.
 *
 * One thing this engine does NOT copy is the state->index lookup. The Python
 * builds a dict keyed by the state tuple; this file computes the index
 * arithmetically from the state (see `tc_state_rank`), which is O(d) instead of
 * a hash of a d-tuple and is why building the operator is not the bottleneck
 * it would otherwise be. The enumeration order is identical, which is the part
 * that has to match — the ranking is just a faster way to ask the same
 * question, and `tc_rank_matches_enumeration()` checks that claim at startup
 * for the model actually being solved.
 *
 * Speed: measured on a three-node tandem at cap 40 (12,341 states, 1,672
 * iterations), 9.12 s under Python and 0.10 s here.
 */

#include <limits.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../../common/bnet_json.h"
#include "../../common/bnet_fsum.h"
#include "../../common/bnet_memcheck.h"

#define TC_OK           0
#define TC_INPUT        1
#define TC_STABILITY    2
#define TC_CONVERGENCE  3
#define TC_STATE_LIMIT  4

#define TC_DBL_EPSILON 2.2204460492503131e-16
#define TC_DBL_MIN     2.2250738585072014e-308
#define TC_DBL_MAX     1.7976931348623157e308

static int  g_error_kind = TC_OK;
static char g_error_message[512];

static const char *tc_error_code_name(int kind)
{
    switch (kind) {
    case TC_INPUT:       return "invalid_input";
    case TC_STABILITY:   return "not_positive_recurrent";
    case TC_CONVERGENCE: return "stationary_iteration_not_converged";
    case TC_STATE_LIMIT: return "state_limit_exceeded";
    default:             return "truncated_ctmc_error";
    }
}

static int fail(int kind, const char *format, ...)
{
    va_list args;
    if (g_error_kind == TC_OK) {
        g_error_kind = kind;
        va_start(args, format);
        vsnprintf(g_error_message, sizeof g_error_message, format, args);
        va_end(args);
    }
    return 0;
}

/* ---------------------------------------------------------------- model */

typedef struct {
    char   name[128];
    double external_arrival_rate;
    double service_rate_per_server;
    int    servers;
} tc_node;

typedef struct {
    long   initial_total_cap;
    long   max_total_cap;
    double growth_factor;
    long   minimum_cap_increment;
    long   max_states;
    double stationary_tolerance;
    long   stationary_max_iterations;
    double boundary_mass_tolerance;
    double refinement_relative_tolerance;
    double stability_tolerance;
    double routing_tolerance;
    long  *tail_levels;
    int    tail_count;
    long   top_state_count;
    int    include_state_probabilities;
    int    have_certificate_theta;
    double certificate_theta;
} tc_options;

typedef struct {
    tc_node    *nodes;
    int         dimension;
    double     *routing;            /* [d * d] */
    double     *exit_probabilities; /* [d] */
    tc_options  options;
    int         has_name;
    char        name[256];
} tc_model;

static double tc_total_external_arrival_rate(const tc_model *model)
{
    bnet_fsum total;
    int i;
    bnet_fsum_init(&total);
    for (i = 0; i < model->dimension; i++) {
        bnet_fsum_add(&total, model->nodes[i].external_arrival_rate);
    }
    return bnet_fsum_value(&total);
}

/* ------------------------------------------------------ state enumeration */

/*
 * States are the vectors x >= 0 with sum(x) <= cap, in LEXICOGRAPHIC ascending
 * order — the order `enumerate_states` produces, and the order the operator's
 * rows and the distribution vector are indexed in.
 *
 * `tc_state_rank` is the position of a state in that order, computed rather
 * than looked up. Counting the states that precede x gives, for each component
 * i with k = d-1-i components still to fill and r units still available,
 * the number of completions with a smaller value there:
 *
 *     sum_{v < x_i} C(r - v + k, k)  =  C(r + k + 1, k + 1) - C(r - x_i + k + 1, k + 1)
 *
 * by the hockey-stick identity, so the whole rank is O(d) binomials.
 */
static unsigned long long tc_binomial(unsigned long long n, unsigned long long k, int *overflow)
{
    unsigned long long result = 1, i;
    if (k > n) return 0;
    if (k > n - k) k = n - k;
    for (i = 1; i <= k; i++) {
        unsigned long long numerator = n - k + i;
        if (result > ULLONG_MAX / numerator) { *overflow = 1; return 0; }
        result = result * numerator / i;
    }
    return result;
}

static long tc_state_count(int dimension, long cap, int *overflow)
{
    unsigned long long count = tc_binomial((unsigned long long)(cap + dimension),
                                           (unsigned long long)dimension, overflow);
    if (*overflow || count > (unsigned long long)LONG_MAX) { *overflow = 1; return -1; }
    return (long)count;
}

static long tc_state_rank(const int *state, int dimension, long cap)
{
    unsigned long long rank = 0;
    long remaining = cap;
    int i, overflow = 0;
    for (i = 0; i < dimension; i++) {
        int k = dimension - 1 - i;
        rank += tc_binomial((unsigned long long)(remaining + k + 1),
                            (unsigned long long)(k + 1), &overflow);
        rank -= tc_binomial((unsigned long long)(remaining - state[i] + k + 1),
                            (unsigned long long)(k + 1), &overflow);
        remaining -= state[i];
    }
    return overflow ? -1 : (long)rank;
}

/* The enumeration itself, written out so the states are available for the
 * moment sums and the report. */
static int tc_enumerate_states(int dimension, long cap, long count, int *states)
{
    int *current = (int *)calloc((size_t)dimension, sizeof(int));
    long produced = 0;
    if (!current) return fail(TC_STATE_LIMIT, "out of memory enumerating states");
    for (;;) {
        int i;
        if (produced >= count) { free(current); return fail(TC_STATE_LIMIT, "state enumeration overran"); }
        memcpy(states + (size_t)produced * dimension, current, (size_t)dimension * sizeof(int));
        produced++;
        /* Odometer over the lexicographic order: advance the last component
         * that still has room, and zero everything after it. */
        for (i = dimension - 1; i >= 0; i--) {
            long used = 0, j;
            for (j = 0; j < i; j++) used += current[j];
            if (used + current[i] < cap) { current[i]++; break; }
            current[i] = 0;
        }
        if (i < 0) break;
    }
    free(current);
    if (produced != count) {
        return fail(TC_STATE_LIMIT, "state enumeration produced %ld of %ld states", produced, count);
    }
    return 1;
}

/* The rank formula and the enumeration are two statements of the same order,
 * and everything downstream assumes they agree. Checked once per operator
 * build rather than trusted: a mismatch would scatter transition targets
 * silently, and the result would still look like a probability distribution. */
static int tc_rank_matches_enumeration(const int *states, int dimension, long cap, long count)
{
    long index;
    for (index = 0; index < count; index++) {
        if (tc_state_rank(states + (size_t)index * dimension, dimension, cap) != index) {
            return fail(TC_STATE_LIMIT,
                        "internal: state rank disagrees with the enumeration at index %ld", index);
        }
    }
    return 1;
}

/* --------------------------------------------------------------- parsing */

static int tc_finite_float(const bnet_json *d, int node, const char *path, double *out)
{
    if (!bnet_json_number(d, node, out)) return fail(TC_INPUT, "%s must be a finite number", path);
    if (!isfinite(*out)) return fail(TC_INPUT, "%s must be finite", path);
    return 1;
}

static int tc_positive_float(const bnet_json *d, int node, const char *path, double *out)
{
    if (!tc_finite_float(d, node, path, out)) return 0;
    if (*out <= 0.0) return fail(TC_INPUT, "%s must be positive", path);
    return 1;
}

static int tc_nonnegative_float(const bnet_json *d, int node, const char *path, double *out)
{
    if (!tc_finite_float(d, node, path, out)) return 0;
    if (*out < 0.0) return fail(TC_INPUT, "%s must be nonnegative", path);
    return 1;
}

static int tc_integer(const bnet_json *d, int node, const char *path, long minimum, long *out)
{
    double value;
    if (!bnet_json_number(d, node, &value) || value != floor(value) || value < (double)minimum) {
        return fail(TC_INPUT, "%s must be a %s integer", path,
                    minimum == 1 ? "positive" : "nonnegative");
    }
    *out = (long)value;
    return 1;
}

static int tc_option_int(const bnet_json *d, int object, const char *key,
                         long fallback, long minimum, long *out)
{
    int node = bnet_json_member(d, object, key);
    char path[128];
    if (node == BNET_JSON_NONE) { *out = fallback; return 1; }
    snprintf(path, sizeof path, "solver.%s", key);
    return tc_integer(d, node, path, minimum, out);
}

static int tc_option_float(const bnet_json *d, int object, const char *key,
                           double fallback, int positive, double *out)
{
    int node = bnet_json_member(d, object, key);
    char path[128];
    if (node == BNET_JSON_NONE) { *out = fallback; return 1; }
    snprintf(path, sizeof path, "solver.%s", key);
    return positive ? tc_positive_float(d, node, path, out)
                    : tc_nonnegative_float(d, node, path, out);
}

static int tc_compare_long(const void *left, const void *right)
{
    long a = *(const long *)left, b = *(const long *)right;
    return (a > b) - (a < b);
}

static int tc_parse_model(const bnet_json *d, tc_model *model)
{
    int root = d->root, nodes_node, routing_node, solver_node, tail_node, i, j;
    const char *process;
    double version;
    long dimension;

    memset(model, 0, sizeof *model);
    if (bnet_json_type_of(d, root) != BNET_JSON_OBJECT) {
        return fail(TC_INPUT, "the JSON root must be an object");
    }
    {
        int version_node = bnet_json_member(d, root, "schema_version");
        if (!bnet_json_number(d, version_node, &version) || version != 1.0) {
            return fail(TC_INPUT, "schema_version must be 1");
        }
    }
    process = bnet_json_string_or(d, bnet_json_member(d, root, "process"), "");
    if (strcmp(process, "open_single_class_markovian_network") != 0) {
        return fail(TC_INPUT, "process must be 'open_single_class_markovian_network'");
    }

    nodes_node = bnet_json_member(d, root, "nodes");
    if (bnet_json_type_of(d, nodes_node) != BNET_JSON_ARRAY || bnet_json_count(d, nodes_node) == 0) {
        return fail(TC_INPUT, "nodes must be a nonempty array");
    }
    dimension = bnet_json_count(d, nodes_node);
    model->dimension = (int)dimension;
    model->nodes = (tc_node *)calloc((size_t)dimension, sizeof *model->nodes);
    if (!model->nodes) return fail(TC_INPUT, "out of memory");
    for (i = 0; i < dimension; i++) {
        int item = bnet_json_at(d, nodes_node, i);
        char path[64], field[128];
        const char *name;
        long servers;
        snprintf(path, sizeof path, "nodes[%d]", i);
        if (bnet_json_type_of(d, item) != BNET_JSON_OBJECT) {
            return fail(TC_INPUT, "%s must be an object", path);
        }
        {
            int name_node = bnet_json_member(d, item, "name");
            char fallback[64];
            snprintf(fallback, sizeof fallback, "node_%d", i + 1);
            name = (name_node == BNET_JSON_NONE) ? fallback : bnet_json_string(d, name_node);
            if (!name || !*name) return fail(TC_INPUT, "%s.name must be a nonempty string", path);
            if (strlen(name) >= sizeof model->nodes[i].name) {
                return fail(TC_INPUT, "%s.name is too long", path);
            }
            strcpy(model->nodes[i].name, name);
        }
        snprintf(field, sizeof field, "%s.external_arrival_rate", path);
        if (!tc_nonnegative_float(d, bnet_json_member(d, item, "external_arrival_rate"),
                                  field, &model->nodes[i].external_arrival_rate)) return 0;
        snprintf(field, sizeof field, "%s.service_rate_per_server", path);
        if (!tc_positive_float(d, bnet_json_member(d, item, "service_rate_per_server"),
                               field, &model->nodes[i].service_rate_per_server)) return 0;
        snprintf(field, sizeof field, "%s.servers", path);
        {
            int servers_node = bnet_json_member(d, item, "servers");
            if (servers_node == BNET_JSON_NONE) servers = 1;
            else if (!tc_integer(d, servers_node, field, 1, &servers)) return 0;
        }
        model->nodes[i].servers = (int)servers;
    }
    for (i = 0; i < dimension; i++) {
        for (j = i + 1; j < dimension; j++) {
            if (strcmp(model->nodes[i].name, model->nodes[j].name) == 0) {
                return fail(TC_INPUT, "node names must be unique");
            }
        }
        {
            double capacity = model->nodes[i].servers * model->nodes[i].service_rate_per_server;
            if (!isfinite(capacity)) {
                return fail(TC_INPUT, "nodes[%d] service capacity is not finite", i);
            }
        }
    }

    routing_node = bnet_json_member(d, root, "routing");
    if (bnet_json_type_of(d, routing_node) != BNET_JSON_ARRAY
        || bnet_json_count(d, routing_node) != dimension) {
        return fail(TC_INPUT, "routing must be a %ldx%ld matrix", dimension, dimension);
    }
    for (i = 0; i < dimension; i++) {
        int row = bnet_json_at(d, routing_node, i);
        if (bnet_json_type_of(d, row) != BNET_JSON_ARRAY || bnet_json_count(d, row) != dimension) {
            return fail(TC_INPUT, "routing must be a %ldx%ld matrix", dimension, dimension);
        }
    }
    model->routing = (double *)calloc((size_t)dimension * (size_t)dimension, sizeof(double));
    model->exit_probabilities = (double *)calloc((size_t)dimension, sizeof(double));
    if (!model->routing || !model->exit_probabilities) return fail(TC_INPUT, "out of memory");
    for (i = 0; i < dimension; i++) {
        int row = bnet_json_at(d, routing_node, i);
        bnet_fsum row_total;
        double row_sum;
        bnet_fsum_init(&row_total);
        for (j = 0; j < dimension; j++) {
            char path[64];
            snprintf(path, sizeof path, "routing[%d][%d]", i, j);
            if (!tc_nonnegative_float(d, bnet_json_at(d, row, j), path,
                                      &model->routing[(size_t)i * dimension + j])) return 0;
            bnet_fsum_add(&row_total, model->routing[(size_t)i * dimension + j]);
        }
        row_sum = bnet_fsum_value(&row_total);
        if (row_sum > 1.0) {
            return fail(TC_INPUT, "routing row %d sums to %.17g, which exceeds 1", i, row_sum);
        }
        model->exit_probabilities[i] = (1.0 - row_sum) > 0.0 ? (1.0 - row_sum) : 0.0;
    }

    solver_node = bnet_json_member(d, root, "solver");
    if (solver_node != BNET_JSON_NONE && bnet_json_type_of(d, solver_node) != BNET_JSON_OBJECT) {
        return fail(TC_INPUT, "solver must be an object");
    }
    if (!tc_option_int(d, solver_node, "initial_total_cap", 8, 1, &model->options.initial_total_cap)) return 0;
    if (!tc_option_int(d, solver_node, "max_total_cap", 64, 1, &model->options.max_total_cap)) return 0;
    if (model->options.initial_total_cap > model->options.max_total_cap) {
        return fail(TC_INPUT, "solver.initial_total_cap cannot exceed max_total_cap");
    }
    if (!tc_option_float(d, solver_node, "growth_factor", 1.6, 1, &model->options.growth_factor)) return 0;
    if (model->options.growth_factor <= 1.0) {
        return fail(TC_INPUT, "solver.growth_factor must be greater than 1");
    }

    tail_node = bnet_json_member(d, solver_node, "tail_levels");
    if (tail_node == BNET_JSON_NONE) {
        model->options.tail_levels = (long *)malloc(3 * sizeof(long));
        if (!model->options.tail_levels) return fail(TC_INPUT, "out of memory");
        model->options.tail_levels[0] = 1;
        model->options.tail_levels[1] = 5;
        model->options.tail_levels[2] = 10;
        model->options.tail_count = 3;
    } else {
        int count;
        if (bnet_json_type_of(d, tail_node) != BNET_JSON_ARRAY) {
            return fail(TC_INPUT, "solver.tail_levels must be an array");
        }
        count = bnet_json_count(d, tail_node);
        model->options.tail_levels = (long *)malloc((size_t)(count ? count : 1) * sizeof(long));
        if (!model->options.tail_levels) return fail(TC_INPUT, "out of memory");
        for (i = 0; i < count; i++) {
            char path[64];
            snprintf(path, sizeof path, "solver.tail_levels[%d]", i);
            if (!tc_integer(d, bnet_json_at(d, tail_node, i), path, 0,
                            &model->options.tail_levels[i])) return 0;
        }
        model->options.tail_count = count;
    }
    /* sorted(set(...)) */
    qsort(model->options.tail_levels, (size_t)model->options.tail_count, sizeof(long), tc_compare_long);
    {
        int unique = 0;
        for (i = 0; i < model->options.tail_count; i++) {
            if (i == 0 || model->options.tail_levels[i] != model->options.tail_levels[i - 1]) {
                model->options.tail_levels[unique++] = model->options.tail_levels[i];
            }
        }
        model->options.tail_count = unique;
    }

    {
        int include_node = bnet_json_member(d, solver_node, "include_state_probabilities");
        if (include_node != BNET_JSON_NONE
            && bnet_json_type_of(d, include_node) != BNET_JSON_BOOL) {
            return fail(TC_INPUT, "solver.include_state_probabilities must be a boolean");
        }
        model->options.include_state_probabilities = bnet_json_bool_or(d, include_node, 0);
    }
    {
        int theta_node = bnet_json_member(d, solver_node, "certificate_theta");
        if (theta_node != BNET_JSON_NONE && !bnet_json_is_null(d, theta_node)) {
            if (!tc_positive_float(d, theta_node, "solver.certificate_theta",
                                   &model->options.certificate_theta)) return 0;
            model->options.have_certificate_theta = 1;
        }
    }
    if (!tc_option_int(d, solver_node, "minimum_cap_increment", 2, 1,
                       &model->options.minimum_cap_increment)) return 0;
    if (!tc_option_int(d, solver_node, "max_states", 200000, 1, &model->options.max_states)) return 0;
    if (!tc_option_float(d, solver_node, "stationary_tolerance", 1.0e-13, 1,
                         &model->options.stationary_tolerance)) return 0;
    if (!tc_option_int(d, solver_node, "stationary_max_iterations", 200000, 1,
                       &model->options.stationary_max_iterations)) return 0;
    if (!tc_option_float(d, solver_node, "boundary_mass_tolerance", 1.0e-8, 0,
                         &model->options.boundary_mass_tolerance)) return 0;
    if (!tc_option_float(d, solver_node, "refinement_relative_tolerance", 1.0e-7, 0,
                         &model->options.refinement_relative_tolerance)) return 0;
    if (!tc_option_float(d, solver_node, "stability_tolerance", 1.0e-12, 1,
                         &model->options.stability_tolerance)) return 0;
    if (!tc_option_float(d, solver_node, "routing_tolerance", 1.0e-12, 1,
                         &model->options.routing_tolerance)) return 0;
    if (!tc_option_int(d, solver_node, "top_state_count", 20, 0, &model->options.top_state_count)) return 0;

    {
        int name_node = bnet_json_member(d, root, "name");
        if (name_node != BNET_JSON_NONE && !bnet_json_is_null(d, name_node)) {
            const char *name = bnet_json_string(d, name_node);
            if (!name) return fail(TC_INPUT, "name must be a string when present");
            if (strlen(name) >= sizeof model->name) return fail(TC_INPUT, "name is too long");
            strcpy(model->name, name);
            model->has_name = 1;
        }
    }
    if (!isfinite(tc_total_external_arrival_rate(model))) {
        return fail(TC_INPUT, "total external arrival rate is not finite");
    }
    return 1;
}

/* -------------------------------------------------- traffic and stability */

static int tc_solve_linear(double *matrix, const double *rhs, int size, double *result)
{
    double *aug = (double *)malloc((size_t)size * (size_t)(size + 1) * sizeof(double));
    double *scales = (double *)malloc((size_t)size * sizeof(double));
    int column, row, j, ok = 1;
    if (!aug || !scales) { free(aug); free(scales); return fail(TC_INPUT, "out of memory"); }
    for (row = 0; row < size; row++) {
        double biggest = 0.0;
        for (j = 0; j < size; j++) {
            double v = matrix[(size_t)row * size + j];
            aug[(size_t)row * (size + 1) + j] = v;
            if (fabs(v) > biggest) biggest = fabs(v);
        }
        aug[(size_t)row * (size + 1) + size] = rhs[row];
        scales[row] = biggest;
        if (biggest == 0.0) ok = 0;
    }
    if (!ok) {
        free(aug); free(scales);
        return fail(TC_INPUT, "routing matrix is singular; the network is not open");
    }
    for (column = 0; column < size; column++) {
        int pivot = column;
        double best = fabs(aug[(size_t)column * (size + 1) + column]) / scales[column];
        double floor_value, pivot_value;
        for (row = column + 1; row < size; row++) {
            double candidate = fabs(aug[(size_t)row * (size + 1) + column]) / scales[row];
            if (candidate > best) { best = candidate; pivot = row; }
        }
        floor_value = 8.0 * TC_DBL_EPSILON * (double)size * scales[pivot];
        if (fabs(aug[(size_t)pivot * (size + 1) + column]) <= floor_value) {
            free(aug); free(scales);
            return fail(TC_INPUT, "routing matrix is singular; the network is not open");
        }
        if (pivot != column) {
            for (j = 0; j <= size; j++) {
                double t = aug[(size_t)column * (size + 1) + j];
                aug[(size_t)column * (size + 1) + j] = aug[(size_t)pivot * (size + 1) + j];
                aug[(size_t)pivot * (size + 1) + j] = t;
            }
            { double t = scales[column]; scales[column] = scales[pivot]; scales[pivot] = t; }
        }
        pivot_value = aug[(size_t)column * (size + 1) + column];
        for (row = column + 1; row < size; row++) {
            double factor = aug[(size_t)row * (size + 1) + column] / pivot_value;
            aug[(size_t)row * (size + 1) + column] = 0.0;
            for (j = column + 1; j <= size; j++) {
                aug[(size_t)row * (size + 1) + j] -= factor * aug[(size_t)column * (size + 1) + j];
            }
        }
    }
    for (row = size - 1; row >= 0; row--) {
        bnet_fsum tail;
        bnet_fsum_init(&tail);
        for (j = row + 1; j < size; j++) {
            bnet_fsum_add(&tail, aug[(size_t)row * (size + 1) + j] * result[j]);
        }
        result[row] = (aug[(size_t)row * (size + 1) + size] - bnet_fsum_value(&tail))
                      / aug[(size_t)row * (size + 1) + row];
    }
    free(aug); free(scales);
    return 1;
}

typedef struct {
    double *throughput;
    double *capacities;
    double *utilizations;
    double  minimum_capacity_margin;
    double  traffic_equation_residual_scaled;
} tc_stability;

static int tc_traffic_and_stability(const tc_model *model, tc_stability *out)
{
    int dimension = model->dimension, i, j;
    double *system = (double *)malloc((size_t)dimension * (size_t)dimension * sizeof(double));
    double *external = (double *)malloc((size_t)dimension * sizeof(double));
    double scale = TC_DBL_MIN, negative_tolerance, residual = 0.0, minimum_margin;
    memset(out, 0, sizeof *out);
    out->throughput = (double *)calloc((size_t)dimension, sizeof(double));
    out->capacities = (double *)calloc((size_t)dimension, sizeof(double));
    out->utilizations = (double *)calloc((size_t)dimension, sizeof(double));
    if (!system || !external || !out->throughput || !out->capacities || !out->utilizations) {
        free(system); free(external);
        return fail(TC_INPUT, "out of memory");
    }
    for (i = 0; i < dimension; i++) {
        for (j = 0; j < dimension; j++) {
            system[(size_t)i * dimension + j] = (i == j ? 1.0 : 0.0)
                                              - model->routing[(size_t)j * dimension + i];
        }
        external[i] = model->nodes[i].external_arrival_rate;
    }
    if (!tc_solve_linear(system, external, dimension, out->throughput)) {
        free(system); free(external);
        /* The Python re-raises with its own sentence. */
        g_error_kind = TC_OK;
        return fail(TC_INPUT, "I - routing is singular or rank deficient; routing is not open");
    }
    free(system);
    for (i = 0; i < dimension; i++) {
        if (out->throughput[i] > scale) scale = out->throughput[i];
        if (external[i] > scale) scale = external[i];
    }
    negative_tolerance = model->options.routing_tolerance * scale;
    for (i = 0; i < dimension; i++) {
        if (out->throughput[i] < -negative_tolerance) {
            free(external);
            return fail(TC_INPUT, "traffic equations produced a negative throughput");
        }
    }
    for (i = 0; i < dimension; i++) if (out->throughput[i] < 0.0) out->throughput[i] = 0.0;
    for (i = 0; i < dimension; i++) {
        bnet_fsum feed;
        double balance;
        bnet_fsum_init(&feed);
        for (j = 0; j < dimension; j++) {
            bnet_fsum_add(&feed, out->throughput[j] * model->routing[(size_t)j * dimension + i]);
        }
        balance = fabs(out->throughput[i] - external[i] - bnet_fsum_value(&feed));
        if (balance > residual) residual = balance;
    }
    free(external);
    residual /= scale;
    out->traffic_equation_residual_scaled = residual;
    if (residual > model->options.routing_tolerance) {
        return fail(TC_INPUT, "traffic-equation residual exceeds solver.routing_tolerance");
    }
    for (i = 0; i < dimension; i++) {
        out->capacities[i] = model->nodes[i].servers * model->nodes[i].service_rate_per_server;
        out->utilizations[i] = out->throughput[i] / out->capacities[i];
    }
    minimum_margin = 1.0 - out->utilizations[0];
    for (i = 1; i < dimension; i++) {
        double margin = 1.0 - out->utilizations[i];
        if (margin < minimum_margin) minimum_margin = margin;
    }
    out->minimum_capacity_margin = minimum_margin;
    if (!(minimum_margin > model->options.stability_tolerance)) {
        return fail(TC_STABILITY,
                    "the open network does not satisfy strict nodewise traffic stability");
    }
    return 1;
}

/* ------------------------------------------------------ the sparse operator */

typedef struct {
    long    total_cap;
    long    count;
    int    *states;              /* [count * dimension] */
    long   *row_start;           /* [count + 1] into targets/rates */
    long   *targets;
    double *rates;
    double *exit_rates;
    double  uniformization_rate;
    long   *boundary_indices;
    long    boundary_count;
} tc_operator;

static void tc_operator_free(tc_operator *op)
{
    free(op->states); free(op->row_start); free(op->targets); free(op->rates);
    free(op->exit_rates); free(op->boundary_indices);
    memset(op, 0, sizeof *op);
}

/*
 * Builds the uniformized generator for one truncation cap.
 *
 * The Python collects each row into a dict keyed by target index and then
 * sorts it; that sort is observable, because `exit_rates` is an fsum over the
 * row in sorted order and `apply` walks the row in that order accumulating with
 * plain `+=`. So the rows here are built into a small scratch buffer, summed by
 * target, and sorted by target index before being stored.
 */
static int tc_build_operator(const tc_model *model, long total_cap, tc_operator *op)
{
    int dimension = model->dimension, i, j, overflow = 0;
    long count, source, capacity_estimate, used = 0;
    long *scratch_target = NULL;
    double *scratch_rate = NULL;
    int *target_state = NULL;
    bnet_fsum service_bound;
    double gamma, maximum_exit = 0.0;

    memset(op, 0, sizeof *op);
    count = tc_state_count(dimension, total_cap, &overflow);
    if (overflow || count > model->options.max_states) {
        return fail(TC_STATE_LIMIT, "the requested initial truncation exceeds solver.max_states");
    }
    op->total_cap = total_cap;
    op->count = count;
    op->states = (int *)malloc((size_t)count * (size_t)dimension * sizeof(int));
    op->row_start = (long *)malloc((size_t)(count + 1) * sizeof(long));
    op->exit_rates = (double *)malloc((size_t)count * sizeof(double));
    op->boundary_indices = (long *)malloc((size_t)count * sizeof(long));
    scratch_target = (long *)malloc((size_t)(dimension * dimension + 2 * dimension + 1) * sizeof(long));
    scratch_rate = (double *)malloc((size_t)(dimension * dimension + 2 * dimension + 1) * sizeof(double));
    target_state = (int *)malloc((size_t)dimension * sizeof(int));
    if (!op->states || !op->row_start || !op->exit_rates || !op->boundary_indices
        || !scratch_target || !scratch_rate || !target_state) {
        free(scratch_target); free(scratch_rate); free(target_state);
        return fail(TC_STATE_LIMIT, "out of memory building the operator");
    }
    /* Each state has at most one arrival per node plus, per node, one departure
     * and one internal move per destination. */
    capacity_estimate = count * (long)(dimension + dimension + dimension * dimension);
    /* A RAM pre-flight before the one allocation here that scales with the
     * user's input. It exits rather than returning, which is the house
     * convention for this guard: past this point the alternative is the OS
     * thrashing. `solver.max_states` normally binds first, so this fires only
     * when that limit has been raised deliberately. */
    bnet_memcheck_alloc((uint64_t)capacity_estimate * (sizeof(long) + sizeof(double)),
                        "truncated CTMC transition table",
                        "reduce solver.max_total_cap or solver.max_states");
    op->targets = (long *)malloc((size_t)capacity_estimate * sizeof(long));
    op->rates = (double *)malloc((size_t)capacity_estimate * sizeof(double));
    if (!op->targets || !op->rates) {
        free(scratch_target); free(scratch_rate); free(target_state);
        return fail(TC_STATE_LIMIT, "out of memory building the transition table");
    }

    if (!tc_enumerate_states(dimension, total_cap, count, op->states)) goto failed;
    if (!tc_rank_matches_enumeration(op->states, dimension, total_cap, count)) goto failed;

    for (source = 0; source < count; source++) {
        const int *state = op->states + (size_t)source * dimension;
        long total = 0, entries = 0, k, m;
        op->row_start[source] = used;
        for (i = 0; i < dimension; i++) total += state[i];
        if (total == total_cap) op->boundary_indices[op->boundary_count++] = source;

        /* One `add`: accumulate by target, drop self-loops and nonpositive rates. */
#define TC_ADD(rate_value)                                                                  \
        do {                                                                                \
            double rate_ = (rate_value);                                                    \
            if (rate_ > 0.0) {                                                              \
                long target_ = tc_state_rank(target_state, dimension, total_cap);           \
                if (target_ < 0) { fail(TC_STATE_LIMIT, "state rank overflow"); goto failed; } \
                if (target_ != source) {                                                    \
                    long slot_;                                                             \
                    for (slot_ = 0; slot_ < entries; slot_++) {                             \
                        if (scratch_target[slot_] == target_) break;                        \
                    }                                                                       \
                    if (slot_ == entries) {                                                 \
                        scratch_target[entries] = target_;                                  \
                        scratch_rate[entries] = rate_;                                      \
                        entries++;                                                          \
                    } else {                                                                \
                        scratch_rate[slot_] += rate_;                                       \
                    }                                                                       \
                }                                                                           \
            }                                                                               \
        } while (0)

        if (total < total_cap) {
            for (i = 0; i < dimension; i++) {
                if (model->nodes[i].external_arrival_rate > 0.0) {
                    memcpy(target_state, state, (size_t)dimension * sizeof(int));
                    target_state[i] += 1;
                    TC_ADD(model->nodes[i].external_arrival_rate);
                }
            }
        }
        for (i = 0; i < dimension; i++) {
            double service_rate, departure_rate;
            if (state[i] == 0) continue;
            service_rate = model->nodes[i].service_rate_per_server
                         * (state[i] < model->nodes[i].servers ? state[i] : model->nodes[i].servers);
            departure_rate = service_rate * model->exit_probabilities[i];
            if (departure_rate > 0.0) {
                memcpy(target_state, state, (size_t)dimension * sizeof(int));
                target_state[i] -= 1;
                TC_ADD(departure_rate);
            }
            for (j = 0; j < dimension; j++) {
                double probability = model->routing[(size_t)i * dimension + j];
                if (probability == 0.0) continue;
                memcpy(target_state, state, (size_t)dimension * sizeof(int));
                target_state[i] -= 1;
                target_state[j] += 1;
                TC_ADD(service_rate * probability);
            }
        }
#undef TC_ADD

        /* `sorted(targets.items())` — insertion sort, the rows are tiny. */
        for (k = 1; k < entries; k++) {
            long key_target = scratch_target[k];
            double key_rate = scratch_rate[k];
            for (m = k - 1; m >= 0 && scratch_target[m] > key_target; m--) {
                scratch_target[m + 1] = scratch_target[m];
                scratch_rate[m + 1] = scratch_rate[m];
            }
            scratch_target[m + 1] = key_target;
            scratch_rate[m + 1] = key_rate;
        }
        if (used + entries > capacity_estimate) {
            fail(TC_STATE_LIMIT, "internal: transition table estimate was too small");
            goto failed;
        }
        {
            bnet_fsum row_total;
            bnet_fsum_init(&row_total);
            for (k = 0; k < entries; k++) {
                op->targets[used + k] = scratch_target[k];
                op->rates[used + k] = scratch_rate[k];
                bnet_fsum_add(&row_total, scratch_rate[k]);
            }
            op->exit_rates[source] = bnet_fsum_value(&row_total);
            if (op->exit_rates[source] > maximum_exit) maximum_exit = op->exit_rates[source];
        }
        used += entries;
    }
    op->row_start[count] = used;

    bnet_fsum_init(&service_bound);
    for (i = 0; i < dimension; i++) {
        bnet_fsum_add(&service_bound,
                      model->nodes[i].servers * model->nodes[i].service_rate_per_server);
    }
    gamma = tc_total_external_arrival_rate(model) + bnet_fsum_value(&service_bound);
    if (!isfinite(gamma) || gamma <= 0.0) {
        fail(TC_INPUT, "the network does not have a positive finite event-rate bound");
        goto failed;
    }
    if (maximum_exit > gamma * (1.0 + 1.0e-12)) {
        fail(TC_INPUT, "computed exit rate exceeds the uniformization rate");
        goto failed;
    }
    op->uniformization_rate = gamma;
    free(scratch_target); free(scratch_rate); free(target_state);
    return 1;

failed:
    free(scratch_target); free(scratch_rate); free(target_state);
    tc_operator_free(op);
    return 0;
}

/* ------------------------------------------------------- power iteration */

/* One application of the uniformized operator.
 *
 * Plain `+=` into `result[target]`, source-major, skipping zero sources —
 * exactly what `SparseUniformizedOperator.apply` does. Using exact summation
 * here would be more accurate AND would disagree with the reference engine,
 * which is the wrong trade: this is the iterate, not a reported quantity, and
 * the residual it converges to is reported either way. */
static int tc_apply(const tc_operator *op, const double *distribution, double *result)
{
    long source, k;
    double gamma = op->uniformization_rate;
    memset(result, 0, (size_t)op->count * sizeof(double));
    for (source = 0; source < op->count; source++) {
        double probability = distribution[source], self_weight;
        if (probability == 0.0) continue;
        self_weight = 1.0 - op->exit_rates[source] / gamma;
        if (self_weight < -1.0e-13) {
            return fail(TC_CONVERGENCE, "uniformization produced a negative self-transition");
        }
        result[source] += probability * (self_weight > 0.0 ? self_weight : 0.0);
        for (k = op->row_start[source]; k < op->row_start[source + 1]; k++) {
            result[op->targets[k]] += probability * op->rates[k] / gamma;
        }
    }
    return 1;
}

typedef struct {
    long   iterations;
    double last_change_l1;
    double uniformized_residual_l1;
    double generator_residual_l1;
} tc_stationary_diagnostics;

static double tc_fsum_of(const double *values, long count)
{
    bnet_fsum total;
    long i;
    bnet_fsum_init(&total);
    for (i = 0; i < count; i++) bnet_fsum_add(&total, values[i]);
    return bnet_fsum_value(&total);
}

static int tc_stationary_distribution(const tc_operator *op, const tc_model *model,
                                      const tc_operator *previous_op,
                                      const double *previous_distribution,
                                      double *distribution,
                                      tc_stationary_diagnostics *diagnostics)
{
    long i, iteration;
    double *candidate = (double *)malloc((size_t)op->count * sizeof(double));
    double *probe = (double *)malloc((size_t)op->count * sizeof(double));
    double delta = HUGE_VAL, residual = HUGE_VAL;
    int warm = 0;
    if (!candidate || !probe) { free(candidate); free(probe); return fail(TC_INPUT, "out of memory"); }

    /* Warm start: the previous cap's distribution, looked up by state. States
     * absent from the smaller enumeration are zero, as `warm_start.get(...)`
     * gives. The lookup is by rank in the PREVIOUS cap, which is why the rank
     * function takes the cap as a parameter. */
    if (previous_op && previous_distribution) {
        double total;
        for (i = 0; i < op->count; i++) {
            const int *state = op->states + (size_t)i * model->dimension;
            long total_jobs = 0, j, rank;
            for (j = 0; j < model->dimension; j++) total_jobs += state[j];
            if (total_jobs > previous_op->total_cap) { distribution[i] = 0.0; continue; }
            rank = tc_state_rank(state, model->dimension, previous_op->total_cap);
            distribution[i] = (rank >= 0 && rank < previous_op->count)
                            ? previous_distribution[rank] : 0.0;
        }
        total = tc_fsum_of(distribution, op->count);
        if (total > 0.0) {
            for (i = 0; i < op->count; i++) distribution[i] /= total;
            warm = 1;
        }
    }
    if (!warm) {
        memset(distribution, 0, (size_t)op->count * sizeof(double));
        distribution[0] = 1.0;      /* the empty state is lexicographically first */
    }

    for (iteration = 1; iteration <= model->options.stationary_max_iterations; iteration++) {
        double total, candidate_total;
        bnet_fsum change;
        if (!tc_apply(op, distribution, candidate)) { free(candidate); free(probe); return 0; }
        total = tc_fsum_of(candidate, op->count);
        if (!isfinite(total) || total <= 0.0) {
            free(candidate); free(probe);
            return fail(TC_CONVERGENCE, "stationary iteration produced a nonnormalizable vector");
        }
        for (i = 0; i < op->count; i++) {
            double value = candidate[i] / total;
            candidate[i] = value > 0.0 ? value : 0.0;
        }
        candidate_total = tc_fsum_of(candidate, op->count);
        for (i = 0; i < op->count; i++) candidate[i] /= candidate_total;
        bnet_fsum_init(&change);
        for (i = 0; i < op->count; i++) bnet_fsum_add(&change, fabs(candidate[i] - distribution[i]));
        delta = bnet_fsum_value(&change);
        memcpy(distribution, candidate, (size_t)op->count * sizeof(double));
        if (delta <= model->options.stationary_tolerance) {
            bnet_fsum probe_change;
            if (!tc_apply(op, distribution, probe)) { free(candidate); free(probe); return 0; }
            bnet_fsum_init(&probe_change);
            for (i = 0; i < op->count; i++) bnet_fsum_add(&probe_change, fabs(probe[i] - distribution[i]));
            residual = bnet_fsum_value(&probe_change);
            if (residual <= model->options.stationary_tolerance) break;
        }
        if (delta == 0.0) {
            free(candidate); free(probe);
            return fail(TC_CONVERGENCE,
                        "stationary iteration stagnated above the requested residual tolerance");
        }
    }
    if (iteration > model->options.stationary_max_iterations) {
        free(candidate); free(probe);
        return fail(TC_CONVERGENCE, "stationary iteration reached stationary_max_iterations");
    }
    diagnostics->iterations = iteration;
    diagnostics->last_change_l1 = delta;
    diagnostics->uniformized_residual_l1 = residual;
    diagnostics->generator_residual_l1 = op->uniformization_rate * residual;
    free(candidate); free(probe);
    return 1;
}

/* ------------------------------------------------------------- summaries */

typedef struct {
    long    total_cap;
    long    state_count;
    double  empty_probability;
    double *mean_queue_length_by_node;
    double  mean_total_jobs;
    double  second_moment_total_jobs;
    double *mean_busy_servers_by_node;
    double *service_completion_rate_by_node;
    double *external_departure_rate_by_node;
    double *tail_estimates;
    double  probability_at_total_cap;
} tc_summary;

static void tc_summary_free(tc_summary *s)
{
    free(s->mean_queue_length_by_node); free(s->mean_busy_servers_by_node);
    free(s->service_completion_rate_by_node); free(s->external_departure_rate_by_node);
    free(s->tail_estimates);
    memset(s, 0, sizeof *s);
}

static int tc_summarize(const tc_model *model, const tc_operator *op,
                        const double *distribution, tc_summary *out)
{
    int dimension = model->dimension, i, t;
    long index;
    memset(out, 0, sizeof *out);
    out->total_cap = op->total_cap;
    out->state_count = op->count;
    out->mean_queue_length_by_node = (double *)calloc((size_t)dimension, sizeof(double));
    out->mean_busy_servers_by_node = (double *)calloc((size_t)dimension, sizeof(double));
    out->service_completion_rate_by_node = (double *)calloc((size_t)dimension, sizeof(double));
    out->external_departure_rate_by_node = (double *)calloc((size_t)dimension, sizeof(double));
    out->tail_estimates = (double *)calloc((size_t)(model->options.tail_count ?
                                                    model->options.tail_count : 1), sizeof(double));
    if (!out->mean_queue_length_by_node || !out->mean_busy_servers_by_node
        || !out->service_completion_rate_by_node || !out->external_departure_rate_by_node
        || !out->tail_estimates) {
        return fail(TC_INPUT, "out of memory");
    }
    out->empty_probability = distribution[0];

    for (i = 0; i < dimension; i++) {
        bnet_fsum mean, busy;
        bnet_fsum_init(&mean);
        bnet_fsum_init(&busy);
        for (index = 0; index < op->count; index++) {
            int occupancy = op->states[(size_t)index * dimension + i];
            bnet_fsum_add(&mean, distribution[index] * occupancy);
            bnet_fsum_add(&busy, distribution[index]
                          * (occupancy < model->nodes[i].servers ? occupancy : model->nodes[i].servers));
        }
        out->mean_queue_length_by_node[i] = bnet_fsum_value(&mean);
        out->mean_busy_servers_by_node[i] = bnet_fsum_value(&busy);
        out->service_completion_rate_by_node[i] = out->mean_busy_servers_by_node[i]
                                                * model->nodes[i].service_rate_per_server;
        out->external_departure_rate_by_node[i] = out->service_completion_rate_by_node[i]
                                                * model->exit_probabilities[i];
    }
    out->mean_total_jobs = tc_fsum_of(out->mean_queue_length_by_node, dimension);
    {
        bnet_fsum second, boundary;
        bnet_fsum_init(&second);
        bnet_fsum_init(&boundary);
        for (index = 0; index < op->count; index++) {
            long total = 0;
            for (i = 0; i < dimension; i++) total += op->states[(size_t)index * dimension + i];
            /* `sum(state) ** 2` on Python ints, then multiplied — the product
             * is the only floating-point operation. */
            bnet_fsum_add(&second, distribution[index] * (double)(total * total));
        }
        out->second_moment_total_jobs = bnet_fsum_value(&second);
        for (index = 0; index < op->boundary_count; index++) {
            bnet_fsum_add(&boundary, distribution[op->boundary_indices[index]]);
        }
        out->probability_at_total_cap = bnet_fsum_value(&boundary);
    }
    for (t = 0; t < model->options.tail_count; t++) {
        bnet_fsum tail;
        bnet_fsum_init(&tail);
        for (index = 0; index < op->count; index++) {
            long total = 0;
            for (i = 0; i < dimension; i++) total += op->states[(size_t)index * dimension + i];
            if (total >= model->options.tail_levels[t]) bnet_fsum_add(&tail, distribution[index]);
        }
        out->tail_estimates[t] = bnet_fsum_value(&tail);
    }
    {
        double raw_variance = out->second_moment_total_jobs
                            - out->mean_total_jobs * out->mean_total_jobs;
        double scale = 1.0;
        if (fabs(out->second_moment_total_jobs) > scale) scale = fabs(out->second_moment_total_jobs);
        if (out->mean_total_jobs * out->mean_total_jobs > scale) {
            scale = out->mean_total_jobs * out->mean_total_jobs;
        }
        if (raw_variance < -100.0 * TC_DBL_EPSILON * scale) {
            return fail(TC_CONVERGENCE,
                        "truncated stationary moments produce a materially negative variance");
        }
    }
    return 1;
}

/* `compare_summaries`: the largest scaled change across the observable vector. */
static double tc_compare_summaries(const tc_model *model,
                                   const tc_summary *previous, const tc_summary *current)
{
    int dimension = model->dimension, i;
    double worst = 0.0;
    /* The vector is (empty, mean total, second moment, per-node means, tails)
     * in that order; only the maximum matters, so it is folded inline. */
#define TC_OBSERVE(a, b)                                                        \
    do {                                                                        \
        double old_ = (a), new_ = (b);                                          \
        double scale_ = 1.0;                                                    \
        double difference_ = fabs(old_ - new_);                                 \
        if (fabs(old_) > scale_) scale_ = fabs(old_);                           \
        if (fabs(new_) > scale_) scale_ = fabs(new_);                           \
        if (difference_ / scale_ > worst) worst = difference_ / scale_;         \
    } while (0)
    TC_OBSERVE(previous->empty_probability, current->empty_probability);
    TC_OBSERVE(previous->mean_total_jobs, current->mean_total_jobs);
    TC_OBSERVE(previous->second_moment_total_jobs, current->second_moment_total_jobs);
    for (i = 0; i < dimension; i++) {
        TC_OBSERVE(previous->mean_queue_length_by_node[i], current->mean_queue_length_by_node[i]);
    }
    for (i = 0; i < model->options.tail_count; i++) {
        TC_OBSERVE(previous->tail_estimates[i], current->tail_estimates[i]);
    }
#undef TC_OBSERVE
    return worst;
}

/* -------------------------------------------- Foster-Lyapunov certificate */

typedef struct {
    int    certified;
    double mean_total_jobs_upper;
    double probability_outside_selected_cap_upper;
} tc_certificate;

/* `_conservative_exp_from_log`: exponentiate an upper bound without rounding
 * it down to zero, and never below the true value. */
static double tc_conservative_exp_from_log(double log_value, int cap_at_one)
{
    double value;
    if (cap_at_one && log_value >= 0.0) return 1.0;
    if (log_value >= log(TC_DBL_MAX)) return HUGE_VAL;
    value = (log_value <= log(TC_DBL_MIN)) ? TC_DBL_MIN : exp(log_value);
    value = nextafter(value, HUGE_VAL);
    if (cap_at_one) return value < 1.0 ? value : 1.0;
    return value;
}

static void tc_foster_lyapunov(const tc_model *model, long total_cap, tc_certificate *out)
{
    int dimension = model->dimension, i;
    double arrival = tc_total_external_arrival_rate(model);
    double minimum_departure, drift_margin, arithmetic_guard, maximum_theta, theta;
    double exponential_increment, q, theta_drift_margin, theta_arithmetic_guard;
    double small_set_drift, negative_drift, positive_exponential_moment;
    double log_positive_moment, outside_log_bound, first_outside, second_outside;
    double mean_upper, second_moment_upper, stationary_exponential_moment;
    double first_factor, second_factor;
    long outside_level;

    memset(out, 0, sizeof *out);
    if (arrival == 0.0) {
        out->certified = 1;
        out->mean_total_jobs_upper = 0.0;
        out->probability_outside_selected_cap_upper = 0.0;
        return;
    }
    minimum_departure = model->nodes[0].service_rate_per_server * model->exit_probabilities[0];
    for (i = 1; i < dimension; i++) {
        double hazard = model->nodes[i].service_rate_per_server * model->exit_probabilities[i];
        if (hazard < minimum_departure) minimum_departure = hazard;
    }
    drift_margin = minimum_departure - arrival;
    arithmetic_guard = 128.0 * TC_DBL_EPSILON
                     * (minimum_departure > arrival ? minimum_departure : arrival);
    if (!(drift_margin > arithmetic_guard)) return;              /* uncertified */
    maximum_theta = log(minimum_departure) - log(arrival);

    theta = model->options.have_certificate_theta
          ? model->options.certificate_theta
          : (0.5 * maximum_theta < 1.0 ? 0.5 * maximum_theta : 1.0);
    if (theta >= maximum_theta) return;

    exponential_increment = expm1(theta);
    q = exp(-theta);
    theta_drift_margin = minimum_departure * q - arrival;
    theta_arithmetic_guard = 128.0 * TC_DBL_EPSILON
                           * (minimum_departure * q > arrival ? minimum_departure * q : arrival);
    small_set_drift = arrival * exponential_increment;
    negative_drift = exponential_increment * theta_drift_margin;
    if (!isfinite(small_set_drift) || !isfinite(negative_drift)
        || theta_drift_margin <= theta_arithmetic_guard) return;

    positive_exponential_moment = nextafter(arrival / theta_drift_margin, HUGE_VAL);
    if (!isfinite(positive_exponential_moment)) return;
    log_positive_moment = log(positive_exponential_moment);
    outside_level = total_cap + 1;
    outside_log_bound = log_positive_moment - theta * (double)outside_level;
    first_factor = (double)total_cap + 1.0 / (1.0 - q);
    second_factor = (double)total_cap * (double)total_cap
                  + ((2.0 * (double)outside_level - 1.0) / (1.0 - q)
                     + 2.0 * q / ((1.0 - q) * (1.0 - q)));
    first_outside = tc_conservative_exp_from_log(outside_log_bound + log(first_factor), 0);
    second_outside = tc_conservative_exp_from_log(outside_log_bound + log(second_factor), 0);
    mean_upper = tc_conservative_exp_from_log(log_positive_moment + log(q) - log1p(-q), 0);
    second_moment_upper = tc_conservative_exp_from_log(
        log_positive_moment + log(q) + log1p(q) - 2.0 * log1p(-q), 0);
    stationary_exponential_moment = nextafter(1.0 + positive_exponential_moment, HUGE_VAL);
    if (!isfinite(first_outside) || !isfinite(second_outside) || !isfinite(mean_upper)
        || !isfinite(second_moment_upper) || !isfinite(stationary_exponential_moment)) return;

    out->certified = 1;
    out->mean_total_jobs_upper = mean_upper;
    out->probability_outside_selected_cap_upper =
        tc_conservative_exp_from_log(outside_log_bound, 1);
}

/* ---------------------------------------------------------- adaptive loop */

/*
 * The refinement loop's result. Deliberately holds NO operator and no
 * distribution: everything the report needs is already in the summary, and an
 * earlier draft that kept the operator here aliased it with the loop's
 * warm-start copy, so advancing the cap freed a structure that was still in
 * use. One owner per generation is the whole discipline below.
 */
typedef struct {
    tc_summary                summary;
    tc_stationary_diagnostics diagnostics;
    int                       heuristic_converged;
    int                       have_comparison;
    double                    maximum_observable_scaled_change;
    tc_certificate            certificate;
} tc_result;

static void tc_result_free(tc_result *result)
{
    tc_summary_free(&result->summary);
}

static long tc_next_cap(long current, const tc_options *options)
{
    double grown_float = ceil((double)current * options->growth_factor);
    long grown = current + options->minimum_cap_increment;
    long ceiling = (long)grown_float;
    if (ceiling > grown) grown = ceiling;
    return grown < options->max_total_cap ? grown : options->max_total_cap;
}

/*
 * Grow the truncation cap until both heuristics agree, or until a limit stops
 * it. Exactly two generations are alive: the one just solved, and the previous
 * one kept as the warm start and the comparison base. Whichever generation is
 * current when the loop ends is copied into `result` and everything else is
 * released — see the note on tc_result above for why that is worth stating.
 */
static int tc_solve(const tc_model *model, tc_result *result)
{
    long cap = model->options.initial_total_cap;
    tc_operator previous_op;
    tc_summary previous_summary;
    double *previous_distribution = NULL;
    int have_previous = 0, ok = 0;

    memset(result, 0, sizeof *result);
    memset(&previous_op, 0, sizeof previous_op);
    memset(&previous_summary, 0, sizeof previous_summary);

    for (;;) {
        tc_operator op;
        tc_summary summary;
        tc_stationary_diagnostics diagnostics;
        double *distribution = NULL;
        double scaled_change = 0.0;
        int boundary_ok, refinement_ok, stop = 0, converged = 0;
        long proposed, required;
        int overflow = 0;

        if (!tc_build_operator(model, cap, &op)) break;
        distribution = (double *)malloc((size_t)op.count * sizeof(double));
        if (!distribution) { tc_operator_free(&op); fail(TC_INPUT, "out of memory"); break; }
        if (!tc_stationary_distribution(&op, model,
                                        have_previous ? &previous_op : NULL,
                                        have_previous ? previous_distribution : NULL,
                                        distribution, &diagnostics)
            || !tc_summarize(model, &op, distribution, &summary)) {
            tc_operator_free(&op);
            free(distribution);
            break;
        }
        if (have_previous) scaled_change = tc_compare_summaries(model, &previous_summary, &summary);
        boundary_ok = summary.probability_at_total_cap <= model->options.boundary_mass_tolerance;
        refinement_ok = have_previous
                      && scaled_change <= model->options.refinement_relative_tolerance;

        if (boundary_ok && refinement_ok) { stop = 1; converged = 1; }
        else if (cap >= model->options.max_total_cap) { stop = 1; }
        else {
            proposed = tc_next_cap(cap, &model->options);
            required = tc_state_count(model->dimension, proposed, &overflow);
            if (overflow || required > model->options.max_states) stop = 1;
        }

        if (stop) {
            result->summary = summary;                  /* result takes ownership */
            result->diagnostics = diagnostics;
            result->heuristic_converged = converged;
            result->have_comparison = have_previous;
            result->maximum_observable_scaled_change = scaled_change;
            tc_operator_free(&op);
            free(distribution);
            if (have_previous) {
                tc_operator_free(&previous_op);
                free(previous_distribution);
                tc_summary_free(&previous_summary);
                have_previous = 0;
            }
            ok = 1;
            break;
        }

        /* This generation becomes the previous one; the old previous goes. */
        if (have_previous) {
            tc_operator_free(&previous_op);
            free(previous_distribution);
            tc_summary_free(&previous_summary);
        }
        previous_op = op;
        previous_distribution = distribution;
        previous_summary = summary;
        have_previous = 1;
        cap = proposed;
    }

    if (have_previous) {
        tc_operator_free(&previous_op);
        free(previous_distribution);
        tc_summary_free(&previous_summary);
    }
    if (!ok) return 0;
    tc_foster_lyapunov(model, result->summary.total_cap, &result->certificate);
    return 1;
}

/* ---------------------------------------------------------------- output */

/* `{value:.12g}` in the Python's human rows. */
static const char *tc_g12(char *buffer, size_t size, double value)
{
    snprintf(buffer, size, "%.12g", value);
    return buffer;
}

static void tc_print_human(const tc_model *model, const tc_stability *stability,
                           const tc_result *result)
{
    char a[64], b[64], c[64];
    int i;
    printf("Adaptive truncated CTMC\n");
    printf("Model layer: queueing process\n");
    printf("Evidence: truncation diagnostics are heuristic; certificates are "
           "identified separately\n");
    printf("Heuristic converged: %s\n", result->heuristic_converged ? "yes" : "no");
    printf("Selected total cap: %ld\n", result->summary.total_cap);
    printf("Selected states: %ld\n", result->summary.state_count);
    printf("\n");
    for (i = 0; i < model->dimension; i++) {
        printf("Node %d %s: E[N]=%s utilization=%s departure=%s\n",
               i + 1, model->nodes[i].name,
               tc_g12(a, sizeof a, result->summary.mean_queue_length_by_node[i]),
               tc_g12(b, sizeof b, stability->utilizations[i]),
               tc_g12(c, sizeof c, result->summary.external_departure_rate_by_node[i]));
    }
    printf("\n");
    printf("generator residual = %s\n",
           tc_g12(a, sizeof a, result->diagnostics.generator_residual_l1));
    printf("truncation boundary mass = %s\n",
           tc_g12(a, sizeof a, result->summary.probability_at_total_cap));
    if (result->have_comparison) {
        printf("successive refinement relative change = %s\n",
               tc_g12(a, sizeof a, result->maximum_observable_scaled_change));
    }
    if (result->certificate.certified) {
        printf("Foster-Lyapunov certificate: certified\n");
        printf("certified E[N] upper bound = %s\n",
               tc_g12(a, sizeof a, result->certificate.mean_total_jobs_upper));
        printf("certified probability outside selected cap upper bound = %s\n",
               tc_g12(a, sizeof a, result->certificate.probability_outside_selected_cap_upper));
    } else {
        printf("Foster-Lyapunov certificate: unavailable for this model\n");
    }
}

static const char *tc_repr(char *buffer, size_t size, double value)
{
    int precision;
    if (!isfinite(value)) { snprintf(buffer, size, "null"); return buffer; }
    for (precision = 1; precision <= 17; precision++) {
        snprintf(buffer, size, "%.*g", precision, value);
        if (strtod(buffer, NULL) == value) break;
    }
    return buffer;
}

/* The JSON carries the same values as the Python's but is not byte-comparable
 * with it (json.dump sorts keys and writes repr floats); the parity test
 * compares it by value. */
static void tc_write_json(FILE *out, const tc_model *model, const tc_stability *stability,
                          const tc_result *result)
{
    char buffer[64];
    int i;
    fprintf(out, "{\n  \"process\": \"open_single_class_markovian_network\",\n");
    fprintf(out, "  \"status\": \"ok\",\n  \"engine\": \"c\",\n");
    fprintf(out, "  \"network\": {\"node_count\": %d, \"node_names\": [", model->dimension);
    for (i = 0; i < model->dimension; i++) {
        fprintf(out, "%s\"%s\"", i ? ", " : "", model->nodes[i].name);
    }
    fprintf(out, "]},\n  \"stability\": {\"utilization_by_node\": [");
    for (i = 0; i < model->dimension; i++) {
        fprintf(out, "%s%s", i ? ", " : "", tc_repr(buffer, sizeof buffer, stability->utilizations[i]));
    }
    fprintf(out, "], \"throughput_by_node\": [");
    for (i = 0; i < model->dimension; i++) {
        fprintf(out, "%s%s", i ? ", " : "", tc_repr(buffer, sizeof buffer, stability->throughput[i]));
    }
    fprintf(out, "], \"minimum_capacity_margin\": %s},\n",
            tc_repr(buffer, sizeof buffer, stability->minimum_capacity_margin));
    fprintf(out, "  \"approximation\": {\"heuristic_converged\": %s, \"selected_total_cap\": %ld, "
                 "\"selected_state_count\": %ld,\n    \"performance\": {",
            result->heuristic_converged ? "true" : "false",
            result->summary.total_cap, result->summary.state_count);
    fprintf(out, "\"empty_probability\": %s",
            tc_repr(buffer, sizeof buffer, result->summary.empty_probability));
    fprintf(out, ", \"mean_total_jobs\": %s",
            tc_repr(buffer, sizeof buffer, result->summary.mean_total_jobs));
    fprintf(out, ", \"second_moment_total_jobs\": %s",
            tc_repr(buffer, sizeof buffer, result->summary.second_moment_total_jobs));
    fprintf(out, ", \"mean_queue_length_by_node\": [");
    for (i = 0; i < model->dimension; i++) {
        fprintf(out, "%s%s", i ? ", " : "",
                tc_repr(buffer, sizeof buffer, result->summary.mean_queue_length_by_node[i]));
    }
    fprintf(out, "], \"external_departure_rate_by_node\": [");
    for (i = 0; i < model->dimension; i++) {
        fprintf(out, "%s%s", i ? ", " : "",
                tc_repr(buffer, sizeof buffer, result->summary.external_departure_rate_by_node[i]));
    }
    fprintf(out, "], \"boundary\": {\"probability_at_total_cap\": %s}}},\n",
            tc_repr(buffer, sizeof buffer, result->summary.probability_at_total_cap));
    fprintf(out, "  \"diagnostics\": {\"stationary_solver\": {\"iterations\": %ld, "
                 "\"generator_residual_l1\": %s}},\n",
            result->diagnostics.iterations,
            tc_repr(buffer, sizeof buffer, result->diagnostics.generator_residual_l1));
    fprintf(out, "  \"certificates\": {\"foster_lyapunov\": {\"certified\": %s",
            result->certificate.certified ? "true" : "false");
    if (result->certificate.certified) {
        fprintf(out, ", \"bounds\": {\"mean_total_jobs_upper\": %s",
                tc_repr(buffer, sizeof buffer, result->certificate.mean_total_jobs_upper));
        fprintf(out, ", \"probability_outside_selected_cap_upper\": %s}",
                tc_repr(buffer, sizeof buffer,
                        result->certificate.probability_outside_selected_cap_upper));
    }
    fprintf(out, "}}\n}\n");
}

static void usage(FILE *out, const char *program)
{
    fprintf(out,
        "usage: %s <model.json|-> [--json|--compact|--human]\n"
        "\n"
        "Adaptive truncated CTMC for an open single-class Markovian queueing\n"
        "network (C engine). Reads the same document truncated_ctmc.py reads and\n"
        "prints byte-identical output.\n"
        "\n"
        "  --human       the report (what the GUI runs)\n"
        "  --json        structured output (the default, as in the Python)\n"
        "  --version     print the engine identity and exit\n", program);
}

int main(int argc, char **argv)
{
    const char *path = NULL;
    int want_json = 1, i, exit_code = 0;
    bnet_json document;
    tc_model model;
    tc_stability stability;
    tc_result result;

    memset(&model, 0, sizeof model);
    memset(&stability, 0, sizeof stability);
    memset(&result, 0, sizeof result);

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--json") == 0 || strcmp(argv[i], "--compact") == 0) want_json = 1;
        else if (strcmp(argv[i], "--human") == 0) want_json = 0;
        else if (strcmp(argv[i], "--version") == 0) {
            printf("bna_tc (Qnet adaptive truncated CTMC, C engine) 1.0.0\n");
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
        fail(TC_INPUT, "%s", document.error);
    } else if (tc_parse_model(&document, &model)
               && tc_traffic_and_stability(&model, &stability)
               && tc_solve(&model, &result)) {
        if (want_json) tc_write_json(stdout, &model, &stability, &result);
        else           tc_print_human(&model, &stability, &result);
        goto done;
    }
    /* A failure is reported as JSON in BOTH modes, on stdout, with exit status
     * 2 — `truncated_ctmc.py`'s main() falls through to write_json on every
     * error path, including --human. Printing a human line here instead would
     * be nicer and would not match. */
    {
        const char *scan;
        printf("{\n  \"schema_version\": 1,\n  \"solver_version\": \"1.0.0\",\n");
        printf("  \"status\": \"error\",\n  \"engine\": \"c\",\n");
        printf("  \"error\": {\"code\": \"%s\", \"message\": \"", tc_error_code_name(g_error_kind));
        for (scan = g_error_message; *scan; scan++) {
            if (*scan == '"' || *scan == '\\') putchar('\\');
            putchar(*scan);
        }
        printf("\"}\n}\n");
    }
    exit_code = 2;

done:
    tc_result_free(&result);
    free(stability.throughput); free(stability.capacities); free(stability.utilizations);
    free(model.nodes); free(model.routing); free(model.exit_probabilities);
    free(model.options.tail_levels);
    bnet_json_free(&document);
    return exit_code;
}
