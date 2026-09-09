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

import d_audio_backend as backend
import d_audio_contract as contract
from d_audio_sa3 import InferenceResult, VENDOR_PROVENANCE_SHA256, verify_vendor


VENDOR = Path(__file__).resolve().parents[3] / "Vendor" / "stable-audio3-mlx"


def wave_bytes(samples, *, bits=16, tag=1, rate=44_100, channels=2):
    payload = bytearray()
    if tag == 3:
        for sample in samples:
            payload.extend(struct.pack("<f", sample))
    elif bits == 16:
        for sample in samples:
            payload.extend(struct.pack("<h", sample))
    elif bits == 24:
        for sample in samples:
            value = sample & 0xFFFFFF
            payload.extend((value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF))
    elif bits == 32:
        for sample in samples:
            payload.extend(struct.pack("<i", sample))
    align = channels * (bits // 8)
    fmt = struct.pack("<HHIIHH", tag, channels, rate, rate * align, align, bits)
    riff_size = 4 + 8 + len(fmt) + 8 + len(payload)
    return b"RIFF" + struct.pack("<I", riff_size) + b"WAVEfmt " + struct.pack("<I", len(fmt)) + fmt + b"data" + struct.pack("<I", len(payload)) + bytes(payload)


class AudioBackendTests(unittest.TestCase):
    def setUp(self):
        temp_parent = os.environ.get("D_TEST_TEMP_DIR") or os.environ.get("TMPDIR")
        self.temporary = tempfile.TemporaryDirectory(dir=temp_parent)
        self.root = Path(self.temporary.name).resolve()

    def tearDown(self):
        self.temporary.cleanup()

    def base_request(self, operation="generate", *, frames=12_288, source_path=None, encoding="int16"):
        request = {
            "schemaVersion": 1,
            "runID": "12345678-1234-4234-9234-123456789abc",
            "operation": operation,
            "prompt": "雨音 🎵",
            "durationSeconds": frames / 44_100,
            "seed": 2**32 - 2,
            "steps": 8,
            "guidanceScale": 1,
            "strength": 1 if operation == "generate" else 0.5,
        }
        if operation != "generate":
            assert source_path is not None
            raw = source_path.read_bytes()
            request["source"] = {
                "path": str(source_path), "sha256": hashlib.sha256(raw).hexdigest(),
                "frameCount": frames, "sampleRate": 44_100, "channels": 2,
            }
        if operation == "inpaint":
            request["editRegion"] = {"startFrame": 4096, "endFrame": 8192}
        return request

    def make_source(self, *, frames=12_288, bits=16, tag=1, value=1000):
        path = self.root / "source.wav"
        path.write_bytes(wave_bytes([value, -value] * frames, bits=bits, tag=tag))
        return path

    def make_launch(self, operation="generate"):
        job = self.root / "job"
        model = self.root / "model"
        job.mkdir()
        (model / "MLX").mkdir(parents=True)
        source = self.make_source() if operation != "generate" else None
        request_value = self.base_request(operation, source_path=source)
        request_path = self.root / "request.json"
        request_path.write_text(json.dumps(request_value), encoding="utf-8")
        names = contract.required_weight_names("sm-music")
        files = []
        for index, name in enumerate(names):
            payload = f"weight-{index}".encode()
            path = model.joinpath(*name.split("/"))
            path.write_bytes(payload)
            files.append({"path": name, "size": len(payload), "sha256": hashlib.sha256(payload).hexdigest()})
        manifest_path = self.root / "manifest.json"
        manifest_path.write_text(json.dumps({
            "schemaVersion": 1, "repository": contract.MODEL_REPOSITORY,
            "revision": contract.MODEL_REVISION, "files": files,
        }), encoding="utf-8")
        args = ["--request", str(request_path), "--job-directory", str(job),
                "--model-directory", str(model), "--profile", "sm-music",
                "--manifest", str(manifest_path), "--vendor-directory", str(VENDOR)]
        return args, job, request_value, source

    def test_three_operation_contracts_unicode_and_large_seed(self):
        generated = contract.validate_request(self.base_request(), profile="sm-music")
        self.assertEqual(generated.seed, 2**32 - 2)
        self.assertEqual(generated.prompt, "雨音 🎵")
        source = self.make_source()
        variation = contract.validate_request(self.base_request("variation", source_path=source), profile="sm-music")
        inpaint = contract.validate_request(self.base_request("inpaint", source_path=source), profile="sm-music")
        self.assertIsNone(variation.edit_region)
        self.assertEqual(inpaint.effective_latent_region, (1, 2))

    def test_request_rejects_bool_version_types_nonfinite_and_unknown(self):
        for key, value in (("schemaVersion", True), ("seed", True), ("steps", 0),
                           ("durationSeconds", math.inf), ("guidanceScale", 16)):
            request = self.base_request()
            request[key] = value
            with self.subTest(key=key), self.assertRaises(contract.ContractError):
                contract.validate_request(request, profile="sm-music")
        request = self.base_request()
        request["unknown"] = 1
        with self.assertRaises(contract.ContractError):
            contract.validate_request(request, profile="sm-music")

    def test_json_malformed_duplicate_and_nonfinite(self):
        for raw in (b"{", b'{"a":1,"a":2}', b'{"a":NaN}'):
            with self.subTest(raw=raw), self.assertRaises(contract.ContractError):
                contract.decode_strict_json(raw, label="fixture")

    def test_prompt_utf8_limit_and_empty_latent_region(self):
        request = self.base_request()
        request["prompt"] = "é" * (contract.MAX_CONFIG_BYTES // 2 + 1)
        with self.assertRaises(contract.ContractError):
            contract.validate_request(request, profile="sm-music")
        source = self.make_source()
        request = self.base_request("inpaint", source_path=source)
        request["editRegion"] = {"startFrame": 1, "endFrame": 2}
        with self.assertRaisesRegex(contract.ContractError, "empty latent"):
            contract.validate_request(request, profile="sm-music")

    def test_pcm_integer_and_float_decoding_including_int32_boundary(self):
        cases = [
            (16, 1, [-32768, 32767], -1.0),
            (24, 1, [-8388608, 8388607], -1.0),
            (32, 1, [-2147483648, 2147483647], -1.0),
            (32, 3, [-0.25, 0.75], -0.25),
        ]
        for bits, tag, samples, first in cases:
            decoded = contract.decode_wave_bytes(wave_bytes(samples, bits=bits, tag=tag))
            with self.subTest(bits=bits, tag=tag):
                self.assertEqual(decoded.frame_count, 1)
                self.assertEqual(decoded.samples[0], first)
        int32 = contract.decode_wave_bytes(wave_bytes([-2147483648, 2147483647], bits=32))
        self.assertEqual(int32.samples[1], 1.0)  # explicit float32 rounding boundary

    def test_pcm_rejects_rate_channels_and_nonfinite_float(self):
        for raw in (wave_bytes([0, 0], rate=48_000), wave_bytes([0], channels=1),
                    wave_bytes([math.nan, 0.0], bits=32, tag=3)):
            with self.assertRaises(contract.ContractError):
                contract.decode_wave_bytes(raw)

    def test_source_digest_frame_and_changed_file(self):
        source = self.make_source(frames=1)
        raw = source.read_bytes()
        spec = contract.SourceSpec(source, "0" * 64, 1, 44_100, 2)
        with self.assertRaisesRegex(contract.ContractError, "SHA"):
            contract.read_source_wave(spec)
        spec = contract.SourceSpec(source, hashlib.sha256(raw).hexdigest(), 2, 44_100, 2)
        with self.assertRaisesRegex(contract.ContractError, "frameCount"):
            contract.read_source_wave(spec)
        spec = contract.SourceSpec(source, hashlib.sha256(raw).hexdigest(), 1, 44_100, 2)
        original_hash = contract.hash_regular_file
        def changing_hash(path, *, expected_size, label):
            source.write_bytes(raw + b"x")
            return hashlib.sha256(raw).hexdigest()
        with mock.patch.object(contract, "hash_regular_file", side_effect=changing_hash):
            with self.assertRaisesRegex(contract.ContractError, "metadata changed"):
                contract.read_source_wave(spec)
        source.write_bytes(raw)
        self.assertEqual(original_hash(source, expected_size=len(raw), label="source"), hashlib.sha256(raw).hexdigest())

    def test_manifest_exact_four_and_weight_corruption(self):
        args, _job, _request, _source = self.make_launch()
        manifest_path = Path(args[args.index("--manifest") + 1])
        model = Path(args[args.index("--model-directory") + 1])
        value = json.loads(manifest_path.read_text())
        manifest = contract.validate_manifest(value, profile="sm-music")
        contract.verify_manifest_weights(manifest, model)
        for mutation in ("extra", "duplicate", "untrusted"):
            changed = json.loads(json.dumps(value))
            if mutation == "extra":
                changed["files"].append(changed["files"][0])
            elif mutation == "duplicate":
                changed["files"][1] = changed["files"][0]
            else:
                changed["files"][0]["path"] = "../evil.npz"
            with self.subTest(mutation=mutation), self.assertRaises(contract.ContractError):
                contract.validate_manifest(changed, profile="sm-music")
        model.joinpath(*manifest.entries[0].relative_path.split("/")).write_bytes(b"corrupt")
        with self.assertRaises(contract.ContractError):
            contract.verify_manifest_weights(manifest, model)

    def test_paths_overlap_symlink_and_special_file(self):
        args, job, _request, _source = self.make_launch()
        request = Path(args[args.index("--request") + 1])
        model = Path(args[args.index("--model-directory") + 1])
        manifest = Path(args[args.index("--manifest") + 1])
        with self.assertRaises(contract.ContractError):
            contract.validate_launch_paths(request, model / "MLX", model, manifest, VENDOR)
        link = self.root / "linked-request.json"
        link.symlink_to(request)
        with self.assertRaises(contract.ContractError):
            contract.read_regular_file(link, max_bytes=1024, label="link")
        fifo = self.root / "fifo"
        os.mkfifo(fifo)
        with self.assertRaises(contract.ContractError):
            contract.read_regular_file(fifo, max_bytes=1024, label="fifo")
        self.assertEqual(list(job.iterdir()), [])

    def test_atomic_publication_no_overwrite_and_failure_cleanup(self):
        job = self.root / "job"
        job.mkdir()
        target = contract.publish_exclusive(job, "output.wav", b"first")
        self.assertEqual(target.read_bytes(), b"first")
        with self.assertRaises(contract.ContractError):
            contract.publish_exclusive(job, "output.wav", b"second")
        failing = self.root / "failing"
        failing.mkdir()
        with mock.patch.object(contract.os, "link", side_effect=OSError("fixture failure")):
            with self.assertRaises(contract.ContractError):
                contract.publish_exclusive(failing, "result.json", b"{}")
        self.assertEqual(list(failing.iterdir()), [])

    def test_inpaint_preserves_float32_conversion_outside_region(self):
        source = contract.decode_wave_bytes(wave_bytes([-2147483648, 2147483647] * 3, bits=32))
        generated = array("f", [0.25, -0.25] * 3)
        result = contract.preserve_inpaint_outside(generated, source, contract.EditRegion(1, 2))
        self.assertEqual(result[0:2], source.samples[0:2])
        self.assertEqual(result[2:4], generated[2:4])
        self.assertEqual(result[4:6], source.samples[4:6])

    def test_vendor_exact_provenance_and_hashes(self):
        raw = (VENDOR / "provenance.json").read_bytes()
        self.assertEqual(hashlib.sha256(raw).hexdigest(), VENDOR_PROVENANCE_SHA256)
        checked = verify_vendor(VENDOR)
        self.assertIn("models/defs/sa3_pipeline.py", checked)

    def test_inspect_subprocess_without_mlx(self):
        args, job, _request, _source = self.make_launch()
        environment = os.environ.copy()
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["TMPDIR"] = str(self.root)
        completed = subprocess.run(
            [sys.executable, "-B", str(PYTHON_DIR / "d_audio_backend.py"), *args, "--inspect"],
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10, env=environment,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        events = [json.loads(line) for line in completed.stdout.splitlines()]
        self.assertEqual(events[-1]["type"], "inspection")
        self.assertEqual(events[-1]["requiredWeightBytes"], sum(range(8, 12)))
        self.assertEqual(list(job.iterdir()), [])

    def test_full_mock_orchestration_and_result_identity(self):
        args, job, request_value, _source = self.make_launch()
        def fake_engine(request, _manifest, _model, _vendor, _source_wave, progress, _cancelled):
            progress("encodingText", 0, 1)
            progress("encodingText", 1, 1)
            return InferenceResult(array("f", [0.125] * request.requested_frames * 2),
                                   {"mock": 0.0}, {"activeBytes": 0, "cacheBytes": 0, "peakBytes": 0})
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = backend.main(args, engine=fake_engine)
        self.assertEqual(code, 0)
        terminal = json.loads(output.getvalue().splitlines()[-1])
        self.assertEqual(terminal, json.loads((job / "result.json").read_text()))
        self.assertEqual(terminal["runID"], request_value["runID"])
        self.assertTrue((job / "output.wav").is_file())

    def test_cli_invalid_and_stdout_broken_pipe_controlled(self):
        environment = os.environ.copy()
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        completed = subprocess.run(
            [sys.executable, "-B", str(PYTHON_DIR / "d_audio_backend.py")],
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10, env=environment,
        )
        self.assertEqual(completed.returncode, 2)
        self.assertEqual(json.loads(completed.stdout.splitlines()[-1])["kind"], "configuration")
        class Broken:
            def write(self, _value):
                raise BrokenPipeError("fixture")
            def flush(self):
                raise BrokenPipeError("fixture")
        with mock.patch.object(sys, "stdout", Broken()):
            self.assertEqual(backend.main([]), 2)


if __name__ == "__main__":
    unittest.main()
