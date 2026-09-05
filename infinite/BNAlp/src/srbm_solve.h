#ifndef SRBM_SOLVE_H
#define SRBM_SOLVE_H

#include "srbm_types.h"

/* Get a solver backend by name ("cplex", "glpk", "highs").
 * Returns NULL if the backend was not compiled in. */
const srbm_solver_backend_t *srbm_solver_get(const char *name);

/* List available solver names to stdout. */
void srbm_solver_list(void);

/* Convenience: pick first available solver.  Returns NULL if none. */
const srbm_solver_backend_t *srbm_solver_default(void);

/* Free a solution structure. */
void srbm_solution_free(srbm_solution_t *sol);

/* ----------- Backend declarations (each in their own .c file) ----------- */
#ifdef HAVE_CPLEX
extern const srbm_solver_backend_t srbm_solver_cplex;
#endif
#ifdef HAVE_GLPK
extern const srbm_solver_backend_t srbm_solver_glpk;
#endif
#ifdef HAVE_HIGHS
extern const srbm_solver_backend_t srbm_solver_highs;
#endif

#endif /* SRBM_SOLVE_H */
