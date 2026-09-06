/*
 * bnet_json.h — strict, dependency-free JSON reader, header-only.
 *
 * Why this exists: three solvers (BNArmc, BNAqbd, BNAtc/fBNAgc) now ship a C
 * engine beside their Python one, and both engines must read the SAME input
 * document the GUI exports. cJSON was the obvious candidate and was rejected:
 * it is a Homebrew dependency, and the one solver that already needs it
 * (BNAmd) is therefore optional in the packaged app. A method the user can
 * select from Settings must not be optional, so the parser is vendored here
 * instead — ~450 lines, C99, no allocation per node beyond two arena blocks.
 *
 * Deliberately strict, because it reads a machine-written document and a
 * silently-accepted malformation would surface as a wrong number rather than
 * an error: no comments, no trailing commas, no single quotes, no NaN or
 * Infinity literals, no duplicate keys inside one object, and a document that
 * does not consume its whole input is refused.
 *
 * Usage:
 *     bnet_json doc;
 *     if (!bnet_json_parse_file(&doc, path)) { fputs(doc.error, stderr); ... }
 *     int root = doc.root;
 *     int nodes = bnet_json_member(&doc, root, "nodes");
 *     for (i = 0; i < bnet_json_count(&doc, nodes); i++) {
 *         int n = bnet_json_at(&doc, nodes, i);
 *         double rate;
 *         if (!bnet_json_number(&doc, bnet_json_member(&doc, n, "rate"), &rate)) ...
 *     }
 *     bnet_json_free(&doc);
 *
 * Every accessor takes a node index and tolerates BNET_JSON_NONE (-1), so a
 * missing member propagates as "absent" instead of crashing; the caller
 * decides whether absent is an error. That is the one convenience in here.
 */

#ifndef BNET_JSON_H
#define BNET_JSON_H

#include <ctype.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define BNET_JSON_NONE (-1)

enum bnet_json_type {
    BNET_JSON_NULL = 0,
    BNET_JSON_BOOL,
    BNET_JSON_NUMBER,
    BNET_JSON_STRING,
    BNET_JSON_ARRAY,
    BNET_JSON_OBJECT
};

typedef struct {
    int    type;
    double number;      /* NUMBER: the value; BOOL: 0 or 1                  */
    int    text;        /* STRING and object member KEY: offset into pool   */
    int    first;       /* ARRAY/OBJECT: index of first child, else NONE    */
    int    next;        /* next sibling within the parent, else NONE        */
    int    count;       /* ARRAY/OBJECT: number of children                 */
    int    key;         /* object member: offset of its key, else -1        */
} bnet_json_node;

typedef struct {
    bnet_json_node *nodes;
    int             node_count;
    int             node_capacity;
    char           *pool;          /* NUL-separated decoded strings */
    int             pool_len;
    int             pool_capacity;
    char           *text;          /* owned copy of the document */
    int             root;
    char            error[256];
} bnet_json;

/* ---------------------------------------------------------------- internals */

typedef struct {
    bnet_json  *doc;
    const char *p;
    const char *start;
    int         ok;
} bnet_json_parser;

static inline void bnet_json_fail(bnet_json_parser *ps, const char *what)
{
    long line = 1, col = 1;
    const char *q;
    if (!ps->ok) return;                     /* keep the FIRST failure */
    ps->ok = 0;
    for (q = ps->start; q < ps->p && *q; q++) {
        if (*q == '\n') { line++; col = 1; } else { col++; }
    }
    snprintf(ps->doc->error, sizeof ps->doc->error,
             "JSON parse error at line %ld column %ld: %s", line, col, what);
}

static inline int bnet_json_new_node(bnet_json_parser *ps, int type)
{
    bnet_json *d = ps->doc;
    if (d->node_count == d->node_capacity) {
        int cap = d->node_capacity ? d->node_capacity * 2 : 64;
        bnet_json_node *grown;
        if (cap > 40000000) { bnet_json_fail(ps, "document has too many nodes"); return BNET_JSON_NONE; }
        grown = (bnet_json_node *)realloc(d->nodes, (size_t)cap * sizeof *grown);
        if (!grown) { bnet_json_fail(ps, "out of memory"); return BNET_JSON_NONE; }
        d->nodes = grown;
        d->node_capacity = cap;
    }
    {
        bnet_json_node *n = &d->nodes[d->node_count];
        n->type = type; n->number = 0.0; n->text = -1;
        n->first = BNET_JSON_NONE; n->next = BNET_JSON_NONE;
        n->count = 0; n->key = -1;
    }
    return d->node_count++;
}

