import Foundation

/// Plain-text help for each Settings pane.  Printed verbatim to the
/// integrated terminal via the "Help ..." menu items in QnetGUIApp.
///
/// Keep the text narrow (≲ 80 columns) and use simple ASCII — the terminal
/// displays this as-is in a monospace font, so Markdown/rich-text won't
/// render.
enum AlgorithmHelp {

    // MARK: - Simulation

    static let simulation = """
    ================================================================================
    HELP — Simulation (Jackson-Network Monte Carlo)
    ================================================================================

    WHAT IT DOES
    ------------
    Direct discrete-event simulation of the queueing network currently on the
    canvas.  Tracks individual customers as they move between stations.
    Unlike the Brownian approximations (QNA, SBD, SRBM MLMC) this is
    a *literal* simulation of the stochastic process, not an approximation
    of it. Used to produce queue-process reference statistics, with sampling
    uncertainty, for comparison against analytic and approximation methods.

    HOW IT WORKS
    ------------
    1. Build an event queue whose primitives are external arrivals and
       service completions.  Each event has a timestamp, drawn from the
       inter-arrival / service distributions specified on the canvas
       (exponential, deterministic, gamma, hyper-exponential, …).
    2. Maintain a per-station buffer.  Arrivals are enqueued; service
       completions dequeue a customer, sample a route via the outgoing
       link probabilities, and either move the customer to the next
       station or exit the network.
    3. Advance the clock by jumping to the next scheduled event (pure
       event-driven: no fixed time step, no discretization error).
    4. After a warm-up period, begin accumulating time-averaged statistics:
       mean queue length, mean sojourn time, per-class waiting time,
       blocking rate (finite buffers).
    5. Run R replications, each starting from an empty-and-idle system
       with a fresh seed.  Report the sample mean ± standard error across
       replications.

    SETTINGS (Settings ▸ Simulation)
    --------------------------------
      Parallelization:
        Apple GCD   — macOS dispatch_apply; default on macOS.
        OpenMP      — portable multithreading if libomp is installed.
        Sequential  — single-threaded; useful for deterministic debugging.

      Blocking mode (for finite-buffer networks):
        Loss                      — arrivals that find a full buffer are
                                    lost.  Closest to a loss network
                                    (Erlang-B behaviour).
        BAS                       — "Blocking After Service": a server
                                    finishing a job holds the slot until
                                    downstream clears.  External arrivals
                                    that find station 1 full are held in
                                    the source.
        BAS + External Loss       — same as BAS but external arrivals to a
                                    full station are lost.  This regime
                                    matches the reflected Brownian motion
                                    (RBM) approximation most closely, and
                                    is the recommended mode when comparing
                                    against QNA / SBD / SRBM MLMC.

      Replications:
        Number of independent simulation runs (R).  Each run uses its own
        RNG stream.  Final output is reported as mean ± sample-SE across
        the R replications.  Bigger R → tighter CIs, but linear cost.
        Typical values: 30–100.

      Warmup period:
        Simulated model time discarded before statistics start accumulating,
        so the system has time to approach steady state.
        Default 1,000,000.  For fast-mixing networks you can lower this;
        for nearly-unstable ones (rho close to 1) you may need much more.

      Simulation time:
        Simulated model time collected *after* warmup for each replication.
        Default 5,000,000. Longer observation time generally reduces Monte
        Carlo uncertainty, while wall-clock cost also depends on event rates.

    RECOMMENDED WORKFLOWS
    ---------------------
      • Queue-process reference check: R = 30–50, warmup 1M, sim time 10M. Accept
        the analytic-method answer if it falls within the simulation's
        95 % CI.
      • High-precision small d: a single long run (R=1, sim time 100M)
        often beats a many-short-run ensemble in wall time.
      • Comparing against RBM: use "BAS + External Loss" blocking mode;
        that's what the RBM approximation assumes.

    CAVEATS
    -------
      • Warmup choice is *problem-specific*.  Under-warming biases all
        estimates downward; there's no built-in convergence detector.
      • Wall-clock work scales with both simulated time and event rate — a
        high-throughput network processes many more events per model-time unit.
      • For very large networks, Monte Carlo simulation is the slowest
        method. Use QNA / SBD / SRBM MLMC for d > 20 unless you
        specifically need direct queue-process reference estimates.
    """

    // MARK: - Finite Element

    static let finiteElement = """
    ================================================================================
    HELP — Finite Element Method (BNAfm)
    ================================================================================

    WHAT IT DOES
    ------------
    Numerically solves for the stationary distribution of the reflected
    Brownian motion (RBM) approximating the queueing network, using a
    finite-element-style discretization.  Output is an approximation of
    the joint stationary density over the state space (the positive
    orthant for infinite buffers, or a bounded box for finite buffers).

    HOW IT WORKS
    ------------
    1. Build the SRBM primitives (mu, Sigma, R) from the queueing
       network via the GJN workload transformation.  Same primitives the
       other infinite-buffer methods use.
    2. Discretize the state space with a tensor-product mesh of size
       (meshSize)^d.  Over each mesh cell, the density is represented by
       a set of basis functions (polynomials).
    3. Enforce the Basic Adjoint Relationship (BAR), the PDE that
       characterizes RBM stationarity:  <f, Lπ> + boundary terms = 0
       for every test function f.  Choosing f from a finite set gives a
       linear system A x = b for the discrete density.
    4. Solve the linear system; report moments E[X_i^k] and selected
       marginal densities.

    SETTINGS (Settings ▸ Finite Element)
    ------------------------------------
      Solver method:
        Gauss-Legendre
          Classical tensor-product quadrature rule.  Deterministic,
          exact for polynomials up to total degree 2·(mesh order)·d.
          Cost grows exponentially in d (curse of dimensionality);
          best for d ≤ 4.

        CBC Quasi Monte Carlo
          Rank-1 lattice rule constructed via Component-By-Component
          (CBC) search.  Cost grows polynomially in d; trades a small
          integration error for massive speedup at d ≥ 5.  Recommended
          for higher-dimensional networks.

      Mesh size per dimension:
        Number of nodes along each axis of the orthant mesh.  Total
        mesh points: meshSize^d for infinite buffers, (meshSize+1)^d
        for finite.  Finer mesh → better approximation but cost grows
        as mesh^d × (solve time).
        Typical: 10–30 for d ≤ 3, 5–15 for d ≥ 4.

    RECOMMENDED WORKFLOWS
    ---------------------
      • Low-d networks (d ≤ 4): Gauss-Legendre with mesh = 20.  Best
        accuracy for moderate cost; can serve as a baseline reference
        against QNA / SBD.
      • Higher-d networks (d = 5–8): CBC Quasi-MC with mesh = 10.
        The lattice rule absorbs the dimension cost much better than
        tensor-product Gauss.
      • d > 8: Finite Element starts to strain memory / CPU even with
        CBC. Consider SRBM MLMC or SBD instead.

    CAVEATS
    -------
      • Output is the stationary density / moments of the RBM workload
        approximation.  Queue-length metrics are recovered by scaling
        each coordinate by the effective service rate mu_eff_i.  The
        GUI performs this conversion when displaying results.
      • Mesh-size choice is problem-specific.  Under-resolved meshes
        give visibly wrong moments; doubling the mesh and re-running
        is the standard convergence check.
      • Finite-buffer mode (via the fBNAfm binary) works on a finite
        box; the mesh is strictly interior to the box.  Blocking mode
        does not apply — the RBM boundary is the box wall itself.
    """

    // MARK: - Spectral Method

    static let spectralMethod = """
    ================================================================================
    HELP — Spectral Method (BNAsm)
    ================================================================================

    WHAT IT DOES
    ------------
    Approximates the stationary density of the RBM as a finite linear
    combination of polynomial basis functions, and solves for the
    coefficients by enforcing the Basic Adjoint Relationship (BAR) over
    a dual polynomial test space.  This is the method of Dai & Harrison
    (1992); the implementation is the BNET 'bnet' binary.

    HOW IT WORKS
    ------------
    1. Build SRBM primitives (mu, Sigma, R) from the queueing network,
       same as for Finite Element.
    2. Choose a basis.  Default: products of shifted monomials of total
       degree ≤ m.  Optionally: tensor-product Legendre polynomials
       (numerically better-conditioned, especially for large m).
    3. Form the BAR-orthogonality linear system: for each pair of basis
       functions (f, g), compute
             A_{fg} = <L* f, g>    where L* is the adjoint generator of
                                   the RBM.
       The density coefficients vec satisfy  A · vec = b  subject to a
       normalization constraint.
    4. Solve the linear system.  Extract moments and marginal densities
       from the polynomial coefficients.

    SETTINGS (Settings ▸ Spectral Method)
    -------------------------------------
      Polynomial degree (m):
        Maximum total degree of basis functions.  Larger m gives a
        richer basis and smaller truncation error, at cost O(m^(2d))
        for matrix assembly and O(m^(3d)) for linear solve.
        Practical range:
          d = 2:  m = 8–16
          d = 3:  m = 6–10
          d = 4:  m = 4–8
          d ≥ 5:  m = 3–5 (and expect long runtimes)

      Use Legendre basis:
        OFF — standard monomial basis (default).  Simple and sufficient
              for small m.  Condition number grows rapidly with m.

        ON  — orthogonal Legendre polynomials.  Much better-conditioned
              matrices at high m, so you can push m = 12–20 without
              numerical collapse.  Slightly more expensive per basis
              element but worth it whenever m > 8.

    RECOMMENDED WORKFLOWS
    ---------------------
      • Accurate low-d analytic answer: d ≤ 3, m = 10, Legendre ON.
        Rivals analytic closed forms to several decimal places.
      • Moderate d (4–6): m = 6, Legendre ON.  Converges to within
        a few percent of simulation on moderate networks.
      • Exploration: m = 4, any basis.  Fast smoke test before
        committing to a longer run.

    CAVEATS
    -------
      • Polynomial approximation assumes the density is smooth.  For
        networks with strong boundary layers (very heavy traffic, e.g.
        rho > 0.95), the approximation degrades; increase m or switch
        to SRBM MLMC.
      • At large m with monomial basis, the BAR matrix becomes
        ill-conditioned and solutions may be dominated by numerical
        noise.  If moments look implausible, enable Legendre basis
        before raising m.
      • Cost is polynomial in m but exponential in d.  For d ≥ 5 this
        method becomes impractical relative to SRBM MLMC.
    """

    // MARK: - Test Sets

    // MARK: - About SRBM in an Orthant

    static let srbmOrthant = """
    ABOUT SRBM IN AN ORTHANT
    ========================

    Infinite-buffer Run Comparison ships diffusion-based algorithms
    (Spectral, QNA, RQNA, SBD) and a discrete-event simulator
    (jackson_sim). Three of the four diffusion algorithms (Spectral,
    QNA in its two-moment formulation, SBD) approximate the network as
    a Semimartingale Reflected Brownian Motion (SRBM) on the positive
    orthant [0, ∞)^d. RQNA is built on the same primitives but solves
    a per-station fixed-point system instead of the SRBM PDE. This
    page explains the SRBM model and the assumptions underlying it.

    WHY DIFFUSION AT ALL?
    ---------------------
    A multi-class queueing network has a complicated state — buffer
    contents, server occupancy, per-class flows, service-time
    histories. The exact stationary distribution is intractable
    except for very special cases (Jackson networks, BCMP networks,
    skew-symmetric covariance, etc.). Diffusion approximation replaces
    the discrete state with a continuous-time stochastic process whose
    first two moments match the original network's drift and noise.
    Two ingredients make this useful:

      1. Heavy-traffic limit theorem (Reiman 1984, Williams 1998):
         under appropriate scaling as ρ → 1, the workload process
         converges weakly to an SRBM. Hence SRBM is asymptotically
         exact in heavy traffic — and progressively less accurate at
         moderate ρ.
      2. The SRBM is parametrised by just three pieces of data:
         drift θ ∈ Rᵈ, covariance Γ ∈ Rᵈˣᵈ, reflection R ∈ Rᵈˣᵈ.
         These can be computed from the network's arrival-rate vector,
         service-rate vector, and routing matrix in closed form via
         the Harrison–Reiman / Gershwin–Newman (GJN) workload
         transformation.

    THE MATH, IN ONE LINE
    ---------------------
    The workload process W_t ∈ [0, ∞)^d evolves as

        dW_t = θ dt + σ dB_t + R dL_t                        (*)

    where θ is the drift (= α − capacity), σ σ^T = Γ is Brownian
    noise, R is the reflection matrix (R = I − Pᵀ for the standard
    Harrison–Reiman setup with routing matrix P), and L_t is a
    "regulator" process (one component per station) that pushes W
    back into the orthant whenever a coordinate would go negative.
    L_t increases only when W_t is on the lower face W_i = 0.

    The reflection direction at face W_i = 0 is the i-th column of R
    — it tells the workload how to bounce back into the interior.
    Physically, when station i has no work (W_i = 0) the regulator
    "credits" idle capacity; that capacity propagates to other
    stations through the off-diagonal entries of R, modelling the
    fact that an idle server isn't producing flow for downstream.

    For stability, every component of θ must be NEGATIVE (each
    station has more capacity than offered load: ρ_i = α_i / c_i < 1).
    Under this condition (and a regularity condition on R called the
    "completely-S matrix" property) (*) has a unique stationary
    distribution.

    WHAT'S APPROXIMATED, WHAT'S EXACT
    --------------------------------
    Exact in the SRBM:
      • Mass conservation across stations
      • Steady-state throughput = α at each station (sub-stochastic)
      • Per-station ρ via boundary measure: P(W_i = 0) = 1 − ρ_i

    Approximated (exact only in the heavy-traffic limit):
      • Stationary distribution shape (continuous Gaussian-like vs
        discrete geometric M/M/1 tail)
      • Mean queue length E[Q_i]
      • Sojourn-time distribution (only first moment is reliable)
      • Tail probabilities (the SRBM's Gaussian-style tails decay
        slower than the geometric tails of an M/M/1 queue at light
        traffic, so high quantiles are over-predicted at moderate ρ)

    ACCURACY VS ρ
    -------------
    A 4-station feed-forward tandem, single class, exponential
    service, swept across ρ:

        ρ        Spectral worst-station error    QNA error
        ----     ----------------------------    ---------
        0.50     -15%                            ~ 0.5%
        0.70     - 9.5%                          ~ 0.5%
        0.85     - 5%                            ~ 1%
        0.92     - 2.6%                          ~ 1%
        0.97     + 1.0%                          ~ 1%

    Spectral converges to the heavy-traffic SRBM; its accuracy
    improves toward ρ → 1. QNA does moment-matching (which is
    asymptotically exact for Jackson networks) and is uniformly
    accurate to ~1% on Markovian-style random networks regardless
    of ρ. So:

      • In heavy traffic (ρ ≥ 0.92), all four diffusion algorithms
        agree with each other and with simulation to within a few
        percent.
      • In moderate traffic (ρ ≤ 0.85), Spectral is the systematic
        outlier — under-predicting queue means by 5–15%. This is
        not a bug; it is the SRBM diffusion limit telling the truth
        about its accuracy domain.
      • In light traffic (ρ ≤ 0.5), prefer Jackson formula or
        analytical closed-forms over any diffusion method.

    DIFFERENCES BETWEEN THE FOUR INFINITE ALGORITHMS
    -----------------------------------------------
    All four start from the same SRBM primitives (θ, Γ, R), but they
    extract E[Q_i] differently:

      Spectral    Solves the SRBM stationary PDE directly via
                  polynomial basis fit. Accuracy bounded by the
                  diffusion approximation; gets better in heavy
                  traffic. O(m^(2d)) cost in basis degree m.

      QNA         Whitt's two-moment approximation: treats every
                  station as a GI/G/1 with arrival/service SCVs
                  computed by the QNA recursion. Exact for Jackson
                  networks, very good for Markovian-style networks
                  uniformly in ρ. Cheap (O(d) per iteration).

      RQNA        Whitt-You 2022 robust refinement: replaces QNA's
                  single SCV with a *per-class* SCV at each timescale,
                  catching covariances QNA aggregates away. Better on
                  feed-back networks and re-entrant flows; same cost
                  order as QNA.

      SBD         Sequential Bottleneck Decomposition (Dai-Harrison
                  1991): solves a 1-D SRBM per station in topological
                  order, propagating departure-process moments. Almost
                  as cheap as QNA; better than QNA on tandems, worse
                  on complex feedback graphs.

    REFERENCES
    ----------
    Harrison & Reiman (1981)     — Reflected Brownian motion on the
                                   positive orthant.
    Reiman (1984)                — Open queueing networks in heavy
                                   traffic.
    Williams (1998)              — Diffusion approximations for open
                                   multiclass queueing networks.
    Whitt (1983, 1995)           — QNA: Queueing Network Analyzer.
    Whitt & You (2022)           — Refined diffusion approximations
                                   (RQNA framework).
    Dai & Harrison (1991, 1992)  — SRBM polynomial methods + SBD.
    Gamarnik-Cao-Dai-Glynn 2025  — Asymptotic product-form structure
                                   for feed-forward / M-matrix R.

    SEE ALSO
    --------
      "About finite-dimensional SRBM in a Hypercube" — same theory
      extended to bounded buffers, plus the BAS / Loss / SRBM
      protocol comparison and the corrections Run Comparison applies.
    """

