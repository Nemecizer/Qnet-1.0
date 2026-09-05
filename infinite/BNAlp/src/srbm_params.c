/*
 * srbm_params.c – Input file parser for SRBM parameters.
 */
#include "srbm_params.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

/* Skip leading whitespace and return pointer to first non-space char. */
static const char *skip_ws(const char *s)
{
    while (*s && isspace((unsigned char)*s)) s++;
    return s;
}

/* Read a line, stripping comments (anything after '#'). */
static int read_line(FILE *fp, char *buf, int buflen)
{
    if (!fgets(buf, buflen, fp))
        return 0;
    char *hash = strchr(buf, '#');
    if (hash) *hash = '\0';
    /* Strip trailing whitespace */
    int len = (int)strlen(buf);
    while (len > 0 && isspace((unsigned char)buf[len - 1]))
        buf[--len] = '\0';
    return 1;
}

int srbm_params_read(const char *filename, srbm_params_t *params)
{
    FILE *fp = fopen(filename, "r");
    if (!fp) {
        fprintf(stderr, "Cannot open input file: %s\n", filename);
        return -1;
    }

    /* Defaults */
    memset(params, 0, sizeof(*params));
    params->d = 0;
    params->n = 100;
    params->m = 6;
    params->grid_type = 0;
    params->K_user = 0;
    params->max_moments = 4;
    params->smoothness_weight = 0.0;
    params->basis_normalize = 0;
    strcpy(params->solver, "");
    strcpy(params->output_prefix, "srbm_out");

    char line[1024];
    while (read_line(fp, line, sizeof(line))) {
        const char *p = skip_ws(line);
        if (*p == '\0') continue;

        if (strncmp(p, "dimension", 9) == 0) {
            sscanf(p + 9, "%d", &params->d);
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
            if (strcmp(gtype, "exponential") == 0)      params->grid_type = 0;
            else if (strcmp(gtype, "dyadic") == 0)       params->grid_type = 1;
            else if (strcmp(gtype, "exprandom") == 0)    params->grid_type = 2;
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
            /* Next line has d values */
            if (!read_line(fp, line, sizeof(line))) break;
            p = line;
            for (int i = 0; i < params->d; i++) {
                params->mu[i] = strtod(p, (char **)&p);
            }
        }
        else if (strncmp(p, "covariance", 10) == 0) {
            /* Next d lines have d values each */
            for (int i = 0; i < params->d; i++) {
                if (!read_line(fp, line, sizeof(line))) break;
                p = line;
                for (int j = 0; j < params->d; j++) {
                    params->sigma[i * SRBM_MAX_DIM + j] = strtod(p, (char **)&p);
                }
            }
        }
        else if (strncmp(p, "reflection", 10) == 0) {
            for (int i = 0; i < params->d; i++) {
                if (!read_line(fp, line, sizeof(line))) break;
                p = line;
                for (int j = 0; j < params->d; j++) {
                    params->R[i * SRBM_MAX_DIM + j] = strtod(p, (char **)&p);
                }
            }
        }
        else if (strncmp(p, "grid_spacing", 12) == 0) {
            if (!read_line(fp, line, sizeof(line))) break;
            p = line;
            for (int i = 0; i < params->d; i++) {
                params->mu_grid[i] = strtod(p, (char **)&p);
            }
        }
        else if (strncmp(p, "smoothness_weight", 17) == 0) {
            sscanf(p + 17, "%lf", &params->smoothness_weight);
        }
        else if (strncmp(p, "basis_normalize", 15) == 0) {
            sscanf(p + 15, "%d", &params->basis_normalize);
        }
        else if (strncmp(p, "tightness_bounds", 16) == 0) {
            if (!read_line(fp, line, sizeof(line))) break;
            p = line;
            params->K_user = 1;
            for (int i = 0; i < 2 * params->d + 1; i++) {
                params->K[i] = strtod(p, (char **)&p);
            }
        }
    }

    fclose(fp);
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
    return err;
}

void srbm_params_print(const srbm_params_t *params)
{
    int d = params->d;
    printf("SRBM Parameters:\n");
    printf("  dimension     = %d\n", d);
    printf("  grid_n        = %d\n", params->n);
    printf("  basis_m       = %d\n", params->m);
    printf("  grid_type     = %d (0=exp, 1=dya, 2=expran)\n", params->grid_type);
    printf("  max_moments   = %d\n", params->max_moments);
    printf("  solver        = %s\n", params->solver[0] ? params->solver : "(default)");
    printf("  output_prefix = %s\n", params->output_prefix);

    printf("  drift         =");
    for (int i = 0; i < d; i++) printf(" %.4f", params->mu[i]);
    printf("\n");

    printf("  covariance:\n");
    for (int i = 0; i < d; i++) {
        printf("    ");
        for (int j = 0; j < d; j++)
            printf(" %8.4f", params->sigma[i * SRBM_MAX_DIM + j]);
        printf("\n");
    }

    printf("  reflection:\n");
    for (int i = 0; i < d; i++) {
        printf("    ");
        for (int j = 0; j < d; j++)
            printf(" %8.4f", params->R[i * SRBM_MAX_DIM + j]);
        printf("\n");
    }

    printf("  grid_spacing  =");
    for (int i = 0; i < d; i++) printf(" %.4f", params->mu_grid[i]);
    printf("\n");

    if (params->K_user) {
        printf("  tightness K   =");
        for (int i = 0; i < 2 * d + 1; i++) printf(" %.0f", params->K[i]);
        printf("\n");
    } else {
        printf("  tightness K   = (auto: 100000)\n");
    }
    printf("  smoothness_w  = %.6g %s\n", params->smoothness_weight,
           params->smoothness_weight > 0 ? "(TV penalty on lambda)" : "(disabled)");
    printf("  basis_norm    = %d %s\n", params->basis_normalize,
           params->basis_normalize ? "(scale rows by 1/L^|p|)" : "(raw monomials)");
}
