/* Exercises bnet_json.h: what it must accept, and what it must refuse.
 * The refusals matter more than the acceptances — this parser reads a
 * machine-written document, so anything it wrongly accepts becomes a wrong
 * number rather than an error message. */
#include "../bnet_json.h"
#include <math.h>

static int failures = 0;

static void check(int condition, const char *what)
{
    if (!condition) { printf("  FAIL %s\n", what); failures++; }
}

static void accepts(const char *json, const char *what)
{
    bnet_json d;
    char *copy = strdup(json);
    int ok = bnet_json_parse(&d, copy);
    if (!ok) { printf("  FAIL accept %s: %s\n", what, d.error); failures++; }
    bnet_json_free(&d);
}

static void refuses(const char *json, const char *what)
{
    bnet_json d;
    char *copy = strdup(json);
    int ok = bnet_json_parse(&d, copy);
    if (ok) { printf("  FAIL should have refused %s: %s\n", what, json); failures++; }
    else if (strstr(d.error, "JSON parse error") == NULL) {
        printf("  FAIL refusal of %s lacks a located message: %s\n", what, d.error); failures++;
    }
    bnet_json_free(&d);
}

int main(void)
{
    bnet_json d;
    char *doc;
    int root, nodes, n0, opts;
    double v;

    printf("bnet_json tests\n");

    /* --- a document shaped like a real solver input ------------------- */
    doc = strdup(
      "{\"schema_version\": 1, \"name\": \"M/M/1 \\u2014 \\\"tandem\\\"\",\n"
      " \"nodes\": [ {\"id\": \"a\", \"servers\": 2, \"rate\": 1.5e-3, \"capacity\": null},\n"
      "             {\"id\": \"b\", \"servers\": 1, \"rate\": -0.25, \"capacity\": 7} ],\n"
      " \"options\": {\"adaptive\": true, \"quiet\": false} }");
    check(bnet_json_parse(&d, doc), "parses a solver-shaped document");
    root = d.root;
    check(bnet_json_type_of(&d, root) == BNET_JSON_OBJECT, "root is an object");
    check(bnet_json_number_or(&d, bnet_json_member(&d, root, "schema_version"), -1) == 1.0, "schema_version");
    check(strcmp(bnet_json_string_or(&d, bnet_json_member(&d, root, "name"), ""),
                 "M/M/1 \xe2\x80\x94 \"tandem\"") == 0, "\\u and \\\" decode to UTF-8");
    nodes = bnet_json_member(&d, root, "nodes");
    check(bnet_json_count(&d, nodes) == 2, "two nodes");
    n0 = bnet_json_at(&d, nodes, 0);
    check(strcmp(bnet_json_string_or(&d, bnet_json_member(&d, n0, "id"), ""), "a") == 0, "node id");
    check(bnet_json_number(&d, bnet_json_member(&d, n0, "rate"), &v) && fabs(v - 1.5e-3) < 1e-18, "exponent number");
    check(bnet_json_is_null(&d, bnet_json_member(&d, n0, "capacity")), "null capacity");
    check(bnet_json_number_or(&d, bnet_json_member(&d, bnet_json_at(&d, nodes, 1), "rate"), 0) == -0.25, "negative number");
    check(bnet_json_number_or(&d, bnet_json_member(&d, bnet_json_at(&d, nodes, 1), "capacity"), -1) == 7, "integer capacity");
    opts = bnet_json_member(&d, root, "options");
    check(bnet_json_bool_or(&d, bnet_json_member(&d, opts, "adaptive"), 0) == 1, "true");
    check(bnet_json_bool_or(&d, bnet_json_member(&d, opts, "quiet"), 1) == 0, "false");
    /* An absent member must be navigable without crashing. */
    check(bnet_json_member(&d, root, "absent") == BNET_JSON_NONE, "absent member is NONE");
    check(bnet_json_number_or(&d, bnet_json_member(&d, root, "absent"), 42.0) == 42.0, "absent falls back");
    check(bnet_json_count(&d, bnet_json_member(&d, root, "absent")) == 0, "count of absent is 0");
    check(bnet_json_at(&d, BNET_JSON_NONE, 0) == BNET_JSON_NONE, "index of NONE is NONE");
    check(bnet_json_string(&d, bnet_json_member(&d, root, "absent")) == NULL, "string of absent is NULL");
    /* A wrong TYPE must not be silently coerced. */
    check(!bnet_json_number(&d, bnet_json_member(&d, root, "name"), &v), "a string is not a number");
    check(bnet_json_string(&d, bnet_json_member(&d, root, "schema_version")) == NULL, "a number is not a string");
    /* Object iteration by key. */
    check(strcmp(bnet_json_key_of(&d, bnet_json_at(&d, opts, 0)), "adaptive") == 0, "key of first member");
    bnet_json_free(&d);

    /* --- what it must accept ----------------------------------------- */
    accepts("{}", "empty object");
    accepts("[]", "empty array");
    accepts("  \n\t {\"a\":[1,2,[3,{\"b\":null}]]} \n ", "nesting and surrounding whitespace");
    accepts("[0, -0, 1e3, 1E+3, 1e-3, 0.5, -12.75]", "the whole number grammar");
    accepts("\"\\ud83d\\ude00\"", "surrogate pair");
    accepts("3", "a bare number is a document");

    /* --- what it must refuse ----------------------------------------- */
    refuses("{\"a\":1,}", "trailing comma in object");
    refuses("[1,2,]", "trailing comma in array");
    refuses("{'a':1}", "single-quoted key");
    refuses("{\"a\":1} garbage", "trailing content");
    refuses("{\"a\":1 \"b\":2}", "missing comma");
    refuses("{\"a\":NaN}", "NaN literal");
    refuses("{\"a\":Infinity}", "Infinity literal");
    refuses("{\"a\":+1}", "leading plus");
    refuses("{\"a\":01}", "leading zero");
    refuses("{\"a\":.5}", "bare fraction");
    refuses("{\"a\":1.}", "trailing point");
    refuses("{\"a\":0x10}", "hex literal");
    refuses("{\"a\":1e}", "empty exponent");
    refuses("{\"a\":1, \"a\":2}", "duplicate key");
    refuses("{\"a\":1 // comment\n}", "comment");
    refuses("\"unterminated", "unterminated string");
    refuses("\"raw\nnewline\"", "raw control character");
    refuses("\"\\q\"", "unknown escape");
    refuses("\"\\ud83d\"", "lone high surrogate");
    refuses("\"\\udc00\"", "lone low surrogate");
    refuses("[1,2", "unterminated array");
    refuses("{\"a\"", "truncated object");
    refuses("", "empty input");
    refuses("tru", "truncated true");

    if (failures) { printf("%d failure(s)\n", failures); return 1; }
    printf("all bnet_json tests passed\n");
    return 0;
}
