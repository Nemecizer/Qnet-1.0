import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// "SRBM MLMC" — the reference for Run ▸ Run SRBM MLMC.
//
// This used to be a hand-built SwiftUI view shown in its own 820 × 640 window
// (Help ▸ SRBM MLMC Guide) *and* embedded as one topic of the Qnet
// Help window: two viewers for one document, with two type scales, and a
// topic whose search text was only a short précis — so searching Qnet Help
// for "antithetic" or "Replications" never matched the guide.
//
// It is now one plain-text blob in the same shape as every `AlgorithmHelp`
// topic. `HelpMarkup` typesets it, so the guide gets the shared heading
// scale, search-match highlighting, text selection and "print to the Shell"
// for free, and Help ▸ SRBM MLMC Guide opens the Qnet Help window at
// this topic.
// ─────────────────────────────────────────────────────────────────────────────

enum ExactSimulationGuide {
    static let text = """
    SRBM MULTILEVEL MONTE CARLO
    ===========================
    Multilevel Monte Carlo for steady-state queueing networks (BNAmc /
    rbm_mlmc).

    WHAT IT DOES
    ------------
    The algorithm estimates the mean queue length at every station of an open
    queueing network by simulating its heavy-traffic Brownian approximation
    (reflected Brownian motion, RBM, on the positive orthant). The
    implementation is the two-parameter multilevel Monte Carlo (MLMC)
    estimator of Blanchet, Chen, Glynn and Si (2021).

    Unlike QNA or SBD — which produce closed-form analytic approximations —
    SRBM MLMC produces Monte Carlo estimates with a confidence interval for
    the Brownian model. Two explicit finite-horizon and discretisation bias
    sources remain at finite T and L. Cost scales roughly linearly in the
    number of stations d, so high-dimensional networks (d much greater than
    10) are practical.

    HOW THE ALGORITHM WORKS
    -----------------------
    - Each sample draws a random MLMC level M (probability proportional to
      gamma^M) and simulates a synchronously-coupled pair of Brownian paths
      at time steps gamma^M (coarse) and gamma^(M+1) (fine).
    - Reflection at the orthant boundary is enforced via an iterative linear
      complementarity problem (LCP) solver (Algorithm A.1 of the paper).
    - The MLMC telescoping formula combines the coarse and fine estimates
      with a bias that shrinks exponentially in the number of levels L.
    - The binary reports an estimate of E[Y_i(inf)] (stationary workload) for
      each station i. The GUI multiplies by the effective service rate mu_i
      to convert to mean queue length L_i = mu_i · E[Y_i(inf)].

    Parallelism: the sample loop is parallelised with OpenMP by default
    (auto-detecting the number of cores). Apple GCD and serial execution are
    also available.

    HOW TO RUN IT
    -------------
    Run ▸ Run SRBM MLMC (⌥⌘E). The item is enabled only for
    infinite-buffer networks. Accuracy, variance reduction, adaptive sampling
    and parallelism are configured in Settings ▸ SRBM MLMC.

    SETTINGS REFERENCE — ACCURACY
    -----------------------------
    - Target RMSE (epsilon). Smallest achievable root-mean-square error for
      each station estimate. Cost scales as 1/epsilon^2, so halving epsilon
      is roughly 4x the runtime. Typical range 0.001–0.1; default 0.01.
    - Step factor (gamma). Ratio of consecutive MLMC time-step sizes; 1/gamma
      must be an integer. 0.05 is the paper-optimal value (Lemma 7). Smaller
      gamma means less bias per level but more cost per path.

    SETTINGS REFERENCE — ADVANCED OVERRIDES
    ---------------------------------------
    - Override T. Path length. Auto: max(log(d)^2 / 2, 5 x relaxation time).
      Longer T removes initial-transient bias but costs linearly. Override
      only if you know the network mixes fast (saves runtime) or slow (avoids
      under-converged estimates).
    - Override L. Number of MLMC levels. Auto:
      L = ceil((log log d + 2 log(1/epsilon) + k) / log(1/gamma)). More levels
      shrink discretisation bias exponentially but cost grows as gamma^-L.
    - Override N. Fixed-sample Monte Carlo count. Auto:
      N = ceil(K(gamma)^-1 gamma^-L L). Variance is proportional to 1/N
      (linear cost). Adaptive mode uses its required maximum-sample cap and
      disables this override.

    SETTINGS REFERENCE — VARIANCE REDUCTION
    ---------------------------------------
    - Antithetic variates. Each sample draws a +/- noise pair sharing the same
      M and underlying Brownian path. Cuts sample variance by roughly half for
      about 1.5–2x runtime, with no bias impact. Recommended for any serious
      run.
    - Replications (K). Run the full estimator K times with widely separated,
      recorded random streams. With K = 1, station intervals retain the native
      within-run Monte Carlo standard errors, but no joint interval is claimed
      for the average across stations. K = 5–10 estimates both station and
      network-average uncertainty from independent replication estimates,
      including their cross-station covariance.

    SETTINGS REFERENCE — ADAPTIVE SAMPLING
    --------------------------------------
    - Adaptive. Run in batches and stop early when the worst per-dimension
      sample standard error drops below epsilon. Useful when the problem is
      easier than the paper's upper bound predicts. It controls the variance
      only, not the bias: if T or L are too small the stop criterion fires at
      a biased estimate.
    - Batch size / min-samples / max-samples. Batch size controls how often the
      standard error is re-evaluated (default 1000). Min-samples floors the
      stop (default 5 x batch size) so MLMC's heavy tails do not cause
      spuriously low early estimates. The minimum and maximum must both be at
      least two so a sample variance exists. Max-samples is a required hard
      runtime cap. If any replication reaches it first, Qnet retains the
      estimates but labels the result Partial.

    SETTINGS REFERENCE — PARALLELISM AND REPRODUCIBILITY
    ----------------------------------------------------
    - Backend. Auto (prefer OpenMP) / OpenMP / Apple GCD / Serial. On macOS
      with libomp installed, OpenMP is the default and is consistently
      fastest.
    - Threads. Number of parallel threads; 0 means one per physical core.
      Ignored for the Serial backend.
    - Fixed random seed. When on, the run is reproducible; when off the seed is
      randomly chosen. For K > 1, Qnet hashes the base seed into widely
      separated per-replication streams and records the exact list in result
      provenance.

    RECOMMENDED WORKFLOWS
    ---------------------
    1. First look (fastest rough estimate). Leave everything at its default and
       choose Run ▸ Run SRBM MLMC (⌥⌘E). Typical runtime is seconds to
       tens of seconds depending on d, and the output is within +/- epsilon of
       the finite-T, finite-L SRBM estimate with reasonable variance.
    2. Best accuracy per CPU-second. Enable Antithetic variates in Settings.
       That is all: about 2x the accuracy for about 1.5x the cost. It should be
       on for nearly every non-trivial run.
    3. Report a confidence interval. Set Replications to 5 or 10. The output
       reports L_i +/- a 95 % half-width computed from the inter-replication
       variance. The network-average interval is computed per replication, so
       it retains cross-station covariance instead of combining marginal SEs.
    4. Need more accuracy. Halve epsilon (0.01 to 0.005) and expect about 4x
       the runtime. Combine with Antithetic and Replications, and leave the T
       and L overrides alone unless you know the problem.
    5. Reproducible experiment. Turn on Fixed random seed. Qnet deterministically
       hashes that seed into a recorded list of independent top-level streams.
    6. Fast-mixing network, save time. Enable Adaptive with the default batch
       and min-samples. If the standard error drops below epsilon before the
       paper's automatic N, the run stops early — 2–4x faster on easy
       problems. Keep the T and L overrides off.

    CAVEATS AND KNOWN LIMITATIONS
    -----------------------------
    - Infinite-buffer networks only. For finite buffers Run ▸ Run SRBM MLMC
      is disabled and the Finite-Buffer Methods section of the Run
      menu is enabled instead; use Run Comparison or the finite spectral /
      finite-element methods.
    - The output is workload per station; the GUI converts it to queue length
      L_i = mu_i · E[Y_i(inf)]. That conversion assumes a single class, or a
      class-averaged mu_eff per station.
    - Adaptive mode targets sample variance, not bias. The paper's automatic T
      and L keep the bias below epsilon; overriding them aggressively makes
      adaptive converge at a biased point estimate.
    - Near-unstable networks (rho close to 1 at any station) produce inflated
      workloads and need more samples. Expect longer runs.
    - High-dimensional networks (d > 200) are possible but may take minutes per
      run. Adaptive and antithetic sampling are essential at that scale.
    - The MLMC estimator has finite bias O(gamma^L) + O(exp(-c T)). For very
      small target epsilon, the randomised MLMC extension (not yet
      implemented) would be required for strict unbiasedness.

    READING THE OUTPUT
    ------------------
    After a successful run the Shell pane shows:

        SRBM MLMC (Blanchet-Chen-Glynn-Si)
        ==================================
        # Dimension: 5
        # gamma=0.0500  epsilon=0.0100  T=405.00  L=3  N=25260
        # antithetic=on adaptive=off
        # Replications: 5

        Per-Station Mean Queue Length:
          L_1 = 9.0503  ± 0.0981 (95%)    (workload E[Y_1] = 8.15 ± 0.09)
          L_2 = 8.8827  ± 0.0837 (95%)
          ...
        Average queue length: 9.0285  ± 0.0847

    - L_i is the mean queue length at station i with a 95 % Monte Carlo
      half-width. For K = 1 it comes from the native within-run SE; for K > 1
      it comes from variation between independent replication estimates.
    - workload E[Y_i] is the raw SRBM estimate before the mu scaling.
    - The final line is the ensemble average across stations and replications.
      Qnet shows its interval only for K > 1, because one run does not identify
      cross-station covariance.

    REFERENCES
    ----------
    - Blanchet, J., Chen, X., Glynn, P. W., Si, N. (2021). "Efficient
      Steady-State Simulation of High-Dimensional Stochastic Networks."
      Stochastic Systems, 11(2):174–192.
    - Harrison, J. M., Reiman, M. I. (1981). "Reflected Brownian Motion on an
      Orthant." Annals of Applied Probability, 9(2):302–308.
    - Giles, M. B. (2008). "Multilevel Monte Carlo Path Simulation."
      Operations Research, 56(3):607–617.
    - Banerjee, S., Budhiraja, A. (2020). "Parameter and dimension dependence
      of convergence rates to stationarity for reflecting Brownian motions."
      Annals of Applied Probability, 30(5):2005–2029.
    """
}
