"""Strict streaming weight lifetime for a caller-constructed Torch Wan model.

The caller supplies a completely-meta model and a frozen schema-v2 manifest.
A session keeps only common parameters resident; each transformer block is
loaded for the duration of its lease.  This module never discovers models,
downloads files, or changes model classes.
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


_DTYPES = {"float32": torch.float32, "bfloat16": torch.bfloat16}
_OWNERS_LOCK = threading.Lock()
_OWNERS = weakref.WeakKeyDictionary()


class WeightLoadCancelled(RuntimeError):
    """A checkpoint callback requested cancellation at a safe boundary."""


class WeightSessionPoisonedError(RuntimeError):
    """A prior identity, synchronization, or cleanup failure is unrecoverable."""


class _IdentityError(RuntimeError):
    pass


@dataclass(frozen=True)
class _Identity:
    device: int
    inode: int
    size: int
    mtime_ns: int

    @classmethod
    def from_stat(cls, value: os.stat_result) -> "_Identity":
        return cls(value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns)


@dataclass(frozen=True)
class _Record:
    name: str
    relative_name: str
    shard: str
    shape: tuple[int, ...]
    target_dtype: str


@dataclass(frozen=True)
class _Slot:
    module: torch.nn.Module
    name: str
    original: torch.nn.Parameter


def _plain_int(value: Any) -> bool:
    return type(value) is int


def _mapping(value: Any, label: str) -> Mapping:
    if not isinstance(value, Mapping):
        raise TypeError(f"{label} must be a mapping")
    return value


def _keys(value: Mapping, expected: set[str], label: str) -> None:
    actual = set(value)
    if actual != expected or any(not isinstance(key, str) for key in value):
        raise ValueError(
            f"{label} fields differ: expected {sorted(expected)}, "
            f"got {sorted(str(key) for key in actual)}"
        )


def _basename(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise ValueError(f"{label} must be a nonempty basename")
    if value in (".", "..") or "/" in value or "\\" in value:
        raise ValueError(f"{label} must not contain a path")
    if Path(value).name != value:
        raise ValueError(f"{label} must be a basename")
    return value


def _target_dtype(name: str) -> str:
    if name.startswith(("time_embedding.", "time_projection.", "head.")):
        return "float32"
    if name.endswith(".modulation") or any(
        part.startswith("norm") for part in name.split(".")
    ):
        return "float32"
    return "bfloat16"


def _add_note(error: BaseException, message: str) -> None:
    add_note = getattr(error, "add_note", None)
    if add_note is not None:
        add_note(message)


class _SessionContext:
    def __init__(self, owner: "StreamingWeights"):
        self._owner = owner
        self._entered = False
        self._finished = False

    def __enter__(self):
        if self._entered or self._finished:
            raise RuntimeError("a session context cannot be entered more than once")
        self._entered = True
        try:
            return self._owner._enter_session()
        except BaseException:
            self._finished = True
            raise

    def __exit__(self, exc_type, exc, traceback):
        if not self._entered or self._finished:
            raise RuntimeError("session context exit does not match an active entry")
        self._finished = True
        release_error = self._owner._exit_session()
        if release_error is not None:
            if exc is not None:
                _add_note(exc, f"session cleanup also failed: {release_error!r}")
            else:
                raise release_error
        return False


class _ResidentContext:
    def __init__(self, owner: "StreamingWeights", index: int, internal: bool):
        self._owner = owner
        self._index = index
        self._internal = internal
        self._entered = False
        self._finished = False

    def __enter__(self):
        if self._entered or self._finished:
            raise RuntimeError("a resident context cannot be entered more than once")
        self._entered = True
        try:
            return self._owner._acquire_block(self._index, internal=self._internal)
        except BaseException:
            self._finished = True
            raise

    def __exit__(self, exc_type, exc, traceback):
        if not self._entered or self._finished:
            raise RuntimeError("resident context exit does not match an active entry")
        self._finished = True
        release_error = self._owner._release_block(self._index)
        if release_error is not None:
            if exc is not None:
                _add_note(exc, f"block cleanup also failed: {release_error!r}")
            else:
                raise release_error
        return False


class StreamingWeights:
    """Own one meta model and stream its schema-v2 frozen weight set."""

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
        self._callback = checkpoint
        self._lock = threading.RLock()
        self._state = "open"
        self._session_active = False
        self._lease_active = False
        self._forward_active = False
        self._owns_model = False
        self._active_block: int | None = None
        self._return_state: str | None = None
        self._shared_slots: list[_Slot] = []
        self._shared_shards: frozenset[str] = frozenset()
        self._block_slots: list[_Slot] = []
        self._block_shards: frozenset[str] = frozenset()
        self._forward_expected = 0
        self._statistics = {
            "sessions": 0,
            "leases": 0,
            "forwards": 0,
            "tensorsRead": 0,
            "logicalBytes": 0,
            "readSeconds": 0.0,
        }

        manifest = _mapping(frozen_manifest, "manifest")
        _keys(manifest, {"schemaVersion", "blocks", "shared", "shards"}, "manifest")
        if not _plain_int(manifest["schemaVersion"]) or manifest["schemaVersion"] != 2:
            raise ValueError("manifest schemaVersion must be integer 2")

        self._blocks = self._model_blocks(meta_model)
        if self._device == "mps" and len(self._blocks) != 30:
            raise ValueError("the real MPS Wan model must contain exactly 30 blocks")
        self._expected = self._model_parameters(meta_model)
        self._validate_all_meta()
        self._root_identity = self._validate_root(initial=True)
        self._shards = self._freeze_shards(manifest["shards"])
        self._shared = self._freeze_group(
            manifest["shared"], "shared", None, self._shared_parameters()
        )
        self._block_records = self._freeze_blocks(manifest["blocks"])
        self._validate_coverage()
        self._claim()

    @staticmethod
    def _model_blocks(model) -> tuple[torch.nn.Module, ...]:
        blocks = getattr(model, "blocks", None)
        if blocks is None:
            raise ValueError("meta_model must expose transformer blocks")
        try:
            result = tuple(blocks)
        except TypeError as error:
            raise TypeError("meta_model.blocks must be iterable") from error
        if not result or any(not isinstance(block, torch.nn.Module) for block in result):
            raise TypeError("every model block must be a torch module")
        return result

    @staticmethod
    def _model_parameters(model) -> Mapping[str, torch.nn.Parameter]:
        try:
            rows = list(model.named_parameters(recurse=True, remove_duplicate=False))
        except TypeError as error:
            raise TypeError("meta_model must support complete named parameter enumeration") from error
        if not rows:
            raise ValueError("meta_model has no parameters")
        result: dict[str, torch.nn.Parameter] = {}
        identities: set[int] = set()
        for name, parameter in rows:
            if not isinstance(name, str) or not name or name in result:
                raise ValueError("meta_model contains an empty or duplicate parameter name")
            if id(parameter) in identities:
                raise ValueError(f"meta_model contains an aliased parameter: {name}")
            if not isinstance(parameter, torch.nn.Parameter):
                raise TypeError(f"meta_model named a non-parameter: {name}")
            result[name] = parameter
            identities.add(id(parameter))
        return MappingProxyType(result)

    def _shared_parameters(self) -> Mapping[str, torch.nn.Parameter]:
        return MappingProxyType(
            {name: value for name, value in self._expected.items() if not name.startswith("blocks.")}
        )

    def _freeze_shards(self, value: Any) -> Mapping[str, _Identity]:
        rows = _mapping(value, "manifest shards")
        if not rows:
            raise ValueError("manifest shards must not be empty")
        result: dict[str, _Identity] = {}
        for raw_name, raw_identity in rows.items():
            name = _basename(raw_name, "shard name")
            identity = _mapping(raw_identity, f"identity for {name}")
            _keys(identity, {"device", "inode", "size", "mtimeNS"}, f"identity for {name}")
            values = (identity["device"], identity["inode"], identity["size"], identity["mtimeNS"])
            if any(not _plain_int(item) for item in values):
                raise ValueError(f"identity for {name} must contain integers")
            if values[0] < 0 or values[1] <= 0 or values[2] <= 0 or values[3] < 0:
                raise ValueError(f"identity for {name} contains an invalid value")
            if name in result:
                raise ValueError(f"duplicate shard: {name}")
            result[name] = _Identity(*values)
        return MappingProxyType(result)

    def _freeze_group(
        self,
        value: Any,
        group: str,
        block: int | None,
        expected: Mapping[str, torch.nn.Parameter],
    ) -> tuple[_Record, ...]:
        if not isinstance(value, Sequence) or isinstance(value, (str, bytes, bytearray)):
            raise ValueError(f"{group} records must be a sequence")
        if not value or not expected:
            raise ValueError(f"{group} records and model parameters must be nonempty")
        records: list[_Record] = []
        names: set[str] = set()
        prefix = f"blocks.{block}." if block is not None else ""
        for position, raw_record in enumerate(value):
            record = _mapping(raw_record, f"{group} record {position}")
            _keys(
                record,
                {"name", "shard", "shape", "sourceDtype", "targetDtype"},
                f"{group} record {position}",
            )
            name = record["name"]
            if not isinstance(name, str) or not name or name in names:
                raise ValueError(f"duplicate or invalid parameter name: {name!r}")
            if block is None:
                if name.startswith("blocks."):
                    raise ValueError("shared records cannot contain block parameters")
                relative = name
            else:
                if not name.startswith(prefix) or not name[len(prefix) :]:
                    raise ValueError(f"block parameter name must start with {prefix}")
                relative = name[len(prefix) :]
            if relative not in expected:
                raise ValueError(f"manifest names an unknown parameter: {name}")
            shard = _basename(record["shard"], f"shard for {name}")
            if shard not in self._shards:
                raise ValueError(f"parameter {name} references an unknown shard")
            shape = record["shape"]
            if (
                not isinstance(shape, Sequence)
                or isinstance(shape, (str, bytes, bytearray))
                or not shape
                or any(not _plain_int(item) or item <= 0 for item in shape)
            ):
                raise ValueError(f"parameter {name} has an invalid shape")
            shape_tuple = tuple(shape)
            if shape_tuple != tuple(expected[relative].shape):
                raise ValueError(f"parameter {name} shape differs from the meta model")
            if record["sourceDtype"] != "float32":
                raise ValueError(f"parameter {name} sourceDtype must be float32")
            target = record["targetDtype"]
            if target not in _DTYPES or target != _target_dtype(name):
                raise ValueError(f"parameter {name} violates the frozen precision rule")
            names.add(name)
            records.append(_Record(name, relative, shard, shape_tuple, target))
        expected_full = {prefix + name for name in expected}
        if names != expected_full:
            raise ValueError(
                f"{group} parameter coverage differs; missing={sorted(expected_full - names)}, "
                f"extra={sorted(names - expected_full)}"
            )
        return tuple(records)

    def _freeze_blocks(self, value: Any) -> Mapping[int, tuple[_Record, ...]]:
        rows = _mapping(value, "manifest blocks")
        expected_keys = {str(index) for index in range(len(self._blocks))}
        if set(rows) != expected_keys or any(not isinstance(key, str) for key in rows):
            raise ValueError("manifest blocks must contain every 0...N-1 string key exactly")
        result = {}
        for index, block in enumerate(self._blocks):
            expected = MappingProxyType(dict(block.named_parameters(recurse=True)))
            result[index] = self._freeze_group(rows[str(index)], "block", index, expected)
        return MappingProxyType(result)

    def _validate_coverage(self) -> None:
        records = list(self._shared)
        for index in range(len(self._blocks)):
            records.extend(self._block_records[index])
        names = [record.name for record in records]
        if len(names) != len(set(names)) or set(names) != set(self._expected):
            raise ValueError("manifest parameters do not exactly cover the meta model")
        used_shards = {record.shard for record in records}
        if used_shards != set(self._shards):
            raise ValueError(f"manifest contains unused shards: {sorted(set(self._shards) - used_shards)}")
        if self._device == "mps":
            if len(self._shared) != 15 or self._dtype_counts(self._shared) != {"float32": 9, "bfloat16": 6}:
                raise ValueError("real shared weights must be 15 with the frozen 9 FP32 / 6 BF16 split")
            for index, records_for_block in self._block_records.items():
                if len(records_for_block) != 27 or self._dtype_counts(records_for_block) != {"float32": 7, "bfloat16": 20}:
                    raise ValueError(f"real block {index} must be 27 with the frozen 7 FP32 / 20 BF16 split")
            if len(names) != 825:
                raise ValueError("real Wan manifest must contain exactly 825 parameters")

    @staticmethod
    def _dtype_counts(records: Sequence[_Record]) -> dict[str, int]:
        return {name: sum(record.target_dtype == name for record in records) for name in _DTYPES}

    def _validate_all_meta(self) -> None:
        for name, parameter in self._expected.items():
            if parameter.device.type != "meta":
                raise ValueError(f"model parameter must be meta at construction: {name}")

    @property
    def statistics(self) -> Mapping[str, int | float | str]:
        with self._lock:
            return MappingProxyType({**self._statistics, "state": self._state})

    def session(self):
        return _SessionContext(self)

    def resident(self, block_index: int):
        if not _plain_int(block_index) or not 0 <= block_index < len(self._blocks):
            raise ValueError(f"block_index must be an integer in 0...{len(self._blocks) - 1}")
        return _ResidentContext(self, block_index, False)

    def close(self) -> None:
        with self._lock:
            if self._state == "closed":
                return
            if self._session_active or self._lease_active or self._forward_active:
                raise RuntimeError("cannot close StreamingWeights during active work")
            if self._state not in ("open", "poisoned"):
                raise RuntimeError("cannot close StreamingWeights during active work")
            self._state = "closed"
        self._release_ownership()

    def _claim(self) -> None:
        with _OWNERS_LOCK:
            reference = _OWNERS.get(self._model)
            current = reference() if reference is not None else None
            if current is not None and current is not self:
                raise RuntimeError("meta_model already has a StreamingWeights owner")
            _OWNERS[self._model] = weakref.ref(self)
            self._owns_model = True

    def _release_ownership(self) -> None:
        with _OWNERS_LOCK:
            if not self._owns_model:
                return
            reference = _OWNERS.get(self._model)
            if reference is not None and reference() is self:
                del _OWNERS[self._model]
            self._owns_model = False

    def _enter_session(self):
        with self._lock:
            self._require_state("open")
            self._state = "session-loading"
        slots, shards, error, poison = self._load(self._shared, "shared", None)
        if error is not None:
            with self._lock:
                self._shared_slots = slots
                self._state = "poisoned" if poison else "open"
            raise error
        with self._lock:
            self._shared_slots = slots
            self._shared_shards = shards
            self._session_active = True
            self._state = "session-ready"
            self._statistics["sessions"] += 1
        return self._model

    def _exit_session(self) -> BaseException | None:
        with self._lock:
            if not self._session_active:
                return RuntimeError("session exit does not match an active session")
            if self._lease_active or self._forward_active:
                return RuntimeError("session exit requires an idle active session")
            was_poisoned = self._state == "poisoned"
            self._state = "session-releasing"
            slots = self._shared_slots
            shards = self._shared_shards
            orphaned_block_slots = self._block_slots
        orphaned_unresolved: list[_Slot] = []
        orphaned_error: BaseException | None = None
        if orphaned_block_slots:
            orphaned_unresolved, orphaned_error = self._cleanup(orphaned_block_slots)
        error, poison, unresolved = self._release(slots, shards, "shared", None)
        if orphaned_error is not None:
            if error is None:
                error = orphaned_error
            else:
                _add_note(error, f"orphaned block cleanup also failed: {orphaned_error!r}")
        with self._lock:
            self._block_slots = orphaned_unresolved
            self._shared_slots = unresolved
            self._shared_shards = frozenset()
            self._session_active = False
            self._state = (
                "poisoned"
                if was_poisoned or poison or unresolved or orphaned_unresolved
                else "open"
            )
        return error

    def _acquire_block(self, index: int, *, internal: bool):
        with self._lock:
            expected = "forward" if internal else "session-ready"
            self._require_state(expected)
            self._return_state = expected
            self._active_block = index
            self._lease_active = True
            self._state = "block-loading"
        slots, shards, error, poison = self._load(self._block_records[index], "block", index)
        if error is not None:
            with self._lock:
                self._block_slots = slots
                self._active_block = None
                self._lease_active = False
                self._state = "poisoned" if poison else expected
                self._return_state = None
            raise error
        with self._lock:
            self._block_slots = slots
            self._block_shards = shards
            self._state = "block-resident"
            self._statistics["leases"] += 1
        return self._blocks[index]

    def _release_block(self, index: int) -> BaseException | None:
        with self._lock:
            if (
                not self._lease_active
                or self._state != "block-resident"
                or self._active_block != index
            ):
                return RuntimeError("resident lease state is inconsistent")
            self._state = "block-releasing"
            slots = self._block_slots
            shards = self._block_shards
            return_state = self._return_state
        error, poison, unresolved = self._release(slots, shards, "block", index)
        with self._lock:
            self._block_slots = unresolved
            self._block_shards = frozenset()
            self._active_block = None
            self._lease_active = False
            self._return_state = None
            self._state = "poisoned" if poison or unresolved else return_state
        return error

    def _load(
        self, records: Sequence[_Record], group: str, block: int | None
    ) -> tuple[list[_Slot], frozenset[str], BaseException | None, bool]:
        slots: list[_Slot] = []
        shards: set[str] = set()
        synchronization_failed = False
        try:
            self._checkpoint("before_load", group, block, completed=0)
            for record in records:
                source = None
                converted = None
                slot = None
                try:
                    started = time.perf_counter()
                    source = self._read_source(record)
                    elapsed = time.perf_counter() - started
                    logical_bytes = source.numel() * source.element_size()
                    with self._lock:
                        self._statistics["tensorsRead"] += 1
                        self._statistics["logicalBytes"] += logical_bytes
                        self._statistics["readSeconds"] += elapsed
                    shards.add(record.shard)
                    self._checkpoint(
                        "after_read", group, block, completed=len(slots), name=record.name,
                        logicalBytes=logical_bytes, readSeconds=elapsed,
                    )
                    converted = source.to(
                        device=self._device, dtype=_DTYPES[record.target_dtype]
                    )
                    source = None
                    if not bool(torch.isfinite(converted).all().item()):
                        raise ValueError(
                            f"converted tensor {record.name} contains a nonfinite value"
                        )
                    self._checkpoint(
                        "before_install", group, block,
                        completed=len(slots), name=record.name,
                    )
                    slot = self._install(record, converted)
                    slots.append(slot)
                    slot = None
                    converted = None
                    self._checkpoint(
                        "after_install", group, block,
                        completed=len(slots), name=record.name,
                    )
                finally:
                    source = None
                    converted = None
                    slot = None
            try:
                self._synchronize()
            except BaseException:
                synchronization_failed = True
                raise
            self._checkpoint("ready", group, block, completed=len(slots))
            return slots, frozenset(shards), None, False
        except BaseException as error:
            unresolved, cleanup_error = self._cleanup(slots)
            poison = isinstance(error, _IdentityError) or synchronization_failed or cleanup_error is not None
            if cleanup_error is not None:
                _add_note(error, f"cleanup after load failure also failed: {cleanup_error!r}")
            return unresolved, frozenset(), error, poison

    def _release(
        self,
        slots: list[_Slot],
        shards: frozenset[str],
        group: str,
        block: int | None,
    ) -> tuple[BaseException | None, bool, list[_Slot]]:
        first: BaseException | None = None
        poison = False
        try:
            self._checkpoint("before_release", group, block, completed=len(slots))
        except BaseException as error:
            first = error
        try:
            for shard in shards:
                self._verify_shard(shard)
        except BaseException as error:
            poison = isinstance(error, _IdentityError)
            if first is None:
                first = error
            else:
                _add_note(first, f"shard verification also failed: {error!r}")
        unresolved, cleanup_error = self._cleanup(slots)
        if cleanup_error is not None:
            poison = True
            if first is None:
                first = cleanup_error
            else:
                _add_note(first, f"cleanup also failed: {cleanup_error!r}")
        if cleanup_error is None:
            try:
                self._checkpoint("released", group, block, completed=len(slots))
            except BaseException as error:
                if first is None:
                    first = error
                else:
                    _add_note(first, f"released checkpoint also failed: {error!r}")
        return first, poison, unresolved

    def forward(self, *args, **kwargs):
        with self._lock:
            self._require_state("session-ready")
            self._state = "forward"
            self._forward_active = True
            self._forward_expected = 0
        installed: list[tuple[torch.nn.Module, bool, Any, Any]] = []
        primary: BaseException | None = None
        result = None
        try:
            for index, block in enumerate(self._blocks):
                had_instance = "forward" in block.__dict__
                original_instance = block.__dict__.get("forward")
                saved_forward = block.forward

                def wrapper(*block_args, _index=index, _saved=saved_forward, **block_kwargs):
                    return self._run_block(_index, _saved, block_args, block_kwargs)

                block.forward = wrapper
                installed.append((block, had_instance, original_instance, wrapper))
            with torch.inference_mode():
                result = self._model(*args, **kwargs)
            with self._lock:
                if self._forward_expected != len(self._blocks):
                    raise RuntimeError(
                        f"model forward executed {self._forward_expected} of {len(self._blocks)} blocks"
                    )
        except BaseException as error:
            primary = error

        restore_error = self._restore_forwards(installed)
        with self._lock:
            self._forward_active = False
            if restore_error is not None or self._state == "poisoned":
                self._state = "poisoned"
            elif self._state == "forward":
                self._state = "session-ready"
            else:
                restore_error = restore_error or RuntimeError(
                    f"forward ended in inconsistent state: {self._state}"
                )
                self._state = "poisoned"
            if primary is None and restore_error is None:
                self._statistics["forwards"] += 1
        if primary is not None:
            result = None
            if restore_error is not None:
                _add_note(primary, f"forward restoration also failed: {restore_error!r}")
            raise primary
        if restore_error is not None:
            result = None
            raise restore_error
        return result

    def _run_block(self, index: int, saved_forward, args: tuple, kwargs: dict):
        result = None
        try:
            with self._lock:
                self._require_state("forward")
                if index != self._forward_expected:
                    raise RuntimeError(
                        f"model block order differs: expected {self._forward_expected}, got {index}"
                    )
            self._checkpoint("before_forward", "block", index, completed=index)
            with _ResidentContext(self, index, True):
                result = saved_forward(*args, **kwargs)
            self._checkpoint("after_forward", "block", index, completed=index + 1)
            with self._lock:
                self._require_state("forward")
                self._forward_expected += 1
            return result
        finally:
            result = None

    def _restore_forwards(
        self, installed: list[tuple[torch.nn.Module, bool, Any, Any]]
    ) -> BaseException | None:
        errors: list[BaseException] = []
        for block, had_instance, original, wrapper in reversed(installed):
            try:
                if block.__dict__.get("forward") is not wrapper:
                    raise RuntimeError("a block forward changed while streaming")
                if had_instance:
                    block.forward = original
                else:
                    delattr(block, "forward")
            except BaseException as error:
                errors.append(error)
        if not errors:
            return None
        primary = errors[0]
        for error in errors[1:]:
            _add_note(primary, f"additional forward restoration failure: {error!r}")
        return primary

    def _checkpoint(
        self,
        stage: str,
        group: str,
        block: int | None,
        *,
        completed: int,
        name: str | None = None,
        **extra: int | float,
    ) -> None:
        if self._callback is None:
            return
        event: dict[str, str | int | float] = {
            "stage": stage,
            "group": group,
            "completed": completed,
        }
        if block is not None:
            event["block"] = block
        if name is not None:
            event["name"] = name
        event.update(extra)
        self._callback(MappingProxyType(event))

    def _validate_root(self, *, initial: bool = False) -> tuple[int, int]:
        try:
            value = os.lstat(self._root)
        except OSError as error:
            raise _IdentityError(f"model root is unavailable: {self._root}") from error
        if stat.S_ISLNK(value.st_mode) or not stat.S_ISDIR(value.st_mode):
            raise _IdentityError("model_root must be an ordinary directory")
        try:
            if self._root.resolve(strict=True) != self._root:
                raise _IdentityError("model_root must not traverse a symbolic link")
        except OSError as error:
            raise _IdentityError("model_root cannot be resolved safely") from error
        identity = (value.st_dev, value.st_ino)
        if not initial and identity != self._root_identity:
            raise _IdentityError("model_root identity changed")
        return identity

    def _identity_from_path(self, shard: str) -> _Identity:
        self._validate_root()
        path = self._root / shard
        try:
            value = os.lstat(path)
        except OSError as error:
            raise _IdentityError(f"shard is unavailable: {shard}") from error
        if stat.S_ISLNK(value.st_mode) or not stat.S_ISREG(value.st_mode):
            raise _IdentityError(f"shard must be an ordinary file: {shard}")
        return _Identity.from_stat(value)

    def _verify_shard(self, shard: str) -> None:
        if self._identity_from_path(shard) != self._shards[shard]:
            raise _IdentityError(f"shard identity differs from manifest: {shard}")

    def _read_source(self, record: _Record) -> torch.Tensor:
        self._verify_shard(record.shard)
        path = self._root / record.shard
        expected = self._shards[record.shard]
        source = None
        handle = None
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(path, flags)
        except OSError as error:
            raise _IdentityError(f"cannot safely open shard: {record.shard}") from error
        try:
            if _Identity.from_stat(os.fstat(descriptor)) != expected:
                raise _IdentityError(f"opened shard identity differs: {record.shard}")
            descriptor_path = Path("/dev/fd") / str(descriptor)
            if not descriptor_path.exists():
                descriptor_path = Path("/proc/self/fd") / str(descriptor)
            if not descriptor_path.exists():
                raise OSError("this platform has no safe descriptor path")
            try:
                with safe_open(str(descriptor_path), framework="pt", device="cpu") as handle:
                    if record.name not in handle.keys():
                        raise ValueError(f"tensor {record.name} is missing from {record.shard}")
                    source = handle.get_tensor(record.name)
                    if source.dtype != torch.float32:
                        raise ValueError(f"tensor {record.name} is not source float32")
                    if tuple(source.shape) != record.shape:
                        raise ValueError(f"tensor {record.name} shape differs from manifest")
                    if not bool(torch.isfinite(source).all().item()):
                        raise ValueError(f"tensor {record.name} contains a nonfinite value")
                    source = source.clone(memory_format=torch.contiguous_format)
            except (ValueError, _IdentityError):
                raise
            except BaseException as error:
                raise ValueError(f"cannot read tensor {record.name} from {record.shard}") from error
            if _Identity.from_stat(os.fstat(descriptor)) != expected:
                raise _IdentityError(f"shard changed while reading: {record.shard}")
            self._verify_shard(record.shard)
            return source
        finally:
            source = None
            handle = None
            os.close(descriptor)

    def _slot(self, record: _Record) -> _Slot:
        parent_name, separator, leaf = record.name.rpartition(".")
        try:
            parent = self._model.get_submodule(parent_name) if separator else self._model
        except AttributeError as error:
            raise ValueError(f"parameter parent disappeared: {record.name}") from error
        original = parent._parameters.get(leaf)
        if not isinstance(original, torch.nn.Parameter):
            raise ValueError(f"parameter disappeared: {record.name}")
        if original.device.type != "meta":
            raise ValueError(f"parameter is already resident: {record.name}")
        return _Slot(parent, leaf, original)

    def _install(self, record: _Record, value: torch.Tensor) -> _Slot:
        try:
            if tuple(value.shape) != record.shape:
                raise ValueError(f"converted tensor shape differs: {record.name}")
            if value.dtype != _DTYPES[record.target_dtype] or value.device.type != self._device:
                raise RuntimeError(f"converted tensor placement differs: {record.name}")
            slot = self._slot(record)
            slot.module._parameters[slot.name] = torch.nn.Parameter(
                value, requires_grad=slot.original.requires_grad
            )
            return slot
        finally:
            value = None

    def _synchronize(self) -> None:
        if self._device == "mps":
            if not torch.backends.mps.is_available():
                raise RuntimeError("MPS was requested but is unavailable")
            torch.mps.synchronize()

    def _cleanup(self, slots: list[_Slot]) -> tuple[list[_Slot], BaseException | None]:
        errors: list[BaseException] = []
        unresolved: list[_Slot] = []
        try:
            self._synchronize()
        except BaseException as error:
            errors.append(error)
        for slot in reversed(slots):
            try:
                slot.module._parameters[slot.name] = slot.original
            except BaseException as error:
                unresolved.append(slot)
                errors.append(error)
        if not errors:
            return [], None
        primary = errors[0]
        for error in errors[1:]:
            _add_note(primary, f"additional cleanup failure: {error!r}")
        return list(reversed(unresolved)), primary

    def _require_state(self, expected: str) -> None:
        if self._state == "closed":
            raise RuntimeError("StreamingWeights is closed")
        if self._state == "poisoned":
            raise WeightSessionPoisonedError("StreamingWeights is poisoned")
        if self._state != expected:
            raise RuntimeError(f"StreamingWeights requires state {expected}, got {self._state}")


__all__ = ["StreamingWeights", "WeightLoadCancelled", "WeightSessionPoisonedError"]
