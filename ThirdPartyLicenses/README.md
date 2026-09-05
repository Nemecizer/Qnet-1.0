# Third-party components in this build

The supplied binary was built against these installed development packages:

- LLVM libomp 23.1.0
- SuiteSparse 7.14.0
- HiGHS 1.15.1
- GCC runtime libraries from GCC 13.4.0
- cJSON 1.7.19
- SwiftTerm 1.13.0, exact revision recorded in `Vendor/SwiftTerm/VENDORED-REVISION.md`

License texts supplied with the installed packages are retained in the adjacent
directories. The complete SuiteSparse license collection covers components
beyond the subset of libraries actually used by Qnet. SwiftTerm source and its
license are also included in Vendor. System SDK/frameworks and the sources of
Homebrew development packages are not vendored here; install development
prerequisites as described in BUILDING.md to rebuild the native algorithms.

For a rebuild using other library versions, refresh these notices from those
versions before distributing the resulting app.
