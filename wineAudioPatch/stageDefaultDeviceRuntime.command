#!/usr/bin/env python3
"""Clone a verified audio1 runtime into a new, explicit local audio candidate.

This is a maintainer staging operation, not an installer or a product-default
selector. It never changes a current link, prefix, source runtime or App.
"""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(block)
    return checksum.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-tree", required=True, type=Path)
    parser.add_argument("--module", required=True, type=Path)
    parser.add_argument("--bootstrap", required=True, type=Path)
    parser.add_argument("--destination", required=True, type=Path)
    args = parser.parse_args()
    project = Path(__file__).resolve().parent.parent
    for path in (args.source_tree, args.module, args.bootstrap, args.destination):
        if not path.is_absolute():
            parser.error("all paths must be absolute")
    if args.destination.exists() or args.destination.is_symlink():
        parser.error("destination must not exist; never overwrite a candidate")
    if not args.source_tree.is_dir() or not args.module.is_file():
        parser.error("source tree and module must exist")
    if not args.bootstrap.is_file() or not os.access(args.bootstrap, os.X_OK):
        parser.error("bootstrap must be an existing executable")
    source = args.source_tree.resolve(strict=True)
    destination = args.destination.resolve()
    if source in destination.parents or destination in source.parents:
        parser.error("source and destination must be separate trees")
    # A missing external volume must not become an ordinary /Volumes directory.
    if str(destination).startswith("/Volumes/"):
        volume = Path("/Volumes") / destination.parts[2]
        if not os.path.ismount(volume):
            parser.error("destination external volume is not mounted")
    manifest_path = project / "runtimeBootstrap/runtime-manifest.json"
    manifest = json.loads(manifest_path.read_text())
    expected_version = "wine11-codeweavers-26.1-dxmt-0.80-macos15-alpha1-r1-emoji2-audio1"
    if manifest["version"] != expected_version:
        parser.error("rebase this staging tool for a changed runtime baseline")
    subprocess.run([str(args.bootstrap), "verify-tree", "--manifest", str(manifest_path),
                    "--tree", str(source)], check=True)
    unsigned_hash = digest(args.module)
    destination.mkdir(parents=True, exist_ok=False)
    tree = destination / "runtime"
    # Keep a failed staging directory as evidence; a retry needs a new root.
    shutil.copytree(source, tree, symlinks=True)
    (tree / ".DS_Store").unlink(missing_ok=True)
    relative_module = "lib/wine/x86_64-unix/winecoreaudio.so"
    staged_module = tree / relative_module
    if staged_module.is_symlink():
        raise RuntimeError("refusing a symlink module target")
    shutil.copyfile(args.module, staged_module)
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(staged_module)], check=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(staged_module)], check=True)
    signed_hash = digest(staged_module)
    version = "wine11-codeweavers-26.1-dxmt-0.80-macos15-alpha1-r1-emoji2-audio-default-following-20261004"
    manifest["version"] = version
    for patch in manifest["patches"]:
        if patch["targetRelativePath"] == relative_module:
            patch["sourceSha256"] = unsigned_hash
            patch["sha256"] = signed_hash
    for entry in manifest["finalVerificationFiles"]:
        if entry["relativePath"] == relative_module:
            entry["sha256"] = signed_hash
    candidate_manifest = destination / "runtime-manifest.json"
    candidate_manifest.write_text(json.dumps(manifest, indent=2) + "\n")
    catalog = json.loads((project / "runtimeManifest/runtime-catalog.json").read_text())
    baseline_id = expected_version.replace("26.1", "26_1").replace("0.80", "0_80")
    candidate = copy.deepcopy(catalog["engines"][baseline_id])
    candidate["capabilities"]["coreAudioCapturePolicy"] = "runtime-default-input-only"
    candidate["version"]["candidateRevision"] = "default-input-output-following-x86_64-local-adhoc"
    candidate["verificationFiles"]["winecoreaudio"]["sha256"] = signed_hash
    candidate["candidateSelection"].update(productDefault=False, runtimeVersion=version,
                                         activation="explicit-isolated-prefix-only")
    catalog["engines"][version.replace("26.1", "26_1").replace("0.80", "0_80")] = candidate
    (destination / "runtime-catalog.json").write_text(json.dumps(catalog, indent=2) + "\n")
    subprocess.run([str(args.bootstrap), "verify-tree", "--manifest", str(candidate_manifest),
                    "--tree", str(tree)], check=True)
    (destination / "candidate-provenance.json").write_text(json.dumps({
        "baselineVersion": expected_version, "candidateVersion": version,
        "unsignedModuleSha256": unsigned_hash, "stagedModuleSha256": signed_hash,
        "moduleSigning": "ad-hoc-local-only", "activeRuntimeChanged": False,
        "gameOrWineStarted": False,
    }, indent=2) + "\n")
    print(f"Staged isolated runtime: {tree}")


if __name__ == "__main__":
    main()