    // MARK: - About finite-dimensional SRBM in a Hypercube

    static let srbmHypercube = """
    ABOUT FINITE-DIMENSIONAL SRBM IN A HYPERCUBE
    ============================================

    Finite Run Comparison ships SRBM-based algorithms (Spectral, Finite
    Element, Finite-Buffer LP) and a discrete-event simulator (fBNAsim). The
    algorithms and the simulator can disagree even on a "correct" run —
    not because of numerical bugs but because they're not modeling
    *quite* the same protocol. This page explains the mismatch and the
    corrections that close it.

    THE TWO REAL PROTOCOLS THE SIMULATOR IMPLEMENTS
    ----------------------------------------------
    fBNAsim picks one of three discrete blocking protocols based on
    the flag passed by Run Comparison's popup:

      Loss            (-l)  — A customer arriving to a full buffer is
                              rejected at the door. A server that
                              completes service when the next buffer is
                              full also drops its customer (internal
                              loss). No back-pressure: every server
                              keeps running at full speed.
      BAS             (default)
                            — "Blocking After Service": when a server
                              completes and the next buffer is full,
                              the customer stays in the server slot and
                              the server idles until a downstream slot
                              frees. Back-pressure propagates upstream.
                              External arrivals to a full first buffer
                              are blocked at the source (closed system).
      BAS + ExtLoss   (-e)  — Same as BAS internally; external arrivals
                              to a full first buffer are dropped (open).

    All three are well-defined queueing protocols a real factory or
    telecom system would actually exhibit.

    WHAT THE SRBM ALGORITHMS ARE SOLVING
    ------------------------------------
    Spectral, FE, LP all solve the *same* mathematical object: a
    Semimartingale Reflected Brownian Motion on the hypercube
    [0, K_1] × ... × [0, K_d], where K_i = buffer_i + servers_i. The
    workload vector W_t evolves as

        dW_t = θ dt + σ dB_t + R dL_t

    where θ is drift (= α − capacity), σ is noise (covariance Γ),
    R is the reflection matrix, and L_t is a regulator that pushes W
    back into the box at each face. Two regulators:

      • Lower face (W_i = 0)  — pushes UP. Physical meaning: the
                                server idles when there is no work.
      • Upper face (W_i = K_i) — pushes DOWN. Physical meaning: ???

    The upper-face regulator is what makes finite-buffer SRBM "in
    between" the discrete protocols, because it's a CONTINUOUS, INSTANT
    regulator: the moment work tries to push above K_i, an exactly
    balancing amount is removed. It does not distinguish "this excess
    came from an arriving customer" from "this excess came from
    upstream service" from "an upstream customer is blocked from
    delivering" — it just decrements the workload variable continuously.

    So the honest answer to "what protocol does SRBM implement?" is:
    a continuum approximation that doesn't correspond to any of the
    discrete protocols above, because the discrete protocols make
    distinctions about *who* gets affected when a buffer fills, and
    SRBM erases those distinctions.

    SIDE-BY-SIDE: BUFFER i+1 JUST HIT K_{i+1}, ANOTHER ARRIVAL FROM i
    -----------------------------------------------------------------
                          Real Loss        Real BAS         Raw SRBM
                          ----------       --------         --------
      Arriving customer:  rejected         server i idles   work trimmed
                          at the door                       continuously
      Buffer i+1:         stays at K       stays at K       stays at K
      Server i state:     keeps serving    IDLES            keeps serving
                          (next enters)    (back-pressure)  (no back-pressure)
      Buffer i:           drains normal    BUILDS UP        drains normal
                                           (back-pressure)
      Throughput at i:    full × (1−P_f)   reduced          full (over-predicts!)
      Upstream queue:     modest           large            modest

    WHICH DISCRETE PROTOCOL IS THE SRBM CLOSER TO?
    ----------------------------------------------
    SRBM upper reflection most resembles LOSS in spirit:
      • Both lose mass at the boundary (continuously vs. at-arrival).
      • Neither propagates back-pressure to upstream stations — so
        upstream queues stay smaller than BAS would predict.

    But it differs from real Loss because:
      • Real Loss only loses *arrivals*  (P_loss × λ);
        SRBM loses any work that tries to push past the boundary,
        regardless of source. This can over-count rejections.
      • The continuous workload approximation smears out the discrete
        distribution that real Loss queues actually have.

    It differs from BAS catastrophically because:
      • Real BAS reduces upstream μ_eff when downstream is full —
        this is the dominant effect on tandem queue lengths.
      • Raw SRBM doesn't model this at all — upstream μ_eff stays
        constant. Upstream queues come out small. Downstream queues
        come out small too because nothing slows the bottleneck.

    "PRODUCTION BLOCKING WITH INFINITE-SERVER DOWNSTREAM"
    -----------------------------------------------------
    A useful informal description of the raw SRBM:

      Customers complete service at i, attempt handoff to i+1; if
      i+1 is full, the customer just disappears (no rejection cost
      upstream, no idle penalty for server i — as if i+1 had infinite-
      capacity ghost servers waiting to absorb the overflow).

    That's nobody's real protocol — it's the continuum-limit
    interpretation of "instant continuous reflection at the upper
    face." Recognising this explains why the comparison to either
    real protocol is biased without a correction.

    THE CORRECTIONS RUN COMPARISON APPLIES AUTOMATICALLY
    ---------------------------------------------------
    SRBMExporter.computeData ships two iterative corrections, picked
    by the popup:

      Loss correction (when popup = Loss)
        For each station, compute P̂(buffer full) using an M/M/1/K
        loss formula, propagate effective arrivals downstream via the
        routing matrix, and use α_throughput = α_arrive · (1 − P_loss)
        as the SRBM drift's α term. This shrinks the offered load at
        each station to match what a real Loss queue actually feeds
        the downstream stations.

        On a 4-tandem at ρ = 0.9 with buffer 10: closed the average
        absolute error vs Loss simulator from ~25% to ~5%.

      BAS correction (when popup = BAS or BAS + ExtLoss)
        Iteratively shrinks effective service rate at upstream
        stations:  μ_eff_i_BAS = μ_eff_i · (1 − β · Σ_j P_ij · P̂_full_j)
        with β = 0.5 dampening (raw β = 1 over-shoots upstream by
        compounding P_block estimates from already-corrected queues).
        This INTRODUCES the back-pressure that the raw SRBM lacks.

        On a 4-tandem at ρ = 0.9 with buffer 10: closed the average
        absolute error vs BAS simulator from ~8% to ~3%.

    The corrections are mutually exclusive — one or the other, never
    both. Infinite-buffer runs skip both (no blocking happens).

    DIAGNOSTIC FINGERPRINT
    ----------------------
    A 4-station tandem with ρ = 0.9 everywhere, buffer 10, BAS+ExtLoss
    simulator, NO correction:

        Station      Sim BAS    Spectral (raw)    error
        -------      -------    --------------    -----
        S1            4.74          4.21          -11%   ← upstream
        S2            5.62          4.87          -13%      under-predicted
        S3            5.37          4.98          - 7%
        S4            4.48          4.51          + 1%   ← terminal exact

    The growing-toward-upstream error is the signature of "no
    back-pressure modeling." Same network with the BAS correction:

        Station      Sim BAS    Spectral (BAS-fix)
        -------      -------    -----------------
        S1            4.74          4.90 (+ 3%)
        S2            5.62          5.39 (- 4%)
        S3            5.37          5.18 (- 3%)
        S4            4.48          4.50 (+ 0%)

    Mean abs error 8% → 2.6%.

    EXACT REFERENCE WHEN AVAILABLE: CTMC
    ------------------------------------
    For single-class M/M/1 loss tandems with d ≤ 4, all external flow
    entering station 1, and at most 1,000 joint states, Run Comparison
    adds a CTMC (exact loss) column ahead of Simulation. The CTMC solves
    that finite-state loss chain — no diffusion approximation or Monte
    Carlo noise. True BAS needs blocked-server state, so BAS comparisons
    deliberately omit this column.

    PRACTICAL GUIDANCE
    ------------------
      • Pick the popup choice that matches your real system (Loss for
        loss-tolerant systems; BAS for systems with back-pressure).
        The matching correction is applied automatically.
      • Heavy traffic + small buffers (ρ > 0.97, buffer ≤ 10) is the
        regime where SRBM accuracy degrades fastest. A status warning
        fires when both conditions hold and the popup is BAS-style.
      • For CTMC-eligible loss networks (single-class M/M/1 tandem,
        station-1 entry, d ≤ 4, at most 1,000 states) the CTMC column is
        the exact queueing benchmark; compare algorithms to it rather
        than to simulator (which has Monte Carlo noise).
      • The "Average of Algorithms" column averages Spectral / FE / LP
        per row. When the algorithms straddle the reference the average
        cancels their per-station bias; when they all bias the same
        way it doesn't help. Useful to see at a glance whether
        ensembling is paying off on your network.
    """

    static let testSets = """
    ================================================================================
    HELP — Run Test Set (Infinite / Finite)
    ================================================================================

    WHAT IT DOES
    ------------
    Run ▸ Run Infinite Test Set …  (or  Run Finite Test Set …)  generates
    N random networks under the bounds you specify (stations, classes, ρ,
    topology), runs every algorithm in the chosen regime on each one, and
    prints an aggregate accuracy table at the end.

    The simulation result (jackson_sim for infinite, fBNAsim for finite)
    is treated as the queue-process reference. Every other algorithm is
    scored against its point estimate, with the simulation confidence
    interval retained as essential context.

    WHAT EACH PER-CASE NUMBER MEANS
    -------------------------------
    For each case, for each non-reference algorithm, we compute one
    number:

        per_case_err = mean over stations k of  |algo_k - Sim_k| / |Sim_k| * 100%

    That is a single percent error summarising the algorithm's performance
    on that one case (averaged across the K stations in the network).
    With N test cases, you get N such numbers per algorithm — that is the
    population the table aggregates.

    HOW TO READ THE TABLE
    ---------------------
      Algorithm    Mean %err     P50      P90      Max     N

      Mean %err  Average per-case error across the test set.  Sensitive
                 to outliers — one near-ρ=1 case where an approximation
                 blows up can pull the mean up substantially.

      P50        Median per-case error: half the cases came in below
                 this number, half above.  This is the "typical case"
                 metric.  When a few outliers are inflating Mean,
                 compare Mean vs P50 to spot it.

      P90        90th percentile: 90% of cases were at or below this
                 number; the worst 10% were higher.  This is the
                 "tail" metric — useful for picking between methods
                 that have similar means but different worst-case
                 behaviour.

      Max        Single worst-case error in the entire sweep.  If
                 Max is much larger than P90, one or two cases hit
                 a pathological regime; widening N or narrowing ρ
                 usually clarifies whether it's a one-off.

      N          Number of cases that contributed to this row.  A
                 case drops out for a given algorithm when its
                 output file is missing or empty (for example, the
                 LP solver timing out, or the Spectral solver
                 hitting an internal numerical guard).

    PICKING THE SWEEP PARAMETERS
    ----------------------------
    The popup is pre-populated from your saved defaults in
    Settings ▸ Test Sets (one set of defaults for Infinite, one
    for Finite).  Anything you change in the popup overrides the
    default for that one run; it does not write back to Settings.

    Hints:
      • Stations: the FE solver cost scales as n²ᵈ, so for finite
        sweeps keep the upper station bound modest (≤ 4 is comfortable;
        ≥ 5 will dominate sweep time).  The runner auto-caps the FE
        mesh size by station count.
      • ρ: rates closer to 1 are where every approximation gets
        worse.  Sweeping a wide ρ range (e.g. 0.5…0.95) makes the
        Mean / P90 spread informative.  Sweeping a narrow band
        (e.g. 0.85…0.9) tells you how the methods stack up at a
        specific operating point.
      • # cases: 20 is a reasonable default for getting stable
        statistics.  Below ~10 the percentiles get noisy.

    PROGRESS DISPLAY
    ----------------
    Each case prints one line in the Interactive Shell:

        [3/20] d=4 K=2 ρ=0.812  done in 4.71s

    A spinner ticks while the case's binaries are running, then the
    line is overwritten with `done in X.XXs` showing the per-case
    wall-clock time.  When the sweep completes, the aggregate table
    is printed below.

    NOTES
    -----
    • The simulation reference uses the BAS+ext-loss blocking regime
      for finite cases, matching the SRBM convention.  This is the
      recommended default in Run Comparison as well.
    • Random networks are generated fresh on every run — no seed
      input.  Re-running the same sweep parameters will give a
      different sample but should produce comparable aggregate
      statistics if N is large enough.

    WHY SPECTRAL UNDERPERFORMS AT MODERATE ρ (INFINITE TEST SETS)
    ------------------------------------------------------------
    Spectral on a random infinite test set typically reports 5–15%
    mean error per case, while QNA / RQNA / SBD report ≤ 1%.  This
    is not a wiring bug — it is structural and reflects what the
    methods are actually solving.

    The random network generator produces:
      • Sources: Poisson (squared coefficient of variation c²_a = 1)
      • Service: a mix of Exponential, Erlang-2/3, Gamma, and Uniform
        (c²_s mostly in 0.2–1.0)
      • Single server per station, target ρ in the popup-specified band.

    On these Markovian-style networks:
      • QNA / RQNA / SBD do moment matching — they are exact or near
        exact for Jackson networks and degrade gracefully for the
        modest c²_s deviations the random generator introduces.
      • Spectral solves the SRBM diffusion approximation, which is
        a heavy-traffic-asymptotic model.  At moderate ρ the
        parabolic Brownian motion cannot reproduce the geometric
        M/M/1 tail, so steady-state queue lengths come out
        systematically low.

    Empirical sweep on a fixed network (d=4, K=1, feed-forward) shows
    Spectral's error closing as ρ rises:

        ρ       Spectral worst-station error
        ----    ---------------------------
        0.50    -15%
        0.70    - 9.5%
        0.85    - 5%
        0.92    - 2.6%
        0.97    + 1.0%

    Increasing the polynomial degree does NOT help — the answer
    saturates by degree 4–6 and stays biased. The bias is in the
    model, not the basis resolution.

    PRACTICAL ADVICE
    ----------------
    • To benchmark Spectral fairly, narrow the ρ band toward the
      heavy-traffic regime (e.g. 0.92…0.97) where SRBM is designed
      to be accurate.  Spectral closes to within ~1–2% of the other
      methods there.
    • To sweep moderate-load networks, expect Spectral to be the
      least accurate column.  This is correct — the test set is
      reporting the SRBM approximation's actual quality on this
      class of random networks, and is a useful signal for picking
      methods on real networks of similar load.
    • Spectral remains valuable for finite-buffer cases (where it is
      one of three SRBM-based options compared head-to-head) and
      for high-d networks where direct M/M/1 product-form analysis
      is not available.

    FINITE-BUFFER ACCURACY: BAS vs LOSS
    -----------------------------------
    For finite-buffer networks, simulator blocking mode and SRBM
    model assumptions interact and set a floor on how close the
    algorithms can match simulation.

    The SRBM hypercube model (Spectral, Finite Element, Finite-Buffer LP)
    applies continuous reflection at the upper face of each
    station's buffer. That is not BAS and not Loss — it's closer
    to "production blocking with infinite-server downstream". When
    the simulator runs in BAS or BAS+ExtLoss the algorithms tend to
    UNDER-predict queue means at near-saturated stations (no back-
    pressure modeling); when the simulator runs in Loss they tend
    to OVER-predict (no throughput shrinkage from rejected
    arrivals).

    Loss-mode correction (applied automatically when "Loss" is
    chosen in the Run Comparison popup): the SRBM exporter
    iteratively solves an M/M/1/K-style loss fixed point and feeds
    the throughput-reduced drift into Spectral / FEM / LP. Typical
    effect on tandem networks at ρ ≈ 0.9 with buffer 10: average
    error vs the Loss simulator drops from ~25% to ~5%.

    BAS / BAS+ExtLoss is left uncorrected — capturing BAS back-
    pressure in SRBM requires reflection-matrix surgery (coupling
    each station's upper reflection to downstream occupancy), which
    is a research-level change. The residual ~10% gap on tandems at
    ρ = 0.9, buffer 10 is the accepted model limit.

    Practical guidance for tight finite-buffer comparisons:
      • Choose "Loss" in the Run Comparison popup whenever you can.
      • Or move out of near-saturation (ρ ≤ 0.9 with comfortable
        buffer headroom) so all three protocols nearly agree.
      • For very small tandems (d ≤ 4, buffer ≤ ~10) consider a
        direct CTMC solve — `finite/fBNActmc/ctmc_tandem.py` is
        exact in that regime.
    """

