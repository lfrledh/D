#!/usr/bin/env python3
"""Copy a verified development resource set into a build Resources/Engines path."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile
from types import ModuleType
from typing import Any


sys.dont_write_bytecode = True


class EmbedError(Exception):
    """A controlled embed failure with resumable completion information."""

    def __init__(self, message: str, completed: list[str] | None = None) -> None:
        super().__init__(message)
        self.completed = list(completed or [])


def _load_core() -> ModuleType:
    path = Path(__file__).with_name("prepare-development-resources.py")
    spec = importlib.util.spec_from_file_location("_d_development_resources_core", path)
    if spec is None or spec.loader is None:
        raise EmbedError(f"cannot load development resource validator: {path}")
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
    except (OSError, SyntaxError, ImportError) as error:
        raise EmbedError(f"cannot load development resource validator: {path}: {error}") from error
    return module


def _absolute_destination(value: str, core: ModuleType) -> tuple[Path, bool]:
    supplied = Path(value)
    if not supplied.is_absolute():
        raise EmbedError("--destination must be an absolute path")
    path = Path(os.path.abspath(value))
    if path.name in {"", ".", ".."}:
        raise EmbedError("--destination must name an Engines directory")
    try:
        core._reject_symlink_ancestors(path.parent, "destination parent")
    except core.ResourceError as error:
        raise EmbedError(str(error)) from error
    if not path.parent.is_dir():
        raise EmbedError(f"destination parent is not a directory: {path.parent}")
    exists = core._lexists(path)
    if exists:
        try:
            info = path.lstat()
        except OSError as error:
            raise EmbedError(f"destination is unreadable: {path}: {error}") from error
        if not stat.S_ISDIR(info.st_mode):
            raise EmbedError(f"destination must be a non-symlink directory: {path}")
    return path, exists


def _destination_entries(destination: Path) -> set[str]:
    try:
        return {entry.name for entry in destination.iterdir()}
    except OSError as error:
        raise EmbedError(f"cannot enumerate destination: {destination}: {error}") from error


def _verify_existing(
    destination: Path,
    recorded: dict[str, Any],
    core: ModuleType,
) -> list[str]:
    entries = _destination_entries(destination)
    unknown = sorted(entries - set(recorded))
    if unknown:
        raise EmbedError(f"destination contains unknown entries and was not modified: {unknown}")
    completed: list[str] = []
    for name in core.engine_names(recorded):
        if name not in entries:
            continue
        try:
            actual = core.inspect_engine(destination / name, name)
        except core.ResourceError as error:
            raise EmbedError(f"existing destination engine conflicts with prepared content: {name}: {error}") from error
        if actual != recorded[name]:
            raise EmbedError(f"existing destination engine conflicts with prepared inventory: {name}")
        completed.append(name)
    return completed


def embed(prepared: Path, destination: Path, destination_exists: bool, core: ModuleType) -> tuple[str, list[str]]:
    try:
        manifest = core.validate_prepared(prepared)
    except core.ResourceError as error:
        raise EmbedError(f"prepared resource validation failed: {error}") from error
    if core._overlaps(prepared, destination):
        raise EmbedError(f"destination overlaps prepared input: {destination} and {prepared}")
    recorded = manifest["engines"]

    if destination_exists:
        completed = _verify_existing(destination, recorded, core)
    else:
        completed = []
    if len(completed) == len(recorded):
        return "reused", completed

    if not destination_exists:
        try:
            destination.mkdir(mode=0o700)
        except OSError as error:
            raise EmbedError(f"cannot create destination: {destination}: {error}") from error

    source_root = prepared / core.ENGINE_DIRECTORY
    try:
        for name in core.engine_names(recorded):
            if name in completed:
                continue
            staging = Path(tempfile.mkdtemp(prefix=f".d-embed-{name}-", dir=destination))
            published = False
            try:
                shutil.copytree(
                    source_root / name,
                    staging,
                    symlinks=True,
                    copy_function=shutil.copy2,
                    dirs_exist_ok=True,
                )
                copied = core.inspect_engine(staging, name)
                if copied != recorded[name]:
                    raise EmbedError(f"copied engine differs before publication: {name}", completed)
                core._publish_exclusive(staging, destination / name)
                published = True
                completed.append(name)
            finally:
                if not published and staging.exists():
                    shutil.rmtree(staging, ignore_errors=True)
    except EmbedError:
        raise
    except (core.ResourceError, OSError, shutil.Error, UnicodeError) as error:
        raise EmbedError(f"embed failed after engines {completed}: {error}", completed) from error

    try:
        final = _verify_existing(destination, recorded, core)
    except EmbedError as error:
        error.completed = completed
        raise
    if final != list(core.engine_names(recorded)):
        raise EmbedError(f"embed ended incomplete: completed={final}", final)
    return "embedded", final


def _neutralize_failed_stream(stream: Any) -> None:
    """Let normal interpreter cleanup proceed after a descriptor write failure."""
    try:
        descriptor = stream.fileno()
    except (AttributeError, OSError, ValueError):
        return
    try:
        with open(os.devnull, "w", encoding="utf-8") as sink:
            os.dup2(sink.fileno(), descriptor)
    except OSError:
        return


def _safe_report(stream: Any, value: dict[str, Any]) -> bool:
    try:
        payload = json.dumps(value, ensure_ascii=False, sort_keys=True) + "\n"
        if stream.write(payload) != len(payload):
            raise OSError("short stream write")
        stream.flush()
        return True
    except (AttributeError, OSError, UnicodeError, ValueError):
        _neutralize_failed_stream(stream)
        return False


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepared", required=True, help="absolute prepared resource-set path")
    parser.add_argument("--destination", required=True, help="absolute build Resources/Engines path")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    try:
        args = parse_arguments(sys.argv[1:] if argv is None else argv)
        core = _load_core()
        try:
            prepared = core._absolute_directory(args.prepared, "prepared resource set")
        except core.ResourceError as error:
            raise EmbedError(str(error)) from error
        destination, exists = _absolute_destination(args.destination, core)
        status, completed = embed(prepared, destination, exists, core)
        reported = _safe_report(sys.stdout, {
            "schemaVersion": 1,
            "status": status,
            "destination": str(destination),
            "completedEngines": completed,
            "incomplete": False,
            "runtimeVerification": "not-run",
        })
        if not reported:
            _safe_report(sys.stderr, {
                "schemaVersion": 1,
                "status": "failed",
                "error": "could not write the success report to stdout",
                "completedEngines": completed,
                "incomplete": False,
                "runtimeVerification": "not-run",
            })
        return 0 if reported else 2
    except EmbedError as error:
        _safe_report(sys.stderr, {
            "schemaVersion": 1,
            "status": "failed",
            "error": str(error),
            "completedEngines": error.completed,
            "incomplete": True,
            "runtimeVerification": "not-run",
        })
        return 2
    except (OSError, shutil.Error, UnicodeError) as error:
        _safe_report(sys.stderr, {
            "schemaVersion": 1,
            "status": "failed",
            "error": str(error),
            "completedEngines": [],
            "incomplete": True,
            "runtimeVerification": "not-run",
        })
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
