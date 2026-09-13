"""Independent Torch-CPU reference checks for the Wan2.1 MLX VAE decoder.

The test deliberately loads exactly two files named by the environment. It does
not add the upstream repository to sys.path or import any upstream package.
"""

import importlib.util
import os
from pathlib import Path
import unittest


os.environ.setdefault("CUDA_VISIBLE_DEVICES", "")
os.environ.setdefault("OMP_NUM_THREADS", "1")
os.environ.setdefault("MKL_NUM_THREADS", "1")
os.environ.setdefault("VECLIB_MAXIMUM_THREADS", "1")

import numpy as np
import torch
import torch.nn.functional as torch_functional
import mlx.core as mx


torch.set_num_threads(1)
torch.set_num_interop_threads(1)
torch.set_default_device("cpu")
mx.set_default_device(mx.cpu)

ATOL = 3e-4
RTOL = 3e-4


def _required_file(variable: str, directory_filename: str | None = None) -> Path:
    value = os.environ.get(variable)
    if not value:
        raise RuntimeError(f"{variable} must name the frozen source file")
    path = Path(value).expanduser().resolve()
    if path.is_dir() and directory_filename is not None:
        path = path / directory_filename
    if not path.is_file():
        raise RuntimeError(f"{variable} does not name a file: {path}")
    return path


