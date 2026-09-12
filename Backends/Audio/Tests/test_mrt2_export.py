from __future__ import annotations

import importlib
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest import mock

import numpy as np


PYTHON_DIR = Path(__file__).resolve().parents[1] / "Python"
sys.path.insert(0, str(PYTHON_DIR))

import d_mrt2_export as export


class FakeSentencePieceProcessor:
    encoded_inputs: list[str] = []

    def Load(self, path):
        self.path = path
        return True

    def EncodeAsIds(self, value):
        self.encoded_inputs.append(value)
        if value == "too long":
            return list(range(128))
        return [11, 12, 13]


class FakeInterpreter:
    instances: dict[str, "FakeInterpreter"] = {}

    def __init__(self, *, model_path):
        self.name = Path(model_path).name
        self.tensors = {}
        self.allocated = False
        type(self).instances[self.name] = self

    def allocate_tensors(self):
        self.allocated = True

    def get_input_details(self):
        if self.name == "text_encoder.tflite":
            return [
                {"index": 8, "dtype": np.float32, "shape": (1, 128)},
                {"index": 4, "dtype": np.int32, "shape": (1, 128)},
            ]
        if self.name == "mapper.tflite":
            return [
                {"index": 2, "dtype": np.float32, "shape": (1, 768)},
                {"index": 3, "dtype": np.float32, "shape": (1, 768)},
            ]
        return [{"index": 5, "dtype": np.float32, "shape": (1, 768)}]

    def get_output_details(self):
        return [{"index": 9}]

    def set_tensor(self, index, value):
        self.tensors[index] = np.array(value, copy=True)

    def invoke(self):
        return None

    def get_tensor(self, index):
        if self.name == "text_encoder.tflite":
            return np.linspace(1.0, 2.0, 768, dtype=np.float32).reshape(1, 768)
        if self.name == "mapper.tflite":
            return self.tensors[2] + self.tensors[3] * np.float32(0.01)
        return np.arange(12, dtype=np.int32).reshape(1, 12)


class FakeGraph:
    def __init__(self):
        self.calls = []
        self.audio = np.full((1, 2, 1920), 16384, dtype=np.int16)

    def __call__(self, args):
        self.calls.append([np.array(value, copy=True) for value in args])
        state = [np.array(value, copy=True) for value in args[9:]]
        state[0] = state[0] + np.uint32(1)
        state[2][0, 1] += np.uint32(1)
        return [np.array(self.audio, copy=True), *state]


class FakeRuntime:
    def __init__(self, *, state_count=165, default_key=(0, 42), key_dtype=np.uint32):
        self.graph = FakeGraph()
        self.eval_calls = 0
        self.sync_calls = 0
        self.clear_calls = 0
        self.clear_error = None
        self.state = {
            f"state_{index}": np.zeros((1,), dtype=np.uint32)
            for index in range(state_count)
        }
        if state_count > 2:
            self.state["state_2"] = np.array([default_key], dtype=key_dtype)

        self.mx = types.ModuleType("mlx.core")
        self.mx.int32 = np.int32
        self.mx.uint32 = np.uint32
        self.mx.array = lambda value, dtype=None: np.array(value, dtype=dtype)
        self.mx.zeros = lambda shape, dtype=None: np.zeros(shape, dtype=dtype)
        self.mx.import_function = self.import_function
        self.mx.load = self.load
        self.mx.eval = self.evaluate
        self.mx.synchronize = self.synchronize
        self.mx.clear_cache = self.clear_cache

    def import_function(self, path):
        self.graph_path = path
        return self.graph

    def load(self, path):
        self.state_path = path
        return self.state

    def evaluate(self, value):
        self.eval_calls += 1

    def synchronize(self):
        self.sync_calls += 1

    def clear_cache(self):
        self.clear_calls += 1
        if self.clear_error is not None:
            raise self.clear_error


