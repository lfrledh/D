"""CPU contract tests for the R8 Wan 2.2 attention diagnostic matrix."""

from __future__ import annotations

import contextlib
import math
import os
import unittest
from unittest import mock

try:
    import torch
except Exception:  # pragma: no cover - the Lead runtime supplies PyTorch.
    torch = None

from Backends.Video.Tests.wan22_attention_diagnostics import _cpu_fp64, run_attention_matrix


@unittest.skipUnless(torch is not None, "PyTorch is required for behavioral tests")
class AttentionDiagnosticsTests(unittest.TestCase):
    def make_inputs(self, *, length: int = 70, heads: int = 2, dimension: int = 4):
        count = length * heads * dimension
        q = torch.linspace(-1.25, 1.5, count, dtype=torch.float32).reshape(
            1, length, heads, dimension
        )
        k = torch.linspace(1.75, -1.0, count, dtype=torch.float32).reshape(
            1, length, heads, dimension
        )
        v = torch.linspace(-0.75, 0.875, count, dtype=torch.float32).reshape(
            1, length, heads, dimension
        ).to(torch.bfloat16)
        return q, k, v

    def test_outputs_use_full_q64_and_q31_windows_including_true_tail(self):
        q, k, v = self.make_inputs()
        positions = [0, 30, 31, 62, 63, 64, 69]
        original_q = q.clone()
        original_k = k.clone()
        original_v = v.clone()
        calls = []
        original_sdpa = torch.nn.functional.scaled_dot_product_attention

        def recording_sdpa(query, keys, values, **kwargs):
            calls.append((int(query.shape[-2]), query.dtype, query.device.type))
            return original_sdpa(query, keys, values, **kwargs)

        with mock.patch.object(
            torch.nn.functional,
            "scaled_dot_product_attention",
            side_effect=recording_sdpa,
        ):
            result = run_attention_matrix(q, k, v, positions=positions, device="cpu")

        self.assertEqual(
            calls,
            [
                (64, torch.bfloat16, "cpu"),
                (6, torch.bfloat16, "cpu"),
                (31, torch.bfloat16, "cpu"),
                (31, torch.bfloat16, "cpu"),
                (2, torch.bfloat16, "cpu"),
                (6, torch.bfloat16, "cpu"),
                (64, torch.float32, "cpu"),
                (6, torch.float32, "cpu"),
                (len(positions), torch.float64, "cpu"),
            ],
        )
        self.assertTrue(torch.equal(q, original_q))
        self.assertTrue(torch.equal(k, original_k))
        self.assertTrue(torch.equal(v, original_v))

        expected_shape = (1, len(positions), 2, 4)
        expected_dtypes = {
            "A_bf16_q64": torch.bfloat16,
            "B_bf16_q31": torch.bfloat16,
            "C_formula_fp32": torch.float32,
            "C_bf16": torch.bfloat16,
            "D_sdpa_fp32": torch.float32,
            "D_bf16": torch.bfloat16,
            "F_cpu_fp64": torch.float64,
        }
        self.assertEqual(set(result["outputs"]), set(expected_dtypes))
        storage_addresses = []
        for name, expected_dtype in expected_dtypes.items():
            output = result["outputs"][name]
            self.assertEqual(tuple(output.shape), expected_shape)
            self.assertEqual(output.dtype, expected_dtype)
            self.assertEqual(output.device.type, "cpu")
            self.assertTrue(output.is_contiguous())
            storage_addresses.append(output.untyped_storage().data_ptr())
        self.assertEqual(len(storage_addresses), len(set(storage_addresses)))
        self.assertTrue(all(isinstance(value, (int, float, str)) for value in result["metadata"].values()))
        self.assertEqual(result["metadata"]["q64_window_count"], 2)
        self.assertEqual(result["metadata"]["q31_window_count"], 4)
        self.assertEqual(result["metadata"]["C_formula_fp32_calls"], 1)
        self.assertEqual(result["metadata"]["C_formula_fp32_query_rows"], len(positions))

    def test_constant_values_and_hand_calculated_softmax(self):
        q = torch.tensor([[[[1.0, 0.0]], [[0.0, 1.0]]]], dtype=torch.float32)
        k = torch.tensor([[[[1.0, 0.0]], [[0.0, 1.0]]]], dtype=torch.float32)
        v = torch.tensor([[[[2.0, 0.0]], [[0.0, 4.0]]]], dtype=torch.bfloat16)

        result = run_attention_matrix(q, k, v, positions=[0], device="cpu")
        weight = math.exp(1.0 / math.sqrt(2.0)) / (math.exp(1.0 / math.sqrt(2.0)) + 1.0)
        expected = torch.tensor([2.0 * weight, 4.0 * (1.0 - weight)], dtype=torch.float64)
        actual = result["outputs"]["F_cpu_fp64"][0, 0, 0]
        torch.testing.assert_close(actual, expected, rtol=1e-12, atol=1e-12)

        constant_v = torch.full((1, 5, 1, 3), 1.5, dtype=torch.bfloat16)
        q2 = torch.arange(15, dtype=torch.float32).reshape(1, 5, 1, 3) / 7.0
        k2 = torch.flip(q2, dims=[1]).contiguous()
        constant_result = run_attention_matrix(q2, k2, constant_v, positions=[0, 4], device="cpu")
        expected_constant = torch.full((1, 2, 1, 3), 1.5, dtype=torch.float64)
        for name in ("A_bf16_q64", "B_bf16_q31", "C_bf16", "D_bf16"):
            torch.testing.assert_close(
                constant_result["outputs"][name].to(torch.float64),
                expected_constant,
                rtol=0.0,
                atol=0.0,
            )
        fp32_tolerance = 2.0 * torch.finfo(torch.float32).eps
        for name in ("C_formula_fp32", "D_sdpa_fp32"):
            torch.testing.assert_close(
                constant_result["outputs"][name].to(torch.float64),
                expected_constant,
                rtol=0.0,
                atol=fp32_tolerance,
            )
        torch.testing.assert_close(
            constant_result["outputs"]["F_cpu_fp64"],
            expected_constant,
            rtol=0.0,
            atol=2.0 * torch.finfo(torch.float64).eps,
        )

    def test_formula_uses_bf16_quantized_values_and_full_keys(self):
        q, k, v = self.make_inputs(length=9, heads=1, dimension=3)
        positions = [0, 4, 8]
        result = run_attention_matrix(q, k, v, positions=positions, device="cpu")

        quantized_q = q.to(torch.bfloat16).to(torch.float32)
        quantized_k = k.to(torch.bfloat16).to(torch.float32)
        quantized_v = v.to(torch.float32)
        selected = quantized_q[:, positions].permute(0, 2, 1, 3)
        scores = torch.matmul(
            selected,
            quantized_k.permute(0, 2, 1, 3).transpose(-2, -1),
        ) / math.sqrt(3.0)
        probabilities = torch.softmax(scores, dim=-1)
        expected = torch.matmul(
            probabilities, quantized_v.permute(0, 2, 1, 3)
        ).permute(0, 2, 1, 3)
        torch.testing.assert_close(
            result["outputs"]["C_formula_fp32"], expected, rtol=1e-6, atol=1e-6
        )
        torch.testing.assert_close(
            result["outputs"]["C_bf16"], expected.to(torch.bfloat16), rtol=0.0, atol=0.0
        )

    def test_formula_processes_all_thirteen_selected_rows_in_one_pair_of_matmuls(self):
        q, k, v = self.make_inputs(length=139, heads=2, dimension=128)
        positions = list(range(13))
        matmul_shapes = []
        original_matmul = torch.matmul

        def recording_matmul(left, right, *args, **kwargs):
            matmul_shapes.append((tuple(left.shape), tuple(right.shape)))
            return original_matmul(left, right, *args, **kwargs)

        with mock.patch.object(torch, "matmul", side_effect=recording_matmul):
            result = run_attention_matrix(q, k, v, positions=positions, device="cpu")

        self.assertEqual(
            matmul_shapes,
            [
                ((1, 2, 13, 128), (1, 2, 128, 139)),
                ((1, 2, 13, 139), (1, 2, 139, 128)),
            ],
        )
        self.assertEqual(tuple(result["outputs"]["C_formula_fp32"].shape), (1, 13, 2, 128))

    def test_positions_validation_rejects_empty_order_duplicates_bool_and_bounds(self):
        q, k, v = self.make_inputs(length=5, heads=1, dimension=2)
        invalid_positions = (
            [],
            [1, 0],
            [1, 1],
            [False],
            [-1],
            [5],
            [1.0],
            torch.tensor([1]),
        )
        for positions in invalid_positions:
            with self.subTest(positions=positions):
                with self.assertRaises(ValueError):
                    run_attention_matrix(q, k, v, positions=positions, device="cpu")

    def test_shape_dtype_device_and_finite_validation(self):
        q, k, v = self.make_inputs(length=5, heads=1, dimension=2)
        cases = [
            (q.to(torch.float64), k, v),
            (q, k.to(torch.bfloat16), v),
            (q, k, v.to(torch.float32)),
            (q[:, :-1], k, v),
            (q.squeeze(0), k.squeeze(0), v.squeeze(0)),
        ]
        for tensors in cases:
            with self.subTest(shapes=[tuple(value.shape) for value in tensors]):
                with self.assertRaises(ValueError):
                    run_attention_matrix(*tensors, positions=[0], device="cpu")

        for index in range(3):
            tensors = [q.clone(), k.clone(), v.clone()]
            tensors[index][0, 0, 0, 0] = float("nan")
            with self.subTest(nonfinite=index):
                with self.assertRaises(ValueError):
                    run_attention_matrix(*tensors, positions=[0], device="cpu")

        overflow_q = torch.tensor([[[[-1.0]], [[-1.0]]]], dtype=torch.float32)
        overflow_k = torch.tensor(
            [[[[torch.finfo(torch.float32).max]], [[0.0]]]], dtype=torch.float32
        )
        overflow_v = torch.tensor([[[[1.0]], [[2.0]]]], dtype=torch.bfloat16)
        with self.assertRaisesRegex(ValueError, "after BF16 quantization"):
            run_attention_matrix(
                overflow_q, overflow_k, overflow_v, positions=[0], device="cpu"
            )

        with self.assertRaises(ValueError):
            run_attention_matrix(q, k, v, positions=[0], device="cuda")

    def test_fp64_promotion_transfers_to_cpu_before_dtype_change(self):
        calls = []
        float64_token = object()

        class CPUValue:
            def to(self, **kwargs):
                calls.append(("cpu", kwargs))
                return "fp64-result"

        class SourceValue:
            def to(self, **kwargs):
                calls.append(("source", kwargs))
                return CPUValue()

        fake_torch = type("FakeTorch", (), {"float64": float64_token})()
        result = _cpu_fp64(fake_torch, SourceValue())
        self.assertEqual(result, "fp64-result")
        self.assertEqual(
            calls,
            [
                ("source", {"device": "cpu"}),
                ("cpu", {"dtype": float64_token}),
            ],
        )

    def test_enabled_mps_fallback_is_rejected_before_device_work(self):
        q, k, v = self.make_inputs(length=2, heads=1, dimension=2)
        with mock.patch.dict(os.environ, {"PYTORCH_ENABLE_MPS_FALLBACK": "1"}):
            with self.assertRaisesRegex(RuntimeError, "FALLBACK"):
                run_attention_matrix(q, k, v, positions=[0], device="mps")

    def test_runtime_error_propagates_and_local_math_context_exits(self):
        q, k, v = self.make_inputs(length=2, heads=1, dimension=2)
        context_state = {"entered": 0, "exited": 0}

        @contextlib.contextmanager
        def tracking_context(*, backends):
            self.assertEqual(backends, [torch.nn.attention.SDPBackend.MATH])
            context_state["entered"] += 1
            try:
                yield
            finally:
                context_state["exited"] += 1

        with mock.patch.object(torch.nn.attention, "sdpa_kernel", side_effect=tracking_context):
            with mock.patch.object(
                torch.nn.functional,
                "scaled_dot_product_attention",
                side_effect=RuntimeError("diagnostic failure"),
            ):
                with self.assertRaisesRegex(RuntimeError, "diagnostic failure"):
                    run_attention_matrix(q, k, v, positions=[0], device="cpu")

        self.assertEqual(context_state, {"entered": 1, "exited": 1})


if __name__ == "__main__":
    unittest.main()
