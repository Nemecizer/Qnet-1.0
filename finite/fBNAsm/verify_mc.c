/*
 * verify_mc.c - Monte Carlo verification of SRBM expected values
 *
 * Simulates the SRBM process and computes expected values empirically.
 * This provides an independent check of the algorithm results.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>

#define MAX_DIM 10

typedef struct {
    int n_dim;
    double *a_vec;
    double *Gamma;
    double *mu;
    double *R;
} SRBMParams;

/* Cholesky decomposition of Gamma to get sqrt(Gamma) */
void cholesky(double *A, double *L, int n) {
    memset(L, 0, n * n * sizeof(double));
    for (int i = 0; i < n; i++) {
        for (int j = 0; j <= i; j++) {
            double sum = A[i * n + j];
            for (int k = 0; k < j; k++) {
                sum -= L[i * n + k] * L[j * n + k];
            }
            if (i == j) {
                L[i * n + j] = sqrt(sum);
            } else {
                L[i * n + j] = sum / L[j * n + j];
            }
        }
    }
}

/* Standard normal random variable (Box-Muller) */
double randn() {
    static int have_spare = 0;
    static double spare;

    if (have_spare) {
        have_spare = 0;
        return spare;
    }

    double u, v, s;
    do {
        u = 2.0 * rand() / RAND_MAX - 1.0;
        v = 2.0 * rand() / RAND_MAX - 1.0;
        s = u * u + v * v;
    } while (s >= 1.0 || s == 0.0);

    s = sqrt(-2.0 * log(s) / s);
    spare = v * s;
    have_spare = 1;
    return u * s;
}

