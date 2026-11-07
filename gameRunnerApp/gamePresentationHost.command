#!/bin/zsh
# Sourced inside the final game child, before x86 injection/native flags.
# Native ARM mode only creates owner-side Info+symlink metadata; failure keeps
# the original verified Wine path and its existing profile environment.
identityv_prepare_game_presentation() {
  local name_manager resolved_name candidate
  case "${IDENTITYV_GAME_DISPLAY_NAME-}" in
    "Identity V"|"第五人格") ;;
    *)
      name_manager="$APP_CONTENTS/../../../Resources/IdentityVProductManager"
      resolved_name=""
      [[ ! -x "$name_manager" ]] || resolved_name="$("$name_manager" game-display-name 2>/dev/null)"
      case "$resolved_name" in
        "Identity V"|"第五人格") export IDENTITYV_GAME_DISPLAY_NAME="$resolved_name" ;;
        *) export IDENTITYV_GAME_DISPLAY_NAME="第五人格" ;;
      esac
      ;;
  esac
  export WINEPRELOADERAPPNAME="$IDENTITYV_GAME_DISPLAY_NAME"
  game_loader="$WINE_BIN"
  [[ "${LAUNCH_PROFILE-}" == codeweavers-wine-release-dxmt ]] || return 0
  if [[ ! -x "$APP_CONTENTS/MacOS/launchIdentityV" ]]; then
    print -u2 -r -- "IdentityV game host: metadata helper unavailable; using original loader"
    return 0
  fi
  if candidate="$("$APP_CONTENTS/MacOS/launchIdentityV" --prepare-game-host "$WINE_BIN" \
      "${CONFIG_DIR:-$HOME/Library/Application Support/IdentityVOnMac}/GameHosts" \
      "$PRODUCT" "$IDENTITYV_GAME_DISPLAY_NAME" "$LAUNCH_PROFILE")" &&
      [[ "$candidate" == /* && -L "$candidate" && "$candidate" -ef "$WINE_BIN" ]]; then
    game_loader="$candidate"
    export WINELOADER="$game_loader"
    print -u2 -r -- "IdentityV game host: localized metadata host ready"
  else
    print -u2 -r -- "IdentityV game host: unavailable; preserving original loader"
  fi
  return 0
}
