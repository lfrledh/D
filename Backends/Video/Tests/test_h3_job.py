"""CPU-only private-run fixtures. Fake engine/media tools never decode a model."""
import hashlib
import json
import os
from pathlib import Path
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1] / "Adapters"))
import h3_admission
import h3_job as m
from h3_plan import PROFILE


_CLI = '''import json, sys
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, sys.argv.pop(1))
import h3_admission, h3_job
manifest = Path(sys.argv.pop(1))
shader_hash = sys.argv.pop(1)
if shader_hash != "production": h3_job.SHADER_SHA256 = shader_hash
with patch.object(h3_admission, "_inventory", side_effect=lambda: json.loads(manifest.read_bytes())):
    try: sys.exit(h3_job.main())
    except Exception as error:
        print(type(error).__name__ + ": " + str(error), file=sys.stderr, flush=True)
        sys.exit(2)
'''


class H3JobTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(dir=os.environ["TMPDIR"])
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.runtime = self.root / "runtime"
        self.tools = self.root / "tools"
        self.shaders = self.root / "shaders"
        self.model = self.root / "模型 原件"
        for directory in (self.runtime, self.tools, self.shaders, self.model / "FL2VA"):
            directory.mkdir(parents=True)
        self.engine = self.runtime / "h3 fake"
        self.ffprobe = self.tools / "ffprobe"
        self.ffmpeg = self.tools / "ffmpeg"
        self.shader = self.shaders / "h3_shaders.metal"
        self.shader.write_bytes(b"fixed simulated shader")
        self.resource = self.model / "FL2VA/weights.safetensors"
        header = json.dumps({"tensor": {"dtype": "BF16", "shape": [1],
                                        "data_offsets": [0, 2]}}).encode()
        self.resource.write_bytes(struct.pack("<Q", len(header)) + header + b"\0\0")
        self.manifest = self.root / "tiny-test-inventory.json"
        data = self.resource.read_bytes()
        self.manifest.write_text(json.dumps({
            "schema_version": 1, "profile": PROFILE,
            "repository": h3_admission.REPOSITORY, "revision": h3_admission.REVISION,
            "files": [{"name": "FL2VA/weights.safetensors", "size": len(data),
                       "sha256": hashlib.sha256(data).hexdigest(),
                       "tensor_policy": "floating_only"}],
        }))
        self._executable(self.engine, '''import json, os, pathlib, sys, time
root = pathlib.Path(__file__).parent
args = dict(part.split("=", 1) for part in sys.argv[1:] if part.startswith("--") and "=" in part)
mode = (root / "mode").read_text() if (root / "mode").exists() else "success"
pathlib.Path("engine-observation.json").write_text(json.dumps({"argv": sys.argv[1:], "env": dict(os.environ)}))
if mode == "sleep":
    pathlib.Path("child-pid").write_text(str(os.getpid()))
    time.sleep(30)
pathlib.Path(args["--output"]).write_bytes(b"simulated candidate")
if mode == "fail": sys.exit(7)
''')
        self._executable(self.ffprobe, '''import pathlib, sys
sys.stdout.write((pathlib.Path(__file__).parent / "probe.json").read_text())
''')
        self._executable(self.ffmpeg, '''import pathlib, sys
sys.exit(9 if (pathlib.Path(__file__).parent / "fail-decode").exists() else 0)
''')
        self.request = {"schema_version": 1, "profile": PROFILE,
                        "prompt": "山 / hello ; $(no shell)", "negative_prompt": "",
                        "width": 64, "height": 64, "frames": 22, "fps": 24,
                        "steps": 2, "seed": 42, "stream_weights": True}
        self.request_path = self.root / "request.json"
        self.request_path.write_text(json.dumps(self.request))
        self.probe = {"streams": [
            {"codec_type": "video", "codec_name": "h264", "width": 64, "height": 64,
             "nb_read_frames": "22", "avg_frame_rate": "24/1", "duration": "0.91666667", "start_time": "0"},
            {"codec_type": "audio", "codec_name": "aac", "sample_rate": "32000", "channels": 2,
             "duration": "0.91666667", "start_time": "0"},
        ]}
        self._probe()
        self.run_directory = self.root / "private run 空格"

    def _executable(self, path, body):
        path.write_text("#!" + sys.executable + "\n" + body)
        path.chmod(0o700)

    def _probe(self):
        (self.tools / "probe.json").write_text(json.dumps(self.probe))

    def command(self, shader_hash="production"):
        return [sys.executable, "-B", "-c", _CLI,
                str(Path(m.__file__).parent), str(self.manifest), shader_hash,
                "--request", str(self.request_path), "--engine", str(self.engine),
                "--shader", str(self.shader), "--model", str(self.model),
                "--run-directory", str(self.run_directory),
                "--ffmpeg", str(self.ffmpeg), "--ffprobe", str(self.ffprobe),
                "--timeout", "8"]

    def cli(self, *, timeout=20):
        return subprocess.run(self.command(), cwd=self.root, env=os.environ.copy(),
                              stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout)

    def test_cli_success_frozen_request_environment_and_no_overwrite(self):
        digest = hashlib.sha256(self.shader.read_bytes()).hexdigest()
        with patch.dict(os.environ, {"H3_EXTRA_OVERRIDE": "must not inherit", "AWS_SECRET_ACCESS_KEY": "fixture-secret"}):
            completed = subprocess.run(self.command(digest), cwd=self.root, env=os.environ.copy(),
                                       capture_output=True, text=True, timeout=20)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        record = json.loads((self.run_directory / "result.json").read_text())
        self.assertEqual(record["schema"], "d.h3.private-candidate.v1")
        self.assertTrue(record["media_verified"])
        self.assertFalse(record["published"])
        self.assertFalse(record["engine_source_verified"])
        self.assertEqual(record["engine_sha256"], hashlib.sha256(self.engine.read_bytes()).hexdigest())
        self.assertEqual(record["candidate_file"], "candidate.mp4")
        self.assertEqual(record["sha256"], hashlib.sha256(b"simulated candidate").hexdigest())
        self.assertEqual((self.run_directory / "h3_shaders.metal").read_bytes(), self.shader.read_bytes())
        observation = json.loads((self.run_directory / "engine-observation.json").read_text())
        self.assertEqual(observation["env"]["H3_DIT_F32_FINAL"], "1")
        self.assertEqual(observation["env"]["H3_CPU_SAMPLER"], "1")
        self.assertNotIn("H3_EXTRA_OVERRIDE", observation["env"])
        self.assertNotIn("AWS_SECRET_ACCESS_KEY", observation["env"])
        self.assertIn("--layers=50", observation["argv"])
        self.assertIn("--ssd-streaming", observation["argv"])
        self.assertIn("--prompt=" + self.request["prompt"], observation["argv"])
        second = subprocess.run(self.command(digest), cwd=self.root, env=os.environ.copy(),
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(second.returncode, 2)
        self.assertEqual((self.run_directory / "candidate.mp4").read_bytes(), b"simulated candidate")

    def test_admission_mutation_cannot_change_frozen_plan_or_result(self):
        original = self.request.copy()
        digest = hashlib.sha256(self.shader.read_bytes()).hexdigest()
        real_admission = h3_admission.admit_h3_fl2va

        def mutating_admission(model, *, cancelled):
            self.request["seed"] = 999
            self.request["prompt"] = "later prompt"
            self.request["stream_weights"] = False
            return real_admission(model, cancelled=cancelled)

        with patch.object(m, "SHADER_SHA256", digest), \
                patch.object(h3_admission, "_inventory", side_effect=lambda: json.loads(self.manifest.read_bytes())), \
                patch.object(m, "admit_h3_fl2va", side_effect=mutating_admission):
            result = m.execute(self.request, engine=self.engine, shader=self.shader,
                               model=self.model, run_directory=self.run_directory,
                               ffmpeg=self.ffmpeg, ffprobe=self.ffprobe,
                               timeout_seconds=8, cancel_event=threading.Event())
        argv = json.loads((self.run_directory / "engine-observation.json").read_text())["argv"]
        saved = json.loads((self.run_directory / "result.json").read_text())
        self.assertEqual(result["request"], original)
        self.assertEqual(saved["request"], original)
        self.assertEqual(saved["plan"]["provenance"]["request"], original)
        self.assertIn("--seed=42", argv)
        self.assertIn("--prompt=" + original["prompt"], argv)
        self.assertIn("--ssd-streaming", argv)
        self.assertNotIn("--seed=999", argv)

    def test_mutable_or_wrong_type_request_is_rejected_before_admission(self):
        for field, value in (("prompt", ["mutable"]), ("seed", True),
                             ("stream_weights", 1)):
            with self.subTest(field=field):
                invalid = self.request.copy()
                invalid[field] = value
                with patch.object(m, "admit_h3_fl2va") as admission:
                    with self.assertRaises(ValueError):
                        m.execute(invalid, engine=self.engine, shader=self.shader,
                                  model=self.model, run_directory=self.run_directory,
                                  ffmpeg=self.ffmpeg, ffprobe=self.ffprobe,
                                  timeout_seconds=8, cancel_event=threading.Event())
                    admission.assert_not_called()

    def test_wrong_shader_and_run_overlap_rejected_before_launch(self):
        wrong = self.cli()
        self.assertEqual(wrong.returncode, 2)
        self.assertFalse(self.run_directory.exists())
        event = threading.Event()
        with self.assertRaises(ValueError):
            m.execute(self.request, engine=self.engine, shader=self.shader, model=self.model,
                      run_directory=self.model / "nested-run", ffmpeg=self.ffmpeg,
                      ffprobe=self.ffprobe, timeout_seconds=8, cancel_event=event)
        self.assertFalse((self.model / "nested-run").exists())
        with self.assertRaises(ValueError):
            m.execute(self.request, engine=self.engine, shader=self.shader, model=self.model,
                      run_directory=self.runtime / "nested-run", ffmpeg=self.ffmpeg,
                      ffprobe=self.ffprobe, timeout_seconds=8, cancel_event=event)

    def test_cli_request_limit_and_invalid_request_keep_existing_resources(self):
        original = self.resource.read_bytes()
        self.request_path.write_bytes(b" " * (1024 * 1024 + 1))
        oversized = self.cli()
        self.assertEqual(oversized.returncode, 2)
        self.assertIn("1 MiB", oversized.stderr)
        self.assertFalse(self.run_directory.exists())
        self.assertEqual(self.resource.read_bytes(), original)
        self.request["frames"] = 23
        self.request_path.write_text(json.dumps(self.request))
        digest = hashlib.sha256(self.shader.read_bytes()).hexdigest()
        invalid = subprocess.run(self.command(digest), cwd=self.root, env=os.environ.copy(),
                                 capture_output=True, text=True, timeout=20)
        self.assertEqual(invalid.returncode, 2)
        record = json.loads((self.run_directory / "result.json").read_text())
        self.assertEqual(record["error"]["type"], "ValueError")
        self.assertIsNone(record["engine_process"])
        self.assertFalse((self.run_directory / "candidate.mp4").exists())
        self.assertEqual(self.resource.read_bytes(), original)

    def test_wrong_audio_process_failure_and_decode_failure_preserve_records(self):
        digest = hashlib.sha256(self.shader.read_bytes()).hexdigest()
        with patch.object(m, "SHADER_SHA256", digest), patch.object(h3_admission, "_inventory", side_effect=lambda: json.loads(self.manifest.read_bytes())):
            self.probe["streams"][1]["sample_rate"] = "48000"
            self._probe()
            with self.assertRaisesRegex(ValueError, "32000"):
                m.execute(self.request, engine=self.engine, shader=self.shader, model=self.model,
                          run_directory=self.run_directory, ffmpeg=self.ffmpeg, ffprobe=self.ffprobe,
                          timeout_seconds=8, cancel_event=threading.Event())
            record = json.loads((self.run_directory / "result.json").read_text())
            self.assertFalse(record["media_verified"])
            self.assertEqual(record["error"]["type"], "ValueError")
            self.assertEqual(record["media"]["audio_sample_rate"], 48000)
            self.assertTrue((self.run_directory / "probe-log/stdout.log").exists())
            self.assertTrue((self.run_directory / "candidate.mp4").exists())
            self.run_directory = self.root / "failed process"
            (self.runtime / "mode").write_text("fail")
            failed = m.execute(self.request, engine=self.engine, shader=self.shader, model=self.model,
                               run_directory=self.run_directory, ffmpeg=self.ffmpeg, ffprobe=self.ffprobe,
                               timeout_seconds=8, cancel_event=threading.Event())
            self.assertEqual(failed["engine_process"]["status"], "failed")
            self.assertFalse(failed["media_verified"])
            self.assertTrue((self.run_directory / "candidate.mp4").exists())
            self.run_directory = self.root / "failed decode"
            (self.runtime / "mode").unlink()
            self.probe["streams"][1]["sample_rate"] = "32000"
            self._probe()
            (self.tools / "fail-decode").write_text("yes")
            with self.assertRaisesRegex(ValueError, "decode"):
                m.execute(self.request, engine=self.engine, shader=self.shader, model=self.model,
                          run_directory=self.run_directory, ffmpeg=self.ffmpeg, ffprobe=self.ffprobe,
                          timeout_seconds=8, cancel_event=threading.Event())
            self.assertFalse(json.loads((self.run_directory / "result.json").read_text())["media_verified"])

    def test_cli_signal_cancels_owned_engine_without_success(self):
        (self.runtime / "mode").write_text("sleep")
        digest = hashlib.sha256(self.shader.read_bytes()).hexdigest()
        command = self.command(digest)
        process = subprocess.Popen(command, cwd=self.root, env=os.environ.copy(),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            marker = self.run_directory / "child-pid"
            deadline = time.monotonic() + 10
            while not marker.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.03)
            self.assertTrue(marker.exists(), "fake engine never reached its sleep marker")
            process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=15)
            self.assertEqual(process.returncode, 2, stderr.decode())
            record = json.loads((self.run_directory / "result.json").read_text())
            self.assertFalse(record["media_verified"])
            self.assertEqual(record["engine_process"]["status"], "cancelled")
            self.assertFalse((self.run_directory / "candidate.mp4").exists())
            with self.assertRaises(ProcessLookupError):
                os.kill(int(marker.read_text()), 0)
        finally:
            if process.poll() is None:
                process.terminate()
                process.communicate(timeout=15)


if __name__ == "__main__":
    unittest.main()
