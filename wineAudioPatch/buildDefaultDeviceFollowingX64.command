#!/bin/zsh
# Build an isolated CodeWeavers 26.1 x86_64 default-device-following module.
# Requires an explicitly supplied external build root on the verified S690 volume.
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
archive="${CROSSOVER_SOURCE_ARCHIVE:-}"
llvm_root="${LLVM_MINGW_ROOT:-}"
bison_bin="${BISON:-}"
baseline_module="${ACTIVE_AUDIO_MODULE:-}"
build_root="${IDV_WINE_AUDIO_BUILD_ROOT:-}"
volume_mount="${IDV_WINE_AUDIO_VOLUME:-}"
expected_volume_uuid="${IDV_WINE_AUDIO_VOLUME_UUID:-}"
expected_archive_sha='e4ec87d5821a009dd1f1d2e36ffe2e24b8fcbae9516375ea42f95a16928ab8fa'
expected_source_sha='635347dcfc86800ed64737c6487a808836240e7846c6af699493e7a683d3f42c'
expected_patched_source_sha='ccd1db550dd16471e1f6df203e880928d1474aa82a42a9bc994d083f0baa3153'
expected_baseline_sha='90419c1a4009407b28b353614b883ef3d1531e8b852416fe0eaf704c90b6fce0'
target='dlls/winecoreaudio.drv/winecoreaudio.so'