    // MARK: - General

    static let general = """
    ================================================================================
    HELP — General Preferences
    ================================================================================

    WHAT THIS PANE CONTROLS
    -----------------------
    Non-algorithmic application behaviour: tab persistence across app
    launches, and the default answer for the Run Comparison blocking-
    mode dialog.

    SETTINGS (Settings ▸ General)
    -----------------------------
      On quit:
        Ask whether to restore tabs  — default.  On relaunch the app
                                       prompts whether to reopen the tabs
                                       that were open when you quit.
        Always restore tabs          — reopen automatically, no prompt.
        Never restore tabs           — start with a fresh blank tab.

      Remember choice (skip popup):
        When OFF (default), every "Run Comparison" invocation pops up a
        dialog asking which buffer-blocking regime the simulation should
        use for the comparison run.  When ON, that dialog is skipped
        and the "Default choice" below is used silently.  The dialog
        itself has a "Remember choice" checkbox that flips this flag.

      Default choice (blocking regime):
        The preselected buffer-blocking regime, used whenever
        "Remember choice" is on *or* when the user just presses
        Enter on the dialog.
          Loss Network           — arrivals to a full buffer are
                                   discarded entirely.
          BAS                    — "Blocking After Service": server
                                   holds the job until downstream
                                   clears.  External arrivals queue
                                   in the source.
          BAS + External Loss    — same as BAS but external arrivals
                                   to a full station are lost.  This
                                   matches the RBM approximation
                                   semantics most closely and is the
                                   recommended default for
                                   comparisons.

    NOTES
    -----
    These preferences are persisted via macOS UserDefaults.  They affect
    behaviour across all tabs and all sessions; there is no per-tab
    override.  "Restore Defaults" resets only the fields in this pane,
    not the contents of any open tab.
    """

    // MARK: - Linear Program — Performance Hints

    static let linearProgramPerformanceHints = """
    ================================================================================
    PERFORMANCE HINTS — Linear Program (Saure-Glynn-Zeevi 2008)
    ================================================================================

    WHY SIZE MATTERS
    ----------------
    The LP that srbm_lp builds has roughly nᵈ interior λ-variables, where
    n = grid_n and d = number of stations.  At n = 100, that's:

       d = 2  →     10 000 cells  (OK,      ~0.5 s)
       d = 3  →  1 000 000 cells  (ENORMOUS, minutes to hours)
       d = 4  → 100 000 000 cells (INFEASIBLE at this n)

    So n must shrink as d grows — commercial LP solvers can handle around
    10 000 – 100 000 variables briskly, above that CPLEX / HiGHS start to
    struggle with a dense Basic-Adjoint-Relationship matrix like ours.

    RECOMMENDED DEFAULTS (used when grid_n = 0 and basis_m = 0)
    ----------------------------------------------------------
    The defaults below are what Sections 4 & 6 of the paper use.  Set
    `grid_n` and `basis_m` to 0 in Settings ▸ Linear Program to let the
    GUI pick these automatically based on d:

       Dimension d    grid_n    basis_m    # cells    typical solve
       -----------    ------    -------    -------    -------------
              1–2       100         6      ≤10 000    < 1 s
                3        25         5      15 625     ~0.5 – 3 s
                4        12         4      20 736     ~5 – 15 s
                5        10         3     100 000     ~20 – 60 s
                6         8         3     262 144     minutes
              ≥7         6         3      ~47 000     minutes to hours

    Doubling n multiplies LP size by 2^d.  Doubling m multiplies the
    number of basis functions (BAR rows) by roughly (m+d choose d)/(m-1+d
    choose d).  At d = 3 going from m = 5 → 6 takes you from 56 to 84
    basis functions — about 50% more BAR rows.

    TUNING GUIDELINES
    -----------------
      • Tail stations under-converged?   Raise basis_m by 1 (accept the
                                         cost; the LP gets slower).
      • Solver reports "numerical"       Enable `basis_normalize` — scales
        trouble or "dual infeasible"?    monomial rows to unit magnitude
                                         and usually restores stability.
      • LP degenerate (u* = 0, many      Enable the smoothness term with
        vertices pick awful moments)?    a small weight (e.g. 1e-4) to
                                         break ties toward a smooth λ.
      • Running out of memory at d=4+?   Drop grid_n to 8 – 10 and
                                         basis_m to 3.  Switch solver to
                                         HiGHS (uses less memory than
                                         CPLEX barrier).

    SOLVER CHOICE
    -------------
      CPLEX is usually fastest on d ≤ 3 dense LPs (IBM's dual simplex is
      highly tuned for this structure).
      HiGHS is competitive at d ≥ 4 where the LP becomes sparse in a
      way CPLEX's presolve doesn't fully exploit; HiGHS also has a
      lower memory footprint.
      GLPK is the fallback; slowest but available everywhere.

    MULTI-LEVEL NESTED GRIDS
    ------------------------
    Enable "Multi-level refinement" in Settings ▸ Linear Program to run
    the LP twice: first on a coarse grid (≈ n_target / 2) for a quick
    preview, then on the full grid for the refined answer.  The coarse
    run lets you sanity-check the problem setup in seconds before
    committing to the full solve.  Cost ≈ 1.05× - 1.3× of the full
    solve, but you see an intermediate result along the way.

    WHEN TO STOP TUNING
    -------------------
    If you need d ≥ 5 or you want ε ≤ 0.01 on every station, the LP
    approach hits a wall. Switch to SRBM MLMC, which scales
    almost linearly with d and has explicit accuracy control.
    """

    // MARK: - Inspector (editing parameters)

    static let inspector = """
    ================================================================================
    HELP — Inspector Pane and Parameter Sheets
    ================================================================================

    WHAT THIS IS
    ------------
    Every node and link has parameters: a name, the number of servers
    and the buffer size, the service or inter-arrival law (a
    distribution family and its parameters, or a mean and SCV that are
    solved into them), a picture, and for a link the routing
    probability and the customer class it carries.  Qnet edits them in
    two hosts that show the SAME grouped form, bound to the same draft:

      The Inspector pane      View ▸ Panes ▸ Inspector   (⌥⌘5)
                              Focus it with ⌃⌘5.
      The parameter sheet     Edit ▸ Edit Parameters…    (⌘I), or the
                              "Edit in Sheet" button in the pane header.

    Neither host has a field the other lacks.  They differ only in
    geometry and in WHEN a change is written to the network.

    THE INSPECTOR PANE (docked, follows the selection)
    ---------------------------------------------------
    The pane sits in the right column above the Status pane and shows
    whatever is selected on the canvas: a node, a link, or the one node
    of a one-node marquee selection.  While S3 is being edited the
    canvas still shows S3 and its neighbours; click S2 and the pane
    moves with you.

      Commit rule:   a text field is written when you LEAVE it (Tab,
                     Return, or a click elsewhere).  Pickers, steppers
                     and the picture choice are written as soon as the
                     draft settles (a fraction of a second).
      Undo:          every commit is one undoable step, named for the
                     node ("Edit S1 Parameters").  A RUN of commits to
                     the same field - a stepper held down, a value
                     retyped and re-blurred - folds into ONE step, so a
                     single ⌘Z takes back the whole run.  Undo keeps
                     the selection: the pane shows the restored value
                     in the same field.
      Invalid input: a field that does not pass validation shows its
                     message in red and is NEVER written.  Fix it,
                     press Escape to put the whole draft back to the
                     last committed values, or move the selection - in
                     which case the invalid edit is discarded and one
                     warning line in the Status log says which field
                     and which text were dropped.
      Per class:     a station serving several classes shows a Class
                     picker over one set of distribution fields.  A
                     commit never moves that picker or the entry mode.
      Reload:        when the network changes elsewhere (undo, the AI
                     assistant, the sheet's Save) the pane re-reads the
                     node - unless you are typing in it, in which case
                     your edit wins and is committed on blur as usual.

    THE PARAMETER SHEET (modal, review and save)
    --------------------------------------------
    ⌘I opens the same sections in a sheet with room for the per-class
    service TABLE (one row per class: distribution, parameters, and the
    live lambda / mean / SCV / mu readouts).

      Save:          writes every change as ONE undo step and closes.
      Cancel / Esc:  closes; asks Save / Don't Save / Cancel first when
                     the draft differs from what is stored.
      Previous/Next: ⌥↑ / ⌥↓ step through the nodes of
                     the same kind without closing the sheet (the same
                     prompt appears if the draft is dirty).  The sheet
                     opens at one size for the whole walk.
      Up / Down:     move between class rows in the table when no text
                     field is being edited; inside a field the keys
                     belong to the field.  Tab visits fields only, one
                     stop per control - rows are not Tab stops.
      Bulk actions:  "Copy Class 1 to N other classes" and "Exponential
                     (rate 1) for all classes" say their scope in the
                     title and offer a one-click Undo in the footer.

    WHILE A NUMBER IS HALF-TYPED
    ----------------------------
    "1e-" or "0." is not a mistake yet.  Nothing turns red; the footer
    (sheet) says "Still typing ..." and Save stays disabled until the
    number is complete.  The pane simply does not commit until the
    field is left with a complete value.

    THE LOAD ROW
    ------------
    A station's Capacity section shows lambda (the station's total
    arrival rate from the traffic equations), c*mu (servers times the
    effective service rate) and rho = lambda / (c*mu), recomputed from
    the values being typed before they are saved.  rho >= 0.95 warns
    (heavy traffic); rho >= 1 is called unstable.  Neither blocks a
    save - an unstable station is a legal network, just a bad one.

    SHORTCUTS
    ---------
      ⌥⌘5               show / hide the Inspector pane
      ⌃⌘5               focus the Inspector (caret in the first field)
      ⌘I                open the parameter sheet for the selection
      ⌥↑ / ⌥↓           previous / next node of the same kind (sheet)
      Escape            pane: revert the uncommitted draft;
                        sheet: close (asks if the draft is dirty)
      Return            commit the field (pane) / Save (sheet)
    """

    // MARK: - Interactive Shell

    static let interactiveShell = """
    ================================================================================
    HELP — Shell Pane
    ================================================================================

    WHAT THIS PANE CONTROLS
    -----------------------
    Appearance of the integrated terminal (the window/pane where the
    algorithms print their output).  These are cosmetic settings only;
    they do not affect the algorithms themselves.

    SETTINGS (Settings ▸ Interactive Shell Window)
    ----------------------------------------------
      Font:
        Any font family installed on the machine.  "System Monospaced
        (default)" is a sensible, fixed-width system font that aligns
        numeric output in columns correctly.  Proportional fonts are
        allowed but table output won't line up.

      Text size:
        Point size, 8–28.  Takes effect immediately in the terminal
        pane.  Consider size 13–14 on high-DPI displays and 12 on
        standard-density.

    NOTES
    -----
    The terminal is a PTY-backed emulator that honours ANSI colour
    codes and most escape sequences (cursor movement, erase, colour).
    Algorithm output uses minimal colouring; the font/size settings
    here apply uniformly.  For per-session colour themes or more
    elaborate shell customization, use .bashrc / .zshrc in your
    usual shell — this pane is only for the font.
    """

    // MARK: - Feedback Networks

    static let feedbackNetworks = """
    ================================================================================
    HELP — Feedback Networks
    ================================================================================

    WHAT THIS IS
    ------------
    BNET supports queueing networks whose routing matrix P has entries
    P[i][j] > 0 for j ≤ i — i.e. jobs leaving station i can loop back to
    itself or to an earlier station. All solvers (spectral method, finite
    element, QNA, SBD, simulation, LP, MLMC) handle feedback natively; the
    only feed-forward-restricted feature is GCDG 2025 Corollary 3 in the
    analytical-tractability detector.

    EXISTENCE CONDITION (Taylor–Williams 1993)
    -------------------------------------------
    The SRBM with reflection matrix R = I − Pᵀ on the orthant exists and is
    unique in law iff R is "completely-S": every principal submatrix is an
    S-matrix (admits a non-negative vector u with Ru > 0). For generalized
    Jackson networks (P sub-stochastic) this reduces to the physically
    intuitive condition that every station has a positive-probability path
    to the sink. BNET checks this automatically — if it fails, the red
    banner fires and Analyze Network lists it as a CRITICAL finding.

    ALGORITHMS AND FEEDBACK
    -----------------------
    Exact / asymptotically exact under general feedback:
      • Spectral method (BNAsm) — Dai–Harrison 1992, reference QNET engine.
        Solves the SRBM Fokker–Planck PDE on the orthant via a polynomial
        / Legendre expansion. No feed-forward restriction. Reference:
        daiHarrison92.pdf §2.
      • Finite element method (BNAfm) — Shen–Chen–Dai–Dai 2002. Bounded
        hypercube with converging sequence of SRBMs. Handles feedback in
        the reflection matrix at any station. Reference: shenChenDaiDai02.pdf.
      • LP method (BNAlp) — Saure–Glynn–Zeevi 2008. BAR-based linear
        program with polynomial test functions. General R.
      • SRBM MLMC (rbm_mlmc) — Blanchet–Chen–Si 2021. Linear-in-d cost,
        no feedforward assumption; estimates the Brownian model.
      • Jackson simulation (jackson_sim / fBNAsim) — queue-process reference
        with Monte Carlo uncertainty.

    Approximate under heavy feedback — may degrade:
      • QNA (Whitt 1983) uses renewal superposition / departure SCV
        formulas that iterate to a fixed point through feedback cycles.
        Convergence is slow at light loads; expect 10–30% error on E[X]
        for tight cycles with ρ < 0.7. Accurate in heavy traffic.
      • SBD (Dai–Nguyen–Reiman 1994) decomposes the network into
        subnetworks then calls QNET on each. Better than QNA under
        feedback but still two-moment fit.

    Advisory findings Analyze Network emits automatically:
      • "Routing has self-loops" — P[i][i] > 0, arrivals to station i are
        no longer a renewal process. OK up to P ≈ 0.3.
      • "Routing has feedback cycles (i ↔ j)" — the QNA / SBD fixed-point
        is slow to converge; prefer spectral / FEM / simulation.

    REFERENCES
    ----------
    Dai, J.G., and Harrison, J.M. (1992). "Reflected Brownian motion in an
      orthant: Numerical methods for steady-state analysis." Annals of
      Applied Probability 2(1): 65–86.  (QNET / BNAsm foundation.)
    Dai, J.G., Nguyen, V., and Reiman, M.I. (1994). "Sequential bottleneck
      decomposition: An approximation method for generalized Jackson
      networks." Operations Research 42(1): 119–136.  (SBD / BNAsbd.)
    Shen, X., Chen, H., Dai, J.G., and Dai, W. (2002). "The finite element
      method for computing the stationary distribution of an SRBM in a
      hypercube with applications to finite buffer queueing networks."
      Queueing Systems 42: 33–62.  (BNAfm.)
    Taylor, L.M., and Williams, R.J. (1993). "Existence and uniqueness of
      semimartingale reflecting Brownian motions in an orthant."
      Probability Theory and Related Fields 96: 283–317.  (Existence.)

    HOW TO EXERCISE FEEDBACK IN BNET
    --------------------------------
      • Draw feedback edges directly on the canvas (station → earlier
        buffer), or
      • Use Network ▸ Generate Random Network… and pick the topology
        "Jackson feedback" (light feedback) or "General P-matrix" (full
        feedback). The dialog writes a stable target-ρ network with the
        chosen topology into a new tab.
      • Load the paper example files DaiHarrison92.d2.c2.1.inf.bnet,
        DaiNguyenReiman94.d3.c1.1.inf.bnet, Schwerer01.*.inf.bnet.
    """