static inline int bnet_json_pool_put(bnet_json_parser *ps, const char *s, int len)
{
    bnet_json *d = ps->doc;
    int offset;
    if (d->pool_len + len + 1 > d->pool_capacity) {
        int cap = d->pool_capacity ? d->pool_capacity : 256;
        char *grown;
        while (cap < d->pool_len + len + 1) {
            if (cap > (1 << 29)) { bnet_json_fail(ps, "string pool too large"); return -1; }
            cap *= 2;
        }
        grown = (char *)realloc(d->pool, (size_t)cap);
        if (!grown) { bnet_json_fail(ps, "out of memory"); return -1; }
        d->pool = grown;
        d->pool_capacity = cap;
    }
    offset = d->pool_len;
    memcpy(d->pool + offset, s, (size_t)len);
    d->pool[offset + len] = '\0';
    d->pool_len += len + 1;
    return offset;
}

static inline void bnet_json_skip_ws(bnet_json_parser *ps)
{
    while (*ps->p == ' ' || *ps->p == '\t' || *ps->p == '\n' || *ps->p == '\r') ps->p++;
}

static inline int bnet_json_value(bnet_json_parser *ps);

/* Decodes into a scratch buffer the caller frees. Rejects raw control
 * characters and lone surrogates; \u escapes become UTF-8. */
static inline char *bnet_json_scan_string(bnet_json_parser *ps, int *out_len)
{
    const char *p = ps->p;
    char *buf;
    int len = 0, cap;
    if (*p != '"') { bnet_json_fail(ps, "expected a string"); return NULL; }
    p++;
    cap = 32;
    buf = (char *)malloc((size_t)cap);
    if (!buf) { bnet_json_fail(ps, "out of memory"); return NULL; }
    for (;;) {
        unsigned char c = (unsigned char)*p;
        if (c == '"') { p++; break; }
        if (c == '\0') { free(buf); ps->p = p; bnet_json_fail(ps, "unterminated string"); return NULL; }
        if (c < 0x20) { free(buf); ps->p = p; bnet_json_fail(ps, "raw control character in string"); return NULL; }
        if (len + 5 > cap) {
            char *grown;
            cap *= 2;
            grown = (char *)realloc(buf, (size_t)cap);
            if (!grown) { free(buf); bnet_json_fail(ps, "out of memory"); return NULL; }
            buf = grown;
        }
        if (c != '\\') { buf[len++] = (char)c; p++; continue; }
        p++;
        switch (*p) {
        case '"':  buf[len++] = '"';  p++; break;
        case '\\': buf[len++] = '\\'; p++; break;
        case '/':  buf[len++] = '/';  p++; break;
        case 'b':  buf[len++] = '\b'; p++; break;
        case 'f':  buf[len++] = '\f'; p++; break;
        case 'n':  buf[len++] = '\n'; p++; break;
        case 'r':  buf[len++] = '\r'; p++; break;
        case 't':  buf[len++] = '\t'; p++; break;
        case 'u': {
            unsigned long cp = 0;
            int i;
            p++;
            for (i = 0; i < 4; i++) {
                int hv;
                char h = p[i];
                if      (h >= '0' && h <= '9') hv = h - '0';
                else if (h >= 'a' && h <= 'f') hv = h - 'a' + 10;
                else if (h >= 'A' && h <= 'F') hv = h - 'A' + 10;
                else { free(buf); ps->p = p; bnet_json_fail(ps, "bad \\u escape"); return NULL; }
                cp = cp * 16 + (unsigned long)hv;
            }
            p += 4;
            if (cp >= 0xD800 && cp <= 0xDBFF) {          /* high surrogate */
                unsigned long lo = 0;
                int j;
                if (p[0] != '\\' || p[1] != 'u') { free(buf); ps->p = p; bnet_json_fail(ps, "unpaired surrogate"); return NULL; }
                p += 2;
                for (j = 0; j < 4; j++) {
                    int hv;
                    char h = p[j];
                    if      (h >= '0' && h <= '9') hv = h - '0';
                    else if (h >= 'a' && h <= 'f') hv = h - 'a' + 10;
                    else if (h >= 'A' && h <= 'F') hv = h - 'A' + 10;
                    else { free(buf); ps->p = p; bnet_json_fail(ps, "bad \\u escape"); return NULL; }
                    lo = lo * 16 + (unsigned long)hv;
                }
                p += 4;
                if (lo < 0xDC00 || lo > 0xDFFF) { free(buf); ps->p = p; bnet_json_fail(ps, "unpaired surrogate"); return NULL; }
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
            } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
                free(buf); ps->p = p; bnet_json_fail(ps, "unpaired low surrogate"); return NULL;
            }
            if (cp < 0x80) {
                buf[len++] = (char)cp;
            } else if (cp < 0x800) {
                buf[len++] = (char)(0xC0 | (cp >> 6));
                buf[len++] = (char)(0x80 | (cp & 0x3F));
            } else if (cp < 0x10000) {
                buf[len++] = (char)(0xE0 | (cp >> 12));
                buf[len++] = (char)(0x80 | ((cp >> 6) & 0x3F));
                buf[len++] = (char)(0x80 | (cp & 0x3F));
            } else {
                buf[len++] = (char)(0xF0 | (cp >> 18));
                buf[len++] = (char)(0x80 | ((cp >> 12) & 0x3F));
                buf[len++] = (char)(0x80 | ((cp >> 6) & 0x3F));
                buf[len++] = (char)(0x80 | (cp & 0x3F));
            }
            break;
        }
        default:
            free(buf); ps->p = p; bnet_json_fail(ps, "unknown escape sequence"); return NULL;
        }
    }
    buf[len] = '\0';
    *out_len = len;
    ps->p = p;
    return buf;
}

