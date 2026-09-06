/*
 * bna_qbd.c — exact stationary distribution of a level-independent
 * continuous-time QBD.
 *
 * The C engine for `Run > Exact Matrix-Analytic QBD`. `qbd_solver.py` in this
 * directory is the other one; Settings > Solvers > Solver Engine picks between
 * them, and both read the same exported document.
 *
 * THE CONTRACT BETWEEN THE TWO ENGINES
 *
 * Byte-identical output, with no exceptions — this method has no random stream
 * and no wall-clock safeguard, so unlike the regenerative simulator there is
 * nothing here that can legitimately differ. `tests/test_engine_parity.sh`
 * diffs the whole of stdout, report and machine records alike, on every
 * packaged example and on every refusal.
 *
 * Holding that line costs three specific disciplines, and every one of them has
 * a comment at the point it applies:
 *
 *   1. `math.fsum` where the Python uses `math.fsum`. That is nearly every
 *      inner product in this file: matrix multiply, row-vector multiply, dot,
 *      the infinity norm, the back-substitution tail. bnet_fsum is Shewchuk's
 *      exact summation, the same algorithm CPython implements, so the sums are
 *      not merely close but the same double. Where the Python uses a PLAIN sum
 *      — there is exactly one, in `perron_bounds` — this file uses a plain
 *      left-to-right sum too, and says so.
 *
 *   2. -ffp-contract=off (see the Makefile). Clang would otherwise fuse
 *      `a*b + c` into one FMA, which is a different double from the same
 *      expression evaluated in two steps. The Python never fuses.
 *
 *   3. Tie-breaking that matches Python's. `max(range(...), key=...)` keeps
 *      the FIRST maximum; the pivot search here uses a strict `>` so it does
 *      too. Choosing a different pivot on a tie would give a different — still
 *      correct — factorisation and a visibly different residual.
 *
 * SPEED, AND WHAT EXACTNESS COSTS
 *
 * Measured on this machine over an M/E_k/1: at 16 phases 0.70 s -> 0.03 s
 * (23x), at 32 phases 8.28 s -> 0.50 s (17x), at 48 phases 38.9 s -> 2.4 s
 * (16x). The work is O(k^3) per iteration with O(k) iterations, so the absolute
 * saving grows as k^4 even though the ratio does not.
 *
 * 16x, not the ~200x a C rewrite of this kernel would normally give, and the
 * gap is entirely the exact summation. Measured directly on the 32x32 kernel:
 * naive accumulation runs at 3,707 M-MAC/s and bnet_fsum at 159 M-MAC/s, a
 * factor of 23, because Shewchuk's algorithm carries three to four non-
 * overlapping partial sums for this data and re-runs its compare-and-split loop
 * over all of them for every term.
 *
 * That cost is the price of the contract at the top of this file, and it is
 * worth paying: 16x with an answer that is bit-for-bit the Python's beats 200x
 * with an answer that is merely very close, because "very close" is exactly the
 * situation in which a user cannot tell a rounding difference from a bug. The
 * Python spends the same 23x on the same algorithm and pays interpreter
 * overhead on top; that difference is what this engine collects.
 */

#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../../common/bnet_json.h"
#include "../../common/bnet_fsum.h"

#define QBD_OK           0
#define QBD_INPUT        1
#define QBD_STABILITY    2
#define QBD_CONVERGENCE  3
#define QBD_NUMERICAL    4

#define QBD_DBL_EPSILON 2.2204460492503131e-16
#define QBD_DBL_MIN     2.2250738585072014e-308

static int  g_error_kind = QBD_OK;
static char g_error_message[512];

static const char *qbd_error_code_name(int kind)
{
    switch (kind) {
    case QBD_INPUT:       return "invalid_input";
    case QBD_STABILITY:   return "not_positive_recurrent";
    case QBD_CONVERGENCE: return "did_not_converge";
    case QBD_NUMERICAL:   return "numerical_failure";
    default:              return "qbd_error";
    }
}

static int fail(int kind, const char *format, ...)
{
    va_list args;
    if (g_error_kind == QBD_OK) {
        g_error_kind = kind;
        va_start(args, format);
        vsnprintf(g_error_message, sizeof g_error_message, format, args);
        va_end(args);
    }
    return 0;
}

/* ------------------------------------------------------------- matrices */

/*
 * A matrix is a shape plus a contiguous block. Every allocation is registered
 * so `qbd_release_all()` can free the lot at exit: the numeric routines below
 * are transcriptions of Python expressions that build a dozen temporaries per
 * line, and threading an explicit free through each of them would bury the
 * arithmetic — which is the part that has to be read against the original.
 * The program is short-lived and the matrices are phase-sized, so an arena is
 * the right trade; it is not a licence to allocate in an inner loop, and
 * nothing here does.
 */
typedef struct {
    int     rows;
    int     cols;
    double *a;
} qbd_matrix;

#define QBD_AT(m, i, j) ((m).a[(size_t)(i) * (size_t)(m).cols + (size_t)(j)])

static double **g_blocks = NULL;
static int      g_block_count = 0;
static int      g_block_capacity = 0;

static double *qbd_alloc(size_t count)
{
    double *block = (double *)calloc(count ? count : 1, sizeof(double));
    if (!block) { fail(QBD_NUMERICAL, "out of memory"); return NULL; }
    if (g_block_count == g_block_capacity) {
        int cap = g_block_capacity ? g_block_capacity * 2 : 64;
        double **grown = (double **)realloc(g_blocks, (size_t)cap * sizeof *grown);
        if (!grown) { free(block); fail(QBD_NUMERICAL, "out of memory"); return NULL; }
        g_blocks = grown;
        g_block_capacity = cap;
    }
    g_blocks[g_block_count++] = block;
    return block;
}

static void qbd_release_all(void)
{
    int i;
    for (i = 0; i < g_block_count; i++) free(g_blocks[i]);
    free(g_blocks);
    g_blocks = NULL;
    g_block_count = g_block_capacity = 0;
}

static qbd_matrix qbd_zeros(int rows, int cols)
{
    qbd_matrix m;
    m.rows = rows;
    m.cols = cols;
    m.a = qbd_alloc((size_t)rows * (size_t)cols);
    return m;
}

static qbd_matrix qbd_identity(int size)
{
    qbd_matrix m = qbd_zeros(size, size);
    int i;
    if (!m.a) return m;
    for (i = 0; i < size; i++) QBD_AT(m, i, i) = 1.0;
    return m;
}

static qbd_matrix qbd_copy(qbd_matrix source)
{
    qbd_matrix m = qbd_zeros(source.rows, source.cols);
    if (m.a) memcpy(m.a, source.a, (size_t)source.rows * (size_t)source.cols * sizeof(double));
    return m;
}

/* fsum over the k terms, matching `matrix_add(*matrices)`. */
static qbd_matrix qbd_add(const qbd_matrix *terms, int count)
{
    qbd_matrix out = qbd_zeros(terms[0].rows, terms[0].cols);
    int i, j, t;
    if (!out.a) return out;
    for (i = 0; i < out.rows; i++) {
        for (j = 0; j < out.cols; j++) {
            bnet_fsum total;
            bnet_fsum_init(&total);
            for (t = 0; t < count; t++) bnet_fsum_add(&total, QBD_AT(terms[t], i, j));
            QBD_AT(out, i, j) = bnet_fsum_value(&total);
        }
    }
    return out;
}

static qbd_matrix qbd_add2(qbd_matrix a, qbd_matrix b)
{
    qbd_matrix terms[2];
    terms[0] = a; terms[1] = b;
    return qbd_add(terms, 2);
}

static qbd_matrix qbd_add3(qbd_matrix a, qbd_matrix b, qbd_matrix c)
{
    qbd_matrix terms[3];
    terms[0] = a; terms[1] = b; terms[2] = c;
    return qbd_add(terms, 3);
}

/* Plain elementwise difference — the Python's `matrix_subtract` is not an fsum. */
static qbd_matrix qbd_subtract(qbd_matrix left, qbd_matrix right)
{
    qbd_matrix out = qbd_zeros(left.rows, left.cols);
    int i, j;
    if (!out.a) return out;
    for (i = 0; i < out.rows; i++)
        for (j = 0; j < out.cols; j++)
            QBD_AT(out, i, j) = QBD_AT(left, i, j) - QBD_AT(right, i, j);
    return out;
}

static qbd_matrix qbd_scale(qbd_matrix m, double scalar)
{
    qbd_matrix out = qbd_zeros(m.rows, m.cols);
    int i, j;
    if (!out.a) return out;
    for (i = 0; i < out.rows; i++)
        for (j = 0; j < out.cols; j++)
            QBD_AT(out, i, j) = scalar * QBD_AT(m, i, j);
    return out;
}

/* THE kernel: 91% of the Python's run time, and the reason this engine exists. */
static qbd_matrix qbd_multiply(qbd_matrix left, qbd_matrix right)
{
    qbd_matrix out = qbd_zeros(left.rows, right.cols);
    int i, j, k;
    if (!out.a) return out;
    for (i = 0; i < left.rows; i++) {
        for (j = 0; j < right.cols; j++) {
            bnet_fsum total;
            bnet_fsum_init(&total);
            for (k = 0; k < right.rows; k++) {
                bnet_fsum_add(&total, QBD_AT(left, i, k) * QBD_AT(right, k, j));
            }
            QBD_AT(out, i, j) = bnet_fsum_value(&total);
        }
    }
    return out;
}

static void qbd_row_vector_multiply(const double *vector, qbd_matrix m, double *out)
{
    int i, j;
    for (j = 0; j < m.cols; j++) {
        bnet_fsum total;
        bnet_fsum_init(&total);
        for (i = 0; i < m.rows; i++) bnet_fsum_add(&total, vector[i] * QBD_AT(m, i, j));
        out[j] = bnet_fsum_value(&total);
    }
}

