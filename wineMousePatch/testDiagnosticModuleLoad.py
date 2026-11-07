#!/usr/bin/env python3
"""Load an explicit diagnostic module in a short-lived x86_64 CLI process.
Does not call Wine/macdrv initialization, create NSApplication, windows, input,
or attach to an existing process. Dependencies come from an explicit runtime.
"""
import hashlib
import os
import pathlib
import subprocess
import sys
import tempfile

module = pathlib.Path(sys.argv[1]).resolve(strict=True)
runtime = pathlib.Path(sys.argv[2]).resolve(strict=True)
dependencies = runtime / 'lib/wine/x86_64-unix'
assert (dependencies / 'ntdll.so').is_file() and (dependencies / 'win32u.so').is_file()
probe = r'''
#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char **argv) {
    if (argc != 2) return 64;
    void *handle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!handle) { fprintf(stderr, "module-load-failed: %s\n", dlerror()); return 1; }
    puts("module-load-ok; no Wine initialization called");
    return 0;
}
'''
with tempfile.TemporaryDirectory(prefix='idv-capture-module-load-') as temp:
    root = pathlib.Path(temp)
    (root / 'probe.c').write_text(probe)
    binary = root / 'probe'
    subprocess.run(['clang', '-arch', 'x86_64', '-Werror', str(root / 'probe.c'), '-Wl,-rpath,' + str(module.parent), '-Wl,-rpath,' + str(dependencies), '-o', str(binary)], check=True)
    for enabled in (False, True):
        env = os.environ.copy()
        for name in ('IDENTITYV_CAPTURE_DIAGNOSTICS', 'DYLD_INSERT_LIBRARIES', 'DYLD_LIBRARY_PATH', 'DYLD_FALLBACK_LIBRARY_PATH'):
            env.pop(name, None)
        if enabled:
            env['IDENTITYV_CAPTURE_DIAGNOSTICS'] = '1'
        result = subprocess.run([str(binary), str(module)], env=env, capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stderr)
        records = [line for line in result.stderr.splitlines() if line.startswith('IDV_CAPTURE_DIAG ')]
        paired = (module.parent / 'win32u.so').is_file()
        assert len(records) == (2 if paired else 1), result.stderr
        assert all(f'reason=module-start enabled={int(enabled)} diagnosticBuild=1' in record for record in records), result.stderr
        if paired:
            assert sum('layer=win32u ' in record for record in records) == 1
            assert sum('layer=macdrv ' in record for record in records) == 1
        print('\n'.join(records))
    print('PASS: actual x86_64 module constructor emits presence with flag absent/present; no Wine initialization')
    print('module SHA256:', hashlib.sha256(module.read_bytes()).hexdigest())
