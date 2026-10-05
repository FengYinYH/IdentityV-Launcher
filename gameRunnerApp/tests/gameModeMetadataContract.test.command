#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
launcher_plist="$root/../playerLauncherApp/Info.plist"
runner_plist="$root/IdentityV-Mac.app/Contents/Info.plist"

[[ -r "$launcher_plist" && -r "$runner_plist" ]]
/usr/bin/plutil -lint "$launcher_plist" >/dev/null
/usr/bin/plutil -lint "$runner_plist" >/dev/null

# The UI is a launcher, not the gameplay client.  Keep the game category and
# Game Mode opt-in on the embedded runner that owns the Wine game process.
[[ "$(/usr/bin/plutil -extract LSApplicationCategoryType raw -o - "$launcher_plist")" == "public.app-category.utilities" ]]
! /usr/libexec/PlistBuddy -c 'Print :LSSupportsGameMode' "$launcher_plist" >/dev/null 2>&1
! /usr/libexec/PlistBuddy -c 'Print :GCSupportsGameMode' "$launcher_plist" >/dev/null 2>&1

[[ "$(/usr/bin/plutil -extract CFBundleDisplayName raw -o - "$runner_plist")" == "第五人格" ]]
[[ "$(/usr/bin/plutil -extract CFBundleName raw -o - "$runner_plist")" == "第五人格" ]]
[[ "$(/usr/bin/plutil -extract LSApplicationCategoryType raw -o - "$runner_plist")" == "public.app-category.games" ]]
[[ "$(/usr/bin/plutil -extract LSSupportsGameMode raw -o - "$runner_plist")" == "true" ]]
[[ "$(/usr/bin/plutil -extract LSUIElement raw -o - "$runner_plist")" == "true" ]]
! /usr/libexec/PlistBuddy -c 'Print :GCSupportsGameMode' "$runner_plist" >/dev/null 2>&1

# Exercise only the exact final child fragment with a harmless shell stub.
# No Wine, GUI, game, prefix or audio is started. The parent must retain no
# app-name override, and both products must keep their Windows argv intact.
/usr/bin/python3 - "$root" <<'PY'
import os, subprocess, sys, tempfile
from pathlib import Path
root = Path(sys.argv[1])
mac = (root / 'IdentityV-Mac.app/Contents/MacOS/launchIdentityVRunner').read_text()
agtk = (root / 'IdentityV-AGTK.app/Contents/MacOS/launchIdentityVRunner').read_text()
assert mac == agtk
assert mac.count('export WINEPRELOADERAPPNAME=') == 1
fragment = mac.split('    (\n      # CodeWeavers', 1)[1]
fragment = '      # CodeWeavers' + fragment.split('    ) >>"$LOG_FILE"', 1)[0]
assert '/usr/bin/env' not in fragment
with tempfile.TemporaryDirectory(prefix='wine-menu-child-contract-') as directory:
    app_contents = Path(directory) / 'Launcher.app/Contents/Helpers/Runner.app/Contents'
    app_contents.mkdir(parents=True)
    manager = Path(directory) / 'Launcher.app/Contents/Resources/IdentityVProductManager'
    manager.parent.mkdir()
    manager.write_text('#!/bin/zsh\n[[ "$1" == game-display-name && $# == 1 ]] || exit 2\nprint -r -- "Identity V"\n')
    manager.chmod(0o700)
    stub = Path(directory) / 'wine-stub'
    stub.write_text('#!/bin/zsh\nprint -r -- "$WINEPRELOADERAPPNAME"\nprint -r -- "$1"\n')
    stub.chmod(0o700)
    for product, windows_root, selected, expected in [('mainland', 'IdentityV', 'Identity V', 'Identity V'), ('global', 'IdentityVGlobal', '第五人格', '第五人格'), ('global', 'IdentityVGlobal', 'invalid', 'Identity V'), ('mainland', 'IdentityV', '', 'Identity V')]:
        environment = os.environ.copy()
        environment.update(PRODUCT=product, WINDOWS_GAME_ROOT=windows_root, WINE_BIN=str(stub), IDENTITYV_GAME_DISPLAY_NAME=selected)
        environment['APP_CONTENTS'] = str(app_contents)
        code = 'unset WINEPRELOADERAPPNAME\ntypeset -a hud_environment GAME_LAUNCH_ARGUMENTS\n(\n' + fragment + '\n)\nprint -r -- "parent=${WINEPRELOADERAPPNAME-unset}"\n'
        result = subprocess.run(['/bin/zsh', '-c', code], env=environment, text=True, capture_output=True, check=True)
        assert result.stdout.splitlines() == [expected, 'C:\\Games\\' + windows_root + '\\dwrg.exe', 'parent=unset'], result.stdout
print('Game child menu-name scope and Windows argv contract passed')
PY

print -r -- "Game Mode metadata contract self-test passed"
