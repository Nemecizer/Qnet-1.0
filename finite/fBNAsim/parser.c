/*
 * parser.c - Input file parser for fBNA queueing network exports
 *
 * Supports two formats:
 *
 * (A) Legacy single-class format:
 *   # dimension
 *   d
 *   # arrival_distribution
 *   exponential rate=1.0
 *   # buffer_sizes
 *   b1 b2 ... bd
 *   # service_distributions
 *   <d lines>
 *   # routing_matrix
 *   <d x d>
 *
 * (B) Multi-class format (also produced by NetworkExporter.swift):
 *   # num_classes
 *   K
 *   # dimension
 *   d
 *   # arrival_distributions
 *   <K lines, one per class>
 *   # servers_per_station
 *   c1 c2 ... cd
 *   # buffer_sizes
 *   b1 b2 ... bd
 *   # service_distributions
 *   <d lines, pipe-separated for K classes>
 *   # routing_matrix_class_1
 *   <d x d>
 *   ...
 *   # routing_matrix_class_K
 *   <d x d>
 *
 * Backward compatible: old files without num_classes/servers_per_station
 * parse as K=1, c_i=1.
 */

#include "parser.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#define LINE_BUF 1024

/* ------------------------------------------------------------------ */
/* Helpers                                                            */
/* ------------------------------------------------------------------ */

static char *trim_left(char *s)
{
    while (*s && isspace((unsigned char)*s))
        s++;
    return s;
}

static void chomp(char *s)
{
    size_t len = strlen(s);
    while (len > 0 && (s[len - 1] == '\n' || s[len - 1] == '\r'))
        s[--len] = '\0';
}