static void qbd_matrix_vector_multiply(qbd_matrix m, const double *vector, double *out)
{
    int i, j;
    for (i = 0; i < m.rows; i++) {
        bnet_fsum total;
        bnet_fsum_init(&total);
        for (j = 0; j < m.cols; j++) bnet_fsum_add(&total, QBD_AT(m, i, j) * vector[j]);
        out[i] = bnet_fsum_value(&total);
    }
}

static double qbd_dot(const double *left, const double *right, int count)
{
    bnet_fsum total;
    int i;
    bnet_fsum_init(&total);
    for (i = 0; i < count; i++) bnet_fsum_add(&total, left[i] * right[i]);
    return bnet_fsum_value(&total);
}

static double qbd_max_abs_matrix(qbd_matrix m)
{
    double best = 0.0;
    int i, n = m.rows * m.cols;
    for (i = 0; i < n; i++) if (fabs(m.a[i]) > best) best = fabs(m.a[i]);
    return best;
}

static double qbd_max_abs_vector(const double *v, int count)
{
    double best = 0.0;
    int i;
    for (i = 0; i < count; i++) if (fabs(v[i]) > best) best = fabs(v[i]);
    return best;
}

static double qbd_infinity_norm(qbd_matrix m)
{
    double best = 0.0;
    int i, j;
    for (i = 0; i < m.rows; i++) {
        bnet_fsum total;
        double row_sum;
        bnet_fsum_init(&total);
        for (j = 0; j < m.cols; j++) bnet_fsum_add(&total, fabs(QBD_AT(m, i, j)));
        row_sum = bnet_fsum_value(&total);
        if (row_sum > best) best = row_sum;
    }
    return best;
}

static qbd_matrix qbd_power(qbd_matrix m, int exponent)
{
    qbd_matrix result = qbd_identity(m.rows);
    qbd_matrix factor = qbd_copy(m);
    int remaining = exponent;
    while (remaining) {
        if (remaining & 1) result = qbd_multiply(result, factor);
        remaining >>= 1;
        if (remaining) factor = qbd_multiply(factor, factor);
    }
    return result;
}

/* Scaled partial-pivot elimination. `keep the FIRST maximum` is deliberate:
 * Python's `max(range(...), key=...)` does, and a different pivot on a tie
 * gives a different (still correct) factorisation and a different residual. */
static int qbd_solve_linear(qbd_matrix m, const double *rhs, double *solution)
{
    int size = m.rows, column, row, j, ok = 1;
    double *aug, *scales;
    if (size == 0 || m.cols != size) {
        return fail(QBD_INPUT, "linear solve requires a nonempty square matrix");
    }
    aug = qbd_alloc((size_t)size * (size_t)(size + 1));
    scales = qbd_alloc((size_t)size);
    if (!aug || !scales) return 0;
    for (row = 0; row < size; row++) {
        double biggest = 0.0;
        for (j = 0; j < size; j++) {
            double v = QBD_AT(m, row, j);
            aug[(size_t)row * (size + 1) + j] = v;
            if (fabs(v) > biggest) biggest = fabs(v);
        }
        aug[(size_t)row * (size + 1) + size] = rhs[row];
        scales[row] = biggest;
        if (biggest == 0.0) ok = 0;
    }
    if (!ok) return fail(QBD_INPUT, "singular matrix contains an all-zero equation");

    for (column = 0; column < size; column++) {
        int pivot = column;
        double best = fabs(aug[(size_t)column * (size + 1) + column]) / scales[column];
        double pivot_floor, pivot_value;
        for (row = column + 1; row < size; row++) {
            double candidate = fabs(aug[(size_t)row * (size + 1) + column]) / scales[row];
            if (candidate > best) { best = candidate; pivot = row; }
        }
        pivot_floor = 8.0 * QBD_DBL_EPSILON * (double)(size > 1 ? size : 1) * scales[pivot];
        if (fabs(aug[(size_t)pivot * (size + 1) + column]) <= pivot_floor) {
            return fail(QBD_INPUT, "singular or numerically rank-deficient matrix");
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
            if (factor == 0.0) continue;
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
            bnet_fsum_add(&tail, aug[(size_t)row * (size + 1) + j] * solution[j]);
        }
        solution[row] = (aug[(size_t)row * (size + 1) + size] - bnet_fsum_value(&tail))
                        / aug[(size_t)row * (size + 1) + row];
    }
    return 1;
}

static int qbd_inverse(qbd_matrix m, qbd_matrix *out)
{
    int size = m.rows, column, row;
    double *rhs = qbd_alloc((size_t)size);
    double *column_solution = qbd_alloc((size_t)size);
    qbd_matrix result = qbd_zeros(size, size);
    if (!rhs || !column_solution || !result.a) return 0;
    for (column = 0; column < size; column++) {
        for (row = 0; row < size; row++) rhs[row] = 0.0;
        rhs[column] = 1.0;
        if (!qbd_solve_linear(m, rhs, column_solution)) return 0;
        /* `inverse` transposes a list of solved COLUMNS, so solution i of
         * column j lands at [i][j]. */
        for (row = 0; row < size; row++) QBD_AT(result, row, column) = column_solution[row];
    }
    *out = result;
    return 1;
}

/*
 * x M = 0 with x·normalization = 1.
 *
 * Every row is tried as the one to replace, and the candidate with the smallest
 * balance residual wins — the Python's comment explains why: assuming a
 * particular balance equation is the redundant one is not robust. The
 * REVERSED loop order (size-1 down to 0) is copied exactly, because ties on
 * residual are resolved by "first seen wins" and reversing the scan would pick
 * a different vector for the same input.
 */
static int qbd_solve_left_null(qbd_matrix m, const double *normalization,
                               int have_nonnegative_tolerance, double nonnegative_tolerance,
                               double *out, double *out_residual)
{
    int size = m.rows, replacement, i, j;
    double *best = NULL, *best_nonnegative = NULL;
    double best_residual = 0.0, best_nonnegative_residual = 0.0;
    double *candidate = qbd_alloc((size_t)size);
    double *rhs = qbd_alloc((size_t)size);
    double *product = qbd_alloc((size_t)size);
    if (!candidate || !rhs || !product) return 0;
    if (m.cols != size) return fail(QBD_INPUT, "normalization vector has the wrong dimension");

    for (replacement = size - 1; replacement >= 0; replacement--) {
        qbd_matrix equations = qbd_zeros(size, size);
        double residual, smallest;
        int saved_kind;
        if (!equations.a) return 0;
        /* transpose(matrix), then row `replacement` replaced by the
         * normalization vector. */
        for (i = 0; i < size; i++)
            for (j = 0; j < size; j++)
                QBD_AT(equations, i, j) = QBD_AT(m, j, i);
        for (j = 0; j < size; j++) QBD_AT(equations, replacement, j) = normalization[j];
        for (j = 0; j < size; j++) rhs[j] = 0.0;
        rhs[replacement] = 1.0;

        /* A singular replacement is skipped, not fatal — the Python catches
         * QBDInputError and continues — so the error slot is saved and
         * restored rather than left holding a failure that did not matter. */
        saved_kind = g_error_kind;
        if (!qbd_solve_linear(equations, rhs, candidate)) {
            g_error_kind = saved_kind;
            continue;
        }
        qbd_row_vector_multiply(candidate, m, product);
        residual = qbd_max_abs_vector(product, size);
        if (!best || residual < best_residual) {
            if (!best) { best = qbd_alloc((size_t)size); if (!best) return 0; }
            memcpy(best, candidate, (size_t)size * sizeof(double));
            best_residual = residual;
        }
        smallest = candidate[0];
        for (j = 1; j < size; j++) if (candidate[j] < smallest) smallest = candidate[j];
        if (have_nonnegative_tolerance && smallest >= -nonnegative_tolerance
            && (!best_nonnegative || residual < best_nonnegative_residual)) {
            if (!best_nonnegative) {
                best_nonnegative = qbd_alloc((size_t)size);
                if (!best_nonnegative) return 0;
            }
            memcpy(best_nonnegative, candidate, (size_t)size * sizeof(double));
            best_nonnegative_residual = residual;
        }
    }
    if (!best) {
        return fail(QBD_INPUT, "balance equations do not have a unique normalizable "
                               "solution; the QBD may be reducible");
    }
    if (best_nonnegative) {
        memcpy(out, best_nonnegative, (size_t)size * sizeof(double));
        if (out_residual) *out_residual = best_nonnegative_residual;
    } else {
        memcpy(out, best, (size_t)size * sizeof(double));
        if (out_residual) *out_residual = best_residual;
    }
    return 1;
}

/* --------------------------------------------------------------- model */

typedef struct {
    double absolute_tolerance;
    double relative_tolerance;
    double residual_tolerance;
    double generator_tolerance;
    double stability_tolerance;
    long   max_iterations;
    long   max_report_level;
    int   *tail_levels;         /* sorted, unique */
    int    tail_count;
} qbd_options;

typedef struct {
    qbd_matrix  b00, b01, b10, b11;
    qbd_matrix  a_down, a_same, a_up;
    qbd_options options;
    int         has_name;
    char        name[256];
} qbd_model;

#define QBD_BOUNDARY_PHASES(model) ((model)->b00.rows)
#define QBD_INTERIOR_PHASES(model) ((model)->a_same.rows)

