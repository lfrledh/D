from __future__ import annotations

from collections import OrderedDict
import gc
import json
import math
import os
from pathlib import Path
import sys
import tempfile
from types import ModuleType, SimpleNamespace
import unittest
from unittest import mock
import warnings

import numpy as np


PYTHON_DIR = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = Path(__file__).resolve().parents[4]
if str(PYTHON_DIR) not in sys.path:
    sys.path.insert(0, str(PYTHON_DIR))

import d_singing_qixuan as qixuan


class QixuanNumericTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_root = Path(os.environ["D_TEST_TEMP_DIR"])
        self.source_filter = np.zeros((128, 1025), dtype=np.float64)
        self.source_filter[:, :128] = np.eye(128, dtype=np.float64)
        self.target_filter = self.source_filter.copy()

    def _exact_solver(self, matrix, target, *, m, maxiter):
        self.assertIs(matrix, self.source_filter)
        self.assertEqual(m, 10)
        self.assertEqual(maxiter, 200)
        result = np.zeros((1025, target.shape[1]), dtype=np.float64)
        result[:128] = target
        return result

    def test_projection_uses_amplitude_epsilon_and_bounded_blocks(self) -> None:
        log_mel = np.full((128, 33), math.log(2.0), dtype=np.float32)
        checkpoints = 0

        def checkpoint() -> None:
            nonlocal checkpoints
            checkpoints += 1

        mapped, residual = qixuan.project_log_mel(
            log_mel,
            checkpoint=checkpoint,
            source_filter=self.source_filter,
            target_filter=self.target_filter,
            solver=self._exact_solver,
        )
        expected = math.log(math.sqrt(4.0 + 1e-9))
        self.assertEqual(mapped.shape, (128, 33))
        self.assertEqual(mapped.dtype, np.float32)
        np.testing.assert_allclose(mapped, expected, rtol=0, atol=2e-7)
        self.assertEqual(residual, 0.0)
        self.assertEqual(checkpoints, 4)  # before and after each 32-frame NNLS block

    def test_projection_residual_is_global_and_rejects_above_budget(self) -> None:
        def zero_solver(_matrix, target, *, m, maxiter):
            return np.zeros((1025, target.shape[1]), dtype=np.float64)

        with self.assertRaisesRegex(qixuan.QixuanRuntimeError, "relative residual"):
            qixuan.project_log_mel(
                np.zeros((128, 2), dtype=np.float32),
                checkpoint=lambda: None,
                source_filter=self.source_filter,
                target_filter=self.target_filter,
                solver=zero_solver,
            )

    def test_projection_rejects_warning_bad_shape_negative_and_nonfinite(self) -> None:
        def warning_solver(_matrix, target, *, m, maxiter):
            warnings.warn("fixture convergence warning", RuntimeWarning)
            return np.zeros((1025, target.shape[1]), dtype=np.float64)

        with self.assertRaisesRegex(qixuan.QixuanRuntimeError, "NNLS emitted a warning"):
            qixuan.project_log_mel(
                np.zeros((128, 1), dtype=np.float32), checkpoint=lambda: None,
                source_filter=self.source_filter, target_filter=self.target_filter,
                solver=warning_solver,
            )
        invalid_values = [
            np.zeros((127, 1), dtype=np.float32),
            np.zeros((128, 0), dtype=np.float32),
            np.full((128, 1), np.nan, dtype=np.float32),
        ]
        for value in invalid_values:
            with self.subTest(shape=value.shape):
                with self.assertRaises(qixuan.QixuanRuntimeError):
                    qixuan.project_log_mel(
                        value, checkpoint=lambda: None,
                        source_filter=self.source_filter, target_filter=self.target_filter,
                        solver=self._exact_solver,
                    )

    def test_projection_zeros_unsupported_frequency_bins_before_residual(self) -> None:
        observed = None

        def solver(_matrix, target, *, m, maxiter):
            nonlocal observed
            observed = np.ones((1025, target.shape[1]), dtype=np.float64) * 9.0
            observed[:128] = target
            return observed

        mapped, residual = qixuan.project_log_mel(
            np.zeros((128, 1), dtype=np.float32), checkpoint=lambda: None,
            source_filter=self.source_filter, target_filter=self.target_filter, solver=solver,
        )
        self.assertEqual(residual, 0.0)
        self.assertTrue(np.all(observed[128:] == 0.0))
        self.assertTrue(np.isfinite(mapped).all())

    def test_projection_mixed_band_small_amplitude_places_epsilon_before_filter(self) -> None:
        target_filter = self.target_filter.copy()
        target_filter[0] = 0.0
        target_filter[0, 0] = 0.25
        target_filter[0, 1] = 0.75
        values = np.full((128, 1), 1e-8, dtype=np.float64)
        values[0, 0] = 2e-8
        values[1, 0] = 4e-8
        mapped, residual = qixuan.project_log_mel(
            np.log(values).astype(np.float32), checkpoint=lambda: None,
            source_filter=self.source_filter, target_filter=target_filter,
            solver=self._exact_solver,
        )
        expected_amplitude = (
            0.25 * math.sqrt((2e-8) ** 2 + 1e-9)
            + 0.75 * math.sqrt((4e-8) ** 2 + 1e-9)
        )
        self.assertAlmostEqual(float(mapped[0, 0]), math.log(expected_amplitude), places=5)
        self.assertLess(residual, 1e-6)

    def test_projection_33_frame_unequal_blocks_uses_global_squares(self) -> None:
        block_sizes = []

        def solver(_matrix, target, *, m, maxiter):
            block_sizes.append(target.shape[1])
            result = np.zeros((1025, target.shape[1]), dtype=np.float64)
            result[:128] = target if target.shape[1] == 32 else target * 0.5
            return result

        _mapped, residual = qixuan.project_log_mel(
            np.zeros((128, 33), dtype=np.float32), checkpoint=lambda: None,
            source_filter=self.source_filter, target_filter=self.target_filter, solver=solver,
        )
        self.assertEqual(block_sizes, [32, 1])
        self.assertAlmostEqual(residual, math.sqrt(0.25 / 33.0), places=12)

    def test_projection_checkpoint_cancellation_is_not_wrapped(self) -> None:
        calls = 0

        def checkpoint():
            nonlocal calls
            calls += 1
            if calls == 2:
                raise qixuan.RenderCancelled("NNLS fixture cancellation")

        with self.assertRaises(qixuan.RenderCancelled):
            qixuan.project_log_mel(
                np.zeros((128, 33), dtype=np.float32), checkpoint=checkpoint,
                source_filter=self.source_filter, target_filter=self.target_filter,
                solver=self._exact_solver,
            )

    def test_fake_onnx_session_enforces_interface_and_releases_session(self) -> None:
        class Metadata:
            def __init__(self, name, dtype, shape):
                self.name, self.type, self.shape = name, dtype, shape

        class Options:
            pass

        class Session:
            alive = 0

            def __init__(self, path, sess_options, providers):
                type(self).alive += 1
                self.providers = providers

            def __del__(self):
                type(self).alive -= 1

            def disable_fallback(self):
                pass

            def get_providers(self):
                return self.providers

            def get_inputs(self):
                return [Metadata("input", "tensor(float)", [1, 2])]

            def get_outputs(self):
                return [Metadata("output", "tensor(float)", [1, 2])]

            def run(self, names, feeds):
                return [feeds["input"].copy()]

        ort = SimpleNamespace(
            __version__="1.22.1", SessionOptions=Options, InferenceSession=Session,
            GraphOptimizationLevel=SimpleNamespace(ORT_DISABLE_ALL=0),
            ExecutionMode=SimpleNamespace(ORT_SEQUENTIAL=0),
        )
        engine = qixuan.QixuanEngine(Path("/bank"), Path("/vocoder"), Path("/vendor"))
        with mock.patch.dict(sys.modules, {"onnxruntime": ort}):
            result = engine._run_onnx(
                "fixture.onnx", {"input": np.ones((1, 2), dtype=np.float32)},
                {"output": ((1, 2), "float32")},
            )
            np.testing.assert_array_equal(result["output"], [[1, 1]])
            self.assertEqual(Session.alive, 0)
            with self.assertRaisesRegex(qixuan.QixuanRuntimeError, "input names"):
                engine._run_onnx(
                    "fixture.onnx", {"wrong": np.ones((1, 2), dtype=np.float32)},
                    {"output": ((1, 2), "float32")},
                )
            self.assertEqual(Session.alive, 0)
            with self.assertRaisesRegex(qixuan.QixuanRuntimeError, "dtype metadata"):
                engine._run_onnx(
                    "fixture.onnx", {"input": np.ones((1, 2), dtype=np.int64)},
                    {"output": ((1, 2), "float32")},
                )
            with self.assertRaisesRegex(qixuan.QixuanRuntimeError, "shape metadata"):
                engine._run_onnx(
                    "fixture.onnx", {"input": np.ones((1, 3), dtype=np.float32)},
                    {"output": ((1, 2), "float32")},
                )
            self.assertEqual(Session.alive, 0)

    def test_vocoder_accepts_ordered_state_and_forces_cpu_float32(self) -> None:
        records = {
            "constructed": 0, "strict": False, "called": 0, "deleted": 0,
            "device_depth": 0,
        }

        class Device:
            type = "cpu"

            def __enter__(self):
                records["device_depth"] += 1
                return self

            def __exit__(self, *_args):
                records["device_depth"] -= 1
                return False

        float32 = object()

        class Tensor:
            def __init__(self, array=None):
                self.array = array
                self.device = Device()
                self.dtype = float32

            def to(self, *, device, dtype):
                self.device, self.dtype = device, dtype
                return self

            def __getitem__(self, item):
                return Tensor(self.array[item])

            def cpu(self):
                return self

            def numpy(self):
                return self.array

        state_tensor = Tensor()

        class Inference:
            def __enter__(self): return self
            def __exit__(self, *_args): return False

        class Torch:
            default = object()

            @staticmethod
            def inference_mode(): return Inference()
            @staticmethod
            def get_default_dtype(): return Torch.default
            @staticmethod
            def set_default_dtype(value): Torch.default = value
            @staticmethod
            def device(_name): return Device()
            @staticmethod
            def load(_path, *, map_location, weights_only):
                self.assertEqual(map_location.type, "cpu")
                self.assertTrue(weights_only)
                return {"generator": OrderedDict([("weight", state_tensor)])}
            @staticmethod
            def is_tensor(value): return isinstance(value, Tensor)
            @staticmethod
            def from_numpy(value): return Tensor(value)

        Torch.float32 = float32

        test_case = self

        class Model:
            def __init__(self, config, *, use_cuda_kernel):
                records["constructed"] += 1
                test_case.assertFalse(use_cuda_kernel)
                test_case.assertEqual(records["device_depth"], 1)
                test_case.assertIs(Torch.default, float32)
                self.tensor = Tensor()

            def __del__(self): records["deleted"] += 1
            def to(self, *, device, dtype):
                test_case.assertEqual(device.type, "cpu")
                test_case.assertIs(dtype, float32)
                return self
            def load_state_dict(self, state, *, strict):
                test_case.assertIs(type(state), OrderedDict)
                records["strict"] = strict
            def remove_weight_norm(self): pass
            def eval(self): return self
            def requires_grad_(self, value):
                test_case.assertFalse(value); return self
            def parameters(self): return (self.tensor,)
            def buffers(self): return ()
            def __call__(self, tensor):
                records["called"] += 1
                return Tensor(np.full((1, 1, 512), 0.25, dtype=np.float32))

        with tempfile.TemporaryDirectory(dir=self.temp_root) as raw:
            root = Path(raw)
            (root / "vocoder").mkdir()
            (root / "vocoder" / "config.json").write_text(json.dumps({
                "sampling_rate": 44100, "n_fft": 2048, "hop_size": 512, "num_mels": 128,
            }), encoding="utf-8")
            engine = qixuan.QixuanEngine(root / "bank", root / "vocoder", root / "vendor")
            conditions = SimpleNamespace(
                alignment=SimpleNamespace(frame_count=1),
                mel=np.zeros((1, 1, 128), dtype=np.float32),
            )
            with mock.patch.object(
                qixuan, "project_log_mel", return_value=(np.zeros((128, 1), dtype=np.float32), 0.0)
            ), mock.patch.object(qixuan, "_import_bigvgan", return_value=(Torch, dict, Model)):
                output = engine.vocoder(conditions, lambda: None)
                for stop_at in (4, 5):
                    calls = 0
                    called_before = records["called"]

                    def checkpoint():
                        nonlocal calls
                        calls += 1
                        if calls == stop_at:
                            raise qixuan.RenderCancelled(f"fixture checkpoint {stop_at}")

                    def invoke_cancelled():
                        with self.assertRaises(qixuan.RenderCancelled):
                            engine.vocoder(conditions, checkpoint)

                    invoke_cancelled()
                    gc.collect()
                    self.assertEqual(records["constructed"], records["deleted"])
                    if stop_at == 4:
                        self.assertEqual(records["called"], called_before)
            self.assertEqual(output.native_frame_count, 512)
            self.assertEqual(records["constructed"], 3)
            self.assertTrue(records["strict"])
            self.assertEqual(records["called"], 2)
            gc.collect()
            self.assertEqual(records["deleted"], 3)

            caller_dtype = Torch.default

            class FailingModel:
                def __init__(self, config, *, use_cuda_kernel):
                    test_case.assertEqual(records["device_depth"], 1)
                    test_case.assertIs(Torch.default, float32)
                    raise RuntimeError("fixture constructor failure")

            with mock.patch.object(
                qixuan, "project_log_mel", return_value=(np.zeros((128, 1), dtype=np.float32), 0.0)
            ), mock.patch.object(qixuan, "_import_bigvgan", return_value=(Torch, dict, FailingModel)):
                with self.assertRaisesRegex(qixuan.QixuanRuntimeError, "constructor failure"):
                    engine.vocoder(conditions, lambda: None)
            self.assertIs(Torch.default, caller_dtype)
            self.assertEqual(records["device_depth"], 0)

    def test_vocoder_checkpoint_cancellation_remains_dedicated_and_cleans_model(self) -> None:
        # The full fake-interface success test above owns state/load details.  Here
        # a tiny import seam proves cancellation before construction is untouched.
        with tempfile.TemporaryDirectory(dir=self.temp_root) as raw:
            root = Path(raw); (root / "vocoder").mkdir()
            (root / "vocoder" / "config.json").write_text(json.dumps({
                "sampling_rate": 44100, "n_fft": 2048, "hop_size": 512, "num_mels": 128,
            }), encoding="utf-8")
            conditions = SimpleNamespace(
                alignment=SimpleNamespace(frame_count=1),
                mel=np.zeros((1, 1, 128), dtype=np.float32),
            )
            calls = 0
            def checkpoint():
                nonlocal calls
                calls += 1
                if calls == 3:
                    raise qixuan.RenderCancelled("before construction")
            with mock.patch.object(
                qixuan, "project_log_mel", return_value=(np.zeros((128, 1), dtype=np.float32), 0.0)
            ), mock.patch.object(qixuan, "_import_bigvgan", return_value=(SimpleNamespace(), dict, object)):
                with self.assertRaises(qixuan.RenderCancelled):
                    qixuan.QixuanEngine(root / "bank", root / "vocoder", root / "vendor").vocoder(
                        conditions, checkpoint
                    )

    def test_vendor_preflight_rejects_initializer_external_namespace_and_preload_without_execution(self) -> None:
        with tempfile.TemporaryDirectory(dir=self.temp_root) as raw:
            root = Path(raw) / "bigvgan"; root.mkdir()
            for name in ("bigvgan.py", "activations.py", "env.py", "utils.py", "meldataset.py"):
                (root / name).write_text("", encoding="utf-8")
            torch_root = root / "alias_free_activation" / "torch"; torch_root.mkdir(parents=True)
            for name in ("__init__.py", "act.py", "filter.py", "resample.py"):
                (torch_root / name).write_text("", encoding="utf-8")
            qixuan._preflight_vendor_imports(root)

            unlisted = root / "unlisted.py"
            unlisted.write_text("raise AssertionError('must never execute')\n", encoding="utf-8")
            root_local_wrong = SimpleNamespace(__file__=str(unlisted))
            with mock.patch.dict(sys.modules, {"bigvgan": root_local_wrong}):
                with self.assertRaisesRegex(qixuan.QixuanRuntimeError, "exact bound source"):
                    qixuan._preflight_vendor_imports(root)

            wrong_namespace = root / "wrong-namespace"
            wrong_namespace.mkdir()
            cached_namespace = SimpleNamespace(__file__=None, __path__=[str(wrong_namespace)])
            with mock.patch.dict(sys.modules, {"alias_free_activation": cached_namespace}):
                with self.assertRaisesRegex(qixuan.QixuanRuntimeError, "search locations"):
                    qixuan._preflight_vendor_imports(root)

            exact_module = SimpleNamespace(__file__=str(root / "bigvgan.py"))
            exact_namespace = SimpleNamespace(
                __file__=None,
                __path__=[str(root / "alias_free_activation"), str(root / "alias_free_activation")],
            )
            with mock.patch.dict(sys.modules, {
                "bigvgan": exact_module, "alias_free_activation": exact_namespace,
            }), mock.patch.object(sys, "path", [str(root), str(root), *sys.path]):
                qixuan._preflight_vendor_imports(root)

            sentinel = Path(raw) / "executed"
            initializer = root / "alias_free_activation" / "__init__.py"
            initializer.write_text(f"open({str(sentinel)!r},'w').write('bad')\n", encoding="utf-8")
            with self.assertRaises(qixuan.QixuanRuntimeError):
                qixuan._preflight_vendor_imports(root)
            self.assertFalse(sentinel.exists())
            initializer.unlink()

            external = Path(raw) / "external"; (external / "alias_free_activation").mkdir(parents=True)
            (external / "alias_free_activation" / "__init__.py").write_text("", encoding="utf-8")
            with mock.patch.object(sys, "path", [str(external), *sys.path]):
                with self.assertRaises(qixuan.QixuanRuntimeError):
                    qixuan._preflight_vendor_imports(root)

            foreign = ModuleType("alias_free_activation.torch.act")
            foreign.__file__ = str(external / "act.py")
            with mock.patch.dict(sys.modules, {"alias_free_activation.torch.act": foreign}):
                with self.assertRaises(qixuan.QixuanRuntimeError):
                    qixuan._preflight_vendor_imports(root)

    def test_fixed_vendor_preflight_executes_no_vendor_module(self) -> None:
        before = {name for name in qixuan._VENDOR_MODULES if name in sys.modules}
        qixuan._preflight_vendor_imports(
            REPOSITORY_ROOT / "Backends" / "Audio" / "SingingVendor" / "bigvgan"
        )
        after = {name for name in qixuan._VENDOR_MODULES if name in sys.modules}
        self.assertEqual(after, before)

    def test_pitch_to_note_arrays_uses_nearest_previous_and_first_for_leading_rest(self) -> None:
        class Alignment:
            note_midi = (None, None, 60, None, 64, None)

        midi, rests, first = qixuan.QixuanEngine._note_arrays(Alignment())
        np.testing.assert_array_equal(midi, [[60, 60, 60, 60, 64, 64]])
        np.testing.assert_array_equal(rests, [[True, True, False, True, False, True]])
        self.assertEqual(first.shape, ())
        self.assertEqual(first.dtype, np.float32)


if __name__ == "__main__":
    unittest.main()
