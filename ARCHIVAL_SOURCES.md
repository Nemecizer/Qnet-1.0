# Archival compatibility sources

All maintained Qnet algorithms and their build inputs are complete in this
package. Two legacy compatibility experiments remain for historical reference:

- `infinite/BNAsim/gjn.c`
- `infinite/BNAsim/mcn.c`

Those files predate the maintained `jackson_sim.c` and
`jackson_sim_finite.c` engines. They refer to Meschach-era headers that were not
present in either the supplied repository or its original application bundle,
and they are intentionally not Makefile targets. The maintained simulation
engines contain their complete sources and are built by
`build_all_algorithms.sh` and `build_app.sh`.
