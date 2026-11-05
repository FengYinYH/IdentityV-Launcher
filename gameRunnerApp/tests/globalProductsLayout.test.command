#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h:h}"
RUNNER="$PROJECT_ROOT/gameRunnerApp/IdentityV-Mac.app/Contents/MacOS/launchIdentityVRunner"
AGTK_RUNNER="$PROJECT_ROOT/gameRunnerApp/IdentityV-AGTK.app/Contents/MacOS/launchIdentityVRunner"
TEST_ROOT="$(/usr/bin/mktemp -d /tmp/identityv-global-products.XXXXXX)"
trap '/bin/rm -rf "$TEST_ROOT"' EXIT

[[ -x "$RUNNER" && -x "$AGTK_RUNNER" ]]
/usr/bin/cmp -s "$RUNNER" "$AGTK_RUNNER"

for function_name in plist_raw global_installation_raw; do
  function_source="$(/usr/bin/awk -v name="$function_name" '
    $0 ~ "^" name "\\(\\) \\{" { capture=1 }
    capture { print }
    capture && /^}/ { exit }
  ' "$RUNNER")"
  [[ -n "$function_source" ]] || { print -u2 -- "cannot locate $function_name"; exit 1; }
  eval "$function_source"
done

# Every global lookup must go through the layout-tolerant helper.
if /usr/bin/grep -q 'plist_raw "$PRODUCTS_FILE" "installations\.global\.[A-Za-z]' "$RUNNER"; then
  print -u2 -- "runner still reads products.json installations through an object-only key path"
  exit 1
fi

expect_field() {
  local field="$1" expected="$2" actual
  actual="$(global_installation_raw "$field")" || {
    print -u2 -- "global $field was not found in ${PRODUCTS_FILE:t}"
    exit 1
  }
  [[ "$actual" == "$expected" ]] || {
    print -u2 -- "global $field mismatch in ${PRODUCTS_FILE:t}: $actual"
    exit 1
  }
}

expect_all_fields() {
  expect_field prefix.volumeUUID "1B35B891-7DA3-467D-9204-053B7E74BC3F"
  expect_field prefix.relativePath "Users/player/Library/Application Support/IdentityVOnMac/Prefixes/global-0123456789abcdef0123"
  expect_field gameRoot.volumeUUID "1B35B891-7DA3-467D-9204-053B7E74BC3F"
  expect_field gameRoot.relativePath "Users/player/Library/Application Support/IdentityV/Global/game"
}

# ProductManager stores `[ProductID: Installation]` with Swift's default
# Dictionary coding. ProductID is a String-backed enum, so JSONEncoder emits a
# flat [key, value, ...] array. This is the exact shape of a fresh RC.4
# global-only install, including JSONEncoder's escaped slashes.
PRODUCTS_FILE="$TEST_ROOT/swift-array.json"
/bin/cat > "$PRODUCTS_FILE" <<'JSON'
{
  "installations" : [
    "global",
    {
      "gameRoot" : {
        "relativePath" : "Users\/player\/Library\/Application Support\/IdentityV\/Global\/game",
        "volumeUUID" : "1B35B891-7DA3-467D-9204-053B7E74BC3F"
      },
      "installedVersion" : "v3_1278_fixture",
      "prefix" : {
        "relativePath" : "Users\/player\/Library\/Application Support\/IdentityVOnMac\/Prefixes\/global-0123456789abcdef0123",
        "volumeUUID" : "1B35B891-7DA3-467D-9204-053B7E74BC3F"
      }
    }
  ],
  "schemaVersion" : 1,
  "selectedProductId" : "mainland"
}
JSON
expect_all_fields

# Both products installed: global is not the first pair.
PRODUCTS_FILE="$TEST_ROOT/swift-array-two-products.json"
/bin/cat > "$PRODUCTS_FILE" <<'JSON'
{
  "installations" : [
    "mainland",
    {
      "gameRoot" : { "relativePath" : "Users/player/IdentityV", "volumeUUID" : "00000000-0000-0000-0000-000000000000" },
      "prefix" : { "relativePath" : "Users/player/prefix-mainland", "volumeUUID" : "00000000-0000-0000-0000-000000000000" }
    },
    "global",
    {
      "gameRoot" : { "relativePath" : "Users/player/Library/Application Support/IdentityV/Global/game", "volumeUUID" : "1B35B891-7DA3-467D-9204-053B7E74BC3F" },
      "prefix" : { "relativePath" : "Users/player/Library/Application Support/IdentityVOnMac/Prefixes/global-0123456789abcdef0123", "volumeUUID" : "1B35B891-7DA3-467D-9204-053B7E74BC3F" }
    }
  ],
  "schemaVersion" : 1,
  "selectedProductId" : "global"
}
JSON
expect_all_fields

# A keyed object (hand-written or a future CodingKeyRepresentable ProductID)
# remains accepted.
PRODUCTS_FILE="$TEST_ROOT/object.json"
/bin/cat > "$PRODUCTS_FILE" <<'JSON'
{
  "installations" : {
    "global" : {
      "gameRoot" : { "relativePath" : "Users/player/Library/Application Support/IdentityV/Global/game", "volumeUUID" : "1B35B891-7DA3-467D-9204-053B7E74BC3F" },
      "prefix" : { "relativePath" : "Users/player/Library/Application Support/IdentityVOnMac/Prefixes/global-0123456789abcdef0123", "volumeUUID" : "1B35B891-7DA3-467D-9204-053B7E74BC3F" }
    }
  },
  "schemaVersion" : 1,
  "selectedProductId" : "global"
}
JSON
expect_all_fields

# A mainland-only record must not resolve a global binding, and a value
# position is never mistaken for a key.
PRODUCTS_FILE="$TEST_ROOT/mainland-only.json"
/bin/cat > "$PRODUCTS_FILE" <<'JSON'
{
  "installations" : [
    "mainland",
    {
      "gameRoot" : { "relativePath" : "Users/player/IdentityV", "volumeUUID" : "00000000-0000-0000-0000-000000000000" },
      "prefix" : { "relativePath" : "Users/player/prefix-mainland", "volumeUUID" : "00000000-0000-0000-0000-000000000000" }
    }
  ],
  "schemaVersion" : 1,
  "selectedProductId" : "mainland"
}
JSON
if global_installation_raw prefix.volumeUUID >/dev/null; then
  print -u2 -- "mainland-only products.json resolved a global prefix"
  exit 1
fi

PRODUCTS_FILE="$TEST_ROOT/value-named-global.json"
/bin/cat > "$PRODUCTS_FILE" <<'JSON'
{ "installations" : [ "mainland", "global" ], "schemaVersion" : 1, "selectedProductId" : "mainland" }
JSON
if global_installation_raw prefix.volumeUUID >/dev/null; then
  print -u2 -- "a value slot named global was treated as a key"
  exit 1
fi

print -r -- "global products.json layout self-test passed"
