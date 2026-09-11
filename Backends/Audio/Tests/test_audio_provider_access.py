from __future__ import annotations

from array import array
import contextlib
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import tokenize
import unittest
from unittest import mock


PYTHON_DIR = Path(__file__).resolve().parents[1] / "Python"
sys.path.insert(0, str(PYTHON_DIR))

import d_audio_backend as backend
import d_audio_contract as contract
from d_audio_access import AudioAccessError
from d_audio_sa3 import InferenceResult


TASK_TMP = Path(os.environ["D_TEST_TEMP_DIR"])
PYTHON = Path(sys.executable)
VENDOR = Path(__file__).resolve().parents[3] / "Vendor" / "stable-audio3-mlx"
RUN_ID = "12345678-1234-4234-9234-123456789abc"


def wave_bytes(frames: int) -> bytes:
    payload = b"\0\0\0\0" * frames
    align = 4
    fmt = struct.pack("<HHIIHH", 1, 2, 44_100, 44_100 * align, align, 16)
    riff_size = 4 + 8 + len(fmt) + 8 + len(payload)
    return (
        b"RIFF" + struct.pack("<I", riff_size) + b"WAVE"
        + b"fmt " + struct.pack("<I", len(fmt)) + fmt
        + b"data" + struct.pack("<I", len(payload)) + payload
    )


class RecordingWriter:
    def __init__(self, lifecycle: list[str] | None = None) -> None:
        self.values: list[tuple[dict, bool]] = []
        self.lifecycle = lifecycle

    def emit(self, value, *, terminal=False):
        self.values.append((value, terminal))
        if terminal and self.lifecycle is not None:
            self.lifecycle.append(f"terminal:{value['type']}")

    def progress(self, run_id, phase, completed, total):
        self.emit({
            "schemaVersion": 1, "type": "progress", "runID": run_id,
            "phase": phase, "completed": completed, "total": total,
        })

    @property
    def terminals(self):
        return [value for value, terminal in self.values if terminal]