    // MARK: - Analytical Tractability

    static let analyticalTractability = """
    ================================================================================
    HELP — Analytical Tractability
    ================================================================================

    WHAT THIS IS
    ------------
    When the network you just loaded falls into one of a handful of well-
    studied special cases, the stationary distribution of the station
    queue lengths has a closed-form (or asymptotic product-form) expression.
    In those cases, BNET sidesteps the numerical solver for the mean E[X_i]
    and reports the analytical result as the reference column in Run
    Comparison. A green "This network is analytically tractable" banner
    appears on the canvas whenever at least one of the conditions below
    holds.

    HOW THE ANALYTICAL PILL DECIDES
    -------------------------------
    The Analytical pill in the flag bar lights up whenever a known
    closed-form or asymptotic product-form distribution applies to the
    network. Its popover names the branch that matched: exact (Jackson
    product form, Harrison-Williams skew-symmetric) or asymptotic (GCDG 2025
    Corollary 1 / 2 / 3). The values populate the "Exact Result" column of
    Run Comparison and of single-method runs. There is nothing to configure:
    the detector always tries every branch.

    ACCURACY
    --------
    Exact branches are closed-form. The GCDG 2025 corollaries -- M-matrix R,
    2-D P-matrix R, and lower-triangular R -- hold asymptotically in the
    multi-scaling regime (traffic slackness delta_i = r^i); for moderate rho
    the means may differ from simulation by 10-30 %. The popover's detail
    line says which branch fired.

    Detection is attempted in this order; the strongest match wins.

    (1) OPEN JACKSON NETWORK  — exact product form
    -----------------------------------------------
    Conditions:
      • All external inter-arrival distributions are Poisson/exponential
      • All station service distributions are exponential
      • Infinite buffers, work-conserving FCFS
      • One customer class -- or several, provided no station is visited by
        more than one of them. Classes on disjoint stations are separate
        Jackson networks sharing a canvas, not a multi-class network: every
        server still sees a single exponential stream, so this is the same
        theorem rather than an extension of it. Two archetypes inserted
        side by side are the everyday case. A station genuinely shared by two
        classes is not accepted here, even when both are served at the same
        rate.
      • ρ_i = α_i / (s_i · μ_i)  < 1  at every station

    Result (Jackson 1957 / Gordon-Newell):
      π(n_1, ..., n_d) = ∏_i π_i(n_i),
      with each station behaving as an independent M/M/s_i queue.

      E[N_i] = Erlang-C mean for M/M/s_i   (reduces to ρ_i/(1−ρ_i) for s_i = 1).

    (2) HARRISON-WILLIAMS SKEW-SYMMETRIC SRBM  — exact product form
    ---------------------------------------------------------------
    Conditions (Harrison & Williams 1987a, eq. 2.7):
      2Γ = R · diag(Γ_ii/R_ii) + diag(Γ_ii/R_ii) · Rᵀ
      (where Γ is the SRBM covariance and R is the reflection matrix)

    Result:
      Z has product exponential stationary distribution with
        E[Z_k] = Γ_kk / (2 · R_kk · δ_k),   δ = −R⁻¹μ.

    (3) GCDG 2025 MULTI-SCALING ASYMPTOTIC PRODUCT FORM
    ---------------------------------------------------
    Reference:
      Guang, Chen, Dai, Glynn (2025). "Asymptotic Product-form Steady-state
      Distribution for SRBM in Multi-scaling Regime." arXiv:2503.19710.

    Under the multi-scaling regime δ_i = r^i (traffic slackness at distinct
    heavy-traffic speeds) and the uniform moment bound condition, the
    rescaled SRBM converges to a product of independent exponentials with
    explicit means (Theorem 1, eqs. 2.4-2.6):

        m_k = u_k' Γ u_k / (2 · u_k' R_{:,k}),
        u_k = [w_{1k}, ..., w_{k-1,k}, 1, 0, ..., 0]'
        with w solving Σ_{j<k} w_{jk} R_{jℓ} + R_{kℓ} = 0 for ℓ = 1..k-1.

    The moment bound condition has been verified for:
      • Corollary 1 — R is an M-matrix (e.g. every Jackson-style SRBM
                      with R = I − Pᵀ)
      • Corollary 2 — d = 2 and R is a P-matrix
      • Corollary 3 — R is lower-triangular (feed-forward / tandem
                      with station numbering respected)

    These results are ASYMPTOTIC (they hold in a heavy-traffic limit).
    BNET reports the corresponding means but labels the column
    "Asymptotic E[X]" to distinguish from the two exact cases above.

    STABILITY PRECONDITION
    ----------------------
    All tests require ρ_i < 1 at every station. If any ρ_i ≥ 1 the banner
    is suppressed (matches the red "Network Has Warnings" banner).

    HOW TO USE
    ----------
    Load or edit a network. The analytical check runs automatically and,
    if any condition matches, a green banner appears at the top-left of
    the canvas describing which result applies. In Run Comparison, an
    extra block titled with the matched condition appears after the main
    SM/FM/Sim (or SM/QNA/SBD/Sim) table, showing the analytical means
    alongside the simulation for direct % delta comparison.
    """

    // MARK: - Per-algorithm reference pages

    // Each page follows: WHAT IT IS / HOW IT WORKS / WHEN IT WORKS WELL /
    // WHEN IT DOESN'T (+ALTERNATIVES) / ROBUSTNESS / HINTS. Wired up
    // through the Help menu under "Infinite Algorithms" and "Finite
    // Algorithms" sub-sections.

    static let algSpectralInfinite = """
    SPECTRAL METHOD — INFINITE BUFFERS (BNAsm / `bnet`)
    ===================================================

    WHAT IT IS
    ----------
    Solves the SRBM stationary PDE on the positive orthant directly,
    using a polynomial basis fit. Returns the joint stationary
    density p(x_1, ..., x_d) and per-station moments E[Q_i].
    Implementation: `infinite/BNAsm/bnet`.

    HOW IT WORKS
    ------------
    1. Build SRBM primitives (drift θ, covariance Γ, reflection R)
       from the queueing network via the Harrison–Reiman / GJN
       workload transformation.
    2. Choose a polynomial basis (default: monomials of total degree
       ≤ m; optionally Legendre for better conditioning at large m).
    3. Form the BAR-orthogonality system: for each pair of basis
       functions (f, g), compute the matrix entry
           A_{fg} = ⟨L* f, g⟩
       where L* is the adjoint generator of the SRBM. The density
       coefficients satisfy A·c = b plus a normalization constraint.
    4. Solve the linear system. Extract per-station means by
       integrating x_i against the polynomial density.

    WHEN IT WORKS WELL
    ------------------
      • Heavy-traffic networks (ρ ≥ 0.92). Spectral converges to
        the heavy-traffic SRBM limit, so the diffusion approximation
        is asymptotically exact and the polynomial basis captures it.
      • Smooth densities. Light- to moderate-traffic networks where
        the orthant density is smooth (no boundary layers) admit
        clean polynomial fits at modest degree.
      • Low-d networks. d ≤ 3 with degree m = 10 rivals analytical
        closed forms to several decimal places.
      • Re-entrant networks where the workload is well-mixed across
        stations — Spectral handles non-trivial Γ off-diagonals
        cleanly because the basis spans the full d-cube.

    WHEN IT DOESN'T WORK + ALTERNATIVES
    -----------------------------------
      • Moderate traffic (ρ ≤ 0.85): Spectral systematically
        under-predicts queue means by 5–15% on Markovian-style
        random networks. The diffusion approximation itself is
        biased here, not the basis fit.
        → Use QNA or SBD for accurate moment estimates at moderate ρ.

      • Light traffic (ρ ≤ 0.5): the M/M/1 geometric tail dominates
        and the SRBM Gaussian tail under-counts.
        → Use the Jackson formula (Help ▸ Analytical Tractability)
        directly when applicable, or QNA for non-Jackson systems.

      • d ≥ 5: cost grows as O(m^(2d)) for matrix assembly and
        O(m^(3d)) for solve. At d = 5, m = 6 the matrix is already
        ~16K × 16K.
        → Use QNA / RQNA / SBD (cheap regardless of d). Or Exact
        Simulation (MLMC) when statistical noise is acceptable.

    ROBUSTNESS / CURSE OF DIMENSIONALITY
    ------------------------------------
    Cost: O(m^(2d)) memory, O(m^(3d)) time. Practical envelope:

        d = 2:  m ≤ 16, time < 1 s
        d = 3:  m ≤ 10, time ~ a few seconds
        d = 4:  m ≤ 8,  time ~ a minute
        d ≥ 5:  m ≤ 5,  time ~ minutes; basis under-resolved

    Failure modes by dimension:
      d ≤ 4:  numerically robust; use Legendre basis at m > 8 to
              avoid monomial-basis ill-conditioning.
      d = 5:  watch for plausibility — saturated values at low m
              are the basis, not the answer.
      d ≥ 6:  basically out of practical range — switch methods.

    HINTS FOR BETTER RESULTS
    ------------------------
      • Enable Legendre basis (Settings ▸ Spectral Method) whenever
        m > 8. The orthogonal basis avoids the explosive condition
        number of monomials at high degree.
      • Convergence check: rerun with m → m + 2; if E[Q_i] moves by
        > 1% the answer hasn't converged — raise m further.
      • For ρ < 0.85 networks, expect the systematic Spectral bias
        and don't chase it by raising m — the bias is in the model,
        not the basis. Compare against QNA to bound the gap.
      • If the network is approximately feed-forward and ρ is
        moderate, the Sequential Bottleneck Decomposition (SBD)
        is comparable in accuracy and ~ 100× faster.
    """

    static let algQNA = """
    QNA — QUEUEING NETWORK ANALYZER (BNAqna)
    ========================================

    WHAT IT IS
    ----------
    Whitt's Queueing Network Analyzer (1983, 1995). Approximates
    every station as a GI/G/1 queue with arrival and service squared-
    coefficients-of-variation (SCVs) computed by a network-wide
    recursion. Returns mean queue length, sojourn time, and effective
    inter-arrival/service moments per station.
    Implementation: `infinite/BNAqna/bna_qna`.

    HOW IT WORKS
    ------------
    1. Solve the traffic equations: α = (I − Pᵀ)⁻¹ λ to get the
       per-station throughput α_i.
    2. Compute the per-station traffic intensity ρ_i = α_i / μ_i.
    3. Recursively solve for the per-station arrival SCV:
           c_a²_i = (sum_j w_ji · departure SCV from j)
       where w_ji is a weighted blend of routing and arrival shares.
    4. Compute departure SCV at each station from arrival SCV +
       service SCV via a Marshall-style approximation.
    5. Iterate to fixed point (typically 5–20 iterations).
    6. Plug into the Allen-Cunneen GI/G/m formula:
           E[W_q] = ρ / (1 − ρ) · (c_a² + c_s²) / 2 · (1/μ)
       to get per-station mean wait, then E[Q] = α · E[W_q] +
       (1 in service if busy).

    WHEN IT WORKS WELL
    ------------------
      • Markovian-style networks (exponential or near-exponential
        arrivals and service). QNA is exact for Jackson networks.
      • Mid-to-heavy traffic (ρ in 0.5 – 0.95). The Allen-Cunneen
        formula is most accurate here.
      • Feed-forward and modestly feedback networks. The recursion
        on arrival SCVs converges quickly and stably.
      • Quick exploration. QNA runs in milliseconds even for d = 50;
        useful as a sanity check on any longer-running method.

    WHEN IT DOESN'T WORK + ALTERNATIVES
    -----------------------------------
      • Heavy feedback networks. The arrival-SCV recursion has weak
        coupling that can mis-attribute variability around feedback
        loops, leading to ~10% errors at re-entrant stations.
        → Use RQNA — its per-class SCV at each timescale handles
        feedback better.

      • Highly bursty arrivals (c_a² > 5) or low-CV² service
        (c_s² < 0.2). The Marshall departure-SCV approximation
        biases moment-matching at the extremes.
        → Use Spectral (heavy traffic) or simulation (always
        possible, just slow).

      • Multi-class networks with strong class asymmetries (e.g.,
        one class is 90% of arrivals, another 10%). QNA aggregates
        all classes' moments into a single (c_a², c_s²) per station,
        losing per-class structure.
        → Use RQNA with per-class flag enabled.

    ROBUSTNESS / CURSE OF DIMENSIONALITY
    ------------------------------------
    Cost: O(d^2) per iteration (for the routing-matrix solve), and
    typically converges in O(20) iterations. For d = 100 the whole
    method runs in tens of milliseconds. Memory O(d^2). The curse
    of dimensionality does not bite QNA at all — it's O(d^2)
    regardless of network depth or load.

    HINTS FOR BETTER RESULTS
    ------------------------
      • Always run QNA first as a baseline: it's free relative to
        the cost of any other method, and disagreements between
        QNA and Spectral / SBD usually localize the issue.
      • If QNA disagrees with simulation by > 5%, check feedback
        cycles in the routing graph (Help ▸ Feedback Networks).
        QNA struggles with strong feedback; switch to RQNA.
      • For best agreement with simulation, use BAS+ExtLoss in the
        sim popup — that's the protocol the SRBM/QNA approximation
        is closest to.
    """

    static let algRQNA = """
    RQNA — REFINED QUEUEING NETWORK ANALYZER (BNArqna)
    ==================================================

    WHAT IT IS
    ----------
    The Whitt-You (2022) refinement of QNA. Replaces QNA's single
    arrival/service SCV per station with a *per-class* SCV at each
    *timescale*, capturing covariances QNA aggregates away. More
    accurate on feedback and re-entrant networks; comparable cost.
    Implementation: `infinite/BNArqna/bna_rqna`.

    HOW IT WORKS
    ------------
    1. Same traffic-equation step as QNA: solve α = (I − Pᵀ)⁻¹ λ.
    2. For each station × class × timescale (the Index of Dispersion
       for Counts, IDC), compute a refined arrival/service SCV using
       Whitt-You's per-class moment-matching.
    3. Iterate the IDC fixed point (typically 10–50 iterations) — at
       each step the per-class SCVs at each station are updated from
       the network's flow / variability propagation.
    4. Plug into a refined Allen-Cunneen formula with per-class
       weights to get E[W_q] per station.
    5. Sum per-class waits weighted by visit ratios for end-to-end
       sojourn estimates.

    WHEN IT WORKS WELL
    ------------------
      • Feedback / re-entrant networks. The per-class IDC framework
        was designed specifically for these, and improves on QNA by
        5-10% on networks with strong cycles.
      • Multi-class networks with class-specific routing. RQNA
        tracks each class separately rather than aggregating.
      • Cases where QNA disagrees with simulation — RQNA usually
        closes most of the gap.

    WHEN IT DOESN'T WORK + ALTERNATIVES
    -----------------------------------
      • Very simple feed-forward networks. RQNA's extra machinery
        adds no value over QNA here, and may converge slower.
        → Use plain QNA.

      • Networks where the Whitt-You IDC fixed point fails to
        converge. Symptom: error bars in the output, or values
        that ping-pong between iterations. This happens occasionally
        on networks with cycles of length > 4.
        → Use Spectral (heavy traffic) or SBD (feed-forward).

      • Ultra-heavy traffic (ρ ≥ 0.99). RQNA is asymptotically
        accurate but the iteration takes many more steps to
        converge here.
        → Use Spectral, which is designed for this regime.

    ROBUSTNESS / CURSE OF DIMENSIONALITY
    ------------------------------------
    Cost: O(d^2 · K · T) per iteration where K is class count, T is
    timescale count (default 4). Typical iteration count 10-50.
    For d = 50, K = 4 the whole method runs in seconds. Memory
    O(d · K · T). Like QNA, the curse of dimensionality is mild —
    cost is polynomial in everything.

    HINTS FOR BETTER RESULTS
    ------------------------
      • Compare to QNA. If they agree, both are right. If they
        disagree, RQNA is usually closer to simulation (especially
        on feedback networks).
      • For extremely re-entrant networks (Kumar-Seidman style),
        RQNA's accuracy can saturate at ~5% error — the per-class
        IDC structure captures most but not all of the variability
        propagation.
      • Convergence: if the per-class IDC fixed point looks slow,
        check Settings ▸ RQNA (if exposed) for damping factor;
        a damping of 0.7 is more robust than the default 1.0.
    """

