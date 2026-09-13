"""Independent Torch-CPU references for the frozen Wan T2V numerics.

The upstream repository is never added to ``sys.path``. Pure numerical
definitions are selected from four fixed official files with ``ast``; CUDA
attention wrappers and tokenizer/model-loading code are not executed.
"""

import ast
import contextlib
import functools
import importlib
import inspect
import os
from pathlib import Path
import sys
import tokenize
import types
from types import SimpleNamespace
from typing import List, Optional, Tuple, Union
import unittest
from unittest import mock
import warnings


os.environ.setdefault("CUDA_VISIBLE_DEVICES", "")
os.environ.setdefault("OMP_NUM_THREADS", "1")
os.environ.setdefault("MKL_NUM_THREADS", "1")
os.environ.setdefault("VECLIB_MAXIMUM_THREADS", "1")

import mlx.core as mx
import numpy as np
import torch
import torch.nn as torch_nn
import torch.nn.functional as torch_functional


torch.set_num_threads(1)
torch.set_num_interop_threads(1)
torch.set_default_device("cpu")
mx.set_default_device(mx.cpu)

FP32_ATOL = 3e-5
FP32_RTOL = 3e-5
BF16_ATOL = 0.02
BF16_RTOL = 0.02
SIGMA_ATOL = 1e-7


def _required_directory(variable: str) -> Path:
    value = os.environ.get(variable)
    if not value:
        raise RuntimeError(f"{variable} must name the frozen directory")
    path = Path(value).expanduser().resolve()
    if not path.is_dir():
        raise RuntimeError(f"{variable} does not name a directory: {path}")
    return path


VENDOR_ROOT = _required_directory("D_WAN_VENDOR")
REFERENCE_ROOT = _required_directory("D_WAN_REFERENCE_ROOT")
T5_REFERENCE = REFERENCE_ROOT / "wan/modules/t5.py"
MODEL_REFERENCE = REFERENCE_ROOT / "wan/modules/model.py"
UNIPC_REFERENCE = REFERENCE_ROOT / "wan/utils/fm_solvers_unipc.py"
ATTENTION_REFERENCE = REFERENCE_ROOT / "wan/modules/attention.py"
for _reference_path in (
    T5_REFERENCE,
    MODEL_REFERENCE,
    UNIPC_REFERENCE,
    ATTENTION_REFERENCE,
):
    if not _reference_path.is_file():
        raise RuntimeError(f"missing frozen official source: {_reference_path}")


def _load_vendor_modules():
    package_name = "d_wan_numeric_vendor"
    package = types.ModuleType(package_name)
    package.__path__ = [str(VENDOR_ROOT)]
    package.__package__ = package_name
    sys.modules[package_name] = package
    return SimpleNamespace(
        text=importlib.import_module(f"{package_name}.text_encoder"),
        rope=importlib.import_module(f"{package_name}.rope"),
        attention=importlib.import_module(f"{package_name}.attention"),
        transformer=importlib.import_module(f"{package_name}.transformer"),
        model=importlib.import_module(f"{package_name}.wan_2"),
        scheduler=importlib.import_module(f"{package_name}.scheduler"),
    )


class _DisabledAutocast(contextlib.ContextDecorator):
    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        return False


class _CPUAMP:
    """Keep official FP32-disabled regions explicit on CPU.

    The fixture's BF16 linear pre-hooks below model the surrounding production
    autocast separately; this shim never enters a CUDA autocast context.
    """

    @staticmethod
    def autocast(function=None, **_kwargs):
        context = _DisabledAutocast()
        if function is not None:
            return context(function)
        return context


def _source_tree(path: Path) -> ast.Module:
    with tokenize.open(path) as source:
        return ast.parse(source.read(), filename=str(path))


def _selected_namespace(
    path: Path,
    *,
    functions: tuple[str, ...] = (),
    classes: tuple[str, ...] = (),
    injected: dict | None = None,
) -> SimpleNamespace:
    selected = []
    for node in _source_tree(path).body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            if node.name in functions:
                selected.append(node)
        elif isinstance(node, ast.ClassDef) and node.name in classes:
            selected.append(node)
    requested = set(functions) | set(classes)
    found = {node.name for node in selected}
    if found != requested:
        raise RuntimeError(f"missing official definitions in {path}: {requested - found}")
    module = ast.fix_missing_locations(ast.Module(body=selected, type_ignores=[]))
    namespace = dict(injected or {})
    namespace.setdefault("__name__", "d_wan_official_ast_reference")
    exec(compile(module, str(path), "exec"), namespace)
    return SimpleNamespace(**namespace)


