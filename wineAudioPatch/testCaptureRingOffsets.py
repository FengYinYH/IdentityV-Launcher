#!/usr/bin/env python3
"""Replay exact CW capture functions with synthetic PCM; no audio devices.

Usage: python3 testCaptureRingOffsets.py CURRENT_COREAUDIO NEW_OUTPUT
       [--upstream ORIGINAL_COREAUDIO]
The input hashes are fixed; output must be a new directory. The candidate only
normalizes the capture read offset and never changes an installed module.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

CURRENT_SHA = "ccd1db550dd16471e1f6df203e880928d1474aa82a42a9bc994d083f0baa3153"
UPSTREAM_SHA = "635347dcfc86800ed64737c6487a808836240e7846c6af699493e7a683d3f42c"
FUNCTIONS = ("ca_wrap_buffer", "ca_capture_cb", "buf_ptr_diff", "feed_cb", "capture_resample",
             "unix_get_capture_buffer", "unix_release_capture_buffer")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def exact_source(path, expected):
    data = path.read_bytes()
    if digest(data) != expected:
        raise SystemExit("Input source SHA256 mismatch: " + str(path))
    return data.decode()


def extract(source, name):
    # Known fixed C source has each function's closing brace in column zero.
    import re
    match = re.search(r"^static [^\n]+\b" + name + r"\(", source, re.M)
    if not match:
        raise SystemExit("Missing exact-source function: " + name)
    end = source.index("\n}\n", match.start()) + 3
    return source[match.start():end]


def run_case(root, label, source):
    directory = root / label
    directory.mkdir()
    functions = "\n".join(extract(source, name) for name in FUNCTIONS)
    (directory / "capture_functions.inc").write_text(functions)
    fixture = Path(__file__).with_name("repro") / "capture_ring_fixture.c"
    binary = directory / "fixture"
    command = ["/usr/bin/xcrun", "clang", "-std=c11", "-Wall", "-Wextra", "-Werror",
               "-Wno-unused-function", "-Wno-unused-parameter", "-Wno-sign-compare", "-g", "-O1",
               "-fsanitize=address,undefined", "-fno-omit-frame-pointer", "-I", str(directory),
               str(fixture), "-framework", "AudioToolbox", "-o", str(binary)]
    result = subprocess.run(command, capture_output=True, text=True)
    (directory / "compile.txt").write_text(result.stdout + result.stderr)
    result.check_returncode()
    mode = "candidate" if label == "candidate" else "original"
    result = subprocess.run([str(binary), mode], capture_output=True, text=True)
    (directory / "result.txt").write_text(result.stdout + result.stderr)
    result.check_returncode()
    print(result.stdout.strip())
    if mode == "original":
        fault = subprocess.run([str(binary), "unsafe-read"], capture_output=True, text=True)
        (directory / "original-invalid-read-asan.txt").write_text(fault.stdout + fault.stderr)
        if fault.returncode == 0 or "heap-buffer-overflow" not in fault.stderr:
            raise SystemExit("Original GetBuffer pointer did not reproduce expected ASan failure")
    # Keep this second, unchanged defect explicit. Do not silently widen the
    # modulo candidate to modify the realtime callback or add allocations.
    fault = subprocess.run([str(binary), "large-callback"], capture_output=True, text=True)
    (directory / "oversized-callback-asan.txt").write_text(fault.stdout + fault.stderr)
    if fault.returncode == 0 or "heap-buffer-overflow" not in fault.stderr:
        raise SystemExit("Oversized callback boundary did not reproduce expected separate defect")
    return {"sourceSha256": digest(source.encode()), "functionExcerptSha256": digest(functions.encode()),
            "normalCases": result.stdout.strip(), "oversizedCallback": "known separate ASan overflow; unchanged"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("current_source", type=Path)
    parser.add_argument("new_output", type=Path)
    parser.add_argument("--upstream", type=Path)
    args = parser.parse_args()
    source = exact_source(args.current_source, CURRENT_SHA)
    upstream = exact_source(args.upstream, UPSTREAM_SHA) if args.upstream else None
    root = args.new_output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    patch = Path(__file__).with_name("capture-ring-offset-normalization.patch")
    candidate_path = root / "coreaudio.c"
    subprocess.run(["/usr/bin/patch", "--silent", "-o", str(candidate_path),
                    str(args.current_source.resolve()), str(patch.resolve())], check=True)
    candidate = candidate_path.read_text()
    summary = {"patchSha256": digest(patch.read_bytes()), "current": run_case(root, "current", source),
               "candidate": run_case(root, "candidate", candidate)}
    if upstream:
        summary["upstream"] = run_case(root, "upstream", upstream)
    (root / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print("PASS: original-source failure / candidate sample-order and buffer-lifetime regression; no devices opened")


if __name__ == "__main__":
    main()
