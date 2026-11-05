#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h:h}"
RUNNER="$PROJECT_ROOT/gameRunnerApp/IdentityV-Mac.app/Contents/MacOS/launchIdentityVRunner"
AGTK_RUNNER="$PROJECT_ROOT/gameRunnerApp/IdentityV-AGTK.app/Contents/MacOS/launchIdentityVRunner"
TEST_ROOT="$(/usr/bin/mktemp -d /tmp/identityv-game-root-binding.XXXXXX)"
trap '/bin/rm -rf "$TEST_ROOT"' EXIT

[[ -x "$RUNNER" && -x "$AGTK_RUNNER" ]]
/usr/bin/cmp -s "$RUNNER" "$AGTK_RUNNER"

function_source="$(/usr/bin/awk '
  /^game_root_binding_is_valid\(\) \{/ { capture=1 }
  capture { print }
  capture && /^}/ { exit }
' "$RUNNER")"
[[ -n "$function_source" ]] || { print -u2 -- "cannot locate game_root_binding_is_valid"; exit 1; }
eval "$function_source"

physical_root="$TEST_ROOT/physical"
alias_root="$TEST_ROOT/alias"
game_dir="$physical_root/game"
managed_link="$TEST_ROOT/prefix/drive_c/Games/IdentityV"
/bin/mkdir -p "$game_dir" "${managed_link:h}" "$TEST_ROOT/foreign"
/bin/ln -s "$physical_root" "$alias_root"
/bin/ln -s "$alias_root/game" "$managed_link"

# The binding check is based on device/inode identity rather than a textual
# `realpath` spelling.  This same predicate accepts the startup Data volume's
# `/Users` and `/System/Volumes/Data/Users` aliases in the live RC.
game_root_binding_is_valid "$game_dir" "$managed_link"

/bin/rm "$managed_link"
/bin/ln -s "$TEST_ROOT/foreign" "$managed_link"
if game_root_binding_is_valid "$game_dir" "$managed_link"; then
  print -u2 -- "foreign game-root binding was accepted"
  exit 1
fi

/bin/rm "$managed_link"
/bin/mkdir -p "$managed_link"
if game_root_binding_is_valid "$game_dir" "$managed_link"; then
  print -u2 -- "real directory was accepted in place of the managed link"
  exit 1
fi

# Exercise the producer's real Codable representation, not a hand-authored
# object fixture: enum dictionary keys become an alternating key/value array.
for function_name in plist_raw product_installation_key_path; do
  function_source="$(/usr/bin/awk -v name="$function_name" '
    $0 == name "() {" { capture=1 }
    capture { print }
    capture && /^}/ { exit }
  ' "$RUNNER")"
  [[ -n "$function_source" ]]
  eval "$function_source"
done
products="$TEST_ROOT/products.json"
/usr/bin/xcrun swift -e '
import Foundation
enum ProductID: String, Codable { case mainland, global }
struct Location: Codable { let volumeUUID: String; let relativePath: String }
struct Installation: Codable { let prefix: Location; let gameRoot: Location }
struct State: Codable { let schemaVersion: Int; let installations: [ProductID: Installation] }
let record = Installation(prefix: Location(volumeUUID: "1234-ABCD", relativePath: "prefix"), gameRoot: Location(volumeUUID: "1234-ABCD", relativePath: "game"))
let data = try JSONEncoder().encode(State(schemaVersion: 1, installations: [.mainland: record, .global: record]))
FileHandle.standardOutput.write(data)
' >"$products"
[[ "$(/usr/bin/plutil -type installations "$products")" == "array" ]]
key_path="$(product_installation_key_path "$products" global)"
[[ "$(plist_raw "$products" "$key_path.prefix.relativePath")" == "prefix" ]]
[[ "$(plist_raw "$products" "$key_path.gameRoot.relativePath")" == "game" ]]

# Dictionary order is not a launch contract; the requested product must be found
# in either position. Missing, duplicate and malformed records fail closed.
for data in \
  '{"installations":["global",{},"mainland",{}]}' \
  '{"installations":["mainland",{},"global",{}]}' \
  '{"installations":["global",{}]}' \
  '{"installations":{"global":{}}}'; do
  print -r -- "$data" >"$products"
  [[ -n "$(product_installation_key_path "$products" global)" ]]
done
for data in \
  '{"installations":["mainland",{}]}' \
  '{"installations":["global",{},"global",{}]}' \
  '{"installations":["global"]}' \
  '{"installations":["global","invalid"]}' \
  '{"installations":["unknown",{},"global",{}]}' \
  '{"installations":{"global":"invalid"}}' \
  '{"installations":{}}'; do
  print -r -- "$data" >"$products"
  if product_installation_key_path "$products" global >/dev/null; then
    print -u2 -- "invalid product installation record was accepted: $data"
    exit 1
  fi
done

print -r -- "game-root APFS alias and product-state Codable binding self-test passed"
