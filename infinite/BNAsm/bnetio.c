/*
 * bnetio.c - I/O functions for BNET solver
 * Updated to use SuiteSparse instead of meschach
 */

#include "bnet.h"
#include <stdio.h>
#include <string.h>
#include <math.h>

double gmax;
int verbosity = 2;  /* Default to full output */
int compact_mode = 0;  /* Compact output mode */
double bnet_means[BNET_MAX_DIM];
int bnet_ndim = 0;

/* Defined in bnet.c — populated by the -P PATH flag below so the
 * solver's internal progress hooks know where to write. */
extern char bnet_progress_path[1024];

#ifndef ANSI_C

FILE **option(argc, argv, print, mode, iterative, bnet_solver, use_lu, regularization_epsilon)
     int argc;
     char *argv[];
     int *print;
     int *mode;
     int *iterative;
     int *bnet_solver;
     int *use_lu;
     double *regularization_epsilon;

#else

FILE **option(int argc,
              char *argv[],
              int *print,
              int *mode,
              int *iterative,
              int *bnet_solver,
              int *use_lu,
              double *regularization_epsilon)
#endif
{
    FILE **fp = (FILE **)malloc((unsigned)2 * sizeof(FILE *));
    int c;

    while (--argc > 0 && (*++argv)[0] == '-')
        while (c = *++argv[0])
            switch (c) {
            case 'V':
                (void)fprintf(stdout, " This is BNET 1.1, C version 1992;\n");
                (void)fprintf(stdout, " please contact dai@isye.gatech.edu for ");
                (void)fprintf(stdout, "possible newer version.\n\n");
                exit(0);
                break;
            case 'v':
                /* -v requires a numeric argument (0, 1, or 2) */
                if (argc > 1 && argv[1][0] != '-') {
                    argc--;
                    argv++;
                    verbosity = atoi(*argv);
                    if (verbosity < 0 || verbosity > 2) {
                        (void)fprintf(stderr, " bnet: verbosity must be 0, 1, or 2\n");
                        exit(1);
                    }
                    /* Skip to end of current arg to break inner loop */
                    while (*argv[0]) argv[0]++;
                    argv[0]--;
                } else {
                    (void)fprintf(stderr, " bnet: -v requires a numeric argument (0, 1, or 2)\n");
                    exit(1);
                }
                break;
            case 'p':
                *print = TRUE;
                break;
            case 'b':
                *bnet_solver = TRUE;
                break;
            case 'l':
                *use_lu = TRUE;
                break;
            case 'r':
                /* -r requires a numeric argument (epsilon value) */
                if (argc > 1 && argv[1][0] != '-') {
                    argc--;
                    argv++;
                    *regularization_epsilon = atof(*argv);
                    if (*regularization_epsilon <= 0.0) {
                        (void)fprintf(stderr, " bnet: regularization epsilon must be positive\n");
                        exit(1);
                    }
                    /* Skip to end of current arg to break inner loop */
                    while (*argv[0]) argv[0]++;
                    argv[0]--;
                } else {
                    (void)fprintf(stderr, " bnet: -r requires a numeric argument (epsilon value)\n");
                    (void)fprintf(stderr, " Example: -r 0.001\n");
                    exit(1);
                }
                break;
            case 'c':
                compact_mode = 1;
                verbosity = 0;  /* suppress all diagnostic output in compact mode */
                break;
            case 'P':
                /* -P PATH : path of the Qnet progress file the solver
                 * appends ticks to. Eats the next argv. */
                if (argc > 1 && argv[1][0] != '-') {
                    argc--;
                    argv++;
                    strncpy(bnet_progress_path, *argv, sizeof(bnet_progress_path) - 1);
                    bnet_progress_path[sizeof(bnet_progress_path) - 1] = '\0';
                    while (*argv[0]) argv[0]++;
                    argv[0]--;
                } else {
                    (void)fprintf(stderr, " bnet: -P requires a file-path argument\n");
                    exit(1);
                }
                break;
            case 'h':
                (void)fprintf(stderr, " Usage: bnet [-h] [-c] [-p] [-b] [-l] [-r epsilon] [-v level] [-V]  ");
                (void)fprintf(stderr, "[data_file [output_file]]\n");
                (void)fprintf(stderr, " Options: \n");
                (void)fprintf(stderr, "  -h print this help message \n");
                (void)fprintf(stderr, "  -c compact output (algorithm name + means only)\n");
                (void)fprintf(stderr, "  -p print the input data \n");
                (void)fprintf(stderr, "  -b use the bnet linear solver\n");
                (void)fprintf(stderr, "  -l use LU factorization (for non-positive-definite matrices)\n");
                (void)fprintf(stderr, "  -r epsilon  apply regularization (add epsilon to diagonal)\n");
                (void)fprintf(stderr, "              Example: -r 0.001\n");
                (void)fprintf(stderr, "  -v level  set verbosity level:\n");
                (void)fprintf(stderr, "            0 = silent (no output)\n");
                (void)fprintf(stderr, "            1 = steps only (Step # messages)\n");
                (void)fprintf(stderr, "            2 = full output (default)\n");
                (void)fprintf(stderr, "  -P file  progress file: write '<total>\\n' header then\n");
                (void)fprintf(stderr, "           one '.' byte per completed basis/matrix row\n");
                (void)fprintf(stderr, "  -V print the current version of bnet\n");
                exit(0);
                break;
            default:
                (void)fprintf(stderr, " bnet: illegal option %c\n", c);
                argc = -1;
                break;
            }
    if (argc < 0 || argc > 2) {
        (void)fprintf(stderr, " Usage: bnet [-h] [-p] [-b] [-v]  ");
        (void)fprintf(stderr, "[data_file [output_file]]\n");
        exit(EXIT_FAILURE);    /* misuse — caller needs to see non-zero */
    } else if (argc == 0) {
        fp[0] = stdin;
        fp[1] = stdout;
    } else if (argc == 1) {
        fp[0] = fopen(*argv, "r");
        if (!fp[0]) {
            fprintf(stderr, " bnet: cannot open input file '%s'\n", *argv);
            exit(EXIT_FAILURE);
        }
        fp[1] = stdout;
    } else if (argc == 2) {
        fp[0] = fopen(*argv, "r");
        if (!fp[0]) {
            fprintf(stderr, " bnet: cannot open input file '%s'\n", *argv);
            exit(EXIT_FAILURE);
        }
        argv++;
        fp[1] = fopen(*argv, "w");
        if (!fp[1]) {
            fprintf(stderr, " bnet: cannot open output file '%s'\n", *argv);
            exit(EXIT_FAILURE);
        }
    }
    return (fp);
}

