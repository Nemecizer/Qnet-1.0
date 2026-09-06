/* Exactness, not closeness: each case is one where a left-to-right sum gives a
 * different double, and the expected values come from math.fsum itself. */
#include "../bnet_fsum.h"
#include <stdio.h>

static int failures = 0;

static void expect(double got, double want, const char *what)
{
    if (got != want) { printf("  FAIL %s: got %.17g want %.17g\n", what, got, want); failures++; }
}

int main(void)
{
    printf("bnet_fsum tests\n");
    {   /* The canonical cancellation case: naive summation gives 0.0. */
        static const double v[3] = { 1.0, 1.0e100, -1.0e100 };
        expect(bnet_fsum_array(v, 3), 1.0, "1 + 1e100 - 1e100");
    }
    {   /* Ten tenths: naive gives 0.9999999999999999. */
        double v[10]; int i;
        for (i = 0; i < 10; i++) v[i] = 0.1;
        expect(bnet_fsum_array(v, 10), 1.0, "ten tenths");
    }
    {   /* Ordering must not matter. */
        static const double a[4] = { 1e16, 1.0, -1e16, 1.0 };
        static const double b[4] = { 1.0, 1e16, 1.0, -1e16 };
        expect(bnet_fsum_array(a, 4), 2.0, "1e16 ordering A");
        expect(bnet_fsum_array(b, 4), 2.0, "1e16 ordering B");
    }
    {   /* A routing row that a naive sum would report as > 1. */
        static const double v[3] = { 0.1, 0.2, 0.7 };
        expect(bnet_fsum_array(v, 3), 1.0, "0.1 + 0.2 + 0.7 is exactly 1");
    }
    {   double v[1]; v[0] = 0.0; expect(bnet_fsum_array(v, 1), 0.0, "single zero"); }
    {   expect(bnet_fsum_array(NULL, 0), 0.0, "empty sum is zero"); }
    if (failures) { printf("%d failure(s)\n", failures); return 1; }
    printf("all bnet_fsum tests passed\n");
    return 0;
}
