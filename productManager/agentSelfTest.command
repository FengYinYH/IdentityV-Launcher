#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
TEST_ROOT="$(mktemp -d)"
trap '/bin/rm -rf "$TEST_ROOT"' EXIT
/usr/bin/xcrun swiftc -swift-version 5 -warnings-as-errors -O -target arm64-apple-macos14.0 \
  "$SCRIPT_DIR/AgentCLI.swift" "$SCRIPT_DIR/tests/AgentCLIFixture.swift" -o "$TEST_ROOT/fixture"
python3 "$SCRIPT_DIR/tests/agentCLI.test.py" "$TEST_ROOT/fixture"
