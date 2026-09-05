/* bnet_parser.c — Direct parser for .bnet JSON files via cJSON.
 *
 * The GUI exports a network as JSON with this shape:
 *
 *   {
 *     "canvasScale": 1,
 *     "infiniteBuffers": true|false,
 *     "nodes": [ { "id":..., "kind":"source|buffer|station|sink",
 *                  "name":..., "distribution":..., "distributionParameters":...,
 *                  "bufferSize":..., "numberOfServers":...,
 *                  "serviceDistributions": {} or { "0": {...}, "1": {...}, ... } } ],
 *     "links": [ { "fromNodeID":..., "toNodeID":..., "customerClass":N,
 *                  "routingProbability":p } ]
 *   }
 *
 * The topology is always Source → Buffer → Station → Buffer → Station → ... → Sink.
 * We produce an MCNetwork where:
 *   - sources[c] corresponds to class c (inferred from source name "Src<k>")
 *   - stations[i] corresponds to station index i (from name "S<k>")
 *   - per-class routing matrix P[c][i][j] is built by looking at the class-tagged
 *     links leaving a station (through a buffer) into another station
 */

#include "mc_srbm.h"

#include <cjson/cJSON.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <errno.h>

#define ERRLOG(...) do { snprintf(errbuf, errbuf_len, __VA_ARGS__); } while(0)

/* ─── Tiny helpers for pulling a trailing integer out of a name ──────── */
static int name_index(const char *s)
{
    int i = (int)strlen(s) - 1;
    while (i >= 0 && isdigit((unsigned char)s[i])) i--;
    return atoi(s + i + 1);
}

/* ─── Distribution parameter parsing (handles "rate=1.0, k=4" style) ── */
static int parse_param(const char *text, const char *key, double *out)
{
    const char *p = strstr(text, key);
    if (!p) return 0;
    p += strlen(key);
    while (*p == ' ' || *p == '=' || *p == ':') p++;
    *out = atof(p);
    return 1;
}

static MCDistKind distkind_of(const char *name)
{
    if (!name) return DIST_UNKNOWN;
    if (!strcmp(name, "exponential"))  return DIST_EXPONENTIAL;
    if (!strcmp(name, "erlang"))       return DIST_ERLANG;
    if (!strcmp(name, "gamma"))        return DIST_GAMMA;
    if (!strcmp(name, "constant"))     return DIST_CONSTANT;
    if (!strcmp(name, "uniform"))      return DIST_UNIFORM;
    if (!strcmp(name, "weibull"))      return DIST_WEIBULL;
    if (!strcmp(name, "lognormal"))    return DIST_LOGNORMAL;
    if (!strcmp(name, "pareto"))       return DIST_PARETO;
    if (!strcmp(name, "poisson"))      return DIST_POISSON;
    return DIST_UNKNOWN;
}

static void fill_dist(MCDist *d, const char *dist_name, const char *dist_params)
{
    d->kind = distkind_of(dist_name);
    d->p0 = d->p1 = d->p2 = 0.0;

    if (!dist_params) { d->p0 = 1.0; return; }

    switch (d->kind) {
    case DIST_EXPONENTIAL:
        parse_param(dist_params, "rate",  &d->p0);
        if (d->p0 == 0.0) parse_param(dist_params, "lambda", &d->p0);
        break;
    case DIST_ERLANG:
        parse_param(dist_params, "k",     &d->p0);
        parse_param(dist_params, "rate",  &d->p1);
        if (d->p1 == 0.0) parse_param(dist_params, "lambda", &d->p1);
        break;
    case DIST_GAMMA:
        parse_param(dist_params, "shape", &d->p0);
        parse_param(dist_params, "scale", &d->p1);
        break;
    case DIST_CONSTANT:
        parse_param(dist_params, "value", &d->p0);
        break;
    case DIST_UNIFORM:
        parse_param(dist_params, "min",   &d->p0);
        parse_param(dist_params, "max",   &d->p1);
        if (d->p1 == 0.0) parse_param(dist_params, "a", &d->p0);
        if (d->p1 == 0.0) parse_param(dist_params, "b", &d->p1);
        break;
    case DIST_WEIBULL:
        parse_param(dist_params, "shape", &d->p0);
        parse_param(dist_params, "scale", &d->p1);
        break;
    case DIST_LOGNORMAL:
        parse_param(dist_params, "mu",    &d->p0);
        parse_param(dist_params, "sigma", &d->p1);
        break;
    case DIST_PARETO:
        parse_param(dist_params, "shape", &d->p0);
        parse_param(dist_params, "scale", &d->p1);
        break;
    case DIST_POISSON:
        parse_param(dist_params, "lambda", &d->p0);
        if (d->p0 == 0.0) parse_param(dist_params, "rate", &d->p0);
        break;
    default:
        d->p0 = 1.0;
        break;
    }
    if (d->kind == DIST_EXPONENTIAL && d->p0 == 0.0) d->p0 = 1.0;
}

