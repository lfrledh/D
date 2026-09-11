"""Receive narrowly-scoped file access prepared by the parent application."""

from __future__ import annotations

import base64
import binascii
from contextlib import contextmanager
import ctypes
from dataclasses import dataclass
import json
import os
from pathlib import Path, PurePosixPath
import stat
import sys
from typing import Any, Iterator, Sequence
import uuid


_MAX_MANIFEST_BYTES = 64 * 1024
_MAX_BOOKMARK_BYTES = 16 * 1024
_MAX_GRANTS = 4
_RESOLUTION_OPTIONS = (1 << 8) | (1 << 9) | (1 << 15)
_CORE_FOUNDATION = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"


class AudioAccessError(Exception):
    """The supplied bootstrap capability could not be validated or activated."""


class _DuplicateKeyError(ValueError):
    pass


@dataclass(frozen=True)
class _Grant:
    path: str
    bookmark: bytes


@dataclass(frozen=True)
class _ActiveGrant:
    url: object
    started: bool


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, child in pairs:
        if key in value:
            raise _DuplicateKeyError("duplicate JSON key")
        value[key] = child
    return value


def _reject_constant(_value: str) -> None:
    raise ValueError("non-finite JSON number")


def _exact_keys(value: dict[str, Any], expected: set[str], label: str) -> None:
    if set(value) != expected:
        raise AudioAccessError(f"{label} has invalid fields")


def _validated_path_text(value: Any, *, label: str) -> str:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise AudioAccessError(f"{label} must be a normalized absolute local path")
    pure = PurePosixPath(value)
    if pure.anchor != "/" or ".." in pure.parts or value == "/":
        raise AudioAccessError(f"{label} must be a normalized absolute local path")
    if os.path.normpath(value) != value:
        raise AudioAccessError(f"{label} must be a normalized absolute local path")
    return value


def _allowed_path_set(allowed_paths: Sequence[Path]) -> set[str]:
    if isinstance(allowed_paths, (str, bytes)):
        raise AudioAccessError("allowed_paths must be a sequence of paths")
    try:
        values = list(allowed_paths)
    except TypeError as exc:
        raise AudioAccessError("allowed_paths must be a sequence of paths") from exc
    if not 1 <= len(values) <= _MAX_GRANTS:
        raise AudioAccessError("allowed_paths must contain between one and four paths")
    result: set[str] = set()
    for item in values:
        if not isinstance(item, Path):
            raise AudioAccessError("allowed_paths entries must be Path values")
        text = _validated_path_text(str(item), label="allowed path")
        if text in result:
            raise AudioAccessError("allowed_paths contains a duplicate path")
        result.add(text)
    return result


def _file_identity(info: os.stat_result) -> tuple[int, int, int, int, int, int]:
    return (
        info.st_dev,
        info.st_ino,
        info.st_mode,
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
    )


def _open_manifest_without_symlinks(path: Path) -> tuple[int, os.stat_result]:
    directory_flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    leaf_flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    try:
        directory = os.open(path.anchor, directory_flags)
    except OSError as exc:
        raise AudioAccessError("manifest path could not be traversed safely") from exc
    try:
        for part in path.parts[1:-1]:
            try:
                child = os.open(part, directory_flags, dir_fd=directory)
            except OSError as exc:
                raise AudioAccessError(
                    "manifest path contains a symbolic link or unavailable component"
                ) from exc
            os.close(directory)
            directory = child
        try:
            leaf = os.stat(path.name, dir_fd=directory, follow_symlinks=False)
        except OSError as exc:
            raise AudioAccessError("manifest is unavailable") from exc
        if stat.S_ISLNK(leaf.st_mode):
            raise AudioAccessError("manifest path contains a symbolic link")
        if not stat.S_ISREG(leaf.st_mode):
            raise AudioAccessError("manifest must be a regular file")
        try:
            descriptor = os.open(path.name, leaf_flags, dir_fd=directory)
        except OSError as exc:
            raise AudioAccessError("manifest could not be opened safely") from exc
        return descriptor, leaf
    finally:
        os.close(directory)


