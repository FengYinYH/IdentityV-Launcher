#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h:h}"
RUNNER="$ROOT/gameRunnerApp/IdentityV-Mac.app/Contents/MacOS/launchIdentityVRunner"
AGTK_RUNNER="$ROOT/gameRunnerApp/IdentityV-AGTK.app/Contents/MacOS/launchIdentityVRunner"
TEST_ROOT="$(/usr/bin/mktemp -d /tmp/identityv-native-contract.XXXXXX)"
cleanup_contract() {
  [[ -z "${LAUNCHED_WINE_PID:-}" ]] || wait "$LAUNCHED_WINE_PID" 2>/dev/null || true
  local resolved="$(/bin/realpath "$TEST_ROOT")"
  [[ "$resolved" == /private/tmp/identityv-native-contract.* && -d "$resolved" && ! -L "$TEST_ROOT" ]] || return 1
  /bin/rm -rf -- "${TEST_ROOT:?}"
}
trap cleanup_contract EXIT
/usr/bin/cmp -s "$RUNNER" "$AGTK_RUNNER"

# Non-SIP ARM helpers must really execute, rather than have SIP silently strip
# leaked DYLD variables. The final Wine stand-in really loads an x86-only DSO.
cat > "$TEST_ROOT/probe.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static const char *value(const char *key) { const char *p=getenv(key);return p?p:"unset"; }
static void field(FILE *out,const char *s) { fputs(s,out);fputc(0,out); }
int main(int argc,char **argv) {
 const char *role=argc==2&&!strcmp(argv[1],"game-display-name")?"resolver":argc==2&&!strcmp(argv[1],"--control")?"control":"wine";
 FILE *out=fopen(value("IDV_TEST_NATIVE_OUTPUT"),"ab");if(!out)return 2;
 char pid[32];snprintf(pid,sizeof(pid),"%ld",(long)getpid());
 field(out,role);field(out,pid);field(out,value("DYLD_INSERT_LIBRARIES"));
 field(out,value("DYLD_FALLBACK_LIBRARY_PATH"));field(out,value("IDENTITYV_NATIVE_CAMERA_CLIP"));
 field(out,value("IDENTITYV_FOREGROUND_WARP_GATE"));field(out,value("IDENTITYV_WARP_GATE_AUDIT"));
 field(out,value("IDV_TEST_NATIVE_LOADED"));field(out,value("WINEPRELOADERAPPNAME"));
 field(out,argc>1?argv[1]:"");field(out,argc>1?argv[argc-1]:"");
 if(fclose(out))return 3;if(!strcmp(role,"resolver"))puts("Identity V");return 0;
}
C
cat > "$TEST_ROOT/native.c" <<'C'
#include <stdlib.h>
__attribute__((constructor)) static void loaded(void) { setenv("IDV_TEST_NATIVE_LOADED","1",1); }
C
cat > "$TEST_ROOT/noop.c" <<'C'
int idv_contract_noop(void) {return 0;}
C
COMPLEX="$TEST_ROOT/"$'引号 空格\'"\\路径\n换行'
APP_CONTENTS="$COMPLEX/Launcher.app/Contents/Helpers/Runner.app/Contents"
/bin/mkdir -p "$APP_CONTENTS/Resources" "$COMPLEX/Launcher.app/Contents/Resources"
NATIVE_CAMERA_COMPAT="$APP_CONTENTS/Resources/IdentityVNativeCameraCompat.dylib"
COMMAND_GRAVE_FORWARDER="$COMPLEX/forwarder.dylib"
NATIVE_CONTROL="$COMPLEX/Launcher.app/Contents/Resources/IdentityVProductManager"
WINE_BIN="$COMPLEX/wine-probe"
for architecture in arm64 x86_64; do
  [[ "$architecture" == arm64 ]] && output="$NATIVE_CONTROL" || output="$WINE_BIN"
  /usr/bin/clang -arch "$architecture" -mmacosx-version-min=14.0 -Wall -Wextra -Werror "$TEST_ROOT/probe.c" -o "$output"
done
/usr/bin/clang -arch x86_64 -dynamiclib -mmacosx-version-min=14.0 -Wall -Wextra -Werror "$TEST_ROOT/native.c" -o "$NATIVE_CAMERA_COMPAT"
/usr/bin/clang -arch x86_64 -dynamiclib -mmacosx-version-min=14.0 -Wall -Wextra -Werror "$TEST_ROOT/noop.c" -o "$COMMAND_GRAVE_FORWARDER"

AUDIO_INTERPOSER=""
IDV_LOGIN_START_HELPER="$TEST_ROOT/no-login-helper"
LOGIN_DNS_COMPAT="$TEST_ROOT/no-dns"
INPUT_TRACE_ONCE_MARKER="$TEST_ROOT/no-input-marker"
GAME_LAUNCH_ARGUMENTS=(--contract-final-child)
IDENTITYV_DESKTOP_NAME=IdentityV
IDENTITYV_DESKTOP_SIZE=1920x1080
METAL_HUD_ENABLED=0
LOG_FILE="$TEST_ROOT/runner.log"
export DYLD_FALLBACK_LIBRARY_PATH=fixture-fallback
export IDV_TEST_NATIVE_OUTPUT="$TEST_ROOT/records"
unset DYLD_INSERT_LIBRARIES IDV_TEST_NATIVE_LOADED IDENTITYV_WARP_GATE_AUDIT

