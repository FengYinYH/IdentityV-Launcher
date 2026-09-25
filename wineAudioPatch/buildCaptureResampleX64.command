#!/bin/zsh
# Build the CodeWeavers 26.1 capture resampler candidate for the shipped x86_64
# Wine runtime. This only creates an isolated, unsigned module; it never edits
# a runtime, prefix, launcher bundle, or installed application.
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
archive="${CROSSOVER_SOURCE_ARCHIVE:-}"
llvm_root="${LLVM_MINGW_ROOT:-}"
bison_bin="${BISON:-}"
build_root="${IDV_WINE_AUDIO_BUILD_ROOT:-$script_dir/build-26.1/capture-resample-x86_64-$(/bin/date '+%Y%m%dT%H%M%S')}"
expected_archive_sha='e4ec87d5821a009dd1f1d2e36ffe2e24b8fcbae9516375ea42f95a16928ab8fa'
expected_source_sha='635347dcfc86800ed64737c6487a808836240e7846c6af699493e7a683d3f42c'
expected_patched_source_sha='d55561d42cfa69ed75a1b288a2f907ab55c92de42275769fd60df3caa5b4c624'
target='dlls/winecoreaudio.drv/winecoreaudio.so'

[[ "$archive" == /* && -f "$archive" ]] || {
  print -u2 -- 'Set CROSSOVER_SOURCE_ARCHIVE to the verified CodeWeavers 26.1 source archive.'
  exit 64
}
[[ "$llvm_root" == /* && -x "$llvm_root/bin/x86_64-w64-mingw32-gcc" ]] || {
  print -u2 -- 'Set LLVM_MINGW_ROOT to the llvm-mingw toolchain root with bin/x86_64-w64-mingw32-gcc.'
  exit 64
}
[[ "$bison_bin" == /* && -x "$bison_bin" ]] || {
  print -u2 -- 'Set BISON to a Bison 3.8.2 executable.'
  exit 64
}
[[ "$build_root" == /* && ! -e "$build_root" ]] || {
  print -u2 -- "Refusing a non-absolute or existing build root: $build_root"
  exit 64
}

actual_archive_sha="$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')"
[[ "$actual_archive_sha" == "$expected_archive_sha" ]] || {
  print -u2 -- "CodeWeavers source archive hash mismatch: $actual_archive_sha"
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

/usr/bin/patch --dry-run -d "$source_dir" -p1 < "$script_dir/capture-resample-produced-frames.patch"
/usr/bin/patch -d "$source_dir" -p1 < "$script_dir/capture-resample-produced-frames.patch"
actual_patched_sha="$(/usr/bin/shasum -a 256 "$coreaudio_source" | /usr/bin/awk '{print $1}')"
[[ "$actual_patched_sha" == "$expected_patched_source_sha" ]] || {
  print -u2 -- "Patched CoreAudio source hash mismatch: $actual_patched_sha"
  exit 65
}

tool_path="$llvm_root/bin:$(/usr/bin/dirname "$bison_bin"):/usr/bin:/bin:/usr/sbin:/sbin"
(
  cd "$source_dir"
  /usr/bin/arch -x86_64 /usr/bin/env \
    PATH="$tool_path" BISON="$bison_bin" \
    CC='xcrun clang -arch x86_64' CXX='xcrun clang++ -arch x86_64' \
    MACOSX_DEPLOYMENT_TARGET=10.15 \
    ./configure --enable-archs=x86_64 --disable-win16 --disable-tests \
      --without-freetype --without-gstreamer --without-vulkan \
      > "$build_root/configure.log" 2>&1
  /usr/bin/arch -x86_64 /usr/bin/env \
    PATH="$tool_path" BISON="$bison_bin" \
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
/usr/bin/shasum -a 256 "$module" | /usr/bin/tee "$build_root/module.sha256"

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

print -- "Unsigned x86_64 candidate built and checked: $module"
print -- "Logs and hashes: $build_root"
print -- 'This is a compile check only; signing, runtime verification, and game voice regression remain separate.'
