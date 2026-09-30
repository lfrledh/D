"""CPU-only simulated App driver contract checks. No model or GPU imports."""

from __future__ import annotations

from contextlib import contextmanager, redirect_stdout
import hashlib
import io
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import textwrap
import types
import unittest
from unittest import mock
import uuid


ADAPTERS = Path(__file__).resolve().parents[1] / "Adapters"
sys.path.insert(0, str(ADAPTERS))
import app_video_driver as driver


class AppVideoDriverTests(unittest.TestCase):
    def setUp(self):
        evidence_tmp = Path(os.environ["TMPDIR"])
        self.fixture = tempfile.TemporaryDirectory(prefix="app-driver-", dir=evidence_tmp)
        self.addCleanup(self.fixture.cleanup)
        self.root = Path(self.fixture.name)
        self.pack = self.root / "pack"
        self.pack.mkdir()
        (self.pack / "model").mkdir()
        (self.pack / "text_encoder").mkdir()
        self.task = self.root / "task"
        self.task.mkdir()
        (self.task / "tmp").mkdir()
        (self.task / "cache").mkdir()
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.engine_dir = self.root / "engine"
        self.engine_dir.mkdir()
        self.previous_tmpdir = os.environ.get("TMPDIR")
        self.previous_tempdir = tempfile.tempdir
        self.previous_offline = {name: os.environ.get(name) for name in
                                 ("HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE", "LTX2_GEMMA_MAX_LENGTH")}
        os.environ["TMPDIR"] = str(self.task / "tmp")
        os.environ.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", LTX2_GEMMA_MAX_LENGTH="1024")
        self.addCleanup(self._restore_env)
        self.ffprobe = self._program("tools/ffprobe", '''
            #!/usr/bin/env python3
            import json, pathlib, sys
            data = pathlib.Path(sys.argv[-1]).read_bytes()
            h3 = data.startswith(b'SIM-H3')
            frames = 22 if h3 else 9
            rate = '32000' if h3 else '48000'
            duration = '11/12' if h3 else '3/8'
            print(json.dumps({'streams': [
                {'codec_type':'video','codec_name':'h264','width':32,'height':32,
                 'nb_read_frames':str(frames),'avg_frame_rate':'24/1','duration':duration,'start_time':'0'},
                {'codec_type':'audio','codec_name':'aac','sample_rate':rate,'channels':2,
                 'duration':duration,'start_time':'0'}]}))
        ''')
        self.ffmpeg = self._program("tools/ffmpeg", '''
            #!/usr/bin/env python3
            import sys
            print('simulated decode diagnostic', file=sys.stderr)
        ''')
        self.h3_engine = self._program("engine/h3", '''
            #!/usr/bin/env python3
            import json, os, pathlib, sys
            args = dict(item[2:].split('=',1) for item in sys.argv[1:] if item.startswith('--') and '=' in item)
            pathlib.Path(args['output']).write_bytes(b'SIM-H3 candidate')
            pathlib.Path('engine-observation.json').write_text(json.dumps({
                'pgid':os.getpgid(0),'parent_pgid':os.getpgid(os.getppid()),
                'seed':args['seed'],'tmpdir':os.environ['TMPDIR'],
                'h3':{key:value for key,value in os.environ.items() if key.startswith('H3_')}}))
            print('plain H3 diagnostic, not NDJSON')
        ''')
        self.shader = self.engine_dir / "h3.metal"
        self.shader.write_bytes(b"SIMULATED H3 shader")
        self.run_id = str(uuid.uuid4())
        self.profile = driver.H3
        self.request = self._request(self.profile)
        self._write_wire()

    def _restore_env(self):
        if self.previous_tmpdir is None:
            os.environ.pop("TMPDIR", None)
        else:
            os.environ["TMPDIR"] = self.previous_tmpdir
        for name, value in self.previous_offline.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value
        tempfile.tempdir = self.previous_tempdir

    def _program(self, relative, source):
        path = self.root / relative
        path.write_text(textwrap.dedent(source).lstrip(), encoding="utf-8")
        path.chmod(0o700)
        return path

    def _request(self, profile):
        return {"schema_version": 1, "profile": profile, "prompt": "-a prompt without truncation",
                "negative_prompt": "", "width": 32, "height": 32,
                "frames": 22 if profile == driver.H3 else 9, "steps": 2, "fps": 24.0,
                "seed": 2**53 + 17 if profile == driver.H3 else 123,
                "stream_weights": True, "cfg_scale": 1.0, "stg_scale": 0.0}

    def _write_wire(self, *, manifest_profile=None):
        identity = manifest_profile or self.profile
        model_revision, text_revision = driver.REVISIONS[identity]
        manifest = {"schemaVersion": 1, "profile": identity, "modelRevision": model_revision}
        if text_revision is not None:
            manifest["textEncoderRevision"] = text_revision
        raw_manifest = json.dumps(manifest, sort_keys=True).encode()
        (self.pack / driver.MANIFEST_NAME).write_bytes(raw_manifest)
        wire = {"schema_version": 1, "run_id": self.run_id,
                "manifest_sha256": hashlib.sha256(raw_manifest).hexdigest(), "request": self.request}
        (self.task / "request.json").write_bytes(json.dumps(wire, sort_keys=True).encode())

    def _args(self, *, h3=True):
        return types.SimpleNamespace(request=str(self.task / "request.json"), pack=str(self.pack),
            ffmpeg=str(self.ffmpeg), ffprobe=str(self.ffprobe),
            h3_engine=str(self.h3_engine) if h3 else None,
            h3_shader=str(self.shader) if h3 else None,
            access_manifest=None, access_run_id=None)

    def _h3_patches(self):
        import h3_admission, h3_job
        return (mock.patch.object(h3_admission, "admit_h3_fl2va", return_value={"simulated": True}),
                mock.patch.object(h3_job, "SHADER_SHA256", hashlib.sha256(self.shader.read_bytes()).hexdigest()))

    def _result(self):
        return json.loads((self.task / "result.json").read_text())

    def test_h3_success_frozen_seed_inherited_group_and_plain_diagnostic(self):
        admission, shader = self._h3_patches()
        with admission, shader:
            self.assertEqual(driver.run(self._args()), 0)
        record = self._result()
        observed = json.loads((self.task / "engine-observation.json").read_text())
        self.assertEqual(observed["seed"], str(2**53 + 17))
        self.assertEqual(observed["pgid"], observed["parent_pgid"])
        self.assertEqual(observed["tmpdir"], str(self.task / "tmp"))
        self.assertEqual(observed["h3"], {"H3_DIT_F32_FINAL": "1", "H3_FFMPEG": str(self.ffmpeg),
            "H3_FFPROBE": str(self.ffprobe), "H3_PROFILE": "1", "H3_NAX": "0", "H3_CPU_SAMPLER": "1"})
        self.assertEqual(record["source_request"]["seed"], 2**53 + 17)
        self.assertTrue(record["media_verified"])
        self.assertFalse(record["published"])
        self.assertEqual(record["media"]["audio_sample_rate"], 32000)
        self.assertIn("plain H3 diagnostic", (self.task / "engine.stdout").read_text())
        self.assertNotIn("mlx", sys.modules)

    def test_h3_invalid_wire_and_guidance_precede_admission(self):
        import h3_admission
        for field, value in (("cfg_scale", 1.5), ("stg_scale", 1), ("fps", 23.5),
                             ("seed", True), ("stream_weights", 1), ("width", True)):
            with self.subTest(field=field):
                self.request[field] = value
                self._write_wire()
                (self.task / "result.json").unlink(missing_ok=True)
                with mock.patch.object(h3_admission, "admit_h3_fl2va") as admit:
                    self.assertEqual(driver.run(self._args()), 2)
                    admit.assert_not_called()
                self.assertFalse((self.task / "candidate.mp4").exists())
                self.request[field] = self._request(driver.H3)[field]

    def test_ltx_inprocess_full_and_q8_keep_separate_identity(self):
        import ltx_admission, ltx_job
        for profile in (driver.LTX_FULL, driver.LTX_TEST):
            with self.subTest(profile=profile):
                self.profile = profile
                self.request = self._request(profile)
                self._write_wire()
                called = []
                module = types.ModuleType("ltx_pipelines_mlx")
                cli = types.ModuleType("ltx_pipelines_mlx.cli")
                def main():
                    called.append(tuple(sys.argv))
                    self.assertEqual(sys.argv[1], "generate")
                    (self.task / "candidate.mp4").write_bytes(b"SIM-LTX candidate")
                    print("plain in-process LTX diagnostic")
                    raise SystemExit(0)
                cli.main = main
                with mock.patch.dict(sys.modules, {"ltx_pipelines_mlx": module,
                                                   "ltx_pipelines_mlx.cli": cli}), \
                     mock.patch.object(ltx_admission, "admit_ltx23", return_value={"profile": profile}) as admit, \
                     mock.patch.object(ltx_job, "_confirm_tokenizer_patch", return_value="simulated patch"), \
                     mock.patch("socket.socket.connect", side_effect=AssertionError("network forbidden")) as connect:
                    output = io.StringIO()
                    with redirect_stdout(output):
                        self.assertEqual(driver.run(self._args(h3=False)), 0)
                    connect.assert_not_called()
                self.assertEqual(len(called), 1)
                self.assertIn("plain in-process LTX diagnostic", output.getvalue())
                self.assertEqual(admit.call_args.args[0], profile)
                self.assertEqual(self._result()["profile"], profile)
                self.assertEqual(self._result()["media"]["audio_sample_rate"], 48000)
                self.assertNotIn("mlx", sys.modules)
                (self.task / "candidate.mp4").unlink()
                (self.task / "result.json").unlink()
                (self.task / "probe-log.stdout").unlink()
                (self.task / "probe-log.stderr").unlink()
                (self.task / "decode-log.stdout").unlink()
                (self.task / "decode-log.stderr").unlink()

    def test_mismatch_unknown_profile_and_duplicate_keys(self):
        self.profile = driver.LTX_TEST
        self.request = self._request(driver.LTX_TEST)
        self._write_wire(manifest_profile=driver.LTX_FULL)
        with mock.patch.object(driver, "_execute") as execute:
            self.assertEqual(driver.run(self._args(h3=False)), 2)
            execute.assert_not_called()
        (self.task / "result.json").unlink()
        self.profile = driver.LTX_25
        self.request = self._request(driver.LTX_25)
        self._write_wire()
        self.assertEqual(driver.run(self._args(h3=False)), 2)
        self.assertIn("no accessible verified resource inventory", self._result()["error"]["message"])
        (self.task / "result.json").unlink()
        raw = (self.task / "request.json").read_bytes()
        (self.task / "request.json").write_bytes(raw.replace(b'"schema_version": 1,', b'"schema_version": 1, "schema_version": 1,', 1))
        self.assertEqual(driver.run(self._args(h3=False)), 2)
        self.assertIn("duplicate JSON key", self._result()["error"]["message"])

    def test_existing_outputs_and_symlink_are_preserved(self):
        candidate = self.task / "candidate.mp4"
        candidate.write_bytes(b"ORIGINAL")
        self.assertEqual(driver.run(self._args()), 2)
        self.assertEqual(candidate.read_bytes(), b"ORIGINAL")
        (self.task / "result.json").unlink()
        candidate.unlink()
        report = self.task / "result.json"
        report.write_bytes(b"ORIGINAL REPORT")
        self.assertEqual(driver.run(self._args()), 2)
        self.assertEqual(report.read_bytes(), b"ORIGINAL REPORT")
        report.unlink()
        actual = self.task / "other.json"
        actual.write_bytes((self.task / "request.json").read_bytes())
        (self.task / "request.json").unlink()
        (self.task / "request.json").symlink_to(actual)
        with self.assertRaises(ValueError):
            driver.run(self._args())

    def test_decode_failure_and_input_mutation_do_not_verify(self):
        admission, shader = self._h3_patches()
        self.ffmpeg.write_text("#!/usr/bin/env python3\nimport sys\nsys.exit(7)\n")
        self.ffmpeg.chmod(0o700)
        with admission, shader:
            self.assertEqual(driver.run(self._args()), 2)
        self.assertFalse(self._result()["media_verified"])
        self.assertTrue((self.task / "candidate.mp4").exists())
        for name in ("candidate.mp4", "result.json", "h3_shaders.metal", "engine.stdout", "engine.stderr",
                     "probe-log.stdout", "probe-log.stderr", "decode-log.stdout", "decode-log.stderr",
                     "engine-observation.json"):
            (self.task / name).unlink(missing_ok=True)
        self.ffmpeg = self._program("tools/ffmpeg", '''
            #!/usr/bin/env python3
            import sys
            print('simulated full decode', file=sys.stderr)
        ''')
        # A simulated engine mutates the parent-issued request after creation.
        self.h3_engine = self._program("engine/h3", '''
            #!/usr/bin/env python3
            import pathlib, sys
            args = dict(item[2:].split('=',1) for item in sys.argv[1:] if item.startswith('--') and '=' in item)
            pathlib.Path(args['output']).write_bytes(b'SIM-H3 candidate')
            p = pathlib.Path('request.json')
            p.write_bytes(p.read_bytes() + b' ')
        ''')
        admission, shader = self._h3_patches()
        with admission, shader:
            self.assertEqual(driver.run(self._args()), 2)
        self.assertIn("changed during execution", self._result()["error"]["message"])
        self.assertFalse(self._result()["media_verified"])

    def test_engine_failure_records_unverified_without_candidate(self):
        self.h3_engine = self._program("engine/h3", '''
            #!/usr/bin/env python3
            import sys
            print('simulated engine failure', file=sys.stderr)
            sys.exit(7)
        ''')
        admission, shader = self._h3_patches()
        with admission, shader:
            self.assertEqual(driver.run(self._args()), 2)
        self.assertFalse(self._result()["media_verified"])
        self.assertFalse((self.task / "candidate.mp4").exists())
        self.assertIn("simulated engine failure", (self.task / "engine.stderr").read_text())

    def test_access_scope_is_exact_and_precedes_read(self):
        access = self.root / "access.json"
        access.write_bytes(b"simulated bootstrap")
        args = self._args()
        args.access_manifest = str(access)
        args.access_run_id = self.run_id
        state = {"active": False, "read": False}
        @contextmanager
        def acquire(path, *, run_id, allowed_paths):
            self.assertEqual(path, access)
            self.assertEqual(run_id, self.run_id)
            self.assertEqual(allowed_paths, [self.pack, self.task])
            state["active"] = True
            try:
                yield
            finally:
                state["active"] = False
        original_read = driver._read_snapshot
        def read(path, limit):
            self.assertTrue(state["active"])
            state["read"] = True
            return original_read(path, limit)
        module = types.ModuleType("d_audio_access")
        module.acquire_file_access = acquire
        module.AudioAccessError = RuntimeError
        original_child = driver._run_child
        def child(*child_args, **kwargs):
            self.assertTrue(state["active"])
            return original_child(*child_args, **kwargs)
        admission, shader = self._h3_patches()
        with mock.patch.dict(sys.modules, {"d_audio_access": module}), \
             mock.patch.object(driver, "_read_snapshot", side_effect=read), \
             mock.patch.object(driver, "_run_child", side_effect=child), admission, shader:
            self.assertEqual(driver.run(args), 0)
        self.assertTrue(state["read"])
        self.assertFalse(state["active"])

    def test_helper_logs_are_bounded_and_direct_timeout_is_reaped(self):
        noisy = self._program("tools/noisy", '''
            #!/usr/bin/env python3
            import sys
            sys.stdout.buffer.write(b'o' * (4 * 1024 * 1024 + 7))
            sys.stderr.buffer.write(b'e' * (4 * 1024 * 1024 + 7))
        ''')
        result = driver._run_child([str(noisy)], "bounded", 10, self.task)
        self.assertEqual(result["status"], "success")
        self.assertTrue(result["stdout_truncated"])
        self.assertTrue(result["stderr_truncated"])
        self.assertEqual((self.task / "bounded.stdout").stat().st_size, driver.MAX_LOG)
        self.assertEqual((self.task / "bounded.stderr").stat().st_size, driver.MAX_LOG)
        sleeper = self._program("tools/sleeper", '''
            #!/usr/bin/env python3
            import time
            time.sleep(10)
        ''')
        timed = driver._run_child([str(sleeper)], "timed", 0.1, self.task)
        self.assertEqual(timed["status"], "timeout")

    def test_manifest_mutation_and_overlap_fail_closed(self):
        self.h3_engine = self._program("engine/h3", '''
            #!/usr/bin/env python3
            import pathlib, sys
            args = dict(item[2:].split('=',1) for item in sys.argv[1:] if item.startswith('--') and '=' in item)
            pathlib.Path(args['output']).write_bytes(b'SIM-H3 candidate')
            pack = pathlib.Path(args['model-dir']).parent
            manifest = pack / 'D-VIDEO-PACK.json'
            manifest.write_bytes(manifest.read_bytes() + b' ')
        ''')
        admission, shader = self._h3_patches()
        with admission, shader:
            self.assertEqual(driver.run(self._args()), 2)
        self.assertIn("changed during execution", self._result()["error"]["message"])
        self.assertFalse(self._result()["media_verified"])
        self.assertEqual(self._result()["source_request"]["seed"], 2**53 + 17)
        # A task nested below the pack is never a private output location.
        nested = self.pack / "task"
        nested.mkdir()
        (nested / "request.json").write_bytes((self.task / "request.json").read_bytes())
        args = self._args()
        args.request = str(nested / "request.json")
        self.assertEqual(driver.run(args), 2)
        self.assertFalse((nested / "result.json").exists())


if __name__ == "__main__":
    unittest.main()
