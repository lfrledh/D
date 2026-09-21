"""CPU contract tests for the R9 Wan attention implementation."""

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

from Backends.Video.Python.d_video_wan_attention import AttentionCancelled, wan_attention


def _independent_fp64_reference(q, k, v):
    """Formula reference that deliberately does not call SDPA."""

    query = q.to(torch.bfloat16).to(torch.float64).permute(0, 2, 1, 3)
    keys = k.to(torch.bfloat16).to(torch.float64).permute(0, 2, 1, 3)
    values = v.to(torch.float64).permute(0, 2, 1, 3)
    scores = torch.matmul(query, keys.transpose(-2, -1)) / math.sqrt(q.shape[-1])
    probabilities = torch.softmax(scores, dim=-1)
    return torch.matmul(probabilities, values).permute(0, 2, 1, 3).to(torch.bfloat16)


@unittest.skipUnless(torch is not None, "PyTorch is required for behavioral tests")
class WanAttentionTests(unittest.TestCase):
    def make_inputs(
        self,
        *,
        query_length=7,
        key_length=5,
        batch=2,
        heads=3,
        dimension=4,
        q_dtype=None,
        k_dtype=None,
    ):
        q_dtype = q_dtype or torch.float32
        k_dtype = k_dtype or torch.float32
        q_count = batch * query_length * heads * dimension
        k_count = batch * key_length * heads * dimension
        q = torch.linspace(-1.75, 1.625, q_count, dtype=torch.float32).reshape(
            batch, query_length, heads, dimension
        ).to(q_dtype)
        k = torch.linspace(1.375, -1.5, k_count, dtype=torch.float32).reshape(
            batch, key_length, heads, dimension
        ).to(k_dtype)
        v = torch.linspace(-0.875, 1.125, k_count, dtype=torch.float32).reshape(
            batch, key_length, heads, dimension
        ).to(torch.bfloat16)
        return q, k, v

    def assert_matches_reference(self, q, k, v, *, chunk_size):
        originals = tuple(tensor.clone() for tensor in (q, k, v))
        result = wan_attention(q, k, v, query_chunk_size=chunk_size, device="cpu")
        expected = _independent_fp64_reference(q, k, v)

        self.assertEqual(tuple(result.shape), tuple(q.shape))
        self.assertEqual(result.dtype, torch.bfloat16)
        self.assertEqual(result.device.type, "cpu")
        self.assertTrue(torch.isfinite(result).all().item())
        self.assertFalse(result.requires_grad)
        torch.testing.assert_close(
            result.to(torch.float32), expected.to(torch.float32), rtol=0.02, atol=0.02
        )
        for actual, original in zip((q, k, v), originals):
            self.assertTrue(torch.equal(actual, original))
        input_storage = {tensor.untyped_storage().data_ptr() for tensor in (q, k, v)}
        self.assertNotIn(result.untyped_storage().data_ptr(), input_storage)

    def test_cross_and_self_attention_match_independent_fp64_formula(self):
        cases = (
            ("cross_fp32", self.make_inputs(), 3),
            (
                "cross_mixed_qk",
                self.make_inputs(q_dtype=torch.bfloat16, k_dtype=torch.float32),
                64,
            ),
            (
                "self_bf16",
                self.make_inputs(
                    query_length=6,
                    key_length=6,
                    batch=1,
                    heads=2,
                    dimension=5,
                    q_dtype=torch.bfloat16,
                    k_dtype=torch.bfloat16,
                ),
                4,
            ),
        )
        for name, inputs, chunk_size in cases:
            with self.subTest(name=name):
                self.assert_matches_reference(*inputs, chunk_size=chunk_size)

    def test_true_tail_checkpoint_events_are_read_only_scalars(self):
        q, k, v = self.make_inputs(query_length=7, key_length=4, batch=1, heads=1)
        events = []

        def checkpoint(event):
            events.append(dict(event))
            self.assertTrue(all(isinstance(value, (str, int)) for value in event.values()))
            with self.assertRaises(TypeError):
                event["stage"] = "changed"

        result = wan_attention(
            q, k, v, query_chunk_size=3, device="cpu", checkpoint=checkpoint
        )

        expected = []
        for start, end in ((0, 3), (3, 6), (6, 7)):
            expected.extend(
                [
                    {"stage": "before_chunk", "start": start, "end": end, "total": 7},
                    {"stage": "after_chunk", "start": start, "end": end, "total": 7},
                ]
            )
        self.assertEqual(events, expected)
        self.assertEqual(tuple(result.shape), (1, 7, 1, 4))

    def test_sdpa_receives_quantized_fp32_values_and_fixed_semantics(self):
        q, k, v = self.make_inputs(
            query_length=5, key_length=3, batch=1, heads=2, dimension=3
        )
        self.assertFalse(torch.equal(q, q.to(torch.bfloat16).to(torch.float32)))
        self.assertFalse(torch.equal(k, k.to(torch.bfloat16).to(torch.float32)))
        q.requires_grad_()
        calls = []
        original_sdpa = torch.nn.functional.scaled_dot_product_attention

        def recording_sdpa(query, keys, values, **kwargs):
            calls.append(
                {
                    "query": query.detach().clone(),
                    "keys": keys.detach().clone(),
                    "values": values.detach().clone(),
                    "kwargs": dict(kwargs),
                    "grad": torch.is_grad_enabled(),
                    "inference": torch.is_inference_mode_enabled(),
                }
            )
            return original_sdpa(query, keys, values, **kwargs)

        with mock.patch.object(
            torch.nn.functional,
            "scaled_dot_product_attention",
            side_effect=recording_sdpa,
        ):
            result = wan_attention(q, k, v, query_chunk_size=64, device="cpu")

        self.assertEqual(len(calls), 1)
        call = calls[0]
        self.assertFalse(call["grad"])
        self.assertTrue(call["inference"])
        self.assertEqual(
            call["kwargs"],
            {"attn_mask": None, "dropout_p": 0.0, "is_causal": False, "scale": None},
        )
        expected_q = q.detach().to(torch.bfloat16).to(torch.float32).permute(0, 2, 1, 3)
        expected_k = k.to(torch.bfloat16).to(torch.float32).permute(0, 2, 1, 3)
        expected_v = v.to(torch.float32).permute(0, 2, 1, 3)
        self.assertTrue(torch.equal(call["query"], expected_q))
        self.assertTrue(torch.equal(call["keys"], expected_k))
        self.assertTrue(torch.equal(call["values"], expected_v))
        self.assertEqual(result.dtype, torch.bfloat16)

    def test_inference_and_math_backend_contexts_restore_after_success(self):
        q, k, v = self.make_inputs(batch=1, heads=1)
        original_context = torch.nn.attention.sdpa_kernel
        context_events = []

        @contextlib.contextmanager
        def tracking_context(*, backends):
            context_events.append(("enter", tuple(backends)))
            with original_context(backends=backends):
                yield
            context_events.append(("exit", tuple(backends)))

        grad_before = torch.is_grad_enabled()
        flags_before = self._global_sdp_flags()
        with mock.patch.object(torch.nn.attention, "sdpa_kernel", new=tracking_context):
            wan_attention(q, k, v, query_chunk_size=2, device="cpu")

        expected_backends = (torch.nn.attention.SDPBackend.MATH,)
        self.assertEqual(context_events, [("enter", expected_backends), ("exit", expected_backends)])
        self.assertEqual(torch.is_grad_enabled(), grad_before)
        self.assertEqual(self._global_sdp_flags(), flags_before)

    def test_cancellation_releases_context_and_retry_succeeds(self):
        self.assertTrue(issubclass(AttentionCancelled, RuntimeError))
        q, k, v = self.make_inputs(query_length=6, key_length=4, batch=1, heads=1)
        seen = []

        def cancel_after_first_chunk(event):
            seen.append((event["stage"], event["start"], event["end"]))
            if event["stage"] == "after_chunk" and event["start"] == 0:
                raise AttentionCancelled("bounded test cancellation")

        grad_before = torch.is_grad_enabled()
        flags_before = self._global_sdp_flags()
        with self.assertRaisesRegex(AttentionCancelled, "bounded test cancellation"):
            wan_attention(
                q,
                k,
                v,
                query_chunk_size=2,
                device="cpu",
                checkpoint=cancel_after_first_chunk,
            )
        self.assertEqual(seen, [("before_chunk", 0, 2), ("after_chunk", 0, 2)])
        self.assertEqual(torch.is_grad_enabled(), grad_before)
        self.assertEqual(self._global_sdp_flags(), flags_before)

        retry = wan_attention(q, k, v, query_chunk_size=2, device="cpu")
        torch.testing.assert_close(
            retry.to(torch.float32),
            _independent_fp64_reference(q, k, v).to(torch.float32),
            rtol=0.02,
            atol=0.02,
        )

    def test_unknown_callback_error_is_not_wrapped_or_swallowed(self):
        q, k, v = self.make_inputs(batch=1, heads=1)

        class CallbackFailure(Exception):
            pass

        expected = CallbackFailure("callback failed")

        def fail(_event):
            raise expected

        with self.assertRaises(CallbackFailure) as raised:
            wan_attention(q, k, v, device="cpu", checkpoint=fail)
        self.assertIs(raised.exception, expected)

    def test_invalid_parameter_dtype_shape_device_and_finite_values_are_rejected(self):
        q, k, v = self.make_inputs(batch=1, heads=2)

        for invalid in (True, 1.5, "2", None):
            with self.subTest(query_chunk_size=invalid):
                with self.assertRaises(TypeError):
                    wan_attention(q, k, v, query_chunk_size=invalid, device="cpu")
        for invalid in (0, -1):
            with self.subTest(query_chunk_size=invalid):
                with self.assertRaises(ValueError):
                    wan_attention(q, k, v, query_chunk_size=invalid, device="cpu")
        for invalid in ("cuda", "CPU", 0):
            with self.subTest(device=invalid):
                with self.assertRaises(ValueError):
                    wan_attention(q, k, v, device=invalid)
        with self.assertRaises(TypeError):
            wan_attention(q, k, v, device="cpu", checkpoint=object())
        with self.assertRaises(TypeError):
            wan_attention(object(), k, v, device="cpu")
        with self.assertRaises(TypeError):
            wan_attention(q.to(torch.float16), k, v, device="cpu")
        with self.assertRaises(TypeError):
            wan_attention(q, k.to(torch.float64), v, device="cpu")
        with self.assertRaises(TypeError):
            wan_attention(q, k, v.to(torch.float32), device="cpu")
        with self.assertRaises(ValueError):
            wan_attention(q.to_sparse(), k, v, device="cpu")
        with self.assertRaises(ValueError):
            wan_attention(q[:, :, :, 0], k, v, device="cpu")
        with self.assertRaises(ValueError):
            wan_attention(q[:, :0], k, v, device="cpu")
        with self.assertRaises(ValueError):
            wan_attention(q, k, v[:, :-1], device="cpu")
        with self.assertRaises(ValueError):
            wan_attention(q[:, :, :1], k, v, device="cpu")
        with self.assertRaises(ValueError):
            wan_attention(q, k, v, device="mps")

        for name in ("q", "k", "v"):
            bad = [tensor.clone() for tensor in (q, k, v)]
            bad[{"q": 0, "k": 1, "v": 2}[name]].reshape(-1)[0] = float("nan")
            with self.subTest(nonfinite=name):
                with self.assertRaisesRegex(ValueError, name):
                    wan_attention(*bad, device="cpu")

        overflow_q = q.clone()
        overflow_q.reshape(-1)[0] = torch.finfo(torch.float32).max
        with self.assertRaisesRegex(ValueError, "after BF16 quantization"):
            wan_attention(overflow_q, k, v, device="cpu")

    def test_mps_fallback_setting_is_explicitly_rejected(self):
        q, k, v = self.make_inputs(batch=1, heads=1)
        with mock.patch.dict(os.environ, {"PYTORCH_ENABLE_MPS_FALLBACK": "1"}):
            with self.assertRaisesRegex(RuntimeError, "fallback"):
                wan_attention(q, k, v, device="mps")

    def test_finite_fp32_overflowing_bf16_is_rejected_before_delivery(self):
        q, k, v = self.make_inputs(
            query_length=5, key_length=3, batch=1, heads=1, dimension=2
        )
        checkpoint_stages = []
        context_events = []
        sdpa_calls = []
        original_context = torch.nn.attention.sdpa_kernel

        def checkpoint(event):
            checkpoint_stages.append(event["stage"])

        def finite_fp32_max(query, _keys, values, **_kwargs):
            sdpa_calls.append(int(query.shape[-2]))
            shape = (*query.shape[:-1], values.shape[-1])
            return torch.full(
                shape,
                torch.finfo(torch.float32).max,
                dtype=query.dtype,
                device=query.device,
            )

        @contextlib.contextmanager
        def tracking_context(*, backends):
            context_events.append(("enter", tuple(backends)))
            try:
                with original_context(backends=backends):
                    yield
            finally:
                context_events.append(("exit", tuple(backends)))

        grad_before = torch.is_grad_enabled()
        inference_before = torch.is_inference_mode_enabled()
        flags_before = self._global_sdp_flags()
        result = None
        with mock.patch.object(torch.nn.attention, "sdpa_kernel", new=tracking_context):
            with mock.patch.object(
                torch.nn.functional,
                "scaled_dot_product_attention",
                side_effect=finite_fp32_max,
            ):
                with self.assertRaisesRegex(RuntimeError, "BF16 output conversion"):
                    result = wan_attention(
                        q,
                        k,
                        v,
                        query_chunk_size=2,
                        device="cpu",
                        checkpoint=checkpoint,
                    )

        expected_backends = (torch.nn.attention.SDPBackend.MATH,)
        self.assertIsNone(result)
        self.assertEqual(sdpa_calls, [2])
        self.assertEqual(checkpoint_stages, ["before_chunk"])
        self.assertEqual(
            context_events,
            [("enter", expected_backends), ("exit", expected_backends)],
        )
        self.assertEqual(torch.is_grad_enabled(), grad_before)
        self.assertEqual(torch.is_inference_mode_enabled(), inference_before)
        self.assertEqual(self._global_sdp_flags(), flags_before)

    def test_nonfinite_sdpa_result_is_never_delivered(self):
        q, k, v = self.make_inputs(batch=1, heads=1)

        def nonfinite_result(query, _keys, values, **_kwargs):
            shape = (*query.shape[:-1], values.shape[-1])
            return torch.full(shape, float("nan"), dtype=query.dtype, device=query.device)

        with mock.patch.object(
            torch.nn.functional,
            "scaled_dot_product_attention",
            side_effect=nonfinite_result,
        ):
            with self.assertRaisesRegex(RuntimeError, "non-finite"):
                wan_attention(q, k, v, query_chunk_size=2, device="cpu")

    @staticmethod
    def _global_sdp_flags():
        flags = {}
        for name in ("flash_sdp_enabled", "mem_efficient_sdp_enabled", "math_sdp_enabled"):
            value = getattr(torch.backends.cuda, name, None)
            if callable(value):
                flags[name] = value()
        return flags


if __name__ == "__main__":
    unittest.main(verbosity=2)
