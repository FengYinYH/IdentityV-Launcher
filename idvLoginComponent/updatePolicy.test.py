#!/usr/bin/env python3
"""Exercise the exact Swift-embedded policy without starting the login service."""
import importlib.abc
import importlib.util
from pathlib import Path
import sys
import types

root = Path(__file__).resolve().parents[1]
source = (root / "privilegedHelpers/IdentityVPrivilegedStateTool.swift").read_text()
policy = source.split('private let idvLoginUpdatePolicy = #"""\n', 1)[1].split('\n"""#', 1)[0]
compile(policy, "managed-policy.py", "exec")

class OriginalLoader(importlib.abc.Loader):
    def create_module(self, spec):
        return None
    def exec_module(self, module):
        exec("class CloudRes:\n def get_version(self): return 'v99'\n def get_hotfixes(self): return ['remote']\n def login_data(self): return 'unchanged'\n", module.__dict__)

class FrozenFinder(importlib.abc.MetaPathFinder):
    def find_spec(self, fullname, path=None, target=None):
        if fullname == "cloudRes":
            return importlib.util.spec_from_loader(fullname, OriginalLoader(), origin="frozen")

class _HotfixOverlayFinder(importlib.abc.MetaPathFinder):
    def find_spec(self, fullname, path=None, target=None):
        raise AssertionError("must bypass overlay finder to prevent recursion")

env = types.ModuleType("envmgr")
env.genv = types.SimpleNamespace(get=lambda key, default=None: "v6.3.1-beta")
old_env = sys.modules.get("envmgr")
old_main = sys.modules.get("__main__")
old_meta = sys.meta_path[:]
try:
    sys.modules["envmgr"] = env
    main = types.ModuleType("__main__")
    main.handle_update = lambda: (_ for _ in ()).throw(AssertionError("upstream update checker ran"))
    sys.modules["__main__"] = main
    sys.meta_path = [_HotfixOverlayFinder(), FrozenFinder()]
    namespace = {"__file__": "managed-policy.py"}
    exec(policy, namespace)
    cloud = namespace["CloudRes"]()
    assert cloud.get_version() == "v6.3.1-beta"
    assert cloud.get_hotfixes() == []
    assert cloud.login_data() == "unchanged"
    main.handle_update()
    del main.handle_update
    try:
        exec(policy, {"__file__": "managed-policy.py"})
    except RuntimeError:
        pass
    else:
        raise AssertionError("missing update entry point must fail closed")
    main.handle_update = lambda: None
    env.genv.get = lambda key, default=None: "v6.4.0"
    try:
        exec(policy, {"__file__": "managed-policy.py"})
    except RuntimeError:
        pass
    else:
        raise AssertionError("unsupported pin must fail closed")
finally:
    sys.meta_path = old_meta
    sys.modules["__main__"] = old_main
    if old_env is None:
        sys.modules.pop("envmgr", None)
    else:
        sys.modules["envmgr"] = old_env
print("pinned update policy delegation/version/hotfix/recursion contracts passed")
