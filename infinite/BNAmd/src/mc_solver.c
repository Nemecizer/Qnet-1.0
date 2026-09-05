/* mc_solver.c — Multi-class SRBM research solver (main entry).
 *
 * Flow:
 *   1. Parse a .bnet JSON into an MCNetwork.
 *   2. Derive research-grade SRBM parameters (θ, Σ, R, a, per-class α/μ)
 *      via mc_params_build — uses compound service aggregation and per-
 *      class routing variance.
 *   3. Hand them to the FEM solver (mc_fem_run) via BNAParams adapter.
 */

#include "mc_srbm.h"
#include "mc_fem.h"
#include "bna_fm.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void usage(const char *prog)
{
    fprintf(stderr,
        "Usage: %s [options] <input.bnet>\n"
        "\n"
        "  --dump-params   Print the computed SRBM parameters and exit\n"
        "  --legacy-params Use the arithmetic-mean-rate / weighted-mean-SCV\n"
        "                  aggregation (matches SRBMExporter.swift) instead of\n"
        "                  the new compound-formula aggregation\n"
        "  -c              Compact output (E[X_i] only)\n"
        "  -G              GUI output (standardized per-station + per-class)\n"
        "  -n <mesh>       FEM mesh size per dimension (default 10)\n"
        "  -h              This help\n",
        prog);
}

int main(int argc, char **argv)
{
    const char *input_path = NULL;
    int dump_params = 0;
    int compact = 0;
    int gui_output = 0;
    int mesh_n = -1;               /* -1 = auto (use dimension-aware cap) */
    MCParamFlavor flavor = MC_PARAM_FLAVOR_NEW;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--dump-params")) dump_params = 1;
        else if (!strcmp(argv[i], "--legacy-params")) flavor = MC_PARAM_FLAVOR_LEGACY;
        else if (!strcmp(argv[i], "-c") || !strcmp(argv[i], "--compact")) compact = 1;
        else if (!strcmp(argv[i], "-G")) gui_output = 1;
        else if (!strcmp(argv[i], "-n") && i + 1 < argc) mesh_n = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            usage(argv[0]); return 0;
        } else if (argv[i][0] != '-') {
            input_path = argv[i];
        } else {
            fprintf(stderr, "Unknown option: %s\n", argv[i]);
            usage(argv[0]); return 1;
        }
    }
    if (!input_path) { usage(argv[0]); return 1; }

    MCNetwork net;
    char err[512] = {0};
    if (mc_parse_bnet(input_path, &net, err, sizeof(err)) != 0) {
        fprintf(stderr, "parse error: %s\n", err);
        return 1;
    }

    MCParams prm;
    if (mc_params_build_flavor(&net, &prm, flavor, err, sizeof(err)) != 0) {
        fprintf(stderr, "param build error: %s\n", err);
        return 1;
    }

    if (dump_params) {
        mc_params_dump(&prm);
        return 0;
    }

    /* Dimension-aware mesh cap. Defaults aim for the finest mesh the
     * direct solver tolerates without exhausting memory. */
    int cap;
    switch (net.d) {
    case 1: cap = 80; break;
    case 2: cap = 40; break;
    case 3: cap = 16; break;
    case 4: cap = 8;  break;
    case 5: cap = 6;  break;
    default: cap = 4; break;
    }
    if (mesh_n < 0) mesh_n = cap;
    else if (mesh_n > cap) mesh_n = cap;

    BNAParams bp;
    mc_params_to_bnaparams(&prm, &bp, mesh_n);

    int fmt = gui_output ? 2 : (compact ? 1 : 0);
    return mc_fem_run(&bp, fmt);
}