def _read_manifest(path: Path) -> bytes:
    if not isinstance(path, Path):
        raise AudioAccessError("manifest_path must be a Path")
    _validated_path_text(str(path), label="manifest path")
    descriptor, leaf = _open_manifest_without_symlinks(path)
    if stat.S_IMODE(leaf.st_mode) != 0o600:
        os.close(descriptor)
        raise AudioAccessError("manifest permissions must be 0600")
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise AudioAccessError("manifest must be a regular file")
        if stat.S_IMODE(before.st_mode) != 0o600:
            raise AudioAccessError("manifest permissions must be 0600")
        if _file_identity(leaf) != _file_identity(before):
            raise AudioAccessError("manifest changed before it could be read")
        if before.st_size > _MAX_MANIFEST_BYTES:
            raise AudioAccessError("manifest exceeds 65536 bytes")
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(16 * 1024, _MAX_MANIFEST_BYTES + 1 - total))
            if not chunk:
                break
            total += len(chunk)
            if total > _MAX_MANIFEST_BYTES:
                raise AudioAccessError("manifest exceeds 65536 bytes")
            chunks.append(chunk)
        after = os.fstat(descriptor)
        if _file_identity(before) != _file_identity(after) or total != before.st_size:
            raise AudioAccessError("manifest changed while being read")
        return b"".join(chunks)
    except OSError as exc:
        raise AudioAccessError("manifest could not be read safely") from exc
    finally:
        os.close(descriptor)


def _decode_manifest(raw: bytes, *, run_id: str, allowed: set[str]) -> tuple[_Grant, ...]:
    try:
        value = json.loads(
            raw.decode("utf-8", errors="strict"),
            object_pairs_hook=_unique_object,
            parse_constant=_reject_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, _DuplicateKeyError, ValueError,
            OverflowError, RecursionError) as exc:
        raise AudioAccessError("manifest is not valid strict UTF-8 JSON") from exc
    if not isinstance(value, dict):
        raise AudioAccessError("manifest root must be an object")
    _exact_keys(value, {"schemaVersion", "runID", "grants"}, "manifest")
    version = value["schemaVersion"]
    if not isinstance(version, int) or isinstance(version, bool) or version != 1:
        raise AudioAccessError("manifest schemaVersion must be integer 1")
    manifest_run_id = value["runID"]
    if not isinstance(manifest_run_id, str) or not isinstance(run_id, str):
        raise AudioAccessError("runID must be a UUID string")
    try:
        if uuid.UUID(manifest_run_id) != uuid.UUID(run_id):
            raise AudioAccessError("manifest runID does not match the task")
    except (ValueError, AttributeError, TypeError) as exc:
        raise AudioAccessError("runID must be a UUID string") from exc
    grants_value = value["grants"]
    if not isinstance(grants_value, list) or not 1 <= len(grants_value) <= _MAX_GRANTS:
        raise AudioAccessError("manifest grants must contain between one and four entries")
    grants: list[_Grant] = []
    seen: set[str] = set()
    for entry in grants_value:
        if not isinstance(entry, dict):
            raise AudioAccessError("manifest grant must be an object")
        _exact_keys(entry, {"path", "bookmark"}, "manifest grant")
        path = _validated_path_text(entry["path"], label="manifest grant path")
        if path in seen:
            raise AudioAccessError("manifest contains a duplicate grant path")
        encoded = entry["bookmark"]
        if not isinstance(encoded, str) or not encoded:
            raise AudioAccessError("manifest bookmark must be nonempty strict base64")
        try:
            bookmark = base64.b64decode(encoded, validate=True)
        except (binascii.Error, ValueError) as exc:
            raise AudioAccessError("manifest bookmark must be nonempty strict base64") from exc
        if not bookmark or len(bookmark) > _MAX_BOOKMARK_BYTES:
            raise AudioAccessError("manifest bookmark has an invalid decoded size")
        seen.add(path)
        grants.append(_Grant(path, bookmark))
    if seen != allowed:
        raise AudioAccessError("manifest paths do not equal allowed_paths")
    return tuple(grants)


