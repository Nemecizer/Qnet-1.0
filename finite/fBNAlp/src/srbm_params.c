/*
 * srbm_params.c — Input file parser for the rectangle-case SRBM solver.
 *
 * The format extends BNAlp's orthant input file with two new directives:
 *
 *   upper_bounds          required: gives bᵢ for each axis i = 0..d-1.
 *   reflection_form       optional: { minus_only (default) | grouped |
 *                         interleaved }. Selects how the reflection block
 *                         after the `reflection` keyword is read:
 *
 *       minus_only:    next d lines hold a d×d matrix R⁻ (lower face).
 *                      R⁺ is synthesised as -R⁻ in main.c.
 *       grouped:       next d lines hold d×2d, columns laid out as
 *                      [R⁻_0 R⁻_1 ... R⁻_{d-1}  R⁺_0 R⁺_1 ... R⁺_{d-1}].
 *       interleaved:   next d lines hold d×2d, columns laid out as
 *                      [R⁻_0 R⁺_0  R⁻_1 R⁺_1  ...  R⁻_{d-1} R⁺_{d-1}].
 *                      Same convention as fBNAsm.
 *
 * The tightness vector `tightness_bounds` is now of length 4d+1.
 *
 * The orthant-only `grid_spacing` directive is accepted for backwards
 * compatibility but ignored — the rectangle uses a uniform grid keyed
 * off `upper_bounds`.
 */
#include "srbm_params.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

static const char *skip_ws(const char *s)
{
    while (*s && isspace((unsigned char)*s)) s++;
    return s;
}

static int read_line(FILE *fp, char *buf, int buflen)
{
    if (!fgets(buf, buflen, fp)) return 0;
    char *hash = strchr(buf, '#');
    if (hash) *hash = '\0';
    int len = (int)strlen(buf);
    while (len > 0 && isspace((unsigned char)buf[len - 1]))
        buf[--len] = '\0';
    return 1;
}

/* Reflection-form code: 0 = minus_only, 1 = grouped, 2 = interleaved. */
static int reflection_form_default(void) { return 0; }