class MRT2ExportTests(unittest.TestCase):
    def setUp(self):
        parent = os.environ.get("D_TEST_TEMP_DIR") or os.environ.get("TMPDIR")
        self.temporary = tempfile.TemporaryDirectory(dir=parent)
        self.root = Path(self.temporary.name).resolve()
        for relative in [
            export.GRAPH_RELATIVE_PATH,
            export.STATE_RELATIVE_PATH,
            *export.RESOURCE_RELATIVE_PATHS.values(),
        ]:
            path = self.root.joinpath(*relative.parts)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"fake")
        FakeSentencePieceProcessor.encoded_inputs = []
        FakeInterpreter.instances = {}

    def tearDown(self):
        self.temporary.cleanup()

    def modules(self, runtime):
        mlx_package = types.ModuleType("mlx")
        mlx_package.__path__ = []
        mlx_package.core = runtime.mx
        litert_package = types.ModuleType("ai_edge_litert")
        litert_package.__path__ = []
        litert_module = types.ModuleType("ai_edge_litert.interpreter")
        litert_module.Interpreter = FakeInterpreter
        sentencepiece = types.ModuleType("sentencepiece")
        sentencepiece.SentencePieceProcessor = FakeSentencePieceProcessor
        return mock.patch.dict(
            sys.modules,
            {
                "mlx": mlx_package,
                "mlx.core": runtime.mx,
                "ai_edge_litert": litert_package,
                "ai_edge_litert.interpreter": litert_module,
                "sentencepiece": sentencepiece,
            },
        )

    def make_subject(self, *, seed=7, prompt="MiXeD 音乐", runtime=None):
        runtime = runtime or FakeRuntime()
        with self.modules(runtime):
            subject = export.ExportedMRT2(self.root, prompt, seed)
        return subject, runtime

    def test_module_import_is_lazy_and_has_no_full_sdk_dependency(self):
        source = Path(export.__file__).read_text(encoding="utf-8")
        self.assertNotIn("import mlx", source)
        self.assertNotIn("import magenta_rt", source)
        self.assertNotIn("import jax", source)
        self.assertNotIn("import flax", source)
        self.assertNotIn("import sequence_layers", source)
        self.assertNotIn("import librosa", source)
        self.assertNotIn("_mx", {key for key in vars(export) if key == "mx"})

    def test_fixed_arguments_seed_guard_and_cross_frame_state(self):
        subject, runtime = self.make_subject(seed=99)
        self.assertEqual(len(runtime.graph.calls), 5)
        for index, warmup in enumerate(runtime.graph.calls):
            self.assertEqual(warmup[11].dtype, np.uint32)
            np.testing.assert_array_equal(warmup[11], [[0, 42 + index]])

        note_frame = tuple([0] * 127 + [2])
        samples = subject.generate_frame(note_frame)
        self.assertEqual(samples.shape, (1920, 2))
        self.assertEqual(samples.dtype, np.float32)
        self.assertTrue(np.isfinite(samples).all())
        np.testing.assert_array_equal(samples, np.full((1920, 2), 0.5, np.float32))

        call = runtime.graph.calls[5]
        self.assertEqual(len(call), 174)
        self.assertEqual(call[0].shape, (1, 1, 141))
        self.assertEqual(call[0].dtype, np.int32)
        np.testing.assert_array_equal(call[0][0, 0, :12], np.arange(12) + 7)
        np.testing.assert_array_equal(call[0][0, 0, 12:-1], np.array(note_frame) + 7)
        self.assertEqual(call[0][0, 0, -1], 6)
        np.testing.assert_array_equal(call[1], [1.3])
        np.testing.assert_array_equal(call[2], [40])
        self.assertEqual(call[2].dtype, np.int32)
        np.testing.assert_array_equal(call[3], [3.0])
        np.testing.assert_array_equal(call[4], [1.0])
        np.testing.assert_array_equal(call[5], [1.0])
        np.testing.assert_array_equal(call[6][0, 0, :12], [6] * 12)
        np.testing.assert_array_equal(call[6][0, 0, 12:-1], np.array(note_frame) + 7)
        np.testing.assert_array_equal(call[7][0, 0, :12], np.arange(12) + 7)
        np.testing.assert_array_equal(call[7][0, 0, 12:-1], [6] * 128)
        self.assertEqual(call[8].shape, (1, 0, 12))
        np.testing.assert_array_equal(call[11], [[0, 99]])
        np.testing.assert_array_equal(call[9], [0])

        subject.generate_frame(note_frame)
        next_call = runtime.graph.calls[6]
        np.testing.assert_array_equal(next_call[9], [1])
        np.testing.assert_array_equal(next_call[11], [[0, 100]])

    def test_absent_and_explicit_all_zero_notes_are_distinct(self):
        absent, absent_runtime = self.make_subject()
        absent.generate_frame(None)
        explicit, explicit_runtime = self.make_subject()
        explicit.generate_frame(tuple([0] * 128))
        np.testing.assert_array_equal(absent_runtime.graph.calls[5][0][0, 0, 12:-1], [6] * 128)
        np.testing.assert_array_equal(explicit_runtime.graph.calls[5][0][0, 0, 12:-1], [7] * 128)

    def test_text_mapper_rvq_and_identity_are_pinned(self):
        subject, runtime = self.make_subject(seed=123, prompt="MiXeD 音乐")
        self.assertEqual(FakeSentencePieceProcessor.encoded_inputs, ["mixed 音乐"])
        text = FakeInterpreter.instances["text_encoder.tflite"]
        self.assertEqual(text.tensors[4].shape, (1, 128))
        np.testing.assert_array_equal(text.tensors[4][0, :4], [1, 11, 12, 13])
        np.testing.assert_array_equal(text.tensors[8][0, :4], [0, 0, 0, 0])
        self.assertEqual(text.tensors[8][0, 4], 1)
        mapper = FakeInterpreter.instances["mapper.tflite"]
        expected_noise = np.random.RandomState(0).randn(768).astype(np.float32)
        np.testing.assert_array_equal(mapper.tensors[3][0], expected_noise)
        quantizer = FakeInterpreter.instances["pretrained_vector_quantizer.tflite"]
        self.assertAlmostEqual(float(np.linalg.norm(quantizer.tensors[5])), 1.0, places=6)

        identity = subject.identity()
        self.assertEqual(identity["model_revision"], export.MODEL_REVISION)
        self.assertEqual(identity["sdk_revision"], export.SDK_REVISION)
        self.assertEqual(identity["mapper_seed"], 0)
        self.assertEqual(identity["sampling_seed"], 123)
        self.assertEqual(identity["prompt"], "MiXeD 音乐")
        self.assertEqual(identity["prompt_sentencepiece_tokens"], 3)
        self.assertEqual(identity["state_leaf_count"], 165)
        self.assertEqual(identity["graph_internal_precision"], "unknown")
        self.assertEqual(identity["graph_path"], runtime.graph_path)

    def test_long_prompt_is_rejected_without_truncation_or_graph_load(self):
        runtime = FakeRuntime()
        with self.modules(runtime):
            with self.assertRaisesRegex(ValueError, "127-token"):
                export.ExportedMRT2(self.root, "TOO LONG", 1)
        self.assertFalse(hasattr(runtime, "graph_path"))
        self.assertEqual(FakeSentencePieceProcessor.encoded_inputs, ["too long"])

    def test_bad_state_count_default_key_and_seed_are_rejected(self):
        for runtime, message in [
            (FakeRuntime(state_count=164), "165 contiguous"),
            (FakeRuntime(default_key=(0, 43)), "default"),
            (FakeRuntime(key_dtype=np.int64), "uint32"),
        ]:
            with self.subTest(message=message), self.modules(runtime):
                with self.assertRaisesRegex(export.MRT2ExportError, message):
                    export.ExportedMRT2(self.root, "ok", 1)
        for seed in (-1, 2**32, True, 1.5):
            with self.subTest(seed=seed):
                with self.assertRaises(ValueError):
                    export.ExportedMRT2(self.root, "ok", seed)

    def test_note_frame_and_graph_audio_dtype_validation(self):
        subject, runtime = self.make_subject()
        invalid = [(0,) * 127, [0] * 128, (0,) * 127 + (4,), (0,) * 127 + (True,)]
        for note_frame in invalid:
            with self.subTest(note_frame_type=type(note_frame).__name__):
                with self.assertRaises(ValueError):
                    subject.generate_frame(note_frame)
        runtime.graph.audio = np.full((1, 2, 1920), np.nan, dtype=np.float32)
        with self.assertRaisesRegex(export.MRT2ExportError, "dtype int16"):
            subject.generate_frame(None)
        self.assertEqual(len(runtime.graph.calls), 6)

    def test_prompt_request_boundaries_match_audio_request(self):
        for prompt in ("", " \n\t", "nul\0inside", "界" * 1366):
            with self.subTest(prompt_length=len(prompt)):
                with self.assertRaises(ValueError):
                    export.ExportedMRT2(self.root, prompt, 1)

    def test_close_is_synchronous_idempotent_and_reports_cache_failure(self):
        subject, runtime = self.make_subject()
        self.assertEqual(subject.close(), {"released": True})
        self.assertEqual(subject.close(), {"released": True})
        self.assertEqual(runtime.sync_calls, 1)
        self.assertEqual(runtime.clear_calls, 1)
        self.assertTrue(subject.identity()["released"])
        with self.assertRaisesRegex(export.MRT2ExportError, "closed"):
            subject.generate_frame(None)

        failing_runtime = FakeRuntime()
        failing_runtime.clear_error = RuntimeError("cache busy")
        failing, _ = self.make_subject(runtime=failing_runtime)
        result = failing.close()
        self.assertFalse(result["released"])
        self.assertIn("cache busy", result["error"])
        self.assertFalse(failing.identity()["released"])

    def test_missing_asset_and_symlink_escape_do_not_fallback(self):
        (self.root / export.GRAPH_RELATIVE_PATH).unlink()
        with self.assertRaisesRegex(export.MRT2ExportError, "graph"):
            export.ExportedMRT2(self.root, "ok", 1)


if __name__ == "__main__":
    unittest.main()
