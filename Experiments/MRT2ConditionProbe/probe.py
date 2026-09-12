#!/usr/bin/env python3
"""Bounded Magenta RT 2 condition probe.

The production CLI has no fake backend. Tests inject an adapter only through
the Python entry point, so invoking this file always selects a real SDK path.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import gc
import hashlib
import importlib.metadata
import json
import math
import os
from pathlib import Path, PurePosixPath
import platform
import signal
import stat
import struct
import sys
import time
from typing import Any, Callable, Protocol

from conditions import (
    ProbeRequest,
    RequestError,
    build_note_frames,
    canonical_json_bytes,
    condition_summary,
    parse_request,
)


REQUEST_LIMIT = 128 * 1024
MANIFEST_LIMIT = 2 * 1024 * 1024
EXPECTED_REPOSITORY = "google/magenta-realtime-2"
EXPECTED_MODEL_REVISION = "010aa0dcb0dfd27b24f0ad07b4dad63e8f9521cc"
EXPECTED_SOURCE_REVISION = "694a545e4ba0b88bf1150137b129582166d3e07f"
MANIFEST_NAME = "D-MODEL-MANIFEST.json"
SAMPLE_RATE = 48_000
CHANNELS = 2
SAMPLES_PER_FRAME = 1_920
SAMPLE_WIDTH = 4
TEMPERATURE = 1.3
TOP_K = 40
CFG_SCALES = {"musiccoca": 3.0, "notes": 1.0, "drums": 1.0}


class ProbeInputError(ValueError):
    pass


class ProbeCancelled(RuntimeError):
    pass


class ProbeTimedOut(RuntimeError):
    pass


class CleanupFailure(RuntimeError):
    pass


class AdapterConstructionError(RuntimeError):
    def __init__(self, original: BaseException, cleanup: dict[str, Any]):
        super().__init__(f"{type(original).__name__}: {original}")
        self.original_type = type(original).__name__
        self.cleanup = cleanup


@dataclass
class Cancellation:
    requested: bool = False

    def request(self) -> None:
        self.requested = True


@dataclass(frozen=True)
class OwnedPublication:
    device: int
    inode: int
    size: int
    sha256: str


class Adapter(Protocol):
    def identity(self) -> dict[str, Any]: ...

    def generate_frame(
        self, note_frame: tuple[int, ...] | None, state: Any
    ) -> tuple[Any, Any]: ...

    def close(self, state: Any) -> dict[str, Any]: ...

    def final_cleanup(self) -> dict[str, Any]: ...


AdapterFactory = Callable[[str, Path, ProbeRequest], Adapter]
ReportWriter = Callable[[Path, dict[str, Any]], None]


def _absolute(path: str) -> Path:
    return Path(os.path.abspath(path))


def _ensure_no_symlink_components(path: Path, *, allow_missing_leaf: bool) -> None:
    if not path.is_absolute():
        raise ProbeInputError(f"路径必须是绝对路径：{path}")
    current = Path(path.anchor)
    parts = path.parts[1:]
    for index, part in enumerate(parts):
        current = current / part
        try:
            info = os.lstat(current)
        except FileNotFoundError:
            if allow_missing_leaf and index == len(parts) - 1:
                return
            raise ProbeInputError(f"路径组件不存在：{current}") from None
        except OSError as error:
            raise ProbeInputError(f"无法检查路径组件 {current}：{error}") from error
        if stat.S_ISLNK(info.st_mode):
            raise ProbeInputError(f"路径及其祖先不允许符号链接：{current}")


def _read_regular_file(path: Path, maximum: int, label: str) -> bytes:
    try:
        info = os.lstat(path)
    except OSError as error:
        raise ProbeInputError(f"无法检查{label}：{error}") from error
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise ProbeInputError(f"{label}必须是非符号链接普通文件：{path}")
    if info.st_size > maximum:
        raise ProbeInputError(f"{label}超过 {maximum} bytes 上限")
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
        try:
            opened_info = os.fstat(descriptor)
            if not stat.S_ISREG(opened_info.st_mode):
                raise ProbeInputError(f"{label}不是普通文件：{path}")
            if opened_info.st_size > maximum:
                raise ProbeInputError(f"{label}超过 {maximum} bytes 上限")
            chunks: list[bytes] = []
            remaining = maximum + 1
            while remaining:
                chunk = os.read(descriptor, min(65_536, remaining))
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            raw = b"".join(chunks)
            if len(raw) > maximum:
                raise ProbeInputError(f"{label}超过 {maximum} bytes 上限")
            return raw
        finally:
            os.close(descriptor)
    except ProbeInputError:
        raise
    except OSError as error:
        raise ProbeInputError(f"无法读取{label}：{error}") from error


def _paths_overlap(first: Path, second: Path) -> bool:
    first_text = os.fspath(first)
    second_text = os.fspath(second)
    try:
        common = os.path.commonpath((first_text, second_text))
    except ValueError:
        return False
    return common == first_text or common == second_text


def _prepare_paths(
    model_root_text: str, request_text: str, output_text: str
) -> tuple[Path, Path, Path]:
    model_root = _absolute(model_root_text)
    request_path = _absolute(request_text)
    output_root = _absolute(output_text)
    if not Path(model_root_text).is_absolute():
        raise ProbeInputError("--model-root 必须是绝对目录")
    if not Path(output_text).is_absolute():
        raise ProbeInputError("--output 必须是绝对的新任务目录")
    _ensure_no_symlink_components(model_root, allow_missing_leaf=False)
    if not model_root.is_dir():
        raise ProbeInputError(f"model-root 不是目录：{model_root}")
    _ensure_no_symlink_components(output_root, allow_missing_leaf=True)
    if output_root.exists() or os.path.lexists(output_root):
        raise ProbeInputError(f"output 必须不存在：{output_root}")
    parent = output_root.parent
    if not parent.is_dir():
        raise ProbeInputError(f"output 的父目录必须已存在：{parent}")
    request_physical = Path(os.path.realpath(request_path))
    if _paths_overlap(output_root, model_root):
        raise ProbeInputError("output 不得与 model-root 重叠")
    if _paths_overlap(output_root, request_physical):
        raise ProbeInputError("output 不得与 request 重叠")
    return model_root, request_path, output_root


def _json_without_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ProbeInputError(f"模型清单字段重复：{key}")
        result[key] = value
    return result


def _reject_constant(token: str) -> None:
    raise ProbeInputError(f"模型清单不允许非有限数值：{token}")


def _manifest_integer(value: Any, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ProbeInputError(f"模型清单 {field} 必须是非负整数")
    return value


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    finally:
        os.close(descriptor)
    return digest.hexdigest()


def _validate_manifest(model_root: Path) -> dict[str, Any]:
    manifest_path = model_root / MANIFEST_NAME
    raw = _read_regular_file(manifest_path, MANIFEST_LIMIT, "模型清单")
    try:
        document = json.loads(
            raw.decode("utf-8", errors="strict"),
            object_pairs_hook=_json_without_duplicates,
            parse_constant=_reject_constant,
        )
    except ProbeInputError:
        raise
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError) as error:
        raise ProbeInputError(f"模型清单不是严格 UTF-8 JSON：{error}") from error
    required = {"repository", "revision", "license", "files", "totalBytes"}
    if not isinstance(document, dict) or set(document) != required:
        raise ProbeInputError("模型清单必须且只能包含 repository/revision/license/files/totalBytes")
    if document["repository"] != EXPECTED_REPOSITORY:
        raise ProbeInputError("模型清单 repository 不符合冻结值")
    if document["revision"] != EXPECTED_MODEL_REVISION:
        raise ProbeInputError("模型清单 revision 不符合冻结值")
    if not isinstance(document["license"], str) or not document["license"]:
        raise ProbeInputError("模型清单 license 必须是非空字符串")
    files = document["files"]
    if not isinstance(files, list) or not files:
        raise ProbeInputError("模型清单 files 必须是非空数组")
    declared_total = _manifest_integer(document["totalBytes"], "totalBytes")
    observed_total = 0
    seen: set[str] = set()
    verified_files: list[dict[str, Any]] = []
    for index, entry in enumerate(files):
        if not isinstance(entry, dict) or set(entry) != {"path", "size", "sha256"}:
            raise ProbeInputError(f"模型清单 files[{index}] 字段不合法")
        relative = entry["path"]
        if not isinstance(relative, str) or not relative:
            raise ProbeInputError(f"模型清单 files[{index}].path 不合法")
        pure = PurePosixPath(relative)
        if (
            pure.is_absolute()
            or ".." in pure.parts
            or "." in pure.parts
            or "\\" in relative
            or str(pure) != relative
        ):
            raise ProbeInputError(f"模型清单路径逃逸或未规范化：{relative}")
        if relative in seen:
            raise ProbeInputError(f"模型清单路径重复：{relative}")
        seen.add(relative)
        size = _manifest_integer(entry["size"], f"files[{index}].size")
        expected_sha = entry["sha256"]
        if (
            not isinstance(expected_sha, str)
            or len(expected_sha) != 64
            or any(character not in "0123456789abcdef" for character in expected_sha)
        ):
            raise ProbeInputError(f"模型清单 files[{index}].sha256 不合法")
        file_path = model_root.joinpath(*pure.parts)
        _ensure_no_symlink_components(file_path, allow_missing_leaf=False)
        try:
            info = os.lstat(file_path)
        except OSError as error:
            raise ProbeInputError(f"模型文件不可用 {relative}：{error}") from error
        if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
            raise ProbeInputError(f"模型文件必须是非符号链接普通文件：{relative}")
        if info.st_size != size:
            raise ProbeInputError(f"模型文件大小不符：{relative}")
        try:
            observed_sha = _sha256_file(file_path)
        except OSError as error:
            raise ProbeInputError(f"模型文件读取失败 {relative}：{error}") from error
        if observed_sha != expected_sha:
            raise ProbeInputError(f"模型文件摘要不符：{relative}")
        observed_total += size
        verified_files.append({"path": relative, "size": size, "sha256": observed_sha})
    if observed_total != declared_total:
        raise ProbeInputError("模型清单 totalBytes 与逐文件总和不符")
    return {
        "repository": document["repository"],
        "revision": document["revision"],
        "license": document["license"],
        "totalBytes": observed_total,
        "files": verified_files,
        "manifestSha256": hashlib.sha256(raw).hexdigest(),
    }


def _directory_fsync(directory: Path) -> None:
    descriptor = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _owned_publication(path: Path, expected_sha256: str) -> OwnedPublication:
    info = os.lstat(path)
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise RuntimeError(f"发布对象不是普通文件：{path}")
    return OwnedPublication(
        device=info.st_dev,
        inode=info.st_ino,
        size=info.st_size,
        sha256=expected_sha256,
    )


def _remove_if_owned(path: Path, owned: OwnedPublication) -> dict[str, Any]:
    """Remove only the exact regular file this process published."""
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return {"removed": False, "reason": "alreadyMissing"}
    except OSError as error:
        return {"removed": False, "reason": "lstatFailed", "error": str(error)}
    if (
        stat.S_ISLNK(info.st_mode)
        or not stat.S_ISREG(info.st_mode)
        or info.st_dev != owned.device
        or info.st_ino != owned.inode
        or info.st_size != owned.size
    ):
        return {"removed": False, "reason": "identityChanged", "preserved": True}
    try:
        if _sha256_file(path) != owned.sha256:
            return {"removed": False, "reason": "contentChanged", "preserved": True}
        # Recheck identity after hashing before unlinking by name.
        current = os.lstat(path)
        if (
            current.st_dev != owned.device
            or current.st_ino != owned.inode
            or stat.S_ISLNK(current.st_mode)
            or not stat.S_ISREG(current.st_mode)
        ):
            return {"removed": False, "reason": "identityChanged", "preserved": True}
        os.unlink(path)
        _directory_fsync(path.parent)
        return {"removed": True, "reason": "ownedPublicationRolledBack"}
    except OSError as error:
        return {"removed": False, "reason": "rollbackFailed", "error": str(error)}


def _publish_no_replace(
    temporary: Path, destination: Path, *, expected_sha256: str
) -> OwnedPublication:
    if os.path.lexists(destination):
        raise FileExistsError(f"拒绝覆盖：{destination}")
    owned: OwnedPublication | None = None
    try:
        os.link(temporary, destination, follow_symlinks=False)
        owned = _owned_publication(destination, expected_sha256)
        os.unlink(temporary)
        _directory_fsync(destination.parent)
        return owned
    except BaseException:
        if owned is not None:
            _remove_if_owned(destination, owned)
        raise


def _report_payload(document: dict[str, Any]) -> bytes:
    return json.dumps(
        document,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        indent=2,
    ).encode("utf-8") + b"\n"


def _remove_if_matching_payload(path: Path, payload: bytes) -> dict[str, Any]:
    """Roll back a report only when its identity and full content are ours."""
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return {"removed": False, "reason": "alreadyMissing"}
    except OSError as error:
        return {"removed": False, "reason": "lstatFailed", "error": str(error)}
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        return {"removed": False, "reason": "identityChanged", "preserved": True}
    owned = OwnedPublication(
        device=info.st_dev,
        inode=info.st_ino,
        size=len(payload),
        sha256=hashlib.sha256(payload).hexdigest(),
    )
    return _remove_if_owned(path, owned)


def _write_report(path: Path, document: dict[str, Any]) -> None:
    temporary = path.parent / "report.partial.json"
    payload = _report_payload(document)
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        offset = 0
        while offset < len(payload):
            offset += os.write(descriptor, payload[offset:])
        os.fsync(descriptor)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise
    finally:
        os.close(descriptor)
    try:
        _publish_no_replace(
            temporary,
            path,
            expected_sha256=hashlib.sha256(payload).hexdigest(),
        )
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def _wav_header(data_bytes: int) -> bytes:
    if data_bytes > 0xFFFFFFFF - 36:
        raise ValueError("WAV 数据超过 RIFF 32-bit 上限")
    byte_rate = SAMPLE_RATE * CHANNELS * SAMPLE_WIDTH
    block_align = CHANNELS * SAMPLE_WIDTH
    return struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF",
        36 + data_bytes,
        b"WAVE",
        b"fmt ",
        16,
        3,  # WAVE_FORMAT_IEEE_FLOAT
        CHANNELS,
        SAMPLE_RATE,
        byte_rate,
        block_align,
        32,
        b"data",
        data_bytes,
    )


def _frame_bytes(waveform: Any) -> bytes:
    if getattr(waveform, "sample_rate", None) != SAMPLE_RATE:
        raise RuntimeError("后端帧采样率必须是 48000 Hz")
    samples = getattr(waveform, "samples", None)
    if samples is None:
        raise RuntimeError("后端没有返回 samples")
    shape = tuple(getattr(samples, "shape", ()))
    if shape != (SAMPLES_PER_FRAME, CHANNELS):
        raise RuntimeError(
            f"后端帧形状必须是 ({SAMPLES_PER_FRAME}, {CHANNELS})，实际为 {shape}"
        )
    dtype = getattr(samples, "dtype", None)
    dtype_name = getattr(dtype, "name", str(dtype))
    if dtype_name != "float32":
        raise RuntimeError(f"后端帧必须是 float32，实际为 {dtype_name}")
    try:
        payload = samples.tobytes(order="C")
    except TypeError:
        payload = samples.tobytes()
    expected_bytes = SAMPLES_PER_FRAME * CHANNELS * SAMPLE_WIDTH
    if len(payload) != expected_bytes:
        raise RuntimeError("后端帧 float32 byte 长度不符")
    for (value,) in struct.iter_unpack("<f", payload):
        if not math.isfinite(value):
            raise RuntimeError("后端帧包含 NaN 或 Infinity")
    return payload


def _hash_file(path: Path) -> tuple[int, str]:
    size = path.stat().st_size
    return size, _sha256_file(path)


def _runtime_identity() -> dict[str, Any]:
    return {
        "pythonVersion": platform.python_version(),
        "pythonImplementation": platform.python_implementation(),
        "executable": sys.executable,
        "expectedUpstreamSourceRevision": EXPECTED_SOURCE_REVISION,
    }


class _SDKAdapter:
    """Imports MLX/Magenta only when a real run explicitly constructs it."""

    def __init__(self, backend: str, model_root: Path, request: ProbeRequest):
        self._backend = backend
        self._model: Any = None
        self._embedding: Any = None
        self._mx: Any = None
        self._musiccoca_key = "unknown"
        self._notes_key = "unknown"
        self._identity: dict[str, Any] = {}
        try:
            import mlx.core as mx
            from magenta_rt import MagentaRT2Mlx, MagentaRT2StdMlxfn, paths
            from magenta_rt.config import MUSICCOCA, PIANOROLL_WITH_ONSETS

            self._mx = mx
            self._musiccoca_key = MUSICCOCA.key
            self._notes_key = PIANOROLL_WITH_ONSETS.key
            paths.set_magenta_home(model_root)
            mx.random.seed(request.seed)
            arguments = {
                "size": "mrt2_small",
                "temperature": TEMPERATURE,
                "top_k": TOP_K,
                "cfg_scales": dict(CFG_SCALES),
            }
            if backend == "exported":
                self._model = MagentaRT2StdMlxfn(warmup_steps=5, **arguments)
                precision = (
                    "exported graph internal precision unknown; graph int16 output "
                    "is converted by the SDK to float32 using division by 32768"
                )
            else:
                self._model = MagentaRT2Mlx(bits=None, **arguments)
                precision = (
                    "bits=None disables additional quantization; Depthformer loader "
                    "uses BF16, codec dtype remains observed/unknown"
                )
            self._embedding = self._model.embed_style(
                request.prompt, use_mapper=True
            )
            self._identity = {
                "backendClass": type(self._model).__name__,
                "module": type(self._model).__module__,
                "moduleFile": sys.modules[type(self._model).__module__].__file__,
                "magentaRtVersion": self._package_version("magenta-rt"),
                "mlxVersion": self._package_version("mlx"),
                "precision": precision,
            }
        except BaseException as error:
            self._model = None
            self._embedding = None
            gc.collect()
            attempted_cleanup = self._best_effort_sync_and_clear()
            cleanup = {
                "status": "unknownAfterConstructorFailure",
                "released": False,
                "constructorError": f"{type(error).__name__}: {error}",
                "attemptedSynchronizationAndCacheClear": attempted_cleanup,
            }
            raise AdapterConstructionError(error, cleanup) from error

    @staticmethod
    def _package_version(distribution: str) -> str:
        try:
            return importlib.metadata.version(distribution)
        except importlib.metadata.PackageNotFoundError:
            return "unknown"

    def identity(self) -> dict[str, Any]:
        return dict(self._identity)

    def generate_frame(
        self, note_frame: tuple[int, ...] | None, state: Any
    ) -> tuple[Any, Any]:
        conditioning: dict[str, Any] = {self._musiccoca_key: self._embedding}
        if note_frame is not None:
            conditioning[self._notes_key] = list(note_frame)
        return self._model.generate(
            conditioning=conditioning,
            cfg_scales=dict(CFG_SCALES),
            temperature=TEMPERATURE,
            top_k=TOP_K,
            frames=1,
            state=state,
        )

    def _memory(self) -> dict[str, Any]:
        result: dict[str, Any] = {
            "activeBytes": "unknown",
            "cacheBytes": "unknown",
            "peakBytes": "unknown",
        }
        errors: dict[str, str] = {}
        metal = getattr(self._mx, "metal", None)
        for key, name in (
            ("activeBytes", "get_active_memory"),
            ("cacheBytes", "get_cache_memory"),
            ("peakBytes", "get_peak_memory"),
        ):
            function = getattr(self._mx, name, None)
            api = f"mlx.core.{name}"
            if not callable(function):
                function = getattr(metal, name, None)
                api = f"mlx.core.metal.{name}"
            if callable(function):
                try:
                    result[key] = int(function())
                    result[f"{key}API"] = api
                except Exception as error:
                    errors[key] = f"{type(error).__name__}: {error}"
            else:
                errors[key] = "API unavailable"
        if errors:
            result["observationErrors"] = errors
        return result

    def _best_effort_sync_and_clear(self) -> dict[str, Any]:
        outcome: dict[str, Any] = {"synchronized": False, "cacheCleared": False}
        if self._mx is None:
            return outcome
        synchronize = getattr(self._mx, "synchronize", None)
        if callable(synchronize):
            try:
                synchronize()
                outcome["synchronized"] = True
            except Exception as error:
                outcome["synchronizeError"] = f"{type(error).__name__}: {error}"
        else:
            outcome["synchronizeError"] = "mlx.core.synchronize API unavailable"
        metal = getattr(self._mx, "metal", None)
        clear_cache = getattr(self._mx, "clear_cache", None)
        clear_cache_api = "mlx.core.clear_cache"
        if not callable(clear_cache):
            clear_cache = getattr(metal, "clear_cache", None)
            clear_cache_api = "mlx.core.metal.clear_cache"
        if callable(clear_cache):
            try:
                clear_cache()
                outcome["cacheCleared"] = True
            except Exception as error:
                outcome["clearCacheError"] = f"{type(error).__name__}: {error}"
            outcome["clearCacheAPI"] = clear_cache_api
        else:
            outcome["clearCacheError"] = "MLX clear_cache API unavailable"
        return outcome

    def close(self, state: Any) -> dict[str, Any]:
        before = self._memory()
        if isinstance(state, list):
            state.clear()
        self._embedding = None
        self._model = None
        return {"memoryBeforeRelease": before, "releaseRequested": True}

    def final_cleanup(self) -> dict[str, Any]:
        gc.collect()
        result = self._best_effort_sync_and_clear()
        gc.collect()
        result["memoryAfterRelease"] = self._memory()
        # A successful terminal state requires both draining queued MLX work
        # and clearing the cache. Missing or failed operations remain visible
        # and prevent publication.
        result["released"] = bool(
            result.get("synchronized") and result.get("cacheCleared")
        )
        return result


def _default_adapter_factory(
    backend: str, model_root: Path, request: ProbeRequest
) -> Adapter:
    return _SDKAdapter(backend, model_root, request)


def _check_stop(cancellation: Cancellation, deadline: float, clock: Callable[[], float]) -> None:
    if cancellation.requested:
        raise ProbeCancelled("收到取消请求；已等待当前边界")
    if clock() >= deadline:
        raise ProbeTimedOut("达到 timeout-seconds；仅在可检查边界停止")


def _base_report(
    request: ProbeRequest,
    backend: str,
    started_wall: str,
) -> dict[str, Any]:
    summary = condition_summary(request)
    summary.update(
        {
            "sha256": request.condition_sha256,
            "timeBase": {"frameRate": request.frame_rate, "frameDurationSeconds": 0.04},
            "durationFrames": request.duration_frames,
            "encoding": "per pitch: 0=off, 1=sustain, 2=onset; half-open note intervals",
            "inputExactness": "exact",
            "audioCompliance": "pending/approximate until real listening and independent analysis",
        }
    )
    return {
        "schemaVersion": 1,
        "outcome": "running",
        "startedAt": started_wall,
        "requestSha256": request.source_sha256,
        "executedRequest": request.executed_snapshot(),
        "condition": summary,
        "backendMode": backend,
        "runtime": _runtime_identity(),
        "sampling": {
            "temperature": TEMPERATURE,
            "topK": TOP_K,
            "cfg": dict(CFG_SCALES),
            "seed": request.seed,
        },
        "model": None,
        "sdk": {"status": "notLoaded"},
        "timing": {
            "loadSeconds": None,
            "firstAudioSeconds": None,
            "frameSeconds": [],
            "totalSeconds": None,
        },
        "cleanup": {"status": "notStarted"},
        "output": None,
        "quality": "pending",
    }


def _finish_adapter(adapter: Adapter, state_holder: list[Any]) -> dict[str, Any]:
    # Popping makes this function the sole owner of the streaming state. Drop
    # that final reference before measuring the post-release allocator state.
    state = state_holder.pop()
    close_result = adapter.close(state)
    state = None
    gc.collect()
    final_result = adapter.final_cleanup()
    result = dict(close_result)
    result.update(final_result)
    return result


def _mark_cleanup_failure(
    report: dict[str, Any], cancellation: Cancellation, message: str
) -> None:
    prior_outcome = report.get("outcome")
    prior_error = report.get("error")
    report["failureContext"] = {
        "priorOutcome": prior_outcome,
        "priorError": prior_error,
        "cancellationRequested": cancellation.requested,
    }
    report["outcome"] = "failed"
    report["error"] = {"type": "CleanupFailure", "message": message}


def _cleanup_complete(cleanup: dict[str, Any]) -> bool:
    return (
        cleanup.get("released") is True
        and cleanup.get("synchronized") is True
        and cleanup.get("cacheCleared") is True
    )


def run_probe(
    *,
    model_root_text: str,
    request_text: str,
    output_text: str,
    backend: str,
    timeout_seconds: float,
    adapter_factory: AdapterFactory = _default_adapter_factory,
    cancellation: Cancellation | None = None,
    report_writer: ReportWriter = _write_report,
    clock: Callable[[], float] = time.monotonic,
) -> int:
    """Run one job and return the documented process status."""
    cancellation = cancellation or Cancellation()
    started = clock()
    started_wall = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    output_root: Path | None = None
    report: dict[str, Any] | None = None
    temporary_wav: Path | None = None
    adapter: Adapter | None = None
    state: Any = None
    adapter_finished = False
    published_wav: OwnedPublication | None = None
    published_wav_path: Path | None = None
    attempted_success_report: bytes | None = None
    exit_code = 1
    try:
        if backend not in {"exported", "unquantized"}:
            raise ProbeInputError("backend 必须是 exported 或 unquantized")
        if not math.isfinite(timeout_seconds) or not 0 < timeout_seconds <= 600:
            raise ProbeInputError("timeout-seconds 必须大于 0 且不超过 600")
        model_root, request_path, output_root = _prepare_paths(
            model_root_text, request_text, output_text
        )
        raw_request = _read_regular_file(request_path, REQUEST_LIMIT, "请求文件")
        try:
            request = parse_request(raw_request)
        except RequestError as error:
            raise ProbeInputError(str(error)) from error
        try:
            os.mkdir(output_root, 0o700)
        except OSError as error:
            output_root = None
            raise ProbeInputError(f"无法创建 output 任务目录：{error}") from error

        report = _base_report(request, backend, started_wall)
        deadline = started + timeout_seconds
        _check_stop(cancellation, deadline, clock)
        report["model"] = _validate_manifest(model_root)
        _check_stop(cancellation, deadline, clock)

        load_started = clock()
        print("阶段：验证完成，加载后端", flush=True)
        report["cleanup"] = {
            "status": "unknownDuringConstruction",
            "released": False,
        }
        adapter = adapter_factory(backend, model_root, request)
        report["cleanup"] = {"status": "pending", "released": False}
        report["timing"]["loadSeconds"] = clock() - load_started
        report["sdk"] = adapter.identity()
        _check_stop(cancellation, deadline, clock)

        note_frames = build_note_frames(request)
        temporary_wav = output_root / "output.partial.wav"
        descriptor = os.open(
            temporary_wav, os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o600
        )
        data_bytes = 0
        first_audio_seconds: float | None = None
        try:
            os.write(descriptor, b"\x00" * 44)
            for frame_index in range(request.duration_frames):
                _check_stop(cancellation, deadline, clock)
                frame_started = clock()
                note_frame = None if note_frames is None else note_frames[frame_index]
                waveform, state = adapter.generate_frame(note_frame, state)
                _check_stop(cancellation, deadline, clock)
                payload = _frame_bytes(waveform)
                offset = 0
                while offset < len(payload):
                    offset += os.write(descriptor, payload[offset:])
                data_bytes += len(payload)
                elapsed = clock() - frame_started
                report["timing"]["frameSeconds"].append(elapsed)
                if first_audio_seconds is None:
                    first_audio_seconds = clock() - started
                    report["timing"]["firstAudioSeconds"] = first_audio_seconds
                completed = frame_index + 1
                if completed % 25 == 0 or completed == request.duration_frames:
                    print(f"进度：{completed}/{request.duration_frames} 帧", flush=True)
            expected_data = request.duration_frames * SAMPLES_PER_FRAME * CHANNELS * SAMPLE_WIDTH
            if data_bytes != expected_data:
                raise RuntimeError("累计 WAV 数据长度不符")
            os.lseek(descriptor, 0, os.SEEK_SET)
            header = _wav_header(data_bytes)
            written = os.write(descriptor, header)
            if written != len(header):
                raise OSError("WAV header 短写")
            os.fsync(descriptor)
        finally:
            os.close(descriptor)

        state_holder = [state]
        state = None
        report["cleanup"] = _finish_adapter(adapter, state_holder)
        adapter_finished = True
        if not _cleanup_complete(report["cleanup"]):
            raise CleanupFailure("后端释放、同步或 cache 清理未完成")
        _check_stop(cancellation, deadline, clock)

        wav_size, wav_sha = _hash_file(temporary_wav)
        expected_file_size = 44 + data_bytes
        if wav_size != expected_file_size:
            raise RuntimeError("WAV 文件大小不符")
        destination = output_root / "output.wav"
        published_wav = _publish_no_replace(
            temporary_wav, destination, expected_sha256=wav_sha
        )
        published_wav_path = destination
        temporary_wav = None
        report["output"] = {
            "path": "output.wav",
            "sampleRate": SAMPLE_RATE,
            "channels": CHANNELS,
            "sampleFormat": "IEEE_FLOAT32_LE",
            "conditionFrames": request.duration_frames,
            "sampleFrames": request.duration_frames * SAMPLES_PER_FRAME,
            "samplesPerConditionFrame": SAMPLES_PER_FRAME,
            "sizeBytes": wav_size,
            "sha256": wav_sha,
            "gainApplied": False,
            "clipped": False,
            "resampled": False,
        }
        report["outcome"] = "completed"
        report["timing"]["totalSeconds"] = clock() - started
        attempted_success_report = _report_payload(report)
        report_writer(output_root / "report.json", report)
        print(f"完成：{destination}", flush=True)
        print(f"报告：{output_root / 'report.json'}", flush=True)
        exit_code = 0
    except ProbeCancelled as error:
        exit_code = 130
        if report is not None:
            report["outcome"] = "cancelled"
            report["error"] = {"type": type(error).__name__, "message": str(error)}
    except ProbeTimedOut as error:
        exit_code = 1
        if report is not None:
            report["outcome"] = "timedOut"
            report["error"] = {"type": type(error).__name__, "message": str(error)}
    except ProbeInputError as error:
        exit_code = 2
        if report is not None:
            report["outcome"] = "invalidInput"
            report["error"] = {"type": type(error).__name__, "message": str(error)}
        else:
            print(f"输入错误：{error}", file=sys.stderr, flush=True)
    except AdapterConstructionError as error:
        exit_code = 1
        if report is not None:
            report["outcome"] = "failed"
            report["error"] = {
                "type": "AdapterConstructionError",
                "causeType": error.original_type,
                "message": str(error),
            }
            report["cleanup"] = error.cleanup
        else:
            print(f"后端构造失败：{error}", file=sys.stderr, flush=True)
    except CleanupFailure as error:
        exit_code = 1
        if report is not None:
            _mark_cleanup_failure(report, cancellation, str(error))
        else:
            print(f"清理失败：{error}", file=sys.stderr, flush=True)
    except BaseException as error:
        exit_code = 1
        if report is not None:
            report["outcome"] = "failed"
            report["error"] = {"type": type(error).__name__, "message": str(error)}
        else:
            print(f"失败：{type(error).__name__}: {error}", file=sys.stderr, flush=True)
    finally:
        if temporary_wav is not None:
            try:
                os.unlink(temporary_wav)
            except FileNotFoundError:
                pass
            except OSError as error:
                print(f"未发布临时 WAV 清理失败：{error}", file=sys.stderr, flush=True)
        if adapter is not None and not adapter_finished:
            try:
                state_holder = [state]
                state = None
                cleanup = _finish_adapter(adapter, state_holder)
                if report is not None:
                    report["cleanup"] = cleanup
                    if not _cleanup_complete(cleanup):
                        _mark_cleanup_failure(
                            report,
                            cancellation,
                            "后端释放、同步或 cache 清理未完成",
                        )
                        exit_code = 1
            except BaseException as error:
                if report is not None:
                    report["cleanup"] = {
                        "released": False,
                        "error": f"{type(error).__name__}: {error}",
                    }
                    _mark_cleanup_failure(
                        report,
                        cancellation,
                        "后端清理抛出异常",
                    )
                exit_code = 1
        if report is not None and output_root is not None and exit_code != 0:
            report_path = output_root / "report.json"
            if attempted_success_report is not None:
                report["acceptedSuccessReportRollback"] = _remove_if_matching_payload(
                    report_path, attempted_success_report
                )
            if published_wav is not None and published_wav_path is not None:
                rollback = _remove_if_owned(published_wav_path, published_wav)
                report["publication"] = {
                    "accepted": False,
                    "ownedWavRollback": rollback,
                }
                report["output"] = None
            report["timing"]["totalSeconds"] = clock() - started
            try:
                report_writer(report_path, report)
            except BaseException as error:
                print(
                    f"报告写入失败：{type(error).__name__}: {error}",
                    file=sys.stderr,
                    flush=True,
                )
                exit_code = 1
        adapter = None
        state = None
        gc.collect()
    return exit_code


def _timeout(value: str) -> float:
    try:
        parsed = float(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("必须是数字") from error
    if not math.isfinite(parsed) or not 0 < parsed <= 600:
        raise argparse.ArgumentTypeError("必须大于 0 且不超过 600")
    return parsed


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="MRT2 短条件后端受控探针")
    parser.add_argument("--model-root", required=True)
    parser.add_argument("--request", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--backend", required=True, choices=("exported", "unquantized"))
    parser.add_argument("--timeout-seconds", type=_timeout, default=180.0)
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    cancellation = Cancellation()
    previous_handler = signal.getsignal(signal.SIGINT)

    def request_cancel(_signum: int, _frame: Any) -> None:
        cancellation.request()

    signal.signal(signal.SIGINT, request_cancel)
    try:
        return run_probe(
            model_root_text=arguments.model_root,
            request_text=arguments.request,
            output_text=arguments.output,
            backend=arguments.backend,
            timeout_seconds=arguments.timeout_seconds,
            cancellation=cancellation,
        )
    finally:
        signal.signal(signal.SIGINT, previous_handler)


if __name__ == "__main__":
    raise SystemExit(main())
