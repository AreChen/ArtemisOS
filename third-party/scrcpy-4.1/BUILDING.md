# Display source/build record for ArtemisOS 1.0.6

The official scrcpy-win64-v4.1.zip has SHA-256
`5b12172b3264b2889f4583ee64752ce832e29bc8b1089dca81093459697165db`.
All ten runtime/artwork files copied from WinGet match the corresponding
entries in this independently downloaded official ZIP. GitHub asset metadata,
original checksums and detached signature are retained in `evidence/`.
The OpenPGP signature was not independently verified; no such claim is made.

Actual release build: https://github.com/Genymobile/scrcpy/actions/runs/29188298263
at commit `fa57d7c6b47139797a8e103f87719740718887d4`. The final v4.1 tag is
`2926c06c5dc3064ae6d8db706f1a98a37cfcf3f0`. Both complete sources are offered.
`evidence/build-to-tag-comparison.json` shows only a documentation/release-link
commit between them: the client, server, dependency recipes and workflow are
unchanged. No ArtemisOS patches are applied to these sources or binaries.

## Build path

1. Extract `source-archives/scrcpy-build-fa57d7c6.tar.gz`. It includes full app
   and server code, Meson/cross files, `app/deps/_init`, all dependency recipes,
   `.github/workflows/release.yml` and `release/build_windows.sh`.
2. Use a Linux cross-build host with the workflow's dependencies: Meson, Ninja,
   NASM, mingw-w64, mingw-w64-tools, libz-mingw-w64-dev, plus CMake/autotools/
   pkg-config required by the recipes. The actual DLLs report GCC 13-win32.
3. Put the supplied FFmpeg/libusb/dav1d source tarballs into
   `app/deps/work/sources/`. Put `SDL-release-3.4.12.tar.gz` there under the
   recipe's expected basename `sdl-3.4.12.tar.gz`. All four archive checksums
   match the complete unmodified upstream dependency recipes.
4. From the scrcpy root run:

   ```sh
   app/deps/sdl.sh win64 cross shared
   app/deps/dav1d.sh win64 cross shared
   app/deps/ffmpeg.sh win64 cross shared
   app/deps/libusb.sh win64 cross shared
   ```

   dav1d always builds statically despite the final argument. FFmpeg embeds
   dav1d/zlib; scrcpy links FFmpeg/SDL/libusb dynamically. Exact actual FFmpeg
   options are in `evidence/observed-ffmpeg-build.txt`. The original build used
   the runner's libz-mingw-w64-dev, with zlib 1.3.1 identified in the DLLs;
   upstream zlib 1.3.1 source is also supplied.
5. Follow the original `release/build_windows.sh` Meson commands and
   `cross_win64.txt`; set `VERSION=v4.1` because an archive has no git tags.
   The recipe uses release mode, LTO, stripping, compile_server=false and
   portable=true. The all-in-one script also downloads an ADB package; that
   ADB is not redistributed by this frontend, which uses ArtemisOS SDK ADB.
   `release/build_server.sh` and its workflow describe the separate Java 17/
   Android server build. Building the LGPL libraries needs no Android SDK/AOSP.

The actual official DLLs are unmodified; original recipes contain no patches
to the LGPL projects. Full archives include headers, source, build definitions
and original per-file notices. This review did not rebuild the libraries.
The precise Ubuntu package revisions for MinGW/zlib and the complete original
runner image are unavailable from release assets; byte-identical reproduction
is not asserted. MinGW runtime notice texts are retained from upstream v12.0.0,
and GCC 13 exception texts from GCC 13.3.0; they cover the observed toolchain
family without asserting its exact distro package revision. Compilers/system
toolchain packages are distinct from the complete LGPL library source delivery.

## Distribution

Keep compatible shared DLLs replaceable and offer the source ZIP from the same
public download place as installers/OTA, with equivalent access. This is the
LGPL 2.1 section 4 and 6(d) route, not a three-year written source offer.
It is satisfied only after the source ZIP is actually publicly downloadable
without extra restrictions. Record that upload/readback check in the release
evidence; do not treat prepared local files or upstream URLs as publication.
