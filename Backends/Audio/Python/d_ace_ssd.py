"""Exact F32 ACE decoder preparation and demand-loaded official MLX layers.

The official decoder, attention, sampler and VAE are unchanged. Only weight
residency changes. Derived files belong to the backend, never the checkpoint.
"""
from __future__ import annotations

from contextlib import contextmanager
import copy
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import tempfile
from typing import Any, Callable

from d_audio_ace_contract import ACEContractError

CONVERTER = "ace-xl-f32-ssd-v1"


def check_cancel(cancelled: Callable[[], bool]) -> None:
    if cancelled():
        raise InterruptedError("ACE cancelled at SSD layer boundary")


def digest(path: Path, cancelled: Callable[[], bool] = lambda: False) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            check_cancel(cancelled)
            value.update(block)
    return value.hexdigest()


def identity(path: Path) -> tuple[int, int, int, int, int]:
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode):
        raise ACEContractError("ACE prepared resource is not a regular file", "configuration")
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns


def checked_directory(path: Path) -> None:
    if not path.is_absolute():
        raise ACEContractError("ACE SSD cache must be absolute", "configuration")
    for parent in (path, *path.parents):
        if parent.is_symlink():
            raise ACEContractError("ACE SSD cache cannot contain symlinks", "configuration")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not path.is_dir():
        raise ACEContractError("ACE SSD cache is not a directory", "configuration")


def mapped_tensor(key: str, value: Any) -> tuple[str, Any]:
    """The two layout mappings in pinned official dit_convert.py, with no cast."""
    import numpy as np
    if not key.startswith("decoder.") or value.dtype != np.float32:
        raise ACEContractError("ACE decoder must contain original F32 parameters", "configuration")
    name = key.removeprefix("decoder.")
    if name.startswith("proj_in.1."):
        name = name.replace("proj_in.1.", "proj_in.", 1)
        if name.endswith(".weight"):
            value = value.swapaxes(1, 2)
    elif name.startswith("proj_out.1."):
        name = name.replace("proj_out.1.", "proj_out.", 1)
        if name.endswith(".weight"):
            value = value.transpose(1, 2, 0)
    if "rotary_emb" in name:
        raise ACEContractError("Unexpected learned rotary parameter in ACE checkpoint", "configuration")
    return name, np.ascontiguousarray(value)


def decoder_groups(index: dict[str, str], layer_count: int) -> dict[str, list[str]]:
    groups: dict[str, list[str]] = {"resident": []}
    groups.update({f"layer-{i:03}": [] for i in range(layer_count)})
    for key in sorted(index):
        if not key.startswith("decoder."):
            continue
        parts = key.split(".")
        group = "resident"
        if len(parts) > 3 and parts[1] == "layers":
            if not parts[2].isdigit() or str(int(parts[2])) != parts[2]:
                raise ACEContractError("Invalid ACE layer identity", "configuration")
            group = f"layer-{int(parts[2]):03}"
        if group not in groups:
            raise ACEContractError("ACE layer outside complete configuration", "configuration")
        groups[group].append(key)
    if any(not keys for keys in groups.values()):
        raise ACEContractError("ACE decoder layer or resident parameters missing", "configuration")
    return groups