class _CoreFoundationAdapter:
    _CFIndex = ctypes.c_long
    _CFOptionFlags = ctypes.c_ulong
    _Boolean = ctypes.c_ubyte
    _CFRef = ctypes.c_void_p

    def __init__(self, library: Any) -> None:
        self._library = library
        uint8_pointer = ctypes.POINTER(ctypes.c_ubyte)
        library.CFDataCreate.argtypes = [self._CFRef, uint8_pointer, self._CFIndex]
        library.CFDataCreate.restype = self._CFRef
        library.CFURLCreateByResolvingBookmarkData.argtypes = [
            self._CFRef,
            self._CFRef,
            self._CFOptionFlags,
            self._CFRef,
            self._CFRef,
            ctypes.POINTER(self._Boolean),
            ctypes.POINTER(self._CFRef),
        ]
        library.CFURLCreateByResolvingBookmarkData.restype = self._CFRef
        library.CFURLGetFileSystemRepresentation.argtypes = [
            self._CFRef,
            self._Boolean,
            uint8_pointer,
            self._CFIndex,
        ]
        library.CFURLGetFileSystemRepresentation.restype = self._Boolean
        library.CFURLStartAccessingSecurityScopedResource.argtypes = [self._CFRef]
        library.CFURLStartAccessingSecurityScopedResource.restype = self._Boolean
        library.CFURLStopAccessingSecurityScopedResource.argtypes = [self._CFRef]
        library.CFURLStopAccessingSecurityScopedResource.restype = None
        library.CFRelease.argtypes = [self._CFRef]
        library.CFRelease.restype = None

    def _release(self, reference: object) -> None:
        if reference:
            self._library.CFRelease(reference)

    def resolve(self, bookmark: bytes) -> tuple[object, str]:
        payload = (ctypes.c_ubyte * len(bookmark)).from_buffer_copy(bookmark)
        data = self._library.CFDataCreate(None, payload, len(bookmark))
        if not data:
            raise AudioAccessError("bookmark data could not be represented")
        error = self._CFRef()
        stale = self._Boolean(0)
        url: object = None
        try:
            url = self._library.CFURLCreateByResolvingBookmarkData(
                None,
                data,
                _RESOLUTION_OPTIONS,
                None,
                None,
                ctypes.byref(stale),
                ctypes.byref(error),
            )
        finally:
            self._release(data)
            self._release(error.value)
        if not url:
            raise AudioAccessError("bookmark could not be resolved")
        if stale.value:
            self._release(url)
            raise AudioAccessError("bookmark is stale")
        try:
            for size in (1024, 4096, 16 * 1024, 64 * 1024, 256 * 1024):
                buffer = (ctypes.c_ubyte * size)()
                success = self._library.CFURLGetFileSystemRepresentation(url, 0, buffer, size)
                if success:
                    raw_path = bytes(buffer).split(b"\0", 1)[0]
                    if not raw_path:
                        break
                    try:
                        return url, raw_path.decode("utf-8", errors="strict")
                    except UnicodeDecodeError as exc:
                        raise AudioAccessError("bookmark has no valid local path") from exc
            raise AudioAccessError("bookmark has no valid local path")
        except BaseException:
            self._release(url)
            raise

    def start(self, url: object) -> bool:
        return bool(self._library.CFURLStartAccessingSecurityScopedResource(url))

    def stop(self, url: object) -> None:
        self._library.CFURLStopAccessingSecurityScopedResource(url)

    def release_url(self, url: object) -> None:
        self._release(url)


def _make_cf_adapter() -> _CoreFoundationAdapter:
    if sys.platform != "darwin":
        raise AudioAccessError("file access bookmarks are unsupported on this platform")
    try:
        library = ctypes.CDLL(_CORE_FOUNDATION)
        return _CoreFoundationAdapter(library)
    except (AttributeError, OSError) as exc:
        raise AudioAccessError("CoreFoundation file access support is unavailable") from exc


def _check_directory_readable(path: str) -> None:
    flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise AudioAccessError("granted directory is not readable") from exc
    try:
        if not stat.S_ISDIR(os.fstat(descriptor).st_mode):
            raise AudioAccessError("granted path is not a readable directory")
    finally:
        os.close(descriptor)


def _cleanup(adapter: Any, active: list[_ActiveGrant]) -> bool:
    failed = False
    for grant in reversed(active):
        if grant.started:
            try:
                adapter.stop(grant.url)
            except BaseException:
                failed = True
        try:
            adapter.release_url(grant.url)
        except BaseException:
            failed = True
    active.clear()
    return failed


@contextmanager
def acquire_file_access(
    manifest_path: Path,
    *,
    run_id: str,
    allowed_paths: Sequence[Path],
) -> Iterator[None]:
    """Validate and hold the exact file capabilities for the duration of ``with``."""

    allowed = _allowed_path_set(allowed_paths)
    grants = _decode_manifest(_read_manifest(manifest_path), run_id=run_id, allowed=allowed)
    adapter = _make_cf_adapter()
    active: list[_ActiveGrant] = []
    try:
        for grant in grants:
            url: object = None
            started = False
            try:
                url, resolved_path = adapter.resolve(grant.bookmark)
                resolved_path = _validated_path_text(resolved_path, label="resolved bookmark path")
                if resolved_path != grant.path:
                    raise AudioAccessError("resolved bookmark path does not match its grant")
                started = bool(adapter.start(url))
                _check_directory_readable(grant.path)
            except AudioAccessError:
                if url is not None:
                    _cleanup(adapter, [_ActiveGrant(url, started)])
                raise
            except BaseException as exc:
                if url is not None:
                    _cleanup(adapter, [_ActiveGrant(url, started)])
                raise AudioAccessError("file access could not be activated") from exc
            active.append(_ActiveGrant(url, started))
    except BaseException:
        _cleanup(adapter, active)
        raise

    try:
        yield
    except BaseException:
        _cleanup(adapter, active)
        raise
    else:
        if _cleanup(adapter, active):
            raise AudioAccessError("file access cleanup did not complete")
