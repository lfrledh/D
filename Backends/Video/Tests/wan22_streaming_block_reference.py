"""Bounded, offline single-block streaming reference for Wan2.2.

This diagnostic owns only parameters belonging to transformer blocks 0, 14,
and 29.  It deliberately does not load common weights, run inference, alter
model classes, or provide a fallback device.  A caller supplies a model whose
blocks are on the meta device and a versioned manifest frozen by an external
integrity guard.
"""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass
import os
from pathlib import Path
import stat
import threading
import time
from types import MappingProxyType
from typing import Any
import weakref

from safetensors import safe_open
import torch


_ALLOWED_BLOCKS = (0, 14, 29)
_ALLOWED_TARGET_DTYPES = {
    "float32": torch.float32,
    "bfloat16": torch.bfloat16,
}
_MODEL_OWNERS_LOCK = threading.Lock()
_MODEL_OWNERS = weakref.WeakKeyDictionary()


class BlockLoadCancelled(RuntimeError):
    """Raised by a checkpoint callback to request a bounded cancellation."""


class BlockLoaderPoisonedError(RuntimeError):
    """The loader cannot safely grant another lease after a cleanup failure."""


class _ShardIdentityError(RuntimeError):
    pass


@dataclass(frozen=True)
class _ShardIdentity:
    device: int
    inode: int
    size: int
    mtime_ns: int

    @classmethod
    def from_stat(cls, value: os.stat_result) -> "_ShardIdentity":
        return cls(value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns)


@dataclass(frozen=True)
class _TensorRecord:
    name: str
    relative_name: str
    shard: str
    shape: tuple[int, ...]
    target_dtype_name: str


@dataclass(frozen=True)
class _ParameterSlot:
    module: torch.nn.Module
    name: str
    original: torch.nn.Parameter


def _is_plain_int(value: Any) -> bool:
    return type(value) is int


def _required_mapping(value: Any, label: str) -> Mapping:
    if not isinstance(value, Mapping):
        raise TypeError(f"{label} must be a mapping")
    return value


def _required_keys(value: Mapping, expected: set[str], label: str) -> None:
    actual = set(value)
    if actual != expected or any(not isinstance(key, str) for key in value):
        raise ValueError(
            f"{label} fields differ: expected {sorted(expected)}, "
            f"got {sorted(str(key) for key in actual)}"
        )


def _target_dtype_for(name: str) -> str:
    parts = name.split(".")
    if name.endswith(".modulation") or any(part.startswith("norm") for part in parts):
        return "float32"
    return "bfloat16"


