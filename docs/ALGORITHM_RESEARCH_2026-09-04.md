# Further steady-state algorithms for Qnet

Literature survey and proposed development roadmap · 4 September 2026 · baseline: Qnet 0.90.34

## Recommendation in brief

My first three additions would be **phase-type/Markovian-arrival queue models**, **exact finite-state blocking models**, and **Poisson-equation control variates for the existing simulator**. They address different gaps: distributional detail, correct blocking semantics, and computational cost. Next I would add error-controlled infinite-state truncation and bottleneck-cluster decomposition. Neural methods are worth a research prototype, but not the first production investment.

This is a targeted survey of methods relevant to the models represented in Qnet, not a systematic review of every queueing paper. It covers foundational research and selected recent developments available by the date above. Recommendations, priorities, and Qnet-specific designs below are my synthesis; they are not claims made by the cited authors. No proposed numerical algorithm has been implemented as part of this survey, and this is not a review of the effectiveness of the existing numerical code.

## 1. What is already present—and what is actually new

The supplied source contains QNA/RQNA, discrete-event queue simulation, SRBM spectral/finite-element/LP/MLMC methods, SBD, and newer sparse CTMC, matrix-geometric QBD, product-form, truncated-CTMC, regenerative, BAR-bound, low-rank BAR, and experimental multiclass-diffusion modules. See `STEADY_STATE_METHODS.md` for the detailed contracts. An algorithm existing as a general command-line module does not mean the GUI can represent its full input class.

| Existing capability | Useful next step, without duplicating it |
|---|---|
| General QBD block solver; GUI restricted to scalar M/M/1 | Generate blocks from MAP/PH models; add richer boundaries and matrix-analytic families |
| Finite CTMC for Markovian loss-on-full networks | Explicit blocked-server states for blocking after/before service |
| Closed/open/mixed product-form module; restricted GUI | Mean-value analysis, scalable normalizers, and closed-population model entry |
| Adaptive truncated CTMC | Broader non-product-form generators plus independently checkable tail/moment bounds |
| Regenerative simulation; narrow importance sampling | Poisson controls and network-level rare-event simulation |
| Low-rank exponential-mixture BAR approximation | Tensor-compressed discrete CTMC stationary vectors—a different object |
| SRBM moment/LP and finite-domain numerical methods | Full rectangle BAR with upper-face measures and goal-oriented error estimation |
| RQNA dispersion propagation | Explicit stochastic arrival phases/correlation models, rather than another two-moment formula |

The Whitt–You RQNA paper targets open, single-class, single-server networks with general service and Markovian routing, using dispersion over multiple timescales. Qnet-specific multiclass or multi-server extensions should not inherit the paper's scope automatically. That distinction matters when choosing benchmark models. [Whitt and You, *A Robust Queueing Network Analyzer Based on Indices of Dispersion*](https://arxiv.org/abs/2003.11174).

## 2. Candidate algorithms, ordered by expected value for Qnet

### 1. MAP/PH queue solvers and phase-aware network decomposition

**What to add.** A phase-type (PH) service representation and a Markovian arrival process (MAP) representation. Start with M/Erlang-k/1, M/hyperexponential/1, and MAP/PH/1. Generate the boundary and interior QBD blocks automatically, then reuse the existing matrix-geometric solver. Subsequently add multi-server finite-boundary models, priorities, batch arrivals, and M/G/1-type block algorithms where appropriate.

