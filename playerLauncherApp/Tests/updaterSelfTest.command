#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h:h}"
TEST_ROOT="$(mktemp -d)"
trap '/bin/rm -rf "$TEST_ROOT"' EXIT
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
xcrun swiftc -swift-version 5 -warnings-as-errors -parse-as-library -target arm64-apple-macos14.0 -sdk "$SDK_PATH" -framework AppKit -framework SwiftUI \
  "$ROOT/playerLauncherApp/Sources/ToolboxModels.swift" \
  "$ROOT/playerLauncherApp/Sources/LauncherLanguage.swift" \
  "$ROOT/playerLauncherApp/Sources/LauncherUpdateView.swift" \
  "$ROOT/playerLauncherApp/Tests/LauncherUpdatePreviewSelfTest.swift" -o "$TEST_ROOT/preview"
"$TEST_ROOT/preview"
xcrun swiftc -swift-version 5 -warnings-as-errors -O -parse-as-library -target arm64-apple-macos14.0 -sdk "$SDK_PATH" \
  "$ROOT/playerLauncherApp/Sources/LauncherUpdateChecker.swift" \
  "$ROOT/playerLauncherApp/Tests/LauncherUpdateCheckerSelfTest.swift" -o "$TEST_ROOT/checker"
"$TEST_ROOT/checker"
xcrun swiftc -swift-version 5 -warnings-as-errors -O -parse-as-library -target arm64-apple-macos14.0 -sdk "$SDK_PATH" -framework AppKit \
  "$ROOT/playerLauncherApp/Sources/LauncherUpdateChecker.swift" \
  "$ROOT/playerLauncherApp/Sources/LauncherUpdateInstallation.swift" \
  "$ROOT/playerLauncherApp/Sources/LauncherUpdateAgent.swift" \
  "$ROOT/playerLauncherApp/Sources/LauncherLanguage.swift" \
  "$ROOT/sharedDiagnostics/LauncherOperationLocks.swift" \
  "$ROOT/playerLauncherApp/Tests/LauncherUpdateInstallationSelfTest.swift" -o "$TEST_ROOT/installation"
"$TEST_ROOT/installation"
xcrun swiftc -swift-version 5 -warnings-as-errors -O -parse-as-library -target arm64-apple-macos14.0 -sdk "$SDK_PATH" -framework AppKit \
  "$ROOT/playerLauncherApp/Sources/LauncherUpdateChecker.swift" \
  "$ROOT/playerLauncherApp/Sources/LauncherUpdateInstallation.swift" \
  "$ROOT/sharedDiagnostics/LauncherOperationLocks.swift" \
  "$ROOT/playerLauncherApp/Sources/LauncherLanguage.swift" \
  "$ROOT/playerLauncherApp/UpdateHelper/LauncherUpdateHelper.swift" -o "$TEST_ROOT/helper"
xcrun swiftc -swift-version 5 -warnings-as-errors -O -parse-as-library -D LAUNCHER_UPDATE_RESULT_SELF_TEST -target arm64-apple-macos14.0 -sdk "$SDK_PATH" -framework AppKit \
  "$ROOT/playerLauncherApp/Sources/LauncherUpdateChecker.swift" \
  "$ROOT/playerLauncherApp/Sources/LauncherUpdateInstallation.swift" \
  "$ROOT/playerLauncherApp/Sources/LauncherLanguage.swift" \
  "$ROOT/sharedDiagnostics/LauncherOperationLocks.swift" \
  "$ROOT/playerLauncherApp/UpdateHelper/LauncherUpdateHelper.swift" \
  "$ROOT/playerLauncherApp/Tests/LauncherUpdateResultSelfTest.swift" -o "$TEST_ROOT/result"
"$TEST_ROOT/result"
print -- 'Updater focused checks passed (no installed App replaced).'
