# Qnet 0.90.34 — running and rebuilding

This directory is a standalone Qnet source package. It contains the Swift GUI,
the complete finite- and infinite-capacity algorithm sources, their examples and
tests, release validation, the application icon, and the exact SwiftTerm source
used by the GUI. SwiftPM does not need the network to resolve SwiftTerm.
The distribution also includes a freshly built `Qnet.app`, containing the native
solver executables and their relocated shared libraries. Keep it beside
`Package.swift`: a source-launched GUI can use these packaged solvers immediately.

## Requirements

- Apple-silicon Mac. This package was verified on macOS 26; build on the target
  Mac because Homebrew library deployment targets follow the build host.
- Xcode Command Line Tools with Swift 6.2 or later.
- Python 3 and `make`.
- Homebrew development libraries used by the native solvers:

  These libraries are needed to **rebuild** the native solvers; their runtime
  copies are already inside the supplied application.

  ```sh
  brew install python libomp suite-sparse highs gcc@13
  ```

- Optional experimental multiclass diffusion solver:

  ```sh
  brew install cjson
  ```

NumPy is optional and only enables the dense finite tandem CTMC. CVXPY and an
SDP backend are optional and only enable general numerical BAR bounds. The app's
startup checklist reports these separately.

## Run from source

From this directory:

```sh
swift run
```

This compiles and launches the Swift GUI, using the adjacent `Qnet.app` for
native solvers. No separate native build is needed for this supplied distribution.
If you remove the app or edit native algorithms, rebuild their executables with
`./build_all_algorithms.sh`; rebuild the app as well to replace its packaged
copies, which take precedence over loose executables. `swift run Qnet --version`
prints `Qnet 0.90.34` without opening the GUI.

The compiler, macOS SDK, Python interpreter, and Homebrew development packages
are system prerequisites, not supplied source dependencies. The bundled app's
native solvers do not need Homebrew at runtime; Python-backed methods still need
Python, with NumPy/CVXPY only for the methods that require them. This is not a
compiler/SDK or a universal Intel-and-Apple-silicon distribution.

If an interrupted Command Line Tools update reports that the default SDK and
Swift compiler do not match, update Command Line Tools. As a temporary local
workaround, select another installed compatible SDK before invoking Swift:

```sh
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
swift run
```

The provided `./run_qnet.sh` selects a working installed SDK and project-local
compiler caches automatically. The normal `swift run` command cannot repair an
incompatible system compiler/SDK. See `VERIFICATION.md` for the exact test
conditions and the managed-environment limitation encountered on this Mac.

## Build the application bundle

```sh
./build_app.sh
```

The script rebuilds all required native algorithms and the release Swift GUI,
then creates, relocates, ad-hoc signs, and audits `Qnet.app` in this directory.
It preserves version **0.90.34**; rebuilding does not increment the patch number.
It also packages the vendored SwiftTerm Metal shader needed by the terminal view.
The experimental multiclass diffusion solver is recorded as unavailable if its
optional cJSON dependency is absent; that does not invalidate the other solvers.

To run the complete automated source-and-bundle check:

```sh
./verify_source_package.sh
```

The first application launch may require Control-clicking `Qnet.app`, choosing
**Open**, and confirming once because the local build is ad-hoc signed rather
than Developer-ID signed and notarized.