def _official_unpatchify():
    tree = _source_tree(MODEL_REFERENCE)
    method = None
    for node in tree.body:
        if isinstance(node, ast.ClassDef) and node.name == "WanModel":
            method = next(
                (
                    child
                    for child in node.body
                    if isinstance(child, ast.FunctionDef)
                    and child.name == "unpatchify"
                ),
                None,
            )
            break
    if method is None:
        raise RuntimeError("official WanModel.unpatchify definition is missing")
    module = ast.fix_missing_locations(ast.Module(body=[method], type_ignores=[]))
    namespace = {"math": __import__("math"), "torch": torch}
    exec(compile(module, str(MODEL_REFERENCE), "exec"), namespace)
    return namespace["unpatchify"]


class _ConfigMixin:
    def register_to_config(self, **values):
        if not hasattr(self, "config"):
            self.config = SimpleNamespace()
        for name, value in values.items():
            setattr(self.config, name, value)


def _register_to_config(initializer):
    signature = inspect.signature(initializer)

    @functools.wraps(initializer)
    def wrapped(self, *args, **kwargs):
        bound = signature.bind(self, *args, **kwargs)
        bound.apply_defaults()
        self.register_to_config(
            **{name: value for name, value in bound.arguments.items() if name != "self"}
        )
        return initializer(self, *args, **kwargs)

    return wrapped


class _SchedulerMixin:
    pass


class _SchedulerOutput:
    def __init__(self, prev_sample):
        self.prev_sample = prev_sample


def _unexpected_deprecation(*args, **kwargs):
    raise AssertionError(f"unexpected deprecated reference path: {args}, {kwargs}")


vendor = _load_vendor_modules()

official_t5 = _selected_namespace(
    T5_REFERENCE,
    functions=("fp16_clamp", "init_weights"),
    classes=(
        "GELU",
        "T5LayerNorm",
        "T5Attention",
        "T5FeedForward",
        "T5SelfAttention",
        "T5CrossAttention",
        "T5RelativeEmbedding",
        "T5Encoder",
        "T5Decoder",
        "T5Model",
    ),
    injected={
        "math": __import__("math"),
        "torch": torch,
        "nn": torch_nn,
        "F": torch_functional,
    },
)

official_attention = _selected_namespace(
    ATTENTION_REFERENCE,
    functions=("attention",),
    injected={
        "torch": torch,
        "warnings": warnings,
        "FLASH_ATTN_2_AVAILABLE": False,
        "FLASH_ATTN_3_AVAILABLE": False,
    },
)

official_model = _selected_namespace(
    MODEL_REFERENCE,
    functions=("sinusoidal_embedding_1d", "rope_params", "rope_apply"),
    classes=(
        "WanRMSNorm",
        "WanLayerNorm",
        "WanSelfAttention",
        "WanT2VCrossAttention",
        "WanAttentionBlock",
        "Head",
        "WanModel",
    ),
    injected={
        "math": __import__("math"),
        "torch": torch,
        "nn": torch_nn,
        "amp": _CPUAMP,
        "flash_attention": official_attention.attention,
        "ModelMixin": torch_nn.Module,
        "ConfigMixin": _ConfigMixin,
        "register_to_config": _register_to_config,
    },
)
official_model.unpatchify = _official_unpatchify()
official_model.WanAttentionBlock.__init__.__globals__[
    "WAN_CROSSATTENTION_CLASSES"
] = {"t2v_cross_attn": official_model.WanT2VCrossAttention}

official_scheduler = _selected_namespace(
    UNIPC_REFERENCE,
    classes=("FlowUniPCMultistepScheduler",),
    injected={
        "math": __import__("math"),
        "np": np,
        "torch": torch,
        "List": List,
        "Optional": Optional,
        "Tuple": Tuple,
        "Union": Union,
        "ConfigMixin": _ConfigMixin,
        "register_to_config": _register_to_config,
        "SchedulerMixin": _SchedulerMixin,
        "SchedulerOutput": _SchedulerOutput,
        "KarrasDiffusionSchedulers": (),
        "deprecate": _unexpected_deprecation,
    },
)


def _torch_numpy(value: torch.Tensor) -> np.ndarray:
    return value.detach().to(device="cpu", dtype=torch.float32).numpy()


def _mx_dtype(torch_dtype):
    return mx.bfloat16 if torch_dtype == torch.bfloat16 else mx.float32


def _to_mx(value: torch.Tensor, dtype=None):
    return mx.array(_torch_numpy(value), dtype=dtype or _mx_dtype(value.dtype))


def _copy_linear(torch_layer, mlx_layer):
    dtype = _mx_dtype(torch_layer.weight.dtype)
    mlx_layer.weight = _to_mx(torch_layer.weight, dtype=dtype)
    if torch_layer.bias is not None:
        mlx_layer.bias = _to_mx(torch_layer.bias, dtype=dtype)


def _copy_t5_attention(torch_layer, mlx_layer):
    for name in ("q", "k", "v", "o"):
        _copy_linear(getattr(torch_layer, name), getattr(mlx_layer, name))


