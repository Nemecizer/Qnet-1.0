# fBNAlp — finite-buffer LP solver for SRBM

LP-based steady-state solver for a semimartingale reflecting Brownian
motion (SRBM) on the bounded rectangle `[0, b₁] × … × [0, b_d]`. The
finite-buffer counterpart of `Qnet/infinite/BNAlp/srbm_lp` (Saure /
Glynn / Zeevi orthant LP).

## Status

Phase 1 scaffold. The current binary is the orthant LP code copied from
`OLD/BNA/BNAlp` and renamed to `fBNAlp_solver`. The math extension to
the rectangle case (2d boundary measures, upper-face reflection, longer
tightness vector, uniform tensor grid) lands in subsequent phases —
see `/Users/nemecj/.claude/plans/misty-shimmying-pike.md` for the full
plan.

## Build

```
make                      # default: HiGHS backend
make SOLVERS="highs glpk" # add GLPK
make SOLVERS="highs cplex" # add CPLEX (developer machines only)
make clean
```

Default backend is HiGHS because it's open source and bundled into
`Qnet.app`. CPLEX is non-redistributable, so `build_app.sh` always
invokes the HiGHS-only build.

## Run

```
./fBNAlp_solver --input examples/2d.in --solver highs
./fBNAlp_solver --list-solvers
./fBNAlp_solver --help
```