    static let algSBD = """
    SBD — SEQUENTIAL BOTTLENECK DECOMPOSITION (BNAsbd)
    ==================================================

    WHAT IT IS
    ----------
    Dai-Harrison (1991) sequential decomposition: solves a 1-D SRBM
    per station in topological order (or, for cyclic networks, in
    a heuristic order based on bottleneck severity), propagating
    departure-process moments downstream. Comparable accuracy to
    QNA for ρ in 0.7–0.95, often better on tandems.
    Implementation: `infinite/BNAsbd/bna_sbd`.

    HOW IT WORKS
    ------------
    1. Solve the traffic equations and build the routing graph.
    2. Find a topological order (or use bottleneck-severity heuristic
       if the graph is cyclic).
    3. For each station k in order:
       a. Aggregate inbound flow from already-solved upstream
          stations into a single GI/G/1 arrival process.
       b. Solve the 1-D SRBM stationary distribution for station k.
       c. Compute the departure-process moments of station k and
          propagate them to downstream successors per the routing
          matrix.
    4. Report per-station means and the global throughput.

    WHEN IT WORKS WELL
    ------------------
      • Pure feed-forward tandems. SBD is essentially exact for
        single-class M/M/1 tandems, and very good for general
        feed-forward networks.
      • Light feedback (small re-entry probability). The heuristic
        ordering still works.
      • Heavy traffic (ρ close to 1). The 1-D SRBM solver is
        accurate in this regime.

    WHEN IT DOESN'T WORK + ALTERNATIVES
    -----------------------------------
      • Strong feedback / re-entrant networks. The topological-order
        heuristic breaks down when feedback dominates.
        → Use RQNA (designed for feedback) or Spectral (handles
        arbitrary R).

      • Heavily multi-class networks with shared bottleneck
        servers. SBD aggregates classes per station, losing
        per-class detail.
        → Use RQNA for per-class accuracy.

      • Very-low-traffic networks (ρ ≤ 0.3). The 1-D SRBM
        approximation breaks down at light load.
        → Use the Jackson formula directly (closed form).

    ROBUSTNESS / CURSE OF DIMENSIONALITY
    ------------------------------------
    Cost: O(d) station solves, each O(1) for the closed-form 1-D
    SRBM. Total: milliseconds for any reasonable d. Memory O(d).
    Curse of dimensionality is essentially absent.

    HINTS FOR BETTER RESULTS
    ------------------------
      • SBD is the cheapest non-trivial option — always run it
        alongside QNA as a cross-check.
      • If SBD and QNA disagree by > 5%, the network has strong
        coupling that 1-D decomposition can't capture; trust
        Spectral (heavy traffic) or RQNA (feedback) instead.
      • SBD's accuracy degrades toward downstream stations on
        deep tandems (d > 8) because the propagated moments
        accumulate approximation error. Compare with simulation
        on the last station to gauge this.
    """

    static let algSimulationInfinite = """
    SIMULATION (INFINITE BUFFERS) — jackson_sim (BNAsim)
    ====================================================

    WHAT IT IS
    ----------
    Direct discrete-event simulation of the queueing network with
    no buffer constraints. Tracks individual customers as they move
    between stations. Used as a queue-process reference against which
    the analytic / approximation methods (Spectral, QNA, RQNA, SBD)
    are validated.
    Implementation: `infinite/BNAsim/jackson_sim`.

    HOW IT WORKS
    ------------
    1. Build an event queue whose primitives are external arrivals
       and service completions. Each event has a timestamp drawn
       from the inter-arrival / service distributions specified on
       the canvas (exponential, gamma, deterministic, etc.).
    2. Maintain a per-station FIFO buffer. Arrivals are enqueued;
       service completions dequeue a customer, sample a route via
       the outgoing link probabilities, and either move the
       customer to the next station or exit the network.
    3. Advance the clock to the next scheduled event (event-driven;
       no fixed time step).
    4. Discard the warmup period; accumulate time-averaged
       statistics afterward.
    5. Run R replications, each starting empty-and-idle with a
       fresh seed. Report sample mean ± standard error across
       replications.

    WHEN IT WORKS WELL
    ------------------
      • Queue-process reference. The only method that *literally*
        simulates the stochastic process — every other method is
        an approximation.
      • Networks with arbitrary distributions. Anything you can
        sample from is supported; no Markovian assumption.
      • Single-class or multi-class with no shared assumptions.
      • Validation of new networks before relying on diffusion
        approximations.

    WHEN IT DOESN'T WORK + ALTERNATIVES
    -----------------------------------
      • Very large networks (d > 100). Event throughput drops as
        the per-event station selection cost grows.
        → Use QNA (millisecond runtime regardless of d).

      • Very heavy traffic (ρ ≥ 0.99). Convergence to steady state slows
        sharply as ρ approaches one and may require a much longer warmup.
        → Use Spectral (asymptotically exact in the heavy-traffic
        limit; no warmup needed).

      • Tail-probability estimates. Monte Carlo gives mean ± O(1/√N)
        accuracy; rare-event tails take exponential effort.
        → Use a dedicated rare-event simulation method for extreme tails;
        the existing SRBM solvers primarily target stationary moments.

    ROBUSTNESS / CURSE OF DIMENSIONALITY
    ------------------------------------
    Cost is proportional to the number of events processed across all
    replications; event count depends on simulated time and network rates.
    Memory is O(d) apart from queued customers.

    HINTS FOR BETTER RESULTS
    ------------------------
      • Confidence intervals: report mean ± 2 SE across replications.
        If the algorithm answer falls inside that band, declare
        agreement (don't chase the point estimate).
      • Heavy traffic warmup: scale warmup with 1/(1−ρ)². For
        ρ = 0.95 use 100× more warmup than for ρ = 0.5.
      • Replication count: R = 30–100 is usually plenty. More
        replications buys ~1/√R reduction in standard error, so
        going from R=30 to R=300 only halves the CI.
      • Use parallel mode (Apple GCD or OpenMP) for any R > 1 —
        replications are embarrassingly parallel.
    """

    static let algSpectralFinite = """
    SPECTRAL METHOD — FINITE BUFFERS (fBNAsm / `srbm_solver`)
    =========================================================

    WHAT IT IS
    ----------
    Solves the SRBM stationary PDE on a bounded hypercube
    [0, K_1] × ... × [0, K_d] using a polynomial basis fit. Same
    technique as the infinite-buffer Spectral method, but the
    polynomials live on a bounded domain and the upper-face
    reflection adds extra boundary measures.
    Implementation: `finite/fBNAsm/srbm_solver`.

    HOW IT WORKS
    ------------
    1. Build SRBM primitives (drift θ, covariance Γ, reflection R)
       plus the hypercube extents (a_i = buffer_i + servers_i) from
       the network. With Loss/BAS popup correction, drift and α
       are pre-corrected by SRBMExporter.
    2. Choose a polynomial basis on the hypercube — products of
       shifted Legendre or Chebyshev polynomials of degree ≤ m.
    3. Form the BAR-orthogonality system over both interior and
       2d boundary faces. Each face contributes a boundary measure
       term to the matrix.
    4. Solve the linear system. Extract per-station means and
       throughputs (Γ_i = μ_eff_i − δ_lower_i, clipped to
       [0, min(μ_eff, α)] to suppress numerical artifacts).

    WHEN IT WORKS WELL
    ------------------
      • Heavy-traffic finite-buffer networks. Same heavy-traffic
        story as the infinite case: SRBM is asymptotically exact
        as ρ → 1.
      • Loss-mode comparisons (with Loss correction enabled
        automatically by the popup). Closes typical 25% over-
        prediction down to ~5%.
      • d ≤ 4 with modest mesh / degree.
      • Tandem and feed-forward networks where the SRBM upper-
        face reflection is a reasonable approximation to the
        actual blocking semantics.

    WHEN IT DOESN'T WORK + ALTERNATIVES
    -----------------------------------
      • Strong BAS back-pressure without correction. Raw Spectral
        under-predicts upstream queues by 10–15% under BAS sim.
        → Pick BAS / BAS+ExtLoss in the popup so the BAS
        correction is applied. Or accept ~3% residual error.

      • Small single-class M/M/1 loss tandems with d ≤ 4. CTMC gives
        the exact answer with no diffusion approximation.
        → Look at the CTMC (exact loss) column; trust it as the
        benchmark only when Loss is the selected protocol.

      • d ≥ 5: cost prohibitive for high-degree basis on bounded
        domain (state space cap typically forces m ≤ 4).
        → Use Finite-Buffer LP (lower memory) or simulation.

      • Light-traffic (ρ ≤ 0.5). The diffusion approximation
        is biased here.
        → Use the M/M/1/K closed form for single-class, or
        simulation for general networks.

    ROBUSTNESS / CURSE OF DIMENSIONALITY
    ------------------------------------
    Cost: O(m^(2d)) memory, O(m^(3d)) time — same as infinite
    Spectral, but the basis must also fit boundary terms which
    inflates memory by ~2d. Practical envelope:

        d = 2:  m ≤ 16, runs in seconds
        d = 3:  m ≤ 8,  runs in tens of seconds
        d = 4:  m ≤ 6,  minutes
        d ≥ 5:  m ≤ 4,  approaching out-of-range

    HINTS FOR BETTER RESULTS
    ------------------------
      • Pick the popup choice that matches your real system
        (Loss / BAS / BAS+ExtLoss) — the matching SRBM correction
        is applied automatically and closes the model gap.
      • Convergence check: rerun with degree m → m + 2; if E[X_i]
        moves > 1% the answer hasn't converged.
      • Compare with FE and LP (always shown side-by-side in Run
        Comparison). All three solve the same SRBM but with
        different numerical approaches; agreement to within 1%
        means the SRBM has converged. Disagreement means at least
        one solver hasn't.
      • For ρ < 0.85 expect systematic bias — see "About
        finite-dimensional SRBM in a Hypercube" for diagnostics.
    """

    static let algFiniteElement = """
    FINITE ELEMENT METHOD — fBNAfm
    ==============================

    WHAT IT IS
    ----------
    Tensor-product finite-element discretization of the SRBM PDE
    on the bounded hypercube. Solves the stationary density via
    direct sparse linear solve (CHOLMOD / UMFPACK). Two sub-
    solvers shipped: Gauss-Legendre (deterministic quadrature)
    and CBC Quasi Monte Carlo (lattice rule).
    Implementation: `finite/fBNAfm/bna_fm_gauss` (default) and
    `finite/fBNAfm/bna_fm_cbc`.

    HOW IT WORKS
    ------------
    1. Build SRBM primitives (with Loss/BAS popup correction
       applied by SRBMExporter if relevant).
    2. Build a tensor-product mesh over the hypercube of size
       (mesh)^d cells. Over each cell, the density is represented
       by a polynomial basis (typically degree 2 per dimension).
    3. Assemble the BAR matrix: ⟨L* φ_i, φ_j⟩ for every pair of
       basis functions, plus boundary integrals at the upper
       and lower faces.
    4. Solve the resulting sparse linear system (CHOLMOD for
       symmetric positive-definite parts, UMFPACK for the rest).
    5. Extract per-station moments by integrating x_i against
       the discrete density.

    WHEN IT WORKS WELL
    ------------------
      • Networks where the SRBM density has sharp features that
        polynomial basis (Spectral) can't capture. The tensor-
        product mesh resolves boundary layers cleanly.
      • d ≤ 3 with mesh ≥ 12. Best accuracy among the three SRBM
        algorithms in this regime.
      • Smooth-coefficient SRBMs where the linear solve is well-
        conditioned.

    WHEN IT DOESN'T WORK + ALTERNATIVES
    -----------------------------------
      • d ≥ 5. Mesh count grows as mesh^d; even mesh=4 gives
        4^5 = 1024 cells, often slow to assemble.
        → Switch to CBC Quasi-MC sub-solver (Settings ▸ Finite
        Element → Solver Method = CBC). It absorbs dimension
        cost much better than Gauss-Legendre at the price of
        a small integration error.
        → Or use Spectral with low degree (cheap) or LP (sparse
        and dimension-tolerant).

      • Very heavy traffic (ρ ≥ 0.97). The boundary layer is
        sharp and needs a refined mesh near the upper face.
        → Increase mesh and/or use BAS correction; or compare
        with Spectral which handles heavy traffic gracefully.

      • Memory pressure. Sparse matrices for high mesh / high d
        can exceed memory. The runtime auto-caps mesh size by
        dimension to keep things tractable.

    ROBUSTNESS / CURSE OF DIMENSIONALITY
    ------------------------------------
    Cost: assembly O(mesh^d), solve O((mesh^d)^1.5) for sparse
    Cholesky in the well-conditioned case. Practical envelope:

        d = 2:  mesh ≤ 30, runs in seconds
        d = 3:  mesh ≤ 15, tens of seconds
        d = 4:  mesh ≤ 8,  ~ a minute
        d ≥ 5:  mesh ≤ 4,  switch to CBC sub-solver

    HINTS FOR BETTER RESULTS
    ------------------------
      • For d ≤ 4, Gauss-Legendre with mesh = 20 is the gold
        standard among approximations. Use it as a baseline
        when comparing Spectral / LP.
      • For d ≥ 5, CBC Quasi-MC is the practical choice.
      • Convergence check: double the mesh and rerun; if E[X_i]
        moves > 1% the mesh wasn't fine enough.
      • Memory cap: the GUI auto-limits mesh by dimension via
        the fmMeshCap policy. To override, use `bna_fm_gauss`
        directly from the command line with explicit mesh value.
    """

    static let algFiniteLP = """
    FINITE-BUFFER LP — fBNAlp
    =========================

    WHAT IT IS
    ----------
    Linear-programming relaxation of the SRBM stationary
    distribution. Restricts the search to a polynomial basis on
    the hypercube and enforces the BAR equation as LP equality
    constraints. Solves with HiGHS, GLPK, or CPLEX. Cheap and
    naturally sparse.
    Implementation: `finite/fBNAlp/fBNAlp_solver`.

    HOW IT WORKS
    ------------
    1. Build SRBM primitives (with Loss/BAS popup correction).
    2. Discretize the hypercube with a tensor-product grid of
       N nodes per dimension and a polynomial basis of degree m
       per dimension.
    3. For each grid node, write the BAR equation as a linear
       equality constraint over the basis coefficients. Normalize
       to integrate to 1.
    4. Solve the LP. The objective can be set to maximize entropy
       or just feasibility; both work.
    5. Extract per-station means via integration of the basis
       polynomial.

    WHEN IT WORKS WELL
    ------------------
      • Higher-d networks (d = 5, 6) where Spectral and FEM run
        out of memory. LP's sparse structure scales better.
      • Cases where the SRBM density is smooth — the LP relaxation
        converges quickly to a clean answer.
      • Heavy-traffic regimes (with BAS or Loss correction
        applied).

    WHEN IT DOESN'T WORK + ALTERNATIVES
    -----------------------------------
      • Networks where the LP becomes infeasible (numerical
        issue with very heavy traffic). Symptom: solver reports
        infeasible status.
        → Try a different solver (HiGHS / GLPK / CPLEX) via
        Settings ▸ Finite-Buffer LP. Some are more numerically robust.
        → Or switch to Spectral / FEM.

      • Very small networks (d = 2, low buffer). The grid is
        coarse and Spectral / FEM both give better answers
        for the same effort.
        → Use Spectral or FEM.

      • Light-traffic (ρ ≤ 0.5). Same diffusion-approximation
        bias as Spectral.
        → Use M/M/1/K closed form or simulation.

    ROBUSTNESS / CURSE OF DIMENSIONALITY
    ------------------------------------
    Cost: O((N × m)^d) LP variables, but the constraint matrix
    is sparse. HiGHS scales well to ~100K variables. Practical
    envelope:

        d = 2:  N = 30, m = 8, runs in seconds
        d = 3:  N = 20, m = 5, tens of seconds
        d = 4:  N = 8,  m = 3, ~ a minute
        d = 5:  N = 6,  m = 3, minutes
        d ≥ 6:  out of practical range

    HINTS FOR BETTER RESULTS
    ------------------------
      • Stick with HiGHS unless you have a CPLEX license; it's
        the fastest open-source LP solver and the implementation
        is well-tuned.
      • Settings ▸ Finite-Buffer LP exposes grid type (uniform vs.
        Chebyshev) and basis normalization. Chebyshev grids
        cluster nodes near the boundaries — better for boundary-
        layer-heavy SRBMs (heavy traffic).
      • For convergence checking, increase grid_n by 2 and
        rerun; basis_m by 1 should cover the same ground.
      • Compare with Spectral and FE as a cross-check. All three
        solve the same SRBM, so disagreement points to a solver
        artifact in one of them.
    """