def _load_file(module_name: str, path: Path):
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot create import spec for {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


REFERENCE_PATH = _required_file("D_WAN_REFERENCE_VAE")
VENDOR_PATH = _required_file("D_WAN_VENDOR", "vae.py")
reference = _load_file("d_wan_official_vae_reference", REFERENCE_PATH)
vendor = _load_file("d_wan_mlx_vae_under_test", VENDOR_PATH)


class _TinyWanVAE(vendor.WanVAE):
    """Small decoder fixture that inherits the production decode methods."""

    def __init__(self):
        vendor.nn.Module.__init__(self)
        self.z_dim = 16
        self.mean = mx.array(vendor.VAE_MEAN, dtype=mx.float32)
        self.std = mx.array(vendor.VAE_STD, dtype=mx.float32)
        self.inv_std = 1.0 / self.std
        self.conv2 = vendor.CausalConv3d(16, 16, 1)
        self.decoder = vendor.Decoder3d(
            dim=2,
            z_dim=16,
            dim_mult=[1, 1, 1, 1],
            num_res_blocks=0,
            temporal_upsample=[True, True, False],
        )


def _torch_numpy(value: torch.Tensor) -> np.ndarray:
    return value.detach().to(device="cpu", dtype=torch.float32).numpy()


def _mlx(value: torch.Tensor, axes=None):
    array = _torch_numpy(value)
    if axes is not None:
        array = np.transpose(array, axes)
    return mx.array(array, dtype=mx.float32)


def _copy_causal_conv(torch_layer, mlx_layer) -> None:
    # Torch O,I,D,H,W -> MLX O,D,H,W,I.
    mlx_layer.weight = _mlx(torch_layer.weight, (0, 2, 3, 4, 1))
    mlx_layer.bias = _mlx(torch_layer.bias)


def _copy_conv2d(torch_layer, mlx_layer) -> None:
    # Torch O,I,H,W -> MLX O,H,W,I.
    mlx_layer.weight = _mlx(torch_layer.weight, (0, 2, 3, 1))
    mlx_layer.bias = _mlx(torch_layer.bias)


def _copy_rms(torch_layer, mlx_layer) -> None:
    mlx_layer.gamma = _mlx(torch_layer.gamma)


def _copy_residual(torch_layer, mlx_layer) -> None:
    _copy_rms(torch_layer.residual[0], mlx_layer.residual[0])
    _copy_causal_conv(torch_layer.residual[2], mlx_layer.residual[2])
    _copy_rms(torch_layer.residual[3], mlx_layer.residual[3])
    _copy_causal_conv(torch_layer.residual[6], mlx_layer.residual[6])
    if mlx_layer.shortcut is not None:
        _copy_causal_conv(torch_layer.shortcut, mlx_layer.shortcut)


def _copy_attention(torch_layer, mlx_layer) -> None:
    _copy_rms(torch_layer.norm, mlx_layer.norm)
    _copy_conv2d(torch_layer.to_qkv, mlx_layer.to_qkv)
    _copy_conv2d(torch_layer.proj, mlx_layer.proj)


def _copy_resample(torch_layer, mlx_layer) -> None:
    _copy_conv2d(torch_layer.resample[1], mlx_layer.resample[1])
    if mlx_layer.mode in ("upsample3d", "downsample3d"):
        _copy_causal_conv(torch_layer.time_conv, mlx_layer.time_conv)


def _copy_decoder(torch_layer, mlx_layer) -> None:
    _copy_causal_conv(torch_layer.conv1, mlx_layer.conv1)
    for torch_child, mlx_child in zip(torch_layer.middle, mlx_layer.middle):
        if isinstance(torch_child, reference.ResidualBlock):
            _copy_residual(torch_child, mlx_child)
        else:
            _copy_attention(torch_child, mlx_child)
    for torch_child, mlx_child in zip(torch_layer.upsamples, mlx_layer.upsamples):
        if isinstance(torch_child, reference.ResidualBlock):
            _copy_residual(torch_child, mlx_child)
        else:
            _copy_resample(torch_child, mlx_child)
    _copy_rms(torch_layer.head[0], mlx_layer.head[0])
    _copy_causal_conv(torch_layer.head[2], mlx_layer.head[2])


def _fill_reference_parameters(module, seed: int) -> None:
    generator = torch.Generator(device="cpu")
    generator.manual_seed(seed)
    with torch.no_grad():
        for parameter in module.parameters():
            parameter.uniform_(-0.075, 0.075, generator=generator)


def _assert_close(
    case: unittest.TestCase,
    actual,
    expected: torch.Tensor | np.ndarray,
    label: str,
) -> float:
    actual_np = np.asarray(actual, dtype=np.float32)
    expected_np = (
        _torch_numpy(expected)
        if isinstance(expected, torch.Tensor)
        else np.asarray(expected, dtype=np.float32)
    )
    case.assertEqual(actual_np.shape, expected_np.shape, label)
    max_abs = float(np.max(np.abs(actual_np - expected_np), initial=0.0))
    print(f"{label}: max_abs_error={max_abs:.9g}")
    np.testing.assert_allclose(actual_np, expected_np, atol=ATOL, rtol=RTOL)
    return max_abs


def _reference_cached_conv(layer, chunks):
    cache = None
    outputs = []
    for chunk in chunks:
        next_cache = chunk[:, :, -reference.CACHE_T :].clone()
        if next_cache.shape[2] < reference.CACHE_T and cache is not None:
            next_cache = torch.cat([cache[:, :, -1:], next_cache], dim=2)
        outputs.append(layer(chunk, cache))
        cache = next_cache
    return outputs


def _vendor_cached_conv(layer, chunks):
    cache = None
    outputs = []
    for chunk in chunks:
        next_cache = chunk[:, :, -vendor.CACHE_T :]
        if next_cache.shape[2] < vendor.CACHE_T and cache is not None:
            next_cache = mx.concatenate([cache[:, :, -1:], next_cache], axis=2)
        outputs.append(layer(chunk, cache_x=cache))
        cache = next_cache
    return outputs


class WanVAEReferenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.reference_vae = reference.WanVAE_(
            dim=2,
            z_dim=16,
            dim_mult=[1, 1, 1, 1],
            num_res_blocks=0,
            attn_scales=[],
            temperal_downsample=[False, True, True],
            dropout=0.0,
        ).to(device="cpu", dtype=torch.float32).eval()
        _fill_reference_parameters(cls.reference_vae, 20260914)

        # Avoid constructing the production-width decoder solely for a fixture.
        cls.vendor_vae = _TinyWanVAE()
        _copy_causal_conv(cls.reference_vae.conv2, cls.vendor_vae.conv2)
        _copy_decoder(cls.reference_vae.decoder, cls.vendor_vae.decoder)
        cls.scale = (
            torch.tensor(vendor.VAE_MEAN, dtype=torch.float32),
            1.0 / torch.tensor(vendor.VAE_STD, dtype=torch.float32),
        )

    def test_rms_norm_matches_f_normalize_for_zero_and_tiny_inputs(self):
        layer = vendor.RMS_norm(2, images=False)
        tiny = np.array([0.0, 1e-14, -1e-14, 0.0], dtype=np.float32).reshape(
            1, 2, 2, 1, 1
        )
        actual = layer(mx.array(tiny))
        expected = (
            torch_functional.normalize(torch.from_numpy(tiny), dim=1)
            * np.sqrt(2.0)
        )
        _assert_close(self, actual, expected, "RMS_norm tiny/zero")

    def test_causal_conv_cache_first_and_following_chunks(self):
        torch_layer = reference.CausalConv3d(2, 3, 3, padding=1).float().eval()
        _fill_reference_parameters(torch_layer, 11)
        mlx_layer = vendor.CausalConv3d(2, 3, 3, padding=1)
        _copy_causal_conv(torch_layer, mlx_layer)
        rng = np.random.default_rng(12)
        arrays = [
            rng.standard_normal((1, 2, 1, 2, 2), dtype=np.float32)
            for _ in range(3)
        ]
        torch_outputs = _reference_cached_conv(
            torch_layer, [torch.from_numpy(value) for value in arrays]
        )
        mlx_outputs = _vendor_cached_conv(
            mlx_layer, [mx.array(value) for value in arrays]
        )
        for index, (actual, expected) in enumerate(zip(mlx_outputs, torch_outputs)):
            _assert_close(self, actual, expected, f"CausalConv3d chunk {index}")

    def test_upsample_resample_sentinel_and_following_cache(self):
        torch_layer = reference.Resample(2, "upsample3d").float().eval()
        _fill_reference_parameters(torch_layer, 21)
        mlx_layer = vendor.Resample(2, "upsample3d")
        _copy_resample(torch_layer, mlx_layer)
        rng = np.random.default_rng(22)
        torch_cache = [None]
        mlx_cache = [None]
        for index in range(3):
            value = rng.standard_normal((1, 2, 1, 2, 2), dtype=np.float32)
            expected = torch_layer(
                torch.from_numpy(value), feat_cache=torch_cache, feat_idx=[0]
            )
            actual = mlx_layer(mx.array(value), feat_cache=mlx_cache, feat_idx=[0])
            self.assertEqual(actual.shape[2], 1 if index == 0 else 2)
            _assert_close(self, actual, expected, f"Resample upsample3d chunk {index}")

    def test_residual_block_cache_first_and_following_chunks(self):
        torch_layer = reference.ResidualBlock(2, 3).float().eval()
        _fill_reference_parameters(torch_layer, 31)
        mlx_layer = vendor.ResidualBlock(2, 3)
        _copy_residual(torch_layer, mlx_layer)
        rng = np.random.default_rng(32)
        torch_cache = [None, None]
        mlx_cache = [None, None]
        for index in range(3):
            value = rng.standard_normal((1, 2, 1, 2, 2), dtype=np.float32)
            expected = torch_layer(
                torch.from_numpy(value), feat_cache=torch_cache, feat_idx=[0]
            )
            actual = mlx_layer(mx.array(value), feat_cache=mlx_cache, feat_idx=[0])
            _assert_close(self, actual, expected, f"ResidualBlock chunk {index}")

    def _latent(self, temporal: int, seed: int = 41) -> np.ndarray:
        return np.random.default_rng(seed).standard_normal(
            (1, 16, temporal, 1, 1), dtype=np.float32
        )

    def _reference_decode(self, latent: np.ndarray) -> torch.Tensor:
        with torch.no_grad():
            return self.reference_vae.decode(
                torch.from_numpy(latent), self.scale
            ).clamp(-1.0, 1.0)

    def test_decoder_matches_all_reference_frames_for_1_2_5_latents(self):
        for temporal in (1, 2, 5):
            latent = self._latent(temporal, seed=40 + temporal)
            expected = self._reference_decode(latent)
            actual = self.vendor_vae.decode(mx.array(latent))
            self.assertEqual(actual.dtype, mx.float32)
            self.assertEqual(actual.shape, (1, 3, 4 * temporal - 3, 8, 8))
            _assert_close(self, actual, expected, f"Decoder3d T={temporal}")

    def test_decode_chunks_match_decode_and_do_not_reuse_cache(self):
        latent = mx.array(self._latent(5, seed=51))
        baseline = self.vendor_vae.decode(latent)
        chunks = list(self.vendor_vae.decode_chunks(latent))
        self.assertEqual([chunk.shape[2] for chunk in chunks], [1, 4, 4, 4, 4])
        combined = mx.concatenate(chunks, axis=2)
        _assert_close(self, combined, np.asarray(baseline), "decode_chunks combination")

        repeated = self.vendor_vae.decode(latent)
        _assert_close(self, repeated, np.asarray(baseline), "decode repeated call")

        interrupted = self.vendor_vae.decode_chunks(latent)
        first = next(interrupted)
        self.assertEqual(first.shape[2], 1)
        interrupted.close()
        self.assertIsNone(interrupted.gi_frame)
        after_close = self.vendor_vae.decode(latent)
        _assert_close(self, after_close, np.asarray(baseline), "decode after early close")

    def test_invalid_inputs_and_unaccepted_tiling_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "rank-5"):
            self.vendor_vae.decode(mx.zeros((1, 16, 1, 1)))
        with self.assertRaisesRegex(ValueError, "16 latent channels"):
            self.vendor_vae.decode(mx.zeros((1, 15, 1, 1, 1)))
        with self.assertRaisesRegex(ValueError, "at least one latent frame"):
            self.vendor_vae.decode(mx.zeros((1, 16, 0, 1, 1)))
        with self.assertRaisesRegex(ValueError, "at least one latent frame"):
            self.vendor_vae.decode(mx.zeros((1, 16, 0, 1, 1)))
        for bad in (np.nan, np.inf, -np.inf):
            latent = self._latent(1, seed=61)
            latent[0, 0, 0, 0, 0] = bad
            with self.assertRaisesRegex(ValueError, "finite latent values"):
                self.vendor_vae.decode(mx.array(latent))
        with self.assertRaisesRegex(NotImplementedError, "not passed numerical acceptance"):
            self.vendor_vae.decode_tiled(mx.array(self._latent(1)))


if __name__ == "__main__":
    unittest.main(verbosity=2)
