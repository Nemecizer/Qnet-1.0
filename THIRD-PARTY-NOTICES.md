# Third-party notices

Qnet's own source is MIT-licensed; see [LICENSE](LICENSE). That license does not
relicense the third-party components distributed alongside it, which keep their
own terms. This file records them.

The MIT license covers Qnet's own source: the Swift GUI under Sources/, the
solver implementations under finite/ and infinite/, the GUIKit framework, the
validation suite, the build scripts, and the documentation.

It does NOT relicense third-party components distributed alongside it. Those
keep their own terms:

  * Vendor/SwiftTerm — MIT, © Miguel de Icaza, the xterm.js authors and
    SourceLair; see Vendor/SwiftTerm/LICENSE.

  * A built Qnet.app additionally redistributes the native libraries its
    solvers link against, each under its own license, with the texts retained
    in ThirdPartyLicenses/:
      libomp (Apache-2.0 with LLVM exception), HiGHS (MIT), cJSON (MIT),
      SuiteSparse (a mix, chiefly LGPL-2.1+ and Apache-2.0 by component),
      and the GCC 13 runtime libraries libgcc_s, libgfortran, libquadmath
      and libgomp.

    The GCC runtime libraries are GPL-3.0-or-later **with the GCC Runtime
    Library Exception** (ThirdPartyLicenses/gcc13/COPYING.RUNTIME). That
    exception is what permits them to be linked into and distributed with a
    program under this license; it does not make Qnet a GPL work. If you
    rebuild against different library versions, refresh the notices in
    ThirdPartyLicenses/ before redistributing the result.

  * The published papers under Papers/ are third-party copyrighted works. They
    are excluded from this repository by .gitignore and are not redistributed;
    Papers/Qnet_Bibliography.ris and Papers/Paper_Index.md cite them so they
    can be obtained from their publishers.
