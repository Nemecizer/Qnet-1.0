/* The C stream must BE CPython's stream, not merely resemble it.
 * Expected values were printed by this project's interpreter:
 *   python3 -c "import random; r=random.Random(S); print([r.random() for _ in range(4)])"
 * and are compared bitwise, because "close" is not the property being tested. */
#include "../bnet_pyrandom.h"
#include <stdio.h>
#include <math.h>

static int failures = 0;

static void check_stream(uint64_t seed, const double *expected, int count, const char *what)
{
    bnet_pyrandom r;
    int i;
    bnet_pyrandom_seed_u64(&r, seed);
    for (i = 0; i < count; i++) {
        double got = bnet_pyrandom_double(&r);
        if (got != expected[i]) {
            printf("  FAIL %s draw %d: got %.17g want %.17g\n", what, i, got, expected[i]);
            failures++;
        }
    }
}

int main(void)
{
    /* seed 0 */
    static const double s0[4] = {
        0.8444218515250481, 0.7579544029403025, 0.420571580830845, 0.25891675029296335 };
    /* seed 1 */
    static const double s1[4] = {
        0.13436424411240122, 0.8474337369372327, 0.763774618976614, 0.2550690257394217 };
    /* seed 20260904 — the solver's own default base_seed */
    static const double sd[4] = {
        0.11918340771709279, 0.3973601108863849, 0.8643849902080922, 0.24815198667780725 };
    /* a seed above 2**32, to exercise the two-word key path */
    static const double sw[4] = {
        0.8225316907510454, 0.20196191685618736, 0.6359524796129433, 0.4340654355058259 };

    printf("bnet_pyrandom tests\n");
    check_stream(0, s0, 4, "seed 0");
    check_stream(1, s1, 4, "seed 1");
    check_stream(20260904, sd, 4, "seed 20260904 (solver default)");
    check_stream(1234567890123ULL, sw, 4, "seed 1234567890123 (two-word key)");

    /* derive_seed must agree with the Python helper of the same name. */
    if (bnet_derive_seed(20260904, 0, 0x54494D45ULL) != 3205774083325936370ULL) {
        printf("  FAIL derive_seed(20260904, 0, 'TIME') = %llu\n",
               (unsigned long long)bnet_derive_seed(20260904, 0, 0x54494D45ULL));
        failures++;
    }
    if (bnet_derive_seed(20260904, 0, 0x43484F49ULL) != 16493988551420689874ULL) {
        printf("  FAIL derive_seed(20260904, 0, 'CHOI') = %llu\n",
               (unsigned long long)bnet_derive_seed(20260904, 0, 0x43484F49ULL));
        failures++;
    }

    if (failures) { printf("%d failure(s)\n", failures); return 1; }
    printf("all bnet_pyrandom tests passed\n");
    return 0;
}