static int qbd_as_matrix(const bnet_json *d, int node, const char *path, qbd_matrix *out)
{
    int rows, cols, i, j;
    if (bnet_json_type_of(d, node) != BNET_JSON_ARRAY || bnet_json_count(d, node) == 0) {
        return fail(QBD_INPUT, "%s must be a nonempty array of rows", path);
    }
    rows = bnet_json_count(d, node);
    for (i = 0; i < rows; i++) {
        int row = bnet_json_at(d, node, i);
        if (bnet_json_type_of(d, row) != BNET_JSON_ARRAY || bnet_json_count(d, row) == 0) {
            return fail(QBD_INPUT, "%s must contain nonempty array rows", path);
        }
    }
    cols = bnet_json_count(d, bnet_json_at(d, node, 0));
    for (i = 0; i < rows; i++) {
        if (bnet_json_count(d, bnet_json_at(d, node, i)) != cols) {
            return fail(QBD_INPUT, "%s must be rectangular", path);
        }
    }
    *out = qbd_zeros(rows, cols);
    if (!out->a) return 0;
    for (i = 0; i < rows; i++) {
        int row = bnet_json_at(d, node, i);
        for (j = 0; j < cols; j++) {
            double value;
            if (!bnet_json_number(d, bnet_json_at(d, row, j), &value) || !isfinite(value)) {
                return fail(QBD_INPUT, "%s[%d][%d] must be a finite number", path, i, j);
            }
            QBD_AT(*out, i, j) = value;
        }
    }
    return 1;
}

static int qbd_positive_float(const bnet_json *d, int object, const char *key,
                              double fallback, double *out)
{
    int node = bnet_json_member(d, object, key);
    if (node == BNET_JSON_NONE) { *out = fallback; return 1; }
    if (!bnet_json_number(d, node, out) || !isfinite(*out) || *out <= 0.0) {
        return fail(QBD_INPUT, "solver.%s must be a positive finite number", key);
    }
    return 1;
}

static int qbd_nonnegative_int(const bnet_json *d, int object, const char *key,
                               long fallback, long *out)
{
    int node = bnet_json_member(d, object, key);
    double value;
    if (node == BNET_JSON_NONE) { *out = fallback; return 1; }
    if (!bnet_json_number(d, node, &value) || value != floor(value) || value < 0.0) {
        return fail(QBD_INPUT, "solver.%s must be a nonnegative integer", key);
    }
    *out = (long)value;
    return 1;
}

static int qbd_check_shape(qbd_matrix m, int rows, int cols, const char *name)
{
    if (m.rows != rows || m.cols != cols) {
        return fail(QBD_INPUT, "%s has shape %dx%d; expected %dx%d", name, m.rows, m.cols, rows, cols);
    }
    return 1;
}

static int qbd_check_transition_block(qbd_matrix m, const char *name, double tolerance)
{
    int i, j;
    for (i = 0; i < m.rows; i++)
        for (j = 0; j < m.cols; j++)
            if (QBD_AT(m, i, j) < -tolerance)
                return fail(QBD_INPUT, "%s[%d][%d] must be nonnegative", name, i, j);
    return 1;
}

static int qbd_check_same_level_block(qbd_matrix m, const char *name, double tolerance)
{
    int i, j;
    for (i = 0; i < m.rows; i++) {
        for (j = 0; j < m.cols; j++) {
            double value = QBD_AT(m, i, j);
            if (i == j) {
                if (value >= 0.0) return fail(QBD_INPUT, "%s[%d][%d] must be negative", name, i, j);
            } else if (value < -tolerance) {
                return fail(QBD_INPUT, "%s[%d][%d] must be nonnegative", name, i, j);
            }
        }
    }
    return 1;
}

/* Python's repr(float): the shortest digits that read back exactly. The
 * row-sum message quotes the value, so the two engines must spell it alike. */
static const char *qbd_repr(char *buffer, size_t size, double value)
{
    int precision;
    for (precision = 1; precision <= 17; precision++) {
        snprintf(buffer, size, "%.*g", precision, value);
        if (strtod(buffer, NULL) == value) break;
    }
    return buffer;
}

static int qbd_check_row_sums(const qbd_matrix *blocks, int count,
                              const char *name, double tolerance)
{
    int rows = blocks[0].rows, i, b, j;
    double scale = QBD_DBL_MIN;
    for (b = 0; b < count; b++) {
        double norm = qbd_infinity_norm(blocks[b]);
        if (norm > scale) scale = norm;
    }
    for (i = 0; i < rows; i++) {
        /* fsum of per-block fsums, exactly as the Python nests them. */
        bnet_fsum outer;
        double total;
        bnet_fsum_init(&outer);
        for (b = 0; b < count; b++) {
            bnet_fsum inner;
            bnet_fsum_init(&inner);
            for (j = 0; j < blocks[b].cols; j++) bnet_fsum_add(&inner, QBD_AT(blocks[b], i, j));
            bnet_fsum_add(&outer, bnet_fsum_value(&inner));
        }
        total = bnet_fsum_value(&outer);
        if (fabs(total) > tolerance * scale) {
            char shown[64];
            /* `{total:.17g}` in the Python, not repr(): 17 significant
             * digits regardless of how few would round-trip. */
            snprintf(shown, sizeof shown, "%.17g", total);
            return fail(QBD_INPUT, "%s generator row %d sums to %s, not zero", name, i, shown);
        }
    }
    return 1;
}

/* Strong connectivity of a directed graph given as adjacency lists, by the
 * same forward-and-reverse reachability the Python uses. */
static int qbd_adjacency_strongly_connected(const char *adjacency, int size)
{
    char *seen;
    int *stack;
    int direction, ok = 1;
    if (size <= 1) return 1;
    seen = (char *)calloc((size_t)size, 1);
    stack = (int *)malloc((size_t)size * sizeof(int));
    if (!seen || !stack) { free(seen); free(stack); fail(QBD_NUMERICAL, "out of memory"); return 0; }
    for (direction = 0; direction < 2 && ok; direction++) {
        int top = 0, i;
        memset(seen, 0, (size_t)size);
        seen[0] = 1;
        stack[top++] = 0;
        while (top) {
            int state = stack[--top], target;
            for (target = 0; target < size; target++) {
                int edge = direction == 0 ? adjacency[(size_t)state * size + target]
                                          : adjacency[(size_t)target * size + state];
                if (edge && !seen[target]) { seen[target] = 1; stack[top++] = target; }
            }
        }
        for (i = 0; i < size; i++) if (!seen[i]) { ok = 0; break; }
    }
    free(seen); free(stack);
    return ok;
}

static int qbd_strongly_connected(qbd_matrix generator)
{
    int size = generator.rows, i, j, ok;
    char *adjacency = (char *)calloc((size_t)size * (size_t)size, 1);
    if (!adjacency) { fail(QBD_NUMERICAL, "out of memory"); return 0; }
    for (i = 0; i < size; i++)
        for (j = 0; j < size; j++)
            if (i != j && QBD_AT(generator, i, j) > 0.0) adjacency[(size_t)i * size + j] = 1;
    ok = qbd_adjacency_strongly_connected(adjacency, size);
    free(adjacency);
    return ok;
}

static int qbd_boundary_interior_connected(const qbd_model *model)
{
    int m0 = QBD_BOUNDARY_PHASES(model), m = QBD_INTERIOR_PHASES(model);
    int size = m0 + m, i, j, ok;
    char *adjacency = (char *)calloc((size_t)size * (size_t)size, 1);
    if (!adjacency) { fail(QBD_NUMERICAL, "out of memory"); return 0; }
    for (i = 0; i < m0; i++) {
        for (j = 0; j < m0; j++)
            if (i != j && QBD_AT(model->b00, i, j) > 0.0) adjacency[(size_t)i * size + j] = 1;
        for (j = 0; j < m; j++)
            if (QBD_AT(model->b01, i, j) > 0.0) adjacency[(size_t)i * size + (m0 + j)] = 1;
    }
    for (i = 0; i < m; i++) {
        int source = m0 + i, b;
        const qbd_matrix blocks[4] = { model->b11, model->a_down, model->a_same, model->a_up };
        for (j = 0; j < m0; j++)
            if (QBD_AT(model->b10, i, j) > 0.0) adjacency[(size_t)source * size + j] = 1;
        for (b = 0; b < 4; b++)
            for (j = 0; j < m; j++)
                if (i != j && QBD_AT(blocks[b], i, j) > 0.0)
                    adjacency[(size_t)source * size + (m0 + j)] = 1;
    }
    ok = qbd_adjacency_strongly_connected(adjacency, size);
    free(adjacency);
    return ok;
}

