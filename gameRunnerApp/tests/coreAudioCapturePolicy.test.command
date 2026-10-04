#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h:h}"
RUNNER="$PROJECT_ROOT/gameRunnerApp/IdentityV-Mac.app/Contents/MacOS/launchIdentityVRunner"
AGTK_RUNNER="$PROJECT_ROOT/gameRunnerApp/IdentityV-AGTK.app/Contents/MacOS/launchIdentityVRunner"
CATALOG="$PROJECT_ROOT/runtimeManifest/runtime-catalog.json"
MAC_CATALOG="$PROJECT_ROOT/gameRunnerApp/IdentityV-Mac.app/Contents/Resources/runtime-catalog.json"
AGTK_CATALOG="$PROJECT_ROOT/gameRunnerApp/IdentityV-AGTK.app/Contents/Resources/runtime-catalog.json"

[[ -x "$RUNNER" && -x "$AGTK_RUNNER" && -r "$CATALOG" ]]
/usr/bin/cmp -s "$RUNNER" "$AGTK_RUNNER"
/usr/bin/cmp -s "$CATALOG" "$MAC_CATALOG"
/usr/bin/cmp -s "$CATALOG" "$AGTK_CATALOG"

# Catch catalog/manifest drift before the full App build. Runtime catalog files
# may be verified against either the original source bytes or the final patched
# bytes; status-only records intentionally describe files that are not bundled.
/usr/bin/python3 - "$PROJECT_ROOT" <<'PY'
import copy
import json
import re
import sys
import tempfile
from pathlib import Path

root = Path(sys.argv[1])
catalog_path = root / "runtimeManifest/runtime-catalog.json"
manifest_path = root / "runtimeBootstrap/runtime-manifest.json"

def validate(catalog, manifest):
    engines = catalog["engines"]
    for engine_id, engine in engines.items():
        for key, record in engine.get("verificationFiles", {}).items():
            if "relativePath" not in record:
                assert "sha256" not in record, f"{engine_id}.{key}: status-only record cannot have a digest"
                continue
            digest = record.get("sha256", "")
            assert re.fullmatch(r"[0-9a-f]{64}", digest), f"{engine_id}.{key}: digest must be 64 lowercase hex characters"

    defaults = [
        (engine_id, engine)
        for engine_id, engine in engines.items()
        if engine.get("candidateSelection", {}).get("productDefault") is True
    ]
    assert len(defaults) == 1, "catalog must have exactly one product default"
    engine_id, engine = defaults[0]
    assert engine["candidateSelection"].get("runtimeVersion") == manifest.get("version"), \
        "product default runtime version must match bootstrap manifest"

    manifest_files = {
        item["relativePath"]: item["sha256"]
        for field in ("sourceVerificationFiles", "finalVerificationFiles")
        for item in manifest.get(field, [])
    }
    catalog_files = {
        record["relativePath"]: record["sha256"]
        for record in engine.get("verificationFiles", {}).values()
        if "relativePath" in record
    }
    for relative_path, digest in catalog_files.items():
        assert manifest_files.get(relative_path) == digest, \
            f"product default digest differs from bootstrap manifest: {relative_path}"
    for relative_path, digest in {
        item["relativePath"]: item["sha256"]
        for item in manifest.get("finalVerificationFiles", [])
    }.items():
        assert catalog_files.get(relative_path) == digest, \
            f"bootstrap final file missing or differs in product catalog: {relative_path}"

catalog = json.loads(catalog_path.read_text())
manifest = json.loads(manifest_path.read_text())
validate(catalog, manifest)

# A one-character truncation of a real default DXMT digest must fail this same
# contract. Use a temporary catalog fixture; no runtime files are copied.
fixture = copy.deepcopy(catalog)
default_engine = next(
    engine for engine in fixture["engines"].values()
    if engine.get("candidateSelection", {}).get("productDefault") is True
)
dxmt = next(
    record for record in default_engine["verificationFiles"].values()
    if record.get("relativePath", "").endswith("/winemetal.so")
)
dxmt["sha256"] = dxmt["sha256"][:-1]
with tempfile.TemporaryDirectory(prefix="coreaudio-catalog-contract-") as temporary:
    fixture_path = Path(temporary) / "catalog.json"
    fixture_path.write_text(json.dumps(fixture))
    try:
        validate(json.loads(fixture_path.read_text()), manifest)
    except AssertionError as error:
        assert "64 lowercase hex" in str(error), f"fixture failed for an unexpected reason: {error}"
    else:
        raise AssertionError("one-character DXMT digest truncation was accepted")