static int next_data_line(FILE *fp, char *buf, size_t sz)
{
    while (fgets(buf, (int)sz, fp)) {
        chomp(buf);
        char *t = trim_left(buf);
        if (*t == '\0' || *t == '#')
            continue;
        if (t != buf)
            memmove(buf, t, strlen(t) + 1);
        return 1;
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* Distribution string parser                                         */
/* ------------------------------------------------------------------ */

static int dist_type_from_name(const char *name)
{
    if (strcmp(name, "exponential") == 0) return DIST_EXPONENTIAL;
    if (strcmp(name, "gamma")       == 0) return DIST_GAMMA;
    if (strcmp(name, "uniform")     == 0) return DIST_UNIFORM;
    if (strcmp(name, "constant")    == 0) return DIST_CONSTANT;
    if (strcmp(name, "weibull")     == 0) return DIST_WEIBULL;
    if (strcmp(name, "erlang")      == 0) return DIST_ERLANG;
    if (strcmp(name, "lognormal")   == 0) return DIST_LOGNORMAL;
    if (strcmp(name, "pareto")      == 0) return DIST_PARETO;
    if (strcmp(name, "poisson")     == 0) return DIST_POISSON;
    return -1;
}

static int parse_distribution(const char *line, Distribution *dist)
{
    char type_str[64];
    char params_str[256];

    int n = sscanf(line, "%63s %255[^\n]", type_str, params_str);
    if (n < 1) {
        fprintf(stderr, "Error: empty distribution line\n");
        return -1;
    }

    int dt = dist_type_from_name(type_str);
    if (dt < 0) {
        fprintf(stderr, "Error: unknown distribution '%s'\n", type_str);
        return -1;
    }
    dist->type = (DistType)dt;
    memset(dist->params, 0, sizeof(dist->params));

    if (n < 2) {
        fprintf(stderr, "Error: distribution '%s' has no parameters\n", type_str);
        return -1;
    }

    char *saveptr = NULL;
    char *token = strtok_r(params_str, ",", &saveptr);
    while (token) {
        char *eq = strchr(token, '=');
        if (!eq) {
            fprintf(stderr, "Error: malformed param '%s'\n", token);
            return -1;
        }
        *eq = '\0';
        char *key = trim_left(token);
        double val = atof(eq + 1);

        switch (dist->type) {
        case DIST_EXPONENTIAL:
            if (strcmp(key, "rate") == 0) dist->params[0] = val;
            break;
        case DIST_GAMMA:
            if (strcmp(key, "shape") == 0) dist->params[0] = val;
            if (strcmp(key, "scale") == 0) dist->params[1] = val;
            break;
        case DIST_UNIFORM:
            if (strcmp(key, "min") == 0) dist->params[0] = val;
            if (strcmp(key, "max") == 0) dist->params[1] = val;
            break;
        case DIST_CONSTANT:
            if (strcmp(key, "value") == 0) dist->params[0] = val;
            break;
        case DIST_WEIBULL:
            if (strcmp(key, "shape") == 0) dist->params[0] = val;
            if (strcmp(key, "scale") == 0) dist->params[1] = val;
            break;
        case DIST_ERLANG:
            if (strcmp(key, "k") == 0)    dist->params[0] = val;
            if (strcmp(key, "rate") == 0) dist->params[1] = val;
            break;
        case DIST_LOGNORMAL:
            if (strcmp(key, "mu") == 0)    dist->params[0] = val;
            if (strcmp(key, "sigma") == 0) dist->params[1] = val;
            break;
        case DIST_PARETO:
            if (strcmp(key, "shape") == 0) dist->params[0] = val;
            if (strcmp(key, "scale") == 0) dist->params[1] = val;
            break;
        case DIST_POISSON:
            if (strcmp(key, "lambda") == 0) dist->params[0] = val;
            break;
        }

        token = strtok_r(NULL, ",", &saveptr);
    }

    return 0;
}

/* ------------------------------------------------------------------ */
/* Section seeking                                                    */
/* ------------------------------------------------------------------ */

/* Seek forward to a comment line containing tag.  Returns 1 if found. */
static int seek_section(FILE *fp, const char *tag)
{
    char buf[LINE_BUF];
    while (fgets(buf, LINE_BUF, fp)) {
        chomp(buf);
        char *t = trim_left(buf);
        if (*t == '#' && strstr(t, tag) != NULL)
            return 1;
    }
    return 0;
}


/* ------------------------------------------------------------------ */
/* Parse routing matrix (d x d) from current file position            */
/* ------------------------------------------------------------------ */
static int parse_routing_matrix(FILE *fp, int d, double mat[MAX_STATIONS][MAX_STATIONS])
{
    char buf[LINE_BUF];
    for (int i = 0; i < d; i++) {
        if (!next_data_line(fp, buf, LINE_BUF)) {
            fprintf(stderr, "Error: cannot read routing row %d\n", i + 1);
            return -1;
        }
        char *p = buf;
        for (int j = 0; j < d; j++) {
            char *end;
            double v = strtod(p, &end);
            if (end == p) {
                fprintf(stderr, "Error: invalid routing entry [%d][%d]\n", i, j);
                return -1;
            }
            mat[i][j] = v;
            p = end;
        }
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* Main parser                                                        */
/* ------------------------------------------------------------------ */

int parse_network_file(const char *filename, Network *net)
{
    FILE *fp = fopen(filename, "r");
    if (!fp) {
        fprintf(stderr, "Error: cannot open '%s'\n", filename);
        return -1;
    }

    memset(net, 0, sizeof(*net));
    char buf[LINE_BUF];

    /* ── num_classes (optional, default 1) ──────────────────────── */
    int has_num_classes = 0;
    net->K = 1;
    if (seek_section(fp, "num_classes")) {
        if (!next_data_line(fp, buf, LINE_BUF) || sscanf(buf, "%d", &net->K) != 1) {
            fprintf(stderr, "Error: cannot read num_classes\n");
            fclose(fp);
            return -1;
        }
        if (net->K < 1 || net->K > MAX_CLASSES) {
            fprintf(stderr, "Error: num_classes %d out of range [1, %d]\n",
                    net->K, MAX_CLASSES);
            fclose(fp);
            return -1;
        }
        has_num_classes = 1;
    }
    rewind(fp);

    /* ── dimension ─────────────────────────────────────────────── */
    if (!seek_section(fp, "dimension")) {
        fprintf(stderr, "Error: missing '# dimension' section\n");
        fclose(fp);
        return -1;
    }
    if (!next_data_line(fp, buf, LINE_BUF) || sscanf(buf, "%d", &net->d) != 1) {
        fprintf(stderr, "Error: cannot read dimension\n");
        fclose(fp);
        return -1;
    }
    if (net->d < 1 || net->d > MAX_STATIONS) {
        fprintf(stderr, "Error: dimension %d out of range [1, %d]\n",
                net->d, MAX_STATIONS);
        fclose(fp);
        return -1;
    }

    /* ── arrival_distributions (multi-class) or arrival_distribution (single) ── */
    rewind(fp);
    if (has_num_classes && seek_section(fp, "arrival_distributions")) {
        /* Multi-class: K lines */
        for (int k = 0; k < net->K; k++) {
            if (!next_data_line(fp, buf, LINE_BUF) ||
                parse_distribution(buf, &net->arrival_dist[k]) != 0) {
                fprintf(stderr, "Error: cannot parse arrival distribution for class %d\n", k + 1);
                fclose(fp);
                return -1;
            }
        }
    } else {
        /* Legacy single-class */
        rewind(fp);
        if (!seek_section(fp, "arrival_distribution")) {
            fprintf(stderr, "Error: missing '# arrival_distribution(s)' section\n");
            fclose(fp);
            return -1;
        }
        if (!next_data_line(fp, buf, LINE_BUF) ||
            parse_distribution(buf, &net->arrival_dist[0]) != 0) {
            fprintf(stderr, "Error: cannot parse arrival distribution\n");
            fclose(fp);
            return -1;
        }
    }

    /* ── arrival_stations (optional, default all classes enter S1) ──
     *
     * One line of K integers, 1-indexed station IDs (so "1 3" means
     * class 0 enters S1 and class 1 enters S3). When the section is
     * absent every class enters station 0, preserving prior behavior.
     * The exporter writes this whenever it can resolve each source's
     * downstream station; missing or malformed entries are flagged.
     */
    for (int k = 0; k < net->K; k++)
        net->arrival_station[k] = 0;
    rewind(fp);
    if (seek_section(fp, "arrival_stations")) {
        if (!next_data_line(fp, buf, LINE_BUF)) {
            fprintf(stderr, "Error: cannot read arrival_stations\n");
            fclose(fp);
            return -1;
        }
        char *p = buf;
        for (int k = 0; k < net->K; k++) {
            char *end;
            long v = strtol(p, &end, 10);
            if (end == p) {
                fprintf(stderr, "Error: invalid arrival_stations entry %d\n", k + 1);
                fclose(fp);
                return -1;
            }
            /* File is 1-indexed; struct stores 0-indexed. We don't
             * know net->d yet at section-seek time, but it has been
             * set above, so range-check now. */
            if (v < 1 || v > net->d) {
                fprintf(stderr,
                        "Error: arrival_stations[%d] = %ld is out of range [1, %d]\n",
                        k + 1, v, net->d);
                fclose(fp);
                return -1;
            }
            net->arrival_station[k] = (int)(v - 1);
            p = end;
        }
    }

    /* ── servers_per_station (optional, default all 1) ─────────── */
    for (int i = 0; i < net->d; i++)
        net->servers[i] = 1;
    rewind(fp);
    if (seek_section(fp, "servers_per_station")) {
        if (!next_data_line(fp, buf, LINE_BUF)) {
            fprintf(stderr, "Error: cannot read servers_per_station\n");
            fclose(fp);
            return -1;
        }
        char *p = buf;
        for (int i = 0; i < net->d; i++) {
            char *end;
            long v = strtol(p, &end, 10);
            if (end == p || v < 1) {
                fprintf(stderr, "Error: invalid servers_per_station at position %d\n", i);
                fclose(fp);
                return -1;
            }
            net->servers[i] = (int)v;
            p = end;
        }
    }

    /* ── buffer_sizes ──────────────────────────────────────────── */
    rewind(fp);
    if (!seek_section(fp, "buffer_sizes")) {
        fprintf(stderr, "Error: missing '# buffer_sizes' section\n");
        fclose(fp);
        return -1;
    }
    if (!next_data_line(fp, buf, LINE_BUF)) {
        fprintf(stderr, "Error: cannot read buffer sizes\n");
        fclose(fp);
        return -1;
    }
    {
        char *p = buf;
        for (int i = 0; i < net->d; i++) {
            char *end;
            long v = strtol(p, &end, 10);
            if (end == p || v < 1) {
                fprintf(stderr, "Error: invalid buffer size at position %d\n", i);
                fclose(fp);
                return -1;
            }
            net->buffer_size[i] = (int)v;
            p = end;
        }
    }

    /* ── service_distributions (pipe-separated for multi-class) ── */
    rewind(fp);
    if (!seek_section(fp, "service_distributions")) {
        fprintf(stderr, "Error: missing '# service_distributions' section\n");
        fclose(fp);
        return -1;
    }
    for (int i = 0; i < net->d; i++) {
        if (!next_data_line(fp, buf, LINE_BUF)) {
            fprintf(stderr, "Error: cannot parse service distribution %d\n", i + 1);
            fclose(fp);
            return -1;
        }

        /* Check for pipe-separated per-class distributions */
        char *pipe = strchr(buf, '|');
        if (pipe && net->K > 1) {
            /* Split on '|' and parse each class */
            char linecopy[LINE_BUF];
            strncpy(linecopy, buf, LINE_BUF - 1);
            linecopy[LINE_BUF - 1] = '\0';
            char *saveptr = NULL;
            char *tok = strtok_r(linecopy, "|", &saveptr);
            for (int k = 0; k < net->K; k++) {
                if (!tok) {
                    fprintf(stderr, "Error: service_distributions station %d: "
                            "expected %d classes, got %d\n", i + 1, net->K, k);
                    fclose(fp);
                    return -1;
                }
                char *trimmed = trim_left(tok);
                if (parse_distribution(trimmed, &net->service_dist[i][k]) != 0) {
                    fprintf(stderr, "Error: cannot parse service distribution "
                            "station %d class %d\n", i + 1, k + 1);
                    fclose(fp);
                    return -1;
                }
                tok = strtok_r(NULL, "|", &saveptr);
            }
        } else {
            /* Single distribution: applies to all classes */
            if (parse_distribution(buf, &net->service_dist[i][0]) != 0) {
                fprintf(stderr, "Error: cannot parse service distribution %d\n", i + 1);
                fclose(fp);
                return -1;
            }
            /* Copy to all classes */
            for (int k = 1; k < net->K; k++)
                net->service_dist[i][k] = net->service_dist[i][0];
        }
    }

    /* ── routing matrices ──────────────────────────────────────── */
    if (net->K > 1) {
        /* Multi-class: look for routing_matrix_class_N for each class */
        for (int k = 0; k < net->K; k++) {
            char tag[64];
            snprintf(tag, sizeof(tag), "routing_matrix_class_%d", k + 1);
            rewind(fp);
            if (!seek_section(fp, tag)) {
                fprintf(stderr, "Error: missing '# %s' section\n", tag);
                fclose(fp);
                return -1;
            }
            if (parse_routing_matrix(fp, net->d, net->routing[k]) != 0) {
                fclose(fp);
                return -1;
            }
        }
    } else {
        /* Single-class: look for routing_matrix */
        rewind(fp);
        if (!seek_section(fp, "routing_matrix")) {
            fprintf(stderr, "Error: missing '# routing_matrix' section\n");
            fclose(fp);
            return -1;
        }
        if (parse_routing_matrix(fp, net->d, net->routing[0]) != 0) {
            fclose(fp);
            return -1;
        }
    }

    fclose(fp);
    return 0;
}
