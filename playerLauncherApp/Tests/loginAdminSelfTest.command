#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h:h}"
TEMP_ROOT="$(mktemp -d /tmp/idv-login-admin-test.XXXXXX)"
trap '/bin/rm -rf "$TEMP_ROOT"' EXIT
python3 - "$ROOT" "$TEMP_ROOT" <<'PY'
from pathlib import Path
import sys
root, tmp = map(Path, sys.argv[1:])
s = (root/'playerLauncherApp/Sources/LauncherUpdateAgent.swift').read_text()
core = s[s.index('/// Both GUI and Agent'):]
(tmp/'Core.swift').write_text('import AppKit\nimport Foundation\nenum ToolboxViewModel { static func loginReadinessStatus() -> String { "not-running" } }\n'+core)
PY
cat > "$TEMP_ROOT/Main.swift" <<'SWIFT'
import Foundation
@main struct Test {
    @MainActor static func main() async throws {
        var opens = 0
        for state in ["not-running", "starting", "misconfigured", "unknown", "helper-update-required"] {
            do {
                try await LoginAdmin.open(readiness: { state }, browser: { _ in opens += 1; return true })
                fatalError("Unavailable state opened")
            } catch LoginAdmin.Failure.unavailable { }
        }
        precondition(opens == 0)
        try await LoginAdmin.open(readiness: { "ready" }, browser: { url in
            precondition(url.absoluteString == "https://localhost/_idv-login/index")
            precondition(url.query == nil && url.user == nil && url.password == nil)
            opens += 1; return true
        })
        precondition(opens == 1)
        do {
            try await LoginAdmin.open(readiness: { "ready" }, browser: { _ in false })
            fatalError("Browser failure lost")
        } catch LoginAdmin.Failure.browser { }
        print("Login admin shared core: ready/stopped/starting/unavailable/browser failure passed; no browser or component modified")
    }
}
SWIFT
xcrun swiftc -module-cache-path "$TEMP_ROOT/cache" -swift-version 5 -warnings-as-errors -parse-as-library -framework AppKit "$TEMP_ROOT/Core.swift" "$ROOT/playerLauncherApp/Sources/LauncherLanguage.swift" "$TEMP_ROOT/Main.swift" -o "$TEMP_ROOT/test"
"$TEMP_ROOT/test"
