#!/usr/bin/env python3
"""Compare a diagnostic pair to an explicit baseline without loading Wine."""
import hashlib
import json
import pathlib
import re
import subprocess
import sys

candidate = pathlib.Path(sys.argv[1]).resolve(strict=True)
runtime = pathlib.Path(sys.argv[2]).resolve(strict=True)
def output(*args):
    return subprocess.check_output(args, text=True)
def exports(path):
    return {line.split()[-1] for line in output('nm', '-gU', str(path)).splitlines() if line.split()}
def dependencies(path):
    return [line.strip().split(' (')[0] for line in output('otool', '-L', str(path)).splitlines()[1:]]
def strings(path, pattern):
    return {line for line in output('strings', str(path)).splitlines() if re.fullmatch(pattern, line)}
report = {'budgets': {'macdrv': 48, 'win32u': 16, 'processTotalMax': 64}, 'deployed': False}
for name in ('winemac.so', 'win32u.so'):
    new = candidate / name
    old = runtime / 'lib/wine/x86_64-unix' / name
    assert exports(new) == exports(old), f'{name}: exports differ'
    assert dependencies(new) == dependencies(old), f'{name}: load dependencies differ'
    backends = strings(new, r'lib[^ /]+\.(?:dylib|so(?:\.[0-9]+)?)')
    ft = strings(new, r'FT_[A-Za-z0-9_]+')
    assert backends == strings(old, r'lib[^ /]+\.(?:dylib|so(?:\.[0-9]+)?)'), f'{name}: dynamic backends differ'
    assert ft == strings(old, r'FT_[A-Za-z0-9_]+'), f'{name}: FreeType function names differ'
    assert 'minos 14.0' in output('xcrun', 'vtool', '-show-build', str(new))
    report[name] = {'sha256': hashlib.sha256(new.read_bytes()).hexdigest(), 'exportCount': len(exports(new)), 'exportsMatch': True, 'dependenciesMatch': True, 'dynamicBackends': sorted(backends), 'freeTypeDynamicFunctionCount': len(ft), 'minimumMacOS': '14.0'}
ft_library = runtime / 'lib64/libfreetype.6.dylib'
required = strings(candidate / 'win32u.so', r'FT_[A-Za-z0-9_]+')
assert {'_' + name for name in required} <= exports(ft_library), 'runtime FreeType lacks required functions'
report['baselineGdi32SHA256'] = hashlib.sha256((runtime / 'lib/wine/x86_64-windows/gdi32.dll').read_bytes()).hexdigest()
print(json.dumps(report, indent=2))