static inline int bnet_json_object(bnet_json_parser *ps)
{
    int node = bnet_json_new_node(ps, BNET_JSON_OBJECT);
    int last = BNET_JSON_NONE;
    if (node == BNET_JSON_NONE) return BNET_JSON_NONE;
    ps->p++;                                       /* '{' */
    bnet_json_skip_ws(ps);
    if (*ps->p == '}') { ps->p++; return node; }
    for (;;) {
        int keylen, keyoff, child, existing;
        char *key;
        bnet_json_skip_ws(ps);
        key = bnet_json_scan_string(ps, &keylen);
        if (!key) return BNET_JSON_NONE;
        keyoff = bnet_json_pool_put(ps, key, keylen);
        free(key);
        if (keyoff < 0) return BNET_JSON_NONE;
        bnet_json_skip_ws(ps);
        if (*ps->p != ':') { bnet_json_fail(ps, "expected ':' after an object key"); return BNET_JSON_NONE; }
        ps->p++;
        bnet_json_skip_ws(ps);
        child = bnet_json_value(ps);
        if (child == BNET_JSON_NONE) return BNET_JSON_NONE;
        /* A duplicate key means the writer and the reader disagree about the
         * document; refusing beats silently taking one of the two values. */
        for (existing = ps->doc->nodes[node].first; existing != BNET_JSON_NONE;
             existing = ps->doc->nodes[existing].next) {
            if (strcmp(ps->doc->pool + ps->doc->nodes[existing].key,
                       ps->doc->pool + keyoff) == 0) {
                bnet_json_fail(ps, "duplicate key in one object");
                return BNET_JSON_NONE;
            }
        }
        ps->doc->nodes[child].key = keyoff;
        if (last == BNET_JSON_NONE) ps->doc->nodes[node].first = child;
        else                        ps->doc->nodes[last].next = child;
        last = child;
        ps->doc->nodes[node].count++;
        bnet_json_skip_ws(ps);
        if (*ps->p == ',') { ps->p++; continue; }
        if (*ps->p == '}') { ps->p++; return node; }
        bnet_json_fail(ps, "expected ',' or '}' in an object");
        return BNET_JSON_NONE;
    }
}

static inline int bnet_json_array(bnet_json_parser *ps)
{
    int node = bnet_json_new_node(ps, BNET_JSON_ARRAY);
    int last = BNET_JSON_NONE;
    if (node == BNET_JSON_NONE) return BNET_JSON_NONE;
    ps->p++;                                       /* '[' */
    bnet_json_skip_ws(ps);
    if (*ps->p == ']') { ps->p++; return node; }
    for (;;) {
        int child;
        bnet_json_skip_ws(ps);
        child = bnet_json_value(ps);
        if (child == BNET_JSON_NONE) return BNET_JSON_NONE;
        if (last == BNET_JSON_NONE) ps->doc->nodes[node].first = child;
        else                        ps->doc->nodes[last].next = child;
        last = child;
        ps->doc->nodes[node].count++;
        bnet_json_skip_ws(ps);
        if (*ps->p == ',') { ps->p++; continue; }
        if (*ps->p == ']') { ps->p++; return node; }
        bnet_json_fail(ps, "expected ',' or ']' in an array");
        return BNET_JSON_NONE;
    }
}