    static let algAdaptiveTruncatedCTMC = """
    ADAPTIVE TRUNCATED CTMC — INFINITE MARKOV CHAIN
    =================================================

    WHAT IT IS
    ----------
    A queue-process approximation for open, infinite-buffer, single-class
    M/M/c networks. It solves a sequence of finite continuous-time Markov
    chains obtained by capping the network's total population, rather than
    replacing the queues by a diffusion. Implementation:
    `infinite/BNAtc/truncated_ctmc.py`.

    HOW IT WORKS
    ------------
    1. Verify the open-network traffic equations and strict station loads.
    2. Enumerate all population vectors whose total is at most the current
       cap and solve the sparse generator by matrix-free uniformization.
    3. Enlarge the cap until both boundary probability and the successive
       change in mean populations meet their requested tolerances.
    4. Report generator residuals, cap history, boundary mass and refinement
       change separately from the queue estimates.

    WHAT THE CLAIM MEANS
    --------------------
    The stability check is rigorous for the supported Jackson-network class.
    Agreement between successive caps and small boundary mass are numerical
    truncation evidence, not by themselves a proof of error. A separate
    Foster–Lyapunov tail or moment certificate is reported only when the
    solver's explicit sufficient condition holds; it is never inferred from
    apparent convergence.

    SUPPORTED SCOPE
    ---------------
      • One customer class with no class changes.
      • Poisson external arrivals and exponential service.
      • One or more identical servers per station and arbitrary open routing.
      • Infinite buffers and a stable network.

    State count grows combinatorially with the cap and number of stations.
    The hard state limit stops the run before an unmanageable allocation. For
    a finite loss network use Exact Sparse CTMC; for a broader stochastic
    model use direct queue simulation.
    """

    static let algRegenerativeSimulation = """
    REGENERATIVE MONTE CARLO — QUEUEING PROCESS
    ===========================================

    WHAT IT IS
    ----------
    A continuous-time discrete-event simulation whose IID observations are
    complete empty-system-to-empty-system cycles. It estimates steady-state
    reward ratios and their uncertainty without pretending individual events
    or time slices are independent. Implementation:
    `infinite/BNArmc/regenerative_mc.py`.

    SEQUENTIAL PRECISION
    --------------------
    Precision is checked only at complete regeneration epochs. Every selected
    metric must meet its absolute or relative half-width target, minimum
    effective-cycle count and rare-event positive-cycle safeguard. Summable
    alpha spending covers repeated scheduled looks and monitored metrics.
    Intervals remain asymptotic regenerative-ratio t intervals; they are not
    advertised as exact finite-sample confidence sequences.

    SCOPE
    -----
      • Open multiclass Markovian routing with no class changes.
      • Poisson arrivals and FCFS M/M/c stations.
      • One service rate per station shared across classes.
      • Either all infinite buffers or all finite loss-on-full buffers.
      • Strict Jackson offered-load stability for infinite networks.

    Runs retain a 64-bit base seed and deterministic stream identifier.
    Per-cycle time/event guards stop explicitly rather than truncating a long
    cycle into a biased observation. A likelihood-ratio importance sampler is
    available only for the documented one-node M/M/1/K rare-event case;
    unsupported models are rejected.
    """

    static let algAdaptiveLowRankBAR = """
    ADAPTIVE LOW-RANK BAR — ORTHANT SRBM
    ====================================

    WHAT IT IS
    ----------
    A grid-free numerical approximation of an orthant SRBM's stationary
    transform by a nonnegative mixture of separable exponentials.
    Implementation: `infinite/BNAalr/low_rank_bar.py`.

    HOW IT WORKS
    ------------
    The solver fits the Basic Adjoint Relationship (BAR) on a deterministic
    training set, checks it on a separate held-out collocation set, and
    increases mixture rank. It stops only after both the held-out residual and
    successive moment change meet their requested tolerances twice. Storage
    grows roughly with rank times dimension instead of a full tensor grid.

    EVIDENCE AND CLAIMS
    -------------------
    The displayed BAR residual and moment-refinement change are numerical
    diagnostics, not error bounds. A finite set of transform points may miss
    local or tail behavior. The method claims an exact rank-one result only
    when the Harrison–Williams skew-symmetry identity holds exactly for the
    supplied decimals and held-out BAR also passes; all other results are
    labeled approximations.

    SCOPE
    -----
      • Stable orthant SRBM with constant drift and covariance.
      • Positive-semidefinite covariance with positive diagonal.
      • Nonsingular M-matrix reflection and −R⁻¹μ > 0.
      • One to sixteen station-workload dimensions.

    This solves the diffusion exported from the queue network. Agreement with
    Spectral, LP, or SRBM MLMC checks the SRBM numerics, not the diffusion's
    approximation error relative to the discrete queue.
    """

    static let algBARMomentBounds = """
    BAR STEADY-STATE MOMENT BOUNDS — ORTHANT SRBM
    =============================================

    WHAT IT IS
    ----------
    A polynomial Basic Adjoint Relationship outer relaxation for stationary
    SRBM moments. It builds interior and boundary Stieltjes moment matrices,
    face-support identities and BAR equalities. Implementation:
    `infinite/BNAbb/solver.py`.

    CERTIFICATION POLICY
    --------------------
    Stable one-dimensional SRBMs and exactly skew-symmetric product-form
    SRBMs receive exact rational point bounds and are labeled certified.
    General models require an optional SDP solver. Floating-point CVXPY
    results include independent residual, nonnegativity and eigenvalue checks,
    but remain explicitly uncertified. With no SDP backend, Qnet still builds
    and reports the auditable conic relaxation without inventing bounds.

    SCOPE AND LIMITS
    ----------------
      • Strictly positive-definite covariance.
      • Nonsingular reflection M-matrix and strict SRBM stability.
      • Infinite-buffer orthant diffusion only.
      • Finite relaxation order; cost grows combinatorially with dimension.

    The outer-relaxation interpretation assumes the relevant stationary
    moments exist and justify the polynomial BAR. Noncompact support means a
    finite upper problem can be unbounded, and no finite-order hierarchy
    convergence claim is made. Bounds concern the SRBM—not the discrete queue.
    """

    static let algCTMC = """
    EXACT SPARSE CTMC — FINITE MARKOV CHAIN
    =======================================

    WHAT IT IS
    ----------
    An exact queue-process solver for finite-capacity open Markovian
    networks under loss-on-full semantics. It supports arbitrary routing,
    feedback, multiple FCFS servers, multiple classes, and class changes.
    Queue order is retained, so class-dependent service rates remain exact.
    Implementation: `finite/fBNAgc/solver.py`.

    HOW IT WORKS
    ------------
    1. Begin with the empty network and enumerate every reachable state.
       A station state is the complete ordered FCFS class sequence, not
       merely one count per class.
    2. Store the continuous-time generator as sparse transition lists.
       Arrivals or routed transfers that find a full destination are loss
       rewards; they do not create a state transition.
    3. Uniformize the generator and iterate the stationary row vector until
       its L1 step meets the requested tolerance.
    4. Independently report ||pi Q||_1, flow conservation, population,
       utilization, full/loss probabilities, throughput, and Little's-law
       waiting and sojourn times.

    EXACT SCOPE
    -----------
      • Independent Poisson external-arrival processes.
      • Exponential service by station and class, FCFS, one or more servers.
      • Finite total capacity, including customers in service.
      • Loss on full for external and internally routed arrivals.
      • State-independent routing with an exit path from every reachable
        station/class pair.

    The result has numerical iteration tolerance but no diffusion or Monte
    Carlo error. General BAS is not silently approximated because it needs
    additional blocked-server state; use finite simulation or the explicitly
    approximate finite-buffer decomposition instead.

    LIMITS AND SAFE FAILURE
    -----------------------
    Ordered multiclass state spaces can grow exponentially in capacity,
    classes, and stations. The default reachable-state limit is 200,000.
    Hitting it stops the run with an actionable error; the solver never
    reports a silently truncated chain as exact. For larger networks, use
    finite-buffer decomposition for a fast queue approximation or simulation
    for a direct queue-process estimate with confidence intervals.
    """

    static let algFiniteDecomposition = """
    FINITE-BUFFER DECOMPOSITION — fBNAdecomp
    ========================================

    WHAT IT IS
    ----------
    A fast queue-level approximation for open multiclass finite-capacity
    networks. Each station is solved as an M/M/c/K birth-death queue; routed
    offered flows and admitted throughputs are reconciled by a damped fixed
    point. Implementation: `finite/fBNAdecomp/fbna_decomp.py`.

    MODEL AND OUTPUT
    ----------------
      • Poisson external arrivals and exponential FCFS service.
      • Multiple classes, servers, feedback, and class-changing routes.
      • Exact isolated-station M/M/c/K probabilities computed in log space.
      • Station/class population, queue, utilization, throughput, full/loss
        probability, waiting/sojourn, routed-flow and conservation results.
      • Iteration count, residual history, local balance checks and warnings.

    BLOCKING SEMANTICS
    ------------------
    Loss mode discards external or internal arrivals that see a full station.
    Its network result is still approximate because station occupancies and
    internal departure processes are decoupled.

    BAS and BAS + external loss use an additional frozen-server and enabled-
    arrival independence closure. These modes preserve flow by construction
    but do not reproduce joint blocking-duration correlations. Qnet labels
    them "BAS approximation" everywhere; treat them cautiously when full
    probabilities or feedback are large.

    WHEN TO USE IT
    --------------
    Use this between exact CTMC and simulation: it is useful when the exact
    state space is too large and a quick estimate of finite-capacity effects
    is needed. Check its residual and conservation diagnostics, then compare
    important cases against seeded simulation. It is not a certified bound.
    """

    static let algSimulationFinite = """
    SIMULATION (FINITE BUFFERS) — fBNAsim
    =====================================

    WHAT IT IS
    ----------
    Discrete-event simulation of the queueing network with finite
    buffers. Same engine as the infinite-buffer simulator but with
    blocking semantics enforced. Three blocking modes: Loss, BAS,
    BAS+ExtLoss (chosen by the Run Comparison popup).
    Implementation: `finite/fBNAsim/fBNAsim`.

    HOW IT WORKS
    ------------
    1. Same event-driven engine as jackson_sim (see "Help —
       Simulation (Infinite)" for the basics).
    2. Per-station buffers have a hard cap = buffer_size. When
       a customer arrives or completes service into a full
       buffer:
         Loss mode:  customer is dropped (recorded as a loss).
         BAS mode:   server idles; the customer stays in the
                     server slot and the upstream pipe back-
                     pressures.
         BAS+ExtLoss: same as BAS internally but external
                     arrivals to a full first buffer drop.
    3. Track per-station occupancy, throughput (= served rate),
       loss rate, sojourn time. Report mean ± SE across reps.

    WHEN IT WORKS WELL
    ------------------
      • Queue-process reference for finite-buffer networks. The
        only method that literally simulates the chosen blocking
        protocol (Loss / BAS / BAS+ExtLoss).
      • Networks with arbitrary distributions and arbitrary
        topology — anything you can simulate, this can do.
      • Validation of the SRBM corrections (Loss correction,
        BAS correction): change popup, re-run, see whether the
        algorithm columns track the simulator.

    WHEN IT DOESN'T WORK + ALTERNATIVES
    -----------------------------------
      • Heavy traffic (ρ ≥ 0.97) requires a much longer warmup.
        Mixing slows sharply as utilisation approaches one.
        → Use Spectral with BAS / Loss correction; SRBM is
        asymptotically exact in heavy traffic.

      • Single-class M/M/1 tandems with small buffers.
        → Use CTMC — exact and noise-free.

      • Very large networks (d > 100). Event throughput drops.
        → Use QNA-equivalent methods (no finite-buffer QNA in
        the current shipping set, but you can run the infinite
        version and ignore the buffer effect for a baseline).

    ROBUSTNESS / CURSE OF DIMENSIONALITY
    ------------------------------------
    Cost is proportional to events processed across all replications;
    memory is O(d · max_buffer). Wall time depends on both the simulated
    horizon and event rate. Heavy-traffic
    finite-buffer networks need extra warmup because BAS back-
    pressure causes long mixing times.

    HINTS FOR BETTER RESULTS
    ------------------------
      • Pick the blocking mode that matches your real system.
        The popup choice is sticky — set "Remember choice" to
        skip the dialog on subsequent runs.
      • For tight CIs in heavy traffic: increase warmup to 5M+,
        use 30+ replications, run in parallel mode.
      • The CTMC column (when available) has zero Monte Carlo
        noise. If both CTMC and Sim are shown, prefer CTMC as
        the reference.
      • Compare loss rates (printed in the verbose output) with
        the SRBM Loss-correction iteration — they should agree
        to a few percent if the correction is well-tuned.
    """

    // MARK: - Connect to Anthropic

    static let connectAnthropic = """
    ================================================================================
    HOW TO — Connect the AI Assistant to Anthropic (Claude API)
    ================================================================================

    OVERVIEW
    --------
    The AI Assistant pane (lower-right of the main window) can drive BNET
    via natural language once it is connected to a large language model.
    This guide walks through configuring the Anthropic (Claude) backend.
    The settings live in Settings ▸ AI Assistant.

    STEP 1 — GET AN API KEY FROM ANTHROPIC
    --------------------------------------
      1. Open https://console.anthropic.com/ in a browser.
      2. Sign in (create an account if needed).
      3. In the left sidebar click "API Keys".
      4. Click "Create Key", give it a label (e.g. "Qnet desktop"),
         and copy the key that appears. It starts with "sk-ant-...".
         You will not be able to view the key again after closing the
         dialog — copy it now.
      5. Make sure the account has credit/billing configured. New
         accounts typically come with a small amount of free credit;
         otherwise add a payment method under "Billing".

    STEP 2 — OPEN THE SETTINGS PANE
    -------------------------------
      BNET  →  Settings…  (⌘ ,)  →  AI Assistant  (in the left sidebar)

    STEP 3 — FILL IN THE FIELDS
    ---------------------------
      Show AI Assistant pane     ON  (the toggle at the top of the pane;
                                     flip it off any time to hide the
                                     pane and expand the shell)

      Provider:                  Anthropic (Claude API)

      Base URL:                  https://api.anthropic.com
                                 Leave this alone unless you are
                                 routing through a corporate proxy.
                                 The client appends "/v1/messages"
                                 automatically.

      Model:                     claude-sonnet-4-6
                                 Good default. Other valid choices:
                                   claude-opus-4-7    — most capable,
                                                        costs more
                                   claude-haiku-4-5   — fastest,
                                                        cheapest
                                 Only models your account has access
                                 to will work.

      API Key:                   paste the "sk-ant-..." key from
                                 step 1. Click "Show" to confirm
                                 you pasted correctly. The key is
                                 stored in the macOS Keychain under
                                 service "com.bnetgui.ai", account
                                 "anthropic" — not in UserDefaults,
                                 not in any plain-text file.

      System prompt:             a short instruction the model sees
                                 at the start of every turn. The
                                 default ("You are an assistant
                                 embedded in BNET...") is fine.
                                 Customize if you want a different
                                 tone or extra context.

      Max tokens:                4096 is a reasonable default.
                                 Raise it if you want longer
                                 replies; lower it to cap cost.

      Temperature:               0.7 is fine for chat. Drop toward
                                 0 for deterministic / analytical
                                 answers, raise toward 1 for more
                                 creative output.

      Timeout (seconds):         60. Bump higher only if you see
                                 frequent timeouts under load.

    STEP 4 — SAVE AND TEST
    ----------------------
      1. Click "Save".
      2. Click "Test Connection". BNET sends a one-shot "pong" probe.
         On success you will see:
           ✓ Reply: pong
         On failure you will see an error in red (see troubleshooting
         below).

    STEP 5 — USE IT
    ---------------
    Close Settings and type a prompt into the AI Assistant pane at the
    bottom-right of the main window. Press Enter or click the paper
    airplane icon (⌘↵) to send.

    Examples to try:
      "Summarize the current network."
         → The model calls get_network_summary and describes what it
           finds.
      "Run a comparison."
         → The model calls run_command(name=RunComparison) and the
           output appears in the Shell pane below.

    Tool-call status lines in the transcript start with "▶" and show
    which tool the AI invoked and with what arguments.

    TROUBLESHOOTING
    ---------------
      "AI backend not configured: API key is required..."
        The API key field is empty. Paste the sk-ant-... key and click
        Save before trying again.

      "HTTP 401: ... authentication_error ..."
        The key is invalid or revoked. Generate a new key on the
        Anthropic console and paste it in.

      "HTTP 400: ... model: ... not found"
        The model name you entered is not available to your account.
        Try "claude-sonnet-4-6" or "claude-haiku-4-5" — whichever
        your account is authorized for.

      "HTTP 429: rate_limit"
        Too many requests in the last minute. Wait and retry, or
        switch to a cheaper/smaller model.

      "HTTP 529: overloaded_error"
        Anthropic's servers are temporarily overloaded. Retry in a
        moment; nothing on your end is wrong.

      "Network error: ..."
        No connectivity, DNS issue, or a corporate proxy blocking
        api.anthropic.com. Check your network; if behind a proxy,
        set Base URL accordingly.

      Tool calls never happen
        All four backends (Anthropic, OpenAI, LM Studio, Ollama)
        speak the structured tools[] protocol. For OpenAI, make sure
        you picked a function-calling model (gpt-4o, gpt-4o-mini,
        gpt-4-turbo, or a recent gpt-3.5-turbo). For LM Studio /
        Ollama, the loaded model itself must be tool-trained —
        Llama 3.1+, Qwen 2.5+, and recent Mistral instruct releases
        all work; older and sub-3B models reply in prose instead of
        emitting `tool_calls`. See the per-backend "How to connect"
        help for tool-capable model picks.

    SECURITY NOTES
    --------------
      • The API key lives in the macOS Keychain; you can inspect or
        delete it with Keychain Access (service: com.bnetgui.ai).
      • Conversations are sent to Anthropic's API verbatim. Do not
        paste secrets, credentials, or confidential data into the
        AI Assistant unless you understand Anthropic's data-handling
        policy and are comfortable with it.
      • The model can execute menu commands (run_command). Review
        each ▶ status line in the transcript to see what it did.
    """

