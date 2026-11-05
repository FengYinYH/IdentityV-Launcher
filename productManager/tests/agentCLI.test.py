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
    assert invoke('task', task.lower())[0]['taskId'] == task
    assert invoke('logs', task, 'stdout')[0]['text'].strip().startswith('{')
    invoke('worker', task, code=1)  # duplicate execution rejected
    events = invoke('run', 'repair', '--fixture-fail', code=1)
    task = events[0]['taskId']
    record = invoke('task', task)[0]
    assert record['state'] == 'failed' and record['childExitCode'] == 7
    assert record['errorCode'] == 'core_operation_failed' and 'E42' in record['error']
    assert 'private-value' not in record['error']
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
    # A core may acknowledge cancellation with exit 130 after its own cleanup.
    task = invoke('start', 'install', '--fixture-cooperative-cancel')[0]['taskId']
    wait_for(lambda r: r['state'] == 'running')
    deadline = time.monotonic() + 5
    while not invoke('events', task)[-1]['event'] == 'progress':
        assert time.monotonic() < deadline
        time.sleep(.05)
    invoke('cancel', task)
    record = wait_for(lambda r: r['state'] in ('cancelled', 'failed', 'succeeded'))
    assert record['state'] == 'cancelled' and record['childExitCode'] == 130
    events = invoke('run', 'repair', '--fixture-unrequested-130', code=1)
    record = invoke('task', events[0]['taskId'])[0]
    assert record['state'] == 'failed' and not record['cancellationRequested']
    invoke('task', '../escape', code=1)
    invoke('run', 'invented', code=1)
    invoke('run', 'remove', '--expected-removal-token', 'a' * 64, code=1)
    # Exercise native confirmation cancellation without accepting deletion.
    # On headless hosts this must fail closed, never invoke the fixture core.
    for signal_cancel in (False, True):
        stream = tempfile.TemporaryFile(mode='w+')
        proc = subprocess.Popen([binary, 'agent', 'run', 'remove', '--product', 'global', '--fixture-only'],
                                env=env, stdout=stream, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 10
            confirmation = None
            while time.monotonic() < deadline:
                candidates = sorted(pathlib.Path(tmp).glob('*/task.json'), key=lambda p: p.stat().st_mtime, reverse=True)
                if candidates:
                    candidate = json.loads(candidates[0].read_text())
                    if candidate['arguments'][0] == 'remove':
                        confirmation = candidate
                        if candidate['state'] in ('awaiting_confirmation', 'failed'): break
                if proc.poll() is not None: break
                time.sleep(.05)
            assert confirmation, 'missing confirmation task'
            cid = confirmation['taskId']
            assert invoke('logs', cid, 'stdout')[0]['text'] == ''
            if proc.poll() is None:
                before = invoke('task', cid)[0]['updatedAt']
                heartbeat_deadline = time.monotonic() + 3
                while invoke('task', cid)[0]['updatedAt'] <= before:
                    assert time.monotonic() < heartbeat_deadline, 'modal must keep heartbeating'
                    time.sleep(.05)
                if signal_cancel: proc.send_signal(signal.SIGTERM)
                else: invoke('cancel', cid)
                assert proc.wait(timeout=5) == 130
                done = invoke('task', cid)[0]
                assert done['state'] == 'cancelled' and done['cancellationRequested']
                assert done['removalPreview']['gamePath'] == '/fixture/TEST-ONLY-game'
                assert invoke('logs', cid, 'stdout')[0]['text'] == ''
            else:
                assert confirmation['state'] == 'failed' and confirmation['error'] == 'confirmation_unavailable'
        finally:
            if proc.poll() is None: proc.terminate(); proc.wait(timeout=5)
            stream.close()

    path = pathlib.Path(tmp, task, 'task.json')
    record['state'] = 'running'; record['updatedAt'] = 0
    path.write_text(json.dumps(record))
    assert invoke('task', task)[0]['observedState'] == 'unknown'
print('Agent CLI receipt, structured output, failure, progress, cancellation, logs and unknown-state tests passed.')