class AudioProviderAccessTests(unittest.TestCase):
    def setUp(self):
        if sys.version_info[:2] != (3, 12):
            self.fail(
                f"audio provider access tests require Python 3.12, got "
                f"{sys.version_info.major}.{sys.version_info.minor}"
            )
        if not PYTHON.is_file():
            self.fail("sys.executable must name the active Python 3.12 executable")
        if not TASK_TMP.is_dir():
            self.fail("D_TEST_TEMP_DIR must name the existing task temporary directory")
        self.temporary = tempfile.TemporaryDirectory(dir=TASK_TMP)
        self.root = Path(self.temporary.name).resolve()
        self.counter = 0

    def tearDown(self):
        self.temporary.cleanup()

    def make_launch(self, *, operation="generate"):
        self.counter += 1
        case = self.root / f"case-{self.counter}"
        run = case / "run"
        job = run / "job"
        model = case / "model"
        private = case / "private"
        job.mkdir(parents=True)
        (model / "MLX").mkdir(parents=True)
        private.mkdir(parents=True)

        frames = 4
        request = {
            "schemaVersion": 1,
            "runID": RUN_ID,
            "operation": operation,
            "prompt": "provider access fixture",
            "durationSeconds": frames / 44_100,
            "seed": 7,
            "steps": 8,
            "guidanceScale": 1,
            "strength": 1 if operation == "generate" else 0.5,
        }
        source_directory = None
        if operation != "generate":
            source_directory = case / "source"
            source_directory.mkdir()
            source = source_directory / "input.wav"
            source.write_bytes(wave_bytes(frames))
            request["source"] = {
                "path": str(source),
                "sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                "frameCount": frames,
                "sampleRate": 44_100,
                "channels": 2,
            }
        request_path = run / "request.json"
        request_path.write_text(json.dumps(request), encoding="utf-8")

        files = []
        for index, name in enumerate(contract.required_weight_names("sm-music")):
            payload = f"weight-{index}".encode()
            path = model.joinpath(*name.split("/"))
            path.write_bytes(payload)
            files.append({
                "path": name,
                "size": len(payload),
                "sha256": hashlib.sha256(payload).hexdigest(),
            })
        weights = run / "weights.json"
        weights.write_text(json.dumps({
            "schemaVersion": 1,
            "repository": contract.MODEL_REPOSITORY,
            "revision": contract.MODEL_REVISION,
            "files": files,
        }), encoding="utf-8")
        access_manifest = private / "access.json"
        access_manifest.write_text("{}", encoding="utf-8")
        access_manifest.chmod(0o600)

        args = [
            "--request", str(request_path),
            "--job-directory", str(job),
            "--model-directory", str(model),
            "--profile", "sm-music",
            "--manifest", str(weights),
            "--vendor-directory", str(VENDOR),
            "--access-manifest", str(access_manifest),
            "--access-run-id", RUN_ID,
        ]
        if source_directory is not None:
            args += ["--access-source-directory", str(source_directory)]
        return args, job, model, run, source_directory, access_manifest

    @staticmethod
    def engine(lifecycle=None, *, error=None):
        def run(request, _manifest, _model, _vendor, _source, _progress, _cancelled):
            if lifecycle is not None:
                lifecycle.append("engine")
            if error is not None:
                raise error
            return InferenceResult(
                array("f", [0.125] * request.requested_frames * 2),
                {"fixture": 0.0},
                {"measurementKind": "unavailable", "measurementPhase": "fixture",
                 "activeBytes": None, "cacheBytes": None, "peakBytes": None},
            )
        return run

    def test_access_enters_before_external_reads_and_terminal_follows_release(self):
        args, _job, model, run, _source, access_manifest = self.make_launch()
        lifecycle = []
        original_validate = backend.validate_launch_paths

        @contextlib.contextmanager
        def receiver(manifest_path, *, run_id, allowed_paths):
            self.assertEqual(manifest_path, access_manifest)
            self.assertEqual(run_id, RUN_ID)
            self.assertEqual(tuple(allowed_paths), (model, run))
            lifecycle.append("acquire")
            yield
            lifecycle.append("release")

        def validate(*values):
            lifecycle.append("external-read")
            return original_validate(*values)

        writer = RecordingWriter(lifecycle)
        with (
            mock.patch.object(backend, "acquire_file_access", receiver),
            mock.patch.object(backend, "validate_launch_paths", side_effect=validate),
            mock.patch.object(backend, "verify_vendor", return_value={}),
        ):
            code = backend._execute(args, writer, self.engine(lifecycle), lambda: False)
        self.assertEqual(code, 0)
        self.assertLess(lifecycle.index("acquire"), lifecycle.index("external-read"))
        self.assertLess(lifecycle.index("external-read"), lifecycle.index("engine"))
        self.assertLess(lifecycle.index("engine"), lifecycle.index("release"))
        self.assertEqual(lifecycle[-1], "terminal:result")
        self.assertEqual([item["type"] for item in writer.terminals], ["result"])

    def test_acquire_failure_blocks_reads_engine_and_writes_without_private_detail(self):
        args, _job, _model, _run, _source, _manifest = self.make_launch()

        @contextlib.contextmanager
        def receiver(*_args, **_kwargs):
            raise AudioAccessError("private bookmark and CF detail")
            yield

        writer = RecordingWriter()
        with (
            mock.patch.object(backend, "acquire_file_access", receiver),
            mock.patch.object(backend, "validate_launch_paths") as validate,
            mock.patch.object(backend, "publish_exclusive") as publish,
        ):
            code = backend._execute(args, writer, self.engine(), lambda: False)
        self.assertEqual(code, 2)
        validate.assert_not_called()
        publish.assert_not_called()
        self.assertEqual(len(writer.terminals), 1)
        self.assertEqual(writer.terminals[0]["kind"], "configuration")
        self.assertNotIn("bookmark", json.dumps(writer.terminals))
        self.assertNotIn("CF", json.dumps(writer.terminals))

    def test_uuid_mismatch_releases_before_configuration_terminal(self):
        args, _job, _model, _run, _source, _manifest = self.make_launch()
        args[args.index("--access-run-id") + 1] = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        lifecycle = []

        @contextlib.contextmanager
        def receiver(*_args, **_kwargs):
            lifecycle.append("acquire")
            yield
            lifecycle.append("release")

        writer = RecordingWriter(lifecycle)
        engine = mock.Mock(side_effect=AssertionError("engine must not run"))
        with mock.patch.object(backend, "acquire_file_access", receiver):
            code = backend._execute(args, writer, engine, lambda: False)
        self.assertEqual(code, 2)
        engine.assert_not_called()
        self.assertEqual(lifecycle[-2:], ["release", "terminal:error"])
        self.assertEqual(writer.terminals[0]["kind"], "configuration")

    def test_partial_flags_and_source_without_access_reject_before_receiver(self):
        args, _job, _model, _run, _source, _manifest = self.make_launch()
        manifest_index = args.index("--access-manifest")
        legacy = args[:manifest_index]
        cases = (
            legacy + ["--access-manifest", args[manifest_index + 1]],
            legacy + ["--access-run-id", RUN_ID],
            legacy + ["--access-source-directory", str(self.root / "source")],
        )
        for candidate in cases:
            with self.subTest(candidate=candidate[-2]):
                writer = RecordingWriter()
                with mock.patch.object(backend, "acquire_file_access") as receiver:
                    code = backend._execute(candidate, writer, self.engine(), lambda: False)
                self.assertEqual(code, 2)
                receiver.assert_not_called()
                self.assertEqual(writer.terminals[0]["kind"], "configuration")

    def test_source_directory_absent_mismatch_and_excess_are_rejected(self):
        for mode in ("absent", "mismatch", "excess"):
            with self.subTest(mode=mode):
                if mode == "excess":
                    args, _job, _model, _run, _source, _manifest = self.make_launch()
                    extra = self.root / f"extra-{self.counter}"
                    extra.mkdir()
                    args += ["--access-source-directory", str(extra)]
                else:
                    args, _job, _model, _run, source, _manifest = self.make_launch(
                        operation="variation"
                    )
                    marker = args.index("--access-source-directory")
                    if mode == "absent":
                        del args[marker:marker + 2]
                    else:
                        other = self.root / f"other-{self.counter}"
                        other.mkdir()
                        args[marker + 1] = str(other)

                released = []

                @contextlib.contextmanager
                def receiver(*_args, **_kwargs):
                    yield
                    released.append(True)

                writer = RecordingWriter()
                engine = mock.Mock(side_effect=AssertionError("engine must not run"))
                with mock.patch.object(backend, "acquire_file_access", receiver):
                    code = backend._execute(args, writer, engine, lambda: False)
                self.assertEqual(code, 2)
                self.assertEqual(released, [True])
                engine.assert_not_called()
                self.assertEqual(writer.terminals[0]["kind"], "configuration")

    def test_access_releases_for_inspect_cancel_engine_validation_and_output_failures(self):
        modes = ("inspect", "cancel", "engine", "validation", "output")
        for mode in modes:
            with self.subTest(mode=mode):
                args, _job, _model, _run, _source, _manifest = self.make_launch()
                if mode == "inspect":
                    args.append("--inspect")
                lifecycle = []

                @contextlib.contextmanager
                def receiver(*_args, **_kwargs):
                    lifecycle.append("acquire")
                    yield
                    lifecycle.append("release")

                writer = RecordingWriter(lifecycle)
                engine_error = RuntimeError("fixture engine failure") if mode == "engine" else None
                patches = [
                    mock.patch.object(backend, "acquire_file_access", receiver),
                    mock.patch.object(backend, "verify_vendor", return_value={}),
                ]
                if mode == "validation":
                    patches.append(mock.patch.object(
                        backend, "validate_manifest",
                        side_effect=contract.ContractError("fixture invalid", "configuration"),
                    ))
                if mode == "output":
                    patches.append(mock.patch.object(
                        backend, "publish_exclusive",
                        side_effect=contract.ContractError("fixture output", "output"),
                    ))
                with contextlib.ExitStack() as stack:
                    for patcher in patches:
                        stack.enter_context(patcher)
                    code = backend._execute(
                        args,
                        writer,
                        self.engine(error=engine_error),
                        (lambda: True) if mode == "cancel" else (lambda: False),
                    )
                expected = {"inspect": 0, "cancel": 130, "engine": 1,
                            "validation": 2, "output": 2}[mode]
                self.assertEqual(code, expected)
                self.assertEqual(lifecycle[-2], "release")
                self.assertTrue(lifecycle[-1].startswith("terminal:"))
                self.assertEqual(len(writer.terminals), 1)

    def test_cleanup_failure_replaces_success_with_one_configuration_error(self):
        args, job, _model, _run, _source, _manifest = self.make_launch()
        lifecycle = []

        @contextlib.contextmanager
        def receiver(*_args, **_kwargs):
            lifecycle.append("acquire")
            yield
            lifecycle.append("cleanup-failed")
            raise AudioAccessError("private stop failure")

        writer = RecordingWriter(lifecycle)
        with (
            mock.patch.object(backend, "acquire_file_access", receiver),
            mock.patch.object(backend, "verify_vendor", return_value={}),
        ):
            code = backend._execute(args, writer, self.engine(), lambda: False)
        self.assertEqual(code, 2)
        self.assertEqual([item["type"] for item in writer.terminals], ["error"])
        self.assertEqual(writer.terminals[0]["kind"], "configuration")
        self.assertNotIn("stop failure", json.dumps(writer.terminals))
        self.assertTrue((job / "output.wav").is_file())
        self.assertTrue((job / "result.json").is_file())
        self.assertEqual(lifecycle[-2:], ["cleanup-failed", "terminal:error"])

    def test_root_overlap_and_manifest_inside_grant_reject_lexically(self):
        args, _job, model, run, _source, access_manifest = self.make_launch()
        cases = []
        root_model = list(args)
        root_model[root_model.index("--model-directory") + 1] = "/"
        cases.append(root_model)
        overlap = list(args)
        overlap[overlap.index("--model-directory") + 1] = str(run / "nested-model")
        cases.append(overlap)
        manifest_inside = list(args)
        manifest_inside[manifest_inside.index("--access-manifest") + 1] = str(run / "private.json")
        cases.append(manifest_inside)
        self.assertNotEqual(model, run)
        self.assertNotIn(access_manifest, (model, run))
        for candidate in cases:
            writer = RecordingWriter()
            with mock.patch.object(backend, "acquire_file_access") as receiver:
                code = backend._execute(candidate, writer, self.engine(), lambda: False)
            self.assertEqual(code, 2)
            receiver.assert_not_called()

    def test_invalid_access_arguments_and_manifest_exit_in_full_process(self):
        args, _job, _model, _run, _source, access_manifest = self.make_launch()
        environment = os.environ.copy()
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["TMPDIR"] = str(TASK_TMP)
        environment["D_TEST_TEMP_DIR"] = str(TASK_TMP)
        environment["PYTHONPYCACHEPREFIX"] = str(TASK_TMP / "pycache")
        environment["XDG_CACHE_HOME"] = str(TASK_TMP / "xdg-cache")

        manifest_index = args.index("--access-manifest")
        partial = args[:manifest_index] + ["--access-manifest", str(access_manifest)]
        access_manifest.write_text('{"private":"do-not-echo"}', encoding="utf-8")
        access_manifest.chmod(0o600)
        for candidate in (partial, args):
            completed = subprocess.run(
                [str(PYTHON), "-B", str(PYTHON_DIR / "d_audio_backend.py"), *candidate],
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=10,
                env=environment,
            )
            self.assertEqual(completed.returncode, 2, completed.stderr)
            terminals = [json.loads(line) for line in completed.stdout.splitlines()]
            self.assertEqual(len(terminals), 1)
            self.assertEqual(terminals[0]["type"], "error")
            self.assertEqual(terminals[0]["kind"], "configuration")
            self.assertNotIn("do-not-echo", completed.stdout + completed.stderr)

    def test_stdout_delivery_failure_releases_access_before_return(self):
        args, job, _model, _run, _source, _access_manifest = self.make_launch()
        protected = self.root / "readonly-stdout"
        protected.write_bytes(b"unchanged")
        before = protected.read_bytes()
        probe = f"""
import contextlib
from pathlib import Path
import sys
from unittest import mock
sys.path.insert(0, {str(PYTHON_DIR)!r})
import d_audio_backend as backend

events = []

@contextlib.contextmanager
def receiver(*_args, **_kwargs):
    events.append("enter")
    yield
    events.append("release")

def forbidden_engine(*_args, **_kwargs):
    raise AssertionError("engine must not run after stdout delivery failure")

with mock.patch.object(backend, "acquire_file_access", receiver):
    code = backend._execute(sys.argv[1:], backend.EventWriter(), forbidden_engine, lambda: False)
events.append("returned")
raise SystemExit(0 if code == 2 and events == ["enter", "release", "returned"] else 91)
"""
        environment = os.environ.copy()
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["TMPDIR"] = str(TASK_TMP)
        environment["D_TEST_TEMP_DIR"] = str(TASK_TMP)
        environment["PYTHONPYCACHEPREFIX"] = str(TASK_TMP / "pycache")
        environment["XDG_CACHE_HOME"] = str(TASK_TMP / "xdg-cache")
        stdout_fd = os.open(protected, os.O_RDONLY)
        try:
            completed = subprocess.run(
                [str(PYTHON), "-B", "-c", probe, *args],
                stdin=subprocess.DEVNULL,
                stdout=stdout_fd,
                stderr=subprocess.PIPE,
                text=True,
                timeout=10,
                env=environment,
            )
        finally:
            os.close(stdout_fd)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(protected.read_bytes(), before)
        self.assertIn("stdout delivery failed", completed.stderr)
        self.assertNotIn('\"type\":\"result\"', completed.stderr)
        self.assertEqual(list(job.iterdir()), [])

    def test_syntax_is_compiled_in_memory_without_importing_targets(self):
        for target in (PYTHON_DIR / "d_audio_backend.py", Path(__file__)):
            with tokenize.open(target) as handle:
                source = handle.read()
            compile(source, str(target), "exec", dont_inherit=True)


if __name__ == "__main__":
    unittest.main()
