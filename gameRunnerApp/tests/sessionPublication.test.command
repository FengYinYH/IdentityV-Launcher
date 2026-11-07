#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h:h}"
RUNNER="$ROOT/gameRunnerApp/IdentityV-Mac.app/Contents/MacOS/launchIdentityVRunner"
TEST_ROOT="$(mktemp -d)"
trap '/bin/rm -rf "$TEST_ROOT"' EXIT
COMPLEX="$TEST_ROOT/"$'引号 空格\'"\\路径\n换行'
/bin/mkdir -p -- "$COMPLEX"
cat > "$TEST_ROOT/probe.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static const char *value(const char *key) { const char *p = getenv(key); return p ? p : "unset"; }
int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--session") == 0) return puts("schema=1") < 0;
    int native = argc == 1 || (argc == 2 && strcmp(argv[1], "game-display-name") == 0);
    FILE *out = fopen(value("IDV_TEST_PROBE_OUTPUT"), "ab");
    if (!out) return 1;
    fprintf(out, "%ld", (long)getpid()); fputc(0, out);
    fputs(value("DYLD_INSERT_LIBRARIES"), out); fputc(0, out);
    fputs(value("DYLD_FALLBACK_LIBRARY_PATH"), out); fputc(0, out);
    fputs(value("WINEPRELOADERAPPNAME"), out); fputc(0, out);
    fputs(native ? "native" : "wine", out); fputc(0, out);
    if (fclose(out) != 0) return 1;
    if (native) puts("Identity V");
    return 0;
}
C
cat > "$TEST_ROOT/noop.c" <<'C'
int idv_test_noop(void) { return 0; }
C
APP_CONTENTS="$COMPLEX/Launcher.app/Contents/Helpers/Runner.app/Contents"
/bin/mkdir -p -- "$APP_CONTENTS/Resources" "$COMPLEX/Launcher.app/Contents/Resources"
/bin/cp "$ROOT/gameRunnerApp/gamePresentationHost.command" "$APP_CONTENTS/Resources/gamePresentationHost.command"
/usr/bin/clang -arch arm64 -mmacosx-version-min=14.0 -Wall -Wextra -Werror "$TEST_ROOT/probe.c" -o "$COMPLEX/Launcher.app/Contents/Resources/IdentityVProductManager"
/usr/bin/clang -arch x86_64 -mmacosx-version-min=14.0 -Wall -Wextra -Werror "$TEST_ROOT/probe.c" -o "$COMPLEX/wine-probe"
/usr/bin/clang -arch x86_64 -dynamiclib -mmacosx-version-min=14.0 -Wall -Wextra -Werror "$TEST_ROOT/noop.c" -o "$COMPLEX/x86-only.dylib"
# The exact shipped functions; no Wine, input helper, App or game is started.
eval "$(sed -n '/^publish_run_session() {/,/^}/p' "$RUNNER")"
eval "$(sed -n '/^launch_game_once() {/,/^}/p' "$RUNNER")"
COMMAND_GRAVE_FORWARDER="$COMPLEX/x86-only.dylib"
AUDIO_INTERPOSER=""
IDV_LOGIN_START_HELPER="$TEST_ROOT/no-login-helper"
LOGIN_DNS_COMPAT="$TEST_ROOT/no-login-dns"
INPUT_TRACE_ONCE_MARKER="$TEST_ROOT/no-input-marker"
WINE_BIN="$COMPLEX/wine-probe"
GAME_LAUNCH_ARGUMENTS=()
IDENTITYV_DESKTOP_NAME=IdentityV
IDENTITYV_DESKTOP_SIZE=1920x1080
METAL_HUD_ENABLED=0
LOG_FILE="$TEST_ROOT/runner.log"
export DYLD_FALLBACK_LIBRARY_PATH="fixture-fallback"
export IDV_TEST_PROBE_OUTPUT="$TEST_ROOT/probe.records"
for PRODUCT in mainland global; do
  [[ "$PRODUCT" == mainland ]] && WINDOWS_GAME_ROOT=IdentityV || WINDOWS_GAME_ROOT=IdentityVGlobal
  for IDENTITYV_USE_VIRTUAL_DESKTOP in 0 1; do
    unset DYLD_INSERT_LIBRARIES IDENTITYV_GAME_DISPLAY_NAME WINEPRELOADERAPPNAME
    RUN_SESSION_FILE="$COMPLEX/session-${PRODUCT}-${IDENTITYV_USE_VIRTUAL_DESKTOP}.env"
    : >| "$IDV_TEST_PROBE_OUTPUT"
    launch_game_once
    captured_pid="$LAUNCHED_WINE_PID"
    wait "$captured_pid"
    [[ "${DYLD_INSERT_LIBRARIES-unset}" == unset ]]
    # A non-SIP arm64 native child would die if the old global export leaked.
    "$COMPLEX/Launcher.app/Contents/Resources/IdentityVProductManager" --session > "$TEST_ROOT/native-session"
    [[ -s "$TEST_ROOT/native-session" ]]
    python3 - "$RUN_SESSION_FILE" "$PRODUCT" "$WINDOWS_GAME_ROOT" "$captured_pid" "$IDV_TEST_PROBE_OUTPUT" "$COMMAND_GRAVE_FORWARDER" "$IDENTITYV_USE_VIRTUAL_DESKTOP" <<'PY'
