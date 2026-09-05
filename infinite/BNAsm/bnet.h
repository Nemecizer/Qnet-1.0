/*
 * bnet.h - Header file for BNET solver
 * Updated to use SuiteSparse CHOLMOD instead of meschach
 */

#ifndef BNET_H
#define BNET_H

#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "suitesparse_compat.h"

#ifndef TRUE
#define TRUE 1
#endif
#ifndef FALSE
#define FALSE 0
#endif

#ifndef True
#define True 1
#endif
#ifndef False
#define False 0
#endif

/* Real type for computations */
typedef double real;

/* Global maximum gamma */
extern double gmax;

/* Global verbosity level: 0=silent, 1=steps only, 2=full */
extern int verbosity;

/* Compact output mode (-c flag) */
extern int compact_mode;

/* Stored means from Output() for final printing */
#define BNET_MAX_DIM 64
extern double bnet_means[BNET_MAX_DIM];
extern int bnet_ndim;

/* Polynomial structure */
typedef struct {
    real *itr;   /* Interior polynomial coefficients */
    real **bd;   /* Boundary polynomial coefficients */
} poly;

/* Utility functions - memory allocation */
extern float  *vector();
extern int    *ivector();
extern real   *dvector();
extern real   *cvector();
extern float  **matrix();
extern int    **imatrix();
extern real   **dmatrix();
extern real   **cmatrix();
extern void   free_ivector();
extern void   free_dvector();
extern void   free_imatrix();
extern void   free_dmatrix();
extern void   Bneterror();
extern void   gaxpy_cholesky();

/* I/O and data processing functions */
extern void   print_original_data();
extern void   print_converted_data();
extern void   scaling();

/* Index computation functions */
extern int    **ComputeC();
extern int    **ComputeIndex();
extern double **ComputeWeight();

/* Core algorithm functions */
extern void   Basis();
extern void   orthogonalize();
extern void   Density1();
extern void   Density2();
extern void   Output();
extern void   coefficient();

#ifdef ANSI_C
#include <stdio.h>

extern int    get_dimension(FILE *);
extern int    get_degree(FILE *);
extern FILE   **option(int argc, char *argv[],
                       int *print, int *mode, int *iterative, int *imsl,
                       int *use_lu, double *regularization_epsilon);

extern DMAT   *get_covariance(int d, FILE *);
extern DMAT   *get_reflection(int d, FILE *);
extern DVEC   *get_drift(int d, FILE *);
extern void   scaling(FILE *output_fp, DMAT *Gamma, DVEC *mu, DMAT *R, DVEC *mygamma);

#else
/* Non-ANSI C declarations */
extern int    get_dimension();
extern int    get_degree();
extern FILE   **option();
extern DMAT   *get_covariance();
extern DMAT   *get_reflection();
extern DVEC   *get_drift();
extern void   scaling();
#endif

#endif /* BNET_H */
