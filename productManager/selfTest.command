#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
SOURCE="$SCRIPT_DIR/IdentityVProductManager.swift"
CATALOG="$PROJECT_ROOT/productCatalog/products.json"
TEST_ROOT="$(/usr/bin/mktemp -d)"
TEST_HOME="$TEST_ROOT/home"
TEST_BIN="$TEST_ROOT/bin"
MANAGER="$TEST_BIN/IdentityVProductManager"
SDK_PATH="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"

cleanup() {
  /bin/rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

/bin/mkdir -p "$TEST_HOME" "$TEST_BIN"
/usr/bin/xcrun swiftc \
  -swift-version 5 \
  -warnings-as-errors \
  -O \
  -target arm64-apple-macos14.0 \
  -sdk "$SDK_PATH" \
  "$SOURCE" \
  "$SCRIPT_DIR/AgentCLI.swift" "$SCRIPT_DIR/../sharedDiagnostics/LauncherOperationLocks.swift" \
  "$SCRIPT_DIR/LegacyDefaultPathMigration.swift" \
  "$SCRIPT_DIR/LegacyDefaultPathMigrationSelfTest.swift" \
  "$SCRIPT_DIR/../playerLauncherApp/Sources/LauncherLanguage.swift" \
  -o "$MANAGER"
/bin/cp "$CATALOG" "$TEST_BIN/products.json"
/bin/cp "$PROJECT_ROOT/docs/agentCLI.md" "$TEST_BIN/agent-cli.md"
/usr/bin/install -m 755 "$SCRIPT_DIR/idv" "$TEST_BIN/idv"
"$MANAGER" self-test
HOME="$TEST_HOME" "$MANAGER" status --json | /usr/bin/plutil -extract schemaVersion raw - | /usr/bin/grep -qx '1'
HOME="$TEST_HOME" IDENTITYV_AGENT_TASK_ROOT="$TEST_ROOT/tasks" python3 "$SCRIPT_DIR/tests/managerAgent.test.py" "$MANAGER"
python3 "$SCRIPT_DIR/tests/updaterAgent.test.py" "$MANAGER"
if [[ "${1:-}" == "--network-smoke" ]]; then
  HOME="$TEST_HOME" IDENTITYV_AGENT_TASK_ROOT="$TEST_ROOT/tasks" python3 "$SCRIPT_DIR/tests/officialNetworkSmoke.test.py" "$MANAGER"
fi
# Do not exercise `select` here: it correctly refuses while a real game is
# running, which would make this otherwise offline self-test host-dependent.
[[ ! -e "$TEST_HOME/Library/Application Support/IdentityVOnMac/active-installation.json" ]]
print -- "产品管理器自检通过。"