def _copy_t5_block(torch_layer, mlx_layer):
    mlx_layer.norm1.weight = _to_mx(torch_layer.norm1.weight)
    mlx_layer.norm2.weight = _to_mx(torch_layer.norm2.weight)
    _copy_t5_attention(torch_layer.attn, mlx_layer.attn)
    _copy_linear(torch_layer.ffn.gate[0], mlx_layer.ffn.gate_proj)
    _copy_linear(torch_layer.ffn.fc1, mlx_layer.ffn.fc1)
    _copy_linear(torch_layer.ffn.fc2, mlx_layer.ffn.fc2)
    if torch_layer.pos_embedding is not None:
        mlx_layer.pos_embedding.embedding.weight = _to_mx(
            torch_layer.pos_embedding.embedding.weight
        )


def _copy_wan_attention(torch_layer, mlx_layer):
    for name in ("q", "k", "v", "o"):
        _copy_linear(getattr(torch_layer, name), getattr(mlx_layer, name))
    mlx_layer.norm_q.weight = _to_mx(torch_layer.norm_q.weight)
    mlx_layer.norm_k.weight = _to_mx(torch_layer.norm_k.weight)


def _copy_wan_block(torch_layer, mlx_layer):
    mlx_layer.modulation = _to_mx(torch_layer.modulation)
    _copy_wan_attention(torch_layer.self_attn, mlx_layer.self_attn)
    _copy_wan_attention(torch_layer.cross_attn, mlx_layer.cross_attn)
    mlx_layer.norm3.weight = _to_mx(torch_layer.norm3.weight)
    mlx_layer.norm3.bias = _to_mx(torch_layer.norm3.bias)
    _copy_linear(torch_layer.ffn[0], mlx_layer.ffn.fc1)
    _copy_linear(torch_layer.ffn[2], mlx_layer.ffn.fc2)


def _install_bfloat16_autocast_boundaries(torch_block):
    linears = (
        torch_block.self_attn.q,
        torch_block.self_attn.k,
        torch_block.self_attn.v,
        torch_block.self_attn.o,
        torch_block.cross_attn.q,
        torch_block.cross_attn.k,
        torch_block.cross_attn.v,
        torch_block.cross_attn.o,
        torch_block.ffn[0],
        torch_block.ffn[2],
    )
    for linear in linears:
        linear.to(dtype=torch.bfloat16)

        def cast_input(module, arguments):
            return (arguments[0].to(module.weight.dtype), *arguments[1:])

        linear.register_forward_pre_hook(cast_input)


class _RecordingLinear(vendor.attention.nn.Module):
    def __init__(self, linear, label: str, records: list):
        super().__init__()
        self.linear = linear
        self.label = label
        self.records = records

    def __call__(self, value):
        self.records.append((self.label, value.dtype))
        return self.linear(value)


def _fill_parameters(module, seed: int, scale: float = 0.075):
    generator = torch.Generator(device="cpu")
    generator.manual_seed(seed)
    with torch.no_grad():
        for parameter in module.parameters():
            parameter.uniform_(-scale, scale, generator=generator)


def _as_float_numpy(value) -> np.ndarray:
    if isinstance(value, torch.Tensor):
        return _torch_numpy(value)
    if isinstance(value, mx.array):
        value = value.astype(mx.float32)
    return np.asarray(value).astype(np.float32)


def _errors(actual, expected) -> tuple[float, float]:
    actual_np = _as_float_numpy(actual)
    expected_np = _as_float_numpy(expected)
    difference = np.abs(actual_np - expected_np)
    max_abs = float(np.max(difference, initial=0.0))
    denominator = np.maximum(np.abs(expected_np), 1e-12)
    max_relative = float(np.max(difference / denominator, initial=0.0))
    return max_abs, max_relative


def _assert_close(
    case: unittest.TestCase,
    actual,
    expected,
    label: str,
    *,
    atol: float = FP32_ATOL,
    rtol: float = FP32_RTOL,
    report: bool = True,
) -> tuple[float, float]:
    actual_np = _as_float_numpy(actual)
    expected_np = _as_float_numpy(expected)
    case.assertEqual(actual_np.shape, expected_np.shape, label)
    case.assertTrue(np.isfinite(actual_np).all(), f"{label}: MLX result is not finite")
    case.assertTrue(
        np.isfinite(expected_np).all(), f"{label}: Torch result is not finite"
    )
    max_abs, max_relative = _errors(actual_np, expected_np)
    if report:
        actual_dtype = getattr(actual, "dtype", actual_np.dtype)
        expected_dtype = getattr(expected, "dtype", expected_np.dtype)
        print(
            f"{label}: maxabs={max_abs:.9g} relative={max_relative:.9g} "
            f"mlx_dtype={actual_dtype} torch_dtype={expected_dtype} finite=true"
        )
    np.testing.assert_allclose(actual_np, expected_np, atol=atol, rtol=rtol)
    return max_abs, max_relative


