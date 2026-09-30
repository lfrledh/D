"""Offline gates around the pinned official AceStepHandler; no model or code download."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from d_audio_ace_contract import ACEContractError, PROFILE


class OfflineACEMixin:
    """Override official convenience fallbacks that would change the admitted run."""

    _ace_manifest: dict[str, Any]
    _ace_runtime_root: Path

    def _ensure_models_present(self, *, checkpoint_path: Path, config_path: str,
                               prefer_source: str | None, vae_variant: str | None = None):
        if config_path != "acestep-v15-xl-sft" or checkpoint_path != self._ace_runtime_root / "checkpoints":
            return "ACE runtime view does not match pinned XL SFT profile", False
        if prefer_source is not None:
            return "ACE offline runtime refuses model source fallback", False
        if not (checkpoint_path / "acestep-v15-xl-sft").is_dir():
            return "ACE XL SFT runtime checkpoint is absent", False
        if not (checkpoint_path / "vae").is_dir() or not (checkpoint_path / "Qwen3-Embedding-0.6B").is_dir():
            return "ACE shared VAE or embedding checkpoint is absent", False
        for entry in self._ace_manifest["files"]:
            if not (self._ace_runtime_root / entry["path"]).is_file():
                return f"ACE prepared runtime view omits {entry['path']}", False
        return None

    @staticmethod
    def _sync_model_code_if_needed(config_path: str, checkpoint_path: Path) -> None:
        from acestep.model_downloader import _check_code_mismatch

        if config_path != "acestep-v15-xl-sft" or _check_code_mismatch(config_path, checkpoint_path):
            raise ACEContractError("ACE prepared model code is absent or differs from pinned source", "configuration")

    def _resolve_initialize_device(self, requested_device: str) -> str:
        if requested_device != "mps":
            raise ACEContractError("ACE XL SFT profile requires explicit MPS", "configuration")
        import torch
        if not torch.backends.mps.is_available():
            raise ACEContractError("ACE MPS device is unavailable; no CPU fallback", "configuration")
        return "mps"

    def _initialize_mlx_backends(self, *, device: str, use_mlx_dit: bool,
                                  mlx_compile_requested: bool):
        if device != "mps" or not use_mlx_dit:
            raise ACEContractError("ACE requires MLX DiT and MPS", "configuration")
        dit, vae = super()._initialize_mlx_backends(
            device=device, use_mlx_dit=use_mlx_dit,
            mlx_compile_requested=mlx_compile_requested)
        if not dit.startswith("Active") or not vae.startswith("Active"):
            raise ACEContractError("ACE MLX DiT or VAE conversion failed; PyTorch fallback forbidden", "configuration")
        if not self.use_mlx_dit or self.mlx_decoder is None or not self.use_mlx_vae or self.mlx_vae is None:
            raise ACEContractError("ACE MLX DiT/VAE flags are not ready", "configuration")
        return dit, vae


def make_handler(runtime_root: Path, manifest: dict[str, Any]):
    """Import official source only after manifest, offline and path checks."""
    if not (runtime_root / "acestep" / "handler.py").is_file():
        raise ACEContractError("ACE pinned source runtime is not deployed", "configuration")
    import sys
    sys.path.insert(0, str(runtime_root))
    from acestep.handler import AceStepHandler

    class OfflineACEHandler(OfflineACEMixin, AceStepHandler):
        pass

    handler = OfflineACEHandler()
    handler._ace_manifest = manifest
    handler._ace_runtime_root = runtime_root
    return handler


def forbid_torch_fallback(handler: Any) -> None:
    if not handler.use_mlx_dit or handler.mlx_decoder is None or not handler.use_mlx_vae or handler.mlx_vae is None:
        raise ACEContractError("ACE MLX backends not ready", "configuration")

    def fail(*_args: Any, **_kwargs: Any):
        raise ACEContractError("ACE PyTorch fallback invoked after MLX conversion", "engine")

    for obj, method in ((handler.model, "generate_audio"),
                        (handler.vae, "encode"), (handler.vae, "decode")):
        setattr(obj, method, fail)