int srbm_params_read(const char *filename, srbm_params_t *params)
{
    FILE *fp = fopen(filename, "r");
    if (!fp) {
        fprintf(stderr, "Cannot open input file: %s\n", filename);
        return -1;
    }

    memset(params, 0, sizeof(*params));
    params->d = 0;
    params->n = 100;
    params->m = 6;
    params->grid_type = 0;             /* uniform */
    params->K_user = 0;
    params->max_moments = 4;
    params->smoothness_weight = 0.0;
    params->basis_normalize = 0;
    params->R_full_2d = 0;
    strcpy(params->solver, "");
    strcpy(params->output_prefix, "srbm_out");

    int reflection_form = reflection_form_default();
    int upper_bounds_set = 0;

    char line[1024];
    while (read_line(fp, line, sizeof(line))) {
        const char *p = skip_ws(line);
        if (*p == '\0') continue;

        if (strncmp(p, "dimension", 9) == 0) {
            sscanf(p + 9, "%d", &params->d);
            /* Validate the cap at parse time so a too-large dim shows
             * the right error rather than the cascade-of-missing-fields
             * cascade (e.g. "missing upper_bounds" when the real issue
             * is d > SRBM_MAX_DIM). */
            if (params->d < 1 || params->d > SRBM_MAX_DIM) {
                fprintf(stderr,
                    "Invalid dimension d=%d (must be 1..%d)\n",
                    params->d, SRBM_MAX_DIM);
                fclose(fp);
                return -1;
            }
        }
        else if (strncmp(p, "grid_n", 6) == 0) {
            sscanf(p + 6, "%d", &params->n);
        }
        else if (strncmp(p, "basis_m", 7) == 0) {
            sscanf(p + 7, "%d", &params->m);
        }
        else if (strncmp(p, "grid_type", 9) == 0) {
            char gtype[32] = {0};
            sscanf(p + 9, "%31s", gtype);
            if (strcmp(gtype, "uniform") == 0)        params->grid_type = 0;
            else if (strcmp(gtype, "chebyshev") == 0) params->grid_type = 1;
            else {
                fprintf(stderr, "Unknown grid_type: %s\n", gtype);
                fclose(fp);
                return -1;
            }
        }
        else if (strncmp(p, "max_moments", 11) == 0) {
            sscanf(p + 11, "%d", &params->max_moments);
        }
        else if (strncmp(p, "solver", 6) == 0) {
            sscanf(p + 6, "%31s", params->solver);
        }
        else if (strncmp(p, "output_prefix", 13) == 0) {
            sscanf(p + 13, "%255s", params->output_prefix);
        }
        else if (strncmp(p, "drift", 5) == 0) {
            if (!read_line(fp, line, sizeof(line))) break;
            p = line;
            for (int i = 0; i < params->d; i++)
                params->mu[i] = strtod(p, (char **)&p);
        }
        else if (strncmp(p, "covariance", 10) == 0) {
            for (int i = 0; i < params->d; i++) {
                if (!read_line(fp, line, sizeof(line))) break;
                p = line;
                for (int j = 0; j < params->d; j++)
                    params->sigma[i * SRBM_MAX_DIM + j] = strtod(p, (char **)&p);
            }
        }
        else if (strncmp(p, "reflection_form", 15) == 0) {
            char form[32] = {0};
            sscanf(p + 15, "%31s", form);
            if      (strcmp(form, "minus_only") == 0)  reflection_form = 0;
            else if (strcmp(form, "grouped") == 0)     reflection_form = 1;
            else if (strcmp(form, "interleaved") == 0) reflection_form = 2;
            else {
                fprintf(stderr, "Unknown reflection_form: %s\n", form);
                fclose(fp); return -1;
            }
        }
        else if (strncmp(p, "reflection", 10) == 0) {
            int d = params->d;
            if (reflection_form == 0) {
                /* d × d, R only */
                for (int i = 0; i < d; i++) {
                    if (!read_line(fp, line, sizeof(line))) break;
                    p = line;
                    for (int j = 0; j < d; j++)
                        params->R[i * SRBM_MAX_DIM + j] = strtod(p, (char **)&p);
                }
                params->R_full_2d = 0;
            } else {
                /* d × 2d block */
                for (int i = 0; i < d; i++) {
                    if (!read_line(fp, line, sizeof(line))) break;
                    p = line;
                    if (reflection_form == 1) {
                        /* grouped: R⁻ first, R⁺ second */
                        for (int j = 0; j < d; j++)
                            params->R[i * SRBM_MAX_DIM + j] = strtod(p, (char **)&p);
                        for (int j = 0; j < d; j++)
                            params->R_plus[i * SRBM_MAX_DIM + j] = strtod(p, (char **)&p);
                    } else {
                        /* interleaved: pairs (R⁻_j, R⁺_j) */
                        for (int j = 0; j < d; j++) {
                            params->R[i * SRBM_MAX_DIM + j]      = strtod(p, (char **)&p);
                            params->R_plus[i * SRBM_MAX_DIM + j] = strtod(p, (char **)&p);
                        }
                    }
                }
                params->R_full_2d = 1;
            }
        }
        else if (strncmp(p, "upper_bounds", 12) == 0) {
            if (!read_line(fp, line, sizeof(line))) break;
            p = line;
            for (int i = 0; i < params->d; i++)
                params->b_upper[i] = strtod(p, (char **)&p);
            upper_bounds_set = 1;
        }
        else if (strncmp(p, "grid_spacing", 12) == 0) {
            /* Accepted but ignored — orthant artefact. Skip the next line. */
            if (!read_line(fp, line, sizeof(line))) break;
        }
        else if (strncmp(p, "smoothness_weight", 17) == 0) {
            sscanf(p + 17, "%lf", &params->smoothness_weight);
        }
        else if (strncmp(p, "basis_normalize", 15) == 0) {
            sscanf(p + 15, "%d", &params->basis_normalize);
        }
        else if (strncmp(p, "service_rates", 13) == 0) {
            if (!read_line(fp, line, sizeof(line))) break;
            p = line;
            for (int i = 0; i < params->d; i++)
                params->service_rates[i] = strtod(p, (char **)&p);
            params->has_service_rates = 1;
        }
        else if (strncmp(p, "tightness_bounds", 16) == 0) {
            if (!read_line(fp, line, sizeof(line))) break;
            p = line;
            params->K_user = 1;
            int K_len = 4 * params->d + 1;
            for (int i = 0; i < K_len; i++)
                params->K[i] = strtod(p, (char **)&p);
        }
    }

    fclose(fp);

    if (!upper_bounds_set) {
        fprintf(stderr,
                "Error: input file is missing the required `upper_bounds` directive\n");
        return -1;
    }
    return 0;
}