static int qbd_validate_model(const qbd_model *model)
{
    int m0 = QBD_BOUNDARY_PHASES(model), m = QBD_INTERIOR_PHASES(model);
    double tolerance = model->options.generator_tolerance;
    qbd_matrix level0[2], level1[3], interior[3], phase_generator;

    if (!qbd_check_shape(model->b00, m0, m0, "boundary.level_0_same")) return 0;
    if (!qbd_check_shape(model->b01, m0, m,  "boundary.level_0_up")) return 0;
    if (!qbd_check_shape(model->b10, m,  m0, "boundary.level_1_down")) return 0;
    if (!qbd_check_shape(model->b11, m,  m,  "boundary.level_1_same")) return 0;
    if (!qbd_check_shape(model->a_down, m, m, "interior.down")) return 0;
    if (!qbd_check_shape(model->a_same, m, m, "interior.same")) return 0;
    if (!qbd_check_shape(model->a_up,   m, m, "interior.up")) return 0;

    if (!qbd_check_transition_block(model->b01, "boundary.level_0_up", tolerance)) return 0;
    if (!qbd_check_transition_block(model->b10, "boundary.level_1_down", tolerance)) return 0;
    if (!qbd_check_transition_block(model->a_down, "interior.down", tolerance)) return 0;
    if (!qbd_check_transition_block(model->a_up, "interior.up", tolerance)) return 0;
    if (!qbd_check_same_level_block(model->b00, "boundary.level_0_same", tolerance)) return 0;
    if (!qbd_check_same_level_block(model->b11, "boundary.level_1_same", tolerance)) return 0;
    if (!qbd_check_same_level_block(model->a_same, "interior.same", tolerance)) return 0;

    level0[0] = model->b00; level0[1] = model->b01;
    if (!qbd_check_row_sums(level0, 2, "level 0", tolerance)) return 0;
    level1[0] = model->b10; level1[1] = model->b11; level1[2] = model->a_up;
    if (!qbd_check_row_sums(level1, 3, "level 1", tolerance)) return 0;
    interior[0] = model->a_down; interior[1] = model->a_same; interior[2] = model->a_up;
    if (!qbd_check_row_sums(interior, 3, "interior", tolerance)) return 0;

    phase_generator = qbd_add3(model->a_down, model->a_same, model->a_up);
    if (!phase_generator.a) return 0;
    if (!qbd_strongly_connected(phase_generator)) {
        if (g_error_kind != QBD_OK) return 0;
        return fail(QBD_INPUT, "the interior phase generator is reducible; schema version 1 "
                               "requires one irreducible phase class");
    }
    if (!qbd_boundary_interior_connected(model)) {
        if (g_error_kind != QBD_OK) return 0;
        return fail(QBD_INPUT, "the boundary/interior phase graph is reducible; schema version 1 "
                               "requires one communicating structure and does not choose among "
                               "multiple stationary classes");
    }
    return 1;
}

static int qbd_compare_int(const void *left, const void *right)
{
    int a = *(const int *)left, b = *(const int *)right;
    return (a > b) - (a < b);
}

static int qbd_parse_model(const bnet_json *d, qbd_model *model)
{
    int root = d->root, boundary, interior, options_node, tail_node;
    const char *process;
    const char *name;
    double schema;
    long max_iterations, max_report_level;
    int i, count, unique;

    memset(model, 0, sizeof *model);
    if (bnet_json_type_of(d, root) != BNET_JSON_OBJECT) {
        return fail(QBD_INPUT, "the JSON root must be an object");
    }
    schema = bnet_json_number_or(d, bnet_json_member(d, root, "schema_version"), 1.0);
    if (schema != 1.0) return fail(QBD_INPUT, "only schema_version 1 is supported");
    process = bnet_json_string_or(d, bnet_json_member(d, root, "process"), "continuous_time_qbd");
    if (strcmp(process, "continuous_time_qbd") != 0) {
        return fail(QBD_INPUT, "process must be 'continuous_time_qbd'");
    }
    boundary = bnet_json_member(d, root, "boundary");
    interior = bnet_json_member(d, root, "interior");
    if (bnet_json_type_of(d, boundary) != BNET_JSON_OBJECT
        || bnet_json_type_of(d, interior) != BNET_JSON_OBJECT) {
        return fail(QBD_INPUT, "boundary and interior must be JSON objects");
    }
    if (!qbd_as_matrix(d, bnet_json_member(d, boundary, "level_0_same"),
                       "boundary.level_0_same", &model->b00)) return 0;
    if (!qbd_as_matrix(d, bnet_json_member(d, boundary, "level_0_up"),
                       "boundary.level_0_up", &model->b01)) return 0;
    if (!qbd_as_matrix(d, bnet_json_member(d, boundary, "level_1_down"),
                       "boundary.level_1_down", &model->b10)) return 0;
    if (!qbd_as_matrix(d, bnet_json_member(d, boundary, "level_1_same"),
                       "boundary.level_1_same", &model->b11)) return 0;
    if (!qbd_as_matrix(d, bnet_json_member(d, interior, "down"), "interior.down", &model->a_down)) return 0;
    if (!qbd_as_matrix(d, bnet_json_member(d, interior, "same"), "interior.same", &model->a_same)) return 0;
    if (!qbd_as_matrix(d, bnet_json_member(d, interior, "up"), "interior.up", &model->a_up)) return 0;

    options_node = bnet_json_member(d, root, "solver");
    if (options_node != BNET_JSON_NONE && bnet_json_type_of(d, options_node) != BNET_JSON_OBJECT) {
        return fail(QBD_INPUT, "solver must be a JSON object");
    }
    if (!qbd_nonnegative_int(d, options_node, "max_iterations", 100000, &max_iterations)) return 0;
    if (max_iterations < 1) return fail(QBD_INPUT, "solver.max_iterations must be at least 1");
    if (!qbd_nonnegative_int(d, options_node, "max_report_level", 10, &max_report_level)) return 0;
    model->options.max_iterations = max_iterations;
    model->options.max_report_level = max_report_level;

    tail_node = bnet_json_member(d, options_node, "tail_levels");
    if (tail_node == BNET_JSON_NONE) {
        /* The arena holds doubles; these are ints, so they get their own
         * block, freed with the model. */
        model->options.tail_levels = (int *)malloc(3 * sizeof(int));
        if (!model->options.tail_levels) return fail(QBD_NUMERICAL, "out of memory");
        model->options.tail_levels[0] = 1;
        model->options.tail_levels[1] = 5;
        model->options.tail_levels[2] = 10;
        model->options.tail_count = 3;
    } else {
        if (bnet_json_type_of(d, tail_node) != BNET_JSON_ARRAY) {
            return fail(QBD_INPUT, "solver.tail_levels must be an array of nonnegative integers");
        }
        count = bnet_json_count(d, tail_node);
        model->options.tail_levels = (int *)malloc((size_t)(count ? count : 1) * sizeof(int));
        if (!model->options.tail_levels) return fail(QBD_NUMERICAL, "out of memory");
        for (i = 0; i < count; i++) {
            double value;
            if (!bnet_json_number(d, bnet_json_at(d, tail_node, i), &value)
                || value != floor(value) || value < 0.0) {
                return fail(QBD_INPUT, "solver.tail_levels[%d] must be a nonnegative integer", i);
            }
            model->options.tail_levels[i] = (int)value;
        }
        model->options.tail_count = count;
    }
    /* `tuple(sorted(set(levels)))` */
    qsort(model->options.tail_levels, (size_t)model->options.tail_count,
          sizeof(int), qbd_compare_int);
    unique = 0;
    for (i = 0; i < model->options.tail_count; i++) {
        if (i == 0 || model->options.tail_levels[i] != model->options.tail_levels[i - 1]) {
            model->options.tail_levels[unique++] = model->options.tail_levels[i];
        }
    }
    model->options.tail_count = unique;

    if (!qbd_positive_float(d, options_node, "absolute_tolerance", 1.0e-14,
                            &model->options.absolute_tolerance)) return 0;
    if (!qbd_positive_float(d, options_node, "relative_tolerance", 1.0e-12,
                            &model->options.relative_tolerance)) return 0;
    if (!qbd_positive_float(d, options_node, "residual_tolerance", 1.0e-11,
                            &model->options.residual_tolerance)) return 0;
    if (!qbd_positive_float(d, options_node, "generator_tolerance", 1.0e-11,
                            &model->options.generator_tolerance)) return 0;
    if (!qbd_positive_float(d, options_node, "stability_tolerance", 1.0e-12,
                            &model->options.stability_tolerance)) return 0;

    {
        int name_node = bnet_json_member(d, root, "name");
        if (name_node != BNET_JSON_NONE && !bnet_json_is_null(d, name_node)) {
            name = bnet_json_string(d, name_node);
            if (!name) return fail(QBD_INPUT, "name must be a string when present");
            if (strlen(name) >= sizeof model->name) return fail(QBD_INPUT, "name is too long");
            strcpy(model->name, name);
            model->has_name = 1;
        }
    }
    return qbd_validate_model(model);
}

/* ---------------------------------------------------- stability and rate */

typedef struct {
    const char *classification;
    double     *phase_vector;
    double      phase_balance_residual_inf;
    double      phase_balance_residual_scaled;
    double      mean_upward_rate;
    double      mean_downward_rate;
    double      net_level_drift;
    double      decision_tolerance;
} qbd_stability;

static int qbd_stability_diagnostics(const qbd_model *model, qbd_stability *out)
{
    int size = QBD_INTERIOR_PHASES(model), i;
    double *ones = qbd_alloc((size_t)size);
    double *phase_vector = qbd_alloc((size_t)size);
    double *product = qbd_alloc((size_t)size);
    double *scratch = qbd_alloc((size_t)size);
    qbd_matrix phase_generator;
    double negativity_tolerance = 100.0 * model->options.generator_tolerance;
    double smallest, phase_total, phase_scale, drift_scale, tolerance;
    bnet_fsum total;
    if (!ones || !phase_vector || !product || !scratch) return 0;
    for (i = 0; i < size; i++) ones[i] = 1.0;
    phase_generator = qbd_add3(model->a_down, model->a_same, model->a_up);
    if (!phase_generator.a) return 0;
    if (!qbd_solve_left_null(phase_generator, ones, 1, negativity_tolerance,
                             phase_vector, NULL)) return 0;
    smallest = phase_vector[0];
    for (i = 1; i < size; i++) if (phase_vector[i] < smallest) smallest = phase_vector[i];
    if (smallest < -negativity_tolerance) {
        return fail(QBD_INPUT, "interior phase stationary vector is not nonnegative");
    }
    for (i = 0; i < size; i++) if (phase_vector[i] < 0.0) phase_vector[i] = 0.0;
    bnet_fsum_init(&total);
    for (i = 0; i < size; i++) bnet_fsum_add(&total, phase_vector[i]);
    phase_total = bnet_fsum_value(&total);
    if (!isfinite(phase_total) || phase_total <= 0.0) {
        return fail(QBD_INPUT, "interior phase stationary vector cannot be normalized");
    }
    for (i = 0; i < size; i++) phase_vector[i] /= phase_total;
    qbd_row_vector_multiply(phase_vector, phase_generator, product);
    out->phase_balance_residual_inf = qbd_max_abs_vector(product, size);
    phase_scale = qbd_infinity_norm(phase_generator);
    if (phase_scale < QBD_DBL_MIN) phase_scale = QBD_DBL_MIN;
    out->phase_balance_residual_scaled = out->phase_balance_residual_inf / phase_scale;

    qbd_row_vector_multiply(phase_vector, model->a_up, scratch);
    out->mean_upward_rate = qbd_dot(scratch, ones, size);
    qbd_row_vector_multiply(phase_vector, model->a_down, scratch);
    out->mean_downward_rate = qbd_dot(scratch, ones, size);
    out->net_level_drift = out->mean_upward_rate - out->mean_downward_rate;
    drift_scale = out->mean_upward_rate + out->mean_downward_rate;
    if (drift_scale < QBD_DBL_MIN) drift_scale = QBD_DBL_MIN;
    tolerance = model->options.stability_tolerance * drift_scale;
    out->decision_tolerance = tolerance;
    if (out->net_level_drift < -tolerance)      out->classification = "positive_recurrent";
    else if (out->net_level_drift > tolerance)  out->classification = "transient";
    else                                        out->classification = "null_recurrent_or_critical";
    out->phase_vector = phase_vector;
    return 1;
}

