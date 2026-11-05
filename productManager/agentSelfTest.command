#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
TEST_ARGUMENTS=()
if [[ "${1:-}" == "--headless" ]]; then
  TEST_ARGUMENTS+=(--headless)
elif [[ $# -ne 0 ]]; then
  print -u2 -- "usage: agentSelfTest.command [--headless]"
  exit 64
fi
TEST_ROOT="$(mktemp -d)"
trap '/bin/rm -rf "$TEST_ROOT"' EXIT
/usr/bin/xcrun swiftc -D AGENT_FIXTURE -swift-version 5 -warnings-as-errors -O -target arm64-apple-macos14.0 \
  "$SCRIPT_DIR/AgentCLI.swift" "$SCRIPT_DIR/../sharedDiagnostics/LauncherOperationLocks.swift" "$SCRIPT_DIR/../playerLauncherApp/Sources/LauncherLanguage.swift" "$SCRIPT_DIR/tests/AgentCLIFixture.swift" -o "$TEST_ROOT/fixture"
"$TEST_ROOT/fixture" handoff-self-test
/bin/cp "$SCRIPT_DIR/../docs/agentCLI.md" "$TEST_ROOT/agent-cli.md"
/bin/cp "$SCRIPT_DIR/../playerLauncherApp/IdentityVLauncher.icns" "$TEST_ROOT/IdentityVLauncher.icns"
python3 "$SCRIPT_DIR/tests/agentCLI.test.py" "$TEST_ROOT/fixture" "${TEST_ARGUMENTS[@]}"