def _tiny_model_config():
    return SimpleNamespace(
        dim=24,
        num_heads=2,
        out_dim=2,
        patch_size=(1, 2, 2),
        text_len=5,
        freq_dim=8,
        in_dim=2,
        text_dim=12,
        ffn_dim=48,
        window_size=(-1, -1),
        qk_norm=True,
        cross_attn_norm=False,
        eps=1e-6,
        num_layers=0,
    )


class WanPatchRopeAndPrecisionTests(unittest.TestCase):
    def test_patchify_matches_conv3d_fp32_and_bfloat16(self):
        rng = np.random.default_rng(101)
        source = rng.standard_normal((2, 2, 4, 6), dtype=np.float32) * 0.2
        weight = rng.standard_normal((24, 2, 1, 2, 2), dtype=np.float32) * 0.1
        bias = rng.standard_normal((24,), dtype=np.float32) * 0.05

        for torch_dtype, mlx_dtype, atol, rtol in (
            (torch.float32, mx.float32, FP32_ATOL, FP32_RTOL),
            (torch.bfloat16, mx.bfloat16, BF16_ATOL, BF16_RTOL),
        ):
            with self.subTest(dtype=str(torch_dtype)):
                reference = torch_nn.Conv3d(
                    2, 24, kernel_size=(1, 2, 2), stride=(1, 2, 2)
                ).to(dtype=torch_dtype)
                with torch.no_grad():
                    reference.weight.copy_(torch.from_numpy(weight).to(torch_dtype))
                    reference.bias.copy_(torch.from_numpy(bias).to(torch_dtype))

                model = vendor.model.WanModel(_tiny_model_config())
                model.patch_embedding_proj.weight = mx.array(weight.reshape(24, -1), dtype=mlx_dtype)
                model.patch_embedding_proj.bias = mx.array(bias, dtype=mlx_dtype)
                projection_dtypes = []
                model.patch_embedding_proj = _RecordingLinear(
                    model.patch_embedding_proj,
                    "patch_embedding",
                    projection_dtypes,
                )
                expected = reference(
                    torch.from_numpy(source).to(torch_dtype).unsqueeze(0)
                ).flatten(2).transpose(1, 2)
                mlx_input = mx.array(source, dtype=mx.float32)
                self.assertEqual(mlx_input.dtype, mx.float32)
                actual, grid = model._patchify(mlx_input)
                self.assertEqual(grid, (2, 2, 3))
                self.assertEqual(actual.dtype, mlx_dtype)
                self.assertEqual(
                    projection_dtypes,
                    [("patch_embedding", mlx_dtype)],
                )
                _assert_close(
                    self,
                    actual,
                    expected,
                    f"patchify {torch_dtype}",
                    atol=atol,
                    rtol=rtol,
                )

    def test_unpatchify_uses_official_coordinate_order(self):
        config = _tiny_model_config()
        model = vendor.model.WanModel(config)
        grid = (2, 2, 3)
        values = np.arange(2 * np.prod(grid) * 8, dtype=np.float32).reshape(
            2, np.prod(grid), 8
        )
        reference_self = SimpleNamespace(out_dim=2, patch_size=(1, 2, 2))
        expected = official_model.unpatchify(
            reference_self,
            torch.from_numpy(values),
            torch.tensor([grid, grid], dtype=torch.int64),
        )
        actual = model.unpatchify(mx.array(values), [grid, grid])
        for index, (mlx_value, torch_value) in enumerate(zip(actual, expected)):
            _assert_close(self, mlx_value, torch_value, f"unpatchify sample {index}")

    def test_rope_three_axes_and_precomputed_cache(self):
        head_dim = 12
        segments = (4, 4, 4)
        official_freqs = torch.cat(
            [official_model.rope_params(16, segment) for segment in segments], dim=1
        )
        mlx_freqs = mx.concatenate(
            [vendor.rope.rope_params(16, segment) for segment in segments], axis=1
        )
        _assert_close(
            self,
            mlx_freqs,
            torch.view_as_real(official_freqs),
            "RoPE FP64-angle table",
        )

        grid = (2, 2, 3)
        rng = np.random.default_rng(102)
        values = rng.standard_normal((1, 12, 2, head_dim), dtype=np.float32)
        expected = official_model.rope_apply(
            torch.from_numpy(values),
            torch.tensor([grid], dtype=torch.int64),
            official_freqs,
        )
        uncached = vendor.rope.rope_apply(mx.array(values), [grid], mlx_freqs)
        cache = vendor.rope.rope_precompute_cos_sin([grid], mlx_freqs)
        cached = vendor.rope.rope_apply(
            mx.array(values), [grid], mlx_freqs, precomputed_cos_sin=cache
        )
        self.assertEqual(uncached.dtype, mx.float32)
        self.assertEqual(cache[0].dtype, mx.float32)
        self.assertEqual(cache[1].dtype, mx.float32)
        _assert_close(self, uncached, expected, "RoPE three nonzero axes")
        _assert_close(self, cached, uncached, "RoPE cached/uncached")

    def test_time_embedding_uses_official_fp64_angles(self):
        timesteps = np.array([0, 1, 499, 999], dtype=np.int64)
        expected = official_model.sinusoidal_embedding_1d(
            8, torch.from_numpy(timesteps)
        ).float()
        actual = vendor.model.sinusoidal_embedding_1d(8, mx.array(timesteps))
        self.assertEqual(actual.dtype, mx.float32)
        _assert_close(self, actual, expected, "time sinusoid 0/1/499/999")

        reference_model = official_model.WanModel(
            model_type="t2v",
            patch_size=(1, 2, 2),
            text_len=5,
            in_dim=2,
            dim=24,
            ffn_dim=48,
            freq_dim=8,
            text_dim=12,
            out_dim=2,
            num_heads=2,
            num_layers=0,
            window_size=(-1, -1),
            qk_norm=True,
            cross_attn_norm=False,
            eps=1e-6,
        ).float().eval()
        _fill_parameters(reference_model.time_embedding, 1021)
        _fill_parameters(reference_model.time_projection, 1022)
        mlx_model = vendor.model.WanModel(_tiny_model_config())
        _copy_linear(reference_model.time_embedding[0], mlx_model.time_embedding_0)
        _copy_linear(reference_model.time_embedding[2], mlx_model.time_embedding_1)
        _copy_linear(reference_model.time_projection[1], mlx_model.time_projection)

        expected_time = reference_model.time_embedding(expected)
        expected_projection = reference_model.time_projection(expected_time)
        actual_time = mlx_model.time_embedding_1(
            mlx_model.time_embedding_act(mlx_model.time_embedding_0(actual))
        )
        actual_projection = mlx_model.time_projection(
            mlx_model.time_projection_act(actual_time)
        )
        _assert_close(self, actual_time, expected_time, "time embedding MLP")
        _assert_close(
            self,
            actual_projection,
            expected_projection,
            "time modulation projection",
        )

    def test_text_projection_casts_before_bfloat16_linears(self):
        reference_model = official_model.WanModel(
            model_type="t2v",
            patch_size=(1, 2, 2),
            text_len=5,
            in_dim=2,
            dim=24,
            ffn_dim=48,
            freq_dim=8,
            text_dim=12,
            out_dim=2,
            num_heads=2,
            num_layers=0,
            window_size=(-1, -1),
            qk_norm=True,
            cross_attn_norm=False,
            eps=1e-6,
        ).float().eval()
        _fill_parameters(reference_model.text_embedding, 1023)
        reference_model.text_embedding.to(dtype=torch.bfloat16)

        mlx_model = vendor.model.WanModel(_tiny_model_config())
        _copy_linear(reference_model.text_embedding[0], mlx_model.text_embedding_0)
        _copy_linear(reference_model.text_embedding[2], mlx_model.text_embedding_1)
        mlx_model.patch_embedding_proj.weight = mlx_model.patch_embedding_proj.weight.astype(
            mx.bfloat16
        )
        mlx_model.patch_embedding_proj.bias = mlx_model.patch_embedding_proj.bias.astype(
            mx.bfloat16
        )

        rng = np.random.default_rng(1023)
        contexts = [
            rng.standard_normal((3, 12), dtype=np.float32) * 0.1,
            rng.standard_normal((4, 12), dtype=np.float32) * 0.1,
        ]
        padded = np.stack(
            [
                np.pad(context, ((0, 5 - context.shape[0]), (0, 0)))
                for context in contexts
            ]
        )
        expected = reference_model.text_embedding(
            torch.from_numpy(padded).to(torch.bfloat16)
        )
        actual = mlx_model.embed_text([mx.array(context) for context in contexts])
        self.assertEqual(actual.dtype, mx.bfloat16)
        _assert_close(
            self,
            actual,
            expected,
            "text embedding BF16 pre-cast",
            atol=BF16_ATOL,
            rtol=BF16_RTOL,
        )

    def test_wan_norm_and_head_match_official_fp32(self):
        rng = np.random.default_rng(103)
        values = rng.standard_normal((2, 5, 24), dtype=np.float32) * 0.2

        reference_rms = official_model.WanRMSNorm(24, eps=1e-6).float().eval()
        _fill_parameters(reference_rms, 1031)
        mlx_rms = vendor.attention.WanRMSNorm(24, eps=1e-6)
        mlx_rms.weight = _to_mx(reference_rms.weight)
        _assert_close(
            self,
            mlx_rms(mx.array(values)),
            reference_rms(torch.from_numpy(values)),
            "Wan RMS norm",
        )

        reference_norm = official_model.WanLayerNorm(
            24, eps=1e-6, elementwise_affine=True
        ).float().eval()
        _fill_parameters(reference_norm, 1032)
        mlx_norm = vendor.attention.WanLayerNorm(
            24, eps=1e-6, elementwise_affine=True
        )
        mlx_norm.weight = _to_mx(reference_norm.weight)
        mlx_norm.bias = _to_mx(reference_norm.bias)
        _assert_close(
            self,
            mlx_norm(mx.array(values)),
            reference_norm(torch.from_numpy(values)),
            "Wan affine layer norm",
        )

        reference_head = official_model.Head(24, 2, (1, 2, 2), eps=1e-6).float().eval()
        _fill_parameters(reference_head, 1033)
        mlx_head = vendor.model.Head(24, 2, (1, 2, 2), eps=1e-6)
        _copy_linear(reference_head.head, mlx_head.head)
        mlx_head.modulation = _to_mx(reference_head.modulation)
        embeddings = rng.standard_normal((2, 24), dtype=np.float32) * 0.1
        _assert_close(
            self,
            mlx_head(mx.array(values), mx.array(embeddings)),
            reference_head(torch.from_numpy(values), torch.from_numpy(embeddings)),
            "Wan output Head",
        )

    def test_cross_attention_cached_and_uncached_are_equivalent(self):
        mx.random.seed(104)
        layer = vendor.attention.WanCrossAttention(24, 2, qk_norm=True, eps=1e-6)
        rng = np.random.default_rng(104)
        hidden = mx.array(rng.standard_normal((1, 3, 24), dtype=np.float32))
        context = mx.array(rng.standard_normal((1, 5, 24), dtype=np.float32))
        uncached = layer(hidden, context, context_lens=[4])
        cached = layer(
            hidden,
            context,
            context_lens=[4],
            kv_cache=layer.prepare_kv(context),
        )
        _assert_close(self, cached, uncached, "cross-KV cached/uncached")

    def test_complete_bfloat16_dit_block_attention_boundaries(self):
        reference = official_model.WanAttentionBlock(
            "t2v_cross_attn",
            dim=24,
            ffn_dim=48,
            num_heads=2,
            window_size=(-1, -1),
            qk_norm=True,
            cross_attn_norm=True,
            eps=1e-6,
        ).float().eval()
        _fill_parameters(reference, 1051, scale=0.04)
        _install_bfloat16_autocast_boundaries(reference)

        block = vendor.transformer.WanAttentionBlock(
            dim=24,
            ffn_dim=48,
            num_heads=2,
            window_size=(-1, -1),
            qk_norm=True,
            cross_attn_norm=True,
            eps=1e-6,
        )
        _copy_wan_block(reference, block)

        output_projection_dtypes = []
        block.self_attn.o = _RecordingLinear(
            block.self_attn.o, "self_o", output_projection_dtypes
        )
        block.cross_attn.o = _RecordingLinear(
            block.cross_attn.o, "cross_o", output_projection_dtypes
        )

        grid = (1, 2, 2)
        segments = (4, 4, 4)
        torch_freqs = torch.cat(
            [official_model.rope_params(16, segment) for segment in segments], dim=1
        )
        mlx_freqs = mx.concatenate(
            [vendor.rope.rope_params(16, segment) for segment in segments], axis=1
        )
        rng = np.random.default_rng(105)
        hidden = rng.standard_normal((1, 4, 24), dtype=np.float32) * 0.08
        context = rng.standard_normal((1, 5, 24), dtype=np.float32) * 0.08
        modulation = rng.standard_normal((1, 6, 24), dtype=np.float32) * 0.02

        expected = reference(
            torch.from_numpy(hidden).to(torch.bfloat16),
            torch.from_numpy(modulation),
            torch.tensor([4], dtype=torch.int64),
            torch.tensor([grid], dtype=torch.int64),
            torch_freqs,
            torch.from_numpy(context).to(torch.bfloat16),
            None,
        )

        sdpa_dtypes = []
        original_sdpa = vendor.attention.mx.fast.scaled_dot_product_attention

        def recording_sdpa(q, k, v, *args, **kwargs):
            sdpa_dtypes.append((q.dtype, k.dtype, v.dtype))
            return original_sdpa(q, k, v, *args, **kwargs)

        with mock.patch.object(
            vendor.attention.mx.fast,
            "scaled_dot_product_attention",
            side_effect=recording_sdpa,
        ):
            actual = block(
                mx.array(hidden, dtype=mx.bfloat16),
                mx.array(modulation[:, None, :, :]),
                [4],
                [grid],
                mlx_freqs,
                mx.array(context, dtype=mx.bfloat16),
            )
            cross_cache = block.cross_attn.prepare_kv(
                mx.array(context, dtype=mx.bfloat16)
            )
            cached = block(
                mx.array(hidden, dtype=mx.bfloat16),
                mx.array(modulation[:, None, :, :]),
                [4],
                [grid],
                mlx_freqs,
                mx.array(context, dtype=mx.bfloat16),
                cross_kv_cache=cross_cache,
            )

        self.assertEqual(cross_cache[0].dtype, mx.bfloat16)
        self.assertEqual(cross_cache[1].dtype, mx.bfloat16)
        self.assertEqual(len(sdpa_dtypes), 4)
        for q_dtype, k_dtype, v_dtype in sdpa_dtypes:
            self.assertEqual(q_dtype, mx.bfloat16)
            self.assertEqual(k_dtype, mx.bfloat16)
            self.assertEqual(v_dtype, mx.bfloat16)
        self.assertEqual(
            output_projection_dtypes,
            [
                ("self_o", mx.bfloat16),
                ("cross_o", mx.bfloat16),
                ("self_o", mx.bfloat16),
                ("cross_o", mx.bfloat16),
            ],
        )
        self.assertEqual(actual.dtype, mx.float32)
        _assert_close(
            self,
            actual,
            expected,
            "complete DiT block BF16 attention boundary",
            atol=BF16_ATOL,
            rtol=BF16_RTOL,
        )
        _assert_close(
            self,
            cached,
            actual,
            "complete DiT block cached/uncached",
            atol=BF16_ATOL,
            rtol=BF16_RTOL,
        )


