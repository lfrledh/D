import mlx.core as mx
import mlx.nn as nn

from .rope import rope_apply


def _linear_dtype(layer) -> mx.Dtype:
    """Get the compute dtype of a linear layer, handling QuantizedLinear and LoRA wrappers."""
    # Unwrap LoRA wrapper to get the underlying linear layer
    inner = getattr(layer, "linear", layer)
    if isinstance(inner, nn.QuantizedLinear):
        return inner.scales.dtype
    return inner.weight.dtype


def _attention_compute_dtype(layer) -> mx.Dtype:
    """Return the validated SDPA dtype selected by the V projection."""
    dtype = _linear_dtype(layer)
    if dtype not in (mx.float16, mx.bfloat16, mx.float32):
        raise TypeError(f"unsupported Wan attention compute dtype: {dtype}")
    return dtype


class WanRMSNorm(nn.Module):
    """RMS normalization with learnable scale."""

    def __init__(self, dim: int, eps: float = 1e-5):
        super().__init__()
        self.eps = eps
        self.weight = mx.ones((dim,))

    def __call__(self, x: mx.array) -> mx.array:
        x_fp32 = x.astype(mx.float32)
        variance = mx.mean(mx.square(x_fp32), axis=-1, keepdims=True)
        normalized = x_fp32 * mx.rsqrt(variance + self.eps)
        return normalized.astype(x.dtype) * self.weight


class WanLayerNorm(nn.Module):
    """LayerNorm computed in float32, with optional affine."""

    def __init__(self, dim: int, eps: float = 1e-6, elementwise_affine: bool = False):
        super().__init__()
        self.eps = eps
        self.elementwise_affine = elementwise_affine
        if elementwise_affine:
            self.weight = mx.ones((dim,))
            self.bias = mx.zeros((dim,))

    def __call__(self, x: mx.array) -> mx.array:
        x_fp32 = x.astype(mx.float32)
        mean = mx.mean(x_fp32, axis=-1, keepdims=True)
        centered = x_fp32 - mean
        variance = mx.mean(mx.square(centered), axis=-1, keepdims=True)
        normalized = centered * mx.rsqrt(variance + self.eps)
        if self.elementwise_affine:
            normalized = normalized * self.weight.astype(mx.float32)
            normalized = normalized + self.bias.astype(mx.float32)
        return normalized.astype(x.dtype)


class WanSelfAttention(nn.Module):
    """Self-attention with QK normalization and 3-way factorized RoPE."""

    def __init__(
        self,
        dim: int,
        num_heads: int,
        window_size: tuple = (-1, -1),
        qk_norm: bool = True,
        eps: float = 1e-6,
    ):
        super().__init__()
        assert dim % num_heads == 0
        self.dim = dim
        self.num_heads = num_heads
        self.head_dim = dim // num_heads
        self.window_size = window_size
        self.scale = self.head_dim**-0.5

        self.q = nn.Linear(dim, dim)
        self.k = nn.Linear(dim, dim)
        self.v = nn.Linear(dim, dim)
        self.o = nn.Linear(dim, dim)

        self.norm_q = WanRMSNorm(dim, eps=eps) if qk_norm else None
        self.norm_k = WanRMSNorm(dim, eps=eps) if qk_norm else None

    def __call__(
        self,
        x: mx.array,
        seq_lens: list,
        grid_sizes: list,
        freqs: mx.array,
        rope_cos_sin: tuple | None = None,
        attn_mask: mx.array | None = None,
    ) -> mx.array:
        b, s, _ = x.shape
        n, d = self.num_heads, self.head_dim

        q = self.q(x.astype(_linear_dtype(self.q)))
        k = self.k(x.astype(_linear_dtype(self.k)))
        if self.norm_q is not None:
            q = self.norm_q(q)
        if self.norm_k is not None:
            k = self.norm_k(k)

        q = q.reshape(b, s, n, d)
        k = k.reshape(b, s, n, d)
        v = self.v(x.astype(_linear_dtype(self.v))).reshape(b, s, n, d)

        # RoPE in float32 for precision (official uses float64)
        q = rope_apply(
            q.astype(mx.float32), grid_sizes, freqs, precomputed_cos_sin=rope_cos_sin
        )
        k = rope_apply(
            k.astype(mx.float32), grid_sizes, freqs, precomputed_cos_sin=rope_cos_sin
        )

        # Official flash_attention converts Q/K to V's half precision before
        # the kernel. Keep the same explicit boundary for MLX SDPA.
        attention_dtype = _attention_compute_dtype(self.v)
        q = q.astype(attention_dtype).transpose(0, 2, 1, 3)
        k = k.astype(attention_dtype).transpose(0, 2, 1, 3)
        v = v.astype(attention_dtype).transpose(0, 2, 1, 3)

        # Use precomputed mask or build from seq_lens
        mask = attn_mask
        if mask is None and any(sl < s for sl in seq_lens):
            mask = mx.zeros((b, 1, 1, s), dtype=attention_dtype)
            for i, sl in enumerate(seq_lens):
                mask[i, :, :, sl:] = -1e9
        elif mask is not None:
            mask = mask.astype(attention_dtype)

        # Use memory-efficient scaled dot-product attention
        # mx.fast.scaled_dot_product_attention expects [B, N, L, D]
        if mask is not None:
            out = mx.fast.scaled_dot_product_attention(
                q, k, v, scale=self.scale, mask=mask
            )
        else:
            out = mx.fast.scaled_dot_product_attention(q, k, v, scale=self.scale)

        out = out.transpose(0, 2, 1, 3).reshape(b, s, -1)
        return self.o(out.astype(_linear_dtype(self.o)))


