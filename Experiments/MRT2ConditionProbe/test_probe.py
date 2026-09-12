"""CPU-only tests for the bounded MRT2 probe.

No test imports Magenta RT, MLX, NumPy, or a model. The probe's internal
adapter seam is used directly; the production CLI exposes no such switch.
"""

from __future__ import annotations

import array
import hashlib
import json
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
if os.fspath(HERE) not in sys.path:
    sys.path.insert(0, os.fspath(HERE))

import conditions
import probe


def request_document(**updates):
    document = {
        "schemaVersion": 1,
        "frameRate": 25,
        "durationFrames": 4,
        "prompt": "dry piano trio",
        "seed": 7,
    }
    document.update(updates)
    return document


def encode(document) -> bytes:
    return json.dumps(document, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


class _DType:
    name = "float32"


class FakeSamples:
    shape = (probe.SAMPLES_PER_FRAME, probe.CHANNELS)
    dtype = _DType()

    def __init__(self, value: float = 0.125):
        self.values = array.array(
            "f", [value] * (probe.SAMPLES_PER_FRAME * probe.CHANNELS)
        )

    def tobytes(self, order="C") -> bytes:
        if order != "C":
            raise ValueError(order)
        return self.values.tobytes()


class FakeWaveform:
    sample_rate = probe.SAMPLE_RATE

    def __init__(self, samples=None):
        self.samples = samples or FakeSamples()


class FakeAdapter:
    def __init__(
        self,
        *,
        cancellation=None,
        fail_at=None,
        waveform_factory=FakeWaveform,
        released=True,
        synchronized=True,
        cache_cleared=True,
    ):
        self.cancellation = cancellation
        self.fail_at = fail_at
        self.waveform_factory = waveform_factory
        self.released = released
        self.synchronized = synchronized
        self.cache_cleared = cache_cleared
        self.note_frames = []
        self.close_called = False
        self.final_cleanup_called = False

    def identity(self):
        return {
            "backendClass": "InjectedCPUAdapter",
            "precision": "fixture-float32",
        }

    def generate_frame(self, note_frame, state):
        index = len(self.note_frames)
        self.note_frames.append(note_frame)
        if self.fail_at == index:
            raise RuntimeError("fixture generation failure")
        if self.cancellation is not None:
            self.cancellation.request()
        return self.waveform_factory(), {"frame": index + 1}

    def close(self, state):
        self.close_called = True
        return {"releaseRequested": True, "stateObserved": state is not None}

    def final_cleanup(self):
        self.final_cleanup_called = True
        return {
            "released": self.released,
            "synchronized": self.synchronized,
            "cacheCleared": self.cache_cleared,
            "memoryAfterRelease": "fixture",
        }


class ConditionsTests(unittest.TestCase):
    def parse(self, **updates):
        return conditions.parse_request(encode(request_document(**updates)))

    def test_onset_sustain_end_adjacent_reonset_and_chord(self):
        request = self.parse(
            notes=[
                {"pitch": 60, "startFrame": 1, "endFrame": 3},
                {"pitch": 60, "startFrame": 3, "endFrame": 4},
                {"pitch": 64, "startFrame": 1, "endFrame": 4},
            ]
        )
        frames = conditions.build_note_frames(request)
        self.assertEqual(frames[0][60], 0)
        self.assertEqual(frames[1][60], 2)
        self.assertEqual(frames[2][60], 1)
        self.assertEqual(frames[3][60], 2)
        self.assertEqual(frames[1][64], 2)
        self.assertEqual(frames[2][64], 1)
        self.assertEqual(frames[3][64], 1)
        self.assertTrue(all(value in (0, 1, 2) for frame in frames for value in frame))

    def test_absent_and_explicit_empty_are_distinct(self):
        absent = self.parse()
        explicit = self.parse(notes=[])
        self.assertIsNone(conditions.build_note_frames(absent))
        frames = conditions.build_note_frames(explicit)
        self.assertEqual(len(frames), explicit.duration_frames)
        self.assertTrue(all(not any(frame) for frame in frames))
        self.assertNotEqual(absent.condition_sha256, explicit.condition_sha256)
        self.assertEqual(absent.notes_mode, "absent")
        self.assertEqual(explicit.notes_mode, "explicit")

    def test_rejects_boolean_in_every_numeric_position(self):
        documents = [
            request_document(schemaVersion=True),
            request_document(frameRate=True),
            request_document(durationFrames=True),
            request_document(seed=True),
            request_document(notes=[{"pitch": True, "startFrame": 0, "endFrame": 1}]),
            request_document(notes=[{"pitch": 60, "startFrame": True, "endFrame": 1}]),
            request_document(notes=[{"pitch": 60, "startFrame": 0, "endFrame": True}]),
        ]
        for document in documents:
            with self.subTest(document=document), self.assertRaises(conditions.RequestError):
                conditions.parse_request(encode(document))

    def test_rejects_unknown_duplicate_and_nonfinite_fields(self):
        with self.assertRaises(conditions.RequestError):
            self.parse(extra="no")
        with self.assertRaises(conditions.RequestError):
            self.parse(notes=[{"pitch": 60, "startFrame": 0, "endFrame": 1, "x": 1}])
        with self.assertRaises(conditions.RequestError):
            conditions.parse_request(
                b'{"schemaVersion":1,"schemaVersion":1,"frameRate":25,'
                b'"durationFrames":1,"prompt":"x","seed":0}'
            )
        with self.assertRaises(conditions.RequestError):
            conditions.parse_request(
                b'{"schemaVersion":1,"frameRate":25,"durationFrames":1,'
                b'"prompt":"x","seed":NaN}'
            )
        with self.assertRaises(conditions.RequestError):
            conditions.parse_request(
                b'{"schemaVersion":1,"frameRate":25,"durationFrames":1,'
                b'"prompt":"\\ud800","seed":0}'
            )

    def test_rejects_bounds_float_time_overlap_and_bad_prompt(self):
        invalid = [
            request_document(durationFrames=0),
            request_document(durationFrames=401),
            request_document(seed=-1),
            request_document(seed=1 << 32),
            request_document(notes=[{"pitch": 128, "startFrame": 0, "endFrame": 1}]),
            request_document(notes=[{"pitch": 60, "startFrame": 0.0, "endFrame": 1}]),
            request_document(notes=[{"pitch": 60, "startFrame": 1, "endFrame": 1}]),
            request_document(
                notes=[
                    {"pitch": 60, "startFrame": 0, "endFrame": 3},
                    {"pitch": 60, "startFrame": 2, "endFrame": 4},
                ]
            ),
            request_document(prompt=""),
            request_document(prompt="x\x00y"),
            request_document(prompt="乐" * 1366),
        ]
        for document in invalid:
            with self.subTest(document=document), self.assertRaises(conditions.RequestError):
                conditions.parse_request(encode(document))

    def test_source_and_normalized_condition_hashes(self):
        raw = encode(
            request_document(
                notes=[
                    {"pitch": 64, "startFrame": 0, "endFrame": 1},
                    {"pitch": 60, "startFrame": 0, "endFrame": 2},
                ]
            )
        )
        request = conditions.parse_request(raw)
        self.assertEqual(request.source_sha256, hashlib.sha256(raw).hexdigest())
        self.assertEqual([note.pitch for note in request.notes], [60, 64])
        expected = hashlib.sha256(
            conditions.canonical_json_bytes(request.normalized_condition())
        ).hexdigest()
        self.assertEqual(request.condition_sha256, expected)


class ProbeTests(unittest.TestCase):
    def setUp(self):
        configured_root = os.environ.get("MRT2_PROBE_TEST_ROOT")
        if configured_root:
            Path(configured_root).mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=configured_root)
        self.root = Path(self.temporary.name)
        self.model_root = self.root / "model"
        self.model_root.mkdir()
        model_file = self.model_root / "weights.bin"
        model_file.write_bytes(b"fixed-fixture-weights")
        model_sha = hashlib.sha256(model_file.read_bytes()).hexdigest()
        manifest = {
            "repository": probe.EXPECTED_REPOSITORY,
            "revision": probe.EXPECTED_MODEL_REVISION,
            "license": "CC-BY-4.0",
            "files": [
                {"path": "weights.bin", "size": model_file.stat().st_size, "sha256": model_sha}
            ],
            "totalBytes": model_file.stat().st_size,
        }
        (self.model_root / probe.MANIFEST_NAME).write_text(
            json.dumps(manifest), encoding="utf-8"
        )
        self.request_path = self.root / "request.json"
        self.request_raw = encode(request_document(durationFrames=2, notes=[]))
        self.request_path.write_bytes(self.request_raw)

    def tearDown(self):
        self.temporary.cleanup()

    def run_with(self, adapter, output_name="job", **overrides):
        output = self.root / output_name
        arguments = {
            "model_root_text": os.fspath(self.model_root),
            "request_text": os.fspath(self.request_path),
            "output_text": os.fspath(output),
            "backend": "exported",
            "timeout_seconds": 30.0,
            "adapter_factory": lambda _backend, _root, _request: adapter,
        }
        arguments.update(overrides)
        code = probe.run_probe(**arguments)
        return code, output

    def test_import_does_not_load_sdk_or_numpy(self):
        self.assertNotIn("mlx.core", sys.modules)
        self.assertNotIn("magenta_rt", sys.modules)
        self.assertNotIn("numpy", sys.modules)

    def test_success_writes_exact_float32_wav_and_report(self):
        adapter = FakeAdapter()
        code, output = self.run_with(adapter)
        self.assertEqual(code, 0)
        self.assertTrue(adapter.close_called)
        self.assertTrue(adapter.final_cleanup_called)
        wav = (output / "output.wav").read_bytes()
        header = struct.unpack("<4sI4s4sIHHIIHH4sI", wav[:44])
        self.assertEqual(header[0], b"RIFF")
        self.assertEqual(header[2], b"WAVE")
        self.assertEqual(header[5], 3)
        self.assertEqual(header[6], 2)
        self.assertEqual(header[7], 48_000)
        self.assertEqual(header[10], 32)
        self.assertEqual(
            len(wav),
            44 + 2 * probe.SAMPLES_PER_FRAME * probe.CHANNELS * probe.SAMPLE_WIDTH,
        )
        report = json.loads((output / "report.json").read_text(encoding="utf-8"))
        self.assertEqual(report["outcome"], "completed")
        self.assertEqual(report["requestSha256"], hashlib.sha256(self.request_raw).hexdigest())
        self.assertEqual(report["condition"]["mode"], "explicit")
        self.assertEqual(report["output"]["sampleFormat"], "IEEE_FLOAT32_LE")
        self.assertEqual(report["model"]["revision"], probe.EXPECTED_MODEL_REVISION)
        self.assertEqual(
            report["executedRequest"],
            {
                "schemaVersion": 1,
                "frameRate": 25,
                "durationFrames": 2,
                "prompt": "dry piano trio",
                "seed": 7,
                "notesMode": "explicit",
                "notes": [],
            },
        )
        self.assertEqual(self.request_path.read_bytes(), self.request_raw)

    def test_absent_does_not_send_note_condition_and_empty_sends_zeros(self):
        self.request_path.write_bytes(encode(request_document(durationFrames=1)))
        absent_adapter = FakeAdapter()
        code, _ = self.run_with(absent_adapter, "absent")
        self.assertEqual(code, 0)
        self.assertEqual(absent_adapter.note_frames, [None])

        self.request_path.write_bytes(encode(request_document(durationFrames=1, notes=[])))
        empty_adapter = FakeAdapter()
        code, _ = self.run_with(empty_adapter, "empty")
        self.assertEqual(code, 0)
        self.assertEqual(len(empty_adapter.note_frames[0]), 128)
        self.assertFalse(any(empty_adapter.note_frames[0]))

    def test_generation_failure_and_cancellation_do_not_publish_and_release(self):
        failed = FakeAdapter(fail_at=0)
        code, output = self.run_with(failed, "failed")
        self.assertEqual(code, 1)
        self.assertFalse((output / "output.wav").exists())
        self.assertTrue(failed.close_called)
        self.assertTrue(failed.final_cleanup_called)
        self.assertEqual(
            json.loads((output / "report.json").read_text())["outcome"], "failed"
        )

        cancellation = probe.Cancellation()
        cancelled = FakeAdapter(cancellation=cancellation)
        code, output = self.run_with(
            cancelled, "cancelled", cancellation=cancellation
        )
        self.assertEqual(code, 130)
        self.assertFalse((output / "output.wav").exists())
        self.assertTrue(cancelled.close_called)
        self.assertEqual(
            json.loads((output / "report.json").read_text())["outcome"], "cancelled"
        )

    def test_bad_frame_is_failure_without_publish(self):
        samples = FakeSamples()
        samples.shape = (1, 2)
        adapter = FakeAdapter(waveform_factory=lambda: FakeWaveform(samples))
        code, output = self.run_with(adapter, "bad-frame")
        self.assertEqual(code, 1)
        self.assertFalse((output / "output.wav").exists())

    def test_incomplete_cleanup_is_failure_without_publish(self):
        fixtures = (
            ("release", {"released": False}),
            ("synchronize", {"released": True, "synchronized": False}),
            ("cache", {"released": True, "cache_cleared": False}),
        )
        for label, arguments in fixtures:
            with self.subTest(label=label):
                adapter = FakeAdapter(**arguments)
                code, output = self.run_with(adapter, f"cleanup-failure-{label}")
                self.assertEqual(code, 1)
                self.assertFalse((output / "output.wav").exists())
                report = json.loads((output / "report.json").read_text())
                self.assertEqual(report["outcome"], "failed")

    def test_cancellation_with_incomplete_cleanup_is_execution_failure(self):
        cancellation = probe.Cancellation()
        adapter = FakeAdapter(cancellation=cancellation, released=False)
        code, output = self.run_with(
            adapter,
            "cancel-cleanup-failure",
            cancellation=cancellation,
        )
        self.assertEqual(code, 1)
        self.assertFalse((output / "output.wav").exists())
        report = json.loads((output / "report.json").read_text())
        self.assertEqual(report["outcome"], "failed")
        self.assertEqual(report["error"]["type"], "CleanupFailure")
        self.assertFalse(report["cleanup"]["released"])
        self.assertEqual(report["failureContext"]["priorOutcome"], "cancelled")
        self.assertTrue(report["failureContext"]["cancellationRequested"])
        self.assertEqual(
            report["failureContext"]["priorError"]["type"], "ProbeCancelled"
        )

    def test_report_failure_cannot_return_success(self):
        adapter = FakeAdapter()

        def fail_report(_path, _document):
            raise OSError("fixture report failure")

        code, output = self.run_with(
            adapter, "report-failure", report_writer=fail_report
        )
        self.assertEqual(code, 1)
        self.assertFalse((output / "output.wav").exists())
        self.assertFalse((output / "report.json").exists())

    def test_partial_success_report_is_removed_on_transaction_failure(self):
        adapter = FakeAdapter()
        calls = 0

        def write_then_fail(path, document):
            nonlocal calls
            calls += 1
            if calls == 1:
                path.write_bytes(probe._report_payload(document))
            raise OSError("failure after report file creation")

        code, output = self.run_with(
            adapter, "partial-report-failure", report_writer=write_then_fail
        )
        self.assertEqual(code, 1)
        self.assertFalse((output / "output.wav").exists())
        self.assertFalse((output / "report.json").exists())

    def test_report_failure_preserves_replaced_output_file(self):
        adapter = FakeAdapter()
        calls = 0
        foreign = b"replacement-not-owned-by-probe"

        def replace_output_then_fail(_path, _document):
            nonlocal calls
            calls += 1
            if calls == 1:
                output_wav = self.root / "replaced-output" / "output.wav"
                output_wav.unlink()
                output_wav.write_bytes(foreign)
            raise OSError("fixture report failure after replacement")

        code, output = self.run_with(
            adapter,
            "replaced-output",
            report_writer=replace_output_then_fail,
        )
        self.assertEqual(code, 1)
        self.assertEqual((output / "output.wav").read_bytes(), foreign)
        self.assertFalse((output / "report.json").exists())

    def test_constructor_failure_reports_cleanup_unknown(self):
        def fail_constructor(_backend, _root, _request):
            raise RuntimeError("constructor fixture")

        code, output = self.run_with(
            FakeAdapter(),
            "constructor-failure",
            adapter_factory=fail_constructor,
        )
        self.assertEqual(code, 1)
        self.assertFalse((output / "output.wav").exists())
        report = json.loads((output / "report.json").read_text())
        self.assertEqual(report["outcome"], "failed")
        self.assertEqual(report["cleanup"]["status"], "unknownDuringConstruction")
        self.assertFalse(report["cleanup"]["released"])

    def test_surrogate_prompt_is_input_error(self):
        self.request_path.write_bytes(
            b'{"schemaVersion":1,"frameRate":25,"durationFrames":1,'
            b'"prompt":"\\ud800","seed":0}'
        )
        adapter = FakeAdapter()
        code, output = self.run_with(adapter, "surrogate-prompt")
        self.assertEqual(code, 2)
        self.assertFalse(output.exists())
        self.assertFalse(adapter.note_frames)

    def test_rejects_request_symlink_existing_output_and_overlap(self):
        request_link = self.root / "request-link.json"
        request_link.symlink_to(self.request_path)
        adapter = FakeAdapter()
        code, output = self.run_with(
            adapter, "request-link-job", request_text=os.fspath(request_link)
        )
        self.assertEqual(code, 2)
        self.assertFalse(output.exists())

        existing = self.root / "existing"
        existing.mkdir()
        code, _ = self.run_with(adapter, "unused", output_text=os.fspath(existing))
        self.assertEqual(code, 2)

        nested = self.model_root / "new-job"
        code, _ = self.run_with(adapter, "unused-2", output_text=os.fspath(nested))
        self.assertEqual(code, 2)
        self.assertFalse(nested.exists())

    def test_rejects_model_and_output_ancestor_symlinks(self):
        real_parent = self.root / "real-parent"
        real_parent.mkdir()
        linked_parent = self.root / "linked-parent"
        linked_parent.symlink_to(real_parent, target_is_directory=True)
        adapter = FakeAdapter()
        code, _ = self.run_with(
            adapter,
            "unused",
            output_text=os.fspath(linked_parent / "job"),
        )
        self.assertEqual(code, 2)
        self.assertFalse((real_parent / "job").exists())

        model_link = self.root / "model-link"
        model_link.symlink_to(self.model_root, target_is_directory=True)
        code, output = self.run_with(
            adapter,
            "model-link-job",
            model_root_text=os.fspath(model_link),
        )
        self.assertEqual(code, 2)
        self.assertFalse(output.exists())

    def test_manifest_digest_size_and_escape_are_rejected_before_load(self):
        manifest_path = self.model_root / probe.MANIFEST_NAME
        original = json.loads(manifest_path.read_text())
        for label, mutate in (
            ("digest", lambda value: value["files"][0].update(sha256="0" * 64)),
            ("size", lambda value: value["files"][0].update(size=999)),
            ("escape", lambda value: value["files"][0].update(path="../request.json")),
        ):
            with self.subTest(label=label):
                manifest = json.loads(json.dumps(original))
                mutate(manifest)
                manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
                adapter = FakeAdapter()
                code, output = self.run_with(adapter, f"manifest-{label}")
                self.assertEqual(code, 2)
                self.assertFalse(adapter.note_frames)
                self.assertFalse((output / "output.wav").exists())
                self.assertEqual(
                    json.loads((output / "report.json").read_text())["outcome"],
                    "invalidInput",
                )
        manifest_path.write_text(json.dumps(original), encoding="utf-8")


if __name__ == "__main__":
    unittest.main()