static inline int bnet_json_value(bnet_json_parser *ps)
{
    bnet_json_skip_ws(ps);
    switch (*ps->p) {
    case '{': return bnet_json_object(ps);
    case '[': return bnet_json_array(ps);
    case '"': {
        int len, off, node;
        char *s = bnet_json_scan_string(ps, &len);
        if (!s) return BNET_JSON_NONE;
        off = bnet_json_pool_put(ps, s, len);
        free(s);
        if (off < 0) return BNET_JSON_NONE;
        node = bnet_json_new_node(ps, BNET_JSON_STRING);
        if (node == BNET_JSON_NONE) return BNET_JSON_NONE;
        ps->doc->nodes[node].text = off;
        return node;
    }
    case 't':
        if (strncmp(ps->p, "true", 4) != 0) { bnet_json_fail(ps, "expected 'true'"); return BNET_JSON_NONE; }
        ps->p += 4;
        { int n = bnet_json_new_node(ps, BNET_JSON_BOOL);
          if (n != BNET_JSON_NONE) ps->doc->nodes[n].number = 1.0;
          return n; }
    case 'f':
        if (strncmp(ps->p, "false", 5) != 0) { bnet_json_fail(ps, "expected 'false'"); return BNET_JSON_NONE; }
        ps->p += 5;
        { int n = bnet_json_new_node(ps, BNET_JSON_BOOL);
          if (n != BNET_JSON_NONE) ps->doc->nodes[n].number = 0.0;
          return n; }
    case 'n':
        if (strncmp(ps->p, "null", 4) != 0) { bnet_json_fail(ps, "expected 'null'"); return BNET_JSON_NONE; }
        ps->p += 4;
        return bnet_json_new_node(ps, BNET_JSON_NULL);
    default: {
        /* Hand-validate the JSON number grammar before strtod, because strtod
         * also accepts "nan", "inf", "0x10" and a leading '+', none of which
         * are JSON, and accepting them here would let a malformed document
         * become a plausible-looking rate. */
        const char *b = ps->p;
        const char *q = b;
        char *end;
        double value;
        int node;
        if (*q == '-') q++;
        if (*q == '0') { q++; }
        else if (*q >= '1' && *q <= '9') { while (*q >= '0' && *q <= '9') q++; }
        else { bnet_json_fail(ps, "expected a value"); return BNET_JSON_NONE; }
        if (*q == '.') { q++; if (!(*q >= '0' && *q <= '9')) { ps->p = q; bnet_json_fail(ps, "digit expected after '.'"); return BNET_JSON_NONE; }
                         while (*q >= '0' && *q <= '9') q++; }
        if (*q == 'e' || *q == 'E') { q++; if (*q == '+' || *q == '-') q++;
                         if (!(*q >= '0' && *q <= '9')) { ps->p = q; bnet_json_fail(ps, "digit expected in exponent"); return BNET_JSON_NONE; }
                         while (*q >= '0' && *q <= '9') q++; }
        errno = 0;
        value = strtod(b, &end);
        if (end != q) { bnet_json_fail(ps, "malformed number"); return BNET_JSON_NONE; }
        ps->p = q;
        node = bnet_json_new_node(ps, BNET_JSON_NUMBER);
        if (node == BNET_JSON_NONE) return BNET_JSON_NONE;
        ps->doc->nodes[node].number = value;
        return node;
    }
    }
}

/* ------------------------------------------------------------------- public */

static inline void bnet_json_free(bnet_json *d)
{
    free(d->nodes); free(d->pool); free(d->text);
    d->nodes = NULL; d->pool = NULL; d->text = NULL;
    d->node_count = d->node_capacity = d->pool_len = d->pool_capacity = 0;
    d->root = BNET_JSON_NONE;
}

static inline int bnet_json_parse(bnet_json *d, char *owned_text)
{
    bnet_json_parser ps;
    memset(d, 0, sizeof *d);
    d->root = BNET_JSON_NONE;
    d->text = owned_text;
    ps.doc = d; ps.p = owned_text; ps.start = owned_text; ps.ok = 1;
    d->root = bnet_json_value(&ps);
    if (ps.ok) {
        bnet_json_skip_ws(&ps);
        if (*ps.p != '\0') bnet_json_fail(&ps, "trailing content after the document");
    }
    if (!ps.ok) { d->root = BNET_JSON_NONE; return 0; }
    return 1;
}

