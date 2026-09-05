/*
 * poly_ops.c - Polynomial operations for SRBM solver
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "srbm_types.h"

#define INITIAL_CAPACITY 64
#define TOLERANCE 1e-14

/* Initialize polynomial */
void poly_init(Polynomial *p, int n_dim) {
    p->terms = (PolyTerm *)malloc(INITIAL_CAPACITY * sizeof(PolyTerm));
    if (!p->terms) {
        fprintf(stderr, "Error: Failed to allocate polynomial terms\n");
        exit(1);
    }
    p->n_terms = 0;
    p->capacity = INITIAL_CAPACITY;
    p->n_dim = n_dim;
}

/* Free polynomial */
void poly_free(Polynomial *p) {
    if (p->terms) {
        free(p->terms);
        p->terms = NULL;
    }
    p->n_terms = 0;
    p->capacity = 0;
}

/* Add term to polynomial */
void poly_add_term(Polynomial *p, double coeff, const int *exponents) {
    if (fabs(coeff) < TOLERANCE) {
        return;  /* Skip near-zero coefficients */
    }

    /* Expand capacity if needed */
    if (p->n_terms >= p->capacity) {
        p->capacity *= 2;
        p->terms = (PolyTerm *)realloc(p->terms, p->capacity * sizeof(PolyTerm));
        if (!p->terms) {
            fprintf(stderr, "Error: Failed to reallocate polynomial terms\n");
            exit(1);
        }
    }

    /* Add the term */
    p->terms[p->n_terms].coeff = coeff;
    memcpy(p->terms[p->n_terms].exponents, exponents, p->n_dim * sizeof(int));
    p->n_terms++;
}

/* Compare exponent vectors for equality */
static int exponents_equal(const int *e1, const int *e2, int n_dim) {
    for (int i = 0; i < n_dim; i++) {
        if (e1[i] != e2[i]) return 0;
    }
    return 1;
}

/* Consolidate terms with same exponents */
void poly_consolidate(Polynomial *p) {
    if (p->n_terms <= 1) return;

    /* Simple O(n^2) consolidation - could be optimized with hash table */
    for (int i = 0; i < p->n_terms; i++) {
        if (fabs(p->terms[i].coeff) < TOLERANCE) continue;

        for (int j = i + 1; j < p->n_terms; j++) {
            if (fabs(p->terms[j].coeff) < TOLERANCE) continue;

            if (exponents_equal(p->terms[i].exponents, p->terms[j].exponents, p->n_dim)) {
                p->terms[i].coeff += p->terms[j].coeff;
                p->terms[j].coeff = 0.0;  /* Mark as removed */
            }
        }
    }

    /* Compact the array by removing zero terms */
    int write_idx = 0;
    for (int read_idx = 0; read_idx < p->n_terms; read_idx++) {
        if (fabs(p->terms[read_idx].coeff) >= TOLERANCE) {
            if (write_idx != read_idx) {
                p->terms[write_idx] = p->terms[read_idx];
            }
            write_idx++;
        }
    }
    p->n_terms = write_idx;
}

/* Scale polynomial by scalar */
void poly_scale(Polynomial *p, double scalar) {
    for (int i = 0; i < p->n_terms; i++) {
        p->terms[i].coeff *= scalar;
    }
}

/* Compute result = f - scalar * g */
void poly_subtract_scaled(Polynomial *result, const Polynomial *f,
                          const Polynomial *g, double scalar) {
    /* Copy f to result */
    poly_copy(result, f);

    /* Subtract scaled g */
    for (int i = 0; i < g->n_terms; i++) {
        poly_add_term(result, -scalar * g->terms[i].coeff, g->terms[i].exponents);
    }

    /* Consolidate */
    poly_consolidate(result);
}

/* Copy polynomial */
void poly_copy(Polynomial *dest, const Polynomial *src) {
    dest->n_dim = src->n_dim;
    dest->n_terms = src->n_terms;

    /* Ensure capacity */
    if (dest->capacity < src->n_terms) {
        dest->capacity = src->n_terms;
        dest->terms = (PolyTerm *)realloc(dest->terms, dest->capacity * sizeof(PolyTerm));
        if (!dest->terms) {
            fprintf(stderr, "Error: Failed to allocate polynomial copy\n");
            exit(1);
        }
    }

    /* Copy terms */
    memcpy(dest->terms, src->terms, src->n_terms * sizeof(PolyTerm));
}

/* Initialize AfFunction */
void af_init(AfFunction *af, int n_dim) {
    af->n_dim = n_dim;
    af->n_faces = 2 * n_dim;

    poly_init(&af->interior, n_dim);

    af->boundaries = (Polynomial *)malloc(af->n_faces * sizeof(Polynomial));
    if (!af->boundaries) {
        fprintf(stderr, "Error: Failed to allocate boundary polynomials\n");
        exit(1);
    }

    for (int i = 0; i < af->n_faces; i++) {
        /* Boundary polynomials have n_dim-1 dimensions */
        poly_init(&af->boundaries[i], n_dim > 1 ? n_dim - 1 : 1);
    }
}

/* Free AfFunction */
void af_free(AfFunction *af) {
    poly_free(&af->interior);

    if (af->boundaries) {
        for (int i = 0; i < af->n_faces; i++) {
            poly_free(&af->boundaries[i]);
        }
        free(af->boundaries);
        af->boundaries = NULL;
    }
}

/* Copy AfFunction */
void af_copy(AfFunction *dest, const AfFunction *src) {
    dest->n_dim = src->n_dim;
    dest->n_faces = src->n_faces;

    poly_copy(&dest->interior, &src->interior);

    for (int i = 0; i < src->n_faces; i++) {
        poly_copy(&dest->boundaries[i], &src->boundaries[i]);
    }
}

/* Scale AfFunction */
void af_scale(AfFunction *af, double scalar) {
    poly_scale(&af->interior, scalar);

    for (int i = 0; i < af->n_faces; i++) {
        poly_scale(&af->boundaries[i], scalar);
    }
}

/* Compute result = f - scalar * g for AfFunction */
void af_subtract_scaled(AfFunction *result, const AfFunction *f,
                        const AfFunction *g, double scalar) {
    poly_subtract_scaled(&result->interior, &f->interior, &g->interior, scalar);

    for (int i = 0; i < f->n_faces; i++) {
        poly_subtract_scaled(&result->boundaries[i],
                            &f->boundaries[i],
                            &g->boundaries[i], scalar);
    }
}

/* Free parameters */
void params_free(SRBMParams *params) {
    if (params->a_vec) { free(params->a_vec); params->a_vec = NULL; }
    if (params->Gamma) { free(params->Gamma); params->Gamma = NULL; }
    if (params->mu) { free(params->mu); params->mu = NULL; }
    if (params->R) { free(params->R); params->R = NULL; }
    if (params->service_rates) { free(params->service_rates); params->service_rates = NULL; }
}

/* Free result */
void result_free(SRBMResult *result) {
    if (result->q) { free(result->q); result->q = NULL; }
    if (result->delta) { free(result->delta); result->delta = NULL; }
}
