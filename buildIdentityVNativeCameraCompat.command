#!/bin/zsh
set -euo pipefail

# Build the source-owned adapter, leaving the verified OEM Wine modules intact.
# The adapter validates its own scope and the exact OEM ABI at process startup;
# unknown runtimes stay on their existing input path.
PROJECT_ROOT="${0:A:h}"
SOURCE="$PROJECT_ROOT/wineMousePatch/native_protocol_compat.m"
BUILD_DIR="$PROJECT_ROOT/wineMousePatch/build"
OUTPUT="$BUILD_DIR/IdentityVNativeCameraCompat.dylib"
(( $# == 0 )) || { print -u2 -- "用法：${0:t}"; exit 2; }

/bin/mkdir -p "$BUILD_DIR"
/usr/bin/xcrun --sdk macosx clang \
  -arch x86_64 -O2 -fno-objc-arc -mmacosx-version-min=14.0 \
  -Werror -Wno-deprecated-declarations -fvisibility=hidden -dynamiclib \
  -Wl,-install_name,@rpath/IdentityVNativeCameraCompat.dylib \
  -framework CoreFoundation "$SOURCE" -lobjc -o "$OUTPUT"
/usr/bin/codesign --force --sign - --timestamp=none \
  --identifier com.fengyin.identityv.runner.native-camera-compat "$OUTPUT"
/usr/bin/codesign --verify --strict "$OUTPUT"
/usr/bin/otool -D "$OUTPUT" | /usr/bin/tail -n 1 | /usr/bin/grep -qx '@rpath/IdentityVNativeCameraCompat.dylib'
# Loader wrapping changed caller-relative dependency lookup in an earlier
# candidate. Keep that regression out of the packaged adapter.
if /usr/bin/otool -l "$OUTPUT" | /usr/bin/grep -q '__interpose'; then
  print -u2 -- "拒绝打包拦截动态加载器的鼠标兼容层"
  exit 70
fi
if /usr/bin/nm -u "$OUTPUT" | /usr/bin/grep -Eq '(_dlopen|_CGEventTapCreate)$'; then
  print -u2 -- "拒绝打包含动态加载器包装或全局输入 tap 的鼠标兼容层"
  exit 70
fi
for app in "$PROJECT_ROOT/gameRunnerApp/IdentityV-Mac.app" "$PROJECT_ROOT/gameRunnerApp/IdentityV-AGTK.app"; do
  [[ -d "$app/Contents/Resources" ]] || continue
  /usr/bin/install -m 644 "$OUTPUT" "$app/Contents/Resources/IdentityVNativeCameraCompat.dylib"
  /usr/bin/codesign --force --deep --sign - "$app"
done
print -r -- "已构建鼠标兼容层：$OUTPUT"
print -- "仅更新项目内 runner 资源；未修改 /Applications 或运行中的 Wine 模块。"
