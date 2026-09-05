/*
 * srbm_types.h - Data structures for SRBM solver
 *
 * Implementation of Dai & Harrison (1991) SRBM algorithm in C
 */

#ifndef SRBM_TYPES_H
#define SRBM_TYPES_H

#include <stdlib.h>
#include <stdint.h>

/* Maximum supported dimensions */
#define MAX_DIM 10
#define MAX_TERMS 10000
#define MAX_POLY_ORDER 20
#define CC_MAX 32   /* Max customer classes */

/* Polynomial term: coefficient * x1^e1 * x2^e2 * ... * xn^en */
typedef struct {
    double coeff;
    int exponents[MAX_DIM];
} PolyTerm;

/* Polynomial as a collection of terms */
typedef struct {
    PolyTerm *terms;
    int n_terms;
    int capacity;
    int n_dim;
} Polynomial;

/* Af function: interior polynomial + boundary polynomials */
typedef struct {
    Polynomial interior;
    Polynomial *boundaries;  /* Array of 2*n_dim polynomials */
    int n_dim;
    int n_faces;
} AfFunction;

/* SRBM problem parameters */
typedef struct {
    int n_dim;              /* Number of dimensions */
    int n_approx;           /* Polynomial approximation order */
    double *a_vec;          /* Hypercube dimensions [n_dim] */
    double *Gamma;          /* Covariance matrix [n_dim x n_dim] */
    double *mu;             /* Drift vector [n_dim] */
    double *R;              /* Reflection matrix [n_dim x 2*n_dim] */
    double *service_rates;  /* Service rates [n_dim] (optional, for throughput) */
    int has_service_rates;  /* Whether service rates were provided */

    /* Customer class data (optional) */
    int cc_num_classes;                 /* K; 0 = feature off */
    double cc_alpha_total[CC_MAX];      /* total throughput per station */
    double cc_lambda[CC_MAX];           /* external arrival rate per class */
    double cc_alpha[CC_MAX][CC_MAX];    /* alpha[k][i] K x d */
    double cc_mu[CC_MAX][CC_MAX];       /* mu[k][i] K x d */
} SRBMParams;

/* SRBM results */
typedef struct {
    double *q;              /* Expected values E[X_k] [n_dim] */
    double *delta;          /* Boundary measures [2*n_dim] */
    double alpha;           /* Normalization constant */
    int basis_dim;          /* Dimension of approximation basis */
} SRBMResult;

/* Function prototypes for polynomial operations */
void poly_init(Polynomial *p, int n_dim);
void poly_free(Polynomial *p);
void poly_add_term(Polynomial *p, double coeff, const int *exponents);
void poly_consolidate(Polynomial *p);
void poly_scale(Polynomial *p, double scalar);
void poly_subtract_scaled(Polynomial *result, const Polynomial *f,
                          const Polynomial *g, double scalar);
void poly_copy(Polynomial *dest, const Polynomial *src);

/* Function prototypes for AfFunction operations */
void af_init(AfFunction *af, int n_dim);
void af_free(AfFunction *af);
void af_copy(AfFunction *dest, const AfFunction *src);
void af_scale(AfFunction *af, double scalar);
void af_subtract_scaled(AfFunction *result, const AfFunction *f,
                        const AfFunction *g, double scalar);

/* Utility functions */
void params_free(SRBMParams *params);
void result_free(SRBMResult *result);

#endif /* SRBM_TYPES_H */
