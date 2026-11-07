#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
SOURCE="$ROOT/privilegedHelpers/IdentityVPrivilegedStateTool.swift"
OUTPUT="$ROOT/.build/identityv-state-tool"
SDK="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"

/bin/mkdir -p "${OUTPUT:h}"
# Embed the reviewed Python source in the native executable. Startup needs no
# system Python and installer payloads cannot omit a separate overlay resource.
OVERLAY_SOURCE="$ROOT/idvLoginComponent/dnsTCPFallback.py"
EMBEDDED_SOURCE="${OUTPUT:h}/idv-dns-overlay.swift"
OVERLAY_BASE64="$(/usr/bin/base64 < "$OVERLAY_SOURCE" | /usr/bin/tr -d '\n')"
/usr/bin/printf 'import Foundation\nlet idvLoginDNSOverlay = Data(base64Encoded: "%s")!\n' "$OVERLAY_BASE64" > "$EMBEDDED_SOURCE"
/usr/bin/xcrun swiftc \
  -swift-version 5 \
  -warnings-as-errors \
  -O \
  -parse-as-library \
  -target arm64-apple-macos14.0 \
  -sdk "$SDK" \
  "$SOURCE" "$EMBEDDED_SOURCE" \
  -o "$OUTPUT"
/bin/chmod 755 "$OUTPUT"
/usr/bin/codesign --force --sign - --identifier com.fengyin.identityv.installer.privileged-state "$OUTPUT"
"$OUTPUT" --self-test
/usr/bin/python3 "$ROOT/idvLoginComponent/dnsTCPFallback.test.py"
/usr/bin/file "$OUTPUT" | /usr/bin/grep -q 'Mach-O 64-bit executable arm64'
"$ROOT/runtimeManifest/auditMachODeploymentTargets.command" "$OUTPUT"
/usr/bin/printf '构建完成：%s\n' "$OUTPUT"