static void qbd_rate_equation_residuals(const qbd_model *model, qbd_matrix rate,
                                        double *raw, double *scaled)
{
    qbd_matrix rate_squared = qbd_multiply(rate, rate);
    qbd_matrix equation = qbd_add3(model->a_up,
                                   qbd_multiply(rate, model->a_same),
                                   qbd_multiply(rate_squared, model->a_down));
    double residual, scale = QBD_DBL_MIN, candidate;
    residual = qbd_infinity_norm(equation);
    candidate = qbd_infinity_norm(model->a_up);   if (candidate > scale) scale = candidate;
    candidate = qbd_infinity_norm(model->a_same); if (candidate > scale) scale = candidate;
    candidate = qbd_infinity_norm(model->a_down); if (candidate > scale) scale = candidate;
    *raw = residual;
    *scaled = residual / scale;
}

typedef struct {
    long   iterations;
    double last_iteration_delta;
    double rate_equation_residual_inf;
    double rate_equation_residual_scaled;
    double uniformization_rate;
} qbd_iteration_diagnostics;

/* The minimal nonnegative R, by monotone uniformized functional iteration.
 * This loop is where the Python spends 91% of its time. */
static int qbd_compute_rate_matrix(const qbd_model *model, qbd_matrix *out,
                                   qbd_iteration_diagnostics *diagnostics)
{
    int size = QBD_INTERIOR_PHASES(model), i, j;
    double uniformization_rate = -QBD_AT(model->a_same, 0, 0);
    qbd_matrix p_up, p_down, p_same, rate;
    double delta = HUGE_VAL, raw_residual, residual, smallest;
    long iteration;

    for (i = 1; i < size; i++) {
        double candidate = -QBD_AT(model->a_same, i, i);
        if (candidate > uniformization_rate) uniformization_rate = candidate;
    }
    if (!isfinite(uniformization_rate) || uniformization_rate <= 0.0) {
        return fail(QBD_INPUT, "interior.same does not define positive holding rates");
    }
    p_up = qbd_zeros(size, size);
    p_down = qbd_zeros(size, size);
    if (!p_up.a || !p_down.a) return 0;
    for (i = 0; i < size; i++) {
        for (j = 0; j < size; j++) {
            double up = QBD_AT(model->a_up, i, j) / uniformization_rate;
            double down = QBD_AT(model->a_down, i, j) / uniformization_rate;
            QBD_AT(p_up, i, j) = up > 0.0 ? up : 0.0;
            QBD_AT(p_down, i, j) = down > 0.0 ? down : 0.0;
        }
    }
    p_same = qbd_add2(qbd_identity(size), qbd_scale(model->a_same, 1.0 / uniformization_rate));
    if (!p_same.a) return 0;
    smallest = p_same.a[0];
    for (i = 1; i < size * size; i++) if (p_same.a[i] < smallest) smallest = p_same.a[i];
    if (smallest < -model->options.generator_tolerance) {
        return fail(QBD_INPUT, "uniformized same-level block contains a negative probability");
    }
    for (i = 0; i < size * size; i++) if (p_same.a[i] < 0.0) p_same.a[i] = 0.0;

    rate = qbd_zeros(size, size);
    if (!rate.a) return 0;
    qbd_rate_equation_residuals(model, rate, &raw_residual, &residual);
    for (iteration = 1; iteration <= model->options.max_iterations; iteration++) {
        qbd_matrix rate_squared = qbd_multiply(rate, rate);
        qbd_matrix candidate = qbd_add3(p_up,
                                        qbd_multiply(rate, p_same),
                                        qbd_multiply(rate_squared, p_down));
        double monotonicity_floor, minimum_increment, threshold, largest;
        if (!candidate.a) return 0;
        for (i = 0; i < size * size; i++) {
            if (!isfinite(candidate.a[i])) {
                return fail(QBD_CONVERGENCE, "rate-matrix iteration produced a nonfinite value");
            }
        }
        monotonicity_floor = -100.0 * model->options.absolute_tolerance;
        minimum_increment = candidate.a[0] - rate.a[0];
        for (i = 1; i < size * size; i++) {
            double increment = candidate.a[i] - rate.a[i];
            if (increment < minimum_increment) minimum_increment = increment;
        }
        if (minimum_increment < monotonicity_floor) {
            return fail(QBD_CONVERGENCE, "minimal-rate iteration lost componentwise monotonicity");
        }
        for (i = 0; i < size * size; i++) {
            double value = rate.a[i];
            if (candidate.a[i] > value) value = candidate.a[i];
            if (0.0 > value) value = 0.0;
            candidate.a[i] = value;
        }
        delta = qbd_max_abs_matrix(qbd_subtract(candidate, rate));
        rate = candidate;
        qbd_rate_equation_residuals(model, rate, &raw_residual, &residual);
        largest = qbd_max_abs_matrix(rate);
        if (largest < 1.0) largest = 1.0;
        threshold = model->options.absolute_tolerance
                  + model->options.relative_tolerance * largest;
        if (delta <= threshold && residual <= model->options.residual_tolerance) break;
        if (delta == 0.0) {
            return fail(QBD_CONVERGENCE,
                        "rate-matrix iteration stagnated before satisfying the residual tolerance");
        }
    }
    if (iteration > model->options.max_iterations) {
        return fail(QBD_CONVERGENCE,
                    "minimal nonnegative rate-matrix iteration reached max_iterations");
    }
    diagnostics->iterations = iteration;
    diagnostics->last_iteration_delta = delta;
    diagnostics->rate_equation_residual_inf = raw_residual;
    diagnostics->rate_equation_residual_scaled = residual;
    diagnostics->uniformization_rate = uniformization_rate;
    *out = rate;
    return 1;
}

/* Collatz-Wielandt bounds for the Perron root.
 *
 * `upper = max(sum(row) for row in matrix)` in the Python is a PLAIN sum, not
 * an fsum — the only plain one in the file — so this is a plain left-to-right
 * accumulation too. Using fsum here would be more accurate and would disagree. */
static void qbd_perron_bounds(qbd_matrix m, double *lower_out, double *upper_out, int *iterations_out)
{
    int size = m.rows, i, iteration;
    double *vector, *product;
    double lower = 0.0, upper = 0.0;
    if (qbd_max_abs_matrix(m) == 0.0) { *lower_out = 0.0; *upper_out = 0.0; *iterations_out = 0; return; }
    vector = qbd_alloc((size_t)size);
    product = qbd_alloc((size_t)size);
    if (!vector || !product) { *lower_out = 0.0; *upper_out = 0.0; *iterations_out = 0; return; }
    for (i = 0; i < size; i++) vector[i] = 1.0;
    for (i = 0; i < size; i++) {
        double row_sum = 0.0;
        int j;
        for (j = 0; j < size; j++) row_sum += QBD_AT(m, i, j);
        if (i == 0 || row_sum > upper) upper = row_sum;
    }
    for (iteration = 1; iteration <= 10000; iteration++) {
        double scale = 0.0;
        int have_ratio = 0;
        qbd_matrix_vector_multiply(m, vector, product);
        for (i = 0; i < size; i++) {
            if (vector[i] > 1.0e-300) {
                double ratio = product[i] / vector[i];
                if (!have_ratio) { lower = upper = ratio; have_ratio = 1; }
                else {
                    if (ratio < lower) lower = ratio;
                    if (ratio > upper) upper = ratio;
                }
            }
        }
        for (i = 0; i < size; i++) if (i == 0 || product[i] > scale) scale = product[i];
        if (scale <= 0.0) { *lower_out = 0.0; *upper_out = 0.0; *iterations_out = iteration; return; }
        for (i = 0; i < size; i++) {
            double value = product[i] / scale;
            vector[i] = value > 1.0e-300 ? value : 1.0e-300;
        }
        {
            double bound = upper > 1.0 ? upper : 1.0;
            if (upper - lower <= 1.0e-13 * bound) {
                *lower_out = lower; *upper_out = upper; *iterations_out = iteration; return;
            }
        }
    }
    *lower_out = lower; *upper_out = upper; *iterations_out = 10000;
}

/* -------------------------------------------------------------- solution */

typedef struct {
    int     level_at_least;
    double  probability;
} qbd_tail;

