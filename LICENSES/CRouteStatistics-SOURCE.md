# Route statistics component source

The App includes the complete C route statistics component in
`Contents/Resources/Licenses/Source/`:

- `NetworkStatisticsABI.h`: adapted Apple XNU interface declarations, under
  APSL 2.0. Original notices, source commit, modification date and description
  are in the header. The license is `../LICENSES/APSL-2.0.txt`.
- `RouteStatistics.c` and `include/CRouteStatistics.h`: RouteWeaver's original
  implementation and public interface, under the MIT license in `../LICENSE`.

These files are source code, not generated binaries. No XNU implementation
functions or separate source download are required to compile this component.
The ABI header is included by `RouteStatistics.c` and has no standalone
executable. With Apple's macOS SDK and Command Line Tools installed, open a
terminal in a writable copy of this `Source` directory and run:

```sh
xcrun clang -std=gnu11 -Wall -Wextra -I include \
  -c RouteStatistics.c -o RouteStatistics.o
```

This compiles an object file without executing it or modifying system routing.
RouteWeaver's Swift package links the C target `CRouteStatistics`; the complete
application also needs its other Swift sources. The packaged `Package.swift`
and `build_and_run.sh` document the application's build integration and are
included for reference. They are MIT-licensed; they are not a standalone App
source bundle and should not be run from this directory.

Recipients have the adapted header source directly in this package under
APSL 2.0, including its notices and modifications. No claim is made that a
particular repository or release download is publicly available. Future
distributors must retain the applicable notices, license and corresponding
source availability required by APSL 2.0.
