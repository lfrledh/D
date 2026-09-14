"""CPU application-bootstrap checks; no model loading or real bookmarks."""
import argparse
from contextlib import contextmanager
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

sys.path.insert(0, os.environ['D_VIDEO_PYTHON'])
import d_video_run as runner


class VideoAccessTests(unittest.TestCase):
    def arguments(self, root):
        return argparse.Namespace(request=root/'run'/'request.json', model=root/'model',
            tokenizer=root/'tokenizer', output=root/'run'/'frames',
            access_manifest=root/'bootstrap'/'access.json',
            access_run_id='cfe9876a-3e85-4de9-95fa-fa7b8f0e0bc6')

    def test_exact_grants_and_cleanup_precede_success_event(self):
        with tempfile.TemporaryDirectory(dir=os.environ['D_TEST_TEMP_DIR']) as tmp:
            args = self.arguments(Path(tmp)); events = []
            class AccessError(Exception): pass
            @contextmanager
            def grant(path, *, run_id, allowed_paths):
                self.assertEqual(path, args.access_manifest)
                self.assertEqual(run_id, args.access_run_id)
                self.assertEqual(allowed_paths, [args.model, args.request.parent])
                events.append('acquired')
                try: yield
                finally: events.append('released')
            module = types.SimpleNamespace(acquire_file_access=grant, AudioAccessError=AccessError)
            with patch.dict(sys.modules, d_audio_access=module):
                with runner.application_access(args): events.append('executing')
            self.assertEqual(events, ['acquired', 'executing', 'released'])

    def test_denial_and_cleanup_failure_are_explicit(self):
        with tempfile.TemporaryDirectory(dir=os.environ['D_TEST_TEMP_DIR']) as tmp:
            args = self.arguments(Path(tmp))
            class AccessError(Exception): pass
            @contextmanager
            def broken(*a, **kw):
                yield
                raise AccessError('controlled cleanup failure')
            module = types.SimpleNamespace(acquire_file_access=broken, AudioAccessError=AccessError)
            argv = ['video', '--request', str(args.request), '--model', str(args.model),
                    '--tokenizer', str(args.tokenizer), '--output', str(args.output),
                    '--access-manifest', str(args.access_manifest), '--access-run-id', args.access_run_id]
            out, err = io.StringIO(), io.StringIO()
            with patch.dict(sys.modules, d_audio_access=module), patch.object(sys, 'argv', argv), \
                 patch.object(sys, 'stdout', out), patch.object(sys, 'stderr', err), \
                 patch.object(runner, 'run', return_value={'type':'result'}) as run:
                self.assertEqual(runner.main(), 1)
                self.assertEqual(run.call_args.kwargs, {'access_run_id': args.access_run_id, 'emit_result': False})
            self.assertEqual(out.getvalue(), '')
            self.assertIn('controlled cleanup failure', err.getvalue())

    def test_path_and_identity_reject_before_external_read(self):
        args = self.arguments(Path('/controlled'))
        for name, value in [('access_run_id', None), ('access_run_id', '../bad'),
                            ('request', Path('/controlled/other.json')),
                            ('output', Path('/different/frames')), ('model', Path('/'))]:
            altered = argparse.Namespace(**vars(args)); setattr(altered, name, value)
            with self.subTest(name=name, value=value), self.assertRaises(ValueError):
                with runner.application_access(altered): self.fail('invalid capability entered')

    def test_request_identity_checked_before_model_or_tokenizer(self):
        with patch.object(runner, 'read_snapshot', return_value=({'runID':'other'}, 'sha', ())), \
             patch.object(runner, 'validate_request', side_effect=lambda x:x), \
             patch.object(runner, 'PreparedModel') as model:
            with self.assertRaisesRegex(ValueError, 'access run identity'):
                runner.run(Path('/request'), Path('/model'), Path('/tokenizer'), Path('/output'), access_run_id='expected')
            model.assert_not_called()

    def test_real_cli_missing_access_pair_fails_without_model_loading(self):
        with tempfile.TemporaryDirectory(dir=os.environ['D_TEST_TEMP_DIR']) as tmp:
            args = self.arguments(Path(tmp))
            cmd = [sys.executable, '-B', runner.__file__, '--request', str(args.request),
                '--model', str(args.model), '--tokenizer', str(args.tokenizer), '--output', str(args.output),
                '--access-run-id', args.access_run_id]
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout, '')
            self.assertIn('supplied together', result.stderr)
            self.assertEqual(list(Path(tmp).iterdir()), [])


if __name__ == '__main__': unittest.main(verbosity=2)
