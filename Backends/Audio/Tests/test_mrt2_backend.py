from __future__ import annotations

from array import array
import contextlib
import hashlib
import io
import json
import math
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


PYTHON_DIR = Path(__file__).resolve().parents[1] / "Python"
sys.path.insert(0, str(PYTHON_DIR))

import d_audio_mrt2_backend as backend
import d_audio_mrt2_contract as contract
from d_audio_access import AudioAccessError
from d_audio_contract import ContractError


RUN_ID = "12345678-1234-4234-9234-123456789abc"
PYTHON = Path(sys.executable)


class RecordingWriter:
    def __init__(self, lifecycle: list[str] | None = None) -> None:
        self.values: list[tuple[dict, bool]] = []
        self.lifecycle = lifecycle

    def emit(self, value, *, terminal=False):
        self.values.append((value, terminal))
        if terminal and self.lifecycle is not None:
            self.lifecycle.append(f"terminal:{value['type']}")

    def progress(self, run_id, phase, completed, total):
        self.emit(
            {
                "schemaVersion": 1,
                "type": "progress",
                "runID": run_id,
                "phase": phase,
                "completed": completed,
                "total": total,
            }
        )

    @property
    def terminals(self):
        return [value for value, terminal in self.values if terminal]


class FakeEngine:
    def __init__(
        self,
        model: Path,
        prompt: str,
        seed: int,
        *,
        lifecycle: list[str] | None = None,
        fail_frame: int | None = None,
        close_result: dict | None = None,
        bad_frame: str | None = None,
    ) -> None:
        self.model = model
        self.prompt = prompt
        self.seed = seed
        self.lifecycle = lifecycle
        self.fail_frame = fail_frame
        self.close_result = close_result or {"released": True}
        self.bad_frame = bad_frame
        self.conditions = []
        self.closed = False
        if lifecycle is not None:
            lifecycle.append("construct")

    def generate_frame(self, condition):
        index = len(self.conditions)
        self.conditions.append(condition)
        if self.lifecycle is not None:
            self.lifecycle.append(f"frame:{index}")
        if self.fail_frame == index:
            raise RuntimeError("fixture generation failure")
        if self.bad_frame == "short":
            return [[0.0, 0.0]]
        frame = [[0.125, -0.25] for _ in range(contract.SAMPLES_PER_CONDITION_FRAME)]
        if self.bad_frame == "nan":
            frame[0][0] = math.nan
        return frame

    def identity(self):
        return {
            "profile": contract.PROFILE,
            "model_revision": contract.MODEL_REVISION,
            "sdk_revision": contract.SDK_REVISION,
            "model_root": str(self.model),
            "graph_path": str(self.model / "private.graph"),
            "state_path": str(self.model / "private.state"),
            "resource_paths": {"private": str(self.model / "private")},
            "executedFixture": True,
            "sampling_seed": self.seed,
        }

    def close(self):
        self.closed = True
        if self.lifecycle is not None:
            self.lifecycle.append("close")
        return dict(self.close_result)


class FailingWriter(RecordingWriter):
    def __init__(self, fail_phase: str) -> None:
        super().__init__()
        self.fail_phase = fail_phase

    def progress(self, run_id, phase, completed, total):
        if phase == self.fail_phase:
            raise backend.OutputDeliveryError("fixture broken pipe")
        super().progress(run_id, phase, completed, total)


