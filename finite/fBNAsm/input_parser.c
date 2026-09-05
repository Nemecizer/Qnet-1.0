/*
 * input_parser.c - Input file parser for SRBM solver
 *
 * Positional format (fscanf-based, blank lines ignored):
 *   d                          (dimension)
 *   mu_1 ... mu_d              (drift vector)
 *   Gamma (d rows of d values) (covariance matrix)
 *   R (d rows of 2d values)    (reflection matrix)
 *   a_1 ... a_d                (hypercube dimensions)
 *   degree                     (optional: polynomial approximation degree)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "srbm_types.h"
#include "srbm_solver.h"

/*
 * Parse input file
 */
int parse_input_file(const char *filename, SRBMParams *params) {
    FILE *fp = fopen(filename, "r");
    if (!fp) {
        fprintf(stderr, "Error: Cannot open input file '%s'\n", filename);
        return -1;
    }

    /* Initialize params */
    memset(params, 0, sizeof(SRBMParams));

    /* Read dimension */
    int n_dim;
    if (fscanf(fp, "%d", &n_dim) != 1 || n_dim < 1 || n_dim > MAX_DIM) {
        fprintf(stderr, "Error: Invalid dimension\n");
        fclose(fp);
        return -1;
    }
    params->n_dim = n_dim;

    /* Allocate arrays */
    params->a_vec = (double *)calloc(n_dim, sizeof(double));
    params->Gamma = (double *)calloc(n_dim * n_dim, sizeof(double));
    params->mu = (double *)calloc(n_dim, sizeof(double));
    params->R = (double *)calloc(n_dim * 2 * n_dim, sizeof(double));

    if (!params->a_vec || !params->Gamma || !params->mu || !params->R) {
        fprintf(stderr, "Error: Memory allocation failed\n");
        fclose(fp);
        return -1;
    }

    /* Read drift vector */
    for (int i = 0; i < n_dim; i++) {
        if (fscanf(fp, "%lf", &params->mu[i]) != 1) {
            fprintf(stderr, "Error: Cannot read mu[%d]\n", i);
            fclose(fp);
            return -1;
        }
    }

    /* Read covariance matrix */
    for (int i = 0; i < n_dim; i++) {
        for (int j = 0; j < n_dim; j++) {
            if (fscanf(fp, "%lf", &params->Gamma[i * n_dim + j]) != 1) {
                fprintf(stderr, "Error: Cannot read Gamma[%d][%d]\n", i, j);
                fclose(fp);
                return -1;
            }
        }
    }

    /* Read reflection matrix R (n_dim x 2*n_dim) */
    for (int i = 0; i < n_dim; i++) {
        for (int j = 0; j < 2 * n_dim; j++) {
            if (fscanf(fp, "%lf", &params->R[i * 2 * n_dim + j]) != 1) {
                fprintf(stderr, "Error: Cannot read R[%d][%d]\n", i, j);
                fclose(fp);
                return -1;
            }
        }
    }

    /* Read hypercube dimensions */
    for (int i = 0; i < n_dim; i++) {
        if (fscanf(fp, "%lf", &params->a_vec[i]) != 1) {
            fprintf(stderr, "Error: Cannot read a_vec[%d]\n", i);
            fclose(fp);
            return -1;
        }
    }

    /* Read degree (optional) */
    if (fscanf(fp, "%d", &params->n_approx) != 1) {
        params->n_approx = 0;  /* sentinel: caller should prompt */
    }

    /* Read service rates (optional, for throughput computation) */
    params->service_rates = (double *)calloc(n_dim, sizeof(double));
    params->has_service_rates = 0;
    if (params->service_rates) {
        int got_all = 1;
        for (int i = 0; i < n_dim; i++) {
            if (fscanf(fp, "%lf", &params->service_rates[i]) != 1) {
                got_all = 0;
                break;
            }
        }
        if (got_all) params->has_service_rates = 1;
    }

    /* Read customer class data (optional) */
    params->cc_num_classes = 0;
    {
        char keyword[64] = {0};
        int K = 0;
        if (fscanf(fp, " %63s %d", keyword, &K) == 2
            && strcmp(keyword, "customer_classes") == 0
            && K > 0 && K <= CC_MAX) {
            params->cc_num_classes = K;

            /* alpha_total per station */
            for (int i = 0; i < n_dim; i++)
                fscanf(fp, "%lf", &params->cc_alpha_total[i]);

            /* lambda_k per class */
            for (int k = 0; k < K; k++)
                fscanf(fp, "%lf", &params->cc_lambda[k]);

            /* alpha[k][i] — per-class throughput (K rows x d cols) */
            for (int k = 0; k < K; k++)
                for (int i = 0; i < n_dim; i++)
                    fscanf(fp, "%lf", &params->cc_alpha[k][i]);

            /* mu[k][i] — per-class service rate (K rows x d cols) */
            for (int k = 0; k < K; k++)
                for (int i = 0; i < n_dim; i++)
                    fscanf(fp, "%lf", &params->cc_mu[k][i]);
        }
    }

    fclose(fp);
    return 0;
}

/* Print parameters for debugging */
void print_params(const SRBMParams *params) {
    fprintf(stderr, "SRBM Parameters:\n");
    fprintf(stderr, "  n_dim = %d\n", params->n_dim);
    fprintf(stderr, "  n_approx = %d\n", params->n_approx);

    fprintf(stderr, "  a_vec = [");
    for (int i = 0; i < params->n_dim; i++) {
        fprintf(stderr, "%.4f%s", params->a_vec[i],
                i < params->n_dim - 1 ? ", " : "");
    }
    fprintf(stderr, "]\n");

    fprintf(stderr, "  mu = [");
    for (int i = 0; i < params->n_dim; i++) {
        fprintf(stderr, "%.4f%s", params->mu[i],
                i < params->n_dim - 1 ? ", " : "");
    }
    fprintf(stderr, "]\n");

    fprintf(stderr, "  Gamma:\n");
    for (int i = 0; i < params->n_dim; i++) {
        fprintf(stderr, "    ");
        for (int j = 0; j < params->n_dim; j++) {
            fprintf(stderr, "%8.4f ", params->Gamma[i * params->n_dim + j]);
        }
        fprintf(stderr, "\n");
    }

    fprintf(stderr, "  R:\n");
    for (int i = 0; i < params->n_dim; i++) {
        fprintf(stderr, "    ");
        for (int j = 0; j < 2 * params->n_dim; j++) {
            fprintf(stderr, "%8.4f ", params->R[i * 2 * params->n_dim + j]);
        }
        fprintf(stderr, "\n");
    }
}
