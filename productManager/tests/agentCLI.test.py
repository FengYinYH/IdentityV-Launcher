#!/usr/bin/env python3
"""Transport integration tests: fixture cannot modify game/runtime state."""
import json, os, subprocess, sys, tempfile, time, pathlib, signal, uuid
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
        deadline = time.monotonic() + 25
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
    # The owning install worker alone writes the control request and confirms
    # only after the fake core emits the matching state.
    install_root = pathlib.Path(tmp, 'install-root'); install_root.mkdir()
    task = invoke('start', 'install', '--product', 'mainland', '--destination-parent', str(install_root), '--fixture-control')[0]['taskId']
    wait_for(lambda r: r['state'] == 'running')
    deadline = time.monotonic() + 5
    while not any(e.get('payload', {}).get('coreState') == '2' for e in invoke('events', task)):
        assert time.monotonic() < deadline
        time.sleep(.05)
    assert invoke('pause', task)[0]['status'] == 'observed'
    assert invoke('resume', task)[0]['status'] == 'observed'
    assert json.loads((install_root / 'work' / 'download-control.json').read_text())['action'] == 'resume'
    invoke('cancel', task)
    wait_for(lambda r: r['state'] == 'cancelled')
    invoke('pause', task, code=1)
    # A foreign transaction marker must never receive a control file.
    foreign_root = pathlib.Path(tmp, 'foreign-root'); foreign_root.mkdir()
    task = invoke('start', 'install', '--product', 'mainland', '--destination-parent', str(foreign_root), '--fixture-control', '--fixture-bad-marker')[0]['taskId']
    wait_for(lambda r: r['state'] == 'running')
    deadline = time.monotonic() + 5
    while not any(e.get('payload', {}).get('coreState') == '2' for e in invoke('events', task)):
        assert time.monotonic() < deadline
        time.sleep(.05)
    assert invoke('pause', task, code=1)[0]['error'] == 'install_control_unavailable'
    assert not (foreign_root / 'work' / 'download-control.json').exists()
    invoke('cancel', task)
    wait_for(lambda r: r['state'] == 'cancelled')
    # A work directory symlink must not redirect control into another folder.
    symlink_root = pathlib.Path(tmp, 'symlink-root'); symlink_root.mkdir()
    task = invoke('start', 'install', '--product', 'mainland', '--destination-parent', str(symlink_root), '--fixture-control', '--fixture-work-symlink')[0]['taskId']
    wait_for(lambda r: r['state'] == 'running')
    deadline = time.monotonic() + 5
    while not any(e.get('payload', {}).get('coreState') == '2' for e in invoke('events', task)):
        assert time.monotonic() < deadline
        time.sleep(.05)
    assert invoke('pause', task, code=1)[0]['error'] == 'install_control_unavailable'
    assert not (symlink_root / 'work' / 'download-control.json').exists()
    invoke('cancel', task)
    wait_for(lambda r: r['state'] == 'cancelled')
    # Missing core acknowledgement is unknown, even when control was written.
    noack_root = pathlib.Path(tmp, 'install-noack'); noack_root.mkdir()
    task = invoke('start', 'install', '--product', 'mainland', '--destination-parent', str(noack_root), '--fixture-control', '--fixture-no-ack')[0]['taskId']
    wait_for(lambda r: r['state'] == 'running')
    deadline = time.monotonic() + 5
    while not any(e.get('payload', {}).get('coreState') == '2' for e in invoke('events', task)):
        assert time.monotonic() < deadline
        time.sleep(.05)
    assert invoke('pause', task, code=1)[0]['status'] == 'unknown'
    # An interrupted caller releases its OS lock; the effect of an already
    # dispatched request remains unknown until a later core state arrives.
    interrupted = subprocess.Popen([binary, 'agent', 'pause', task], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    time.sleep(.3)
    interrupted.terminate()
    interrupted.communicate(timeout=5)
    assert interrupted.returncode != 0
    assert invoke('pause', task, code=1)[0]['status'] == 'unknown'
    # A control pending during installation cancellation must not claim confirmation.
    request = subprocess.Popen([binary, 'agent', 'pause', task], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    time.sleep(.3)
    invoke('cancel', task)
    out, err = request.communicate(timeout=5)
    assert request.returncode == 1 and json.loads(out)['status'] in ('unknown', 'failed'), (out, err)
    wait_for(lambda r: r['state'] == 'cancelled')
    # Login installation uses fixture downloader/installer only: no network,
    # privileges, certificates or real component are touched.
    install_events = invoke('run', 'login-install')
    install_record = invoke('task', install_events[0]['taskId'])[0]
    assert install_record['state'] == 'succeeded' and install_record['output']['installed'] and install_record['downloadExitCode'] == 0
    install_events = invoke('run', 'login-install', '--fixture-download-fail', code=1)
    assert invoke('task', install_events[0]['taskId'])[0]['error'] == 'login_download_failed'
    assert invoke('task', install_events[0]['taskId'])[0]['downloadExitCode'] == 7
    install_events = invoke('run', 'login-install', '--fixture-install-fail', code=1)
    assert invoke('task', install_events[0]['taskId'])[0]['state'] == 'failed'
    install_events = invoke('run', 'login-install', '--fixture-install-crash', code=1)
    assert invoke('task', install_events[0]['taskId'])[0]['state'] == 'unknown'
    install_events = invoke('run', 'login-install', '--fixture-install-timeout', code=1)
    assert invoke('task', install_events[0]['taskId'])[0]['state'] == 'unknown'
    task = invoke('start', 'login-install', '--fixture-download-slow')[0]['taskId']
    wait_for(lambda r: r['state'] == 'running' and r.get('cancellable') is True)
    invoke('cancel', task)
    wait_for(lambda r: r['state'] == 'cancelled')
    # Offline cancellation lets the stage finish its mount cleanup; a stage
    # failure remains failed rather than being mislabeled cancelled.
    task = invoke('start', 'login-install', '--fixture-offline', '--fixture-download-short')[0]['taskId']
    wait_for(lambda r: r['state'] == 'running' and r.get('cancellable') is True)
    invoke('cancel', task)
    wait_for(lambda r: r['state'] == 'cancelled')
    assert (pathlib.Path(tmp, task, 'fixture-cache', 'fixture-component')).exists()
    task = invoke('start', 'login-install', '--fixture-offline', '--fixture-download-late-fail')[0]['taskId']
    wait_for(lambda r: r['state'] == 'running' and r.get('cancellable') is True)
    invoke('cancel', task)
    record = wait_for(lambda r: r['state'] in ('cancelled', 'failed', 'succeeded'))
    assert record['state'] == 'failed' and record['cancellationRequested'], record
    task = invoke('start', 'login-install', '--fixture-offline', '--fixture-download-late-130')[0]['taskId']
    wait_for(lambda r: r['state'] == 'running' and r.get('cancellable') is True)
    invoke('cancel', task)
    record = wait_for(lambda r: r['state'] in ('cancelled', 'failed', 'succeeded'))
    assert record['state'] == 'failed' and record['cancellationRequested'], record
    # Offline cleanup that does not finish by the deadline is unknown, never
    # fabricated as cancelled or forcibly killed.
    task = invoke('start', 'login-install', '--fixture-offline', '--fixture-download-slow', '--fixture-cancel-timeout')[0]['taskId']
    wait_for(lambda r: r['state'] == 'running' and r.get('cancellable') is True)
    invoke('cancel', task)
    record = wait_for(lambda r: r['state'] in ('cancelled', 'failed', 'succeeded', 'unknown'))
    assert record['state'] == 'unknown' and record['errorCode'] == 'login_download_result_unknown'
    task = invoke('start', 'login-install', '--fixture-download-late-crash')[0]['taskId']
    wait_for(lambda r: r['state'] == 'running' and r.get('cancellable') is True)
    deadline = time.monotonic() + 5
    while not any(e.get('payload', {}).get('phase') == 'fixture-ready' for e in invoke('events', task)):
        assert time.monotonic() < deadline
        time.sleep(.05)
    invoke('cancel', task)
    record = wait_for(lambda r: r['state'] in ('cancelled', 'failed', 'succeeded'))
    assert record['state'] == 'failed' and record['cancellationRequested'], record
    task = invoke('start', 'login-install', '--fixture-confirm-wait')[0]['taskId']
    wait_for(lambda r: r['state'] == 'awaiting_confirmation')
    invoke('cancel', task)
    wait_for(lambda r: r['state'] == 'cancelled')
    task = invoke('start', 'login-install', '--fixture-install-slow')[0]['taskId']
    wait_for(lambda r: r['state'] == 'running' and r.get('cancellable') is False)
    invoke('cancel', task)
    record = wait_for(lambda r: r['state'] in ('succeeded', 'failed', 'cancelled', 'unknown'))
    assert record['state'] == 'succeeded' and record['cancellationRequested']
    # A cancellation already present when a queued worker starts prevents
    # any backend launch, including privileged handoff.
    pre_id = str(uuid.uuid4()).upper()
    pre_dir = pathlib.Path(tmp, pre_id)
    pre_dir.mkdir()
    (pre_dir / 'task.json').write_text(json.dumps({'schemaVersion': 1, 'taskId': pre_id, 'state': 'queued', 'arguments': ['login-stop', '--fixture-slow'], 'updatedAt': time.time()}))
    for name in ('events.jsonl', 'stdout.log', 'stderr.log', 'cancel-requested'):
        (pre_dir / name).touch()
    invoke('worker', pre_id, code=130)
    assert invoke('task', pre_id)[0]['state'] == 'cancelled'
    assert (pre_dir / 'stdout.log').read_text() == ''
    # Stop uses a conservative boundary: once the worker marks handoff,
    # cancellation cannot kill the backend or fabricate cancellation.
    task = invoke('start', 'login-stop', '--fixture-slow')[0]['taskId']
    wait_for(lambda r: r['state'] == 'running' and r.get('cancellable') is False)
    invoke('cancel', task)
    time.sleep(.5)
    assert invoke('task', task)[0]['state'] == 'running'
    record = wait_for(lambda r: r['state'] in ('cancelled', 'failed', 'succeeded', 'unknown'))
    assert record['state'] == 'succeeded' and record['cancellationRequested']
    assert any(e['event'] == 'cancellation_too_late' for e in invoke('events', task))
    events = invoke('run', 'login-stop', '--fixture-fail', code=1)
    assert invoke('task', events[0]['taskId'])[0]['state'] == 'failed'
    events = invoke('run', 'login-stop', '--fixture-crash', code=1)
    assert invoke('task', events[0]['taskId'])[0]['state'] == 'unknown'
    events = invoke('run', 'login-stop', '--fixture-timeout', code=1)
    assert invoke('task', events[0]['taskId'])[0]['errorCode'] == 'privileged_result_unknown'
    # Start shares the same non-interruptible post-handoff transport.
    task = invoke('start', 'login-start', '--fixture-slow', '--fixture-short')[0]['taskId']
    wait_for(lambda r: r['state'] == 'running' and r.get('cancellable') is False)
    invoke('cancel', task)
    record = wait_for(lambda r: r['state'] in ('cancelled', 'failed', 'succeeded', 'unknown'))
    assert record['state'] == 'succeeded' and record['cancellationRequested']
    events = invoke('run', 'login-start', '--fixture-fail', code=1)
    assert invoke('task', events[0]['taskId'])[0]['state'] == 'failed'
    events = invoke('run', 'login-start', '--fixture-crash', code=1)
    assert invoke('task', events[0]['taskId'])[0]['state'] == 'unknown'
    events = invoke('run', 'login-start', '--fixture-timeout', code=1)
    assert invoke('task', events[0]['taskId'])[0]['state'] == 'unknown'
    # Feedback handoff shares the conservative transport, using only a stub.
    task = invoke('start', 'feedback-draft', '--fixture-slow', '--fixture-short')[0]['taskId']
    wait_for(lambda r: r['state'] == 'running' and r.get('cancellable') is False)
    invoke('cancel', task)
    record = wait_for(lambda r: r['state'] in ('cancelled', 'failed', 'succeeded', 'unknown'))
    assert record['state'] == 'succeeded' and record['cancellationRequested']
    events = invoke('run', 'feedback-draft', '--fixture-fail', code=1)
    assert invoke('task', events[0]['taskId'])[0]['state'] == 'failed'
    events = invoke('run', 'repair', '--fixture-unrequested-130', code=1)
    record = invoke('task', events[0]['taskId'])[0]
    assert record['state'] == 'failed' and not record['cancellationRequested']
    invoke('task', '../escape', code=1)
    invoke('run', 'invented', code=1)
    invoke('run', 'remove', '--expected-removal-token', 'a' * 64, code=1)
    # Exercise native confirmation cancellation without accepting deletion.
    # On headless hosts this must fail closed, never invoke the fixture core.
    headless = '--headless' in sys.argv[2:]
    if headless:
        print('DEFERRED: native confirmation UI tests (--headless); transport, cancellation and protocol tests still run.')
    for signal_cancel in (() if headless else (False, True)):
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
