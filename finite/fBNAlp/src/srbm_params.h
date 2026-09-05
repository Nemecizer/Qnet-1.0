#ifndef SRBM_PARAMS_H
#define SRBM_PARAMS_H

#include "srbm_types.h"

/* Parse an input file and fill params.  Returns 0 on success. */
int srbm_params_read(const char *filename, srbm_params_t *params);

/* Validate parameters.  Returns 0 if OK, prints errors to stderr. */
int srbm_params_validate(const srbm_params_t *params);

/* Print parameters to stdout for confirmation. */
void srbm_params_print(const srbm_params_t *params);

#endif /* SRBM_PARAMS_H */