import pathlib,sys,os
p=pathlib.Path(sys.argv[1]); raw=p.read_text()
pairs=[x.split('=',1) for x in raw.splitlines()]
assert len(pairs)==5 and len(dict(pairs))==5
assert dict(pairs)=={'schema':'1','product':sys.argv[2],'runner_pid':str(os.getppid()),'wine_pid':sys.argv[4],'windows_root':sys.argv[3]}
assert p.stat().st_mode&0o777==0o600 and p.stat().st_size>0
parts=pathlib.Path(sys.argv[5]).read_bytes().split(b'\0'); assert parts[-1]==b''
records=[list(map(lambda x:x.decode(),parts[i:i+5])) for i in range(0,len(parts)-1,5)]
wine=[x for x in records if x[-1]=='wine'];assert len(wine)==1,repr(records)
assert wine[0][0]==sys.argv[4] # subshell exec retains exact PID
assert wine[0][1]==sys.argv[6] and wine[0][2]=='fixture-fallback'
native=[x for x in records if x[-1]=='native']
assert len(native)==1 and native[0][1]=='unset'
assert wine[0][3]=='Identity V'
PY
  done
done
# No publication failure may replace a previously valid record with zero bytes.
PRODUCT=global; WINDOWS_GAME_ROOT=IdentityVGlobal; LAUNCHED_WINE_PID=23456
RUN_SESSION_FILE="$COMPLEX/retained.env"
publish_run_session
old_session_text="$(<"$RUN_SESSION_FILE")"
LAUNCHED_WINE_PID=23457
function /bin/mv { return 73; }
if publish_run_session; then print -u2 -- 'rename failure was hidden'; exit 1; fi
[[ "$(<"$RUN_SESSION_FILE")" == "$old_session_text" && -s "$RUN_SESSION_FILE" ]]
# The game stub has already spawned: report failure with its known PID and
# never invoke it a second time just because publication failed.
: >| "$IDV_TEST_PROBE_OUTPUT"
IDENTITYV_USE_VIRTUAL_DESKTOP=0
if launch_game_once; then print -u2 -- 'launch hid publication failure'; exit 1; fi
failed_launch_pid="$LAUNCHED_WINE_PID"
wait "$failed_launch_pid"
[[ "$(<"$RUN_SESSION_FILE")" == "$old_session_text" ]]
grep -Fq -- "failed to publish session for spawned Wine PID $failed_launch_pid; no additional launch attempted" "$LOG_FILE"
python3 - "$IDV_TEST_PROBE_OUTPUT" "$failed_launch_pid" <<'PYCASE'
import pathlib,sys
parts=pathlib.Path(sys.argv[1]).read_bytes().split(b'\0')
records=[parts[i:i+5] for i in range(0,len(parts)-1,5)]
wine=[x for x in records if x[-1]==b'wine']
assert len(wine)==1 and wine[0][0].decode()==sys.argv[2]
PYCASE
unfunction /bin/mv
[[ -z "$(/usr/bin/find "$COMPLEX" -name 'retained.env.tmp.*' -print)" ]]
for invalid_pid in '' 0 1 nope 999999999999; do
  LAUNCHED_WINE_PID="$invalid_pid"
  if publish_run_session; then print -u2 -- 'invalid PID accepted'; exit 1; fi
  [[ "$(<"$RUN_SESSION_FILE")" == "$old_session_text" ]]
done
LAUNCHED_WINE_PID=23456
WINDOWS_GAME_ROOT=$'IdentityVGlobal\nproduct=mainland'
if publish_run_session; then print -u2 -- 'newline field accepted'; exit 1; fi
WINDOWS_GAME_ROOT=IdentityVGlobal
foreign="$COMPLEX/foreign"
print -r -- keep >| "$foreign"
/bin/rm -f -- "$RUN_SESSION_FILE"
/bin/ln -s "$foreign" "$RUN_SESSION_FILE"
if publish_run_session; then print -u2 -- 'symlink accepted'; exit 1; fi
[[ "$(<"$foreign")" == keep && -L "$RUN_SESSION_FILE" ]]
print -r -- 'Session publication passed: child-only x86 injection, native resolver/control clean, fallback/PID retained, both products/modes, atomic 0600 and failed publication preservation; no Wine or game.'
