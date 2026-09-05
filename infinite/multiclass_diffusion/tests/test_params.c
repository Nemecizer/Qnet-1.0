#include "mc_srbm.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void require_close(const char *name, double actual, double expected, double tolerance)
{
    if (!isfinite(actual) || fabs(actual - expected) > tolerance) {
        fprintf(stderr, "%s: got %.17g, expected %.17g (tol %.3g)\n",
                name, actual, expected, tolerance);
        exit(1);
    }
}

static MCDist exponential(double rate)
{
    MCDist d;
    memset(&d, 0, sizeof(d));
    d.kind = DIST_EXPONENTIAL;
    d.p0 = rate;
    return d;
}

static void test_distribution_moments(void)
{
    MCDist d = exponential(4.0);
    require_close("exponential mean", mc_dist_mean(&d), 0.25, 1e-14);
    require_close("exponential SCV", mc_dist_scv(&d), 1.0, 1e-14);

    memset(&d, 0, sizeof(d));
    d.kind = DIST_ERLANG; d.p0 = 4.0; d.p1 = 2.0;
    require_close("Erlang mean", mc_dist_mean(&d), 2.0, 1e-14);
    require_close("Erlang SCV", mc_dist_scv(&d), 0.25, 1e-14);

    memset(&d, 0, sizeof(d));
    d.kind = DIST_PARETO; d.p0 = 3.0; d.p1 = 2.0;
    require_close("Pareto mean", mc_dist_mean(&d), 3.0, 1e-14);
    require_close("Pareto SCV", mc_dist_scv(&d), 1.0 / 3.0, 1e-14);
}

static MCNetwork two_class_fixture(void)
{
    MCNetwork net;
    memset(&net, 0, sizeof(net));
    net.d = 2;
    net.K = 2;
    net.infinite_buffer = 1;

    net.sources[0].class_idx = 0;
    net.sources[0].arrival = exponential(0.4);
    net.sources[0].entry_station = 0;
    net.sources[1].class_idx = 1;
    net.sources[1].arrival = exponential(0.6);
    net.sources[1].entry_station = 0;

    for (int i = 0; i < 2; i++) {
        net.stations[i].num_servers = 1;
        net.stations[i].buffer_size = 20;
        net.stations[i].infinite_buffer = 1;
        net.stations[i].default_service = 0;
    }
    net.stations[0].service[0] = exponential(1.0);
    net.stations[0].service[1] = exponential(2.0);
    net.stations[1].service[0] = exponential(2.0);
    net.stations[1].service[1] = exponential(1.0);

    /* Only class 0 can continue from station 0 to station 1. */
    net.P[0][0][1] = 0.5;
    return net;
}

static void test_compound_service_and_class_routing(void)
{
    MCNetwork net = two_class_fixture();
    MCParams research, legacy;
    char error[256] = {0};
    if (mc_params_build_flavor(&net, &research, MC_PARAM_FLAVOR_NEW,
                               error, sizeof(error)) != 0) {
        fprintf(stderr, "research parameter build failed: %s\n", error);
        exit(1);
    }
    if (mc_params_build_flavor(&net, &legacy, MC_PARAM_FLAVOR_LEGACY,
                               error, sizeof(error)) != 0) {
        fprintf(stderr, "legacy parameter build failed: %s\n", error);
        exit(1);
    }

    require_close("class 0 station 0 flow", research.alpha_c[0][0], 0.4, 1e-12);
    require_close("class 0 station 1 flow", research.alpha_c[0][1], 0.2, 1e-12);
    require_close("class 1 station 0 flow", research.alpha_c[1][0], 0.6, 1e-12);
    require_close("class 1 station 1 flow", research.alpha_c[1][1], 0.0, 1e-12);
    require_close("aggregate station 0 flow", research.alpha[0], 1.0, 1e-12);
    require_close("aggregate station 1 flow", research.alpha[1], 0.2, 1e-12);

    /* Throughput mixture 0.4/0.6 with service means 1 and 1/2. */
    require_close("compound E[S]", research.mean_S[0], 0.7, 1e-12);
    require_close("compound E[S^2]", research.mean_S2[0], 1.1, 1e-12);
    require_close("harmonic effective rate", research.mu_eff[0], 10.0 / 7.0, 1e-12);
    require_close("compound service SCV", research.scv_eff[0], 1.1 / 0.49 - 1.0, 1e-12);
    require_close("legacy arithmetic rate", legacy.mu_eff[0], 1.6, 1e-12);

    /* Aggregate routing is 0.4 * 0.5 = 0.2. */
    require_close("aggregate P01", research.P[0][1], 0.2, 1e-12);
    require_close("reflection R00", research.R[0][0], 1.0, 1e-12);
    require_close("reflection R10", research.R[1][0], -0.2, 1e-12);
    require_close("reflection R11", research.R[1][1], 1.0, 1e-12);
    require_close("upper reflection 0", research.R[0][2], -1.0, 1e-12);
    require_close("upper reflection 1", research.R[1][3], -1.0, 1e-12);

    require_close("drift station 0", research.theta[0], 1.0 - 10.0 / 7.0, 1e-12);
    require_close("drift station 1", research.theta[1], -1.8, 1e-12);
    require_close("covariance symmetry", research.Sigma[0][1], research.Sigma[1][0], 1e-13);
    if (!(research.Sigma[0][0] > 0.0 && research.Sigma[1][1] > 0.0)) {
        fprintf(stderr, "covariance diagonal is not positive\n");
        exit(1);
    }
}

int main(void)
{
    test_distribution_moments();
    test_compound_service_and_class_routing();
    puts("multiclass diffusion primitive tests: PASS");
    return 0;
}
