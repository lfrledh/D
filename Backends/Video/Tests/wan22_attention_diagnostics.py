"""Shape-preserving attention diagnostics for the Wan 2.2 R8 investigation.

This module intentionally owns no model loading, persistence, or global backend
configuration.  PyTorch is imported only when ``run_attention_matrix`` is
called so importing this diagnostic module cannot initialize a runtime.
"""

from __future__ import annotations

import math
import numbers
import os
import time
from collections.abc import Callable, Iterable
from typing import Any


_Q64 = 64
_Q31 = 31
_OUTPUT_NAMES = (
    "A_bf16_q64",
    "B_bf16_q31",
    "C_formula_fp32",
    "C_bf16",
    "D_sdpa_fp32",
    "D_bf16",
    "F_cpu_fp64",
)

__all__ = ["run_attention_matrix"]


def _load_torch() -> Any:
    try:
        import torch
    except Exception as error:  # pragma: no cover - depends on the host runtime.
        raise RuntimeError("PyTorch is required to run attention diagnostics") from error
    return torch


def _validate_inputs(
    torch: Any,
    q: Any,
    k: Any,
    v: Any,
    positions: Iterable[int],
    device: str,
) -> tuple[tuple[int, ...], tuple[int, int, int, int]]:
    if type(device) is not str or device not in {"cpu", "mps"}:
        raise ValueError("device must be exactly 'cpu' or 'mps'")

    tensors = (("q", q, torch.float32), ("k", k, torch.float32), ("v", v, torch.bfloat16))
    for name, tensor, expected_dtype in tensors:
        if not isinstance(tensor, torch.Tensor):
            raise ValueError(f"{name} must be a torch.Tensor")
        if tensor.layout != torch.strided:
            raise ValueError(f"{name} must use strided tensor layout")
        if tensor.device.type != "cpu":
            raise ValueError(f"{name} must be on CPU")
        if tensor.dtype != expected_dtype:
            raise ValueError(f"{name} must have dtype {expected_dtype}")
        if tensor.ndim != 4:
            raise ValueError(f"{name} must have shape [1,N,H,D]")

    shape = tuple(int(value) for value in q.shape)
    if shape != tuple(k.shape) or shape != tuple(v.shape):
        raise ValueError("q, k, and v must have identical [1,N,H,D] shapes")
    if shape[0] != 1 or any(value <= 0 for value in shape[1:]):
        raise ValueError("q, k, and v must have positive shape [1,N,H,D]")

    for name, tensor, _ in tensors:
        if not bool(torch.isfinite(tensor).all().item()):
            raise ValueError(f"{name} must contain only finite values")

    if isinstance(positions, (str, bytes, bytearray, torch.Tensor)):
        raise ValueError("positions must be an iterable of Python integer values")
    try:
        raw_positions = tuple(positions)
    except TypeError as error:
        raise ValueError("positions must be a non-empty iterable") from error
    if not raw_positions:
        raise ValueError("positions must not be empty")

    checked: list[int] = []
    sequence_length = shape[1]
    previous = -1
    for position in raw_positions:
        if isinstance(position, bool) or not isinstance(position, numbers.Integral):
            raise ValueError("positions must contain integers and must reject bool")
        value = int(position)
        if value < 0 or value >= sequence_length:
            raise ValueError("positions contain an out-of-range value")
        if value <= previous:
            raise ValueError("positions must be unique and strictly increasing")
        checked.append(value)
        previous = value

    return tuple(checked), shape


