/*
 * parser.h - Input file parser for fBNA queueing network exports
 */

#ifndef PARSER_H
#define PARSER_H

#include "distributions.h"

#define MAX_STATIONS 64
/* Bumped from 16 to 64 to accommodate the NetworkExporter "synth class"
 * expansion: a Qnet source with split routing into N entry stations is
 * encoded as N separate simulator classes (one per entry station) so the
 * sim's single-entry-per-class API can represent it. Worst case is
 * (#sources) * (#stations) classes. */
#define MAX_CLASSES  64

typedef struct {
    int          K;                                        /* customer classes */
    int          d;                                        /* number of stations */
    Distribution arrival_dist[MAX_CLASSES];                /* per-class interarrival */
    /* Per-class entry station (0-indexed). When the optional
     * "# arrival_stations" section is absent, every class enters at
     * station 0 (legacy behavior). When present, the section lists K
     * 1-indexed station IDs; the parser converts to 0-indexed. */
    int          arrival_station[MAX_CLASSES];
    int          servers[MAX_STATIONS];                    /* servers per station */
    int          buffer_size[MAX_STATIONS];                /* waiting room per station */
    Distribution service_dist[MAX_STATIONS][MAX_CLASSES];  /* per-station per-class */
    double       routing[MAX_CLASSES][MAX_STATIONS][MAX_STATIONS]; /* per-class P[i][j] */
} Network;

/* Parse a network description file.  Returns 0 on success, -1 on error.
 * Error messages are printed to stderr. */
int parse_network_file(const char *filename, Network *net);

#endif /* PARSER_H */
