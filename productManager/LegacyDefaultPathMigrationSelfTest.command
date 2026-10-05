#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
FIXTURE_ROOT="${IDV_RC1_MIGRATION_FIXTURE_ROOT:?Set the pre-created external fixture directory.}"
EXPECTED_UUID="${IDV_RC1_MIGRATION_VOLUME_UUID:?Set the expected mounted-volume UUID.}"

[[ -d "$FIXTURE_ROOT" && ! -L "$FIXTURE_ROOT" ]]
DEVICE="$(/bin/df -P "$FIXTURE_ROOT" | /usr/bin/awk 'NR == 2 { print $1; exit }')"
ACTUAL_UUID="$(/usr/sbin/diskutil info "$DEVICE" | /usr/bin/awk -F': *' '/Volume UUID/ { print $2; exit }')"
[[ -n "$ACTUAL_UUID" && "${ACTUAL_UUID:u}" == "${EXPECTED_UUID:u}" ]]
TEST_ROOT="$(/usr/bin/mktemp -d "$FIXTURE_ROOT/rc1-migration-test.XXXXXXXX")"
TEST_BIN="$TEST_ROOT/bin"
cleanup() {
  /bin/rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

/bin/mkdir -p "$TEST_BIN"
SDK_PATH="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
/usr/bin/xcrun swiftc \
  -swift-version 5 \
  -warnings-as-errors \
  -O \
  -target arm64-apple-macos14.0 \
  -sdk "$SDK_PATH" \
  "$SCRIPT_DIR/LegacyDefaultPathMigration.swift" \
  "$SCRIPT_DIR/LegacyDefaultPathMigrationSelfTest.swift" \
  "$SCRIPT_DIR/LegacyDefaultPathMigrationSelfTestMain.swift" \
  -o "$TEST_BIN/LegacyDefaultPathMigrationSelfTest"
/bin/mkdir -p "$TEST_ROOT/fixtures"
IDV_RC1_MIGRATION_FIXTURE_ROOT="$TEST_ROOT/fixtures" IDV_RC1_MIGRATION_VOLUME_UUID="$EXPECTED_UUID" \
  "$TEST_BIN/LegacyDefaultPathMigrationSelfTest"