class MRT2BackendTests(unittest.TestCase):
    def setUp(self):
        temp_parent = os.environ.get("D_TEST_TEMP_DIR")
        if not temp_parent:
            self.fail("D_TEST_TEMP_DIR must name the task-owned temporary directory")
        self.temporary = tempfile.TemporaryDirectory(dir=temp_parent)
        self.root = Path(self.temporary.name).resolve()
        self.counter = 0

    def tearDown(self):
        self.temporary.cleanup()

    @staticmethod
    def base_request(*, duration_frames=1, notes_marker="absent", seed=42):
        sequence = {
            "schemaVersion": 1,
            "frameRate": 25,
            "durationFrames": duration_frames,
        }
        if notes_marker != "absent":
            sequence["notes"] = notes_marker
        return {
            "schemaVersion": 1,
            "runID": RUN_ID,
            "operation": "generate",
            "prompt": "雨のピアノ",
            "durationSeconds": duration_frames / 25,
            "seed": seed,
            "parameters": {"kind": "mrt2FixedV1", "sequence": sequence},
        }

    def make_launch(self, *, request=None, duration_frames=1):
        self.counter += 1
        case = self.root / f"case-{self.counter}"
        run = case / "run"
        job = run / "job"
        model = case / "model"
        vendor = case / "vendor"
        private = case / "private"
        job.mkdir(parents=True)
        model.mkdir()
        vendor.mkdir()
        private.mkdir()
        request_value = request or self.base_request(duration_frames=duration_frames)
        request_path = run / "request.json"
        request_path.write_text(json.dumps(request_value), encoding="utf-8")

        entries = []
        for index, fixed in enumerate(contract.FIXED_FILES):
            payload = f"fixture-{index}".encode()
            path = model.joinpath(*fixed.relative_path.split("/"))
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(payload)
            entries.append(
                contract.WeightEntry(
                    fixed.relative_path, len(payload), hashlib.sha256(payload).hexdigest()
                )
            )
        manifest_spec = contract.ManifestSpec(files=tuple(entries))
        manifest_value = {
            "schemaVersion": manifest_spec.schema_version,
            "profile": manifest_spec.profile,
            "repository": manifest_spec.repository,
            "revision": manifest_spec.revision,
            "license": manifest_spec.license,
            "files": manifest_spec.provenance(),
        }
        manifest_path = run / "manifest.json"
        manifest_path.write_text(json.dumps(manifest_value), encoding="utf-8")
        access_manifest = private / "access.json"
        access_manifest.write_text("{}", encoding="utf-8")
        access_manifest.chmod(0o600)
        args = [
            "--request",
            str(request_path),
            "--job-directory",
            str(job),
            "--model-directory",
            str(model),
            "--manifest",
            str(manifest_path),
            "--vendor-directory",
            str(vendor),
        ]
        return args, job, model, run, access_manifest, manifest_spec

    @staticmethod
    def factory_box(**options):
        box = {}

        def factory(model, prompt, seed):
            engine = FakeEngine(model, prompt, seed, **options)
            box["engine"] = engine
            return engine

        return factory, box

    @staticmethod
    def run_main(args, factory, manifest_spec):
        output = io.StringIO()
        errors = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            code = backend.main(
                args, engine_factory=factory, manifest_spec=manifest_spec
            )
        events = [json.loads(line) for line in output.getvalue().splitlines()]
        return code, events, errors.getvalue()

    def test_request_nil_empty_and_uint32_seed_semantics(self):
        absent = contract.validate_request(
            self.base_request(duration_frames=2, seed=2**32 - 1)
        )
        explicit = contract.validate_request(
            self.base_request(duration_frames=2, notes_marker=[])
        )
        self.assertEqual(absent.seed, 2**32 - 1)
        self.assertEqual(absent.sequence.notes_mode, "absent")
        self.assertEqual(explicit.sequence.notes_mode, "explicitEmpty")
        self.assertEqual(list(contract.condition_frames(absent.sequence)), [None, None])
        zeros = list(contract.condition_frames(explicit.sequence))
        self.assertEqual(len(zeros), 2)
        self.assertTrue(all(frame == (0,) * 128 for frame in zeros))
        invalid = self.base_request(seed=2**32)
        with self.assertRaises(ContractError):
            contract.validate_request(invalid)

    def test_note_sorting_two_one_zero_encoding_and_overlap(self):
        request = self.base_request(
            duration_frames=4,
            notes_marker=[
                {"pitch": 61, "startFrame": 1, "endFrame": 4},
                {"pitch": 60, "startFrame": 0, "endFrame": 3},
            ],
        )
        parsed = contract.validate_request(request)
        self.assertEqual([note.pitch for note in parsed.sequence.notes], [60, 61])
        self.assertEqual(
            [note["pitch"] for note in parsed.snapshot["parameters"]["sequence"]["notes"]],
            [61, 60],
        )
        self.assertEqual(
            [note["pitch"] for note in parsed.condition_metadata()["sequence"]["notes"]],
            [60, 61],
        )
        frames = list(contract.condition_frames(parsed.sequence))
        self.assertEqual([frame[60] for frame in frames], [2, 1, 1, 0])
        self.assertEqual([frame[61] for frame in frames], [0, 2, 1, 1])
        self.assertFalse(any(3 in frame for frame in frames))
        request["parameters"]["sequence"]["notes"].append(
            {"pitch": 60, "startFrame": 2, "endFrame": 4}
        )
        with self.assertRaisesRegex(ContractError, "overlap"):
            contract.validate_request(request)

    def test_request_rejects_types_boundaries_unknown_and_sa3_fields(self):
        cases = []
        for path, value in (
            (("schemaVersion",), 1.0),
            (("seed",), True),
            (("durationSeconds",), math.inf),
            (("parameters", "sequence", "schemaVersion"), 1.0),
            (("parameters", "sequence", "frameRate"), True),
            (("parameters", "sequence", "durationFrames"), 401),
        ):
            candidate = self.base_request()
            target = candidate
            for key in path[:-1]:
                target = target[key]
            target[path[-1]] = value
            cases.append(candidate)
        wrong_duration = self.base_request()
        wrong_duration["durationSeconds"] = 0.05
        cases.append(wrong_duration)
        blank = self.base_request()
        blank["prompt"] = " \n\t"
        cases.append(blank)
        nul = self.base_request()
        nul["prompt"] = "bad\0prompt"
        cases.append(nul)
        sa3 = self.base_request()
        sa3["steps"] = 8
        cases.append(sa3)
        source = self.base_request()
        source["source"] = {}
        cases.append(source)
        null_notes = self.base_request(notes_marker=None)
        cases.append(null_notes)
        for index, candidate in enumerate(cases):
            with self.subTest(index=index), self.assertRaises(ContractError):
                contract.validate_request(candidate)

    def test_note_event_integer_and_interval_boundaries(self):
        valid = self.base_request(
            duration_frames=400,
            notes_marker=[{"pitch": 127, "startFrame": 0, "endFrame": 400}],
        )
        self.assertEqual(contract.validate_request(valid).sequence.duration_frames, 400)
        for key, value in (
            ("pitch", 128),
            ("pitch", True),
            ("startFrame", -1),
            ("startFrame", 0.0),
            ("endFrame", 0),
            ("endFrame", 401),
        ):
            candidate = self.base_request(
                notes_marker=[{"pitch": 60, "startFrame": 0, "endFrame": 1}]
            )
            candidate["parameters"]["sequence"]["notes"][0][key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ContractError):
                contract.validate_request(candidate)

    def test_strict_json_duplicate_nonfinite_integer_form_and_depth(self):
        for raw in (
            b'{"a":1,"a":2}',
            b'{"a":NaN}',
            b'{"a":Infinity}',
            b'{"a":1e100000}',
        ):
            with self.subTest(raw=raw), self.assertRaises(ContractError):
                contract.decode_mrt2_json(raw, label="fixture")
        nested = b"{}"
        for _ in range(16):
            nested = b'{"x":' + nested + b"}"
        with self.assertRaisesRegex(ContractError, "16"):
            contract.decode_mrt2_json(nested, label="fixture")
        raw = json.dumps(self.base_request()).replace('"schemaVersion": 1', '"schemaVersion": 1.0', 1)
        with self.assertRaises(ContractError):
            contract.validate_request(contract.decode_mrt2_json(raw.encode(), label="request"))

    def test_manifest_exact_identity_order_digest_and_cancellation(self):
        args, _job, model, run, _access, spec = self.make_launch()
        manifest_path = Path(args[args.index("--manifest") + 1])
        value = contract.load_mrt2_json(
            manifest_path, label="manifest", max_bytes=contract.MAX_MANIFEST_BYTES
        )
        self.assertEqual(contract.validate_manifest(value, expected=spec), spec)
        swapped = json.loads(json.dumps(value))
        swapped["files"][0], swapped["files"][1] = swapped["files"][1], swapped["files"][0]
        with self.assertRaises(ContractError):
            contract.validate_manifest(swapped, expected=spec)
        wrong = json.loads(json.dumps(value))
        wrong["revision"] = "self-reported"
        with self.assertRaises(ContractError):
            contract.validate_manifest(wrong, expected=spec)
        contract.verify_manifest_weights(spec, model, cancelled=lambda: False)
        with self.assertRaises(InterruptedError):
            contract.verify_manifest_weights(spec, model, cancelled=lambda: True)
        first = model.joinpath(*spec.files[0].relative_path.split("/"))
        first.write_bytes(b"corrupt")
        with self.assertRaises(ContractError):
            contract.verify_manifest_weights(spec, model, cancelled=lambda: False)
        self.assertTrue(run.is_dir())

    def test_launch_rejects_overlap_symlink_nonregular_and_nonempty_job(self):
        args, job, model, _run, _access, _spec = self.make_launch()
        request = Path(args[args.index("--request") + 1])
        manifest = Path(args[args.index("--manifest") + 1])
        vendor = Path(args[args.index("--vendor-directory") + 1])
        contract.validate_launch_paths(request, job, model, manifest, vendor)
        (job / "output.wav").write_bytes(b"existing")
        with self.assertRaisesRegex(ContractError, "empty"):
            contract.validate_launch_paths(request, job, model, manifest, vendor)
        (job / "output.wav").unlink()
        link = self.root / "model-link"
        link.symlink_to(model, target_is_directory=True)
        with self.assertRaises(ContractError):
            contract.validate_launch_paths(request, job, link, manifest, vendor)
        with self.assertRaises(ContractError):
            contract.validate_launch_paths(request, job, request.parent, manifest, vendor)

    def test_float32_wave_is_exact_48khz_stereo_and_rejects_bad_values(self):
        raw = contract.encode_float32_wave([0.25, -0.5] * 3, 3)
        digest = contract.validate_float32_wave(raw, expected_frames=3)
        self.assertEqual(digest, hashlib.sha256(raw).hexdigest())
        self.assertEqual(struct.unpack_from("<HHI", raw, 20), (3, 2, 48_000))
        with self.assertRaises(ContractError):
            contract.encode_float32_wave([math.nan, 0.0], 1)
        damaged = bytearray(raw)
        damaged[24:28] = struct.pack("<I", 44_100)
        with self.assertRaises(ContractError):
            contract.validate_float32_wave(bytes(damaged), expected_frames=3)

    def test_full_fake_orchestration_result_metadata_progress_and_seed(self):
        args, job, model, _run, _access, spec = self.make_launch(duration_frames=2)
        factory, box = self.factory_box()
        code, events, errors = self.run_main(args, factory, spec)
        self.assertEqual((code, errors), (0, ""))
        terminal = events[-1]
        self.assertEqual(terminal, json.loads((job / "result.json").read_text()))
        self.assertEqual([event["type"] for event in events].count("result"), 1)
        self.assertEqual(terminal["artifact"]["frameCount"], 3_840)
        self.assertEqual(terminal["artifact"]["sampleRate"], 48_000)
        self.assertEqual(terminal["artifact"]["channels"], 2)
        self.assertEqual(terminal["artifact"]["encoding"], "float32")
        self.assertTrue((job / "output.wav").is_file())
        metadata = terminal["metadata"]
        self.assertEqual(metadata["request"], self.base_request(duration_frames=2))
        self.assertEqual(metadata["profile"], contract.PROFILE)
        self.assertEqual(metadata["weightManifest"], spec.provenance())
        self.assertEqual(metadata["cleanup"], {"released": True})
        self.assertIn("firstPCM", metadata["timingsSeconds"])
        self.assertIn("total", metadata["timingsSeconds"])
        self.assertIn("processPeakRSSBytes", metadata["mlxAllocations"])
        identity_text = json.dumps(metadata["engineIdentity"])
        self.assertNotIn(str(model), identity_text)
        self.assertTrue(box["engine"].closed)
        self.assertEqual(box["engine"].seed, 42)
        self.assertEqual(box["engine"].conditions, [None, None])
        phases = [event["phase"] for event in events if event["type"] == "progress"]
        for phase in (
            "validating",
            "encodingText",
            "denoising",
            "decoding",
            "cleanup",
            "publishing",
        ):
            self.assertIn(phase, phases)
        denoising = [
            event for event in events if event.get("phase") == "denoising"
        ]
        self.assertEqual([(item["completed"], item["total"]) for item in denoising], [(0, 2), (1, 2), (2, 2)])
        expected_digest = hashlib.sha256(
            contract.canonical_condition_bytes(contract.validate_request(self.base_request(duration_frames=2)))
        ).hexdigest()
        self.assertEqual(metadata["conditionSHA256"], expected_digest)

    def test_explicit_empty_condition_reaches_engine_as_zero_frames(self):
        request = self.base_request(duration_frames=1, notes_marker=[])
        args, _job, _model, _run, _access, spec = self.make_launch(request=request)
        factory, box = self.factory_box()
        code, _events, _errors = self.run_main(args, factory, spec)
        self.assertEqual(code, 0)
        self.assertEqual(box["engine"].conditions, [(0,) * 128])

    def test_inspect_verifies_files_without_constructing_engine_or_importing_mlx(self):
        args, _job, _model, _run, _access, spec = self.make_launch()
        args.append("--inspect")
        factory = mock.Mock(side_effect=AssertionError("inspect must not construct engine"))
        before = {name for name in sys.modules if name == "mlx" or name.startswith("mlx.")}
        code, events, errors = self.run_main(args, factory, spec)
        after = {name for name in sys.modules if name == "mlx" or name.startswith("mlx.")}
        self.assertEqual((code, errors), (0, ""))
        factory.assert_not_called()
        self.assertEqual(before, after)
        self.assertEqual(events[-1]["type"], "inspection")
        self.assertEqual(events[-1]["weightManifest"], spec.provenance())

    def test_constructor_generation_frame_and_close_failures(self):
        modes = ("constructor", "generation", "short", "nan", "close")
        for mode in modes:
            with self.subTest(mode=mode):
                args, job, _model, _run, _access, spec = self.make_launch()
                box = {}
                if mode == "constructor":
                    def factory(*_args):
                        raise RuntimeError("fixture construction failure")
                else:
                    options = {
                        "fail_frame": 0 if mode == "generation" else None,
                        "bad_frame": mode if mode in ("short", "nan") else None,
                        "close_result": {"released": False} if mode == "close" else None,
                    }
                    factory, box = self.factory_box(**options)
                code, events, _errors = self.run_main(args, factory, spec)
                self.assertEqual(code, 1)
                self.assertEqual([event["type"] for event in events].count("error"), 1)
                self.assertEqual(events[-1]["kind"], "engine")
                self.assertFalse((job / "result.json").exists())
                if mode != "constructor":
                    self.assertTrue(box["engine"].closed)

    def test_cancellation_before_after_construction_and_during_frames_closes(self):
        for stop_at in (1, 2, 4):
            with self.subTest(stop_at=stop_at):
                args, _job, _model, _run, _access, spec = self.make_launch(duration_frames=3)
                factory, box = self.factory_box()
                calls = {"count": 0}

                def cancelled():
                    calls["count"] += 1
                    return calls["count"] >= stop_at

                writer = RecordingWriter()
                code = backend._execute(args, writer, factory, cancelled, spec)
                self.assertEqual(code, 130)
                self.assertEqual(writer.terminals[-1]["kind"], "cancelled")
                if "engine" in box:
                    self.assertTrue(box["engine"].closed)

    def test_output_validation_existing_output_and_publication_failure_are_code_two(self):
        args, job, _model, _run, _access, spec = self.make_launch()
        factory, _box = self.factory_box()
        with mock.patch.object(
            backend,
            "validate_float32_wave",
            side_effect=ContractError("fixture bad WAV", "output"),
        ):
            code, events, _errors = self.run_main(args, factory, spec)
        self.assertEqual(code, 2)
        self.assertEqual(events[-1]["kind"], "output")
        self.assertFalse((job / "output.wav").exists())

        args, job, _model, _run, _access, spec = self.make_launch()
        (job / "output.wav").write_bytes(b"existing")
        factory, _box = self.factory_box()
        code, events, _errors = self.run_main(args, factory, spec)
        self.assertEqual(code, 2)
        self.assertEqual(events[-1]["kind"], "configuration")
        self.assertEqual((job / "output.wav").read_bytes(), b"existing")

    def test_broken_progress_stream_still_closes_engine(self):
        args, _job, _model, _run, _access, spec = self.make_launch()
        factory, box = self.factory_box()
        writer = FailingWriter("denoising")
        code = backend._execute(args, writer, factory, lambda: False, spec)
        self.assertEqual(code, 2)
        self.assertTrue(box["engine"].closed)
        self.assertLessEqual(len(writer.terminals), 1)

    def test_access_acquires_before_reads_and_releases_before_terminal(self):
        args, _job, model, run, access_manifest, spec = self.make_launch()
        args += ["--access-manifest", str(access_manifest), "--access-run-id", RUN_ID]
        lifecycle = []
        factory, _box = self.factory_box(lifecycle=lifecycle)
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
        ):
            code = backend._execute(args, writer, factory, lambda: False, spec)
        self.assertEqual(code, 0)
        self.assertLess(lifecycle.index("acquire"), lifecycle.index("external-read"))
        self.assertLess(lifecycle.index("external-read"), lifecycle.index("construct"))
        self.assertLess(lifecycle.index("close"), lifecycle.index("release"))
        self.assertEqual(lifecycle[-1], "terminal:result")
        self.assertEqual([event["type"] for event in writer.terminals], ["result"])

    def test_access_failure_and_release_failure_never_emit_success_first(self):
        for mode in ("acquire", "release"):
            with self.subTest(mode=mode):
                args, _job, _model, _run, access_manifest, spec = self.make_launch()
                args += [
                    "--access-manifest",
                    str(access_manifest),
                    "--access-run-id",
                    RUN_ID,
                ]
                lifecycle = []

                @contextlib.contextmanager
                def receiver(*_args, **_kwargs):
                    if mode == "acquire":
                        raise AudioAccessError("private fixture detail")
                    lifecycle.append("acquire")
                    yield
                    lifecycle.append("release-failed")
                    raise AudioAccessError("private release detail")

                factory, box = self.factory_box(lifecycle=lifecycle)
                writer = RecordingWriter(lifecycle)
                with mock.patch.object(backend, "acquire_file_access", receiver):
                    code = backend._execute(args, writer, factory, lambda: False, spec)
                self.assertEqual(code, 2)
                self.assertEqual([event["type"] for event in writer.terminals], ["error"])
                self.assertEqual(writer.terminals[0]["kind"], "configuration")
                self.assertNotIn("private", json.dumps(writer.terminals))
                if mode == "acquire":
                    self.assertNotIn("engine", box)
                else:
                    self.assertEqual(lifecycle[-1], "terminal:error")

    def test_cli_partial_access_flags_and_profile_or_source_flags_reject(self):
        args, _job, _model, _run, access_manifest, spec = self.make_launch()
        cases = (
            args + ["--access-manifest", str(access_manifest)],
            args + ["--access-run-id", RUN_ID],
            args + ["--profile", contract.PROFILE],
            args + ["--access-source-directory", str(self.root)],
        )
        for candidate in cases:
            writer = RecordingWriter()
            factory = mock.Mock(side_effect=AssertionError("invalid CLI must not construct"))
            code = backend._execute(candidate, writer, factory, lambda: False, spec)
            self.assertEqual(code, 2)
            factory.assert_not_called()
            self.assertEqual(writer.terminals[0]["kind"], "configuration")

    def test_full_process_cli_missing_bad_request_and_bad_model(self):
        environment = os.environ.copy()
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        missing = subprocess.run(
            [PYTHON, "-B", PYTHON_DIR / "d_audio_mrt2_backend.py"],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=10,
            env=environment,
        )
        self.assertEqual(missing.returncode, 2)
        self.assertEqual(json.loads(missing.stdout.splitlines()[-1])["kind"], "configuration")

        args, _job, _model, _run, _access, _spec = self.make_launch()
        request_path = Path(args[args.index("--request") + 1])
        request_path.write_text("{bad", encoding="utf-8")
        bad_request = subprocess.run(
            [PYTHON, "-B", PYTHON_DIR / "d_audio_mrt2_backend.py", *args],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=10,
            env=environment,
        )
        self.assertEqual(bad_request.returncode, 2)
        self.assertEqual(json.loads(bad_request.stdout.splitlines()[-1])["kind"], "invalidRequest")

        args, _job, model, _run, _access, _spec = self.make_launch()
        first = model.joinpath(*contract.FIXED_FILES[0].relative_path.split("/"))
        first.unlink()
        bad_model = subprocess.run(
            [PYTHON, "-B", PYTHON_DIR / "d_audio_mrt2_backend.py", *args],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=10,
            env=environment,
        )
        self.assertEqual(bad_model.returncode, 2)
        self.assertEqual(json.loads(bad_model.stdout.splitlines()[-1])["kind"], "configuration")

    def test_unwritable_publication_path_is_output_failure_without_overwrite(self):
        args, job, _model, _run, _access, spec = self.make_launch()
        factory, box = self.factory_box()
        original = backend.publish_exclusive

        def reject(target_job, filename, content, **kwargs):
            if filename == "output.wav":
                raise ContractError("failed to publish output.wav: permission denied", "output")
            return original(target_job, filename, content, **kwargs)

        with mock.patch.object(backend, "publish_exclusive", side_effect=reject):
            code, events, _errors = self.run_main(args, factory, spec)
        self.assertEqual(code, 2)
        self.assertEqual(events[-1]["kind"], "output")
        self.assertTrue(box["engine"].closed)
        self.assertEqual(list(job.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