class T5ReferenceTests(unittest.TestCase):
    def test_t5_norm_extreme_small_values_fp32_and_bfloat16(self):
        values = np.array(
            [0.0, 1e-20, -1e-20, 1e-8, -1e-8, 0.25, -0.5, 1.0] * 3,
            dtype=np.float32,
        ).reshape(1, 1, 24)
        for torch_dtype, mlx_dtype, atol, rtol in (
            (torch.float32, mx.float32, FP32_ATOL, FP32_RTOL),
            (torch.bfloat16, mx.bfloat16, BF16_ATOL, BF16_RTOL),
        ):
            with self.subTest(dtype=str(torch_dtype)):
                reference = official_t5.T5LayerNorm(24, eps=1e-6).float().eval()
                _fill_parameters(reference, 201)
                reference = reference.to(dtype=torch_dtype)
                layer = vendor.text.T5LayerNorm(24, eps=1e-6)
                layer.weight = _to_mx(reference.weight, dtype=mlx_dtype)
                expected = reference(torch.from_numpy(values).to(torch_dtype))
                actual = layer(mx.array(values, dtype=mlx_dtype))
                self.assertEqual(actual.dtype, mlx_dtype)
                _assert_close(
                    self,
                    actual,
                    expected,
                    f"T5 norm tiny {torch_dtype}",
                    atol=atol,
                    rtol=rtol,
                )

    def test_t5_attention_masks_posbias_fp32_and_bfloat16(self):
        rng = np.random.default_rng(202)
        values = rng.standard_normal((2, 5, 24), dtype=np.float32) * 0.1
        pos_bias = rng.standard_normal((1, 2, 5, 5), dtype=np.float32) * 0.02
        masks = (
            np.array([[1, 1, 1, 1, 0], [1, 1, 1, 0, 0]], dtype=np.int32),
            np.tril(np.ones((2, 5, 5), dtype=np.int32)),
        )
        for torch_dtype, mlx_dtype, atol, rtol in (
            (torch.float32, mx.float32, FP32_ATOL, FP32_RTOL),
            (torch.bfloat16, mx.bfloat16, BF16_ATOL, BF16_RTOL),
        ):
            reference = official_t5.T5Attention(24, 24, 2, dropout=0.0).float().eval()
            _fill_parameters(reference, 2021)
            reference = reference.to(dtype=torch_dtype)
            layer = vendor.text.T5Attention(24, 24, 2, dropout=0.0)
            _copy_t5_attention(reference, layer)
            for mask in masks:
                with self.subTest(dtype=str(torch_dtype), mask_ndim=mask.ndim):
                    torch_values = torch.from_numpy(values).to(torch_dtype)
                    torch_bias = torch.from_numpy(pos_bias).to(torch_dtype)
                    expected = reference(
                        torch_values,
                        mask=torch.from_numpy(mask),
                        pos_bias=torch_bias,
                    )
                    actual = layer(
                        mx.array(values, dtype=mlx_dtype),
                        mask=mx.array(mask),
                        pos_bias=mx.array(pos_bias, dtype=mlx_dtype),
                    )
                    self.assertEqual(actual.dtype, mlx_dtype)
                    _assert_close(
                        self,
                        actual,
                        expected,
                        f"T5 attention {torch_dtype} mask{mask.ndim}",
                        atol=atol,
                        rtol=rtol,
                    )

    def test_t5_complete_block_fp32_and_bfloat16(self):
        rng = np.random.default_rng(203)
        values = rng.standard_normal((2, 5, 24), dtype=np.float32) * 0.08
        pos_bias = rng.standard_normal((1, 2, 5, 5), dtype=np.float32) * 0.015
        masks = (
            np.array([[1, 1, 1, 1, 0], [1, 1, 1, 0, 0]], dtype=np.int32),
            np.tril(np.ones((2, 5, 5), dtype=np.int32)),
        )
        for torch_dtype, mlx_dtype, atol, rtol in (
            (torch.float32, mx.float32, FP32_ATOL, FP32_RTOL),
            (torch.bfloat16, mx.bfloat16, BF16_ATOL, BF16_RTOL),
        ):
            reference = official_t5.T5SelfAttention(
                24, 24, 48, 2, 8, shared_pos=True, dropout=0.0
            ).float().eval()
            _fill_parameters(reference, 2031)
            reference = reference.to(dtype=torch_dtype)
            block = vendor.text.T5SelfAttentionBlock(
                24, 24, 48, 2, 8, shared_pos=True
            )
            _copy_t5_block(reference, block)
            for mask in masks:
                with self.subTest(dtype=str(torch_dtype), mask_ndim=mask.ndim):
                    expected = reference(
                        torch.from_numpy(values).to(torch_dtype),
                        mask=torch.from_numpy(mask),
                        pos_bias=torch.from_numpy(pos_bias).to(torch_dtype),
                    )
                    actual = block(
                        mx.array(values, dtype=mlx_dtype),
                        mask=mx.array(mask),
                        pos_bias=mx.array(pos_bias, dtype=mlx_dtype),
                    )
                    self.assertEqual(actual.dtype, mlx_dtype)
                    _assert_close(
                        self,
                        actual,
                        expected,
                        f"T5 block {torch_dtype} mask{mask.ndim}",
                        atol=atol,
                        rtol=rtol,
                    )