    // MARK: - Connect to LM Studio

    static let connectLMStudio = """
    ================================================================================
    HOW TO — Connect the AI Assistant to LM Studio (local inference)
    ================================================================================

    OVERVIEW
    --------
    LM Studio is a free desktop app (Mac / Windows / Linux) that downloads
    open-weights language models and serves them through an
    OpenAI-compatible HTTP endpoint. Pointing Qnet at LM Studio gives you
    a fully-local, offline AI Assistant — no API key, no per-token cost,
    no data leaves your machine.

    Tool calls (get_network_summary, add_node, run_command, etc.)
    work against LM Studio PROVIDED the loaded model is tool-trained.
    Tool capability is per-model, not per-server: Llama 3.1+, Qwen
    2.5+, and recent Mistral instruct releases reliably emit
    `tool_calls`; older or sub-3B models don't. If the assistant
    insists on describing tool steps in prose instead of invoking
    them, that's almost always a model-capability problem, not a
    Qnet config problem. Pick LM Studio when you want privacy,
    offline use, or to experiment with open-weights models.

    STEP 1 — INSTALL LM STUDIO
    --------------------------
      1. Download LM Studio from https://lmstudio.ai/ and install it
         like any other Mac app (drag to /Applications).
      2. Launch LM Studio. The first launch downloads a runtime; let
         it finish before continuing.

    STEP 2 — DOWNLOAD A SUITABLE MODEL
    ----------------------------------
    Open the "Discover" tab (magnifying-glass icon in the left
    sidebar) and search for a model. What to pick:

      • Format: GGUF (the only format LM Studio's CPU/Metal runtime
        loads). Most listings on the Discover tab are already GGUF.

      • Type: an instruction-tuned chat model. Files with names
        containing "Instruct", "Chat", or "IT" are tuned to follow
        prompts; raw "base" models will just complete text and won't
        behave like an assistant.

      • Size: pick the largest you can run comfortably given your
        Mac's unified memory. As a rule of thumb the model file should
        leave at least 4 GB of RAM free for the OS.
            8 GB Mac    →  3B-parameter model, Q4_K_M quant
                           (~2-3 GB on disk)
            16 GB Mac   →  7B / 8B model, Q4_K_M
                           (~4-5 GB on disk)
            32 GB Mac   →  13B / 14B model, Q5_K_M, OR a 32B model
                           at Q4_K_M (~18 GB on disk)
            64 GB+ Mac  →  70B model, Q4_K_M (~40 GB on disk)

      • Concrete recommendations (all instruction-tuned, all known to
        chat well; pick the one whose size matches your Mac):
            Llama-3.1-8B-Instruct (Q4_K_M)         — solid all-rounder
            Qwen2.5-7B-Instruct  (Q4_K_M)          — strong reasoning
            Qwen2.5-14B-Instruct (Q4_K_M)          — better answers,
                                                     needs 16 GB+
            Llama-3.3-70B-Instruct (Q4_K_M)        — closest to a
                                                     frontier model,
                                                     needs 64 GB+

      • Quantization: "Q4_K_M" is the sweet spot for size vs. quality.
        Q5_K_M / Q6_K are slightly better at the cost of more RAM.
        Avoid Q2 / Q3 — they degrade noticeably for chat.

      • Context window: any modern instruct model has at least 8K
        tokens of context, which is plenty for the AI Assistant's
        prompts. Larger contexts cost more RAM at load time.

    Click "Download" on the model card and wait for it to finish.

    STEP 3 — START THE LOCAL SERVER
    -------------------------------
      1. Switch to the "Developer" tab (terminal-prompt icon in the
         left sidebar; older builds call this "Local Server").
      2. At the top, choose the model you downloaded from the
         "Select a model to load" dropdown. Wait for the load to
         complete (LM Studio shows a green "Ready" badge).
      3. Confirm the server settings:
            Server port:       1234   (LM Studio's default)
            CORS:              on     (harmless for local use)
            Just-in-time load: on     (auto-reloads if you switch
                                      models; optional)
      4. Click "Start Server" (or the green play button at the top
         of the panel). The endpoint banner reads:
            http://localhost:1234
         and "Reachable at" shows your machine's LAN IP.

    Verify from a terminal that the server is alive:

        curl http://localhost:1234/v1/models

    You should see a JSON list with one entry whose "id" matches the
    name shown next to the loaded model in LM Studio.

    STEP 4 — POINT QNET AT LM STUDIO
    --------------------------------
      Qnet  →  Settings…  (⌘ ,)  →  AI Assistant

      Show AI Assistant pane     ON

      Provider:                  LM Studio (local)

      Base URL:                  http://localhost:1234/v1
                                 This is the default. Qnet appends
                                 "/chat/completions" automatically.
                                 If you started LM Studio on a
                                 different port, change 1234 to match.
                                 To talk to LM Studio running on
                                 another machine on your LAN, use that
                                 machine's IP, e.g.
                                 http://192.168.1.42:1234/v1.

      Model:                     copy the EXACT model id shown in the
                                 LM Studio Developer tab (it usually
                                 matches the download folder name,
                                 e.g. "qwen2.5-7b-instruct" or
                                 "llama-3.1-8b-instruct"). The
                                 placeholder "local-model" only works
                                 if LM Studio's "Just-in-time load"
                                 toggle aliases it for you.

                                 SHORTCUT: click the arrow.clockwise
                                 button next to the Model field to
                                 probe LM Studio's /v1/models endpoint
                                 and populate the dropdown with the
                                 model ids it's currently serving. The
                                 dropdown groups results under
                                 "From server" (live probe) and
                                 "Recommended" (Qnet's curated list).
                                 Note: LM Studio only reports models
                                 that are actually LOADED in the Local
                                 Server tab — if the dropdown comes
                                 back empty, load a model and click
                                 refresh again.

      API Key:                   leave blank. LM Studio does not
                                 require authentication on a
                                 localhost server. (If you put
                                 anything here, Qnet will send it as
                                 a Bearer token; LM Studio ignores
                                 it.)

      System prompt:             the default is fine. With a smaller
                                 local model you may want to add
                                 explicit instructions like "Be
                                 concise. Use plain text. Do not
                                 emit code unless asked."

      Max tokens:                4096 is fine. Smaller (1024-2048)
                                 makes replies snappier on slower
                                 hardware.

      Temperature:               0.3-0.7. Smaller open-weights models
                                 ramble at high temperature; drop to
                                 0.3 if answers feel unfocused.

      Timeout (seconds):         60 is enough for most replies on
                                 Apple Silicon. Bump to 180+ if you
                                 are running a 70B model on a Mac
                                 with limited RAM (slow first token).

    STEP 5 — SAVE AND TEST
    ----------------------
      1. Click "Save".
      2. Click "Test Connection". Qnet sends a one-shot "pong" probe.
         On success you will see:
           ✓ Reply: pong
         (Smaller models sometimes reply with extra words around
         "pong" — that still counts as a successful round-trip.)

    STEP 6 — USE IT
    ---------------
    Type a prompt into the AI Assistant pane. The first reply is
    slower than subsequent ones because LM Studio has to warm the
    model into RAM and build a KV cache; after that, response time
    is steady.

    Examples that work well in chat-only mode:
      "Explain in plain English how the spectral method computes
       steady-state means for a Brownian network."
      "I'm trying to model a 3-station tandem queue with feedback
       from station 3 back to station 1. What rate vector and routing
       matrix should I use?"
      "What's the difference between a finite-element solver and a
       linear-program solver for this kind of problem?"

    HOW TOOLS BEHAVE ON THIS BACKEND
    --------------------------------
    Qnet sends the eight-tool catalog using the OpenAI Chat
    Completions tool schema (which LM Studio implements verbatim).
    The model decides whether to invoke a tool each turn; results
    are fed back as `role: "tool"` messages keyed by the assistant's
    original `tool_call_id`.

    The user-visible behavior depends on the loaded model:
      • Tool-trained models (Llama 3.1+, Qwen 2.5+, recent Mistral
        instruct, etc.) — full parity with the Anthropic / OpenAI
        backends. "Build me a 2-station tandem with a Poisson
        source" will trigger chained add_node / add_link calls and
        the network appears on the canvas.
      • Older / smaller / non-instruct models — LM Studio still
        accepts the request, but the model lacks the training to
        emit `tool_calls`. It will reply in prose instead. Switch
        to a tool-capable model from STEP 2 if that happens.

    Aggressive quantization (q2, q3) sometimes breaks the JSON
    formatting of tool-call arguments even on otherwise tool-capable
    models — re-download at q4_K_M or higher if you see malformed-
    arguments errors in the AI transcript.

    TROUBLESHOOTING
    ---------------
      "Network error: Could not connect to the server"
        LM Studio's server is not running, or the port doesn't match.
        Reopen LM Studio's Developer tab and confirm the green "Server
        running on port 1234" banner is showing.

      "HTTP 404: Cannot POST /v1/chat/completions"
        Base URL is wrong. The OpenAI-compatible path is "/v1" — make
        sure the URL ends in "/v1" (e.g. http://localhost:1234/v1),
        NOT "/v1/chat/completions" (Qnet appends that itself).

      "HTTP 400: model 'local-model' not found"
        The placeholder model id doesn't match what is loaded. Copy
        the exact id from LM Studio's Developer tab into the Model
        field.

      Test Connection succeeds but real prompts time out
        The model is probably swapping to disk. Pick a smaller model
        (e.g. drop from 14B → 7B), a smaller quant (Q5_K_M → Q4_K_M),
        or close other RAM-hungry apps.

      Replies are gibberish or repeat themselves
        You loaded a base (non-instruct) model. Re-download a variant
        whose name contains "Instruct", "Chat", or "IT".

      Replies are extremely slow on first token
        Normal cold-start cost — LM Studio loads weights on demand.
        Send one warm-up prompt right after starting the server, or
        enable "Keep model in memory" in LM Studio's settings.

    SECURITY / PRIVACY NOTES
    ------------------------
      • The conversation never leaves your machine. LM Studio writes
        no logs to the cloud and Qnet sends only to the URL you
        configured.
      • If you bind LM Studio to 0.0.0.0 (or expose port 1234 across
        your network), anyone on that network can use your model.
        Keep it on localhost unless you specifically want LAN access.
      • With a tool-capable model loaded, the AI can drive every
        menu command (run_command), add/delete nodes, edit
        parameters, etc. Review the ▶ tool-call status lines in the
        AI transcript so you see what the assistant did.
    """

    // MARK: - Connect to Ollama

