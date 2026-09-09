from __future__ import annotations

from array import array
import contextlib
import hashlib
import io
import importlib.util
import json
import math
import marshal
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock


PYTHON_DIR = Path(__file__).resolve().parents[1] / "Python"
sys.path.insert(0, str(PYTHON_DIR))

import d_audio_backend as backend
import d_audio_contract as contract
import d_audio_sa3 as sa3
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
        for raw in (b"{", b'{"a":1,"a":2}', b'{"a":NaN}', b'{"a":1e100000}'):
            with self.subTest(raw=raw), self.assertRaises(contract.ContractError):
                contract.decode_strict_json(raw, label="fixture")

    def test_json_depth_and_numeric_conversion_overflow(self):
        def nested(containers):
            raw = b"{}"
            for _ in range(containers - 1):
                raw = b'{"x":' + raw + b"}"
            return raw
        self.assertIsInstance(contract.decode_strict_json(nested(32), label="fixture"), dict)
        with self.assertRaisesRegex(contract.ContractError, "nesting"):
            contract.decode_strict_json(nested(33), label="fixture")
        request = self.base_request()
        request["durationSeconds"] = 10**10_000
        with self.assertRaises(contract.ContractError):
            contract.validate_request(request, profile="sm-music")

    def test_generation_ties_even_and_edit_uses_source_frames(self):
        request = self.base_request(frames=2)
        request["durationSeconds"] = 2.5 / 44_100
        self.assertEqual(contract.validate_request(request, profile="sm-music").requested_frames, 2)
        request["durationSeconds"] = 3.5 / 44_100
        self.assertEqual(contract.validate_request(request, profile="sm-music").requested_frames, 4)
        source = self.make_source(frames=10)
        edit = self.base_request("variation", frames=10, source_path=source)
        edit["durationSeconds"] = 10.5 / 44_100
        self.assertEqual(contract.validate_request(edit, profile="sm-music").requested_frames, 10)
        edit["durationSeconds"] = 10.5001 / 44_100
        with self.assertRaises(contract.ContractError):
            contract.validate_request(edit, profile="sm-music")

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
        probe = (
            "from pathlib import Path; import sys; "
            f"sys.path.insert(0,{str(PYTHON_DIR)!r}); import d_audio_contract as c; "
            "\ntry: c.read_regular_file(Path(sys.argv[1]),max_bytes=1024,label='fifo')"
            "\nexcept c.ContractError: raise SystemExit(0)"
            "\nraise SystemExit(1)"
        )
        completed = subprocess.run([sys.executable, "-B", "-c", probe, str(fifo)],
                                   stdin=subprocess.DEVNULL, capture_output=True, timeout=5)
        self.assertEqual(completed.returncode, 0, completed.stderr)
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
        self.assertEqual(events[-1]["requiredWeightBytes"], 32)
        self.assertEqual(list(job.iterdir()), [])

    def test_missing_mlx_measurements_are_unavailable_not_zero(self):
        measured, peak = sa3._measure(object(), None, "fixturePhase")
        self.assertIsNone(peak)
        self.assertEqual(measured["measurementKind"], "unavailable")
        self.assertEqual(measured["measurementPhase"], "fixturePhase")
        self.assertIsNone(measured["activeBytes"])
        self.assertIsNone(measured["cacheBytes"])
        self.assertIsNone(measured["peakBytes"])
        self.assertIsNone(measured["observedActiveLowerBoundBytes"])

        class PartialMetrics:
            def get_active_memory(self):
                return 17
            def get_cache_memory(self):
                return -1
            def get_peak_memory(self):
                return "99"
        measured, peak = sa3._measure(PartialMetrics(), None, "partialFixture")
        self.assertIsNone(peak)
        self.assertEqual(measured["measurementKind"], "partial-mlx-allocator")
        self.assertEqual(measured["observedActiveLowerBoundBytes"], 17)
        self.assertIsNone(measured["peakBytes"])

    def test_cleanup_failure_cpu_standin_is_reported(self):
        class BrokenCleanup:
            def synchronize(self):
                raise RuntimeError("fixture synchronize failure")
            def clear_cache(self):
                raise AssertionError("must not continue after failed synchronize")
        with self.assertRaisesRegex(RuntimeError, "fixture synchronize failure"):
            sa3._release(BrokenCleanup())

    def test_verified_source_loader_ignores_stale_pyc_and_cleans_owned_module(self):
        vendor = self.root / "vendor-probe"
        vendor.mkdir()
        source = vendor / "probe.py"
        source.write_text("VALUE = 1\n", encoding="utf-8")
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        cache = Path(importlib.util.cache_from_source(str(source)))
        cache.parent.mkdir(parents=True)
        wrong = compile("VALUE = 99\n", str(source), "exec", dont_inherit=True)
        cache.write_bytes(
            importlib.util.MAGIC_NUMBER
            + struct.pack("<III", 0, int(source.stat().st_mtime), source.stat().st_size)
            + marshal.dumps(wrong)
        )
        module = sa3._vendor_import("probe", vendor, {"probe.py": digest})
        self.assertEqual(module.VALUE, 1)
        self.assertNotIn("probe", sys.modules)
        self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), digest)
        sys.modules["probe"] = types.ModuleType("probe")
        try:
            with self.assertRaisesRegex(contract.ContractError, "preloaded"):
                sa3._vendor_import("probe", vendor, {"probe.py": digest})
        finally:
            del sys.modules["probe"]

    def test_verified_source_loader_supports_listed_relative_imports_only(self):
        vendor = self.root / "vendor-package"
        package = vendor / "fixturepkg"
        package.mkdir(parents=True)
        files = {
            "fixturepkg/__init__.py": "",
            "fixturepkg/value.py": "VALUE = 7\n",
            "fixturepkg/consumer.py": "from .value import VALUE\nRESULT = VALUE + 1\n",
        }
        checked = {}
        for relative, text in files.items():
            path = vendor.joinpath(*relative.split("/"))
            path.write_text(text, encoding="utf-8")
            checked[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
        module = sa3._vendor_import("fixturepkg.consumer", vendor, checked)
        self.assertEqual(module.RESULT, 8)
        self.assertFalse(any(name == "fixturepkg" or name.startswith("fixturepkg.") for name in sys.modules))
        (package / "unlisted.py").write_text("VALUE = 99\n", encoding="utf-8")
        (package / "consumer.py").write_text("from .unlisted import VALUE\n", encoding="utf-8")
        checked["fixturepkg/consumer.py"] = hashlib.sha256((package / "consumer.py").read_bytes()).hexdigest()
        with self.assertRaises(ModuleNotFoundError):
            sa3._vendor_import("fixturepkg.consumer", vendor, checked)

    def test_full_mock_orchestration_and_result_identity(self):
        args, job, request_value, _source = self.make_launch()
        def fake_engine(request, _manifest, _model, _vendor, _source_wave, progress, _cancelled):
            progress("encodingText", 0, 1)
            progress("encodingText", 1, 1)
            return InferenceResult(array("f", [0.125] * request.requested_frames * 2),
                                   {"mock": 0.0}, {"measurementKind": "unavailable",
                                                    "measurementPhase": "mock",
                                                    "activeBytes": None, "cacheBytes": None,
                                                    "peakBytes": None})
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = backend.main(args, engine=fake_engine)
        self.assertEqual(code, 0)
        terminal = json.loads(output.getvalue().splitlines()[-1])
        self.assertEqual(terminal, json.loads((job / "result.json").read_text()))
        self.assertEqual(terminal["runID"], request_value["runID"])
        self.assertTrue((job / "output.wav").is_file())

    def test_cli_invalid_and_readonly_streams_full_process(self):
        environment = os.environ.copy()
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        completed = subprocess.run(
            [sys.executable, "-B", str(PYTHON_DIR / "d_audio_backend.py")],
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10, env=environment,
        )
        self.assertEqual(completed.returncode, 2)
        self.assertEqual(json.loads(completed.stdout.splitlines()[-1])["kind"], "configuration")
        protected = self.root / "readonly-descriptor"
        protected.write_bytes(b"unchanged")
        before = protected.read_bytes()
        for stdout_readonly, stderr_readonly in ((True, False), (False, True), (True, True)):
            stdout_fd = os.open(protected, os.O_RDONLY) if stdout_readonly else subprocess.PIPE
            stderr_fd = os.open(protected, os.O_RDONLY) if stderr_readonly else subprocess.PIPE
            try:
                child = subprocess.run(
                    [sys.executable, "-B", str(PYTHON_DIR / "d_audio_backend.py")],
                    stdin=subprocess.DEVNULL, stdout=stdout_fd, stderr=stderr_fd,
                    timeout=10, env=environment,
                )
            finally:
                if stdout_readonly:
                    os.close(stdout_fd)
                if stderr_readonly:
                    os.close(stderr_fd)
            with self.subTest(stdout=stdout_readonly, stderr=stderr_readonly):
                self.assertEqual(child.returncode, 2)
                self.assertEqual(protected.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
