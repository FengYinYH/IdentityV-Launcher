#!/usr/bin/env python3
"""Exercise the real manager protocol with an isolated HOME (no game installation)."""
import json
import subprocess
import sys

manager = sys.argv[1]

def call(*args, code=0):
    result = subprocess.run([manager, 'agent', *args], text=True, capture_output=True)
    assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
    return [json.loads(line) for line in result.stdout.splitlines()]

events = call('run', 'status', '--json')
record = call('task', events[0]['taskId'])[0]
assert record['state'] == 'succeeded' and record['exitCode'] == 0
assert record['output']['schemaVersion'] == 1
assert len(record['output']['products']) == 2
# Missing inspect arguments fail before manifest resolution or file access.
events = call('run', 'inspect', '--json', code=1)
record = call('task', events[0]['taskId'])[0]
assert record['state'] == 'failed' and record['childExitCode'] == 1
assert call('logs', events[0]['taskId'], 'stderr')[0]['text'].strip()
assert events[-1]['event'] == 'result' and events[-1]['exitCode'] == 1
print('Real ProductManager Agent status and error protocol passed (isolated HOME).')