for runner in "$RUNNER" "$AGTK_RUNNER"; do
  # Require the actual resource path and preflight policy, then execute that
  # exact guard against good/missing/symlink/directory fixture resources.
  /usr/bin/grep -Fxq 'NATIVE_CAMERA_COMPAT="$APP_CONTENTS/Resources/IdentityVNativeCameraCompat.dylib"' "$runner"
  preflight_source="$(/usr/bin/sed -n '/^\[\[ -f "\$NATIVE_CAMERA_COMPAT" .*abort_launcher /p' "$runner")"
  [[ -n "$preflight_source" ]]
  abort_launcher() { return 71; }
  eval "$preflight_source"
  saved_resource="$NATIVE_CAMERA_COMPAT"
  /bin/ln -s "$saved_resource" "$TEST_ROOT/resource-link"
  for invalid_resource in "$TEST_ROOT/missing" "$TEST_ROOT/resource-link" "$APP_CONTENTS/Resources"; do
    NATIVE_CAMERA_COMPAT="$invalid_resource"
    if eval "$preflight_source"; then print -u2 -- 'unsafe or absent adapter resource accepted'; exit 1; fi
  done
  NATIVE_CAMERA_COMPAT="$saved_resource"
  # The one link is reused by the second canonical runner.
  [[ ! -L "$TEST_ROOT/resource-link" ]] || { resolved_link="$(/bin/realpath "$TEST_ROOT/resource-link")"; [[ "$resolved_link" == "$(/bin/realpath "$saved_resource")" ]]; /bin/unlink "$TEST_ROOT/resource-link"; }
  eval "$(/usr/bin/sed -n '/^publish_run_session() {/,/^}/p' "$runner")"
  eval "$(/usr/bin/sed -n '/^launch_game_once() {/,/^}/p' "$runner")"
  for PRODUCT in mainland global; do
    [[ "$PRODUCT" == mainland ]] && WINDOWS_GAME_ROOT=IdentityV || WINDOWS_GAME_ROOT=IdentityVGlobal
    for IDENTITYV_USE_VIRTUAL_DESKTOP in 0 1; do
      for setting in default both-off native-only background-only empty-default; do
        unset IDENTITYV_NATIVE_CAMERA_CLIP IDENTITYV_FOREGROUND_WARP_GATE IDENTITYV_GAME_DISPLAY_NAME WINEPRELOADERAPPNAME
        case "$setting" in
          both-off) export IDENTITYV_NATIVE_CAMERA_CLIP=0 IDENTITYV_FOREGROUND_WARP_GATE=0 ;;
          native-only) export IDENTITYV_NATIVE_CAMERA_CLIP=1 IDENTITYV_FOREGROUND_WARP_GATE=0 ;;
          background-only) export IDENTITYV_NATIVE_CAMERA_CLIP=0 IDENTITYV_FOREGROUND_WARP_GATE=1 ;;
          empty-default) export IDENTITYV_NATIVE_CAMERA_CLIP='' IDENTITYV_FOREGROUND_WARP_GATE='' ;;
        esac
        RUN_SESSION_FILE="$TEST_ROOT/session.env"
        : >| "$IDV_TEST_NATIVE_OUTPUT"
        launch_game_once
        captured_pid="$LAUNCHED_WINE_PID"
        wait "$captured_pid"
        [[ "${DYLD_INSERT_LIBRARIES-unset}" == unset && "${IDV_TEST_NATIVE_LOADED-unset}" == unset ]]
        if [[ "$setting" == default ]]; then
          [[ "${IDENTITYV_NATIVE_CAMERA_CLIP-unset}" == unset && "${IDENTITYV_FOREGROUND_WARP_GATE-unset}" == unset ]]
        fi
        "$NATIVE_CONTROL" --control
        python3 - "$IDV_TEST_NATIVE_OUTPUT" "$setting" "$IDENTITYV_USE_VIRTUAL_DESKTOP" "$captured_pid" "$COMMAND_GRAVE_FORWARDER" "$NATIVE_CAMERA_COMPAT" "$WINDOWS_GAME_ROOT" <<'PY'
import pathlib,sys
raw=pathlib.Path(sys.argv[1]).read_bytes().split(b'\0');assert raw[-1]==b'' and (len(raw)-1)%11==0
rows=[[v.decode() for v in raw[i:i+11]] for i in range(0,len(raw)-1,11)]
setting,desktop,pid,forwarder,adapter,game=sys.argv[2:]
wine=[r for r in rows if r[0]=='wine'];native=[r for r in rows if r[0]!='wine'];assert len(wine)==1,rows
r=wine[0];assert r[1]==pid and r[3]=='fixture-fallback'
expected={'default':('1','1'),'empty-default':('1','1'),'both-off':('0','0'),'native-only':('1','0'),'background-only':('0','1')}[setting]
assert tuple(r[4:6])==expected and r[6]=='unset',r
libs=r[2].split(':');assert libs==([forwarder] if setting=='both-off' else [forwarder,adapter]),r
assert r[7]==('unset' if setting=='both-off' else '1'),r # DSO actually loaded
assert r[10]=='--contract-final-child' and r[9]==('explorer' if desktop=='1' else 'C:\\Games\\'+game+'\\dwrg.exe'),r
assert len(native)==(1 if desktop=='1' else 2),rows
assert [n[0] for n in native]==(['control'] if desktop=='1' else ['resolver','control'])
parent={'default':('unset','unset'),'empty-default':('',''),'both-off':('0','0'),'native-only':('1','0'),'background-only':('0','1')}[setting]
for n in native:
 assert n[2]=='unset' and n[7]=='unset' and n[6]=='unset',n
 assert tuple(n[4:6])==parent,n # final-child defaults never poison ARM control
 assert n[3]=='fixture-fallback',n
PY
      done
    done
  done
done
print -r -- 'Native camera contract passed: 40 final x86 Wine children, both canonical runners/products/modes, Native/BG defaults and independent opt-out, exact regular resource, real DSO load, clean ARM resolver/control, PID/fallback retained; no Wine/game/HID.'
