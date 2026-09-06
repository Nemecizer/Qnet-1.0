/*
 * bnet_fsum.h — CPython's `math.fsum`, in C. Header-only.
 *
 * Shewchuk's exact partial-sums algorithm, the same one CPython's
 * mathmodule.c implements: every intermediate is kept as a list of
 * non-overlapping partial sums, so the result is the correctly rounded sum of
 * the inputs regardless of their order or magnitude.
 *
 * It is here because the C solver engines must agree with their Python
 * counterparts BIT FOR BIT, and the Python side uses math.fsum at the points
 * where a plain accumulation would let ordering change a validation outcome —
 * a routing row that sums to 1 + 1e-16, a traffic-equation residual compared
 * against a tolerance. Using a plain sum in C there would make the two engines
 * disagree on inputs that sit exactly on such a boundary. Compensated
 * (Kahan/Neumaier) summation is not enough: it is nearly always right, and
 * "nearly" is what would make the disagreement rare and therefore invisible.
 *
 * The partials array is fixed at 64 entries. That is far beyond what any
 * summation here needs — the count is bounded by the number of distinct binary
 * exponents in play, not by the number of terms — and overflow of it is
 * reported rather than ignored.
 */

#ifndef BNET_FSUM_H
#define BNET_FSUM_H

#include <math.h>

#define BNET_FSUM_MAX_PARTIALS 64

typedef struct {
    double partials[BNET_FSUM_MAX_PARTIALS];
    int    count;
    int    overflowed;      /* set if the partials array filled up */
    double special;         /* running total of inf/nan terms */
    int    have_special;
} bnet_fsum;

static inline void bnet_fsum_init(bnet_fsum *s)
{
    s->count = 0;
    s->overflowed = 0;
    s->special = 0.0;
    s->have_special = 0;
}

static inline void bnet_fsum_add(bnet_fsum *s, double x)
{
    int i, j = 0;
    if (!isfinite(x)) {
        /* CPython accumulates specials separately and lets the usual
         * inf + (-inf) = nan rule decide the outcome. */
        s->special = s->have_special ? s->special + x : x;
        s->have_special = 1;
        return;
    }
    for (i = 0; i < s->count; i++) {
        double y = s->partials[i];
        double hi, lo;
        if (fabs(x) < fabs(y)) { double t = x; x = y; y = t; }
        hi = x + y;
        lo = y - (hi - x);
        if (lo != 0.0) {
            s->partials[j++] = lo;
        }
        x = hi;
    }
    if (j >= BNET_FSUM_MAX_PARTIALS) { s->overflowed = 1; return; }
    s->partials[j] = x;
    s->count = j + 1;
}

static inline double bnet_fsum_value(const bnet_fsum *s)
{
    /* Sum the partials from smallest to largest with one round-half-even
     * correction, exactly as CPython's tail does. */
    double hi = 0.0, lo = 0.0, x, y;
    int i = s->count;
    if (s->have_special) return s->special;
    if (i == 0) return 0.0;
    hi = s->partials[--i];
    while (i > 0) {
        x = hi;
        y = s->partials[--i];
        hi = x + y;
        lo = y - (hi - x);
        if (lo != 0.0) break;
    }
    if (i > 0 && ((lo < 0.0 && s->partials[i - 1] < 0.0) ||
                  (lo > 0.0 && s->partials[i - 1] > 0.0))) {
        y = lo * 2.0;
        x = hi + y;
        if (y == x - hi) hi = x;
    }
    return hi;
}

/* Convenience for the common case: an array, summed exactly. */
static inline double bnet_fsum_array(const double *values, int count)
{
    bnet_fsum s;
    int i;
    bnet_fsum_init(&s);
    for (i = 0; i < count; i++) bnet_fsum_add(&s, values[i]);
    return bnet_fsum_value(&s);
}

#endif /* BNET_FSUM_H */
