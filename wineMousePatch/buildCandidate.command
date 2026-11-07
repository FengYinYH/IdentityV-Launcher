#!/bin/zsh
# Candidate only. Never install, run Wine, or change a default binding.
set -euo pipefail
archive="${1:?usage: buildCandidate.command SOURCE_ARCHIVE NEW_BUILD_ROOT [state-only|session|paired|paired-gated]}"
work="${2:?usage: buildCandidate.command SOURCE_ARCHIVE NEW_BUILD_ROOT [state-only|session|paired|paired-gated]}"
patch_dir="${0:A:h}"
mode="${3:-state-only}"
case "$mode" in state-only|session|paired|paired-gated) ;; *) exit 64 ;; esac
[[ "$archive" == /* && -f "$archive" && ! -L "$archive" && "$work" == /* && ! -e "$work" ]] || exit 64
[[ "$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')" == e4ec87d5821a009dd1f1d2e36ffe2e24b8fcbae9516375ea42f95a16928ab8fa ]] || exit 65
paired=0
if [[ "$mode" == paired* ]]; then
    paired=1
    ft_root="${IDENTITYV_FREETYPE_ROOT:?paired build requires an existing x86_64 FreeType toolchain}"
    base_runtime="${IDENTITYV_BASE_RUNTIME:?paired build requires an explicit baseline runtime for ABI/backend audit}"
    [[ "$ft_root" == /* && -f "$ft_root/include/freetype2/ft2build.h" && -f "$ft_root/lib/libfreetype.dylib" && "$base_runtime" == /* && -d "$base_runtime" ]] || exit 64
fi
/bin/mkdir "$work"
/bin/mkdir "$work/source" "$work/build"
/usr/bin/tar -xzf "$archive" -C "$work/source" --strip-components=2 sources/wine
typeset -a patch_files=("$patch_dir/eefbbc07-ClipCursor-reset.patch" "$patch_dir/confinement-state-validation.patch")
if [[ "$mode" != state-only ]]; then
    patch_files+=("$patch_dir/confinement-session-diagnostics.patch" "$patch_dir/confinement-session-entry-diagnostics.patch")
fi
if (( paired )); then patch_files+=("$patch_dir/upper-clip-session-diagnostics.patch"); fi
if [[ "$mode" == paired-gated ]]; then patch_files+=("$patch_dir/foreground-warp-eligibility.patch"); fi
for patch_file in "${patch_files[@]}"; do
    /usr/bin/patch --dry-run -d "$work/source" -p1 < "$patch_file"
    /usr/bin/patch -d "$work/source" -p1 < "$patch_file"
done
if (( paired )); then /bin/ln -s "$ft_root" "$work/freetype"; fi
(
    cd "$work/build"
    export CC="clang -arch x86_64"
    export CXX="clang++ -arch x86_64"
    export MACOSX_DEPLOYMENT_TARGET=14.0
    export LDFLAGS='-mmacosx-version-min=14.0'
    export CFLAGS='-mmacosx-version-min=14.0 -DSONAME_LIBVULKAN=\"libMoltenVK.dylib\" -include sys/sysctl.h'
    [[ "$mode" == state-only ]] || export CFLAGS="$CFLAGS -DIDENTITYV_CAPTURE_DIAGNOSTIC_BUILD=1"
    typeset -a font_flags=(--without-freetype)
    if (( paired )); then
        export CFLAGS="-g -O2 $CFLAGS"
        export FREETYPE_CFLAGS="-I$work/freetype/include/freetype2"
        export FREETYPE_LIBS="-L$work/freetype/lib -lfreetype"
        font_flags=(--with-freetype --without-fontconfig)
    fi
    "$work/source/configure" --build=x86_64-apple-darwin --host=x86_64-apple-darwin --enable-archs=none --without-mingw --disable-tests --without-x --without-gstreamer --without-vulkan "${font_flags[@]}" > "$work/configure.log" 2>&1
    /usr/bin/make -j4 dlls/winemac.drv/winemac.so > "$work/build.log" 2>&1
)
if (( paired )); then
    /bin/mkdir "$work/session-modules"
    /bin/cp "$work/build/dlls/winemac.drv/winemac.so" "$work/build/dlls/win32u/win32u.so" "$work/session-modules/"
    python3 "$patch_dir/auditPairedModules.py" "$work/session-modules" "$base_runtime" > "$work/paired-audit.json"
    print -- "Paired candidate only ($mode): $work/session-modules"
else
    /usr/bin/shasum -a 256 "$work/build/dlls/winemac.drv/winemac.so"
    print -- "Candidate only ($mode): $work/build/dlls/winemac.drv/winemac.so"
    print -- "Do not distribute the incidental win32u from this non-paired build; FreeType was disabled."
fi