typedef struct {
    qbd_stability stability;
    qbd_matrix    rate;
    qbd_iteration_diagnostics iteration;
    int     boundary_phases, interior_phases;
    double *pi0, *pi1;
    double  probability_empty;
    double  mean_level, second_moment, variance, standard_deviation;
    qbd_tail *tails;
    int     tail_count;
    double  boundary_balance_residual_scaled;
    double  normalization_residual;
    double  rate_spectral_radius_certificate_upper_bound;
    double  identity_minus_rate_condition_inf_estimate;
    double  rate_spectral_radius_lower_bound;
    double  rate_spectral_radius_upper_bound;
    int     spectral_radius_iterations;
} qbd_result;

static double qbd_rounded_nonnegative(double value, double tolerance)
{
    return (value < 0.0 && value >= -tolerance) ? 0.0 : value;
}

static qbd_matrix qbd_assemble_boundary_kernel(const qbd_model *model, qbd_matrix rate)
{
    int m0 = QBD_BOUNDARY_PHASES(model), m = QBD_INTERIOR_PHASES(model), i, j;
    qbd_matrix lower_right = qbd_add2(model->b11, qbd_multiply(rate, model->a_down));
    qbd_matrix kernel = qbd_zeros(m0 + m, m0 + m);
    if (!lower_right.a || !kernel.a) return kernel;
    for (i = 0; i < m0; i++) {
        for (j = 0; j < m0; j++) QBD_AT(kernel, i, j) = QBD_AT(model->b00, i, j);
        for (j = 0; j < m; j++)  QBD_AT(kernel, i, m0 + j) = QBD_AT(model->b01, i, j);
    }
    for (i = 0; i < m; i++) {
        for (j = 0; j < m0; j++) QBD_AT(kernel, m0 + i, j) = QBD_AT(model->b10, i, j);
        for (j = 0; j < m; j++)  QBD_AT(kernel, m0 + i, m0 + j) = QBD_AT(lower_right, i, j);
    }
    return kernel;
}

static int qbd_solve(const qbd_model *model, qbd_result *result)
{
    int m0 = QBD_BOUNDARY_PHASES(model), size = QBD_INTERIOR_PHASES(model), i, j;
    double *one, *interior_mass_weights, *rate_times_mass_weights, *normalization;
    double *boundary_solution, *scratch;
    qbd_matrix identity_minus_rate, fundamental, boundary_kernel;
    qbd_matrix fundamental_squared, fundamental_cubed, full_boundary_row;
    double negativity_tolerance, minimum_fundamental_entry, contraction_upper_bound;
    double fundamental_norm, condition_estimate, total_mass, minimum_probability;
    double factorial_second, variance_scale, variance_roundoff_tolerance, raw_variance;
    bnet_fsum accumulator;

    memset(result, 0, sizeof *result);
    result->boundary_phases = m0;
    result->interior_phases = size;
    if (!qbd_stability_diagnostics(model, &result->stability)) return 0;
    if (strcmp(result->stability.classification, "positive_recurrent") != 0) {
        return fail(QBD_STABILITY, "a stationary probability distribution does not exist under "
                                   "the strict QBD drift criterion");
    }
    if (!qbd_compute_rate_matrix(model, &result->rate, &result->iteration)) return 0;

    one = qbd_alloc((size_t)size);
    interior_mass_weights = qbd_alloc((size_t)size);
    rate_times_mass_weights = qbd_alloc((size_t)size);
    normalization = qbd_alloc((size_t)(m0 + size));
    boundary_solution = qbd_alloc((size_t)(m0 + size));
    scratch = qbd_alloc((size_t)(m0 + size));
    if (!one || !interior_mass_weights || !rate_times_mass_weights
        || !normalization || !boundary_solution || !scratch) return 0;
    for (i = 0; i < size; i++) one[i] = 1.0;

    identity_minus_rate = qbd_subtract(qbd_identity(size), result->rate);
    if (!identity_minus_rate.a) return 0;
    if (!qbd_inverse(identity_minus_rate, &fundamental)) {
        /* The Python re-raises as a numerical failure with its own words. */
        g_error_kind = QBD_OK;
        return fail(QBD_NUMERICAL, "I - R is singular or numerically rank deficient");
    }
    negativity_tolerance = 100.0 * model->options.generator_tolerance;
    minimum_fundamental_entry = fundamental.a[0];
    for (i = 1; i < size * size; i++) {
        if (fundamental.a[i] < minimum_fundamental_entry) minimum_fundamental_entry = fundamental.a[i];
    }
    if (minimum_fundamental_entry < -negativity_tolerance) {
        return fail(QBD_NUMERICAL, "(I - R)^-1 contains a materially negative entry");
    }
    for (i = 0; i < size * size; i++) {
        fundamental.a[i] = qbd_rounded_nonnegative(fundamental.a[i], negativity_tolerance);
    }
    qbd_matrix_vector_multiply(fundamental, one, interior_mass_weights);
    for (i = 0; i < size; i++) {
        if (interior_mass_weights[i] <= 0.0) {
            return fail(QBD_NUMERICAL, "(I - R)^-1 1 is not strictly positive");
        }
    }
    qbd_matrix_vector_multiply(result->rate, interior_mass_weights, rate_times_mass_weights);
    contraction_upper_bound = rate_times_mass_weights[0] / interior_mass_weights[0];
    for (i = 1; i < size; i++) {
        double ratio = rate_times_mass_weights[i] / interior_mass_weights[i];
        if (ratio > contraction_upper_bound) contraction_upper_bound = ratio;
    }
    if (contraction_upper_bound >= 1.0) {
        return fail(QBD_NUMERICAL,
                    "the computed rate matrix does not have a strict spectral-radius certificate");
    }
    fundamental_norm = qbd_infinity_norm(fundamental);
    condition_estimate = qbd_infinity_norm(identity_minus_rate) * fundamental_norm;
    result->identity_minus_rate_condition_inf_estimate = condition_estimate;
    result->rate_spectral_radius_certificate_upper_bound = contraction_upper_bound;

    for (i = 0; i < m0; i++) normalization[i] = 1.0;
    for (i = 0; i < size; i++) normalization[m0 + i] = interior_mass_weights[i];
    boundary_kernel = qbd_assemble_boundary_kernel(model, result->rate);
    if (!boundary_kernel.a) return 0;
    if (!qbd_solve_left_null(boundary_kernel, normalization, 1, negativity_tolerance,
                             boundary_solution, NULL)) return 0;

    minimum_probability = boundary_solution[0];
    for (i = 1; i < m0 + size; i++) {
        if (boundary_solution[i] < minimum_probability) minimum_probability = boundary_solution[i];
    }
    if (minimum_probability < -negativity_tolerance) {
        return fail(QBD_INPUT, "stationary boundary solution contains a negative probability; "
                               "the QBD may be reducible or ill-conditioned");
    }
    result->pi0 = qbd_alloc((size_t)m0);
    result->pi1 = qbd_alloc((size_t)size);
    if (!result->pi0 || !result->pi1) return 0;
    for (i = 0; i < m0; i++) {
        result->pi0[i] = qbd_rounded_nonnegative(boundary_solution[i], negativity_tolerance);
    }
    for (i = 0; i < size; i++) {
        result->pi1[i] = qbd_rounded_nonnegative(boundary_solution[m0 + i], negativity_tolerance);
    }

    /* fsum((fsum(pi0), dot(pi1, weights))) — a two-term fsum over the inner
     * exact sums, which is what the Python writes. */
    bnet_fsum_init(&accumulator);
    {
        bnet_fsum inner;
        bnet_fsum_init(&inner);
        for (i = 0; i < m0; i++) bnet_fsum_add(&inner, result->pi0[i]);
        bnet_fsum_add(&accumulator, bnet_fsum_value(&inner));
        bnet_fsum_add(&accumulator, qbd_dot(result->pi1, interior_mass_weights, size));
    }
    total_mass = bnet_fsum_value(&accumulator);
    if (!isfinite(total_mass) || total_mass <= 0.0) {
        return fail(QBD_INPUT, "stationary normalization is not positive and finite");
    }
    for (i = 0; i < m0; i++) result->pi0[i] /= total_mass;
    for (i = 0; i < size; i++) result->pi1[i] /= total_mass;
    bnet_fsum_init(&accumulator);
    {
        bnet_fsum inner;
        bnet_fsum_init(&inner);
        for (i = 0; i < m0; i++) bnet_fsum_add(&inner, result->pi0[i]);
        bnet_fsum_add(&accumulator, bnet_fsum_value(&inner));
        bnet_fsum_add(&accumulator, qbd_dot(result->pi1, interior_mass_weights, size));
    }
    result->normalization_residual = fabs(bnet_fsum_value(&accumulator) - 1.0);

    /* Boundary balance residual, on the un-normalised concatenation the Python
     * forms as `pi0 + pi1` after normalisation. */
    full_boundary_row = qbd_zeros(1, m0 + size);
    if (!full_boundary_row.a) return 0;
    for (i = 0; i < m0; i++)   QBD_AT(full_boundary_row, 0, i) = result->pi0[i];
    for (i = 0; i < size; i++) QBD_AT(full_boundary_row, 0, m0 + i) = result->pi1[i];
    qbd_row_vector_multiply(full_boundary_row.a, boundary_kernel, scratch);
    {
        double boundary_residual = qbd_max_abs_vector(scratch, m0 + size);
        double kernel_norm = qbd_infinity_norm(boundary_kernel);
        if (kernel_norm < QBD_DBL_MIN) kernel_norm = QBD_DBL_MIN;
        result->boundary_balance_residual_scaled = boundary_residual / kernel_norm;
    }

    qbd_perron_bounds(result->rate, &result->rate_spectral_radius_lower_bound,
                      &result->rate_spectral_radius_upper_bound,
                      &result->spectral_radius_iterations);

    fundamental_squared = qbd_multiply(fundamental, fundamental);
    fundamental_cubed = qbd_multiply(fundamental_squared, fundamental);
    if (!fundamental_squared.a || !fundamental_cubed.a) return 0;
    {
        double *row = qbd_alloc((size_t)size);
        if (!row) return 0;
        qbd_row_vector_multiply(result->pi1, fundamental_squared, row);
        result->mean_level = qbd_dot(row, one, size);
        qbd_row_vector_multiply(result->pi1,
                                qbd_scale(qbd_multiply(result->rate, fundamental_cubed), 2.0), row);
        factorial_second = qbd_dot(row, one, size);
    }
    result->second_moment = result->mean_level + factorial_second;
    raw_variance = result->second_moment - result->mean_level * result->mean_level;
    variance_scale = 1.0;
    if (fabs(result->second_moment) > variance_scale) variance_scale = fabs(result->second_moment);
    if (result->mean_level * result->mean_level > variance_scale) {
        variance_scale = result->mean_level * result->mean_level;
    }
    {
        double a = 100.0 * QBD_DBL_EPSILON
                 * (condition_estimate > 1.0 ? condition_estimate : 1.0) * variance_scale;
        double b = 10.0 * model->options.residual_tolerance * variance_scale;
        variance_roundoff_tolerance = a > b ? a : b;
    }
    if (raw_variance < -variance_roundoff_tolerance) {
        return fail(QBD_NUMERICAL, "computed queue-length variance is materially negative");
    }
    result->variance = raw_variance > 0.0 ? raw_variance : 0.0;
    result->standard_deviation = sqrt(result->variance);

    bnet_fsum_init(&accumulator);
    for (i = 0; i < m0; i++) bnet_fsum_add(&accumulator, result->pi0[i]);
    result->probability_empty = bnet_fsum_value(&accumulator);

    /* Tail probabilities, walking the levels in ascending order and carrying
     * the vector forward with matrix powers, as the Python does. */
    result->tail_count = model->options.tail_count;
    result->tails = (qbd_tail *)calloc((size_t)(result->tail_count ? result->tail_count : 1),
                                       sizeof(qbd_tail));
    if (!result->tails) return fail(QBD_NUMERICAL, "out of memory");
    {
        double *tail_vector = qbd_alloc((size_t)size);
        double *next = qbd_alloc((size_t)size);
        int current_level = 1;
        if (!tail_vector || !next) return 0;
        for (i = 0; i < size; i++) tail_vector[i] = result->pi1[i];
        for (j = 0; j < result->tail_count; j++) {
            int requested = model->options.tail_levels[j];
            double probability;
            result->tails[j].level_at_least = requested;
            if (requested == 0) { result->tails[j].probability = 1.0; continue; }
            if (current_level < requested) {
                qbd_matrix step = qbd_power(result->rate, requested - current_level);
                if (!step.a) return 0;
                qbd_row_vector_multiply(tail_vector, step, next);
                for (i = 0; i < size; i++) tail_vector[i] = next[i];
                current_level = requested;
            }
            probability = qbd_dot(tail_vector, interior_mass_weights, size);
            result->tails[j].probability = probability > 0.0 ? probability : 0.0;
        }
    }
    return 1;
}

