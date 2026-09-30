"""Offline gates around the pinned official AceStepHandler; no model or code download."""

from __future__ import annotations

from pathlib import Path
import hashlib
import shutil
from contextlib import contextmanager
from typing import Any
from unittest import mock

from d_audio_ace_contract import ACEContractError, verify_manifest_files, verify_source_files


def _digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def prepare_runtime_view(run: Path, model: Path, vendor: Path,
                         manifest: dict[str, Any]) -> Path:
    """Create a private checkpoint namespace; never execute checkpoint Python."""
    verify_manifest_files(manifest, model)
    verify_source_files(manifest, vendor)
    view = run / "view"
    view.mkdir(mode=0o700)
    declared_source = {entry["path"]: entry for entry in manifest["sourceFiles"]}
    for entry in manifest["files"]:
        relative = entry["path"]
        source = model / relative
        target = view / relative
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        if source.suffix == ".py":
            continue
        if source.suffix in (".safetensors", ".bin", ".pt", ".pth"):
            target.symlink_to(source)
        else:
            shutil.copyfile(source, target, follow_symlinks=False)
            if _digest(target) != entry["sha256"]:
                raise ACEContractError("ACE private config copy changed", "configuration")
    prefix = "acestep/models/xl_sft/"
    model_code = [entry for path, entry in declared_source.items()
                  if path.startswith(prefix) and path.endswith(".py")
                  and Path(path).name != "__init__.py"]
    required = {prefix + name for name in ("modeling_acestep_v15_xl_base.py",
                                           "configuration_acestep_v15.py",
                                           "apg_guidance.py")}
    if not required <= {item["path"] for item in model_code}:
        raise ACEContractError("ACE official XL model code is absent", "configuration")
    target_dir = view / "checkpoints" / "acestep-v15-xl-sft"
    for entry in model_code:
        source = vendor / entry["path"]
        target = target_dir / Path(entry["path"]).name
        shutil.copyfile(source, target, follow_symlinks=False)
        if _digest(target) != entry["sha256"]:
            raise ACEContractError("ACE official model code copy changed", "configuration")
    verify_runtime_view(view, model, vendor, manifest)
    return view


def verify_runtime_view(view: Path, model: Path, vendor: Path,
                        manifest: dict[str, Any]) -> None:
    expected: set[str] = set()
    for entry in manifest["files"]:
        relative = entry["path"]
        if relative.endswith(".py"):
            continue
        target = view / relative
        expected.add(relative)
        if Path(relative).suffix in (".safetensors", ".bin", ".pt", ".pth"):
            if not target.is_symlink() or target.readlink() != model / relative:
                raise ACEContractError("ACE weight view link changed", "configuration")
        elif target.is_symlink():
            raise ACEContractError("ACE config view became a link", "configuration")
        if not target.is_file() or target.stat().st_size != entry["size"] or _digest(target) != entry["sha256"]:
            raise ACEContractError("ACE private checkpoint view changed", "configuration")
    for entry in manifest["sourceFiles"]:
        relative = entry["path"]
        if (relative.startswith("acestep/models/xl_sft/") and relative.endswith(".py")
                and Path(relative).name != "__init__.py"):
            target_relative = "checkpoints/acestep-v15-xl-sft/" + Path(relative).name
            target = view / target_relative
            expected.add(target_relative)
            if target.is_symlink() or not target.is_file() or _digest(target) != entry["sha256"]:
                raise ACEContractError("ACE official model code view changed", "configuration")
    observed = {path.relative_to(view).as_posix() for path in view.rglob("*") if path.is_file() or path.is_symlink()}
    if observed != expected:
        raise ACEContractError("ACE private view has unapproved files", "configuration")
    verify_manifest_files(manifest, model)
    verify_source_files(manifest, vendor)


@contextmanager
def local_only_loading(view: Path):
    """Constrain the three official pretrained loaders to private local checkpoints."""
    from transformers import AutoModel, AutoTokenizer
    from diffusers.models import AutoencoderOobleck

    checkpoint = (view / "checkpoints").resolve()
    xl = checkpoint / "acestep-v15-xl-sft"
    vae = checkpoint / "vae"
    embedding = checkpoint / "Qwen3-Embedding-0.6B"

    def restricted(original, allowed):
        def load(path, *args, **kwargs):
            if Path(path).resolve() not in allowed or kwargs.get("local_files_only") is False:
                raise ACEContractError("ACE pretrained loader left the private offline view", "configuration")
            kwargs["local_files_only"] = True
            return original(path, *args, **kwargs)
        return load

    model_loader = AutoModel.from_pretrained
    tokenizer_loader = AutoTokenizer.from_pretrained
    vae_loader = AutoencoderOobleck.from_pretrained
    with (mock.patch.object(AutoModel, "from_pretrained",
                            side_effect=restricted(model_loader, {xl, embedding})),
          mock.patch.object(AutoTokenizer, "from_pretrained",
                            side_effect=restricted(tokenizer_loader, {embedding})),
          mock.patch.object(AutoencoderOobleck, "from_pretrained",
                            side_effect=restricted(vae_loader, {vae}))):
        yield


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
        verify_runtime_view(self._ace_runtime_root, self._ace_model_root,
                            self._ace_vendor_root, self._ace_manifest)
        return None

    @staticmethod
    def _sync_model_code_if_needed(config_path: str, checkpoint_path: Path) -> None:
        from acestep.model_downloader import _check_code_mismatch, _CHECKPOINT_TO_VARIANT

        if (config_path != "acestep-v15-xl-sft"
                or _CHECKPOINT_TO_VARIANT.get(config_path) != "xl_sft"
                or _check_code_mismatch(config_path, checkpoint_path)):
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


def make_handler(vendor_root: Path, manifest: dict[str, Any], view: Path, model: Path):
    """Import official source only after manifest, offline and path checks."""
    verify_source_files(manifest, vendor_root)
    verify_runtime_view(view, model, vendor_root, manifest)
    import sys
    sys.path.insert(0, str(vendor_root))
    from acestep.handler import AceStepHandler

    class OfflineACEHandler(OfflineACEMixin, AceStepHandler):
        pass

    handler = OfflineACEHandler()
    handler._ace_manifest = manifest
    handler._ace_runtime_root = view
    handler._ace_model_root = model
    handler._ace_vendor_root = vendor_root
    return handler


def forbid_torch_fallback(handler: Any) -> None:
    if not handler.use_mlx_dit or handler.mlx_decoder is None or not handler.use_mlx_vae or handler.mlx_vae is None:
        raise ACEContractError("ACE MLX backends not ready", "configuration")

    def fail(*_args: Any, **_kwargs: Any):
        raise ACEContractError("ACE PyTorch fallback invoked after MLX conversion", "engine")

    for obj, method in ((handler.model, "generate_audio"),
                        (handler.vae, "encode"), (handler.vae, "decode")):
        setattr(obj, method, fail)
