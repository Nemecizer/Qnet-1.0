# Qnet 0.90.34 distribution verification

Date: 4 September 2026. Host: Apple silicon, macOS 26.6.2.

Source provenance: the latest available working implementation from this task
was used, not the older Dropbox app. A checksum comparison of Swift/C/header/
Fortran/Python/Makefile sources against that implementation found only the
intended package-manifest, version-comment, and `--version` CLI differences.
The vendored SwiftTerm resource-lookup adjustment and release scripts are
packaging changes; existing algorithm mathematics was preserved.

## Passed

- Maintained finite/infinite native algorithms built from the supplied sources,
  including RQNA and the optional multiclass diffusion solver. Python syntax
  validation covered all 32 algorithm/test Python source files.
- Swift debug build and source-run CLI: `--version` returned `Qnet 0.90.34`;
  RQNA help executed successfully.
- A source-run GUI process remained running for eight seconds and was then
  stopped by the test. The managed environment emitted macOS service-access
  warnings; this is a process-start smoke check, not a full interactive UI test.
- Release compilation and app assembly completed. Both Info.plist and the app
  executable report version `0.90.34`; rebuilding preserves that version.
- `codesign --verify --deep --strict Qnet.app` passed (local ad-hoc signature).
- Independent bundle audit passed: **33 available items, zero declared
  unavailable**. These are 13 native executables and 20 support files—not 33
  different numerical methods. Python itself and optional imports are checked
  separately at application startup.
- The production runtime resolver selected all 12 required native executables
  from the adjacent `Qnet.app`, with no `QNET_SOLVER_ROOT` override. The optional
  thirteenth native executable is included and load-checked by the bundle audit.
- SwiftTerm shader resources are discoverable using Foundation bundles in both
  the debug layout and `Qnet.app/Contents/Resources`. Actual Metal rendering
  was not interactively inspected.
- Packaged RQNA self-tests passed. All **35** example documents whose saved
  `infiniteBuffers` property is true passed through the production app's
  comparison exporter and then the bundled RQNA executable. This verifies
  export, invocation, and usable population output, not mathematical accuracy
  for every modeled network.
- `validation/steady_state_suite.sh` passed: 135 Python unit tests, multiclass
  primitive tests, MLMC safety checks, RQNA integration, exporter contracts,
  result parsing, runtime resolution, startup checklist, bundle-audit tests,
  and GUI runtime contracts.
- `verify_source_package.sh` passed the source-run, app-build, signature,
  bundle, RQNA self-test/exporter, and resource-resolution checks. The additional
  all-example RQNA check was also run separately after being added to that script.
- A copy relocated under `/tmp` in a folder containing spaces passed app version,
  strict signature, all 33 bundle-inventory checks, and all 35 RQNA examples.
  No build cache or loose native executable was copied into that test directory.
- The final delivery tree was rebuilt from an empty Swift build directory,
  with all loose native binaries and object files omitted. The cold source build
  completed in about 51 seconds, printed `Qnet 0.90.34`, and passed the production
  runtime/shader discovery check against the included app. Successful source
  tests used the SDK and managed-runner options described below.

## Important host limitation: unconfigured `swift run` did not pass

The installed compiler is Swift **6.3.3**. The default macOS **26.5** SDK reports
Swift **6.3.2**, and an unconfigured invocation fails with the compiler/SDK
compatibility diagnostic. Successful builds used the installed
`/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk` and project-local module
caches. This is a system-toolchain issue, not a missing Qnet algorithm source.

The managed test runner also rejects SwiftPM's nested sandbox. Tests therefore
used `--disable-sandbox` **inside the existing managed environment**. This is
opt-in through `QNET_SWIFT_DISABLE_SANDBOX=1`; it is not enabled by default in the
distributed scripts and normally is unnecessary in a regular Terminal session.

Equivalent commands used for source checks:

```sh
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift run --disable-sandbox Qnet --version
swift run --disable-sandbox Qnet --dump-help rqna
swift run --disable-sandbox
```

The convenience `run_qnet.sh` and the build/verification scripts select local
caches and try the retained compatible SDK automatically. Update or select a
matching compiler/SDK before relying on bare `swift run` in a fresh shell.
No system toolchain, shell profile, or global package installation was changed.

## Distribution and platform boundaries

The binary is arm64. Its bundled libraries require macOS **26.0 or newer**;
the app's minimum-system metadata is calculated from its bundled Mach-O files.
Neither Intel support nor older-macOS compatibility was established. All Qnet
project source and the SwiftTerm source dependency are included, but Apple
compilers/SDKs, Python, and Homebrew development packages are not vendored.
BUILDING.md lists the packages needed for a rebuild. This is a self-contained
project/runtime directory, not a complete development-toolchain image.

The two archival Meschach-era experiments are retained but are not supported
build targets; their original missing headers were not reconstructed. All
maintained GUI algorithm build inputs are supplied.

The app is not Developer-ID signed or notarized. Its signature verification
does not certify GUI usability or mathematical accuracy. No new survey method
was implemented, and existing solver mathematics was not revised in this task.
