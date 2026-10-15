"""Read-only review preflight; fixtures live only under D_TEST_TEMP_DIR."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock
import uuid

sys.dont_write_bytecode = True
script = Path(__file__).resolve().parents[1] / 'launch-review.py'
spec = importlib.util.spec_from_file_location('review_launcher', script)
launcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launcher)


class ReviewLauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ['D_TEST_TEMP_DIR'])
        self.addCleanup(self.temp.cleanup)
        self.parent = Path(self.temp.name)
        self.session = str(uuid.uuid4()).upper()
        self.root = self.parent / self.session
        self.root.mkdir()
        self.marker = self.root / 'download-review-fixture.json'
        self.fixture = {'task': 'D-DOWNLOAD-MANAGEMENT-01', 'session': self.session,
                        'fixtures': 'A/B/C 18 MiB each; no inference route'}

    def test_storage_policy(self):
        cases = ['valid', 'missing-fixtures', 'wrong-fixtures', 'wrong-task', 'wrong-session',
                 'not-object', 'malformed', 'oversized', 'missing-marker', 'symlink-marker']
        cases += ['symlink:' + name for name in launcher.REVIEW_SERVICE_PATHS]
        for kind in cases:
            with self.subTest(kind=kind):
                data = dict(self.fixture)
                if kind == 'missing-fixtures': data.pop('fixtures')
                if kind.startswith('wrong-'): data[kind[6:]] = 'incorrect'
                self.marker.write_text(json.dumps(data))
                link = None
                if kind == 'not-object': self.marker.write_text('[]')
                if kind == 'malformed': self.marker.write_text('{')
                if kind == 'oversized': self.marker.write_text(' ' * 4097)
                if kind in ['missing-marker', 'symlink-marker']: self.marker.unlink()
                if kind == 'symlink-marker':
                    target = self.parent / 'marker-copy.json'; target.write_text(json.dumps(self.fixture))
                    self.marker.symlink_to(target); link = self.marker
                if kind.startswith('symlink:'):
                    link = self.root / kind.split(':', 1)[1]
                    link.parent.mkdir(parents=True, exist_ok=True)
                    link.symlink_to(self.parent / 'absent-target')
                before = sorted(str(p.relative_to(self.root)) for p in self.root.rglob('*'))
                if kind == 'valid': launcher.validate_review_storage(self.root, self.session)
                else:
                    with self.assertRaises((OSError, ValueError)):
                        launcher.validate_review_storage(self.root, self.session)
                # When supplied, compare every fixture with the unchanged real App validator.
                validator = os.environ.get('D_REVIEW_STORAGE_VALIDATOR')
                if validator:
                    result = subprocess.run([validator, str(self.root)], capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0 if kind == 'valid' else 2, result.stdout)
                self.assertEqual(before, sorted(str(p.relative_to(self.root)) for p in self.root.rglob('*')))
                self.assertFalse((self.root / '.d-review-session.lock').exists())
                if link: link.unlink()
        print('STORAGE_SCENARIOS=' + str(len(cases)))

    def test_incomplete_marker_cannot_start_server_or_app(self):
        self.fixture.pop('fixtures'); self.marker.write_text(json.dumps(self.fixture))
        app = self.parent / 'Review.app'; (app / 'Contents').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'DReviewLaunchMode': 'isolated-download-v1', 'CFBundleIdentifier': 'first-test.D.review.D'}))
        receipt = self.parent / 'review.json'
        receipt.write_text(json.dumps({'app': str(app), 'root': str(self.root), 'worktree': str(self.parent),
            'source_sha': 'fixture-sha', 'team': 'FIXTURE', 'code_files': {}, 'session': self.session}))
        arguments = ['launch-review.py', '--receipt', str(receipt), '--fixture-server', str(self.parent / 'server.py'), '--launch']
        signature = types.SimpleNamespace(stderr='Authority=Apple Development:\nTeamIdentifier=FIXTURE', returncode=0)
        with mock.patch.object(sys, 'argv', arguments), \
             mock.patch.object(launcher.subprocess, 'check_output', return_value='fixture-sha\n'), \
             mock.patch.object(launcher.subprocess, 'run', return_value=signature), \
             mock.patch.object(launcher.subprocess, 'Popen') as popen, \
             contextlib.redirect_stderr(io.StringIO()) as errors:
            self.assertEqual(launcher.main(), 2)
            popen.assert_not_called()
            self.assertIn('review fixture marker', errors.getvalue())
        self.assertEqual([p.name for p in self.root.iterdir()], ['download-review-fixture.json'])

    def test_exit_code_preserves_child_failure(self):
        for child, ready, expected in [(0, True, 0), (0, False, 2), (7, True, 7), (7, False, 7), (-15, False, 143)]:
            with self.subTest(child=child, ready=ready):
                self.assertEqual(launcher.launch_exit_code(child, ready), expected)


if __name__ == '__main__':
    unittest.main()
