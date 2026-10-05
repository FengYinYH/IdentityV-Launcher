#!/bin/zsh
set -euo pipefail
root="${0:A:h}"
probe_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp/}identityv-name-test.XXXXXX")"
probe_root="${probe_root:A}"
app="$probe_root/NameProbe.app"
bundle_id="com.fengyin.identityv.name-probe.$(/usr/bin/uuidgen)"
probe_pid=""
cleanup() {
  # PID comes from the exact unique bundle/executable query below.
  [[ -z "$probe_pid" ]] || /bin/kill -TERM "$probe_pid" 2>/dev/null || true
  /bin/rm -rf "$probe_root"
}
trap cleanup EXIT
/bin/mkdir -p "$app/Contents/MacOS"
/usr/bin/python3 - "$app/Contents/Info.plist" "$bundle_id" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump(dict(CFBundleIdentifier=sys.argv[2], CFBundleName='CrossOver-Hosted Application',
                      CFBundleExecutable='NameProbe', CFBundlePackageType='APPL', LSUIElement=True), f)
PY
/usr/bin/xcrun clang -arch x86_64 -fobjc-arc -fblocks -O2 -Wall -Wextra -Werror \
  -framework AppKit -framework Carbon -framework CoreAudio \
  "$root/GameDisplayNameProbe.m" "$root/IdentityVAudioKeyPolicy.c" -o "$app/Contents/MacOS/NameProbe"
/usr/bin/codesign --force --sign - "$app" >/dev/null
cat > "$probe_root/query.swift" <<'SWIFT'
import AppKit
let applications = NSRunningApplication.runningApplications(withBundleIdentifier: CommandLine.arguments[1])
guard applications.count == 1, let application = applications.first,
      application.executableURL?.path == CommandLine.arguments[2], !application.isActive,
      application.localizedName == CommandLine.arguments[3] else { exit(1) }
print(application.processIdentifier)
SWIFT
/usr/bin/xcrun swiftc "$probe_root/query.swift" -o "$probe_root/query"
for display_name in '第五人格' 'Identity V'; do
  /usr/bin/open -g -n "$app" --args "$display_name"
  for attempt in {1..30}; do
    probe_pid="$("$probe_root/query" "$bundle_id" "$app/Contents/MacOS/NameProbe" "$display_name" || true)"
    [[ -z "$probe_pid" ]] || break
    /bin/sleep 0.1
  done
  [[ "$probe_pid" == <-> ]] || { print -u2 -- "LaunchServices name check failed: $display_name"; exit 1; }
  /bin/kill -TERM "$probe_pid"
  probe_pid=""
  /bin/sleep 0.2
done
print -r -- 'Production native display-name adapter: Chinese/English LaunchServices names passed; probes stayed inactive.'