def _q64_windows(positions: tuple[int, ...], sequence_length: int) -> tuple[tuple[int, int], ...]:
    starts = sorted({(position // _Q64) * _Q64 for position in positions})
    return tuple((start, min(start + _Q64, sequence_length)) for start in starts)


def _q31_windows(q64_windows: tuple[tuple[int, int], ...]) -> tuple[tuple[int, int], ...]:
    windows: list[tuple[int, int]] = []
    for start, end in q64_windows:
        boundaries = (start, min(start + _Q31, end), min(start + 2 * _Q31, end), end)
        for left, right in zip(boundaries, boundaries[1:]):
            if left < right:
                windows.append((left, right))
    return tuple(windows)


def _selected_queries(torch: Any, q_bf16: Any, positions: tuple[int, ...]) -> Any:
    return torch.stack([q_bf16[:, position, :, :] for position in positions], dim=1)


def _collect_window_rows(
    torch: Any,
    positions: tuple[int, ...],
    windows: tuple[tuple[int, int], ...],
    operation: Callable[[int, int], Any],
) -> Any:
    selected: dict[int, Any] = {}
    for start, end in windows:
        window_output = operation(start, end)
        expected_shape = (1, end - start)
        if tuple(window_output.shape[:2]) != expected_shape:
            raise RuntimeError(
                f"attention operation returned leading shape {tuple(window_output.shape[:2])}, "
                f"expected {expected_shape}"
            )
        for position in positions:
            if start <= position < end:
                selected[position] = window_output[:, position - start, :, :]
    missing = [position for position in positions if position not in selected]
    if missing:
        raise RuntimeError(f"attention windows did not cover requested positions: {missing}")
    return torch.stack([selected[position] for position in positions], dim=1)


def _synchronize(torch: Any, device: str) -> None:
    if device == "mps":
        torch.mps.synchronize()


def _timed(torch: Any, device: str, operation: Callable[[], Any]) -> tuple[Any, float]:
    _synchronize(torch, device)
    started = time.perf_counter()
    value = operation()
    _synchronize(torch, device)
    return value, time.perf_counter() - started


def _owned_cpu(tensor: Any) -> Any:
    return tensor.detach().to(device="cpu").contiguous().clone()


def _mps_fallback_is_enabled() -> bool:
    value = os.environ.get("PYTORCH_ENABLE_MPS_FALLBACK", "0")
    return value.strip().lower() not in {"", "0", "false", "no", "off"}


def run_attention_matrix(
    q: Any,
    k: Any,
    v: Any,
    *,
    positions: Iterable[int],
    device: str,
) -> dict[str, Any]:
    """Run the frozen R8 attention diagnostic matrix.

    Inputs remain untouched on CPU.  Q and K are quantized to BF16 on the
    requested compute device; every path then consumes those same quantized
    values.  All returned tensors own independent CPU storage.
    """

    torch = _load_torch()
    checked_positions, shape = _validate_inputs(torch, q, k, v, positions, device)
    _, sequence_length, heads, head_dimension = shape

    if device == "mps":
        if _mps_fallback_is_enabled():
            raise RuntimeError("MPS diagnostics require PYTORCH_ENABLE_MPS_FALLBACK to be disabled")
        mps_backend = getattr(torch.backends, "mps", None)
        if mps_backend is None or not mps_backend.is_built() or not mps_backend.is_available():
            raise RuntimeError("MPS was requested but is not built and available")

    attention_api = getattr(torch.nn, "attention", None)
    if attention_api is None or not hasattr(attention_api, "sdpa_kernel"):
        raise RuntimeError("PyTorch does not provide the required local SDPA backend context")
    math_backend = getattr(attention_api.SDPBackend, "MATH", None)
    if math_backend is None:
        raise RuntimeError("PyTorch does not provide the SDPA MATH backend")

    q64_windows = _q64_windows(checked_positions, sequence_length)
    q31_windows = _q31_windows(q64_windows)
    stage_metadata: dict[str, int | float | str] = {}
    outputs: dict[str, Any] = {}

    with torch.inference_mode(), attention_api.sdpa_kernel(backends=[math_backend]):
        # Quantization happens once.  Every matrix path below consumes these
        # exact BF16 values rather than independently rounding raw Q or K.
        q_bf16 = q.to(device=device, dtype=torch.bfloat16)
        k_bf16 = k.to(device=device, dtype=torch.bfloat16)
        v_bf16 = v.to(device=device, dtype=torch.bfloat16)
        k_heads_bf16 = k_bf16.permute(0, 2, 1, 3)
        v_heads_bf16 = v_bf16.permute(0, 2, 1, 3)

        def sdpa_bf16_window(start: int, end: int) -> Any:
            query = q_bf16[:, start:end, :, :].permute(0, 2, 1, 3)
            value = torch.nn.functional.scaled_dot_product_attention(
                query,
                k_heads_bf16,
                v_heads_bf16,
                attn_mask=None,
                dropout_p=0.0,
                is_causal=False,
            )
            return value.permute(0, 2, 1, 3)

        a_value, a_seconds = _timed(
            torch,
            device,
            lambda: _collect_window_rows(
                torch, checked_positions, q64_windows, sdpa_bf16_window
            ),
        )
        outputs["A_bf16_q64"] = _owned_cpu(a_value)
        stage_metadata["A_bf16_q64_seconds"] = a_seconds
        stage_metadata["A_bf16_q64_calls"] = len(q64_windows)
        stage_metadata["A_bf16_q64_max_query_rows"] = max(end - start for start, end in q64_windows)
        del a_value

        b_value, b_seconds = _timed(
            torch,
            device,
            lambda: _collect_window_rows(
                torch, checked_positions, q31_windows, sdpa_bf16_window
            ),
        )
        outputs["B_bf16_q31"] = _owned_cpu(b_value)
        stage_metadata["B_bf16_q31_seconds"] = b_seconds
        stage_metadata["B_bf16_q31_calls"] = len(q31_windows)
        stage_metadata["B_bf16_q31_max_query_rows"] = max(end - start for start, end in q31_windows)
        stage_metadata["B_bf16_q31_min_query_rows"] = min(end - start for start, end in q31_windows)
        del b_value

        k_heads_fp32 = k_heads_bf16.to(dtype=torch.float32)
        v_heads_fp32 = v_heads_bf16.to(dtype=torch.float32)
        scale = 1.0 / math.sqrt(head_dimension)

        def explicit_fp32_window(start: int, end: int) -> Any:
            query = q_bf16[:, start:end, :, :].permute(0, 2, 1, 3).to(dtype=torch.float32)
            scores = torch.matmul(query, k_heads_fp32.transpose(-2, -1)) * scale
            probabilities = torch.softmax(scores, dim=-1)
            value = torch.matmul(probabilities, v_heads_fp32)
            return value.permute(0, 2, 1, 3)

        c_value, c_seconds = _timed(
            torch,
            device,
            lambda: _collect_window_rows(
                torch, checked_positions, q64_windows, explicit_fp32_window
            ),
        )
        outputs["C_formula_fp32"] = _owned_cpu(c_value)
        outputs["C_bf16"] = _owned_cpu(c_value.to(dtype=torch.bfloat16))
        stage_metadata["C_formula_fp32_seconds"] = c_seconds
        stage_metadata["C_formula_fp32_calls"] = len(q64_windows)
        stage_metadata["C_formula_fp32_query_rows"] = _Q64
        del c_value

        def sdpa_fp32_window(start: int, end: int) -> Any:
            query = q_bf16[:, start:end, :, :].permute(0, 2, 1, 3).to(dtype=torch.float32)
            value = torch.nn.functional.scaled_dot_product_attention(
                query,
                k_heads_fp32,
                v_heads_fp32,
                attn_mask=None,
                dropout_p=0.0,
                is_causal=False,
            )
            return value.permute(0, 2, 1, 3)

        d_value, d_seconds = _timed(
            torch,
            device,
            lambda: _collect_window_rows(
                torch, checked_positions, q64_windows, sdpa_fp32_window
            ),
        )
        outputs["D_sdpa_fp32"] = _owned_cpu(d_value)
        outputs["D_bf16"] = _owned_cpu(d_value.to(dtype=torch.bfloat16))
        stage_metadata["D_sdpa_fp32_seconds"] = d_seconds
        stage_metadata["D_sdpa_fp32_calls"] = len(q64_windows)
        stage_metadata["D_sdpa_fp32_query_rows"] = _Q64
        del d_value, k_heads_fp32, v_heads_fp32

        def cpu_fp64_reference() -> Any:
            query = _selected_queries(torch, q_bf16, checked_positions)
            query = query.permute(0, 2, 1, 3).to(device="cpu", dtype=torch.float64)
            keys = k_heads_bf16.to(device="cpu", dtype=torch.float64)
            values = v_heads_bf16.to(device="cpu", dtype=torch.float64)
            value = torch.nn.functional.scaled_dot_product_attention(
                query,
                keys,
                values,
                attn_mask=None,
                dropout_p=0.0,
                is_causal=False,
            )
            return value.permute(0, 2, 1, 3)

        f_value, f_seconds = _timed(torch, "cpu", cpu_fp64_reference)
        outputs["F_cpu_fp64"] = _owned_cpu(f_value)
        stage_metadata["F_cpu_fp64_seconds"] = f_seconds
        stage_metadata["F_cpu_fp64_calls"] = 1
        stage_metadata["F_cpu_fp64_query_rows"] = len(checked_positions)
        del f_value

    expected_output_shape = (1, len(checked_positions), heads, head_dimension)
    for name in _OUTPUT_NAMES:
        tensor = outputs[name]
        if tuple(tensor.shape) != expected_output_shape:
            raise RuntimeError(
                f"{name} returned shape {tuple(tensor.shape)}, expected {expected_output_shape}"
            )
        if tensor.device.type != "cpu":
            raise RuntimeError(f"{name} was not copied to CPU")
        if not bool(torch.isfinite(tensor).all().item()):
            raise FloatingPointError(f"{name} produced a non-finite value")

    metadata: dict[str, int | float | str] = {
        "device": device,
        "sequence_length": sequence_length,
        "head_count": heads,
        "head_dimension": head_dimension,
        "position_count": len(checked_positions),
        "q64_window_count": len(q64_windows),
        "q31_window_count": len(q31_windows),
    }
    metadata.update(stage_metadata)
    return {"outputs": outputs, "metadata": metadata}