def _official_unipc(num_steps: int):
    scheduler = official_scheduler.FlowUniPCMultistepScheduler(
        num_train_timesteps=1000,
        solver_order=2,
        prediction_type="flow_prediction",
        shift=1.0,
        use_dynamic_shifting=False,
        thresholding=False,
        predict_x0=True,
        solver_type="bh2",
        lower_order_final=True,
        disable_corrector=[],
        solver_p=None,
        final_sigmas_type="zero",
    )
    scheduler.set_timesteps(num_steps, device="cpu", shift=8.0)
    return scheduler


def _vendor_unipc(num_steps: int):
    scheduler = vendor.scheduler.FlowUniPCScheduler(
        num_train_timesteps=1000,
        solver_order=2,
        lower_order_final=True,
        disable_corrector=[],
        use_corrector=True,
    )
    scheduler.set_timesteps(num_steps, shift=8.0)
    return scheduler


class UniPCReferenceTests(unittest.TestCase):
    def _compare_schedule(self, num_steps: int):
        reference = _official_unipc(num_steps)
        actual = _vendor_unipc(num_steps)
        reference_sigmas = _torch_numpy(reference.sigmas)
        actual_sigmas = np.asarray(actual.sigmas).astype(np.float32)
        np.testing.assert_allclose(
            actual_sigmas, reference_sigmas, atol=SIGMA_ATOL, rtol=0.0
        )
        np.testing.assert_array_equal(
            np.asarray(actual.timesteps), reference.timesteps.cpu().numpy()
        )

        rng = np.random.default_rng(300 + num_steps)
        initial = rng.standard_normal((1, 2, 2, 2), dtype=np.float32)
        model_outputs = [
            rng.standard_normal(initial.shape, dtype=np.float32) * 0.1
            for _ in range(num_steps)
        ]
        torch_sample = torch.from_numpy(initial.copy())
        mlx_sample = mx.array(initial)
        first_run = []
        max_abs = 0.0
        max_relative = 0.0
        for index, output in enumerate(model_outputs):
            torch_sample = reference.step(
                torch.from_numpy(output), reference.timesteps[index], torch_sample
            ).prev_sample
            mlx_sample = actual.step(
                mx.array(output), actual.timesteps[index], mlx_sample
            )
            first_run.append(np.asarray(mlx_sample).astype(np.float32))
            absolute, relative = _assert_close(
                self,
                mlx_sample,
                torch_sample,
                f"UniPC {num_steps} step {index}",
                report=False,
            )
            max_abs = max(max_abs, absolute)
            max_relative = max(max_relative, relative)

        print(
            f"UniPC {num_steps} steps: maxabs={max_abs:.9g} "
            f"relative={max_relative:.9g} mlx_dtype={mlx_sample.dtype} "
            f"torch_dtype={torch_sample.dtype} finite=true"
        )

        repeated = _vendor_unipc(num_steps)
        repeated_sample = mx.array(initial)
        for index, output in enumerate(model_outputs):
            repeated_sample = repeated.step(
                mx.array(output), repeated.timesteps[index], repeated_sample
            )
            _assert_close(
                self,
                repeated_sample,
                first_run[index],
                f"UniPC fresh scheduler {num_steps} step {index}",
                report=False,
            )

    def test_unipc_50_steps_shift8_order2_bh2(self):
        self._compare_schedule(50)

    def test_unipc_short_4_steps_shift8_order2_bh2(self):
        self._compare_schedule(4)


if __name__ == "__main__":
    unittest.main(verbosity=2)
