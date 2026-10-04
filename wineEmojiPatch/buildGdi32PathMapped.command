#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# Rebuild only the patched Wine GDI PE DLL with source/build path mapping.
# Requires a new build root on a caller-verified external volume.
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
archive="${IDV_GDI_SOURCE_ARCHIVE:-}"
llvm_root="${IDV_GDI_MINGW_ROOT:-}"
bison="${IDV_GDI_BISON:-}"
freetype_root="${IDV_GDI_FREETYPE_ROOT:-}"
gnutls_root="${IDV_GDI_GNUTLS_ROOT:-}"
build_root="${IDV_GDI_BUILD_ROOT:-}"
volume_mount="${IDV_GDI_VOLUME_MOUNT:-}"
expected_uuid="${IDV_GDI_VOLUME_UUID:-}"
jobs="${IDV_GDI_JOBS:-6}"

expected_archive_sha='e4ec87d5821a009dd1f1d2e36ffe2e24b8fcbae9516375ea42f95a16928ab8fa'
expected_0001_sha='0e893472e0e3a83d2080a2649eaf84e996d21ea311f548160af68186ad3b91e8'
expected_0002_sha='fbeefa7343eef5faf9af88c9527ca09e61a8797bca73afa4af4940a68edd4394'
expected_header_sha='0edb20f186c6771ef0b91226a91b7d6f2ef7cb5d97cd1a1a7a1f9715a285ae25'
expected_mingw_wrapper_sha='c9b86311ade81d53235c93fafabdf98328d094de344ea9a9038e0dab6695ee9f'
expected_bison_sha='3d0bf2004036e51fbf4cd4a56dcd485d2ed237a70e7338fb554a35ad9a80a36e'

for required in "$archive" "$llvm_root" "$bison" "$freetype_root" "$gnutls_root" "$build_root" "$volume_mount" "$expected_uuid"; do
  [[ -n "$required" ]] || { print -u2 -- 'Set all IDV_GDI_* input, toolchain, external-volume, and build-root variables.'; exit 64; }