print("Runtime catalog/manifest cross-file contract and truncated-DXMT negative test passed")
PY

# The first case establishes a default before user settings load; the second
# one is the authoritative, post-settings policy gate.  Execute that exact
# runner fragment in a local shell so stale launcher.env values cannot silently
# become an alternative implementation of the contract.
typeset -i policy_case_count=0
policy_case_count="$(/usr/bin/grep -Fxc 'case "$CORE_AUDIO_CAPTURE_POLICY" in' "$RUNNER" || true)"
[[ "$policy_case_count" == 2 ]] || {
  print -u2 -- "expected separate default and post-settings CoreAudio policy gates"
  exit 1
}
policy_source="$(/usr/bin/awk '
  /^case "\$CORE_AUDIO_CAPTURE_POLICY" in$/ { count++; capture = (count == 2) }
  capture { print }
  capture && /^esac$/ { exit }
' "$RUNNER")"
[[ -n "$policy_source" ]] || { print -u2 -- "cannot locate post-settings CoreAudio policy gate"; exit 1; }

resolve_stage() {
  local policy="$1" stage="$2" legacy="$3"
  CORE_AUDIO_CAPTURE_POLICY="$policy"
  IDENTITYV_AUDIO_INTERPOSER_STAGE="$stage"
  IDENTITYV_DEFAULT_INPUT_ONLY="$legacy"
  eval "$policy_source"
  print -r -- "$IDENTITYV_AUDIO_INTERPOSER_STAGE"
}

# Existing Wine 11 runtimes have no source-level device filter.  Their policy
# must win over both an old explicit `off` and the discontinued legacy switch.
[[ "$(resolve_stage rebinder-filter-required off 1)" == rebinder-filter ]]
[[ "$(resolve_stage rebinder-filter-required filter 0)" == rebinder-filter ]]
/usr/bin/plutil -extract 'engines.wine11-codeweavers-26_1-dxmt-0_80-macos15-alpha1-r1.capabilities.coreAudioCapturePolicy' raw -o - "$CATALOG" | /usr/bin/grep -qx 'rebinder-filter-required'

# r4's source-level default-input implementation must never receive an old
# rebinder/filter dylib in addition, even if either legacy setting persisted.
[[ "$(resolve_stage runtime-default-input-only rebinder-filter 0)" == off ]]
[[ "$(resolve_stage runtime-default-input-only filter 1)" == off ]]
[[ "$(resolve_stage runtime-default-device-following rebinder-filter 0)" == off ]]
[[ "$(resolve_stage runtime-default-device-following filter 1)" == off ]]
/usr/bin/plutil -extract 'engines.wine11-codeweavers-26_1-dxmt-0_80-macos15-alpha1-r1-emoji2-audio-default-following-20261004.capabilities.coreAudioCapturePolicy' raw -o - "$CATALOG" | /usr/bin/grep -qx 'runtime-default-device-following'
/usr/bin/plutil -extract 'engines.wine11-codeweavers-26_1-dxmt-0_80-macos15-alpha1-r1-emoji2-audio-default-following-20261004.candidateSelection.fallbackEngineId' raw -o - "$CATALOG" | /usr/bin/grep -qx 'wine11-codeweavers-26_1-dxmt-0_80-macos15-alpha1-r1-emoji2-audio1'
/usr/bin/plutil -extract 'engines.wine11-codeweavers-26_1-dxmt-0_80-macos15-alpha1-r1-emoji2-audio1.candidateSelection.productDefault' raw -o - "$CATALOG" | /usr/bin/grep -qx false
/usr/bin/plutil -extract 'engines.wine11-codeweavers-26_1-dxmt-0_80-macos15-alpha1-r1-emoji2-audio-default-following-20261004.candidateSelection.productDefault' raw -o - "$CATALOG" | /usr/bin/grep -qx true

# The fallback policy intentionally preserves maintenance overrides, including
# the old flag's off -> filter translation.
[[ "$(resolve_stage unmanaged rebinder 1)" == rebinder ]]
[[ "$(resolve_stage unmanaged off 1)" == filter ]]
[[ "$(resolve_stage unmanaged rebinder-filter 0)" == rebinder-filter ]]

print -r -- "CoreAudio capture policy self-test passed"
