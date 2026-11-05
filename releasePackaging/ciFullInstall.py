#!/usr/bin/env python3
"""One real first-install experiment on an ephemeral macOS Actions runner.

Never run on a user's Mac. Raw subprocess output stays in the disposable work
root. The only published artifact is the bounded, deliberately selected JSON.
"""
import argparse
import hashlib
import json
import math
import os
import platform
from pathlib import Path
import re
import shutil
import signal
import subprocess
import time
import uuid

GIB = 1024 ** 3
TERMINAL = {'succeeded', 'failed', 'cancelled'}
GAME_PROCESS_PATTERN = r'(^|[\\/])dwrg[.]exe([[:space:]]|$)'
ALLOWED_DIFF = {'.github/workflows/full-install.yml', 'releasePackaging/ciFullInstall.py',
                'releasePackaging/tests/test_ci_full_install.py', 'docs/ciWorkflow.md',
                'docs/developerGuide.md', 'projectMap.md', 'STATUS.md',
                '.github/workflows/game-launch.yml', 'releasePackaging/ciGraphicsProbe.swift',
                '.github/workflows/server-install.yml', 'gameDownloader/supervisor_test.go'}


class ExperimentError(Exception):
    pass


def required_space(game_bytes):
    if not isinstance(game_bytes, int) or isinstance(game_bytes, bool) or game_bytes <= 0:
        raise ExperimentError('invalid_manifest_size')
    # Measured mainland footprint is base data + about 2GiB. Reserve 4GiB
    # runtime/prefix/transients, 4GiB hot updates and the 6GiB stop floor.
    return (math.ceil(game_bytes / GIB) + 14) * GIB


def safe_text(text):
    lines = []
    for line in text.splitlines()[-30:]:
        if re.search(r'(?i)authorization|bearer|cookie|token|password|secret|private.key|credential|api.key', line):
            lines.append('<redacted credential line>')
        else:
            line = re.sub(r'(https?://[^\s?]+)\?[^\s]*', r'\1?<redacted-query>', line)
            line = re.sub(r'(https?://)[^/\s]+@', r'\1<redacted-user>@', line)
            lines.append(line.replace(str(Path.home()), '<HOME>'))
    return '\n'.join(lines)[-4096:]


def safe_diagnostic(path):
    with path.open('rb') as stream:
        stream.seek(0, 2)
        stream.seek(max(0, stream.tell() - 16384))
        return safe_text(stream.read().decode('utf-8', errors='replace'))


class DiskObserver:
    def __init__(self, root, result, checkpoint=lambda: None):
        self.root, self.result, self.checkpoint = root, result, checkpoint
        self.initial = shutil.disk_usage(root).free
        self.minimum = self.initial
        self.last_emission = 0
        result['initialFreeBytes'] = self.initial
        result['spaceSampleIntervalSeconds'] = 5

    def sample(self):
        free = shutil.disk_usage(self.root).free
        self.minimum = min(self.minimum, free)
        self.result['minimumObservedFreeBytes'] = self.minimum
        self.result['observedAdditionalPeakBytes'] = max(0, self.initial - self.minimum)
        self.checkpoint()
        if time.monotonic() - self.last_emission >= 30:
            self.last_emission = time.monotonic()
            print(json.dumps({'event': 'ci-resource', 'stage': self.result.get('stage'),
                              'freeBytes': free, 'minimumObservedFreeBytes': self.minimum}), flush=True)
        return free


def stop_reason(record, free, elapsed, deadline):
    if record.get('state') in TERMINAL:
        return None
    if free < 6 * GIB:
        return 'free_space_below_6_gib'
    if elapsed >= deadline:
        return 'installation_time_limit'
    return None