done
[[ "$archive" == /* && -f "$archive" ]] || { print -u2 -- 'Source archive must be an existing absolute file.'; exit 64; }
[[ "$llvm_root" == /* && -x "$llvm_root/bin/x86_64-w64-mingw32-gcc" ]] || { print -u2 -- 'Invalid llvm-mingw root.'; exit 64; }
[[ "$bison" == /* && -x "$bison" ]] || { print -u2 -- 'Bison must be an executable absolute path.'; exit 64; }
[[ "$freetype_root" == /* && -d "$freetype_root/include/freetype2" && -d "$freetype_root/lib" ]] || { print -u2 -- 'Invalid x86_64 FreeType root.'; exit 64; }
[[ "$gnutls_root" == /* && -d "$gnutls_root/include" && -d "$gnutls_root/lib" ]] || { print -u2 -- 'Invalid x86_64 GnuTLS root.'; exit 64; }
[[ "$build_root" == /* && "$build_root" == "$volume_mount"/* && "$build_root" != *' '* ]] || {
  print -u2 -- 'Build root must be a new no-space path below the specified external volume.'; exit 64;
}
[[ ! -e "$build_root" && ! -L "$build_root" ]] || { print -u2 -- 'Build root already exists; refusing to reuse or overwrite it.'; exit 64; }
[[ "$jobs" == <-> && "$jobs" -ge 1 && "$jobs" -le 32 ]] || { print -u2 -- 'IDV_GDI_JOBS must be an integer from 1 to 32.'; exit 64; }

volume_info="$(/usr/sbin/diskutil info -plist "$volume_mount")"
actual_uuid="$(/usr/bin/plutil -extract DiskUUID raw -o - - <<< "$volume_info")"
actual_mount="$(/usr/bin/plutil -extract MountPoint raw -o - - <<< "$volume_info")"
[[ "$actual_uuid" == "$expected_uuid" && "$actual_mount" == "$volume_mount" ]] || {
  print -u2 -- 'External build volume mount point or UUID does not match the supplied identity.'; exit 65;
}
[[ "$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')" == "$expected_archive_sha" ]] || {
  print -u2 -- 'CodeWeavers 26.1 source archive SHA-256 mismatch.'; exit 65;
}
[[ "$(/usr/bin/shasum -a 256 "$script_dir/0001-gdi32-shape-valid-surrogate-pairs.patch" | /usr/bin/awk '{print $1}')" == "$expected_0001_sha" ]] || { print -u2 -- '0001 patch SHA-256 mismatch.'; exit 65; }
[[ "$(/usr/bin/shasum -a 256 "$script_dir/0002-uniscribe-rgi-composite-emoji.patch" | /usr/bin/awk '{print $1}')" == "$expected_0002_sha" ]] || { print -u2 -- '0002 patch SHA-256 mismatch.'; exit 65; }
[[ "$(/usr/bin/shasum -a 256 "$script_dir/repro/emoji_rgi_sequences.h" | /usr/bin/awk '{print $1}')" == "$expected_header_sha" ]] || { print -u2 -- 'generated Unicode header SHA-256 mismatch.'; exit 65; }
[[ "$(/usr/bin/shasum -a 256 "$llvm_root/bin/x86_64-w64-mingw32-gcc" | /usr/bin/awk '{print $1}')" == "$expected_mingw_wrapper_sha" ]] || {
  print -u2 -- 'llvm-mingw x86_64 compiler wrapper SHA-256 mismatch.'; exit 65;
}
[[ "$(/usr/bin/shasum -a 256 "$bison" | /usr/bin/awk '{print $1}')" == "$expected_bison_sha" ]] || {
  print -u2 -- 'Bison 3.8.2 executable SHA-256 mismatch.'; exit 65;
}
"$llvm_root/bin/clang" --version | /usr/bin/grep -q '^clang version 21\.1\.8 ' || {
  print -u2 -- 'llvm-mingw Clang must report version 21.1.8.'; exit 65;
}

source_dir="$build_root/source"
build_dir="$build_root/build"
tools_dir="$build_root/tools"
/bin/mkdir -p "$source_dir" "$build_dir" "$tools_dir" "$build_root/candidate"
/usr/bin/tar -xzf "$archive" -C "$source_dir" --strip-components=2 sources/wine
for patch_file in 0001-gdi32-shape-valid-surrogate-pairs.patch 0002-uniscribe-rgi-composite-emoji.patch; do
  /usr/bin/patch --dry-run -d "$source_dir" -p1 < "$script_dir/$patch_file"
  /usr/bin/patch -d "$source_dir" -p1 < "$script_dir/$patch_file"
done
/usr/bin/cmp -s "$source_dir/dlls/gdi32/uniscribe/emoji_rgi_sequences.h" "$script_dir/repro/emoji_rgi_sequences.h" || {
  print -u2 -- 'Patched generated Unicode sequence header differs from the reviewed project copy.'; exit 65;
}

# Wine 26.1 consumes BISON as an unquoted command variable, and its debug info
# records absolute source/build paths by default. Local no-space tool links keep
# configure stable; CROSSCFLAGS maps both trees in debug and __FILE__ strings.
/bin/ln -s "$bison" "$tools_dir/bison"
/bin/ln -s "${bison:h:h}/share/bison" "$tools_dir/bison-share"
/bin/ln -s "$freetype_root" "$tools_dir/freetype"
/bin/ln -s "$gnutls_root" "$tools_dir/gnutls"
cross_flags="-g -O2 -ffile-prefix-map=$source_dir=. -fdebug-prefix-map=$source_dir=. -fmacro-prefix-map=$source_dir=. -ffile-prefix-map=$build_dir=. -fdebug-prefix-map=$build_dir=. -fmacro-prefix-map=$build_dir=. -fdebug-compilation-dir=."
local_llvm_bin="$tools_dir/llvm/bin"
/bin/mkdir -p "$local_llvm_bin"
/bin/cp "$llvm_root/bin/x86_64-w64-mingw32-gcc" "$local_llvm_bin/x86_64-w64-mingw32-gcc"
/bin/ln -s "$llvm_root/bin/clang" "$local_llvm_bin/clang"
path="$local_llvm_bin:${llvm_root}/bin:${tools_dir}:/usr/bin:/bin:/usr/sbin:/sbin"
(
  cd "$build_dir"
  /usr/bin/arch -x86_64 /usr/bin/env PATH="$path" BISON="$tools_dir/bison" \
    BISON_PKGDATADIR="$tools_dir/bison-share" CROSSCFLAGS="$cross_flags" \
    CC='xcrun clang -arch x86_64' CXX='xcrun clang++ -arch x86_64' \
    FREETYPE_CFLAGS="-I$tools_dir/freetype/include/freetype2" \
    FREETYPE_LIBS="-L$tools_dir/freetype/lib -lfreetype" \
    GNUTLS_CFLAGS="-I$tools_dir/gnutls/include" \
    GNUTLS_LIBS="-L$tools_dir/gnutls/lib -lgnutls" \
    ../source/configure --prefix=/identityv-wine11 --enable-archs=x86_64 \
      --disable-win16 --disable-tests --without-gstreamer --without-vulkan --with-gnutls \
      > "$build_root/configure.log" 2>&1
)

(
  cd "$build_dir"
  /usr/bin/arch -x86_64 /usr/bin/env PATH="$path" BISON="$tools_dir/bison" \
    BISON_PKGDATADIR="$tools_dir/bison-share" CROSSCFLAGS="$cross_flags" \
    /usr/bin/make tools/winebuild/winebuild > "$build_root/winebuild-tool.log" 2>&1
)
winebuild="$build_dir/tools/winebuild/winebuild"
winebuild_real="$build_dir/tools/winebuild/winebuild-real"
[[ -f "$winebuild" && ! -L "$winebuild" && ! -e "$winebuild_real" ]] || {
  print -u2 -- 'Host winebuild was not built as a regular file, or wrapper target already exists.'; exit 66;
}
/bin/mv "$winebuild" "$winebuild_real"
/bin/cat > "$winebuild" <<EOF
#!/bin/sh
exec "$winebuild_real" --without-dlltool "\$@"
EOF
/bin/chmod 755 "$winebuild"
(
  cd "$build_dir"
  /usr/bin/arch -x86_64 /usr/bin/env \
    PATH="$path" BISON="$tools_dir/bison" BISON_PKGDATADIR="$tools_dir/bison-share" \
    CROSSCFLAGS="$cross_flags" \
    /usr/bin/make -j"$jobs" \
      dlls/gdi32/x86_64-windows/gdi32.dll > "$build_root/build.log" 2>&1
)

built="$build_dir/dlls/gdi32/x86_64-windows/gdi32.dll"
[[ -f "$built" && ! -L "$built" ]] || { print -u2 -- 'GDI build output is missing or not a regular file.'; exit 66; }
/bin/cp "$built" "$build_root/gdi32.unstripped.dll"
/bin/cp "$built" "$build_root/candidate/gdi32.dll"
"$llvm_root/bin/llvm-strip" --strip-debug "$build_root/candidate/gdi32.dll"

baseline="$project_root/wineEmojiPatch/releasePayloads/gdi32.dll"
baseline_copy="$build_root/baseline-gdi32.dll"
/bin/cp "$baseline" "$baseline_copy"
"$llvm_root/bin/llvm-strip" --strip-debug "$baseline_copy"
"$llvm_root/bin/llvm-readobj" --file-headers --sections --coff-imports --coff-exports \
  "$baseline_copy" > "$build_root/baseline-pe.txt"
"$llvm_root/bin/llvm-readobj" --file-headers --sections --coff-imports --coff-exports \
  "$build_root/candidate/gdi32.dll" > "$build_root/candidate-pe.txt"
"$llvm_root/bin/llvm-objcopy" --dump-section=".text=$build_root/baseline.text" "$baseline_copy"
"$llvm_root/bin/llvm-objcopy" --dump-section=".text=$build_root/candidate.text" "$build_root/candidate/gdi32.dll"
"$llvm_root/bin/llvm-strings" "$build_root/candidate/gdi32.dll" > "$build_root/candidate-strings.txt"
/usr/bin/python3 "$script_dir/repro/verify_gdi_pe_contract.py" \
  --baseline "$baseline" --candidate "$build_root/candidate/gdi32.dll" \
  --baseline-readobj "$build_root/baseline-pe.txt" --candidate-readobj "$build_root/candidate-pe.txt" \
  --baseline-text "$build_root/baseline.text" --candidate-text "$build_root/candidate.text" \
  --strings "$build_root/candidate-strings.txt" --report "$build_root/verification.json" \
  --forbidden "$HOME" "$source_dir" "$build_dir" "$build_root" "$llvm_root" "$bison" "$freetype_root" "$gnutls_root"

/usr/bin/shasum -a 256 "$build_root/gdi32.unstripped.dll" "$build_root/candidate/gdi32.dll" \
  | /usr/bin/tee "$build_root/gdi32.sha256"
print -- "Unstripped build: $build_root/gdi32.unstripped.dll"
print -- "Path-mapped, stripped candidate: $build_root/candidate/gdi32.dll"
print -- "Build evidence: $build_root"
