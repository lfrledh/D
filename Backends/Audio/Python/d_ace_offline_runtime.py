"""Offline gates around the pinned official AceStepHandler; no model or code download."""

from __future__ import annotations

from pathlib import Path
import hashlib
import shutil
from typing import Any

from d_audio_ace_contract import ACEContractError, VerificationRecord, verify_manifest_files, verify_source_files


def _digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def prepare_runtime_view(run: Path, model: Path, vendor: Path,
                         manifest: dict[str, Any], record: VerificationRecord | None = None) -> Path:
    """Create a private checkpoint namespace; never execute checkpoint Python."""
    if record is None:
        verify_manifest_files(manifest, model)
        verify_source_files(manifest, vendor)
    else:
        record.check(manifest, model=model, vendor=vendor)
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
    verify_runtime_view(view, model, vendor, manifest, record)
    return view


def verify_runtime_view(view: Path, model: Path, vendor: Path,
                        manifest: dict[str, Any], record: VerificationRecord | None = None) -> None:
    if view.is_symlink() or not view.is_dir():
        raise ACEContractError("ACE private view root changed", "configuration")
    if record is not None:
        record.check(manifest, model=model, vendor=vendor, view=view)
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
        if not target.is_file() or target.stat().st_size != entry["size"]:
            raise ACEContractError("ACE private checkpoint view changed", "configuration")
        if not target.is_symlink() and _digest(target) != entry["sha256"]:
            raise ACEContractError("ACE private config copy changed", "configuration")
    for entry in manifest["sourceFiles"]:
        relative = entry["path"]
        if (relative.startswith("acestep/models/xl_sft/") and relative.endswith(".py")
                and Path(relative).name != "__init__.py"):
            target_relative = "checkpoints/acestep-v15-xl-sft/" + Path(relative).name
            target = view / target_relative
            expected.add(target_relative)
            if target.is_symlink() or not target.is_file() or _digest(target) != entry["sha256"]:
                raise ACEContractError("ACE official model code view changed", "configuration")
    observed = set()
    observed_dirs = set()
    for path in view.rglob("*"):
        if path.is_symlink() or path.is_file():
            observed.add(path.relative_to(view).as_posix())
        elif path.is_dir():
            observed_dirs.add(path.relative_to(view).as_posix())
        else:
            raise ACEContractError("ACE private view contains unknown entry", "configuration")
        if path != view and path.parent != view and path.parent.is_symlink():
            raise ACEContractError("ACE private view parent became a link", "configuration")
    if observed != expected:
        raise ACEContractError("ACE private view has unapproved files", "configuration")
    expected_dirs = set()
    for relative in expected:
        parent = Path(relative).parent
        while parent != Path("."):
            expected_dirs.add(parent.as_posix())
            parent = parent.parent
    if observed_dirs != expected_dirs:
        raise ACEContractError("ACE private view has unapproved directories", "configuration")
    if record is None:
        verify_manifest_files(manifest, model)
        verify_source_files(manifest, vendor)


class OfflineACEMixin:
    """Override official convenience fallbacks that would change the admitted run."""

    _ace_manifest: dict[str, Any]
    _ace_runtime_root: Path
    _ace_record: VerificationRecord

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
                            self._ace_vendor_root, self._ace_manifest, self._ace_record)
        return None

    def _sync_model_code_if_needed(self, config_path: str, checkpoint_path: Path) -> None:
        if config_path != "acestep-v15-xl-sft" or checkpoint_path != self._ace_runtime_root / "checkpoints":
            raise ACEContractError("ACE prepared model code is absent or differs from pinned source", "configuration")
        verify_runtime_view(self._ace_runtime_root, self._ace_model_root,
                            self._ace_vendor_root, self._ace_manifest, self._ace_record)

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
        release_torch_decoder(self)
        return dit, vae


def release_torch_decoder(handler: Any) -> None:
    """Release only the converted Torch DiT decoder after MLX materialization."""
    import mlx.core as mx
    from mlx.utils import tree_flatten
    if handler.mlx_decoder is None or not handler.use_mlx_dit:
        raise ACEContractError("ACE MLX decoder is unavailable", "configuration")
    parameters = handler.mlx_decoder.parameters()
    mx.eval(parameters)
    arrays = [array for _, array in tree_flatten(parameters)]
    if not arrays:
        raise ACEContractError("ACE converted DiT has no parameters", "configuration")
    for array in arrays:
        if array.dtype != mx.float32:
            raise ACEContractError("ACE converted DiT precision is not float32", "configuration")
    if handler.model is None or handler.model.decoder is None:
        raise ACEContractError("ACE Torch decoder is absent before release", "configuration")
    handler.model.decoder = None


def make_handler(vendor_root: Path, manifest: dict[str, Any], view: Path, model: Path,
                 record: VerificationRecord | None = None):
    """Import official source only after manifest, offline and path checks."""
    if record is None:
        verify_source_files(manifest, vendor_root)
    else:
        record.check(manifest, model=model, vendor=vendor_root, view=view)
    verify_runtime_view(view, model, vendor_root, manifest, record)
    import sys
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(vendor_root))
    from acestep.handler import AceStepHandler

    class OfflineACEHandler(OfflineACEMixin, AceStepHandler):
        pass

    handler = OfflineACEHandler()
    handler._ace_manifest = manifest
    handler._ace_runtime_root = view
    handler._ace_model_root = model
    handler._ace_vendor_root = vendor_root
    handler._ace_record = record
    return handler


def forbid_torch_fallback(handler: Any) -> None:
    if not handler.use_mlx_dit or handler.mlx_decoder is None or not handler.use_mlx_vae or handler.mlx_vae is None:
        raise ACEContractError("ACE MLX backends not ready", "configuration")

    def fail(*_args: Any, **_kwargs: Any):
        raise ACEContractError("ACE PyTorch fallback invoked after MLX conversion", "engine")

    for obj, method in ((handler.model, "generate_audio"),
                        (handler.vae, "encode"), (handler.vae, "decode")):
        setattr(obj, method, fail)
