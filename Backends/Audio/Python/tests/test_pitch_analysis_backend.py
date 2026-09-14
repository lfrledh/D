from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import math
from pathlib import Path
import struct
import tempfile
import types
import unittest
import uuid
from contextlib import contextmanager, redirect_stderr, redirect_stdout


SCRIPT = Path(__file__).resolve().parents[1] / "d_pitch_analysis_backend.py"
SPEC = importlib.util.spec_from_file_location("d_pitch_analysis_backend_under_test", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
provider = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(provider)


def valid_request(root: Path, count: int = 256) -> dict[str, object]:
    raw = struct.pack("<" + "f" * count, *([0.0] * count))
    input_path = root / "input.f32"
    input_path.write_bytes(raw)
    model = root / "swift_f0"
    model.mkdir()
    run = root / "run"
    run.mkdir()
    return {
        "schemaVersion": 1,
        "runID": str(uuid.uuid4()),
        "source": {
            "assetID": str(uuid.uuid4()), "documentID": str(uuid.uuid4()),
            "documentRevision": 3, "contentSHA256": "a" * 64,
            "sampleRate": 16000.0, "frameCount": count,
            "startFrame": 0, "endFrame": count,
        },
        "profile": provider.PROFILE, "preprocessing": provider.PREPROCESSING,
        "modelSHA256": provider.MODEL_SHA256,
        "inputSHA256": hashlib.sha256(raw).hexdigest(), "sampleCount": count,
        "inputPath": str(input_path), "modelDirectory": str(model), "runDirectory": str(run),
    }


class PitchProviderValidationTests(unittest.TestCase):
    def test_hum2_preprocessing_identifier_is_frozen(self) -> None:
        self.assertEqual(provider.PREPROCESSING,
                         "avconverter-mono16k-prime-normal-v1")

    def test_request_rejects_boolean_integer_unknown_key_and_wrong_digest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for mutate in (
                lambda value: value.update(schemaVersion=True),
                lambda value: value.update(extra=1),
                lambda value: value.update(modelSHA256="0" * 64),
                lambda value: value.update(sampleCount=255),
            ):
                case = root / str(uuid.uuid4())
                case.mkdir()
                request = valid_request(case)
                mutate(request)
                with self.assertRaises(provider.ProtocolError):
                    provider._validate_request(request)

    def test_strict_json_rejects_duplicate_and_nonfinite_values(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "request.json"
            path.write_text('{"schemaVersion":1,"schemaVersion":1}', encoding="utf-8")
            with self.assertRaises(provider.ProtocolError):
                provider._read_strict_json(path)
            path.write_text('{"value":NaN}', encoding="utf-8")
            with self.assertRaises(provider.ProtocolError):
                provider._read_strict_json(path)

    def test_frame_validation_hides_unvoiced_pitch_only_after_full_predicate(self) -> None:
        frames = provider._validated_frames(
            [440.0, 440.0, 3000.0], [0.91, 0.9, 0.99], [True, False, False], 3)
        self.assertEqual([item["voiced"] for item in frames], [True, False, False])
        with self.assertRaises(provider.ProtocolError):
            provider._validated_frames([440.0], [0.91], [False], 1)
        with self.assertRaises(provider.ProtocolError):
            provider._validated_frames([math.nan], [0.1], [False], 1)
        with self.assertRaises(provider.ProtocolError):
            provider._validated_frames([440.0], [True], [True], 1)

    def test_fake_detector_contract_has_explicit_floor_frame_count(self) -> None:
        class Detector:
            def detect_from_array(self, audio: object, sample_rate: int) -> object:
                self.sample_rate = sample_rate
                return types.SimpleNamespace(pitch_hz=[220.0], confidence=[0.95], voicing=[True],
                                             timestamps=[127.5 / 16000])

        request = {"sampleCount": 257}
        detector = Detector()
        result = detector.detect_from_array([0.0] * 257, 16000)
        frames = provider._validated_frames(result.pitch_hz, result.confidence, result.voicing,
                                             request["sampleCount"] // provider.HOP)
        self.assertEqual(len(frames), 1)
        self.assertEqual(detector.sample_rate, 16000)

    def test_real_numpy_boolean_scalars_and_numeric_type_boundaries(self) -> None:
        import numpy as np

        frames = provider._validated_frames(
            np.array([440.0, 440.0]), np.array([0.95, 0.1]),
            np.array([True, False], dtype=np.bool_), 2)
        self.assertEqual([item["voiced"] for item in frames], [True, False])
        fake_boolean = type("bool_", (), {"__bool__": lambda self: True})()
        for pitch, confidence, voicing in (
            (np.bool_(True), 0.95, True),
            (440.0, np.bool_(True), True),
            (440.0, 0.95, 1),
            (440.0, 0.95, fake_boolean),
        ):
            with self.subTest(pitch=repr(pitch), confidence=repr(confidence),
                              voicing=repr(voicing)):
                with self.assertRaises(provider.ProtocolError):
                    provider._validated_frames([pitch], [confidence], [voicing], 1)

    def test_access_arguments_are_all_or_nothing(self) -> None:
        args = types.SimpleNamespace(access_manifest="/tmp/access.json", access_run_id=None,
                                     model_directory=None, input_directory=None, run_directory=None)
        with self.assertRaises(provider.ProtocolError):
            provider._access_context(args)

    def test_access_is_acquired_before_request_read_and_paths_are_then_bound(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            frozen = valid_request(root)
            request_path = Path(frozen["runDirectory"]) / "request.json"
            state = {"active": False}

            @contextmanager
            def fake_helper(manifest: Path, run_id: str, directories: list[Path]):
                self.assertEqual(manifest, root / "access.json")
                self.assertEqual(run_id, frozen["runID"])
                self.assertEqual(directories, [Path(frozen["modelDirectory"]),
                                               Path(frozen["inputPath"]).parent,
                                               Path(frozen["runDirectory"])])
                state["active"] = True
                request_path.write_text(json.dumps(frozen), encoding="utf-8")
                try:
                    yield
                finally:
                    state["active"] = False

            def fake_analyzer(request: dict[str, object]) -> dict[str, object]:
                self.assertTrue(state["active"])
                self.assertEqual(request["runID"], frozen["runID"])
                return {"result": "controlled"}

            args = types.SimpleNamespace(
                request=str(request_path), access_manifest=str(root / "access.json"),
                access_run_id=frozen["runID"], model_directory=frozen["modelDirectory"],
                input_directory=str(Path(frozen["inputPath"]).parent),
                run_directory=frozen["runDirectory"])
            self.assertEqual(provider._execute(args, fake_helper, fake_analyzer),
                             {"result": "controlled"})
            self.assertFalse(state["active"])

    def test_bounded_descriptor_reads_reject_oversize_and_linked_parent(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            oversized = root / "oversized.bin"
            with oversized.open("wb") as stream:
                stream.truncate(provider.MAX_REQUEST_BYTES + 1)
            with self.assertRaises(provider.ProtocolError):
                provider._bounded_regular_bytes(
                    oversized, provider.MAX_REQUEST_BYTES, "oversized fixture")

            real = root / "real"
            real.mkdir()
            (real / "input.bin").write_bytes(b"safe")
            linked = root / "linked"
            linked.symlink_to(real, target_is_directory=True)
            with self.assertRaises(provider.ProtocolError):
                provider._bounded_regular_bytes(linked / "input.bin", 4, "linked fixture")

    def test_cli_invalid_request_keeps_stdout_protocol_clean(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            request = Path(temporary) / "request.json"
            request.write_text('{"schemaVersion":true}', encoding="utf-8")
            stdout, stderr = io.StringIO(), io.StringIO()
            with redirect_stdout(stdout), redirect_stderr(stderr):
                status = provider.main(["--request", str(request)])
            self.assertEqual(status, 2)
            self.assertEqual(stdout.getvalue(), "")
            self.assertTrue(stderr.getvalue().startswith("pitch provider failed:"))


if __name__ == "__main__":
    unittest.main()
