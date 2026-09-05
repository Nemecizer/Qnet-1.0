/*
 * gen_tridiag.c
 *
 * Generates an input file for the tridiagonal RBM from the b5 example,
 * scaled to arbitrary dimension d.
 *
 * Parameters (from b5):
 *   Sigma: tridiagonal, diagonal = 1.62, off-diagonal = -0.81
 *   mu:    (-0.1, 0, 0, ..., 0)
 *   R:     lower bidiagonal, diagonal = 1, subdiagonal = -1
 *
 * Usage: gen_tridiag <d> <output_file>
 */

#include <stdio.h>
#include <stdlib.h>

int main(int argc, char *argv[])
{
    if (argc < 3) {
        fprintf(stderr, "Usage: %s <d> <output_file>\n", argv[0]);
        return 1;
    }

    int d = atoi(argv[1]);
    const char *outfile = argv[2];

    if (d < 2) { fprintf(stderr, "d must be >= 2\n"); return 1; }

    double sigma_diag = 1.62;
    double sigma_off  = -0.81;
    double mu_0       = -0.10;

    FILE *f = fopen(outfile, "w");
    if (!f) { fprintf(stderr, "Cannot open %s for writing\n", outfile); return 1; }

    fprintf(f, "# Tridiagonal RBM: d=%d\n", d);
    fprintf(f, "# Sigma: tridiag(%.2f, %.2f, %.2f)\n", sigma_off, sigma_diag, sigma_off);
    fprintf(f, "# mu = (%.2f, 0, ..., 0)\n", mu_0);
    fprintf(f, "# R: bidiag(1, -1)\n");
    fprintf(f, "# Expected E[Y_i(inf)] = 8.1\n");

    /* Dimension */
    fprintf(f, "%d\n", d);

    /* Drift vector: mu = (-0.1, 0, 0, ..., 0) */
    for (int i = 0; i < d; i++) {
        fprintf(f, "%s%.10f", (i > 0) ? " " : "", (i == 0) ? mu_0 : 0.0);
    }
    fprintf(f, "\n");

    /* Covariance matrix: tridiagonal */
    for (int i = 0; i < d; i++) {
        for (int j = 0; j < d; j++) {
            double val = 0.0;
            if (i == j)          val = sigma_diag;
            else if (abs(i - j) == 1) val = sigma_off;
            fprintf(f, "%s%.10f", (j > 0) ? " " : "", val);
        }
        fprintf(f, "\n");
    }

    /* Reflection matrix: lower bidiagonal, diag=1, subdiag=-1 */
    for (int i = 0; i < d; i++) {
        for (int j = 0; j < d; j++) {
            double val = 0.0;
            if (i == j)          val = 1.0;
            else if (i == j + 1) val = -1.0;
            fprintf(f, "%s%.10f", (j > 0) ? " " : "", val);
        }
        fprintf(f, "\n");
    }

    fclose(f);
    fprintf(stderr, "Generated %s: d=%d\n", outfile, d);
    return 0;
}