#ifndef ANSI_C

DMAT *get_covariance(d, input_fp)
     int d;
     FILE *input_fp;
#else

DMAT *get_covariance(int d, FILE *input_fp)

#endif
{
    DMAT *Gamma = dmat_alloc(d, d);
    int i, j;

    for (i = 0; i < d; i++)
        for (j = 0; j < d; j++)
            if (fscanf(input_fp, "%lf", &MAT_AT(Gamma, i, j)) != 1)
                Bneterror("input Gamma is wrong ");
    return (Gamma);
}

#ifndef ANSI_C

DVEC *get_drift(d, input_fp)
     int d;
     FILE *input_fp;
#else
DVEC *get_drift(int d, FILE *input_fp)
#endif
{
    int i;
    DVEC *mu = dvec_alloc(d);

    for (i = 0; i < d; i++)
        if (fscanf(input_fp, "%lf", &VEC_AT(mu, i)) != 1)
            Bneterror("input mu is wrong ");
    return (mu);
}

#ifndef ANSI_C

DMAT *get_reflection(d, input_fp)
     int d;
     FILE *input_fp;

#else
DMAT *get_reflection(int d, FILE *input_fp)
#endif
{
    int i, j;
    DMAT *R = dmat_alloc(d, d);

    for (i = 0; i < d; i++)
        for (j = 0; j < d; j++)
            if (fscanf(input_fp, "%lf", &MAT_AT(R, i, j)) != 1)
                Bneterror("input R is wrong ");
    return (R);
}

#ifndef ANSI_C
void _print_data(output_fp, Gamma, mu, R)
     FILE *output_fp;
     DMAT *Gamma;
     DVEC *mu;
     DMAT *R;

#else
void _print_data(FILE *output_fp,
                 DMAT *Gamma,
                 DVEC *mu,
                 DMAT *R)
#endif
{
    int i, j;
    int d = Gamma->n;

    (void)fprintf(output_fp, "\t dimension = %d\n", d);
    (void)fprintf(output_fp, "\t the covariance matrix Gamma =\n");
    for (i = 0; i < d; i++) {
        for (j = 0; j < d; j++)
            (void)fprintf(output_fp, "\t %5.2f", MAT_AT(Gamma, i, j));
        (void)fprintf(output_fp, "\n");
    }
    (void)fprintf(output_fp, "\n");
    (void)fprintf(output_fp, "\t the drift vector mu =\n");
    for (i = 0; i < d; i++)
        (void)fprintf(output_fp, "\t %5.2f", VEC_AT(mu, i));
    (void)fprintf(output_fp, "\n\n");
    (void)fprintf(output_fp, "\t the reflection matrix R =\n");
    for (i = 0; i < d; i++) {
        for (j = 0; j < d; j++)
            (void)fprintf(output_fp, "\t %5.2f", MAT_AT(R, i, j));
        (void)fprintf(output_fp, "\n");
    }
    (void)fprintf(output_fp, "\n");
}

#ifndef ANSI_C
void print_original_data(output_fp, Gamma, mu, R, n)
     FILE *output_fp;
     DMAT *Gamma;
     DVEC *mu;
     DMAT *R;
     int n;
#else
void print_original_data(FILE *output_fp,
                         DMAT *Gamma,
                         DVEC *mu,
                         DMAT *R,
                         int n)
