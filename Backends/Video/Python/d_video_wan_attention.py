"""Bounded Wan attention using an explicit FP32 SDPA math path."""

from __future__ import annotations

import numbers
import os
from types import MappingProxyType
from typing import Any, Callable, Mapping


class AttentionCancelled(RuntimeError):
    """Raised by a checkpoint callback to cancel attention between chunks."""


Checkpoint = Callable[[Mapping[str, str | int]], None]


def _load_torch() -> Any:
    try:
        import torch
    except Exception as error:  # pragma: no cover - supplied by the runtime.
        raise RuntimeError("PyTorch is required to run Wan attention") from error
    return torch


def _mps_fallback_is_enabled() -> bool:
    value = os.environ.get("PYTORCH_ENABLE_MPS_FALLBACK", "0")
    return value.strip().lower() not in {"", "0", "false", "no", "off"}


def _validate(
    torch: Any,
    q: Any,
    k: Any,
    v: Any,
    *,
    query_chunk_size: int,
    device: str,
    checkpoint: Checkpoint | None,
) -> tuple[int, int, int, int, int]:
    if isinstance(query_chunk_size, bool) or not isinstance(query_chunk_size, numbers.Integral):
        raise TypeError("query_chunk_size must be a positive integer and must not be bool")
    chunk_size = int(query_chunk_size)
    if chunk_size <= 0:
        raise ValueError("query_chunk_size must be positive")
    if type(device) is not str or device not in {"cpu", "mps"}:
        raise ValueError("device must be exactly 'cpu' or 'mps'")
    if checkpoint is not None and not callable(checkpoint):
        raise TypeError("checkpoint must be callable or None")
    if device == "mps" and _mps_fallback_is_enabled():
        raise RuntimeError("MPS attention requires PYTORCH_ENABLE_MPS_FALLBACK to be disabled")

    tensors = (("q", q), ("k", k), ("v", v))
    for name, tensor in tensors:
        if not isinstance(tensor, torch.Tensor):
            raise TypeError(f"{name} must be a torch.Tensor")
        if tensor.layout != torch.strided:
            raise ValueError(f"{name} must use strided tensor layout")
        if tensor.ndim != 4:
            raise ValueError(f"{name} must have layout [B,N,H,D]")

    allowed_query_dtypes = {torch.float32, torch.bfloat16}
    if q.dtype not in allowed_query_dtypes:
        raise TypeError("q must have dtype torch.float32 or torch.bfloat16")
    if k.dtype not in allowed_query_dtypes:
        raise TypeError("k must have dtype torch.float32 or torch.bfloat16")
    if v.dtype != torch.bfloat16:
        raise TypeError("v must have dtype torch.bfloat16")

    if q.device != k.device or q.device != v.device:
        raise ValueError("q, k, and v must be on the same device")
    if q.device.type != device:
        raise ValueError(f"input tensors must already be on the requested {device} device")

    batch, query_length, heads, head_dimension = (int(value) for value in q.shape)
    key_batch, key_length, key_heads, key_dimension = (int(value) for value in k.shape)
    if tuple(v.shape) != tuple(k.shape):
        raise ValueError("k and v must have identical [B,K,H,D] shapes")
    if (batch, heads, head_dimension) != (key_batch, key_heads, key_dimension):
        raise ValueError("q and k/v must agree in batch, heads, and head dimension")
    if any(value <= 0 for value in (batch, query_length, key_length, heads, head_dimension)):
        raise ValueError("q, k, and v dimensions must all be non-empty")

    for name, tensor in tensors:
        if not bool(torch.isfinite(tensor).all().item()):
            raise ValueError(f"{name} must contain only finite values")

    return chunk_size, batch, query_length, heads, head_dimension


def _checkpoint(
    callback: Checkpoint | None,
    stage: str,
    start: int,
    end: int,
    total: int,
) -> None:
    if callback is None:
        return
    callback(
        MappingProxyType(
            {
                "stage": stage,
                "start": start,
                "end": end,
                "total": total,
            }
        )
    )


def wan_attention(
    q: Any,
    k: Any,
    v: Any,
    *,
    query_chunk_size: int = 64,
    device: str = "mps",
    checkpoint: Checkpoint | None = None,
) -> Any:
    """Compute non-causal Wan attention without moving inputs between devices.

    Q and K are first quantized to BF16, matching the model path, and are then
    promoted with the existing BF16 V values for explicit FP32 math SDPA.  Only
    the query axis is chunked; every chunk attends over all K/V rows.
    """

    torch = _load_torch()
    chunk_size, batch, query_length, heads, head_dimension = _validate(
        torch,
        q,
        k,
        v,
        query_chunk_size=query_chunk_size,
        device=device,
        checkpoint=checkpoint,
    )

    attention_api = getattr(torch.nn, "attention", None)
    if attention_api is None or not hasattr(attention_api, "sdpa_kernel"):
        raise RuntimeError("PyTorch does not provide the required local SDPA backend context")
    math_backend = getattr(attention_api.SDPBackend, "MATH", None)
    if math_backend is None:
        raise RuntimeError("PyTorch does not provide the SDPA MATH backend")

    q_bf16 = None
    k_bf16 = None
    k_fp32 = None
    v_fp32 = None
    k_heads = None
    v_heads = None
    output = None
    query = None
    chunk = None
    chunk_bf16 = None
    tensor = None
    try:
        with torch.inference_mode(), attention_api.sdpa_kernel(backends=[math_backend]):
            q_bf16 = q.to(dtype=torch.bfloat16)
            k_bf16 = k.to(dtype=torch.bfloat16)
            for name, tensor in (("q", q_bf16), ("k", k_bf16)):
                if not bool(torch.isfinite(tensor).all().item()):
                    raise ValueError(f"{name} became non-finite after BF16 quantization")

            k_fp32 = k_bf16.to(dtype=torch.float32)
            v_fp32 = v.to(dtype=torch.float32)
            k_heads = k_fp32.permute(0, 2, 1, 3)
            v_heads = v_fp32.permute(0, 2, 1, 3)
            output = torch.empty(
                (batch, query_length, heads, head_dimension),
                dtype=torch.bfloat16,
                device=q.device,
            )

            for start in range(0, query_length, chunk_size):
                end = min(start + chunk_size, query_length)
                _checkpoint(checkpoint, "before_chunk", start, end, query_length)
                query = (
                    q_bf16[:, start:end, :, :]
                    .permute(0, 2, 1, 3)
                    .to(dtype=torch.float32)
                )
                chunk = torch.nn.functional.scaled_dot_product_attention(
                    query,
                    k_heads,
                    v_heads,
                    attn_mask=None,
                    dropout_p=0.0,
                    is_causal=False,
                    scale=None,
                )
                if not bool(torch.isfinite(chunk).all().item()):
                    raise RuntimeError("attention produced non-finite values")
                chunk_bf16 = chunk.permute(0, 2, 1, 3).to(dtype=torch.bfloat16)
                output[:, start:end, :, :].copy_(chunk_bf16)
                query = None
                chunk = None
                chunk_bf16 = None
                _checkpoint(checkpoint, "after_chunk", start, end, query_length)

            return output
    finally:
        query = None
        chunk = None
        chunk_bf16 = None
        k_heads = None
        v_heads = None
        k_fp32 = None
        v_fp32 = None
        q_bf16 = None
        k_bf16 = None
        tensor = None
        output = None


__all__ = ["AttentionCancelled", "wan_attention"]