/* ─── Node lookup tables ─────────────────────────────────────────────── */
typedef struct {
    const char *id;
    const char *name;
    const char *kind;
    int    station_idx;     /* -1 if not a station */
    int    source_idx;      /* -1 if not a source */
    int    buffer_idx;      /* -1 if not a buffer */
    int    sink_idx;        /* -1 if not a sink */
    cJSON *json;
} NodeRec;

static int load_file(const char *path, char **content_out)
{
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    rewind(f);
    char *buf = (char*)malloc(n + 1);
    if (!buf) { fclose(f); return -1; }
    if (fread(buf, 1, n, f) != (size_t)n) { free(buf); fclose(f); return -1; }
    buf[n] = 0;
    fclose(f);
    *content_out = buf;
    return 0;
}

int mc_parse_bnet(const char *path, MCNetwork *net,
                  char *errbuf, size_t errbuf_len)
{
    memset(net, 0, sizeof(*net));
    char *text = NULL;
    if (load_file(path, &text) != 0) {
        ERRLOG("cannot read %s (%s)", path, strerror(errno));
        return -1;
    }

    cJSON *root = cJSON_Parse(text);
    if (!root) {
        ERRLOG("JSON parse error near: %s", cJSON_GetErrorPtr());
        free(text);
        return -1;
    }

    cJSON *jinf = cJSON_GetObjectItemCaseSensitive(root, "infiniteBuffers");
    net->infinite_buffer = (jinf && cJSON_IsBool(jinf) && cJSON_IsTrue(jinf)) ? 1 : 0;

    cJSON *jnodes = cJSON_GetObjectItemCaseSensitive(root, "nodes");
    cJSON *jlinks = cJSON_GetObjectItemCaseSensitive(root, "links");
    if (!cJSON_IsArray(jnodes) || !cJSON_IsArray(jlinks)) {
        ERRLOG("missing nodes/links arrays");
        cJSON_Delete(root);
        free(text);
        return -1;
    }

    /* First pass: classify nodes, set indices from names. */
    int n_nodes = cJSON_GetArraySize(jnodes);
    NodeRec *nodes = (NodeRec*)calloc(n_nodes, sizeof(NodeRec));

    int next_station_from_name = 0, next_source_from_name = 0;
    int max_station_idx = -1, max_source_idx = -1;

    for (int i = 0; i < n_nodes; i++) {
        cJSON *jn = cJSON_GetArrayItem(jnodes, i);
        const char *id    = cJSON_GetStringValue(cJSON_GetObjectItem(jn, "id"));
        const char *name  = cJSON_GetStringValue(cJSON_GetObjectItem(jn, "name"));
        const char *kind  = cJSON_GetStringValue(cJSON_GetObjectItem(jn, "kind"));
        if (!id || !name || !kind) {
            ERRLOG("node %d missing id/name/kind", i);
            free(nodes); cJSON_Delete(root); free(text); return -1;
        }
        nodes[i].id = id;
        nodes[i].name = name;
        nodes[i].kind = kind;
        nodes[i].station_idx = nodes[i].source_idx = nodes[i].buffer_idx = nodes[i].sink_idx = -1;
        nodes[i].json = jn;

        if (!strcmp(kind, "station")) {
            int idx = name_index(name) - 1;           /* S1 → 0, S2 → 1, ... */
            if (idx < 0) idx = next_station_from_name++;
            if (idx >= MC_MAX_DIM) {
                ERRLOG("too many stations (max %d)", MC_MAX_DIM);
                free(nodes); cJSON_Delete(root); free(text); return -1;
            }
            nodes[i].station_idx = idx;
            if (idx > max_station_idx) max_station_idx = idx;
        } else if (!strcmp(kind, "source")) {
            int idx = name_index(name) - 1;           /* Src1 → class 0, Src2 → class 1 */
            if (idx < 0) idx = next_source_from_name++;
            if (idx >= MC_MAX_CLASSES) {
                ERRLOG("too many customer classes (max %d)", MC_MAX_CLASSES);
                free(nodes); cJSON_Delete(root); free(text); return -1;
            }
            nodes[i].source_idx = idx;
            if (idx > max_source_idx) max_source_idx = idx;
        }
    }

    net->d = max_station_idx + 1;
    net->K = max_source_idx  + 1;
    if (net->d <= 0 || net->K <= 0) {
        ERRLOG("no stations or sources");
        free(nodes); cJSON_Delete(root); free(text); return -1;
    }

    /* ─── Fill stations from JSON ──────────────────────────────────── */
    for (int i = 0; i < n_nodes; i++) {
        NodeRec *nr = &nodes[i];
        if (nr->station_idx < 0) continue;
        MCStation *st = &net->stations[nr->station_idx];
        st->station_idx = nr->station_idx;
        strncpy(st->name, nr->name, MC_NAME_LEN - 1);

        cJSON *jns = cJSON_GetObjectItem(nr->json, "numberOfServers");
        st->num_servers = (jns && cJSON_IsNumber(jns)) ? jns->valueint : 1;
        if (st->num_servers < 1) st->num_servers = 1;

        st->infinite_buffer = net->infinite_buffer;
        /* bufferSize at the station itself is 1 (it's a service slot).  The
         * real buffer size comes from the preceding Buffer node; we will
         * look that up after classifying nodes. */
        st->buffer_size = 0;

        cJSON *jdist   = cJSON_GetObjectItem(nr->json, "distribution");
        cJSON *jparams = cJSON_GetObjectItem(nr->json, "distributionParameters");
        fill_dist(&st->default_service_dist,
                  cJSON_GetStringValue(jdist),
                  cJSON_GetStringValue(jparams));

        /* Per-class overrides. */
        cJSON *jsvc = cJSON_GetObjectItem(nr->json, "serviceDistributions");
        int any_override = 0;
        for (int c = 0; c < net->K; c++) st->service[c] = st->default_service_dist;
        if (cJSON_IsObject(jsvc)) {
            cJSON *child = NULL;
            cJSON_ArrayForEach(child, jsvc) {
                if (!child->string) continue;
                int c = atoi(child->string);
                if (c < 0 || c >= net->K) continue;
                const char *cd = cJSON_GetStringValue(cJSON_GetObjectItem(child, "distribution"));
                const char *cp = cJSON_GetStringValue(cJSON_GetObjectItem(child, "distributionParameters"));
                fill_dist(&st->service[c], cd, cp);
                any_override = 1;
            }
        }
        st->default_service = !any_override;
    }

    /* ─── Fill sources ─────────────────────────────────────────────── */
    for (int i = 0; i < n_nodes; i++) {
        NodeRec *nr = &nodes[i];
        if (nr->source_idx < 0) continue;
        MCSource *sr = &net->sources[nr->source_idx];
        sr->class_idx = nr->source_idx;
        cJSON *jdist   = cJSON_GetObjectItem(nr->json, "distribution");
        cJSON *jparams = cJSON_GetObjectItem(nr->json, "distributionParameters");
        fill_dist(&sr->arrival,
                  cJSON_GetStringValue(jdist),
                  cJSON_GetStringValue(jparams));
        sr->entry_station = -1;   /* resolved below via the link graph */
    }

    /* ─── Build an id→NodeRec map ──────────────────────────────────── */
    /* For 10–100 nodes the N² lookup is fine. */
    int n_links = cJSON_GetArraySize(jlinks);

    /* For each station, find its feeding buffer (must be unique).  The
     * topology is guaranteed: Buffer → Station direct link per class. */
    int buffer_of_station[MC_MAX_DIM];
    for (int i = 0; i < MC_MAX_DIM; i++) buffer_of_station[i] = -1;

    for (int L = 0; L < n_links; L++) {
        cJSON *jl = cJSON_GetArrayItem(jlinks, L);
        const char *from = cJSON_GetStringValue(cJSON_GetObjectItem(jl, "fromNodeID"));
        const char *to   = cJSON_GetStringValue(cJSON_GetObjectItem(jl, "toNodeID"));
        if (!from || !to) continue;

        NodeRec *nfrom = NULL, *nto = NULL;
        for (int i = 0; i < n_nodes; i++) {
            if (!strcmp(nodes[i].id, from)) nfrom = &nodes[i];
            if (!strcmp(nodes[i].id, to))   nto   = &nodes[i];
        }
        if (!nfrom || !nto) continue;

        /* Buffer → Station: bufferSize of that buffer sets station's a_i */
        if (!strcmp(nfrom->kind, "buffer") && nto->station_idx >= 0) {
            int sidx = nto->station_idx;
            cJSON *jbs = cJSON_GetObjectItem(nfrom->json, "bufferSize");
            net->stations[sidx].buffer_size = (jbs && cJSON_IsNumber(jbs)) ? jbs->valueint : 10;
            buffer_of_station[sidx] = 1;
        }

        /* Source → Buffer: records the source's entry station (which is the
         * station that this buffer feeds).  We look it up by scanning
         * links from that buffer to a station. */
        if (nfrom->source_idx >= 0 && !strcmp(nto->kind, "buffer")) {
            /* find the station this buffer feeds */
            const char *buf_id = nto->id;
            for (int L2 = 0; L2 < n_links; L2++) {
                cJSON *jl2 = cJSON_GetArrayItem(jlinks, L2);
                const char *f2 = cJSON_GetStringValue(cJSON_GetObjectItem(jl2, "fromNodeID"));
                const char *t2 = cJSON_GetStringValue(cJSON_GetObjectItem(jl2, "toNodeID"));
                if (!f2 || !t2) continue;
                if (strcmp(f2, buf_id) != 0) continue;
                for (int i = 0; i < n_nodes; i++) {
                    if (!strcmp(nodes[i].id, t2) && nodes[i].station_idx >= 0) {
                        net->sources[nfrom->source_idx].entry_station = nodes[i].station_idx;
                    }
                }
            }
        }
    }

    /* Fill routing matrix P[c][i][j]. Walk each class-tagged link that
     * starts at some station and ends (via a buffer) at another station —
     * that gives a_ij for that class.  For station → sink (either direct
     * or via its output buffer), that fraction of traffic leaves. */
    for (int L = 0; L < n_links; L++) {
        cJSON *jl = cJSON_GetArrayItem(jlinks, L);
        cJSON *jcc = cJSON_GetObjectItem(jl, "customerClass");
        cJSON *jp  = cJSON_GetObjectItem(jl, "routingProbability");
        const char *from = cJSON_GetStringValue(cJSON_GetObjectItem(jl, "fromNodeID"));
        const char *to   = cJSON_GetStringValue(cJSON_GetObjectItem(jl, "toNodeID"));
        if (!from || !to || !jcc) continue;
        int c = jcc->valueint;
        double rp = (jp && cJSON_IsNumber(jp)) ? jp->valuedouble : 1.0;

        NodeRec *nfrom = NULL, *nto = NULL;
        for (int i = 0; i < n_nodes; i++) {
            if (!strcmp(nodes[i].id, from)) nfrom = &nodes[i];
            if (!strcmp(nodes[i].id, to))   nto   = &nodes[i];
        }
        if (!nfrom || !nto) continue;
        if (nfrom->station_idx < 0) continue;  /* only track station-out links */
        int from_sidx = nfrom->station_idx;

        /* Case A: direct station → station link (unusual but possible) */
        if (nto->station_idx >= 0 && c < MC_MAX_CLASSES) {
            net->P[c][from_sidx][nto->station_idx] += rp;
        }
        /* Case B: station → buffer → station — walk through buffer */
        else if (!strcmp(nto->kind, "buffer")) {
            const char *buf_id = nto->id;
            for (int L2 = 0; L2 < n_links; L2++) {
                cJSON *jl2 = cJSON_GetArrayItem(jlinks, L2);
                cJSON *jcc2 = cJSON_GetObjectItem(jl2, "customerClass");
                if (!jcc2 || jcc2->valueint != c) continue;
                const char *f2 = cJSON_GetStringValue(cJSON_GetObjectItem(jl2, "fromNodeID"));
                const char *t2 = cJSON_GetStringValue(cJSON_GetObjectItem(jl2, "toNodeID"));
                if (!f2 || !t2 || strcmp(f2, buf_id) != 0) continue;
                for (int i = 0; i < n_nodes; i++) {
                    if (!strcmp(nodes[i].id, t2) && nodes[i].station_idx >= 0) {
                        net->P[c][from_sidx][nodes[i].station_idx] += rp;
                    }
                }
            }
        }
        /* Case C: station → sink (or station → buffer → sink) means flow leaves.
         * We already don't record anything, so implicit rows that sum to
         * < 1 simply lose that fraction to the sink.  That is correct. */
    }

    /* Validate each station has a buffer attached (buffer size known). */
    for (int i = 0; i < net->d; i++) {
        if (net->stations[i].buffer_size <= 0) {
            /* Infinite buffer networks still need a buffer node with some
             * slot count; if missing, treat as 1 (stations only). */
            net->stations[i].buffer_size = 1;
        }
    }

    /* Check each source has an entry station. */
    for (int c = 0; c < net->K; c++) {
        if (net->sources[c].entry_station < 0) {
            ERRLOG("class %d source has no resolved entry station", c + 1);
            free(nodes); cJSON_Delete(root); free(text); return -1;
        }
    }

    free(nodes);
    cJSON_Delete(root);
    free(text);
    return 0;
}
