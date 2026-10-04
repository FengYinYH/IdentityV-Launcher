#!/usr/bin/env python3
"""Exercise the actual package audit: only the verified GDI DLL is allowed."""
import shutil
import subprocess
import tempfile
from pathlib import Path

repo = Path(__file__).resolve().parent.parent
source = (repo / "releasePackaging/buildAlpha1Preview.command").read_text()
definitions = source.split("typeset -a forbidden_patterns\n", 1)[1].split("\naudit_app_payload \"$app_stage\"", 1)[0]
code = "typeset -a forbidden_patterns\n" + definitions + '\nruntime_patch_audit="$1"\naudit_app_payload "$2"\n'
with tempfile.TemporaryDirectory(prefix="idv-package-payload-contract-") as temporary:
    app = Path(temporary) / "fixture.app"
    resources = app / "Contents/Resources"
    resources.mkdir(parents=True)
    shutil.copy2(repo / "runtimeBootstrap/runtime-manifest.json", resources / "runtime-manifest.json")
    shutil.copytree(repo / "runtimeBootstrap/releasePayloads", resources / "RuntimePatches")

    def audit():
        return subprocess.run(["/bin/zsh", "-c", code, "payload-audit-test",
                               str(repo / "runtimeBootstrap/verifyRuntimePatchPayloads.command"), str(app)],
                              capture_output=True, text=True)

    result = audit()
    assert result.returncode == 0, result.stdout + result.stderr
    extra = resources / "unexpected.dll"
    extra.write_bytes(b"unlicensed fixture")
    result = audit()
    assert result.returncode != 0 and "Forbidden game-payload extension" in result.stderr, result.stderr
    extra.unlink()
    (resources / "RuntimePatches/gdi32.dll").write_bytes(b"changed GDI fixture")
    result = audit()
    assert result.returncode != 0 and "runtime patch hash mismatch: gdi32.dll" in result.stderr, result.stderr
print("Package payload audit: verified GDI accepted; extra DLL and changed GDI rejected")