#endif
{
    (void)fprintf(output_fp,
                  "                   ORIGINAL INPUT DATA                  \n");
    (void)fprintf(output_fp, "\n");
    (void)_print_data(output_fp, Gamma, mu, R);
    (void)fprintf(output_fp, "\t maximum degree of polynomials used = %d\n", n);
}

#ifndef ANSI_C
void print_converted_data(output_fp, Gamma, mu, R, mygamma)
     FILE *output_fp;
     DMAT *Gamma;
     DVEC *mu;
     DMAT *R;
     DVEC *mygamma;
#else
void print_converted_data(FILE *output_fp,
                          DMAT *Gamma,
                          DVEC *mu,
                          DMAT *R,
                          DVEC *mygamma)
#endif
{
    int i, j;
    int d = Gamma->n;

    (void)fprintf(output_fp,
                  "\n                      CONVERTED DATA                  \n");
    (void)fprintf(output_fp, "\n");
    (void)_print_data(output_fp, Gamma, mu, R);
    (void)fprintf(output_fp, "\n");
    (void)fprintf(output_fp, "\t gamma_max = \n");
    (void)fprintf(output_fp, "\t %5.2f\n\n", gmax);
    (void)fprintf(output_fp, "\t the vector gamma =\n");
    for (i = 0; i < d; i++)
        (void)fprintf(output_fp, "\t %5.2f", VEC_AT(mygamma, i));
    (void)fprintf(output_fp, "\n\n");
}

void Output(output_fp, rn, Gamma, c, I, Ib, w, d, n)
     FILE *output_fp;
     poly *rn;
     DMAT *Gamma;
     int **c, **I, **Ib, d, n;
     real **w;
{
    poly first_order_poly;
    void initpoly();
    real *mean, inner();
    int l;

    initpoly(&first_order_poly, 1, c, d);
    mean = dvector(1, d);
    for (l = 1; l <= d; l++) {
        first_order_poly.itr[l + 1] = 1.0;
        /* scale back, see A.1 in Dai's dissertation */
        mean[l] = (real)sqrt((double)MAT_AT(Gamma, l - 1, l - 1)) / gmax *
                  inner(rn, n - 1, &first_order_poly, 1, c, I, Ib, w, d);
        first_order_poly.itr[l + 1] = 0.0;
    }

    /* Store means globally for final printing */
    bnet_ndim = d;
    for (l = 1; l <= d && l <= BNET_MAX_DIM; l++)
        bnet_means[l - 1] = mean[l];

    (void)output_fp; /* means printed later in main */
}

/* scaling(output_fp, Gamma, mu, R, mygamma);  */
#ifndef ANSI_C
void scaling(output_fp, Gamma, mu, R, mygamma)
     FILE *output_fp;
     DMAT *Gamma;
     DVEC *mu;
     DMAT *R;
     DVEC *mygamma;
#else
void scaling(FILE *output_fp,
             DMAT *Gamma,
             DVEC *mu,
             DMAT *R,
             DVEC *mygamma)
#endif
{
    int i, j;
    int d = Gamma->n;
    double tem;
    DMAT *Rcpy = dmat_alloc(d, d);
    DVEC *mucpy = dvec_alloc(d);

    for (i = 0; i < d; i++)
        VEC_AT(mu, i) = VEC_AT(mu, i) / sqrt(MAT_AT(Gamma, i, i));

    for (j = 0; j < d; j++) {
        tem = MAT_AT(R, j, j);
        if (tem == 0.0)
            Bneterror("R[i][i] == 0");
        else
            for (i = 0; i < d; i++)
                MAT_AT(R, i, j) = MAT_AT(R, i, j) * sqrt(MAT_AT(Gamma, j, j)) /
                                  (tem * sqrt(MAT_AT(Gamma, i, i)));
    }

    dvec_copy(mu, mucpy);
    dmat_copy(R, Rcpy);

    /* Solve R * mygamma = -mucpy using LU factorization */
    lu_solve(Rcpy, mucpy, mygamma);

    for (i = 0; i < d; i++)
        VEC_AT(mygamma, i) = -VEC_AT(mygamma, i);

    gmax = fabs(VEC_AT(mygamma, 0));
    for (i = 1; i < d; i++)
        if (fabs(VEC_AT(mygamma, i)) > gmax)
            gmax = fabs(VEC_AT(mygamma, i));

    if ((gmax) == 0.0)
        Bneterror("gamma_max is zero, there is no stationary density");

    for (i = 0; i < d; i++) {
        VEC_AT(mu, i) /= (gmax);
        VEC_AT(mygamma, i) /= gmax;
    }

    for (i = 0; i < d; i++)
        for (j = 0; j < d; j++)
            if (i != j)
                MAT_AT(Gamma, i, j) = MAT_AT(Gamma, i, j) /
                                      (sqrt(MAT_AT(Gamma, i, i)) *
                                       sqrt(MAT_AT(Gamma, j, j)));

    dvec_free(mucpy);
    dmat_free(Rcpy);
}