[[ "$archive" == /* && -f "$archive" ]] || {
  print -u2 -- 'Set CROSSOVER_SOURCE_ARCHIVE to the verified CodeWeavers 26.1 source archive.'
  exit 64
}
[[ "$llvm_root" == /* && -x "$llvm_root/bin/x86_64-w64-mingw32-gcc" ]] || {
  print -u2 -- 'Set LLVM_MINGW_ROOT to the llvm-mingw root with bin/x86_64-w64-mingw32-gcc.'
  exit 64
}
[[ "$bison_bin" == /* && -x "$bison_bin" ]] || {
  print -u2 -- 'Set BISON to the required Bison executable.'
  exit 64
}
[[ "$baseline_module" == /* && -f "$baseline_module" ]] || {
  print -u2 -- 'Set ACTIVE_AUDIO_MODULE to the exact audio1 x86_64 module used for ABI comparison.'
  exit 64
}
[[ "$volume_mount" == /* && -d "$volume_mount" && -n "$expected_volume_uuid" ]] || {
  print -u2 -- 'Set IDV_WINE_AUDIO_VOLUME and IDV_WINE_AUDIO_VOLUME_UUID for the intended external build volume.'
  exit 64
}
[[ "$build_root" == "$volume_mount"/* && ! -e "$build_root" ]] || {
  print -u2 -- 'Set a new, unused IDV_WINE_AUDIO_BUILD_ROOT below the supplied external volume; refusing all other locations.'
  exit 64
}
[[ "$build_root" != *' '* ]] || {
  print -u2 -- 'The build-root path must not contain spaces because Wine configure expands BISON unquoted.'
  exit 64
}

volume_info="$(/usr/sbin/diskutil info -plist "$volume_mount")"
volume_uuid="$(/usr/bin/plutil -extract DiskUUID raw -o - - <<< "$volume_info")"
actual_mount="$(/usr/bin/plutil -extract MountPoint raw -o - - <<< "$volume_info")"
[[ -d "$volume_mount" && "$actual_mount" == "$volume_mount" && "$volume_uuid" == "$expected_volume_uuid" ]] || {
  print -u2 -- "Refusing build: volume mount/UUID verification failed ($actual_mount, $volume_uuid)."
  exit 65
}
actual_archive_sha="$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')"
[[ "$actual_archive_sha" == "$expected_archive_sha" ]] || {
  print -u2 -- "CodeWeavers source archive hash mismatch: $actual_archive_sha"
  exit 65
}
actual_baseline_sha="$(/usr/bin/shasum -a 256 "$baseline_module" | /usr/bin/awk '{print $1}')"
[[ "$actual_baseline_sha" == "$expected_baseline_sha" ]] || {
  print -u2 -- "Supplied audio1 baseline hash mismatch: $actual_baseline_sha"
  exit 65
}

/bin/mkdir -p "$build_root/source"
/usr/bin/tar -xzf "$archive" -C "$build_root/source" --strip-components=2 sources/wine
source_dir="$build_root/source"
coreaudio_source="$source_dir/dlls/winecoreaudio.drv/coreaudio.c"
actual_source_sha="$(/usr/bin/shasum -a 256 "$coreaudio_source" | /usr/bin/awk '{print $1}')"
[[ "$actual_source_sha" == "$expected_source_sha" ]] || {
  print -u2 -- "CodeWeavers CoreAudio source hash mismatch: $actual_source_sha"
  exit 65
}

for patch_file in default-input-only.patch capture-resample-produced-frames.patch default-device-following.patch; do
  /usr/bin/patch --dry-run -d "$source_dir" -p1 < "$script_dir/$patch_file"
  /usr/bin/patch -d "$source_dir" -p1 < "$script_dir/$patch_file"
done
/bin/cp "$script_dir/default-device-following-state.h" "$source_dir/dlls/winecoreaudio.drv/"
actual_patched_sha="$(/usr/bin/shasum -a 256 "$coreaudio_source" | /usr/bin/awk '{print $1}')"
[[ "$actual_patched_sha" == "$expected_patched_source_sha" ]] || {
  print -u2 -- "Patched CoreAudio source hash mismatch: $actual_patched_sha"
  exit 65
}

/usr/bin/xcrun clang -std=c11 -Wall -Wextra -Werror -I "$script_dir" \
  "$script_dir/default-device-following-state-test.c" -o "$build_root/state-test"
"$build_root/state-test"

tool_path="$llvm_root/bin:$(/usr/bin/dirname "$bison_bin"):/usr/bin:/bin:/usr/sbin:/sbin"
bison_pkgdatadir="$(/usr/bin/dirname "$bison_bin")/../share/bison"
/bin/mkdir -p "$build_root/tools"
bison_wrapper="$build_root/tools/bison"
/bin/ln -s "$bison_bin" "$bison_wrapper"
(
  cd "$source_dir"
  /usr/bin/arch -x86_64 /usr/bin/env \
    PATH="$tool_path" BISON="$bison_wrapper" BISON_PKGDATADIR="$bison_pkgdatadir" \
    CC='xcrun clang -arch x86_64' CXX='xcrun clang++ -arch x86_64' \
    MACOSX_DEPLOYMENT_TARGET=10.15 \
    ./configure --enable-archs=x86_64 --disable-win16 --disable-tests \
      --without-freetype --without-gstreamer --without-vulkan \
      > "$build_root/configure.log" 2>&1
  /usr/bin/arch -x86_64 /usr/bin/env \
    PATH="$tool_path" BISON="$bison_wrapper" BISON_PKGDATADIR="$bison_pkgdatadir" \
    CC='xcrun clang -arch x86_64' CXX='xcrun clang++ -arch x86_64' \
    MACOSX_DEPLOYMENT_TARGET=10.15 \
    /usr/bin/make "$target" > "$build_root/build.log" 2>&1
)

module="$source_dir/$target"
[[ -f "$module" && ! -L "$module" ]] || {
  print -u2 -- "Build did not produce a regular module: $module"
  exit 66
}
/usr/bin/file "$module" | /usr/bin/tee "$build_root/module.file.txt"
/usr/bin/otool -D "$module" | /usr/bin/tee "$build_root/module.install-name.txt"
/usr/bin/otool -L "$module" | /usr/bin/tee "$build_root/module.dependencies.txt"
/usr/bin/otool -l "$module" | /usr/bin/tee "$build_root/module.load-commands.txt" \
  | /usr/bin/awk '/LC_BUILD_VERSION/{next} /LC_VERSION_MIN_MACOSX/{legacy=1; next} legacy && /version/{print; exit} /minos/{print; exit}' \
  > "$build_root/module.minimum-os.txt"
/usr/bin/nm -gU "$module" | /usr/bin/awk '{print $NF}' | /usr/bin/sort -u > "$build_root/module.exports.txt"
/usr/bin/nm -gU "$baseline_module" | /usr/bin/awk '{print $NF}' | /usr/bin/sort -u > "$build_root/baseline.exports.txt"
/usr/bin/otool -L "$baseline_module" | /usr/bin/tail -n +2 | /usr/bin/sed 's/ (compatibility.*//' | /usr/bin/sort > "$build_root/baseline.dependencies.txt"
/usr/bin/otool -L "$module" | /usr/bin/tail -n +2 | /usr/bin/sed 's/ (compatibility.*//' | /usr/bin/sort > "$build_root/candidate.dependencies.normalized.txt"
/usr/bin/shasum -a 256 "$module" | /usr/bin/tee "$build_root/module.sha256"
/usr/bin/shasum -a 256 "$baseline_module" | /usr/bin/tee "$build_root/baseline.sha256"

/usr/bin/grep -q 'Mach-O 64-bit dynamically linked shared library x86_64' "$build_root/module.file.txt" || {
  print -u2 -- 'Built module is not a thin x86_64 Mach-O shared library.'
  exit 66
}
/usr/bin/grep -q '@rpath/winecoreaudio.so' "$build_root/module.install-name.txt" || {
  print -u2 -- 'Built module has an unexpected install name.'
  exit 66
}
/usr/bin/grep -q 'minos 10.15' "$build_root/module.minimum-os.txt" || {
  print -u2 -- 'Built module does not declare the expected macOS 10.15 deployment target.'
  exit 66
}
/usr/bin/cmp -s "$build_root/module.exports.txt" "$build_root/baseline.exports.txt" || {
  print -u2 -- 'Exported symbol list differs from the supplied audio1 baseline.'
  exit 66
}
/usr/bin/cmp -s "$build_root/candidate.dependencies.normalized.txt" "$build_root/baseline.dependencies.txt" || {
  /usr/bin/diff -u "$build_root/baseline.dependencies.txt" "$build_root/candidate.dependencies.normalized.txt" > "$build_root/dependencies.diff" || true
  print -u2 -- 'Dynamic dependency list differs from the supplied audio1 baseline; inspect dependencies.diff.'
  exit 66
}

print -- "Unsigned x86_64 candidate built and checked: $module"
print -- "Logs, hashes, exports, dependencies: $build_root"
print -- 'This does not sign or install the module and does not access audio devices.'