static inline int bnet_json_parse_file(bnet_json *d, const char *path)
{
    FILE *f;
    char *buf;
    long size;
    size_t got;
    memset(d, 0, sizeof *d);
    d->root = BNET_JSON_NONE;
    if (strcmp(path, "-") == 0) {
        size_t cap = 65536, len = 0;
        buf = (char *)malloc(cap);
        if (!buf) { snprintf(d->error, sizeof d->error, "out of memory"); return 0; }
        for (;;) {
            size_t n = fread(buf + len, 1, cap - len - 1, stdin);
            len += n;
            if (len + 1 < cap) break;
            cap *= 2;
            { char *grown = (char *)realloc(buf, cap);
              if (!grown) { free(buf); snprintf(d->error, sizeof d->error, "out of memory"); return 0; }
              buf = grown; }
        }
        buf[len] = '\0';
        return bnet_json_parse(d, buf);
    }
    f = fopen(path, "rb");
    if (!f) { snprintf(d->error, sizeof d->error, "cannot open %s", path); return 0; }
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); snprintf(d->error, sizeof d->error, "cannot size %s", path); return 0; }
    size = ftell(f);
    if (size < 0) { fclose(f); snprintf(d->error, sizeof d->error, "cannot size %s", path); return 0; }
    rewind(f);
    buf = (char *)malloc((size_t)size + 1);
    if (!buf) { fclose(f); snprintf(d->error, sizeof d->error, "out of memory reading %s", path); return 0; }
    got = fread(buf, 1, (size_t)size, f);
    fclose(f);
    buf[got] = '\0';
    return bnet_json_parse(d, buf);
}

static inline int bnet_json_type_of(const bnet_json *d, int node)
{
    if (node == BNET_JSON_NONE || node >= d->node_count) return -1;
    return d->nodes[node].type;
}

static inline int bnet_json_member(const bnet_json *d, int node, const char *key)
{
    int child;
    if (node == BNET_JSON_NONE || d->nodes[node].type != BNET_JSON_OBJECT) return BNET_JSON_NONE;
    for (child = d->nodes[node].first; child != BNET_JSON_NONE; child = d->nodes[child].next) {
        if (d->nodes[child].key >= 0 && strcmp(d->pool + d->nodes[child].key, key) == 0) return child;
    }
    return BNET_JSON_NONE;
}

static inline int bnet_json_count(const bnet_json *d, int node)
{
    if (node == BNET_JSON_NONE) return 0;
    if (d->nodes[node].type != BNET_JSON_ARRAY && d->nodes[node].type != BNET_JSON_OBJECT) return 0;
    return d->nodes[node].count;
}

static inline int bnet_json_at(const bnet_json *d, int node, int index)
{
    int child, i = 0;
    if (node == BNET_JSON_NONE) return BNET_JSON_NONE;
    if (d->nodes[node].type != BNET_JSON_ARRAY && d->nodes[node].type != BNET_JSON_OBJECT) return BNET_JSON_NONE;
    for (child = d->nodes[node].first; child != BNET_JSON_NONE; child = d->nodes[child].next, i++) {
        if (i == index) return child;
    }
    return BNET_JSON_NONE;
}

/* The key of an object member, or NULL. */
static inline const char *bnet_json_key_of(const bnet_json *d, int node)
{
    if (node == BNET_JSON_NONE || d->nodes[node].key < 0) return NULL;
    return d->pool + d->nodes[node].key;
}

/* Reads a number. Returns 0 for a missing node or a non-number, so a caller
 * that wants "required" and one that wants "default if absent" both work. */
static inline int bnet_json_number(const bnet_json *d, int node, double *out)
{
    if (node == BNET_JSON_NONE || d->nodes[node].type != BNET_JSON_NUMBER) return 0;
    *out = d->nodes[node].number;
    return 1;
}

static inline double bnet_json_number_or(const bnet_json *d, int node, double fallback)
{
    double v;
    return bnet_json_number(d, node, &v) ? v : fallback;
}

static inline int bnet_json_bool(const bnet_json *d, int node, int *out)
{
    if (node == BNET_JSON_NONE || d->nodes[node].type != BNET_JSON_BOOL) return 0;
    *out = d->nodes[node].number != 0.0;
    return 1;
}

static inline int bnet_json_bool_or(const bnet_json *d, int node, int fallback)
{
    int v;
    return bnet_json_bool(d, node, &v) ? v : fallback;
}

static inline const char *bnet_json_string(const bnet_json *d, int node)
{
    if (node == BNET_JSON_NONE || d->nodes[node].type != BNET_JSON_STRING) return NULL;
    return d->pool + d->nodes[node].text;
}

static inline const char *bnet_json_string_or(const bnet_json *d, int node, const char *fallback)
{
    const char *s = bnet_json_string(d, node);
    return s ? s : fallback;
}

static inline int bnet_json_is_null(const bnet_json *d, int node)
{
    return node != BNET_JSON_NONE && d->nodes[node].type == BNET_JSON_NULL;
}

#endif /* BNET_JSON_H */
