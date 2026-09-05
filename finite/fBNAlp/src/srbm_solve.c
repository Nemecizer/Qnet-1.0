/*
 * srbm_solve.c – Solver dispatch layer.
 */
#include "srbm_solve.h"
#include "srbm_mem.h"
#include <string.h>
#include <stdio.h>

static const srbm_solver_backend_t *backends[] = {
#ifdef HAVE_CPLEX
    &srbm_solver_cplex,
#endif
#ifdef HAVE_GLPK
    &srbm_solver_glpk,
#endif
#ifdef HAVE_HIGHS
    &srbm_solver_highs,
#endif
    NULL
};

const srbm_solver_backend_t *srbm_solver_get(const char *name)
{
    for (int i = 0; backends[i] != NULL; i++) {
        if (strcmp(backends[i]->name, name) == 0)
            return backends[i];
    }
    return NULL;
}

void srbm_solver_list(void)
{
    printf("Available LP solvers:");
    for (int i = 0; backends[i] != NULL; i++)
        printf(" %s", backends[i]->name);
    printf("\n");
}

const srbm_solver_backend_t *srbm_solver_default(void)
{
    return backends[0];  /* NULL if none compiled */
}

void srbm_solution_free(srbm_solution_t *sol)
{
    srbm_free(sol->lambda);
    for (int k = 0; k < sol->d; k++) {
        srbm_free(sol->gamma_minus[k]);
        srbm_free(sol->gamma_plus[k]);
    }
    memset(sol, 0, sizeof(*sol));
}
