import importlib.util
import json
import re
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('ci_full_install', Path(__file__).resolve().parents[1] / 'ciFullInstall.py')
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)


class CIInstallTests(unittest.TestCase):

    def test_game_process_pattern_accepts_windows_paths(self):
        # Python equivalent of pgrep's POSIX whitespace class.
        pattern = ci.GAME_PROCESS_PATTERN.replace('[[:space:]]', r'\s')
        for command in ['/tmp/game/dwrg.exe', r'C:\Games\IdentityV\dwrg.exe --example']:
            self.assertIsNotNone(re.search(pattern, command))
        self.assertIsNone(re.search(pattern, '/tmp/not-dwrg.exe'))

    def test_stop_uses_async_receipt_and_terminal_record_not_run_jsonl(self):
        calls = []
        task = '730cbf24-c60b-43f7-af85-e473865e90f8'
        def agent(*arguments):
            calls.append(arguments)
            if arguments[0] == 'start':
                return {'taskId': task, 'state': 'queued'}
            return {'taskId': task, 'state': 'succeeded', 'exitCode': 0}
        self.assertEqual(ci.stop_owned_product(agent, 'global')['exitCode'], 0)
        self.assertEqual(calls, [('start', 'stop', '--product', 'global'), ('task', task)])

    def test_diagnostic_never_publishes_credentials_or_url_query(self):
        with tempfile.TemporaryDirectory() as temp:
            log = Path(temp) / 'build.log'
            log.write_text('phase=build error=E42\nauthorization: Bearer do-not-copy\nhttps://example.invalid/a?opaque=private-value\n')
            diagnostic = ci.safe_diagnostic(log)
            self.assertIn('error=E42', diagnostic)
            self.assertNotIn('do-not-copy', diagnostic)
            self.assertNotIn('private-value', diagnostic)

    def test_resource_budget_and_cancellation(self):
        self.assertEqual(ci.required_space(17_602_266_736), 34 * ci.GIB)
        for size in (0, -1, True, '17000'):
            with self.assertRaises(ci.ExperimentError):
                ci.required_space(size)
        self.assertEqual(ci.stop_reason({'state': 'running'}, 5 * ci.GIB, 1, 10), 'free_space_below_6_gib')
        self.assertEqual(ci.stop_reason({'state': 'running'}, 8 * ci.GIB, 11, 10), 'installation_time_limit')
        self.assertIsNone(ci.stop_reason({'state': 'succeeded'}, 1, 100, 10))

    def test_publication_requires_real_game_and_closed_transaction(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            game = root / 'product/game'
            game.mkdir(parents=True)
            (game / 'dwrg.exe').write_bytes(b'fixture')
            doc = {'products': [{'productId': 'mainland', 'state': 'ready', 'gamePath': str(game), 'installedVersion': 'v1'}]}
            self.assertEqual(ci.verify_ready(doc, root, 'v1'), game.resolve())
            (game.parent / '.identityv-direct-install.json').write_text('{}')
            with self.assertRaises(ci.ExperimentError):
                ci.verify_ready(doc, root, 'v1')
            (game.parent / '.identityv-direct-install.json').unlink()
            with self.assertRaises(ci.ExperimentError):
                ci.verify_ready(doc, root, 'v2')
            with self.assertRaises(ci.ExperimentError):
                ci.verify_ready(doc, root / 'elsewhere', 'v1')

    def test_global_publication_checks_its_own_identity_and_marker(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            game = root / 'global/game'
            game.mkdir(parents=True)
            (game / 'dwrg.exe').write_bytes(b'fixture')
            doc = {'products': [{'productId': 'global', 'state': 'ready', 'gamePath': str(game), 'installedVersion': 'v1'}]}
            self.assertEqual(ci.verify_ready(doc, root, 'v1', 'global'), game.resolve())
            with self.assertRaises(ci.ExperimentError):
                ci.verify_ready(doc, root, 'v1', 'mainland')
            (game.parent / '.identityv-global-install.json').write_text('{}')
            with self.assertRaises(ci.ExperimentError):
                ci.verify_ready(doc, root, 'v1', 'global')

    def test_supervisor_cancels_own_task_and_does_not_claim_success(self):
        calls = []
        def agent(command, task):
            calls.append((command, task))
            if command == 'cancel':
                return {'state': 'running'}
            return {'state': 'running'} if len(calls) == 1 else {'state': 'cancelled', 'exitCode': 130}
        class LowDisk:
            def sample(self):
                return 5 * ci.GIB
        with tempfile.TemporaryDirectory() as temp:
            result = {}
            with self.assertRaisesRegex(ci.ExperimentError, 'free_space_below_6_gib'):
                ci.supervise(agent, 'owned-task', LowDisk(), Path(temp) / 'events', result, poll=0)
            self.assertEqual(calls.count(('cancel', 'owned-task')), 1)
            self.assertEqual(result['taskState'], 'cancelled')

    def test_supervisor_reads_real_terminal_and_bounded_phase_fields(self):
        class Disk:
            def sample(self):
                return 44 * ci.GIB
        with tempfile.TemporaryDirectory() as temp:
            events = Path(temp) / 'events'
            events.write_text(json.dumps({'payload': {'phase': 'verifying', 'url': 'https://example.invalid/?token=never-copy'}}) + '\n')
            result = {}
            ci.supervise(lambda *args: {'state': 'succeeded', 'exitCode': 0, 'childExitCode': 0}, 'task', Disk(), events, result, poll=0)
            self.assertEqual(result['taskState'], 'succeeded')
            self.assertNotIn('never-copy', json.dumps(result))
            with self.assertRaisesRegex(ci.ExperimentError, 'installation_did_not_succeed'):
                ci.supervise(lambda *args: {'state': 'failed', 'exitCode': 1}, 'task', Disk(), events, {}, poll=0)


if __name__ == '__main__':
    unittest.main()