/* ---------------------------------------------------------------- output */

#define QBD_LABEL_WIDTH 38
#define QBD_VALUE_WIDTH 14

/* Column widths are CHARACTER counts in the Python (f"{s:<38}"); printf counts
 * bytes. The model name is the only user-supplied string that reaches a column
 * here, but counting code points costs nothing and removes the question. */
static int qbd_display_width(const char *s)
{
    int width = 0;
    while (*s) { if ((*s & 0xC0) != 0x80) width++; s++; }
    return width;
}

static void qbd_print_row(const char *label, const char *value)
{
    int label_pad = QBD_LABEL_WIDTH - qbd_display_width(label);
    int value_pad = QBD_VALUE_WIDTH - qbd_display_width(value);
    if (label_pad < 0) label_pad = 0;
    if (value_pad < 0) value_pad = 0;
    printf("%s%*s%*s%s\n", label, label_pad, "", value_pad, "", value);
}

static const char *qbd_fmt(char *buffer, size_t size, double value)
{
    if (!isfinite(value)) { snprintf(buffer, size, "-"); return buffer; }
    snprintf(buffer, size, "%.6f", value);
    return buffer;
}

static const char *qbd_fmt_residual(char *buffer, size_t size, double value)
{
    if (!isfinite(value)) { snprintf(buffer, size, "-"); return buffer; }
    snprintf(buffer, size, "%.6e", value);
    return buffer;
}

static const char *qbd_human_number(char *buffer, size_t size, double value)
{
    snprintf(buffer, size, "%.17g", value);
    return buffer;
}