def prepare_decoder(checkpoint: Path, cache_root: Path, source_files: list[dict[str, Any]],
                    cancelled: Callable[[], bool], progress: Callable[[int, int], None],
                    *, verify_sources: Callable[[], None]) -> Path:
    """Prepare once, at most one official layer in memory; publish complete cache only."""
    from safetensors import safe_open
    from safetensors.numpy import save_file
    checked_directory(cache_root)
    source = {"converter": CONVERTER, "files": source_files}
    fingerprint = hashlib.sha256(json.dumps(source, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    destination = cache_root / fingerprint
    lock_path = cache_root / (fingerprint + ".lock")
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise ACEContractError("ACE cache lock is not regular", "configuration")
        # Existing runtime serializes jobs. A second process must not wait forever.
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise ACEContractError("ACE resources are being prepared by another task", "configuration") from exc
        check_cancel(cancelled)
        verify_sources()
        if destination.exists() or destination.is_symlink():
            PreparedDecoder(destination, source, cancelled)
            verify_sources()
            return destination
        config = json.loads((checkpoint / "config.json").read_text())
        count = config["num_hidden_layers"]
        if type(count) is not int or not 1 <= count <= 128:
            raise ACEContractError("Invalid ACE decoder layer count", "configuration")
        index = json.loads((checkpoint / "model.safetensors.index.json").read_text())["weight_map"]
        groups = decoder_groups(index, count)
        declared = {Path(item["path"]).name for item in source_files}
        if any(Path(file).name != file or file not in declared for file in index.values()):
            raise ACEContractError("ACE shard index leaves verified inventory", "configuration")
        staging = Path(tempfile.mkdtemp(prefix=".ace-prepare-", dir=cache_root))
        try:
            entries = []
            total = sum(map(len, groups.values()))
            done = 0
            for group, keys in groups.items():
                values, mappings = {}, []
                for key in keys:
                    check_cancel(cancelled)
                    with safe_open(checkpoint / index[key], framework="np") as handle:
                        raw = handle.get_tensor(key)
                    name, value = mapped_tensor(key, raw)
                    if group != "resident":
                        name = name.split(".", 2)[2]
                    if name in values:
                        raise ACEContractError("ACE converted key collision", "configuration")
                    values[name] = value
                    mappings.append({"sourceKey": key, "sourceShard": index[key],
                        "targetKey": name, "sourceShape": list(raw.shape),
                        "shape": list(value.shape), "dtype": "F32"})
                    del raw, value
                    done += 1
                    progress(done, total)
                target = staging / (group + ".safetensors")
                save_file(values, str(target))
                del values
                with target.open("rb") as stream:
                    os.fsync(stream.fileno())
                entries.append({"name": target.name, "size": target.stat().st_size,
                                "sha256": digest(target, cancelled), "parameters": mappings})
            manifest = {"schemaVersion": 1, "source": source, "layerCount": count, "files": entries}
            path = staging / "manifest.json"
            path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
            with path.open("rb") as stream:
                os.fsync(stream.fileno())
            check_cancel(cancelled)
            PreparedDecoder(staging, source, cancelled)
            verify_sources()
            # Lock plus absent destination: never replace a valid or incomplete cache.
            if destination.exists() or destination.is_symlink():
                raise ACEContractError("ACE SSD destination appeared during preparation", "configuration")
            os.rename(staging, destination)
            parent_fd = os.open(cache_root, os.O_RDONLY)
            try: os.fsync(parent_fd)
            finally: os.close(parent_fd)
            return destination
        finally:
            if staging.exists():
                shutil.rmtree(staging)  # Only this call's unpublished derived resources.
    finally:
        os.close(fd)


class PreparedDecoder:
    """Verified derived shards. Per-load identity guards avoid rehashing 16 GiB per step."""
    def __init__(self, root: Path, source: dict[str, Any] | None,
                 cancelled: Callable[[], bool]):
        if root.is_symlink() or not root.is_dir():
            raise ACEContractError("ACE prepared root unavailable", "configuration")
        path = root / "manifest.json"
        if identity(path)[2] > 1024 * 1024:
            raise ACEContractError("ACE prepared manifest too large", "configuration")
        manifest = json.loads(path.read_text())
        if manifest.get("schemaVersion") != 1 or (source is not None and manifest.get("source") != source):
            raise ACEContractError("ACE prepared source identity mismatch", "configuration")
        self.count = manifest["layerCount"]
        self.root, self.cancelled = root, cancelled
        expected = {"resident.safetensors", *(f"layer-{i:03}.safetensors" for i in range(self.count))}
        entries = manifest["files"]
        if len(entries) != len(expected) or {e["name"] for e in entries} != expected:
            raise ACEContractError("ACE prepared layer set incomplete", "configuration")
        self.identities, self.entries = {}, {}
        for entry in entries:
            check_cancel(cancelled)
            item = root / entry["name"]
            before = identity(item)
            if before[2] != entry["size"] or digest(item, cancelled) != entry["sha256"] or identity(item) != before:
                raise ACEContractError("ACE prepared parameter file changed", "configuration")
            self.identities[entry["name"]] = before
            self.entries[entry["name"]] = entry

    def load(self, name: str) -> dict[str, Any]:
        import mlx.core as mx
        check_cancel(self.cancelled)
        path = self.root / name
        if identity(path) != self.identities[name]:
            raise ACEContractError("ACE prepared shard changed before load", "inputMutation")
        weights = mx.load(str(path))
        expected = {item["targetKey"]: item for item in self.entries[name]["parameters"]}
        if set(weights) != set(expected) or any(value.dtype != mx.float32 or list(value.shape) != expected[key]["shape"] for key, value in weights.items()):
            raise ACEContractError("ACE prepared tensor contract mismatch", "configuration")
        mx.eval(weights)
        if identity(path) != self.identities[name]:
            raise ACEContractError("ACE prepared shard changed during load", "inputMutation")
        check_cancel(self.cancelled)
        return weights


@contextmanager
def preserve_mlx_random():
    import mlx.core as mx
    saved = list(mx.random.state)
    mx.eval(saved)
    try:
        yield
    finally:
        mx.random.state[:] = saved


def make_decoder(config: Any, prepared: PreparedDecoder,
                 progress: Callable[[int, int], None], before_first_layer: Callable[[], None],
                 *, total_steps: int = 1):
    import mlx.core as mx
    from acestep.models.mlx.dit_model import MLXDiTDecoder, MLXDiTLayer
    if config.num_hidden_layers != prepared.count:
        raise ACEContractError("ACE SSD decoder is not the complete configured model", "configuration")
    empty = copy.deepcopy(config)
    empty.num_hidden_layers = 0
    with preserve_mlx_random():
        decoder = MLXDiTDecoder.from_config(empty)
    decoder.load_weights(list(prepared.load("resident.safetensors").items()), strict=True)
    mx.eval(decoder.parameters())
    decoder.materialize_static_buffers()
    state = {"started": False, "calls": 0}

    class Layer:
        # Plain callable: no retained nn.Module parameters between invocations.
        def __init__(self, index: int):
            self.index = index
            self.layer_type = config.layer_types[index]

        def __call__(self, hidden_states, **kwargs):
            check_cancel(prepared.cancelled)
            if not state["started"]:
                before_first_layer()
                state["started"] = True
            layer, weights = None, None
            try:
                with preserve_mlx_random():
                    layer = MLXDiTLayer(hidden_size=config.hidden_size,
                        intermediate_size=config.intermediate_size,
                        num_attention_heads=config.num_attention_heads,
                        num_key_value_heads=config.num_key_value_heads,
                        head_dim=config.head_dim, rms_norm_eps=config.rms_norm_eps,
                        attention_bias=config.attention_bias, layer_idx=self.index,
                        layer_type=self.layer_type, sliding_window=config.sliding_window or 128)
                weights = prepared.load(f"layer-{self.index:03}.safetensors")
                layer.load_weights(list(weights.items()), strict=True)
                check_cancel(prepared.cancelled)
                output = layer(hidden_states, **kwargs)
                cache = kwargs.get("cache")
                retained = cache.get(self.index) if cache is not None and cache.is_updated(self.index) else ()
                mx.eval(output, *retained)
                check_cancel(prepared.cancelled)
                state["calls"] += 1
                progress(state["calls"], prepared.count * total_steps)
                return output
            finally:
                del layer, weights
                mx.clear_cache()

    decoder.layers = [Layer(index) for index in range(prepared.count)]
    return decoder


def load_condition_model(handler: Any, checkpoint: Path, cancelled: Callable[[], bool]) -> None:
    """Never instantiate Torch decoder storage; load remaining original F32 one tensor at a time."""
    import torch
    from accelerate import init_empty_weights
    from safetensors import safe_open
    from acestep.models.xl_sft.configuration_acestep_v15 import AceStepConfig
    from acestep.models.xl_sft.modeling_acestep_v15_xl_base import AceStepConditionGenerationModel
    config = AceStepConfig.from_pretrained(str(checkpoint), local_files_only=True)
    config._attn_implementation = "sdpa"
    # FSQ needs real integer buffers during construction. Parameters stay meta.
    with init_empty_weights(include_buffers=False):
        model = AceStepConditionGenerationModel(config)
    model.decoder = None
    index = json.loads((checkpoint / "model.safetensors.index.json").read_text())["weight_map"]
    remaining = {key for key in index if not key.startswith("decoder.")}
    expected = set(model.state_dict())
    if remaining != expected:
        raise ACEContractError("ACE conditional model key set differs from fixed checkpoint", "configuration")
    for key in sorted(remaining):
        check_cancel(cancelled)
        with safe_open(checkpoint / index[key], framework="pt", device="cpu") as stream:
            value = stream.get_tensor(key)
        target = model.state_dict()[key]
        if value.dtype != torch.float32 or value.shape != target.shape:
            raise ACEContractError("ACE conditional tensor precision/shape mismatch", "configuration")
        model.load_state_dict({key: value}, strict=False, assign=True)
        del value, target
    if any(parameter.is_meta for parameter in model.parameters()):
        raise ACEContractError("ACE conditional model contains uninitialized parameters", "configuration")
    model.eval()
    handler.model, handler.config = model, config
    handler._sync_alignment_config()
    handler.silence_latent = torch.load(checkpoint / "silence_latent.pt", weights_only=True).transpose(1, 2).to("cpu", dtype=torch.float32)


def release_condition_modules(handler: Any) -> None:
    import gc
    import torch
    import mlx.core as mx
    torch.mps.synchronize()
    # One request per provider. Main model shell is retained for offload-context finally.
    handler.text_encoder = None
    for name in ("encoder", "tokenizer", "detokenizer"):
        setattr(handler.model, name, None)
    gc.collect()
    torch.mps.empty_cache()
    mx.clear_cache()