class WanCrossAttention(nn.Module):
    """Cross-attention: Q from hidden states, K/V from text context."""

    def __init__(
        self,
        dim: int,
        num_heads: int,
        qk_norm: bool = True,
        eps: float = 1e-6,
    ):
        super().__init__()
        assert dim % num_heads == 0
        self.num_heads = num_heads
        self.head_dim = dim // num_heads
        self.scale = self.head_dim**-0.5

        self.q = nn.Linear(dim, dim)
        self.k = nn.Linear(dim, dim)
        self.v = nn.Linear(dim, dim)
        self.o = nn.Linear(dim, dim)

        self.norm_q = WanRMSNorm(dim, eps=eps) if qk_norm else None
        self.norm_k = WanRMSNorm(dim, eps=eps) if qk_norm else None

    def prepare_kv(self, context: mx.array) -> tuple:
        """Pre-compute K and V projections for caching.

        Args:
            context: [B, L_ctx, dim]

        Returns:
            (k, v) each [B, N, L_ctx, D] ready for attention
        """
        b = context.shape[0]
        n, d = self.num_heads, self.head_dim
        k = self.k(context.astype(_linear_dtype(self.k)))
        if self.norm_k is not None:
            k = self.norm_k(k)
        k = k.reshape(b, -1, n, d).transpose(0, 2, 1, 3)
        v = self.v(context.astype(_linear_dtype(self.v)))
        v = v.reshape(b, -1, n, d).transpose(0, 2, 1, 3)
        attention_dtype = _attention_compute_dtype(self.v)
        return k.astype(attention_dtype), v.astype(attention_dtype)

    def __call__(
        self,
        x: mx.array,
        context: mx.array,
        context_lens: list | None = None,
        kv_cache: tuple | None = None,
    ) -> mx.array:
        b = x.shape[0]
        n, d = self.num_heads, self.head_dim

        q = self.q(x.astype(_linear_dtype(self.q)))
        if self.norm_q is not None:
            q = self.norm_q(q)
        q = q.reshape(b, -1, n, d).transpose(0, 2, 1, 3)

        if kv_cache is not None:
            k, v = kv_cache
        else:
            k = self.k(context.astype(_linear_dtype(self.k)))
            if self.norm_k is not None:
                k = self.norm_k(k)
            k = k.reshape(b, -1, n, d).transpose(0, 2, 1, 3)
            v = self.v(context.astype(_linear_dtype(self.v)))
            v = v.reshape(b, -1, n, d).transpose(0, 2, 1, 3)

        attention_dtype = _attention_compute_dtype(self.v)
        q = q.astype(attention_dtype)
        k = k.astype(attention_dtype)
        v = v.astype(attention_dtype)

        # Optional context masking
        mask = None
        if context_lens is not None:
            ctx_len = k.shape[2]
            mask = mx.zeros((b, 1, 1, ctx_len), dtype=attention_dtype)
            for i, cl in enumerate(context_lens):
                mask[i, :, :, cl:] = -1e9

        if mask is not None:
            out = mx.fast.scaled_dot_product_attention(
                q, k, v, scale=self.scale, mask=mask
            )
        else:
            out = mx.fast.scaled_dot_product_attention(q, k, v, scale=self.scale)

        out = out.transpose(0, 2, 1, 3).reshape(b, -1, n * d)
        return self.o(out.astype(_linear_dtype(self.o)))