BuTools provides primary reference implementations of block-structured chains, PH/MAP representations, multiclass PH queues, and fluid queues. It is a useful independent benchmark, not a dependency that must be added to the application. [Horváth and Telek, BuTools source and documentation](https://github.com/ghorvath78/butools).

**Why this helps.** Qnet can model low/high service variability and correlated input with an explicit stochastic model. PH fitting by expectation-maximization is an established alternative to fitting only mean and variance. [Asmussen, Nerman and Olsson, *Fitting Phase-Type Distributions via the EM Algorithm*, 1996](https://pure.au.dk/portal/en/publications/fitting-phase-type-distributions-via-the-em-algorithm/).

**Accuracy contract.** The matrix solution is exact for the specified finite-phase Markov model, up to numerical tolerance. Fitting PH to a non-PH distribution introduces modeling error. Replacing network departure streams by finite MAPs introduces another approximation: arbitrary MAP/PH networks do not become product-form or a finite-phase QBD merely because each node does. Finite PH fits also do not reproduce true heavy-tail asymptotics.

**First acceptance tests.** Recover M/M/1, match Pollaczek–Khinchine means for M/PH/1, compare Erlang and hyperexponential cases at the same mean, verify normalization and matrix residuals, and compare correlated-arrival cases against independent simulation. UI inputs must distinguish a specified phase model from a fitted approximation.

### 2. Exact finite CTMC with genuine blocking after service

**What to add.** Extend the finite-state model generator with the server's status, completed customer's intended destination/class, and waiting/blocked customer order. Start with one-class two-station BAS networks. Treat blocking before service as a separate model with an explicit reservation/selection rule—not a renamed BAS flag.

Blocking mechanisms can have different state spaces and stationary behavior even when capacities and service rates match; exact and decomposition approaches have a substantial literature. [Perros, *A Survey of Queueing Networks with Blocking, Part I*, 1986](https://repository.lib.ncsu.edu/items/0c11624e-f1d1-4549-b114-32d8794c9cd2).

**Why this helps.** Qnet's exact loss-network CTMC is not an exact reference for BAS examples. A small exact BAS solver would establish a trustworthy reference for finite-buffer simulation, decomposition, and diffusion approximations.

**Accuracy contract.** Exact for finite Markovian networks under the explicitly chosen blocking discipline. Detect reachable deadlocks and multiple closed communicating classes. A finite chain need not have one meaningful operational equilibrium; absorption in deadlock is not a solver convergence defect.

**First acceptance tests.** Hand-enumerated two-station states; loss versus BAS at identical capacities; capacities including versus excluding service positions; cyclic deadlock; and nonblocking large-capacity limits. Report blocked-server probability separately from occupancy/full probability and loss rate.

### 3. Poisson-equation/martingale variance reduction

Approximate analytic or numerical information can be converted into martingale control variates for Markov-process simulation. This connects naturally to Qnet's combination of approximation methods and simulators. [Henderson and Glynn, *Approximating Martingales for Variance Reduction in Markov Process Simulation*, 2002](https://web.stanford.edu/~glynn/papers/2002/HendersonG02.html).

**What to add.** A simulation mode that learns a control function during a pilot run, freezes it, and reports an independently estimated controlled mean and confidence interval alongside the ordinary estimator. Initial targets should be mean queue length and total population in Markovian open networks; add non-Markovian models only after including residual-time state.

**Accuracy contract.** The simulation still targets the queue, not the diffusion. A poor control can increase variance. Report achieved variance reduction per unit wall-clock time, not just per observation. Initialization bias and statistical uncertainty remain distinct. Section 3 gives a concrete implementation design.

**First acceptance tests.** Known M/M/1 and Jackson means; repeated-run interval coverage; difficult feedback examples; and automatic fallback when the control costs more than it saves.

### 4. Certified or error-controlled truncation of infinite CTMCs

**What to add.** Construct stationary-distribution bounds using Foster–Lyapunov drift conditions, finite truncations, and linear programming. Expand the retained region according to the performance measure requested. This goes beyond observing that two successive caps give similar answers. Kuntz and colleagues survey convergence and error control; their related mathematical-programming paper constructs bounds for chemical-master-equation models. Adapting that construction to queue generators requires new queue-specific conditions, not simply relabeling their examples. [Truncation review, 2019/revised 2020](https://arxiv.org/abs/1909.05794), [*Rigorous bounds on the stationary distributions of the chemical master equation via mathematical programming*, 2019](https://arxiv.org/abs/1702.05468).

**Why this helps.** It can supply an independent discrete-queue reference for non-product-form infinite-buffer models that are too large for naive enumeration but small enough for selective state-space exploration.

**Accuracy contract.** A queue-specific drift proof must be valid on the entire omitted region. Small boundary probability is not itself a certificate. For mean queue length, an unbounded reward, controlling omitted probability alone is insufficient; one needs a weighted tail/moment bound. Arbitrary state-space augmentation is not automatically convergent. [*On Convergence of General Truncation-Augmentation Schemes*, 2022](https://arxiv.org/abs/2203.15167).

**First acceptance tests.** Known geometric tails, upper/lower bounds that contain exact means, tightening under refinement, and explicit refusal to certify when no valid drift bound is available. Begin with a narrow provable family, then extend it.

### 5. Exact small-cluster decomposition for blocked networks

**What to add.** Solve two- or three-node subnetworks exactly, then exchange estimated incoming traffic and blocking information between clusters. Group bottlenecks and strong feedback edges instead of treating all stations independently. Blocking decomposition has practical precedents: Koizumi, Kuno and Smith apply single-node decomposition and compare mathematical and simulation results in a patient-flow network. The exact-cluster extension proposed here is my suggested next step for Qnet, not their specific algorithm. [*Modeling Patient Flows Using a Queuing Network with Blocking*, 2005; manuscript archived 2015](https://pmc.ncbi.nlm.nih.gov/articles/PMC4465555/).

**Accuracy contract.** Exact component solutions do not make the assembled network approximation exact. Cross-cluster correlations and fixed-point convergence are central uncertainties. Preserve flow conservation, disclose the closure equations, and validate against the exact BAS solver and DES. My proposed cluster-selection/refinement design appears below.

### 6. Tensor-train stationary solvers for large structured CTMCs

**What to add.** Represent the generator as sums of local Kronecker products and the stationary vector in tensor-train form. Use rank-adaptive iteration or alternating minimization, with an optional multigrid/coarse-grid correction. Communicating Markov processes—including queueing-network structures—are a direct application of this literature. [Kressner and Macedo, *Low-rank tensor methods for communicating Markov processes*, 2014](https://www.epfl.ch/labs/mathicse/wp-content/uploads/2018/10/17.2014_DK-FM.pdf), [Bolten et al., multigrid with low-rank approximation, 2016](https://arxiv.org/abs/1605.06246).

**Why this helps.** A finite-buffer network may have a huge Cartesian state space but relatively simple local transitions. This is not the same as Qnet's low-rank approximation to an SRBM density.

**Accuracy contract.** Compression can fail for strong dependence, complex routing, or ordered multiclass FCFS states. Monitor rank, normalization, nonnegativity, and generator residual. Residual alone is not a stationary-error bound. Infinite queues still require truncation and a separate tail assessment.

**First acceptance tests.** Product-form chains (rank-one target), small finite networks against sparse CTMC, then bottleneck chains with increasing coupling. Set rank/memory caps and return partial results instead of silently flattening dependence.

### 7. Network-level rare-event importance sampling and splitting

**What to add.** State-dependent importance sampling for queue overflow, and adaptive multilevel splitting for difficult hitting events. Dynamic changes of measure are important: a fixed exponential tilt can perform badly even on simple networks. [Dupuis, Sezer and Wang, *Dynamic Importance Sampling for Queueing Networks*, 2007](https://arxiv.org/abs/0710.4389). Adaptive splitting offers another route to rare-event estimation. [Cérou and Guyader, 2007](https://perso.lpsm.paris/~aguyader/files/papers/cg2.pdf).

**Why this helps.** Ordinary simulation becomes inefficient for tiny blocking/overflow probabilities, while those probabilities can drive capacity decisions.

**Accuracy contract.** A probability of hitting a high level before an empty state is not the steady-state fraction of time above that level. For stationary metrics, use a validated regenerative reward/cycle-length construction or another suitable stationary estimator. Include likelihood weights, branching dependence, denominator uncertainty, and effective sample diagnostics. Zero observed rare events is not evidence of zero probability.

**First acceptance tests.** M/M/1/K exact loss; two-node tandem overflow; feedback models; repeated-run coverage; and comparison with ordinary simulation at probabilities large enough to estimate both ways.

### 8. Perfect stationary sampling

**What to add.** A restricted perfect-sampling backend for generalized Jackson networks, initially a small single-class FIFO family. Blanchet and Chen give a perfect sampler for arbitrary topology under their stability and input assumptions, including finite moment-generating functions near zero and unbounded interarrival support. [*Perfect Sampling of Generalized Jackson Networks*, 2019](https://pubsonline.informs.org/doi/10.1287/moor.2018.0941).

**Why this helps.** It addresses stationary initialization/warm-up rather than only running the existing simulator longer. Related perfect-sampling work treats infinite-server and loss systems. [Blanchet and Dong, 2013 preprint](https://arxiv.org/abs/1312.4088).

**Accuracy contract.** An exact stationary draw does not eliminate Monte Carlo error when estimating a mean from finitely many draws. Assumptions must be checked; coupling time and heavy-traffic cost may be substantial. Do not advertise a universal perfect sampler for arbitrary multiclass blocking networks.

### 9. Mean-value analysis for closed product-form networks

**What to add.** Population-recursive MVA, followed by appropriate approximate MVA or scalable normalizer methods for large class populations. The original MVA computes means, residence times, and throughputs without explicitly evaluating all product-form probabilities. [Reiser and Lavenberg, 1980](https://research.ibm.com/publications/mean-value-analysis-of-closed-multichain-queuing-networks).

**Why this helps.** Qnet already has product-form models, but closed-state enumeration and limited GUI population entry constrain usefulness. This is a scalability and model-entry extension, not a new general solution for blocked networks. For especially large closed multiclass cases, evaluate the multi-branched method of moments as a second exact approach. [*The Multi-Branched Method of Moments for Queueing Networks*, 2009](https://arxiv.org/abs/0902.3065).

**Accuracy contract.** Exact only under the relevant product-form assumptions. Approximate MVA must have a different label. Class-dependent FCFS service, blocking, or arbitrary priorities cannot be admitted simply by reusing the recursion.

### 10. Neural BAR/Laplace-transform solver for SRBM—experimental

A July 2026 preprint proposes learning the Laplace transform of stationary reflected Brownian motion through the basic adjoint relationship (BAR), with experiments on models having known reference tail probabilities. [Dai and Zhang, *Deep Learning Method for Stationary Distribution of Reflected Brownian Motion*, submitted 9 July 2026](https://arxiv.org/abs/2607.08091).

**What to add.** An optional benchmark prototype using exactly the same drift, covariance, and reflection data as Qnet's other SRBM solvers. Compare moments and tails on held-out parameter sets, multiple random seeds, and independent SRBM simulation—not only on training residual.

**Accuracy contract.** This is a recent preprint, not a general certified queue solver. A small BAR loss does not certify the learned stationary law or its far tails, and even an exact SRBM answer has queue-to-diffusion model error. A new machine-learning runtime is a significant packaging cost. I would keep this outside the default app until the benefit is demonstrated.

## 3. Qnet-specific approaches I would prototype

These are proposed combinations of established ideas. I have not established novelty, proved them for all Qnet models, or measured their performance.

### A. Use existing approximations to reduce error in exact-queue simulation

For an ergodic CTMC with generator Q and a suitable integrable function h, stationarity gives Eπ[Qh]=0. Thus a stationary time average of `f(X(t)) + Qh(X(t))` has the same target mean as f. The ideal Poisson equation is `Qh = π(f) − f`.

My design is to fit h using station-wise QNA/diffusion-inspired functions, plus interactions on the most congested routes. Use a separate pilot trajectory for coefficient fitting; freeze the coefficients for the reporting run. Evaluate Qh with the **actual queue generator**, not the Brownian generator. Record the ordinary and controlled estimates together and compare variance per second. This is a Qnet-specific application of the martingale-control literature cited above, not a claim of a new general theorem.

For non-exponential service/arrival models, queue lengths alone are not Markov: include residual times and use the appropriate piecewise-deterministic generator, or stay within the Markovian subset. For controls applied directly to SRBM, enforce the reflecting-boundary domain conditions or include boundary local-time terms. Do not assume the zero-mean identity for an arbitrary smooth function while ignoring reflection. Starting from empty still requires initialization analysis; the stationary identity does not prove finite-time unbiasedness.

### B. Adaptive exact bottleneck clusters with a simulation check

Choose two-node clusters on routes with high utilization, high blocking, or strong feedback. Solve their joint finite-state BAS models. Exchange boundary traffic using a damped fixed point with explicit flow conservation. Compare single-node versus pair predictions; enlarge clusters where the difference is greatest. Use short independent simulations to test whether cluster enlargement actually improves the requested metrics.

This differs from one-station decomposition by retaining selected dependence and blocked-server configurations. It remains an approximation whenever a cluster boundary discards dependence. Return the chosen clusters, flow imbalance, iteration history, and simulation discrepancy. A failed fixed point should be reported as such, not converted into a plausible-looking equilibrium table.

### C. Exact boundary region joined to a matrix-geometric tail

For a network with **one unbounded queue and otherwise finitely many phases/states**, enumerate the irregular low-population region exactly and join it to a genuinely level-independent QBD tail. This can avoid wasting a large truncation on a long but structured queue. The tail must satisfy the same stationary boundary equations and normalization as the interior.

For several unbounded queues, treating their joint configuration as a fixed finite phase is generally invalid. A fitted “effective QBD tail” would be heuristic and require separate error checks. I would implement the exact one-unbounded-coordinate case first; it is a practical generalization of the current scalar GUI adapter.

### D. Refine a finite-domain SRBM solution for the metric the user asks for

For reflected diffusion on a box, stationary BAR includes both lower- and upper-face boundary measures. Its schematic form is `∫ Lf dπ + Σfaces ∫ r_face · ∇f dν_face = 0`, with reflection directions defined consistently for each face. An orthant formula with only lower faces is not made into a finite-buffer model merely by imposing a numerical cap.

My proposed extension is a true rectangle BAR formulation, followed by an adjoint-weighted residual that concentrates mesh/basis refinement where it matters for a requested mean or tail probability. Validate first in one dimension against the normalized stationary density proportional to `exp(2θx/σ²)` on `[0,K]` (uniform if θ=0), then in independent product cases and correlated two-dimensional cases. Treat the adaptive residual as an error indicator until a theorem and verifiable constants justify a bound. This proposal concerns the diffusion model; selecting reflection directions that faithfully approximate queue blocking is a separate modeling task.

## 4. Implementation order and release gates

| Stage | Deliverable | Must demonstrate before release |
|---|---|---|
| A | PH/MAP input schema and single-station adapters; exact two-node BAS CTMC | Known analytic means/tails, hand-enumerated blocking states, unsupported-model rejection |
| B | Controlled simulation; exact boundary/QBD-tail model | Repeated-run interval coverage and wall-time gain; valid generator and tail residuals |
| C | Queue-specific truncation certificates; adaptive BAS clusters | Bounds contain known answers; cluster refinement improves held-out tests |
| D | Closed-network MVA; tensor CTMC backend | Agreement with existing small exact solvers and documented scale limits |
| E | Network rare-event and perfect-sampling modes | Correct stationary target, estimator validation, explicit assumptions and cost limits |
| Research | Rectangle/goal-oriented BAR and neural BAR comparison | Independent numerical references, queue-versus-diffusion error separation |

The priority changes with the workload: move MVA earlier if closed networks dominate, or rare-event simulation earlier if loss probabilities below ordinary-simulation resolution are the main deliverable. Avoid promising a universal exact method for every distribution, multiclass discipline, feedback pattern, and blocking policy.

All new results should identify (1) the actual stochastic model solved, (2) exactness versus approximation, (3) numerical tolerance or certificate, (4) statistical uncertainty, and (5) any model reduction/fitting error. Preserve the current input, solver version, seed, and method settings so an attractive result can be reproduced. This is the most useful common framework for comparing the proposed algorithms with Qnet's existing methods.
