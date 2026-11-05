#!/usr/bin/env python3
"""Exercise the real manager protocol with an isolated HOME (no game installation)."""
import json
import os
import pathlib
import tempfile
import subprocess
import sys
import shutil

manager = sys.argv[1]

def call(*args, code=0):
    result = subprocess.run([manager, 'agent', *args], text=True, capture_output=True)
    assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
    return [json.loads(line) for line in result.stdout.splitlines()]

assert call('help')[0]['documentationAvailable']
assert 'agent start install' in call('docs')[0]['text']
events = call('run', 'status', '--json')
record = call('task', events[0]['taskId'])[0]
assert record['state'] == 'succeeded' and record['exitCode'] == 0
assert record['output']['schemaVersion'] == 1
assert len(record['output']['products']) == 2
# Missing inspect arguments fail before manifest resolution or file access.
events = call('run', 'inspect', '--json', code=1)
record = call('task', events[0]['taskId'])[0]
assert record['state'] == 'failed' and record['childExitCode'] == 1
assert record['errorCode'] == 'core_operation_failed' and record['error']
assert call('logs', events[0]['taskId'], 'stderr')[0]['text'].strip()
assert events[-1]['event'] == 'result' and events[-1]['exitCode'] == 1
print('Real ProductManager Agent status and error protocol passed (isolated HOME).')

# Exercise actual CLI dispatch with a private adapter fixture, without network.
# A global command must use the global adapter and shared identity validator,
# rather than the mainland-only direct resolver (global has no directDownload).
with tempfile.TemporaryDirectory() as root:
    folder = pathlib.Path(root)
    isolated_manager = folder / 'IdentityVProductManager'
    shutil.copy2(manager, isolated_manager)
    shutil.copy2(pathlib.Path(manager).with_name('products.json'), folder / 'products.json')
    adapter = folder / 'IdentityVGlobalAdapter'
    manifest = dict(schemaVersion=1, productId='global', adapter='netease-loadingbay-global-v1',
                    appId=40, gameId='h55naxx2gb', displayName='Identity V', startupPath='dwrg.exe',
                    versionCode='v1_fixture', contentId=42, totalByteCount=17, oversea=True,
                    fetchedAt='2026-11-05T00:00:00Z', directories=[],
                    files=[dict(path='dwrg.exe', byteCount=17, md5='0'*32,
                                xxh64='0123456789abcdef', operation=1,
                                url='https://example.invalid/fixture/dwrg.exe')])
    def write_adapter():
        adapter.write_text("#!/bin/sh\n[ \"$1\" = resolve-manifest ] || exit 64\ncat <<'MANIFEST'\n" + json.dumps(manifest) + '\nMANIFEST\n')
        adapter.chmod(0o700)
    write_adapter()
    command = [str(isolated_manager), 'resolve-manifest', '--json', '--product', 'global']
    resolved = json.loads(subprocess.check_output(command, text=True))
    assert resolved['productId'] == 'global' and resolved['distributionId'] == 40
    assert resolved['files'][0]['xxh64'] == '0123456789abcdef'
    assert resolved['totalByteCount'] == 17
    manifest['productId'] = 'mainland'
    write_adapter()
    rejected = subprocess.run(command, capture_output=True, text=True)
    assert rejected.returncode != 0, 'global adapter identity mismatch must remain rejected'
print('Global resolve-manifest CLI routing and shared validation passed (fixture, no network).')

# The shipped short entry adds only the transport prefix, preserving arguments.
wrapper = str(pathlib.Path(manager).with_name('idv'))
help_result = json.loads(subprocess.check_output([wrapper, '--help'], text=True))
assert help_result['entrypoint'] == wrapper
assert 'resolve-location' in help_result['operations'] and 'remove-preview' in help_result['operations']
with tempfile.TemporaryDirectory(dir=os.environ['HOME']) as tmp:
    root = pathlib.Path(tmp).resolve()
    game = root / 'game'; game.mkdir()
    exe = game / 'dwrg.exe'; exe.write_bytes(b'MZfixture')
    other = game / 'settings.ini'; other.write_text('preserve')
    state = pathlib.Path(os.environ['HOME'], 'Library/Application Support/IdentityVOnMac/products.json')
    before = state.read_bytes() if state.exists() else None
    for selected in (root, game, exe, other):
        events = call('run', 'resolve-location', '--json', '--product', 'global', '--path', str(selected))
        output = call('task', events[0]['taskId'])[0]['output']
        assert output['found'], (str(selected), output)
        assert os.path.samefile(output['gameRoot'], game), (str(selected), output)
        assert not output['alreadyRegistered']
    assert other.read_text() == 'preserve' and exe.read_bytes() == b'MZfixture'
    assert (state.read_bytes() if state.exists() else None) == before
    events = call('run', 'remove-preview', '--json', '--product', 'global', code=1)
    assert call('task', events[0]['taskId'])[0]['state'] == 'failed'
print('Shipped short entry and shared location API passed (isolated files unchanged).')
