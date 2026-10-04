#!/usr/bin/env python3
"""Clone a verified audio1 runtime using the product's signed audio-following patch.

This prepares a new immutable local runtime tree. It never changes a current link,
runtime binding, prefix, source runtime or App, and it never starts Wine.
"""
import argparse
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
    parser.add_argument("--source-module", required=True, type=Path,
                        help="unsigned, stripped module whose SHA is manifest sourceSha256")
    parser.add_argument("--bootstrap", required=True, type=Path)
    parser.add_argument("--destination", required=True, type=Path)
    parser.add_argument("--volume-mount", required=True, type=Path,
                        help="mounted external volume containing the destination")
    parser.add_argument("--volume-uuid", required=True,
                        help="expected DiskUUID of that mounted volume")
    parser.add_argument("--base-manifest", type=Path,
                        help="audio1 manifest used to verify the unchanged source runtime")
    parser.add_argument("--manifest", type=Path,
                        help="product audio-following manifest (defaults to runtimeBootstrap/runtime-manifest.json)")
    parser.add_argument("--catalog", type=Path,
                        help="product runtime catalog (defaults to runtimeManifest/runtime-catalog.json)")
    parser.add_argument("--signing-identity", default="Developer ID Application: Qingxiong Yang (VNTCB2984V)")
    args = parser.parse_args()
    project = Path(__file__).resolve().parent.parent
    args.base_manifest = args.base_manifest or project / "runtimeBootstrap/candidates/audio1/runtime-manifest.json"
    args.manifest = args.manifest or project / "runtimeBootstrap/runtime-manifest.json"
    args.catalog = args.catalog or project / "runtimeManifest/runtime-catalog.json"
    for path in (args.source_tree, args.module, args.source_module, args.bootstrap,
                 args.destination, args.volume_mount, args.base_manifest, args.manifest, args.catalog):
        if not path.is_absolute():
            parser.error("all paths must be absolute")
    if args.destination.exists() or args.destination.is_symlink():
        parser.error("destination must not exist; never overwrite a candidate")
    if (not args.source_tree.is_dir() or not args.module.is_file() or args.module.is_symlink()
            or not args.source_module.is_file() or args.source_module.is_symlink()):
        parser.error("source tree and regular module files must exist")
    if not args.bootstrap.is_file() or not os.access(args.bootstrap, os.X_OK):
        parser.error("bootstrap must be an existing executable")
    for path in (args.base_manifest, args.manifest, args.catalog):
        if not path.is_file() or path.is_symlink():
            parser.error(f"manifest/catalog input must be a regular file: {path}")
    source = args.source_tree.resolve(strict=True)
    destination = args.destination.resolve()
    if source in destination.parents or destination in source.parents:
        parser.error("source and destination must be separate trees")
    volume_mount = args.volume_mount.resolve(strict=True)
    if not args.volume_uuid or not volume_mount.is_dir() or volume_mount == Path("/"):
        parser.error("volume mount and expected UUID must identify an existing external volume")
    try:
        volume_info = subprocess.run(["/usr/sbin/diskutil", "info", "-plist", str(volume_mount)],
                                     capture_output=True, check=True).stdout
        actual_uuid = subprocess.run(["/usr/bin/plutil", "-extract", "DiskUUID", "raw", "-o", "-", "-"],
                                     input=volume_info, capture_output=True, check=True, text=True).stdout.strip()
        actual_mount = subprocess.run(["/usr/bin/plutil", "-extract", "MountPoint", "raw", "-o", "-", "-"],
                                      input=volume_info, capture_output=True, check=True, text=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError) as error:
        parser.error(f"cannot verify the external volume identity: {error}")
    if actual_uuid.casefold() != args.volume_uuid.casefold() or Path(actual_mount) != volume_mount:
        parser.error("external volume mount or UUID does not match the caller-supplied identity")
    if volume_mount not in destination.parents:
        parser.error("destination must be a new directory inside the verified external volume")
    base_manifest = json.loads(args.base_manifest.read_text())
    manifest = json.loads(args.manifest.read_text())
    catalog = json.loads(args.catalog.read_text())
    base_version = "wine11-codeweavers-26.1-dxmt-0.80-macos15-alpha1-r1-emoji2-audio1"
    version = "wine11-codeweavers-26.1-dxmt-0.80-macos15-alpha1-r1-emoji2-audio-default-following-20261004"
    base_id = base_version.replace("26.1", "26_1").replace("0.80", "0_80")
    engine_id = version.replace("26.1", "26_1").replace("0.80", "0_80")
    if base_manifest["version"] != base_version or manifest["version"] != version:
        parser.error("the explicit base/product manifests do not match the audio1 -> default-following version contract")
    if (base_manifest["source"] != manifest["source"]
            or base_manifest["sourceVerificationFiles"] != manifest["sourceVerificationFiles"]):
        parser.error("upstream source identity changed; this audio-only staging script cannot rebase it")
    subprocess.run([str(args.bootstrap), "verify-tree", "--manifest", str(args.base_manifest),
                    "--tree", str(source)], check=True)
    relative_module = "lib/wine/x86_64-unix/winecoreaudio.so"
    audio_patch = next((item for item in manifest["patches"]
                        if item["targetRelativePath"] == relative_module), None)
    if not audio_patch:
        parser.error("product manifest has no winecoreaudio patch entry")
    unsigned_hash = digest(args.source_module)
    signed_hash = digest(args.module)
    if unsigned_hash != audio_patch.get("sourceSha256") or signed_hash != audio_patch.get("sha256"):
        parser.error("unsigned source or signed module SHA-256 does not match the product manifest")
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(args.module)], check=True)
    signature = subprocess.run(["/usr/bin/codesign", "-dv", "--verbose=4", str(args.module)],
                               capture_output=True, text=True, check=True).stderr
    if (f"Authority={args.signing_identity}" not in signature
            or "TeamIdentifier=VNTCB2984V" not in signature
            or "flags=0x10000(runtime)" not in signature):
        parser.error("audio module signature does not match the expected Developer ID/runtime contract")

    defaults = [key for key, value in catalog["engines"].items()
                if value.get("candidateSelection", {}).get("productDefault") is True]
    audio1_engine = catalog["engines"].get(base_id)
    following_engine = catalog["engines"].get(engine_id)
    if (defaults != [engine_id] or not audio1_engine or not following_engine
            or audio1_engine["candidateSelection"].get("productDefault") is not False
            or following_engine["candidateSelection"].get("runtimeVersion") != version
            or following_engine["candidateSelection"].get("fallbackEngineId") != base_id
            or following_engine["capabilities"].get("coreAudioCapturePolicy") != "runtime-default-device-following"
            or following_engine["verificationFiles"].get("winecoreaudio", {}).get("sha256") != signed_hash):
        parser.error("catalog must make the new engine the unique default and retain audio1 as fallback")

    destination.mkdir(parents=True, exist_ok=False)
    tree = destination / "runtime"
    # Keep a failed staging directory as evidence; a retry needs a new root.
    shutil.copytree(source, tree, symlinks=True)
    (tree / ".DS_Store").unlink(missing_ok=True)
    staged_module = tree / relative_module
    if staged_module.is_symlink():
        raise RuntimeError("refusing a symlink module target")
    shutil.copyfile(args.module, staged_module)
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(staged_module)], check=True)
    candidate_manifest = destination / "runtime-manifest.json"
    shutil.copyfile(args.manifest, candidate_manifest)
    shutil.copyfile(args.catalog, destination / "runtime-catalog.json")
    subprocess.run([str(args.bootstrap), "verify-tree", "--manifest", str(candidate_manifest),
                    "--tree", str(tree)], check=True)
    (destination / "candidate-provenance.json").write_text(json.dumps({
        "baselineVersion": base_version, "candidateVersion": version,
        "unsignedModuleSha256": unsigned_hash, "stagedModuleSha256": signed_hash,
        "moduleSigning": "developer-id-runtime-timestamped", "activeRuntimeChanged": False,
        "gameOrWineStarted": False,
    }, indent=2) + "\n")
    print(f"Staged isolated runtime: {tree}")


if __name__ == "__main__":
    main()
