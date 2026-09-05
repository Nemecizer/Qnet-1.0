/*
 * gen_symmetric.c
 *
 * Generates an input file for a symmetric RBM as described in Section 4
 * of Blanchet, Chen, Glynn, Si (2021).
 *
 * For given dimension d and parameter beta:
 *   mu = -[1, 1, ..., 1]^T
 *   rho_sigma = -(1 - beta) / (d - 1)
 *   r          = (1 - beta) / (d - 1)
 *   Sigma: diagonal 1, off-diagonal rho_sigma
 *   R:     diagonal 1, off-diagonal -r
 *
 * True steady-state mean: E[Y_i(inf)] = beta / 2
 *
 * Usage: gen_symmetric <d> <beta> <output_file>
 */

#include <stdio.h>
#include <stdlib.h>

int main(int argc, char *argv[])
{
    if (argc < 4) {
        fprintf(stderr, "Usage: %s <d> <beta> <output_file>\n", argv[0]);
        return 1;
    }

    int    d    = atoi(argv[1]);
    double beta = atof(argv[2]);
    const char *outfile = argv[3];

    if (d < 2) { fprintf(stderr, "d must be >= 2\n"); return 1; }
    if (beta <= 0.0 || beta >= 1.0) {
        fprintf(stderr, "beta must be in (0,1)\n");
        return 1;
    }

    double rho_sigma = -(1.0 - beta) / (d - 1);
    double r         =  (1.0 - beta) / (d - 1);

    FILE *f = fopen(outfile, "w");
    if (!f) { fprintf(stderr, "Cannot open %s for writing\n", outfile); return 1; }

    fprintf(f, "# Symmetric RBM: d=%d, beta=%.4f\n", d, beta);
    fprintf(f, "# True E[Y_i(inf)] = beta/2 = %.6f\n", beta / 2.0);
    fprintf(f, "# rho_sigma = %.10f, r = %.10f\n", rho_sigma, r);

    /* Dimension */
    fprintf(f, "%d\n", d);

    /* Drift vector: mu = -1 for all components */
    for (int i = 0; i < d; i++) {
        fprintf(f, "%s%.10f", (i > 0) ? " " : "", -1.0);
    }
    fprintf(f, "\n");

    /* Covariance matrix: Sigma_{ii} = 1, Sigma_{ij} = rho_sigma */
    for (int i = 0; i < d; i++) {
        for (int j = 0; j < d; j++) {
            double val = (i == j) ? 1.0 : rho_sigma;
            fprintf(f, "%s%.10f", (j > 0) ? " " : "", val);
        }
        fprintf(f, "\n");
    }

    /* Reflection matrix: R_{ii} = 1, R_{ij} = -r */
    for (int i = 0; i < d; i++) {
        for (int j = 0; j < d; j++) {
            double val = (i == j) ? 1.0 : -r;
            fprintf(f, "%s%.10f", (j > 0) ? " " : "", val);
        }
        fprintf(f, "\n");
    }

    fclose(f);
    fprintf(stderr, "Generated %s: d=%d, beta=%.4f, E[Y_i]=%.4f\n",
            outfile, d, beta, beta / 2.0);
    return 0;
}
