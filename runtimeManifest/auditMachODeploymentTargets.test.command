#!/bin/zsh
set -euo pipefail
root=${0:A:h}
fixture=$(/usr/bin/mktemp -d)
trap '/bin/rm -rf "$fixture"' EXIT
/bin/mkdir "$fixture/actual" "$fixture/empty"
print -r -- 'int main(void) { return 0; }' > "$fixture/probe.c"
/usr/bin/xcrun clang -target arm64-apple-macos14.0 "$fixture/probe.c" -o "$fixture/actual/probe"
/bin/ln -s "$fixture/actual" "$fixture/current"
IDV_MAX_MACOS_DEPLOYMENT_TARGET=14.0 "$root/auditMachODeploymentTargets.command" "$fixture/current" > "$fixture/result"
/usr/bin/grep -q '1 Mach-O file(s)' "$fixture/result"
if "$root/auditMachODeploymentTargets.command" "$fixture/empty" > "$fixture/empty-result" 2>&1; then
  print -u2 -- 'Empty audit incorrectly passed'; exit 1
fi
/usr/bin/grep -q 'no Mach-O files checked' "$fixture/empty-result"
print -- 'Deployment audit symlink-root and empty-root regression passed'