/* urllib.parse.quote(text, safe="-._~") — the Python's `_human_token`. */
static void qbd_percent_encode(char *out, size_t size, const char *text)
{
    static const char *hex = "0123456789ABCDEF";
    size_t used = 0;
    for (; *text && used + 4 < size; text++) {
        unsigned char c = (unsigned char)*text;
        int unreserved = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
                       || (c >= '0' && c <= '9')
                       || c == '-' || c == '.' || c == '_' || c == '~';
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

static void qbd_print_count(char *out, size_t size, int number, const char *noun)
{
    snprintf(out, size, "%d %s%s", number, noun, number == 1 ? "" : "s");
}

static void qbd_print_human(const qbd_model *model, const qbd_result *result)
{
    char value[64], label[128], boundary_text[64], interior_text[64];
    const char *name = model->has_name ? model->name : "unnamed";
    char encoded[1024];
    int i;

    printf("Exact Matrix-Analytic QBD\n");
    printf("Model layer: queueing process (exact)\n");
    printf("Evidence: matrix-geometric stationary distribution of the "
           "level-independent QBD; the residuals below are evidence that it was "
           "solved accurately, not that the QBD matches the network\n");
    printf("Model: %s\n", name);
    qbd_print_count(boundary_text, sizeof boundary_text, result->boundary_phases, "boundary phase");
    qbd_print_count(interior_text, sizeof interior_text, result->interior_phases, "interior phase");
    printf("Process: continuous-time QBD, %s, %s\n", boundary_text, interior_text);
    printf("Stability: positive recurrent\n");
    printf("Algorithm: monotone uniformized functional iteration, %ld iterations\n",
           result->iteration.iterations);
    printf("\n");

    qbd_print_row("Quantity", "value");
    for (i = 0; i < QBD_LABEL_WIDTH + QBD_VALUE_WIDTH; i++) putchar('-');
    putchar('\n');
    qbd_print_row("Mean level", qbd_fmt(value, sizeof value, result->mean_level));
    qbd_print_row("Second moment of level", qbd_fmt(value, sizeof value, result->second_moment));
    qbd_print_row("Variance of level", qbd_fmt(value, sizeof value, result->variance));
    qbd_print_row("Standard deviation of level", qbd_fmt(value, sizeof value, result->standard_deviation));
    qbd_print_row("P(level = 0)", qbd_fmt(value, sizeof value, result->probability_empty));
    qbd_print_row("Mean upward rate", qbd_fmt(value, sizeof value, result->stability.mean_upward_rate));
    qbd_print_row("Mean downward rate", qbd_fmt(value, sizeof value, result->stability.mean_downward_rate));
    qbd_print_row("Net level drift", qbd_fmt(value, sizeof value, result->stability.net_level_drift));
    printf("\n");

    if (result->tail_count > 0) {
        qbd_print_row("Level", "P(level >= L)");
        for (i = 0; i < QBD_LABEL_WIDTH + QBD_VALUE_WIDTH; i++) putchar('-');
        putchar('\n');
        for (i = 0; i < result->tail_count; i++) {
            snprintf(label, sizeof label, "%d", result->tails[i].level_at_least);
            qbd_print_row(label, qbd_fmt(value, sizeof value, result->tails[i].probability));
        }
        printf("\n");
    }

    qbd_print_row("Diagnostic", "value");
    for (i = 0; i < QBD_LABEL_WIDTH + QBD_VALUE_WIDTH; i++) putchar('-');
    putchar('\n');
    qbd_print_row("Rate-equation residual (inf)",
                  qbd_fmt_residual(value, sizeof value, result->iteration.rate_equation_residual_inf));
    qbd_print_row("Boundary balance residual (scaled)",
                  qbd_fmt_residual(value, sizeof value, result->boundary_balance_residual_scaled));
    qbd_print_row("Normalization residual",
                  qbd_fmt_residual(value, sizeof value, result->normalization_residual));
    qbd_print_row("Spectral radius of R, upper bound",
                  qbd_fmt(value, sizeof value, result->rate_spectral_radius_certificate_upper_bound));
    qbd_print_row("Condition estimate of I - R (inf)",
                  qbd_fmt(value, sizeof value, result->identity_minus_rate_condition_inf_estimate));
    printf("\n");
    printf("The spectral radius bound is a certificate: a value below 1 proves the "
           "matrix-geometric tail converges.\n");

    /* Machine records, last and byte-identical to the Python's. */
    printf("\n");
    printf("QNET_QBD_EVIDENCE_V1 key=status value=ok\n");
    printf("QNET_QBD_METRIC_V1 metric=mean_level estimate=%s\n",
           qbd_human_number(value, sizeof value, result->mean_level));
    printf("QNET_QBD_METRIC_V1 metric=second_moment_level estimate=%s\n",
           qbd_human_number(value, sizeof value, result->second_moment));
    printf("QNET_QBD_METRIC_V1 metric=variance_level estimate=%s\n",
           qbd_human_number(value, sizeof value, result->variance));
    printf("QNET_QBD_METRIC_V1 metric=standard_deviation_level estimate=%s\n",
           qbd_human_number(value, sizeof value, result->standard_deviation));
    printf("QNET_QBD_METRIC_V1 metric=probability_empty estimate=%s\n",
           qbd_human_number(value, sizeof value, result->probability_empty));
    for (i = 0; i < result->tail_count; i++) {
        printf("QNET_QBD_METRIC_V1 metric=tail_probability level=%d estimate=%s\n",
               result->tails[i].level_at_least,
               qbd_human_number(value, sizeof value, result->tails[i].probability));
    }
    printf("QNET_QBD_EVIDENCE_V1 key=process value=continuous_time_qbd\n");
    qbd_percent_encode(encoded, sizeof encoded, name);
    printf("QNET_QBD_EVIDENCE_V1 key=name value=%s\n", encoded);
    printf("QNET_QBD_EVIDENCE_V1 key=stability_classification value=positive_recurrent\n");
    printf("QNET_QBD_EVIDENCE_V1 key=mean_upward_rate value=%s\n",
           qbd_human_number(value, sizeof value, result->stability.mean_upward_rate));
    printf("QNET_QBD_EVIDENCE_V1 key=mean_downward_rate value=%s\n",
           qbd_human_number(value, sizeof value, result->stability.mean_downward_rate));
    printf("QNET_QBD_EVIDENCE_V1 key=net_level_drift value=%s\n",
           qbd_human_number(value, sizeof value, result->stability.net_level_drift));
    printf("QNET_QBD_EVIDENCE_V1 key=algorithm value=monotone_uniformized_functional_iteration\n");
    printf("QNET_QBD_EVIDENCE_V1 key=iterations value=%ld\n", result->iteration.iterations);
    printf("QNET_QBD_EVIDENCE_V1 key=rate_equation_residual_inf value=%s\n",
           qbd_human_number(value, sizeof value, result->iteration.rate_equation_residual_inf));
    printf("QNET_QBD_EVIDENCE_V1 key=boundary_balance_residual_scaled value=%s\n",
           qbd_human_number(value, sizeof value, result->boundary_balance_residual_scaled));
    printf("QNET_QBD_EVIDENCE_V1 key=normalization_residual value=%s\n",
           qbd_human_number(value, sizeof value, result->normalization_residual));
    printf("QNET_QBD_EVIDENCE_V1 key=spectral_radius_certificate_upper_bound value=%s\n",
           qbd_human_number(value, sizeof value, result->rate_spectral_radius_certificate_upper_bound));
    printf("QNET_QBD_EVIDENCE_V1 key=identity_minus_rate_condition_inf_estimate value=%s\n",
           qbd_human_number(value, sizeof value, result->identity_minus_rate_condition_inf_estimate));
}

/* One failure, reported in whichever form was requested, on stdout with exit
 * status 2 — exactly what qbd_solver.py does. */
static void qbd_report_error(int want_json)
{
    const char *code = qbd_error_code_name(g_error_kind);
    if (want_json) {
        printf("{\n  \"status\": \"error\",\n  \"engine\": \"c\",\n");
        printf("  \"error\": {\"code\": \"%s\", \"message\": \"", code);
        {
            const char *scan = g_error_message;
            for (; *scan; scan++) {
                if (*scan == '"' || *scan == '\\') putchar('\\');
                putchar(*scan);
            }
        }
        printf("\"}\n}\n");
        return;
    }
    {
        char encoded_code[128], encoded_message[1024];
        printf("Exact Matrix-Analytic QBD\n");
        printf("Solver error [%s]: %s\n\n", code, g_error_message);
        qbd_percent_encode(encoded_code, sizeof encoded_code, code);
        qbd_percent_encode(encoded_message, sizeof encoded_message, g_error_message);
        printf("QNET_QBD_ERROR_V1 code=%s message=%s\n", encoded_code, encoded_message);
    }
}

static void usage(FILE *out, const char *program)
{
    fprintf(out,
        "usage: %s <model.json|-> [--json]\n"
        "\n"
        "Exact stationary distribution of a level-independent continuous-time QBD\n"
        "(C engine). Reads the same document qbd_solver.py reads and prints\n"
        "byte-identical output.\n"
        "\n"
        "  --json        write a structured result instead of the report\n"
        "  --version     print the engine identity and exit\n", program);
}

static void qbd_write_json(FILE *out, const qbd_model *model, const qbd_result *result)
{
    char buffer[64];
    int i;
    fprintf(out, "{\n  \"process\": \"continuous_time_qbd\",\n");
    fprintf(out, "  \"status\": \"ok\",\n  \"engine\": \"c\",\n");
    if (model->has_name) fprintf(out, "  \"name\": \"%s\",\n", model->name);
    fprintf(out, "  \"dimensions\": {\"boundary_phases\": %d, \"interior_phases\": %d},\n",
            result->boundary_phases, result->interior_phases);
    fprintf(out, "  \"stability\": {\"classification\": \"%s\", \"mean_upward_rate\": %s",
            result->stability.classification,
            qbd_repr(buffer, sizeof buffer, result->stability.mean_upward_rate));
    fprintf(out, ", \"mean_downward_rate\": %s",
            qbd_repr(buffer, sizeof buffer, result->stability.mean_downward_rate));
    fprintf(out, ", \"net_level_drift\": %s},\n",
            qbd_repr(buffer, sizeof buffer, result->stability.net_level_drift));
    fprintf(out, "  \"queue_length\": {\"mean\": %s",
            qbd_repr(buffer, sizeof buffer, result->mean_level));
    fprintf(out, ", \"second_moment\": %s", qbd_repr(buffer, sizeof buffer, result->second_moment));
    fprintf(out, ", \"variance\": %s", qbd_repr(buffer, sizeof buffer, result->variance));
    fprintf(out, ", \"standard_deviation\": %s},\n",
            qbd_repr(buffer, sizeof buffer, result->standard_deviation));
    fprintf(out, "  \"tail_probabilities\": [");
    for (i = 0; i < result->tail_count; i++) {
        fprintf(out, "%s{\"level_at_least\": %d, \"probability\": %s}", i ? ", " : "",
                result->tails[i].level_at_least,
                qbd_repr(buffer, sizeof buffer, result->tails[i].probability));
    }
    fprintf(out, "],\n  \"diagnostics\": {\"algorithm\": \"monotone_uniformized_functional_iteration\"");
    fprintf(out, ", \"iterations\": %ld", result->iteration.iterations);
    fprintf(out, ", \"rate_equation_residual_inf\": %s",
            qbd_repr(buffer, sizeof buffer, result->iteration.rate_equation_residual_inf));
    fprintf(out, ", \"boundary_balance_residual_scaled\": %s",
            qbd_repr(buffer, sizeof buffer, result->boundary_balance_residual_scaled));
    fprintf(out, ", \"normalization_residual\": %s",
            qbd_repr(buffer, sizeof buffer, result->normalization_residual));
    fprintf(out, ", \"rate_spectral_radius_certificate_upper_bound\": %s",
            qbd_repr(buffer, sizeof buffer, result->rate_spectral_radius_certificate_upper_bound));
    fprintf(out, ", \"identity_minus_rate_condition_inf_estimate\": %s",
            qbd_repr(buffer, sizeof buffer, result->identity_minus_rate_condition_inf_estimate));
    fprintf(out, ", \"rate_spectral_radius_lower_bound\": %s",
            qbd_repr(buffer, sizeof buffer, result->rate_spectral_radius_lower_bound));
    fprintf(out, ", \"rate_spectral_radius_upper_bound\": %s",
            qbd_repr(buffer, sizeof buffer, result->rate_spectral_radius_upper_bound));
    fprintf(out, ", \"spectral_radius_iterations\": %d}\n}\n",
            result->spectral_radius_iterations);
}

int main(int argc, char **argv)
{
    const char *path = NULL;
    /* The Python's default output is pretty JSON and `--human` selects the
     * report; the GUI passes `--human`. Matching the flag set exactly is part
     * of the contract — a person who runs one binary by hand and then the other
     * must not get two different shapes. */
    int want_json = 1, i, exit_code = 0;
    const char *output_path = NULL;
    bnet_json document;
    qbd_model model;
    qbd_result result;

    /* Zeroed here, not just in qbd_solve: the cleanup at `done:` runs for a
     * document that never reached the solver, and freeing an uninitialised
     * pointer aborts the process after a perfectly good error message. */
    memset(&model, 0, sizeof model);
    memset(&result, 0, sizeof result);

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--json") == 0 || strcmp(argv[i], "--compact") == 0) want_json = 1;
        else if (strcmp(argv[i], "--human") == 0) want_json = 0;
        else if (strcmp(argv[i], "-o") == 0 || strcmp(argv[i], "--output") == 0) {
            if (++i >= argc) { fprintf(stderr, "%s: -o needs a path\n", argv[0]); return 2; }
            output_path = argv[i];
        }
        else if (strcmp(argv[i], "--version") == 0) {
            printf("bna_qbd (Qnet matrix-analytic QBD, C engine) 1.0.0\n");
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
        fail(QBD_INPUT, "%s", document.error);
        qbd_report_error(want_json);
        bnet_json_free(&document);
        return 2;
    }
    if (!qbd_parse_model(&document, &model) || !qbd_solve(&model, &result)) {
        qbd_report_error(want_json);
        exit_code = 2;
        goto done;
    }
    if (output_path) {
        FILE *out = fopen(output_path, "w");
        if (!out) {
            fprintf(stderr, "could not write %s\n", output_path);
            exit_code = 2;
            goto done;
        }
        qbd_write_json(out, &model, &result);
        fclose(out);
    }
    if (want_json) qbd_write_json(stdout, &model, &result);
    else           qbd_print_human(&model, &result);

done:
    free(model.options.tail_levels);
    free(result.tails);
    qbd_release_all();
    bnet_json_free(&document);
    return exit_code;
}
