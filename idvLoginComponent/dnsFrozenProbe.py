#!/usr/bin/env python3
"""Build/run a harmless onefile probe with the exact upstream frozen module.

Requires PyInstaller 6.x in the invoking Python. Downloads only fixed public
source (or accepts --upstream-source); it never runs the official proxy binary.
All probe build products are temporary and removed after the result is printed.
"""
import argparse
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
import urllib.request

SOURCE_SHA256 = "76db39b43920e0f5ffc32cfd101c22717c2c04baa8dc9c86f11a69f4d1c1f47e"
SOURCE_URL = "https://raw.githubusercontent.com/KKeygen/idv-login/0cee1f6b5c03b93d999a94bfc6e4baf745456d1b/src/mitm_proxy.py"
RUNNER = r'''
import importlib.abc
import importlib.util
import sys
import socket

# Same source-file meta finder used by official hotfixmgr. PyiFrozenFinder is
# reached through PathFinder's path hooks when the overlay loads the original.
class OverlayFinder(importlib.abc.MetaPathFinder):
    def find_spec(self, fullname, path=None, target=None):
        if fullname == "mitm_proxy":
            return importlib.util.spec_from_file_location(fullname, sys.argv[1])

sys.meta_path.insert(0, OverlayFinder())
assert getattr(sys, "frozen", False)
import mitm_proxy as m
assert m.MitmProxyManager.__module__ == "mitm_proxy"
assert m.resolve_domain_ip.__globals__ is m.__dict__
assert m._idv_original_query.__globals__ is m.__dict__
assert m._query_upstream_parallel is m._idv_original_query
assert m.socket is socket
assert m.COMPAT_HTTPS_PORT == 443
assert not m._idv_supported_binary  # Synthetic onefile is not the official asset.
assert m._idv_capabilities
m._idv_supported_binary = True  # Test supported-path wiring independently.
m._idv_load_dependencies()
m._query_upstream_parallel = m._idv_query_upstream_parallel
m._idv_query_one = lambda server, query: "203.0.113.9"
assert m.resolve_domain_ip("mgbsdk.matrix.netease.com", use_hardcoded_first=False) == "203.0.113.9"
m.add_custom_dns("mgbsdk.matrix.netease.com", 443, "203.0.113.9")
assert socket.getaddrinfo("mgbsdk.matrix.netease.com", 443)[0][4] == ("203.0.113.9", 443)
assert m._dns_cache[("mgbsdk.matrix.netease.com", 443)][0][4] == ("203.0.113.9", 443)
assert m._idv_machinery.PathFinder.find_spec("mitm_proxy").loader.__class__.__name__ == "PyiFrozenLoader"
print("PASS: exact upstream frozen module + external overlay; original globals/classes/cache and DNS delegation preserved; no proxy started")
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream-source", type=Path)
    args = parser.parse_args()
    if args.upstream_source:
        source = args.upstream_source.read_bytes()
    else:
        with urllib.request.urlopen(SOURCE_URL, timeout=30) as response:
            source = response.read()
    if hashlib.sha256(source).hexdigest() != SOURCE_SHA256:
        raise SystemExit("Upstream source SHA256 mismatch")
    with tempfile.TemporaryDirectory(prefix="idv-dns-frozen-") as directory:
        root = Path(directory)
        (root / "mitm_proxy.py").write_bytes(source)
        # Upstream-only environment/log initialization is stubbed. The complete
        # mitm_proxy source and our external overlay execute unchanged.
        (root / "envmgr.py").write_text("genv = None\n")
        (root / "logutil.py").write_text("import logging\nsetup_logger = lambda: logging.getLogger('probe')\nsafe_exception = lambda *a, **k: None\n")
        (root / "probe.py").write_text(RUNNER)
        result = subprocess.run([
            sys.executable, "-m", "PyInstaller", "--noconfirm", "--clean", "--onefile",
            "--log-level", "ERROR", "--hidden-import", "mitm_proxy",
            "--distpath", str(root / "dist"), "--workpath", str(root / "build"),
            "--specpath", str(root), str(root / "probe.py")
        ], cwd=root, capture_output=True, text=True)
        if result.returncode:
            raise SystemExit(result.stdout + result.stderr)
        subprocess.run([str(root / "dist/probe"), str(Path(__file__).with_name("dnsTCPFallback.py").resolve())], check=True)
    print("Probe products removed; Python", sys.version.split()[0])


if __name__ == "__main__":
    main()