int srbm_params_validate(const srbm_params_t *params)
{
    int err = 0;
    if (params->d < 1 || params->d > SRBM_MAX_DIM) {
        fprintf(stderr, "Invalid dimension d=%d (must be 1..%d)\n",
                params->d, SRBM_MAX_DIM);
        err = -1;
    }
    if (params->n < 2) {
        fprintf(stderr, "Invalid grid_n=%d (must be >= 2)\n", params->n);
        err = -1;
    }
    if (params->m < 1) {
        fprintf(stderr, "Invalid basis_m=%d (must be >= 1)\n", params->m);
        err = -1;
    }
    for (int i = 0; i < params->d; i++) {
        if (params->b_upper[i] <= 0.0) {
            fprintf(stderr,
                    "Invalid upper_bounds[%d] = %.4f (must be > 0)\n",
                    i, params->b_upper[i]);
            err = -1;
        }
    }
    return err;
}

void srbm_params_print(const srbm_params_t *params)
{
    int d = params->d;
    printf("SRBM Parameters:\n");
    printf("  dimension     = %d\n", d);
    printf("  grid_n        = %d\n", params->n);
    printf("  basis_m       = %d\n", params->m);
    printf("  grid_type     = %s\n",
           params->grid_type == 0 ? "uniform" :
           params->grid_type == 1 ? "chebyshev" : "?");
    printf("  max_moments   = %d\n", params->max_moments);
    printf("  solver        = %s\n", params->solver[0] ? params->solver : "(default)");
    printf("  output_prefix = %s\n", params->output_prefix);

    printf("  drift         =");
    for (int i = 0; i < d; i++) printf(" %.4f", params->mu[i]);
    printf("\n");

    printf("  upper_bounds  =");
    for (int i = 0; i < d; i++) printf(" %.4f", params->b_upper[i]);
    printf("\n");

    printf("  covariance:\n");
    for (int i = 0; i < d; i++) {
        printf("    ");
        for (int j = 0; j < d; j++)
            printf(" %8.4f", params->sigma[i * SRBM_MAX_DIM + j]);
        printf("\n");
    }

    printf("  reflection (lower):\n");
    for (int i = 0; i < d; i++) {
        printf("    ");
        for (int j = 0; j < d; j++)
            printf(" %8.4f", params->R[i * SRBM_MAX_DIM + j]);
        printf("\n");
    }
    if (params->R_full_2d) {
        printf("  reflection (upper):\n");
        for (int i = 0; i < d; i++) {
            printf("    ");
            for (int j = 0; j < d; j++)
                printf(" %8.4f", params->R_plus[i * SRBM_MAX_DIM + j]);
            printf("\n");
        }
    } else {
        printf("  reflection (upper) = -R (synthesised)\n");
    }

    if (params->K_user) {
        printf("  tightness K   =");
        int K_len = 4 * d + 1;
        for (int i = 0; i < K_len; i++) printf(" %.0f", params->K[i]);
        printf("\n");
    } else {
        printf("  tightness K   = (auto: 100000)\n");
    }
    printf("  smoothness_w  = %.6g %s\n", params->smoothness_weight,
           params->smoothness_weight > 0 ? "(TV penalty on lambda)" : "(disabled)");
    printf("  basis_norm    = %d %s\n", params->basis_normalize,
           params->basis_normalize ? "(scale rows by 1/L^|p|)" : "(raw monomials)");
}
