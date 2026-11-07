#!/bin/zsh
# Build only winemac.so in a caller-owned, new directory. Does not install/run Wine.
set -euo pipefail
archive="${1:?usage: buildCandidate.command SOURCE_ARCHIVE NEW_BUILD_ROOT}"
work="${2:?usage: buildCandidate.command SOURCE_ARCHIVE NEW_BUILD_ROOT}"
patch_dir="${0:A:h}"
[[ "$archive" == /* && -f "$archive" && ! -L "$archive" && "$work" == /* && ! -e "$work" ]] || exit 64
[[ "$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')" == e4ec87d5821a009dd1f1d2e36ffe2e24b8fcbae9516375ea42f95a16928ab8fa ]] || exit 65
/bin/mkdir "$work"
/bin/mkdir "$work/source" "$work/build"
/usr/bin/tar -xzf "$archive" -C "$work/source" --strip-components=2 sources/wine
for patch_file in "$patch_dir/eefbbc07-ClipCursor-reset.patch" "$patch_dir/confinement-state-validation.patch" "$patch_dir/confinement-session-diagnostics.patch"; do
    /usr/bin/patch --dry-run -d "$work/source" -p1 < "$patch_file"
    /usr/bin/patch -d "$work/source" -p1 < "$patch_file"
done
(
    cd "$work/build"
    export CC="clang -arch x86_64"
    export CXX="clang++ -arch x86_64"
    export MACOSX_DEPLOYMENT_TARGET=14.0
    export LDFLAGS='-mmacosx-version-min=14.0'
    export CFLAGS='-mmacosx-version-min=14.0 -DSONAME_LIBVULKAN=\"libMoltenVK.dylib\" -include sys/sysctl.h'
    "$work/source/configure" --build=x86_64-apple-darwin --host=x86_64-apple-darwin --enable-archs=none --without-mingw --disable-tests --without-x --without-gstreamer --without-vulkan --without-freetype > "$work/configure.log" 2>&1
    /usr/bin/make -j4 dlls/winemac.drv/winemac.so > "$work/build.log" 2>&1
)
/usr/bin/shasum -a 256 "$work/build/dlls/winemac.drv/winemac.so"
print -- "Candidate only: $work/build/dlls/winemac.drv/winemac.so"