    static let connectOllama = """
    ================================================================================
    HOW TO — Connect the AI Assistant to Ollama (local inference)
    ================================================================================

    OVERVIEW
    --------
    Ollama is a free, command-line-driven local inference server (Mac /
    Windows / Linux) that downloads open-weights models and exposes
    them on a localhost HTTP endpoint. Pointing Qnet at Ollama gives
    you a fully-local, offline AI Assistant — no API key, no per-token
    cost, no data leaves your machine.

    Compared to LM Studio: Ollama has no GUI, runs as a background
    daemon (autostarts on macOS once installed), and uses a simpler
    "MODEL:TAG" naming scheme. LM Studio has a richer GUI for browsing
    and configuring models. Either backend reaches the same set of
    open-weights models — pick whichever fits your workflow.

    Tool calls (get_network_summary, add_node, run_command, etc.) work
    against Ollama PROVIDED the loaded model is tool-trained. Tool
    capability is per-model, not per-server: Llama 3.1+, Qwen 2.5+,
    and recent Mistral instruct releases reliably emit `tool_calls`;
    older or sub-3B models don't. If the assistant insists on
    describing tool steps in prose instead of invoking them, that's
    almost always a model-capability problem, not a Qnet config
    problem.

    STEP 1 — INSTALL OLLAMA
    -----------------------
    Mac (recommended): download the .dmg from https://ollama.com/ and
    drag to /Applications. The first launch installs a launchd agent
    that starts the server automatically on every login.

    Or via Homebrew:
        brew install ollama
        brew services start ollama

    Verify the daemon is up from a terminal:
        curl http://localhost:11434/api/tags

    You should see a JSON object whose `models` array is empty (no
    models pulled yet) or lists previously-pulled models.

    STEP 2 — PULL A SUITABLE MODEL
    ------------------------------
    Ollama identifies models by a `name:tag` pair. The tag specifies
    parameter count + quantization. Pull from the terminal:

        ollama pull llama3.1:8b-instruct-q4_K_M

    What to pick:

      • Type: an instruction-tuned chat model (tag contains
        "instruct"). Raw base models behave like text completers, not
        assistants.

      • Size: pick the largest you can run comfortably given your
        Mac's unified memory. Rule of thumb — leave at least 4 GB
        free for the OS.
            8 GB Mac    →  3B-parameter model, q4_K_M quant
            16 GB Mac   →  7B / 8B model, q4_K_M
            32 GB Mac   →  13B / 14B model, q5_K_M, OR a 32B model
                           at q4_K_M
            64 GB+ Mac  →  70B model, q4_K_M

      • Concrete tool-capable picks (all instruction-tuned, all
        function-call-trained):
            llama3.1:8b-instruct-q4_K_M       — solid all-rounder
            qwen2.5:7b-instruct-q4_K_M        — strong reasoning
            qwen2.5:14b-instruct-q4_K_M       — better answers,
                                                needs 16 GB+
            llama3.3:70b-instruct-q4_K_M      — closest to a frontier
                                                model, needs 64 GB+

      • Quantization: q4_K_M is the sweet spot for size vs. quality.
        q5_K_M / q6_K are slightly better at the cost of more RAM.
        Avoid q2 / q3 for chat — degrades noticeably and breaks
        tool-call JSON output.

    Check what you've pulled:
        ollama list

    STEP 3 — VERIFY THE SERVER
    --------------------------
    The daemon listens on http://localhost:11434 by default. Confirm
    a chat request round-trips:

        curl http://localhost:11434/api/chat -d '{
          "model": "llama3.1:8b-instruct-q4_K_M",
          "messages": [{"role": "user", "content": "say pong"}],
          "stream": false
        }'

    The first request after pulling a model is slow — Ollama warms
    weights into RAM on demand. Subsequent requests against the same
    model are fast.

    STEP 4 — POINT QNET AT OLLAMA
    -----------------------------
      Qnet  →  Settings…  (⌘ ,)  →  AI Assistant

      Show AI Assistant pane     ON

      Provider:                  Ollama (local)

      Base URL:                  http://localhost:11434
                                 The default. Qnet appends "/api/chat"
                                 automatically. To talk to Ollama
                                 running on another machine on your
                                 LAN, point at that machine's IP, e.g.
                                 http://192.168.1.42:11434 (and
                                 configure Ollama to bind to 0.0.0.0
                                 — see https://github.com/ollama/ollama/blob/main/docs/faq.md).

      Model:                     copy the EXACT name:tag from
                                 `ollama list` (e.g.
                                 llama3.1:8b-instruct-q4_K_M). The
                                 tag matters — without it, Ollama
                                 picks an arbitrary default.

      API Key:                   leave blank. Ollama doesn't
                                 authenticate localhost connections.

      System prompt:             the default is fine. With a smaller
                                 local model you may want to add
                                 "Be concise. Use plain text. Call
                                 tools when the user asks you to
                                 modify the network."

      Max tokens:                4096. Smaller (1024-2048) makes
                                 replies snappier on slower hardware.

      Temperature:               0.3-0.7. Smaller open-weights models
                                 ramble at high temperature; drop to
                                 0.3 if answers feel unfocused or
                                 tool calls become sloppy.

      Timeout (seconds):         60 is enough on Apple Silicon.
                                 Bump to 180+ for 70B models on Macs
                                 with limited RAM (slow first token).

    STEP 5 — SAVE AND TEST
    ----------------------
      1. Click "Save".
      2. Click "Test Connection". Qnet sends a one-shot "pong" probe.
         On success you see:
           ✓ Reply: pong

    STEP 6 — USE IT
    ---------------
    Type a prompt into the AI Assistant pane. With a tool-capable
    model loaded, all eight Qnet tools (get_network_summary,
    add_node, delete_node, add_link, delete_link, update_node,
    update_link, run_command) are available — same as the
    Anthropic / OpenAI backends.

    Examples that exercise the full surface:
      "Summarize the current network."
         → calls get_network_summary, replies in prose.
      "Build me a 2-station tandem with a Poisson source rate=1.5
       and exponential service rate=2 at both stations."
         → chained add_node + add_link calls, network appears on
           the canvas.
      "Run a comparison."
         → run_command(name=RunComparison) — output streams to the
           Interactive Shell.

    HOW TOOLS BEHAVE ON THIS BACKEND
    --------------------------------
    Qnet sends the eight-tool catalog using Ollama's native
    `tools[]` schema. The model decides whether to invoke a tool
    each turn; results are fed back as `role: "tool"` messages.

    Ollama's wire format differs from OpenAI's in two small ways
    Qnet handles internally:
      • `tool_calls[]` entries don't carry call IDs — Qnet
        synthesizes UUIDs locally and matches results positionally.
      • `arguments` is delivered as a parsed JSON object (not a
        string), so the tool dispatcher gets the exact same shape
        it would from Anthropic.

    If the loaded model isn't tool-capable, Ollama still accepts
    the request but the model's response will lack `tool_calls`
    and read like "Sure, here's how you'd add a node…" instead of
    actually adding one. Switch to one of the picks listed in
    STEP 2 if that happens.

    TROUBLESHOOTING
    ---------------
      "Network error: Could not connect to the server"
        The Ollama daemon isn't running. Try:
          brew services start ollama
        or relaunch the Ollama.app from /Applications.

      "HTTP 404: model 'X' not found, try pulling it first"
        You typed a model name that hasn't been pulled. Run
        `ollama list` to see what's available, or
        `ollama pull <name>` to fetch.

      Replies are gibberish or repeat themselves
        Probably a base (non-instruct) model. Pull a tag whose
        name contains "instruct".

      Tool calls never happen even though the model SHOULD support them
        Some quantized model files lose tool-call reliability under
        aggressive quantization (q2 / q3). Re-pull at q4_K_M or
        higher. Also: a `system` prompt that says "Answer concisely"
        sometimes nudges the model away from emitting tool_calls;
        add an explicit "Use the provided tools when appropriate"
        clause.

      First-token latency is multiple seconds
        Cold-start cost while Ollama loads weights. Set
        OLLAMA_KEEP_ALIVE=24h in launchctl to pin loaded models in
        RAM:
          launchctl setenv OLLAMA_KEEP_ALIVE 24h
        (then restart the Ollama daemon).

      Replies are extremely slow throughout the conversation
        The model is paging weights from disk because there isn't
        enough free RAM. Pick a smaller model (8B → 3B) or a
        smaller quant.

    SECURITY / PRIVACY NOTES
    ------------------------
      • The conversation never leaves your machine. Ollama writes
        no logs to the cloud and Qnet sends only to the URL you
        configured.
      • Default bind is localhost only. To enable LAN access you
        must explicitly set OLLAMA_HOST=0.0.0.0 — be aware that
        anyone on that network can then use your model.
      • With tool use enabled, the model can drive every menu
        command (run_command), add/delete nodes, edit parameters,
        etc. Review the ▶ tool-call status lines in the AI
        transcript so you see what the assistant did.
    """

    // MARK: - Infinite-buffer Linear Program (BNAlp / srbm_lp)

    static let algLinearProgramInfinite = """
    LINEAR PROGRAM — INFINITE BUFFERS (BNAlp / `srbm_lp`)
    =====================================================

    WHAT IT IS
    ----------
    A linear-programming relaxation of the SRBM stationary
    distribution on the positive orthant, after Saure, Glynn and
    Zeevi (2008). Instead of solving the Basic Adjoint Relationship
    (BAR) exactly, it asks for a density that satisfies the BAR at a
    finite set of grid points and is spanned by a small polynomial
    basis, then lets an LP solver pick the coefficients. The answer
    is a set of stationary moments — the mean workload per station,
    which Qnet converts to a mean queue length with the effective
    service rate μ_eff.
    Implementation: `infinite/BNAlp/srbm_lp`.

    HOW IT WORKS
    ------------
    1. Build the SRBM primitives (drift θ, covariance Γ, reflection R)
       from the network exactly as the spectral method does.
    2. Lay a grid S_n over the orthant with n points per coordinate.
       Three spacings are offered: exponential (points thin out with
       distance from the origin, matching the exponential decay of
       the density), dyadic (halving intervals) and exponential with
       random jitter (breaks grid artefacts at the cost of
       reproducibility between runs).
    3. Choose m monomial basis functions per coordinate. The density
       is represented by its moments against this basis, so m is the
       number of moments the LP can see.
    4. Write the BAR as one linear equality per grid point and basis
       function, add the normalisation and non-negativity constraints,
       and solve the LP. The solver is HiGHS by default; GLPK and
       CPLEX are used when they are compiled in and selected.
    5. Read the first moments off the solution: E[Y_i] per station.

    WHAT THE PARAMETERS MEAN
    ------------------------
      • Grid size n — constraint points per dimension. More points
        tighten the relaxation and grow the LP as n^d. Leave blank
        for a size chosen from the number of stations:

            d = 1, 2:  n = 100, m = 6
            d = 3:     n = 25,  m = 5
            d = 4:     n = 12,  m = 4
            d = 5:     n = 10,  m = 3
            d = 6:     n = 8,   m = 3
            d ≥ 7:     n = 6,   m = 3

      • Basis size m — monomial basis functions per coordinate. More
        functions fit a richer density and make the program harder
        to condition; above m ≈ 8 switch on basis normalisation.
      • Grid type — exponential is the paper's choice and the right
        default; dyadic is cheaper on very wide domains; exponential
        (random) is for checking that a result is not a grid artefact.
      • LP backend — Auto lets the binary pick the first solver it
        was built with (HiGHS in the shipped build).
      • Smoothness weight — a penalty on the total variation of the
        fitted density, applied lexicographically after the BAR
        residual (paper §6.3). Zero disables it; 0.1–1 smooths the
        marginals when the solution shows ripples between grid
        points.
      • Normalise monomial basis — scales each monomial row by the
        grid extent so the constraint matrix is well conditioned.
        Strongly recommended for d ≥ 3 or m ≥ 6.
      • Multi-level refinement — runs a coarse preview at half the
        grid (never below 6 points) first, then the full grid, so a
        long run shows a first answer early. Only applies when n ≥ 8.

    Settings ▸ Linear Program keeps the defaults; tick "Ask before
    each run" there and Run ▸ Run Linear Program opens the parameter
    sheet every time.

    WHEN IT IS TRUSTWORTHY
    ----------------------
      • Heavy traffic (ρ ≥ 0.8 at the bottleneck), where the SRBM
        itself is a good model of the network.
      • Moderate dimension (d ≤ 4) with the automatic grid: the
        first moments agree with the spectral method to within a
        few percent and the run takes seconds.
      • As a cross-check on the spectral method: both solve the same
        SRBM, so a disagreement between them points at a
        discretisation error in one of them, not at the model.

    WHEN IT IS NOT
    --------------
      • Light traffic (ρ ≤ 0.5): the diffusion approximation itself
        is off, whichever solver is used. Use QNA or simulation.
      • d ≥ 5 with a grid the LP can afford: the relaxation is too
        loose to trust beyond the first moment.
        → Compare with SRBM MLMC (BNAmc), which has no spatial grid.
      • An infeasible LP (the solver reports it): usually heavy
        traffic with an unnormalised basis.
        → Turn on basis normalisation, lower m by one, or change
          the backend.

    WHAT IT PRINTS
    --------------
    Per station: E[Q_i] (workload E[Y_i] × μ_eff,i), plus the solver
    name, the LP objective and the wall-clock time. This method emits
    moments only — no ρ, Γ or sojourn rows — so its column in Run
    Comparison is shorter than the others.
    """

    // MARK: - Multi-class SRBM (experimental research solver)

    static let algMultiClassSRBM = """
    MULTI-CLASS SRBM — EXPERIMENTAL (`mc_solver`)
    =============================================

    WHAT IT IS
    ----------
    A research solver for multi-class networks with infinite buffers.
    The production SRBM path (Spectral, Finite Element, Linear
    Program) collapses every class at a station into one aggregate
    service law before it builds the diffusion. This solver keeps
    the classes apart for as long as it can: it forms a compound
    service-time distribution per station from the per-class laws
    and their visit frequencies, derives the covariance of the
    Brownian motion from per-class routing variance, and builds the
    reflection matrix by the Harrison–Reiman construction. The
    resulting SRBM is then solved by a finite-element discretisation
    on a growing box.
    Implementation: `infinite/BNAmd/mc_solver`. It is
    part of the maintained source tree and is included in release app
    bundles. Its numerical-library dependencies are listed in that
    directory's README.

    HOW IT WORKS
    ------------
    1. Qnet writes the canvas to a temporary .bnet file. Unlike
       every other solver this one reads the network description
       directly, not an exporter's output, so what it sees is
       exactly what is drawn.
    2. Per station, the per-class service laws are combined into
       one compound law whose first two moments respect the class
       mix (the "research" formulation) — or, with the legacy
       formulation, replaced by the same aggregate the production
       SRBM export uses.
    3. Routing variance is computed per class and summed into the
       covariance matrix Γ; the reflection matrix R follows
       Harrison–Reiman.
    4. The SRBM is discretised on a finite truncation box with a
       Hermite finite-element mesh. The mesh has a dimension-aware
       cap; this run does not itself certify truncation error, so
       repeat at another domain/mesh and compare.

    WHAT THE PARAMETERS MEAN
    ------------------------
      • Formulation — Research uses the compound-service and
        routing-variance formulas above. Legacy reproduces the
        production SRBM primitives, so the two formulations can be
        compared on one network to isolate the effect of the
        multi-class treatment.
      • Mesh size per dimension — finite elements along each axis.
        Leave blank for a cap chosen from the number of stations;
        the element count is the mesh size raised to d, so one more
        cell per axis can multiply the run time.

    WHEN IT IS TRUSTWORTHY
    ----------------------
      • Multi-class networks where classes at one station have
        service times that differ by a factor of two or more — the
        case the aggregate treatment handles worst.
      • Heavy traffic, as with every SRBM method.
      • As an experiment beside Run Comparison: run both and read
        the two E[X] columns side by side against simulation.

    WHEN IT IS NOT
    --------------
      • Finite-buffer networks: the solver assumes infinite buffers
        and ignores capacities.
      • A result that has not been checked across mesh/domain choices
        and against queue-process simulation. The result workspace
        retains the formulation and network snapshot for reproduction.
      • Single-class networks: it reduces to the ordinary SRBM and
        the spectral method is faster and better validated.

    WHAT IT PRINTS
    --------------
    Per station: ρ, E[X], Γ and the sojourn time, in the same
    metric-per-row layout as the other single-method runs, with the
    formulation and mesh size named in the banner.
    """

    // MARK: - Solver input files (File ▸ Export, Qnet --export-cmp)

    static let solverInputs = """
    SOLVER INPUT FILES
    ==================

    WHAT THEY ARE
    -------------
    Every method in Qnet is a separate command-line program that reads
    a small text file describing the network. The Run menu writes
    those files to a temporary folder and runs the program for you;
    File ▸ Export writes the same files somewhere you choose, so a
    solver can be run by hand, scripted, or handed to a colleague
    without Qnet. The GUI's own headless mode writes the whole set:

        Qnet --export-cmp network.bnet /path/to/folder

    WHICH FILE FEEDS WHICH SOLVER
    -----------------------------
        qna.qna       QNA, RQNA, SBD          bna_qna, bna_rqna, bna_sbd
        cmp_sm.in     Spectral (infinite)     bnet
        cmp_sim.sim   Simulation (infinite)   jackson_sim
        sm.in         Spectral (finite)       srbm_solver
        fm.in         Finite Element          bna_fm_gauss, bna_fm_cbc
        lp.in         Finite-Buffer LP        fBNAlp_solver
        sim.txt       Simulation (finite)     fBNAsim
        network.bnet  Linear Program, Exact   srbm_lp, rbm_mlmc
                      Simulation, Multi-Class (read the .bnet directly)

    THE EXPORT COMMANDS
    -------------------
      • Export ▸ SRBM Solver Input (.in)… — the drift, covariance and
        reflection data for the spectral solvers. On a finite-buffer
        network the sheet also asks which blocking convention the
        file should encode.
      • Export ▸ QNA Input (.qna)… — the rates, squared coefficients
        of variation and routing matrix for the QNA family.
      • Export ▸ Finite Simulator Input (fBNAsim)… — the network
        description for the finite-buffer simulator.
      • Export ▸ All Solver Inputs to Folder… (⌘E) — every file in
        the table above, into one folder, with the same blocking
        choice for the three finite-buffer SRBM files.

    BLOCKING CONVENTION
    -------------------
    Only sm.in, fm.in and lp.in depend on it; the QNA and simulator
    inputs do not. The SRBM solves a manufacturing-blocking model;
    the Loss and BAS corrections adjust its primitives so it matches
    a loss network or blocking-after-service with external loss. The
    same choice appears on the command line as --loss-fix / --bas-fix,
    so a folder exported from the GUI holds exactly what the script
    would have produced. SRBM in a Hypercube explains the three
    conventions and why the simulator can disagree with the SRBM
    methods when they differ.

    RUNNING A SOLVER BY HAND
    ------------------------
    Every solver takes -c for compact, machine-readable output: an
    algorithm banner, then one line per station of the form
    rho_N = v, Gamma_N = v, sojourn_N = v and E[Q_N] (infinite) or
    E[X_N] (finite). Simulators append a tab and the 95 % half-width.

        infinite/BNAqna/bna_qna  folder/qna.qna -c
        infinite/BNAsm/bnet   -c folder/cmp_sm.in
        infinite/BNAsim/jackson_sim folder/cmp_sim.sim -c -n 5 -r 2000

    The paths are relative to the Qnet source tree; inside Qnet.app
    the binaries live under Contents/Resources/bin.
    """
}
