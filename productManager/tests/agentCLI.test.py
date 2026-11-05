#!/usr/bin/env python3
"""Transport integration tests: fixture cannot modify game/runtime state."""
import json, os, subprocess, sys, tempfile, time, pathlib, signal
binary = sys.argv[1]
with tempfile.TemporaryDirectory() as tmp:
    env = dict(os.environ, IDENTITYV_AGENT_TASK_ROOT=tmp)
    def invoke(*args, code=0):
        result = subprocess.run([binary, 'agent', *args], env=env, capture_output=True, text=True)
        assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
        return [json.loads(line) for line in result.stdout.splitlines()]
    help = invoke('help')[0]
    assert 'remove' in help['operations'] and help['documentationAvailable']
    assert invoke('docs')[0]['format'] == 'markdown' and 'taskId' in invoke('docs')[0]['text']
    events = invoke('run', 'status', '--json')
    task = events[0]['taskId']
    assert [e['sequence'] for e in events] == list(range(1, len(events)+1))
    record = invoke('task', task)[0]
    assert record['state'] == 'succeeded' and record['output']['fixture']
    assert invoke('events', task) == events
    assert invoke('logs', task, 'stdout')[0]['text'].strip().startswith('{')
    invoke('worker', task, code=1)  # duplicate execution rejected
    events = invoke('run', 'repair', '--fixture-fail', code=1)
    task = events[0]['taskId']
    record = invoke('task', task)[0]
    assert record['state'] == 'failed' and record['childExitCode'] == 7
    log = invoke('logs', task, 'stderr')[0]['text']
    assert 'private-value' not in log and 'error=E42' in log
    receipt = invoke('start', 'install', '--fixture-slow')[0]
    task = receipt['taskId']
    def wait_for(predicate):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            record = invoke('task', task)[0]
            if predicate(record): return record
            time.sleep(.1)
        raise AssertionError(record)
    wait_for(lambda r: r['state'] == 'running')
    invoke('cancel', task)
    record = wait_for(lambda r: r['state'] in ('cancelled', 'failed', 'succeeded'))
    assert record['state'] == 'cancelled' and record['exitCode'] == 130
    assert any(e['event'] == 'progress' for e in invoke('events', task))
    invoke('task', '../escape', code=1)
    invoke('run', 'invented', code=1)
    # The test never accepts the deletion modal. Headless case is tested separately.
    path = pathlib.Path(tmp, task, 'task.json')
    record['state'] = 'running'; record['updatedAt'] = 0
    path.write_text(json.dumps(record))
    assert invoke('task', task)[0]['observedState'] == 'unknown'
print('Agent CLI receipt, structured output, failure, progress, cancellation, logs and unknown-state tests passed.')