/* Simulate one step of SRBM with reflection using Skorokhod map */
void srbm_step(double *x, const SRBMParams *params, const double *L, double dt) {
    int n = params->n_dim;
    double dW[MAX_DIM];

    /* Generate correlated Brownian increments */
    double Z[MAX_DIM];
    for (int i = 0; i < n; i++) {
        Z[i] = randn() * sqrt(dt);
    }
    for (int i = 0; i < n; i++) {
        dW[i] = 0;
        for (int j = 0; j <= i; j++) {
            dW[i] += L[i * n + j] * Z[j];
        }
    }

    /* Compute drift + diffusion */
    for (int i = 0; i < n; i++) {
        x[i] += params->mu[i] * dt + dW[i];
    }

    /* Apply reflection using iterative projection (Skorokhod-like) */
    int max_iter = 1000;
    double tol = 1e-10;

    for (int iter = 0; iter < max_iter; iter++) {
        int violated = 0;
        double max_violation = 0;

        /* Find the most violated boundary */
        int worst_face = -1;
        for (int k = 0; k < n; k++) {
            if (x[k] < 0 && -x[k] > max_violation) {
                max_violation = -x[k];
                worst_face = 2 * k;
                violated = 1;
            }
            if (x[k] > params->a_vec[k] && (x[k] - params->a_vec[k]) > max_violation) {
                max_violation = x[k] - params->a_vec[k];
                worst_face = 2 * k + 1;
                violated = 1;
            }
        }

        if (!violated || max_violation < tol) break;

        /* Apply minimal reflection to fix worst violation */
        int k = worst_face / 2;
        int is_lower = (worst_face % 2 == 0);

        /* Get the k-th component of reflection vector */
        double v_k = params->R[k * 2 * n + worst_face];

        if (fabs(v_k) < 1e-10) {
            /* Skew reflection: normal component is zero, just clamp */
            if (is_lower) x[k] = 0;
            else x[k] = params->a_vec[k];
        } else {
            /* Compute reflection amount needed */
            double overshoot = is_lower ? -x[k] : (x[k] - params->a_vec[k]);
            double lambda = overshoot / fabs(v_k);

            /* Apply reflection */
            for (int i = 0; i < n; i++) {
                double v_i = params->R[i * 2 * n + worst_face];
                if (is_lower) {
                    x[i] += lambda * v_i;
                } else {
                    x[i] -= lambda * v_i;
                }
            }
        }
    }

    /* Final clamp as safety */
    for (int k = 0; k < n; k++) {
        if (x[k] < 0) x[k] = 0;
        if (x[k] > params->a_vec[k]) x[k] = params->a_vec[k];
    }
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <input_file> [n_steps] [n_samples]\n", argv[0]);
        return 1;
    }

    /* Default simulation parameters */
    int n_steps = 100000;
    int n_samples = 1000;
    double dt = 0.001;

    if (argc >= 3) n_steps = atoi(argv[2]);
    if (argc >= 4) n_samples = atoi(argv[3]);

    /* Read parameters (positional format) */
    FILE *fp = fopen(argv[1], "r");
    if (!fp) {
        fprintf(stderr, "Cannot open %s\n", argv[1]);
        return 1;
    }

    SRBMParams params = {0};

    if (fscanf(fp, "%d", &params.n_dim) != 1 || params.n_dim < 1) {
        fprintf(stderr, "Error: Invalid dimension\n");
        fclose(fp);
        return 1;
    }

    int n = params.n_dim;
    params.mu = calloc(n, sizeof(double));
    params.Gamma = calloc(n * n, sizeof(double));
    params.R = calloc(n * 2 * n, sizeof(double));
    params.a_vec = calloc(n, sizeof(double));

    for (int i = 0; i < n; i++)
        if (fscanf(fp, "%lf", &params.mu[i]) != 1) { fprintf(stderr, "Error reading mu\n"); return 1; }

    for (int i = 0; i < n; i++)
        for (int j = 0; j < n; j++)
            if (fscanf(fp, "%lf", &params.Gamma[i * n + j]) != 1) { fprintf(stderr, "Error reading Gamma\n"); return 1; }

    for (int i = 0; i < n; i++)
        for (int j = 0; j < 2 * n; j++)
            if (fscanf(fp, "%lf", &params.R[i * 2 * n + j]) != 1) { fprintf(stderr, "Error reading R\n"); return 1; }

    for (int i = 0; i < n; i++)
        if (fscanf(fp, "%lf", &params.a_vec[i]) != 1) { fprintf(stderr, "Error reading a_vec\n"); return 1; }

    fclose(fp);

    /* Compute Cholesky decomposition of Gamma */
    double *L = calloc(params.n_dim * params.n_dim, sizeof(double));
    cholesky(params.Gamma, L, params.n_dim);

    /* Initialize random seed */
    srand(time(NULL));

    /* Run Monte Carlo simulation */
    double *sum_x = calloc(params.n_dim, sizeof(double));
    double *sum_x2 = calloc(params.n_dim, sizeof(double));
    int total_samples = 0;

    fprintf(stderr, "Running Monte Carlo: %d steps, %d samples, dt=%g\n",
            n_steps, n_samples, dt);

    for (int sample = 0; sample < n_samples; sample++) {
        /* Initialize at center */
        double x[MAX_DIM];
        for (int i = 0; i < params.n_dim; i++) {
            x[i] = params.a_vec[i] / 2.0;
        }

        /* Burn-in period */
        for (int t = 0; t < n_steps / 2; t++) {
            srbm_step(x, &params, L, dt);
        }

        /* Sampling period */
        for (int t = 0; t < n_steps / 2; t++) {
            srbm_step(x, &params, L, dt);

            /* Collect samples every 100 steps */
            if (t % 100 == 0) {
                for (int i = 0; i < params.n_dim; i++) {
                    sum_x[i] += x[i];
                    sum_x2[i] += x[i] * x[i];
                }
                total_samples++;
            }
        }

        if ((sample + 1) % 100 == 0) {
            fprintf(stderr, "  Completed %d/%d samples\n", sample + 1, n_samples);
        }
    }

    /* Compute and print results */
    printf("Monte Carlo results (%d total samples):\n", total_samples);
    {
        int w = 1;
        for (int t = params.n_dim; t >= 10; t /= 10) w++;
        for (int i = 0; i < params.n_dim; i++) {
            double mean = sum_x[i] / total_samples;
            double var = sum_x2[i] / total_samples - mean * mean;
            double se = sqrt(var / total_samples);
            printf("  E[X_%0*d] = %.6f ± %.6f\n", w, i + 1, mean, 2 * se);
        }
    }

    /* Cleanup */
    free(params.a_vec);
    free(params.Gamma);
    free(params.mu);
    free(params.R);
    free(L);
    free(sum_x);
    free(sum_x2);

    return 0;
}