def verify_ready(document, destination, version, product='mainland'):
    rows = [x for x in document.get('products', []) if x.get('productId') == product]
    if len(rows) != 1 or rows[0].get('state') != 'ready':
        raise ExperimentError('product_not_ready')
    row = rows[0]
    game = Path(row.get('gamePath', '')).resolve()
    if not game.is_relative_to(destination.resolve()) or not (game / 'dwrg.exe').is_file():
        raise ExperimentError('invalid_published_game_path')
    if row.get('installedVersion') != version:
        raise ExperimentError('upstream_version_changed_or_binding_mismatch')
    if any((game.parent / name).exists() for name in ('.staging', '.identityv-direct-install.json', '.identityv-global-install.json')):
        raise ExperimentError('installation_transaction_not_finished')
    return game


def run_private(command, cwd, env, output, disk, timeout):
    started = time.monotonic()
    with output.open('wb') as stream:
        proc = subprocess.Popen(command, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
        reason = None
        while proc.poll() is None:
            if disk.sample() < 6 * GIB:
                reason = 'free_space_below_6_gib'
            if time.monotonic() - started > timeout:
                reason = 'phase_time_limit'
            if reason:
                # Only this runner-owned subprocess group; never arbitrary user PIDs.
                os.killpg(proc.pid, signal.SIGTERM)
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait()
                raise ExperimentError(reason)
            time.sleep(5)
    if proc.returncode:
        raise ExperimentError('subprocess_exit_' + str(proc.returncode))
    return time.monotonic() - started


def supervise(agent, task_id, disk, event_file, result, timeout=7200, poll=5):
    start = time.monotonic()
    offset, pending = 0, b''
    cancellation, cancel_at = None, None
    result['phaseTransitions'] = []
    while True:
        record = agent('task', task_id)
        free = disk.sample()
        if event_file.exists():
            with event_file.open('rb') as events:
                events.seek(offset)
                pending += events.read()
                offset = events.tell()
            while b'\n' in pending:
                line, pending = pending.split(b'\n', 1)
                event = json.loads(line)
                payload = event.get('payload', {})
                phase = payload.get('phase')
                if payload.get('event') == 'failure':
                    result['coreFailure'] = {k: payload[k] for k in ('errorCode', 'coreState', 'requiredBytes') if k in payload}
                if phase and (not result['phaseTransitions'] or result['phaseTransitions'][-1]['phase'] != phase):
                    # Never copy URLs, raw payloads, messages or file paths.
                    transition = {'phase': str(phase)[:80], 'seconds': round(time.monotonic() - start, 2)}
                    result['phaseTransitions'].append(transition)
                    print(json.dumps({'event': 'ci-install-phase', **transition}), flush=True)
        if record.get('state') in TERMINAL:
            result['installationSeconds'] = round(time.monotonic() - start, 2)
            result['taskState'] = record['state']
            result['taskExitCode'] = record.get('exitCode')
            result['childExitCode'] = record.get('childExitCode')
            if cancellation:
                raise ExperimentError(cancellation)
            if record['state'] != 'succeeded' or record.get('exitCode') != 0:
                result['coreErrorCode'] = record.get('errorCode', 'not_provided')
                result['coreErrorSummary'] = safe_text(str(record.get('error', '')))
                raise ExperimentError('installation_did_not_succeed')
            return
        reason = stop_reason(record, free, time.monotonic() - start, timeout)
        if reason and cancellation is None:
            cancellation, cancel_at = reason, time.monotonic()
            agent('cancel', task_id)
        if cancel_at is not None and time.monotonic() - cancel_at > 30:
            result['taskState'] = record.get('state', 'unknown')
            result['cancellationPending'] = True
            raise ExperimentError(cancellation + '_cancellation_pending')
        time.sleep(poll)


def game_tree_summary(game):
    count, size = 0, 0
    for parent, dirs, files in os.walk(game, followlinks=False):
        for name in files:
            path = Path(parent) / name
            if path.is_symlink():
                continue
            try:
                size += path.stat().st_size
                count += 1
            except FileNotFoundError:
                pass
    return {'files': count, 'bytes': size}


def stop_owned_product(agent, product, timeout=60):
    # `agent run` is JSONL events, whereas start/task each return one document.
    receipt = agent('start', 'stop', '--product', product)
    task = str(uuid.UUID(receipt['taskId']))
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        record = agent('task', task)
        if record.get('state') in TERMINAL:
            return record
        time.sleep(1)
    raise ExperimentError('product_stop_still_pending')


def observe_launch(manager, env, game, product, work, reports, result):
    # This is an observation, never a declaration that the announcement is visible.
    report = {'announcementVerified': False, 'hotUpdateVerified': False,
              'accountLoginAttempted': False, 'inputEventsSent': False,
              'observationLimitSeconds': 480, 'samples': []}
    result['launchObservation'] = report
    report['gameTreeBefore'] = game_tree_summary(game)
    started = time.monotonic()
    def agent(*args, timeout=20):
        proc = subprocess.run([manager, 'agent', *args], env=env, stdin=subprocess.DEVNULL,
                              capture_output=True, timeout=timeout)
        if proc.returncode:
            raise ExperimentError('launch_agent_exit_' + str(proc.returncode))
        return json.loads(proc.stdout)
    task = None
    try:
        receipt = agent('start', 'launch', '--product', product)
        task = str(uuid.UUID(receipt['taskId']))
        report['taskId'] = task
        result['gameLaunchAttempted'] = True
        next_capture = 30
        captures = 0
        while time.monotonic() - started < 480:
            elapsed = round(time.monotonic() - started, 2)
            free = shutil.disk_usage(work).free
            if free < 6 * GIB:
                report['stopReason'] = 'free_space_below_6_gib'
                break
            state = agent('task', task)
            report['taskState'] = state.get('state')
            report['taskExitCode'] = state.get('exitCode')
            if state.get('error'):
                report['errorSummary'] = safe_text(str(state['error']))[:2048]
            pids = subprocess.run(['/usr/bin/pgrep', '-f', GAME_PROCESS_PATTERN],
                                  capture_output=True, text=True).stdout.split()
            sample = {'seconds': elapsed, 'gameProcessCount': len(pids), 'freeBytes': free,
                      'taskState': state.get('state')}
            report['samples'].append(sample)
            print(json.dumps({'event': 'ci-game-observation', 'product': product, **sample}), flush=True)
            if elapsed >= next_capture and captures < 4:
                captures += 1
                name = 'game-' + product + '-' + str(captures) + '.png'
                capture = subprocess.run(['/usr/sbin/screencapture', '-x', str(reports / name)],
                                         stdin=subprocess.DEVNULL, capture_output=True, timeout=15)
                sample['screenshotExitCode'] = capture.returncode
                if capture.returncode == 0:
                    sample['screenshot'] = name
                next_capture = [30, 120, 300, 450][min(captures, 3)]
            if state.get('state') in TERMINAL and state.get('state') != 'succeeded' and not pids and elapsed >= 30:
                report['stopReason'] = 'launch_failed_and_no_game_process'
                break
            time.sleep(15)
        report['coreVerifiedGameWindow'] = report.get('taskState') == 'succeeded' and report.get('taskExitCode') == 0
        result['gameLaunched'] = report['coreVerifiedGameWindow']
    except Exception as error:
        report['observationError'] = safe_text(str(error))[:2048]
    finally:
        # Stop only this freshly installed product with the public shared core.
        if task and report.get('taskState') not in TERMINAL:
            try:
                agent('cancel', task)
            except Exception:
                report['launchCancellationPending'] = True
        try:
            stopped = stop_owned_product(agent, product)
            report['stopTaskState'] = stopped.get('state')
        except Exception as error:
            report['stopError'] = safe_text(str(error))[:1024]
        report['observedSeconds'] = round(time.monotonic() - started, 2)
        report['gameTreeAfter'] = game_tree_summary(game)
        log_root = Path(env['HOME']) / 'Library/Logs/IdentityVOnMac'
        logs = sorted(log_root.glob('*.log'), key=lambda p: p.stat().st_mtime, reverse=True)[:3]
        report['runnerLogTails'] = [safe_diagnostic(p).replace(env['HOME'], '<isolated-home>') for p in logs]
        report['cleanup'] = 'product_stop_attempted_then_ephemeral_runner_reclamation'


def experiment(args, result, checkpoint=lambda: None):
    if os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('RUNNER_OS') != 'macOS' or platform.machine() != 'arm64':
        raise ExperimentError('ephemeral_macos_actions_runner_required')
    if not re.fullmatch(r'[0-9a-f]{40}', args.candidate) or args.candidate == '0' * 40:
        raise ExperimentError('final_candidate_not_frozen')
    source = Path(__file__).resolve().parent.parent
    def git(*cmd):
        return subprocess.check_output(['git', *cmd], cwd=source, text=True).strip()
    result['candidateCommit'] = args.candidate
    result['checkoutCommit'] = git('rev-parse', 'HEAD')
    if git('status', '--porcelain'):
        raise ExperimentError('source_not_clean_before_build')
    subprocess.run(['git', 'merge-base', '--is-ancestor', args.candidate, 'HEAD'], cwd=source, check=True)
    changed = set(git('diff', '--name-only', args.candidate, 'HEAD').splitlines())
    if not changed <= ALLOWED_DIFF:
        raise ExperimentError('business_source_differs_from_frozen_candidate')
    runner_temp = Path(os.environ['RUNNER_TEMP']).resolve()
    work = Path(args.work_root).resolve()
    if not work.is_relative_to(runner_temp) or work == runner_temp or work.exists():
        raise ExperimentError('work_root_must_be_new_under_runner_temp')
    work.mkdir(mode=0o700)
    disk = DiskObserver(work, result, checkpoint)
    env = dict(os.environ, IDENTITYV_SIGNING_MODE='adhoc', IDENTITYV_BUILD_ROOT=str(work / 'build'), IDENTITYV_TEST_HEADLESS='1')
    env.pop('IDENTITYV_SIGNING_IDENTITY', None)
    result['stage'] = 'intel-prerequisite'
    intel = subprocess.run(['/usr/bin/arch', '-x86_64', '/usr/bin/true'], stdin=subprocess.DEVNULL,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
    result['rosettaProbeExitCode'] = intel.returncode
    if intel.returncode != 0:
        raise ExperimentError('rosetta_required_before_build')
    result['nativeUIChecks'] = 'deferred_using_supported_test_only_flag'
    result['stage'] = 'build'
    result['buildSeconds'] = round(run_private(['./buildPlayerLauncher.command'], source, env,
                                             work / 'build.log', disk, 1200), 2)
    resources = work / 'build/第五人格启动器.app/Contents/Resources'
    provenance = json.loads((resources / 'build-provenance.json').read_text())
    if provenance.get('sourceCommit') != result['checkoutCommit'] or provenance.get('sourceClean') is not True:
        raise ExperimentError('build_provenance_mismatch')
    result['buildNumber'] = provenance.get('buildNumber')
    home, destination, tasks = work / 'home', work / 'game', work / 'tasks'
    for directory in (home, destination, tasks):
        directory.mkdir(mode=0o700)
    env.update(HOME=str(home), IDENTITYV_AGENT_TASK_ROOT=str(tasks))
    for key in ('GH_TOKEN', 'GITHUB_TOKEN'):
        env.pop(key, None)
    manager = str(resources / 'IdentityVProductManager')
    result['stage'] = 'prerequisites'
    result['prerequisiteSeconds'] = round(run_private([manager, 'check-runtime-prerequisites'], source, env,
                                                    work / 'prerequisites.log', disk, 15), 2)
    result['stage'] = 'manifest'
    manifest_file = work / 'manifest.json'
    with manifest_file.open('wb') as out, (work / 'manifest-error.log').open('wb') as err:
        manifest_start = time.monotonic()
        subprocess.run([manager, 'resolve-manifest', '--json', '--product', args.product], env=env,
                       stdout=out, stderr=err, check=True, timeout=90)
    manifest = json.loads(manifest_file.read_bytes())
    total = manifest['totalByteCount']
    result['manifestSeconds'] = round(time.monotonic() - manifest_start, 2)
    result['manifest'] = {'versionCode': manifest['versionCode'], 'totalByteCount': total,
                          'fileCount': len(manifest['files']),
                          'sha256': hashlib.sha256(manifest_file.read_bytes()).hexdigest()}
    result['stage'] = 'space-preflight'
    result['spaceReserveGiB'] = {'runtimeAndTransient': 4, 'hotUpdate': 4, 'stopFloor': 6}
    result['requiredFreeBeforeInstallBytes'] = required_space(total)
    result['freeBeforeInstallBytes'] = disk.sample()
    if result['freeBeforeInstallBytes'] < required_space(total):
        raise ExperimentError('insufficient_preflight_space')
    def agent(*arguments):
        p = subprocess.run([manager, 'agent', *arguments], env=env, capture_output=True, check=True, timeout=20)
        return json.loads(p.stdout)
    result['stage'] = 'installation'
    receipt = agent('start', 'install', '--product', args.product, '--destination-parent', str(destination))
    task_id = str(uuid.UUID(receipt['taskId']))
    result['taskId'] = task_id
    supervise(agent, task_id, disk, tasks / task_id.upper() / 'events.jsonl', result)
    result['stage'] = 'published-state'
    # Status is a small JSON document. Query the same core after the task's verified finish.
    status = subprocess.run([manager, 'status', '--json'], env=env, capture_output=True, check=True, timeout=30)
    game = verify_ready(json.loads(status.stdout), destination, manifest['versionCode'], args.product)
    result['stage'] = 'complete'
    result['success'] = True
    result['fullBaseManifestVerification'] = 'performed_by_successful_install_core'
    if args.observe_launch:
        observe_launch(manager, env, game, args.product, work, Path(args.report_root), result)
    disk.sample()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--candidate', required=True)
    parser.add_argument('--product', choices=['mainland', 'global'], default='mainland')
    parser.add_argument('--observe-launch', action='store_true')
    parser.add_argument('--work-root', required=True)
    parser.add_argument('--report-root', required=True)
    args = parser.parse_args()
    result = {'schemaVersion': 1, 'success': False, 'product': args.product,
              'gameLaunched': False, 'accountLoginAttempted': False, 'payloadUploaded': False}
    start = time.monotonic()
    target = None
    if os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('RUNNER_TEMP'):
        parent = Path(args.report_root).resolve()
        temp = Path(os.environ['RUNNER_TEMP']).resolve()
        if parent != temp and parent.is_relative_to(temp):
            parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            target = parent / 'result.json'
    def checkpoint():
        result['totalSeconds'] = round(time.monotonic() - start, 2)
        if target:
            partial = target.with_suffix('.partial')
            partial.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
            partial.replace(target)
    try:
        experiment(args, result, checkpoint)
    except Exception as error:
        work = Path(args.work_root)
        stage = result.get('stage')
        logs = {'build': 'build.log', 'prerequisites': 'prerequisites.log', 'manifest': 'manifest-error.log'}
        log = work / logs.get(stage, 'not-collected')
        if stage in logs and log.is_file():
            result['diagnosticTail'] = safe_diagnostic(log)
        if isinstance(error, subprocess.CalledProcessError):
            result['subprocessExitCode'] = error.returncode
        # Exception messages from subprocesses may contain raw stdout/URLs: retain only class/code.
        result['failure'] = str(error) if isinstance(error, ExperimentError) else type(error).__name__
    checkpoint()
    print(json.dumps(result, ensure_ascii=False), flush=True)
    return 0 if result['success'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
