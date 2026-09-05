# Qnet 0.90.34

This is the prepared `2_QNET` distribution: maintained algorithm sources,
Swift GUI, vendored SwiftTerm library, examples, tests, build scripts, and a
ready-built Apple-silicon `Qnet.app` with its native runtime libraries.

From this directory, with a compatible Swift/macOS SDK installation:

```sh
swift run
```

Rebuild the application bundle without changing version 0.90.34:

```sh
./build_app.sh
```

Keep the included `Qnet.app` beside `Package.swift`: the source-launched GUI
finds its packaged solvers automatically. No paths to the original Qnet folder
are required. Python and optional Python modules are external prerequisites.

Read [BUILDING.md](BUILDING.md) for dependency commands and the SDK workaround
needed on the tested Mac; [VERIFICATION.md](VERIFICATION.md) states precisely
what was and was not tested. [ARCHIVAL_SOURCES.md](ARCHIVAL_SOURCES.md) identifies
two retained historical experiments that are not maintained build targets.

The [algorithm survey](docs/ALGORITHM_RESEARCH_2026-09-04.md) recommends further
methods, cites the literature, and describes Qnet-specific prototype ideas.
These proposed methods have not been added to the numerical implementation.

## Dropbox status

The installed destination is
`/Users/nemecj/Library/CloudStorage/Dropbox/0_CODE/0_CLAUDE/2_QNET`.
Write access was approved and this distribution was copied there on
4 September 2026. File checksums, the app signature, the solver bundle audit,
and all 35 packaged RQNA examples passed in the Dropbox directory.
The existing Dropbox `Qnet` folder was not changed. This local output copy
is also retained as the distribution source.

## License

Qnet's own source — the Swift GUI, the solvers under `finite/` and `infinite/`,
the GUIKit framework, the validation suite and the build scripts — is released
under the MIT License. See [LICENSE](LICENSE).

Third-party components keep their own terms. `Vendor/SwiftTerm` is MIT. A built
`Qnet.app` also redistributes the native libraries its solvers link against —
libomp, HiGHS, cJSON, SuiteSparse and the GCC 13 runtime libraries — each under
its own license, with the texts retained in `ThirdPartyLicenses/`. The GCC
runtime libraries carry the GCC Runtime Library Exception, which is what allows
them to ship inside an MIT-licensed application. `LICENSE` sets this out in full.

The published papers under `Papers/` are third-party copyrighted works, excluded
from the repository and not redistributed; `Papers/Qnet_Bibliography.ris` cites
them so they can be obtained from their publishers.