def _basename(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise ValueError(f"{label} must be a nonempty basename")
    if value in (".", "..") or "/" in value or "\\" in value:
        raise ValueError(f"{label} must not contain a path")
    if Path(value).name != value:
        raise ValueError(f"{label} must be a basename")
    return value


class _ResidentContext:
    def __init__(self, loader: "BlockLoader", block_index: int):
        self._loader = loader
        self._block_index = block_index
        self._entered = False
        self._finished = False

    def __enter__(self):
        if self._entered or self._finished:
            raise RuntimeError("a resident context cannot be entered more than once")
        self._entered = True
        try:
            return self._loader._acquire(self._block_index)
        except BaseException:
            self._finished = True
            raise

    def __exit__(self, exc_type, exc, traceback):
        if not self._entered or self._finished:
            raise RuntimeError("resident context exit does not match an active entry")
        self._finished = True
        release_error = self._loader._release(self._block_index)
        if release_error is not None:
            if exc is not None:
                _add_note(exc, f"block release also failed: {release_error!r}")
            else:
                raise release_error
        return False


def _add_note(error: BaseException, message: str) -> None:
    add_note = getattr(error, "add_note", None)
    if add_note is not None:
        add_note(message)


class BlockLoader:
    """Load exactly one approved transformer block for the duration of a lease."""

    def __init__(
        self,
        meta_model,
        model_root,
        frozen_manifest,
        *,
        device="mps",
        checkpoint=None,
    ):
        if device not in ("cpu", "mps"):
            raise ValueError("device must be explicitly 'cpu' or 'mps'")
        if checkpoint is not None and not callable(checkpoint):
            raise TypeError("checkpoint must be callable or None")
        try:
            root = Path(model_root)
        except TypeError as error:
            raise TypeError("model_root must be path-like") from error
        if not root.is_absolute():
            raise ValueError("model_root must be absolute")

        self._model = meta_model
        self._root = root
        self._device = device
        self._checkpoint_callback = checkpoint
        self._lock = threading.RLock()
        self._state = "open"
        self._active_block: int | None = None
        self._installed: list[_ParameterSlot] = []
        self._active_shards: frozenset[str] = frozenset()
        self._owns_model = False
        self._statistics = {
            "leases": 0,
            "tensorsRead": 0,
            "logicalBytes": 0,
            "readSeconds": 0.0,
        }

        manifest = _required_mapping(frozen_manifest, "manifest")
        _required_keys(manifest, {"schemaVersion", "blocks", "shards"}, "manifest")
        if not _is_plain_int(manifest["schemaVersion"]) or manifest["schemaVersion"] != 1:
            raise ValueError("manifest schemaVersion must be integer 1")

        self._blocks = self._model_blocks(meta_model)
        self._shards = self._freeze_shards(manifest["shards"])
        self._records = self._freeze_blocks(manifest["blocks"])
        self._validate_all_blocks_are_meta()
        self._claim_model_ownership()

    @staticmethod
    def _model_blocks(meta_model) -> tuple[torch.nn.Module, ...]:
        blocks = getattr(meta_model, "blocks", None)
        if blocks is None:
            raise ValueError("meta_model must expose transformer blocks")
        try:
            result = tuple(blocks)
        except TypeError as error:
            raise TypeError("meta_model.blocks must be iterable") from error
        if len(result) <= max(_ALLOWED_BLOCKS):
            raise ValueError("meta_model does not contain all approved blocks")
        if any(not isinstance(block, torch.nn.Module) for block in result):
            raise TypeError("every model block must be a torch module")
        return result

    @staticmethod
    def _freeze_shards(value: Any) -> Mapping[str, _ShardIdentity]:
        rows = _required_mapping(value, "manifest shards")
        if not rows:
            raise ValueError("manifest shards must not be empty")
        frozen: dict[str, _ShardIdentity] = {}
        for raw_name, raw_identity in rows.items():
            name = _basename(raw_name, "shard name")
            if name in frozen:
                raise ValueError(f"duplicate shard: {name}")
            identity = _required_mapping(raw_identity, f"identity for {name}")
            _required_keys(
                identity,
                {"device", "inode", "size", "mtimeNS"},
                f"identity for {name}",
            )
            values = (
                identity["device"],
                identity["inode"],
                identity["size"],
                identity["mtimeNS"],
            )
            if any(not _is_plain_int(item) for item in values):
                raise ValueError(f"identity for {name} must contain integers")
            if values[0] < 0 or values[1] <= 0 or values[2] <= 0 or values[3] < 0:
                raise ValueError(f"identity for {name} contains an invalid value")
            frozen[name] = _ShardIdentity(*values)
        return MappingProxyType(frozen)

    def _freeze_blocks(self, value: Any) -> Mapping[int, tuple[_TensorRecord, ...]]:
        blocks = _required_mapping(value, "manifest blocks")
        if set(blocks) != {str(index) for index in _ALLOWED_BLOCKS}:
            raise ValueError("manifest blocks must contain exactly 0, 14, and 29")
        frozen: dict[int, tuple[_TensorRecord, ...]] = {}
        all_names: set[str] = set()
        referenced_shards: set[str] = set()
        for index in _ALLOWED_BLOCKS:
            raw_records = blocks[str(index)]
            if (
                not isinstance(raw_records, Sequence)
                or isinstance(raw_records, (str, bytes, bytearray))
                or not raw_records
            ):
                raise ValueError(f"block {index} records must be a nonempty sequence")
            expected_parameters = dict(self._blocks[index].named_parameters(recurse=True))
            if not expected_parameters:
                raise ValueError(f"block {index} has no parameters")
            records: list[_TensorRecord] = []
            relative_names: set[str] = set()
            prefix = f"blocks.{index}."
            for position, raw_record in enumerate(raw_records):
                record = _required_mapping(raw_record, f"block {index} record {position}")
                _required_keys(
                    record,
                    {"name", "shard", "shape", "sourceDtype", "targetDtype"},
                    f"block {index} record {position}",
                )
                name = record["name"]
                if not isinstance(name, str) or not name.startswith(prefix):
                    raise ValueError(f"parameter name must start with {prefix}")
                relative_name = name[len(prefix) :]
                if not relative_name or name in all_names or relative_name in relative_names:
                    raise ValueError(f"duplicate or empty parameter name: {name!r}")
                if relative_name not in expected_parameters:
                    raise ValueError(f"manifest names an unknown parameter: {name}")
                shard = _basename(record["shard"], f"shard for {name}")
                if shard not in self._shards:
                    raise ValueError(f"parameter {name} references an unknown shard")
                shape = record["shape"]
                if (
                    not isinstance(shape, Sequence)
                    or isinstance(shape, (str, bytes, bytearray))
                    or not shape
                    or any(not _is_plain_int(item) or item <= 0 for item in shape)
                ):
                    raise ValueError(f"parameter {name} has an invalid shape")
                shape_tuple = tuple(shape)
                if shape_tuple != tuple(expected_parameters[relative_name].shape):
                    raise ValueError(f"parameter {name} shape differs from the meta model")
                if record["sourceDtype"] != "float32":
                    raise ValueError(f"parameter {name} sourceDtype must be float32")
                target_dtype_name = record["targetDtype"]
                if target_dtype_name not in _ALLOWED_TARGET_DTYPES:
                    raise ValueError(f"parameter {name} has an unapproved targetDtype")
                expected_dtype_name = _target_dtype_for(name)
                if target_dtype_name != expected_dtype_name:
                    raise ValueError(
                        f"parameter {name} targetDtype violates the frozen precision rule"
                    )
                all_names.add(name)
                relative_names.add(relative_name)
                referenced_shards.add(shard)
                records.append(
                    _TensorRecord(
                        name=name,
                        relative_name=relative_name,
                        shard=shard,
                        shape=shape_tuple,
                        target_dtype_name=target_dtype_name,
                    )
                )
            missing = set(expected_parameters) - relative_names
            if missing:
                raise ValueError(
                    f"block {index} manifest is missing parameters: {sorted(missing)}"
                )
            if self._device == "mps":
                target_counts = {
                    dtype_name: sum(
                        record.target_dtype_name == dtype_name for record in records
                    )
                    for dtype_name in _ALLOWED_TARGET_DTYPES
                }
                if len(records) != 27 or target_counts != {
                    "float32": 7,
                    "bfloat16": 20,
                }:
                    raise ValueError(
                        f"real block {index} must contain 27 parameters "
                        "with the frozen 7 FP32 / 20 BF16 split"
                    )
            frozen[index] = tuple(records)
        unused = set(self._shards) - referenced_shards
        if unused:
            raise ValueError(f"manifest contains unused shards: {sorted(unused)}")
        return MappingProxyType(frozen)

    def _validate_all_blocks_are_meta(self) -> None:
        for index, block in enumerate(self._blocks):
            for name, parameter in block.named_parameters(recurse=True):
                if parameter.device.type != "meta":
                    raise ValueError(
                        f"model block parameter must remain meta at construction: "
                        f"blocks.{index}.{name}"
                    )

    @property
    def statistics(self) -> Mapping[str, int | float]:
        with self._lock:
            return MappingProxyType(dict(self._statistics))

    def resident(self, block_index: int):
        if not _is_plain_int(block_index) or block_index not in _ALLOWED_BLOCKS:
            raise ValueError("block_index must be integer 0, 14, or 29")
        return _ResidentContext(self, block_index)

    def close(self) -> None:
        with self._lock:
            if self._state == "closed":
                return
            if self._state in ("loading", "resident", "releasing"):
                raise RuntimeError("cannot close BlockLoader during an active lease")
            self._state = "closed"
            self._active_block = None
            self._installed.clear()
            self._active_shards = frozenset()
        self._release_model_ownership()

    def _claim_model_ownership(self) -> None:
        with _MODEL_OWNERS_LOCK:
            existing_reference = _MODEL_OWNERS.get(self._model)
            existing = (
                existing_reference() if existing_reference is not None else None
            )
            if existing is not None and existing is not self:
                raise RuntimeError("meta_model already has a BlockLoader owner")
            _MODEL_OWNERS[self._model] = weakref.ref(self)
            self._owns_model = True

    def _release_model_ownership(self) -> None:
        with _MODEL_OWNERS_LOCK:
            if not self._owns_model:
                return
            existing_reference = _MODEL_OWNERS.get(self._model)
            if existing_reference is not None and existing_reference() is self:
                del _MODEL_OWNERS[self._model]
            self._owns_model = False

    def _begin_acquire(self, block_index: int) -> None:
        with self._lock:
            if self._state == "closed":
                raise RuntimeError("BlockLoader is closed")
            if self._state == "poisoned":
                raise BlockLoaderPoisonedError("BlockLoader is poisoned")
            if self._state != "open":
                raise RuntimeError("BlockLoader already has an active lease")
            self._state = "loading"
            self._active_block = block_index

    def _acquire(self, block_index: int):
        self._begin_acquire(block_index)
        installed: list[_ParameterSlot] = []
        records = self._records[block_index]
        touched_shards: set[str] = set()
        synchronization_failed = False
        try:
            self._checkpoint("before_load", block_index, completed=0)
            for record in records:
                started = time.perf_counter()
                source = self._read_source(record)
                elapsed = time.perf_counter() - started
                logical_bytes = source.numel() * source.element_size()
                with self._lock:
                    self._statistics["tensorsRead"] += 1
                    self._statistics["logicalBytes"] += logical_bytes
                    self._statistics["readSeconds"] += elapsed
                touched_shards.add(record.shard)
                self._checkpoint(
                    "after_read",
                    block_index,
                    name=record.name,
                    completed=len(installed),
                    logicalBytes=logical_bytes,
                    readSeconds=elapsed,
                )
                target_dtype = _ALLOWED_TARGET_DTYPES[record.target_dtype_name]
                converted = source.to(device=self._device, dtype=target_dtype)
                del source
                self._checkpoint(
                    "before_install",
                    block_index,
                    name=record.name,
                    completed=len(installed),
                )
                slot = self._install(block_index, record, converted)
                installed.append(slot)
                del converted
                self._checkpoint(
                    "after_install",
                    block_index,
                    name=record.name,
                    completed=len(installed),
                )
            try:
                self._synchronize()
            except BaseException:
                synchronization_failed = True
                raise
            self._checkpoint("ready", block_index, completed=len(installed))
        except BaseException as error:
            identity_failure = isinstance(error, _ShardIdentityError)
            cleanup_error = self._cleanup(installed)
            poisoned = (
                identity_failure
                or synchronization_failed
                or cleanup_error is not None
            )
            with self._lock:
                self._state = "poisoned" if poisoned else "open"
                self._active_block = None
                self._installed.clear()
                self._active_shards = frozenset()
            if cleanup_error is not None:
                _add_note(error, f"cleanup after load failure also failed: {cleanup_error!r}")
            raise

        with self._lock:
            self._state = "resident"
            self._installed = installed
            self._active_shards = frozenset(touched_shards)
            self._statistics["leases"] += 1
        return self._blocks[block_index]

    def _release(self, block_index: int) -> BaseException | None:
        with self._lock:
            if self._state != "resident" or self._active_block != block_index:
                return RuntimeError("resident lease state is inconsistent")
            self._state = "releasing"
            installed = self._installed
            active_shards = self._active_shards

        first_error: BaseException | None = None
        poison = False
        try:
            self._checkpoint(
                "before_release", block_index, completed=len(installed)
            )
        except BaseException as error:
            first_error = error
        try:
            for shard in active_shards:
                self._verify_shard_identity(shard)
        except BaseException as error:
            poison = isinstance(error, _ShardIdentityError)
            if first_error is None:
                first_error = error
            else:
                _add_note(first_error, f"shard verification also failed: {error!r}")

        cleanup_error = self._cleanup(installed)
        if cleanup_error is not None:
            poison = True
            if first_error is None:
                first_error = cleanup_error
            else:
                _add_note(first_error, f"cleanup also failed: {cleanup_error!r}")

        with self._lock:
            self._state = "poisoned" if poison else "open"
            self._active_block = None
            self._installed = []
            self._active_shards = frozenset()

        if cleanup_error is None:
            try:
                self._checkpoint("released", block_index, completed=len(installed))
            except BaseException as error:
                if first_error is None:
                    first_error = error
                else:
                    _add_note(first_error, f"released checkpoint also failed: {error!r}")
        return first_error

    def _checkpoint(
        self,
        stage: str,
        block_index: int,
        *,
        completed: int,
        name: str | None = None,
        **extra: int | float,
    ) -> None:
        callback = self._checkpoint_callback
        if callback is None:
            return
        event: dict[str, str | int | float] = {
            "stage": stage,
            "block": block_index,
            "completed": completed,
        }
        if name is not None:
            event["name"] = name
        event.update(extra)
        callback(MappingProxyType(event))

    def _validated_root(self) -> Path:
        try:
            root_stat = os.lstat(self._root)
        except OSError as error:
            raise _ShardIdentityError(f"model root is unavailable: {self._root}") from error
        if stat.S_ISLNK(root_stat.st_mode) or not stat.S_ISDIR(root_stat.st_mode):
            raise _ShardIdentityError("model_root must be an ordinary directory")
        try:
            if self._root.resolve(strict=True) != self._root:
                raise _ShardIdentityError("model_root must not traverse a symbolic link")
        except OSError as error:
            raise _ShardIdentityError("model_root cannot be resolved safely") from error
        return self._root

    def _identity_from_path(self, shard: str) -> _ShardIdentity:
        path = self._validated_root() / shard
        try:
            value = os.lstat(path)
        except OSError as error:
            raise _ShardIdentityError(f"shard is unavailable: {shard}") from error
        if stat.S_ISLNK(value.st_mode) or not stat.S_ISREG(value.st_mode):
            raise _ShardIdentityError(f"shard must be an ordinary file: {shard}")
        return _ShardIdentity.from_stat(value)

    def _verify_shard_identity(self, shard: str) -> None:
        actual = self._identity_from_path(shard)
        expected = self._shards[shard]
        if actual != expected:
            raise _ShardIdentityError(f"shard identity differs from manifest: {shard}")

    def _read_source(self, record: _TensorRecord) -> torch.Tensor:
        self._verify_shard_identity(record.shard)
        path = self._root / record.shard
        expected_identity = self._shards[record.shard]
        flags = os.O_RDONLY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        try:
            descriptor = os.open(path, flags)
        except OSError as error:
            raise _ShardIdentityError(
                f"cannot safely open shard: {record.shard}"
            ) from error
        try:
            if _ShardIdentity.from_stat(os.fstat(descriptor)) != expected_identity:
                raise _ShardIdentityError(
                    f"opened shard identity differs from manifest: {record.shard}"
                )
            try:
                with safe_open(str(path), framework="pt", device="cpu") as handle:
                    if record.name not in handle.keys():
                        raise ValueError(
                            f"tensor {record.name} is missing from {record.shard}"
                        )
                    source = handle.get_tensor(record.name)
                    if source.dtype != torch.float32:
                        raise ValueError(f"tensor {record.name} is not source float32")
                    if tuple(source.shape) != record.shape:
                        raise ValueError(f"tensor {record.name} shape differs from manifest")
                    if not bool(torch.isfinite(source).all().item()):
                        raise ValueError(f"tensor {record.name} contains a nonfinite value")
                    source = source.clone(memory_format=torch.contiguous_format)
            except (ValueError, _ShardIdentityError):
                raise
            except BaseException as error:
                raise ValueError(
                    f"cannot read tensor {record.name} from {record.shard}"
                ) from error
            if _ShardIdentity.from_stat(os.fstat(descriptor)) != expected_identity:
                raise _ShardIdentityError(
                    f"shard changed while reading: {record.shard}"
                )
            self._verify_shard_identity(record.shard)
            return source
        finally:
            os.close(descriptor)

    def _parameter_slot(self, block_index: int, relative_name: str) -> _ParameterSlot:
        block = self._blocks[block_index]
        parent_name, separator, leaf_name = relative_name.rpartition(".")
        try:
            parent = block.get_submodule(parent_name) if separator else block
        except AttributeError as error:
            raise ValueError(f"parameter parent disappeared: {relative_name}") from error
        original = parent._parameters.get(leaf_name)
        if not isinstance(original, torch.nn.Parameter):
            raise ValueError(f"parameter disappeared: {relative_name}")
        if original.device.type != "meta":
            raise ValueError(f"parameter is already resident: {relative_name}")
        return _ParameterSlot(parent, leaf_name, original)

    def _install(
        self,
        block_index: int,
        record: _TensorRecord,
        value: torch.Tensor,
    ) -> _ParameterSlot:
        if tuple(value.shape) != record.shape:
            raise ValueError(f"converted tensor shape differs: {record.name}")
        expected_dtype = _ALLOWED_TARGET_DTYPES[record.target_dtype_name]
        if value.dtype != expected_dtype or value.device.type != self._device:
            raise RuntimeError(f"converted tensor placement differs: {record.name}")
        slot = self._parameter_slot(block_index, record.relative_name)
        parameter = torch.nn.Parameter(value, requires_grad=slot.original.requires_grad)
        slot.module._parameters[slot.name] = parameter
        return slot

    def _synchronize(self) -> None:
        if self._device == "mps":
            if not torch.backends.mps.is_available():
                raise RuntimeError("MPS was requested but is unavailable")
            torch.mps.synchronize()

    def _cleanup(self, installed: list[_ParameterSlot]) -> BaseException | None:
        errors: list[BaseException] = []
        try:
            self._synchronize()
        except BaseException as error:
            errors.append(error)
        for slot in reversed(installed):
            try:
                slot.module._parameters[slot.name] = slot.original
            except BaseException as error:
                errors.append(error)
        if not errors:
            return None
        primary = errors[0]
        for additional in errors[1:]:
            _add_note(primary, f"additional cleanup failure: {additional!r}")
        return primary


__all__ = [
    "BlockLoadCancelled",
    "BlockLoader",
    "BlockLoaderPoisonedError",
]
