#!/usr/bin/env python3
"""Portable, offline D test-kit runner (Python 3.12 standard library only)."""

from __future__ import annotations

import argparse
import contextlib
import dataclasses
import datetime as dt
import fcntl
import hashlib
import html
import json
import math
import os
import platform
import re
import signal
import struct
import subprocess
import sys
import threading
import time
import urllib.parse
import uuid
import wave
import zipfile
import zlib
from pathlib import Path
from typing import Any, BinaryIO, Iterable, Mapping, Sequence


SCHEMA_VERSION = 1
MIB = 1024 * 1024
GIB = 1024 * MIB
MAX_JSON_BYTES = 4 * MIB
MAX_PROMPT_BYTES = 1 * MIB
MAX_STREAM_BYTES = 16 * MIB
MAX_PROFILES = 32
MAX_CASES = 256
MAX_MANIFEST_FILES = 10000
PROCESS_POLL_SECONDS = 0.5
MAX_RSS_SAMPLES = 7200
INTERRUPT_GRACE_SECONDS = 30.0
TERM_GRACE_SECONDS = 5.0
ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")


class KitError(Exception):
    """An expected configuration, validation, or execution error."""

    def __init__(self, message: str, *, kind: str = "invalid") -> None:
        super().__init__(message)
        self.kind = kind


def _utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def _is_int(value: Any) -> bool:
    return type(value) is int


def _is_number(value: Any) -> bool:
    return type(value) in (int, float) and math.isfinite(float(value))


def _require(condition: bool, message: str, *, kind: str = "invalid") -> None:
    if not condition:
        raise KitError(message, kind=kind)


def _strict_keys(value: Mapping[str, Any], allowed: set[str], required: set[str], label: str) -> None:
    unknown = set(value) - allowed
    missing = required - set(value)
    _require(not unknown, f"{label} has unknown field(s): {', '.join(sorted(unknown))}")
    _require(not missing, f"{label} is missing field(s): {', '.join(sorted(missing))}")


def _read_json(path: Path, label: str, maximum: int = MAX_JSON_BYTES) -> tuple[bytes, Any]:
    _regular_file(path, label)
    size = path.stat().st_size
    _require(size <= maximum, f"{label} exceeds {maximum} bytes")
    raw = path.read_bytes()
    try:
        return raw, json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise KitError(f"{label} is not valid UTF-8 JSON: {error}") from error


def _atomic_json(path: Path, value: Any) -> None:
    _atomic_bytes(path, (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8"))


def _atomic_bytes(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    _ordinary_directory(path.parent, f"output parent for {path.name}")
    temporary = path.parent / f".{path.name}.{uuid.uuid4().hex}.tmp"
    try:
        with temporary.open("xb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            temporary.unlink()


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(MIB), b""):
            digest.update(block)
    return digest.hexdigest()


def _git_blob_sha1(path: Path, size: int) -> str:
    digest = hashlib.sha1(usedforsecurity=False)
    digest.update(f"blob {size}\0".encode("ascii"))
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(MIB), b""):
            digest.update(block)
    return digest.hexdigest()


def _regular_file(path: Path, label: str, executable: bool | None = None) -> None:
    _require(path.exists(), f"{label} is missing: {path}", kind="blocked")
    _require(not path.is_symlink() and path.is_file(), f"{label} must be a regular non-symlink file: {path}")
    if executable is True:
        _require(os.access(path, os.X_OK), f"{label} is not executable: {path}", kind="blocked")


def _ordinary_directory(path: Path, label: str) -> None:
    _require(path.exists(), f"{label} is missing: {path}", kind="blocked")
    _require(not path.is_symlink() and path.is_dir(), f"{label} must be a non-symlink directory: {path}")


def _relative_path(root: Path, raw: Any, label: str, *, kind: str, must_exist: bool = True) -> Path:
    _require(isinstance(raw, str) and raw and "\0" not in raw, f"{label} must be a nonempty relative path")
    candidate = Path(raw)
    _require(not candidate.is_absolute(), f"{label} must be relative")
    _require(all(part not in ("", ".", "..") for part in candidate.parts), f"{label} contains a forbidden path component")
    _ordinary_directory(root, f"{label} root")
    root_real = root.resolve(strict=True)
    joined = root / candidate
    cursor = root
    for part in candidate.parts:
        cursor = cursor / part
        if cursor.is_symlink():
            raise KitError(f"{label} crosses a symbolic link: {raw}")
    if must_exist:
        _require(joined.exists(), f"{label} is missing: {raw}", kind="blocked")
        resolved = joined.resolve(strict=True)
    else:
        resolved = joined.resolve(strict=False)
    try:
        resolved.relative_to(root_real)
    except ValueError as error:
        raise KitError(f"{label} escapes the kit root: {raw}") from error
    if kind == "file" and must_exist:
        _regular_file(joined, label)
    elif kind == "directory" and must_exist:
        _ordinary_directory(joined, label)
    return joined


def _identifier(value: Any, label: str) -> str:
    _require(isinstance(value, str) and ID_PATTERN.fullmatch(value) is not None, f"{label} is invalid")
    return value


def _version_tuple(value: str) -> tuple[int, ...]:
    match = re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,3}", value)
    _require(match is not None, f"invalid macOS version: {value}")
    return tuple(int(part) for part in value.split("."))


@dataclasses.dataclass(frozen=True)
class KitConfiguration:
    root: Path
    raw: dict[str, Any]
    cli: Path
    engine: Path
    catalog_path: Path
    profiles_path: Path


@dataclasses.dataclass(frozen=True)
class CatalogModel:
    model_id: str
    directory: Path
    manifest: Path
    format: str
    revision: str
    audio_profile: str | None


@dataclasses.dataclass(frozen=True)
class ProfileSet:
    raw: dict[str, Any]
    profiles: dict[str, dict[str, Any]]
    cases: dict[str, dict[str, Any]]
    digest: str


@dataclasses.dataclass
class ProcessResult:
    return_code: int
    elapsed_seconds: float
    stdout_bytes: int
    stderr_bytes: int
    stdout_limited: bool
    stderr_limited: bool
    timed_out: bool
    cancellation_requested: bool
    forced_stop: bool
    rss_samples_kib: list[dict[str, Any]]
    rss_samples_truncated: bool
    child_rss: str = "unknown"


class _BoundedDrain(threading.Thread):
    def __init__(self, source: BinaryIO, destination: BinaryIO, limit: int) -> None:
        super().__init__(daemon=True)
        self.source = source
        self.destination = destination
        self.limit = limit
        self.total = 0
        self.exceeded = False
        self.error: str | None = None

    def run(self) -> None:
        try:
            while True:
                block = self.source.read(65536)
                if not block:
                    break
                self.total += len(block)
                remaining = self.limit - self.destination.tell()
                if remaining > 0:
                    self.destination.write(block[:remaining])
                    self.destination.flush()
                if self.total > self.limit:
                    self.exceeded = True
        except Exception as error:  # recorded rather than abandoning the child pipe
            self.error = f"{type(error).__name__}: {error}"


class KitRunner:
    """Validated runner. test_cli is deliberately constructor-only test injection."""

    def __init__(self, kit_root: Path, *, test_cli: Path | None = None,
                 physical_memory_bytes: int | None = None, os_version: str | None = None) -> None:
        self.root = kit_root.expanduser().resolve(strict=True)
        _ordinary_directory(self.root, "kit root")
        self._test_cli = test_cli
        self._physical_memory = physical_memory_bytes
        self._os_version = os_version
        self.config = self._load_kit()
        self.catalog = self._load_catalog()
        self.profile_set = self._load_profiles()

    def _load_kit(self) -> KitConfiguration:
        raw_bytes, raw = _read_json(self.root / "kit.json", "kit.json")
        del raw_bytes
        _require(isinstance(raw, dict), "kit.json must be an object")
        allowed = {"schemaVersion", "kitID", "sourceSHA", "buildConfiguration", "cli", "engine",
                   "catalog", "profiles", "minimumMacOS", "audioLicenseAcknowledged"}
        _strict_keys(raw, allowed, allowed, "kit.json")
        _require(_is_int(raw["schemaVersion"]) and raw["schemaVersion"] == 1, "unsupported kit.json schemaVersion")
        _identifier(raw["kitID"], "kitID")
        _require(isinstance(raw["sourceSHA"], str) and HEX40.fullmatch(raw["sourceSHA"]), "sourceSHA must be a full lowercase SHA")
        _require(raw["buildConfiguration"] in ("Debug", "Release"), "invalid buildConfiguration")
        _require(type(raw["audioLicenseAcknowledged"]) is bool, "audioLicenseAcknowledged must be boolean")
        _require(isinstance(raw["minimumMacOS"], str), "minimumMacOS must be a string")
        _version_tuple(raw["minimumMacOS"])
        cli = _relative_path(self.root, raw["cli"], "kit CLI", kind="file")
        engine = _relative_path(self.root, raw["engine"], "audio engine", kind="directory")
        catalog = _relative_path(self.root, raw["catalog"], "catalog", kind="file")
        profiles = _relative_path(self.root, raw["profiles"], "profiles", kind="file")
        return KitConfiguration(self.root, raw, cli, engine, catalog, profiles)

    def _load_catalog(self) -> dict[str, CatalogModel]:
        _, raw = _read_json(self.config.catalog_path, "catalog.json")
        _require(isinstance(raw, dict), "catalog.json must be an object")
        _strict_keys(raw, {"schemaVersion", "models"}, {"schemaVersion", "models"}, "catalog.json")
        _require(_is_int(raw["schemaVersion"]) and raw["schemaVersion"] == 1, "unsupported catalog schemaVersion")
        _require(isinstance(raw["models"], dict) and 0 < len(raw["models"]) <= MAX_CASES, "catalog models must be a bounded object")
        models: dict[str, CatalogModel] = {}
        for raw_id, entry in raw["models"].items():
            model_id = _identifier(raw_id, "model ID")
            _require(isinstance(entry, dict), f"catalog model {model_id} must be an object")
            required = {"directory", "manifest", "format", "revision"}
            allowed = required | {"audioProfile"}
            _strict_keys(entry, allowed, required, f"catalog model {model_id}")
            format_name = entry["format"]
            _require(format_name in ("text", "image", "audio"), f"catalog model {model_id} has invalid format")
            revision = entry["revision"]
            _require(isinstance(revision, str) and HEX40.fullmatch(revision), f"catalog model {model_id} has invalid revision")
            audio_profile = entry.get("audioProfile")
            if format_name == "audio":
                _require(audio_profile in ("sm-music", "sm-sfx", "medium"), f"audio model {model_id} needs audioProfile")
            else:
                _require(audio_profile is None, f"non-audio model {model_id} cannot have audioProfile")
            models[model_id] = CatalogModel(
                model_id,
                _relative_path(self.root, entry["directory"], f"model {model_id} directory", kind="directory", must_exist=False),
                _relative_path(self.root, entry["manifest"], f"model {model_id} manifest", kind="file"),
                format_name, revision, audio_profile)
        return models

    def _load_profiles(self) -> ProfileSet:
        raw_bytes, raw = _read_json(self.config.profiles_path, "profiles.json")
        _require(isinstance(raw, dict), "profiles.json must be an object")
        _strict_keys(raw, {"schemaVersion", "profiles", "cases"}, {"schemaVersion", "profiles", "cases"}, "profiles.json")
        _require(_is_int(raw["schemaVersion"]) and raw["schemaVersion"] == 1, "unsupported profiles schemaVersion")
        _require(isinstance(raw["profiles"], list) and 0 < len(raw["profiles"]) <= MAX_PROFILES, "profiles must be a bounded array")
        _require(isinstance(raw["cases"], list) and 0 < len(raw["cases"]) <= MAX_CASES, "cases must be a bounded array")
        cases: dict[str, dict[str, Any]] = {}
        case_allowed = {"id", "title", "model", "capability", "promptFile", "parameters",
                        "timeoutSeconds", "expected", "repeatCount", "sourceCase", "cancelAfterSeconds"}
        case_required = {"id", "title", "model", "capability", "promptFile", "parameters",
                         "timeoutSeconds", "expected", "repeatCount"}
        for entry in raw["cases"]:
            _require(isinstance(entry, dict), "case entry must be an object")
            _strict_keys(entry, case_allowed, case_required, "case")
            case_id = _identifier(entry["id"], "case ID")
            _require(case_id not in cases, f"duplicate case ID: {case_id}")
            _require(isinstance(entry["title"], str) and entry["title"], f"case {case_id} title is invalid")
            _require(entry["model"] in self.catalog, f"case {case_id} names an unknown model")
            capability = entry["capability"]
            _require(capability in ("text", "image", "audio"), f"case {case_id} has invalid capability")
            _require(self.catalog[entry["model"]].format == capability, f"case {case_id} capability differs from model format")
            prompt = _relative_path(self.root, entry["promptFile"], f"case {case_id} prompt", kind="file")
            _require(prompt.stat().st_size <= MAX_PROMPT_BYTES, f"case {case_id} prompt exceeds 1 MiB")
            try:
                prompt.read_text(encoding="utf-8")
            except UnicodeDecodeError as error:
                raise KitError(f"case {case_id} prompt is not UTF-8") from error
            self._validate_parameters(case_id, capability, entry["parameters"], self.catalog[entry["model"]])
            _require(_is_number(entry["timeoutSeconds"]) and 0 < float(entry["timeoutSeconds"]) <= 86400,
                     f"case {case_id} timeoutSeconds is invalid")
            _require(entry["expected"] in ("completed", "cancelled"), f"case {case_id} expected is invalid")
            _require(_is_int(entry["repeatCount"]) and 1 <= entry["repeatCount"] <= 3,
                     f"case {case_id} repeatCount must be 1...3")
            if "cancelAfterSeconds" in entry:
                _require(_is_number(entry["cancelAfterSeconds"]) and 0 < float(entry["cancelAfterSeconds"]) < float(entry["timeoutSeconds"]),
                         f"case {case_id} cancelAfterSeconds is invalid")
                _require(entry["expected"] == "cancelled", f"case {case_id} cancellation must expect cancelled")
            if "sourceCase" in entry:
                _identifier(entry["sourceCase"], f"case {case_id} sourceCase")
                _require(capability == "audio", f"case {case_id} sourceCase is audio-only")
            operation = entry["parameters"].get("audioOperation") if capability == "audio" else None
            if operation in ("variation", "inpaint"):
                _require("sourceCase" in entry, f"case {case_id} editing requires sourceCase")
            if operation == "generate":
                _require("sourceCase" not in entry, f"case {case_id} generation cannot have sourceCase")
            cases[case_id] = entry
        profiles: dict[str, dict[str, Any]] = {}
        for entry in raw["profiles"]:
            _require(isinstance(entry, dict), "profile entry must be an object")
            _strict_keys(entry, {"id", "title", "caseIDs"}, {"id", "title", "caseIDs"}, "profile")
            profile_id = _identifier(entry["id"], "profile ID")
            _require(profile_id not in profiles, f"duplicate profile ID: {profile_id}")
            _require(isinstance(entry["title"], str) and entry["title"], f"profile {profile_id} title is invalid")
            ids = entry["caseIDs"]
            _require(isinstance(ids, list) and 0 < len(ids) <= MAX_CASES, f"profile {profile_id} caseIDs is invalid")
            _require(all(isinstance(item, str) and item in cases for item in ids), f"profile {profile_id} has unknown case IDs")
            _require(len(ids) == len(set(ids)), f"profile {profile_id} has duplicate case IDs")
            seen: set[str] = set()
            for case_id in ids:
                source = cases[case_id].get("sourceCase")
                if source is not None:
                    _require(source in seen, f"case {case_id} sourceCase must be earlier in the same profile")
                    _require(cases[source]["capability"] == "audio" and cases[source]["expected"] == "completed",
                             f"case {case_id} sourceCase must be a completed audio case")
                seen.add(case_id)
            profiles[profile_id] = entry
        return ProfileSet(raw, profiles, cases, hashlib.sha256(raw_bytes).hexdigest())

    def _validate_parameters(self, case_id: str, capability: str, parameters: Any, model: CatalogModel) -> None:
        _require(isinstance(parameters, dict), f"case {case_id} parameters must be an object")
        allowed = {
            "text": {"maxTokens", "temperature", "topP", "maxPromptTokens", "maxOutputTokens", "cacheLimitMiB"},
            "image": {"width", "height", "steps", "guidance", "seed", "imageProfile"},
            "audio": {"durationSeconds", "steps", "guidance", "seed", "audioOperation", "audioStrength",
                      "audioEditStartFrame", "audioEditEndFrame"},
        }[capability]
        _strict_keys(parameters, allowed, allowed - ({"audioEditStartFrame", "audioEditEndFrame"} if capability == "audio" else set()),
                     f"case {case_id} parameters")
        if capability == "text":
            bounds = (("maxTokens", 1, 8192), ("maxPromptTokens", 1, 32768),
                      ("maxOutputTokens", 1, 8192), ("cacheLimitMiB", 0, 1024))
            for name, lower, upper in bounds:
                _require(_is_int(parameters[name]) and lower <= parameters[name] <= upper,
                         f"case {case_id} {name} is out of bounds")
            _require(parameters["maxTokens"] <= parameters["maxOutputTokens"], f"case {case_id} maxTokens exceeds maxOutputTokens")
            _require(_is_number(parameters["temperature"]) and float(parameters["temperature"]) >= 0,
                     f"case {case_id} temperature is invalid")
            _require(_is_number(parameters["topP"]) and 0 < float(parameters["topP"]) <= 1,
                     f"case {case_id} topP is invalid")
            return
        for name in ("steps",):
            _require(_is_int(parameters[name]) and parameters[name] > 0, f"case {case_id} {name} is invalid")
        _require(parameters["steps"] == (4 if capability == "image" else 8), f"case {case_id} changes the fixed step contract")
        _require(_is_number(parameters["guidance"]) and float(parameters["guidance"]) == 1,
                 f"case {case_id} changes the fixed guidance contract")
        seed = parameters["seed"]
        _require((isinstance(seed, str) and seed.isascii() and seed.isdigit() and 0 <= int(seed) < 2**64)
                 or (_is_int(seed) and 0 <= seed < 2**64), f"case {case_id} seed is invalid")
        if capability == "image":
            for name in ("width", "height"):
                value = parameters[name]
                _require(_is_int(value) and 256 <= value <= 2048 and value % 32 == 0,
                         f"case {case_id} {name} violates the image shape contract")
            _require(parameters["imageProfile"] in ("verified512", "scalableKlein4B"), f"case {case_id} imageProfile is invalid")
            if parameters["imageProfile"] == "verified512":
                _require(parameters["width"] == 512 and parameters["height"] == 512,
                         f"case {case_id} verified512 must be 512x512")
            return
        duration = parameters["durationSeconds"]
        maximum = 380 if model.audio_profile == "medium" else 120
        _require(_is_number(duration) and 0 < float(duration) <= maximum, f"case {case_id} durationSeconds is invalid")
        operation = parameters["audioOperation"]
        _require(operation in ("generate", "variation", "inpaint"), f"case {case_id} audioOperation is invalid")
        strength = parameters["audioStrength"]
        _require(_is_number(strength) and 0 < float(strength) <= 1, f"case {case_id} audioStrength is invalid")
        has_start, has_end = "audioEditStartFrame" in parameters, "audioEditEndFrame" in parameters
        if operation == "generate":
            _require(float(strength) == 1 and not has_start and not has_end, f"case {case_id} has invalid generate parameters")
        elif operation == "variation":
            _require(not has_start and not has_end, f"case {case_id} variation cannot have edit bounds")
        else:
            _require(has_start and has_end and _is_int(parameters["audioEditStartFrame"])
                     and _is_int(parameters["audioEditEndFrame"])
                     and 0 <= parameters["audioEditStartFrame"] < parameters["audioEditEndFrame"],
                     f"case {case_id} has invalid inpaint bounds")

    def _resolve_engine(self) -> dict[str, Path]:
        raw_bytes, manifest = _read_json(self.config.engine / "engine.json", "audio engine manifest")
        del raw_bytes
        _require(isinstance(manifest, dict), "audio engine manifest must be an object")
        required = {"schemaVersion", "kind", "pythonABI", "pythonExecutable", "providerScript",
                    "vendorDirectory", "modelManifestsDirectory", "files"}
        _strict_keys(manifest, required, required, "audio engine manifest")
        _require(_is_int(manifest["schemaVersion"]) and manifest["schemaVersion"] == 1, "unsupported audio engine schema")
        _require(manifest["kind"] == "d-audio-engine" and manifest["pythonABI"] == "3.12", "incompatible audio engine")
        _require(isinstance(manifest["files"], list) and len(manifest["files"]) <= MAX_MANIFEST_FILES,
                 "audio engine files must be bounded")
        declared: set[str] = set()
        for entry in manifest["files"]:
            _require(isinstance(entry, dict), "audio engine file entry must be an object")
            _strict_keys(entry, {"path", "sizeBytes", "sha256", "executable"},
                         {"path", "sizeBytes", "sha256", "executable"}, "audio engine file")
            path_raw = entry["path"]
            _require(path_raw not in declared, f"duplicate audio engine file: {path_raw}")
            declared.add(path_raw)
            path = _relative_path(self.config.engine, path_raw, "audio engine file", kind="file")
            _require(_is_int(entry["sizeBytes"]) and entry["sizeBytes"] >= 0 and path.stat().st_size == entry["sizeBytes"],
                     f"audio engine file size mismatch: {path_raw}")
            _require(type(entry["executable"]) is bool, f"audio engine executable must be boolean: {path_raw}")
            _require(isinstance(entry["sha256"], str) and HEX64.fullmatch(entry["sha256"])
                     and _sha256_file(path) == entry["sha256"], f"audio engine digest mismatch: {path_raw}")
            _require(bool(path.stat().st_mode & 0o111) == entry["executable"], f"audio engine executable mode mismatch: {path_raw}")
        python = _relative_path(self.config.engine, manifest["pythonExecutable"], "audio Python", kind="file")
        provider = _relative_path(self.config.engine, manifest["providerScript"], "audio provider", kind="file")
        vendor = _relative_path(self.config.engine, manifest["vendorDirectory"], "audio vendor", kind="directory")
        manifests = _relative_path(self.config.engine, manifest["modelManifestsDirectory"], "audio model manifests", kind="directory")
        _require(manifest["pythonExecutable"] in declared and manifest["providerScript"] in declared,
                 "audio engine entry points are not declared files")
        _require(os.access(python, os.X_OK), "audio Python is not executable", kind="blocked")
        return {"python": python, "provider": provider, "vendor": vendor, "manifests": manifests}

    def _verify_model(self, model: CatalogModel) -> dict[str, Any]:
        _ordinary_directory(model.directory, f"model {model.model_id} directory")
        _, manifest = _read_json(model.manifest, f"manifest for {model.model_id}")
        _require(isinstance(manifest, dict) and _is_int(manifest.get("schemaVersion"))
                 and manifest["schemaVersion"] == 1, f"manifest for {model.model_id} has unsupported schema")
        _require(manifest.get("revision") == model.revision, f"manifest revision mismatch for {model.model_id}")
        files = manifest.get("files")
        _require(isinstance(files, list) and 0 < len(files) <= MAX_MANIFEST_FILES,
                 f"manifest files are invalid for {model.model_id}")
        seen: set[str] = set()
        total = 0
        checked = []
        for entry in files:
            _require(isinstance(entry, dict), f"manifest file for {model.model_id} must be an object")
            if model.format == "text":
                _strict_keys(entry, {"name", "size", "algorithm", "checksum"},
                             {"name", "size", "algorithm", "checksum"}, f"text manifest file {model.model_id}")
                relative, size = entry["name"], entry["size"]
                algorithm, expected = entry["algorithm"], entry["checksum"]
                _require(algorithm in ("sha256", "git-blob-sha1"), f"unsupported digest algorithm for {model.model_id}")
                _require(isinstance(expected, str) and (HEX64.fullmatch(expected) if algorithm == "sha256" else HEX40.fullmatch(expected)),
                         f"invalid digest for {model.model_id}")
            else:
                _strict_keys(entry, {"path", "size", "sha256"}, {"path", "size", "sha256"},
                             f"{model.format} manifest file {model.model_id}")
                relative, size = entry["path"], entry["size"]
                algorithm, expected = "sha256", entry["sha256"]
                _require(isinstance(expected, str) and HEX64.fullmatch(expected), f"invalid digest for {model.model_id}")
            _require(isinstance(relative, str) and relative not in seen, f"duplicate manifest path for {model.model_id}")
            seen.add(relative)
            _require(_is_int(size) and size >= 0, f"invalid manifest size for {model.model_id}")
            path = _relative_path(model.directory, relative, f"model file {model.model_id}/{relative}", kind="file")
            actual_size = path.stat().st_size
            _require(actual_size == size, f"model file size mismatch: {model.model_id}/{relative}", kind="blocked")
            actual = _sha256_file(path) if algorithm == "sha256" else _git_blob_sha1(path, actual_size)
            _require(actual == expected, f"model file digest mismatch: {model.model_id}/{relative}", kind="blocked")
            total += actual_size
            checked.append({"path": relative, "size": actual_size, "algorithm": algorithm, "digest": actual})
        return {"model": model.model_id, "revision": model.revision, "files": checked,
                "fileCount": len(checked), "totalBytes": total}

    def _current_os_version(self) -> str:
        return self._os_version if self._os_version is not None else (platform.mac_ver()[0] or "0")

    def _memory_bytes(self) -> int:
        if self._physical_memory is not None:
            return self._physical_memory
        try:
            return int(os.sysconf("SC_PHYS_PAGES")) * int(os.sysconf("SC_PAGE_SIZE"))
        except (ValueError, OSError):
            return 0

    def _budget(self) -> dict[str, int]:
        physical = self._memory_bytes()
        reserve = max(4 * GIB, math.ceil(physical * 0.25)) if physical > 0 else 0
        available = max(0, physical - reserve)
        return {"physicalMemoryBytes": physical, "reservedBytes": reserve, "admissionBudgetBytes": available,
                "admissionBudgetMiB": available // MIB}

    def _system_observation(self) -> dict[str, Any]:
        chip = _sysctl("machdep.cpu.brand_string")
        memory = _sysctl("hw.memsize")
        physical = int(memory) if memory and memory.isascii() and memory.isdigit() else self._memory_bytes()
        return {"operatingSystem": platform.platform(), "macOSVersion": self._current_os_version(),
                "architecture": platform.machine() or "unknown", "chip": chip or "unknown",
                "physicalMemoryBytes": physical, "swap": _sysctl("vm.swapusage") or "unknown",
                "xcodeAvailable": Path("/Applications/Xcode.app/Contents/Developer").is_dir()}

    def preflight(self, case_ids: Sequence[str] | None = None) -> dict[str, Any]:
        cli = self._test_cli or self.config.cli
        _regular_file(cli, "test CLI" if self._test_cli else "kit CLI", executable=True)
        minimum = _version_tuple(self.config.raw["minimumMacOS"])
        current = _version_tuple(self._current_os_version())
        _require(current >= minimum, f"macOS {self.config.raw['minimumMacOS']} or later is required", kind="blocked")
        chosen = list(case_ids) if case_ids is not None else list(self.profile_set.cases)
        model_ids = list(dict.fromkeys(self.profile_set.cases[item]["model"] for item in chosen))
        if any(self.catalog[item].format == "audio" for item in model_ids):
            _require(self.config.raw["audioLicenseAcknowledged"] is True,
                     "audio use has not been acknowledged by the kit builder", kind="blocked")
            self._resolve_engine()
        models = [self._verify_model(self.catalog[item]) for item in model_ids]
        return {"schemaVersion": 1, "status": "ready", "kitID": self.config.raw["kitID"],
                "sourceSHA": self.config.raw["sourceSHA"], "currentMacOS": self._current_os_version(),
                "minimumMacOS": self.config.raw["minimumMacOS"], "budget": self._budget(), "models": models,
                "system": self._system_observation(), "profileDigest": self.profile_set.digest, "checkedAt": _utc_now()}

    def _select_cases(self, profile_id: str, requested: Sequence[str] | None) -> list[str]:
        _require(profile_id in self.profile_set.profiles, f"unknown profile: {profile_id}")
        profile_cases = self.profile_set.profiles[profile_id]["caseIDs"]
        if requested is None:
            return list(profile_cases)
        _require(requested and len(requested) == len(set(requested)), "--cases must name unique case IDs")
        _require(all(item in profile_cases for item in requested), "--cases must be members of the selected profile")
        return [item for item in profile_cases if item in requested]

    def _engine_arguments(self, model: CatalogModel) -> list[str]:
        if model.format != "audio":
            return []
        engine = self._resolve_engine()
        return ["--audio-python", str(engine["python"]), "--audio-script", str(engine["provider"]),
                "--audio-vendor", str(engine["vendor"]), "--audio-manifest", str(model.manifest),
                "--audio-profile", str(model.audio_profile), "--audio-license-acknowledged", "true"]

    def _command(self, case: dict[str, Any], report: Path, artifacts: Path, budget_mib: int,
                 *, inspect: bool, source: dict[str, Any] | None = None) -> list[str]:
        model = self.catalog[case["model"]]
        prompt = _relative_path(self.root, case["promptFile"], f"case {case['id']} prompt", kind="file")
        cli = self._test_cli or self.config.cli
        command = [str(cli), "--capability", case["capability"], "--model", str(model.directory),
                   "--prompt-file", str(prompt), "--revision", model.revision,
                   "--memory-budget-mib", str(max(1, budget_mib)), "--report", str(report),
                   "--repeat", str(case["repeatCount"])]
        parameters = case["parameters"]
        names = {
            "maxTokens": "--max-tokens", "temperature": "--temperature", "topP": "--top-p",
            "maxPromptTokens": "--max-prompt-tokens", "maxOutputTokens": "--max-output-tokens",
            "cacheLimitMiB": "--cache-limit-mib", "width": "--width", "height": "--height",
            "steps": "--steps", "guidance": "--guidance", "seed": "--seed",
            "imageProfile": "--image-profile", "durationSeconds": "--duration-seconds",
            "audioOperation": "--audio-operation", "audioStrength": "--audio-strength",
            "audioEditStartFrame": "--audio-edit-start-frame", "audioEditEndFrame": "--audio-edit-end-frame",
        }
        for name, value in parameters.items():
            command.extend([names[name], str(value)])
        if case["capability"] in ("image", "audio"):
            command.extend(["--artifacts", str(artifacts)])
        if case["capability"] == "image":
            command.extend(["--image-memory-limit-mib", str(max(1, budget_mib))])
        command.extend(self._engine_arguments(model))
        if case["capability"] == "audio":
            command.extend(["--timeout-seconds", str(case["timeoutSeconds"])])
        if source is not None:
            command.extend(["--audio-source", source["path"], "--audio-source-sha256", source["sha256"],
                            "--audio-source-frames", str(source["frames"])])
        if inspect:
            command.append("--inspect")
        return command

    @staticmethod
    def _terminate_group(process: subprocess.Popen[bytes], first_signal: int = signal.SIGINT) -> bool:
        if process.poll() is not None:
            return False
        forced = False
        for sent, grace in ((first_signal, INTERRUPT_GRACE_SECONDS), (signal.SIGTERM, TERM_GRACE_SECONDS)):
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, sent)
            try:
                process.wait(timeout=grace)
                return forced
            except subprocess.TimeoutExpired:
                forced = True
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        return True

    def _run_process(self, command: Sequence[str], directory: Path, timeout: float,
                     cancel_after: float | None = None, *, _test_ready: Path | None = None) -> ProcessResult:
        _require(not directory.exists() and not directory.is_symlink(), f"process output already exists: {directory}", kind="failed")
        directory.mkdir(parents=True, exist_ok=False)
        private = directory / "private"
        private.mkdir()
        child_tmp = private / "tmp"
        child_cache = private / "cache"
        child_hf = private / "huggingface"
        child_pyc = private / "pycache"
        for path in (child_tmp, child_cache, child_hf, child_pyc):
            path.mkdir()
        environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                       "TMPDIR": str(child_tmp), "XDG_CACHE_HOME": str(child_cache),
                       "HF_HOME": str(child_hf), "HUGGINGFACE_HUB_CACHE": str(child_hf / "hub"),
                       "PYTHONPYCACHEPREFIX": str(child_pyc), "PYTHONDONTWRITEBYTECODE": "1",
                       "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "LC_ALL": "C.UTF-8", "LANG": "C.UTF-8"}
        if "HOME" in os.environ:
            environment["HOME"] = os.environ["HOME"]
        stdout_path, stderr_path = private / "stdout.log", private / "stderr.log"
        started = time.monotonic()
        timed_out = cancelled = forced = False
        samples: list[dict[str, Any]] = []
        with stdout_path.open("xb") as stdout_file, stderr_path.open("xb") as stderr_file:
            try:
                process = subprocess.Popen(list(command), cwd=directory, env=environment, stdout=subprocess.PIPE,
                                           stderr=subprocess.PIPE, start_new_session=True)
            except OSError as error:
                raise KitError(f"cannot start bundled CLI: {error}", kind="failed") from error
            assert process.stdout is not None and process.stderr is not None
            stdout_drain = _BoundedDrain(process.stdout, stdout_file, MAX_STREAM_BYTES)
            stderr_drain = _BoundedDrain(process.stderr, stderr_file, MAX_STREAM_BYTES)
            stdout_drain.start(); stderr_drain.start()
            try:
                while process.poll() is None:
                    elapsed = time.monotonic() - started
                    rss = _rss_kib(process.pid)
                    if len(samples) < MAX_RSS_SAMPLES:
                        samples.append({"elapsedSeconds": round(elapsed, 3), "pid": process.pid, "rssKiB": rss})
                    if stdout_drain.error or stderr_drain.error or stdout_drain.exceeded or stderr_drain.exceeded:
                        forced = self._terminate_group(process) or forced
                        break
                    ready = _test_ready is None or _test_ready.exists()
                    if ready and cancel_after is not None and elapsed >= cancel_after:
                        cancelled = True
                        forced = self._terminate_group(process) or forced
                        break
                    if ready and elapsed >= timeout:
                        timed_out = True
                        forced = self._terminate_group(process) or forced
                        break
                    time.sleep(PROCESS_POLL_SECONDS)
            except KeyboardInterrupt:
                cancelled = True
                forced = self._terminate_group(process) or forced
                raise
            finally:
                if process.poll() is None:
                    forced = self._terminate_group(process) or forced
                stdout_drain.join(timeout=5); stderr_drain.join(timeout=5)
                process.stdout.close(); process.stderr.close()
                stdout_drain.join(timeout=1); stderr_drain.join(timeout=1)
                _require(not stdout_drain.is_alive() and not stderr_drain.is_alive(), "CLI stream drain did not finish", kind="failed")
            _require(not stdout_drain.error and not stderr_drain.error,
                     f"CLI stream drain failed: {stdout_drain.error or stderr_drain.error}", kind="failed")
        result = ProcessResult(process.returncode, time.monotonic() - started, stdout_drain.total, stderr_drain.total,
                               stdout_drain.exceeded, stderr_drain.exceeded, timed_out, cancelled, forced, samples,
                               len(samples) >= MAX_RSS_SAMPLES)
        _atomic_json(directory / "process.json", dataclasses.asdict(result))
        return result

    def _inspect_case(self, case: dict[str, Any], directory: Path, budget_mib: int,
                      source: dict[str, Any] | None = None) -> dict[str, Any]:
        report = directory / "inspection.json"
        artifacts = directory / "inspection-artifacts"
        if case["capability"] in ("image", "audio"):
            artifacts.mkdir(parents=True)
        command = self._command(case, report, artifacts, budget_mib, inspect=True, source=source)
        process = self._run_process(command, directory / "inspection-process", min(float(case["timeoutSeconds"]), 300))
        _require(not process.timed_out and not process.stdout_limited and not process.stderr_limited,
                 f"inspection failed operationally for {case['id']}", kind="failed")
        _, payload = _read_json(report, f"inspection report for {case['id']}")
        _require(isinstance(payload, dict) and _is_int(payload.get("schemaVersion")) and payload.get("schemaVersion") == 1
                 and payload.get("tool") == "d-infer" and payload.get("runs") == [],
                 f"invalid inspection report for {case['id']}")
        _require(_is_int(payload.get("exitCode")) and payload.get("exitCode") == process.return_code,
                 f"inspection exit/report mismatch for {case['id']}")
        _require(not process.forced_stop and not payload.get("failure") and not payload.get("artifactCleanupError"),
                 f"inspection reported an execution/cleanup error for {case['id']}")
        _require(process.return_code == 0, f"inspection failed for {case['id']}", kind="blocked")
        _require(process.stdout_bytes == 0 and not any(path.is_file() for path in artifacts.rglob("*")),
                 f"inspection produced generation output for {case['id']}")
        options = payload.get("options"); model = self.catalog[case["model"]]
        _require(isinstance(options, dict) and isinstance(payload.get("backend"), dict),
                 f"inspection options/backend missing for {case['id']}")
        _validate_actual_options(options, case, model, self.root, budget_mib, source)
        inspection = payload.get("inspection")
        _require(isinstance(inspection, dict) and type(inspection.get("withinBudget")) is bool,
                 f"inspection fields missing for {case['id']}")
        estimate = inspection.get("estimate")
        _require(isinstance(estimate, dict) and _is_int(estimate.get("peakBytes")) and estimate["peakBytes"] >= 0
                 and isinstance(estimate.get("confidence"), str), f"inspection estimate invalid for {case['id']}")
        _require(inspection["withinBudget"] == (estimate["peakBytes"] <= budget_mib * MIB),
                 f"inspection budget conclusion is dishonest for {case['id']}")
        return {"report": "inspection.json", "process": dataclasses.asdict(process),
                "publicProcess": _public_process(process),
                "estimate": estimate, "withinBudget": inspection["withinBudget"]}

    def run(self, profile_id: str, requested: Sequence[str] | None = None, resume: str | None = None) -> dict[str, Any]:
        selected = self._select_cases(profile_id, requested)
        preflight = self.preflight(selected)
        results_root = self.root / "Results"
        _require(not results_root.is_symlink(), "Results must not be a symbolic link", kind="failed")
        results_root.mkdir(exist_ok=True)
        _ordinary_directory(results_root, "Results")
        lock_path = results_root / ".d-testkit.lock"
        _require(not lock_path.is_symlink() and (not lock_path.exists() or lock_path.is_file()),
                 "run lock is not a regular file", kind="failed")
        with lock_path.open("a+b") as lock:
            try:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise KitError("another test-kit run is active", kind="blocked") from error
            return self._run_locked(profile_id, selected, preflight, results_root, resume)

    def _run_locked(self, profile_id: str, selected: list[str], preflight: dict[str, Any],
                    results_root: Path, resume: str | None) -> dict[str, Any]:
        if resume is None:
            run_id = str(uuid.uuid4())
            run_root = results_root / run_id
            try:
                run_root.mkdir()
            except FileExistsError as error:
                raise KitError("new run directory already exists; refusing to overwrite", kind="failed") from error
            run_record = {"schemaVersion": 1, "runID": run_id, "kitID": self.config.raw["kitID"],
                          "sourceSHA": self.config.raw["sourceSHA"], "profileID": profile_id,
                          "profileDigest": self.profile_set.digest, "selectedCaseIDs": selected,
                          "createdAt": _utc_now(), "attempts": []}
        else:
            _identifier(resume, "resume run ID")
            run_root = _relative_path(results_root, resume, "resume run", kind="directory")
            _, run_record = _read_json(run_root / "run.json", "resume run.json")
            _require(isinstance(run_record, dict) and _is_int(run_record.get("schemaVersion"))
                     and run_record.get("schemaVersion") == 1 and run_record.get("runID") == resume, "invalid resume run")
            _require(run_record.get("sourceSHA") == self.config.raw["sourceSHA"], "resume sourceSHA differs")
            _require(run_record.get("profileDigest") == self.profile_set.digest, "resume profile digest differs")
            _require(run_record.get("profileID") == profile_id, "resume profile differs")
            _require(run_record.get("selectedCaseIDs") == selected, "resume selection differs")
            run_id = resume
        successful_sources: dict[str, dict[str, Any]] = {}
        completed: set[str] = set()
        if resume is not None:
            for old_attempt in run_record.get("attempts", []):
                old_id = old_attempt.get("attemptID")
                _identifier(old_id, "previous attempt ID")
                old_root = _relative_path(run_root / "attempts", old_id, "previous attempt", kind="directory")
                _, old_record = _read_json(old_root / "attempt.json", "previous attempt.json")
                for reference in old_record.get("cases", []):
                    old_case_path = _relative_path(old_root, reference.get("path"), "previous case result", kind="file")
                    _, old_case = _read_json(old_case_path, "previous case result")
                    if old_case.get("status") == "passed":
                        old_case_id = old_case.get("caseID")
                        if old_case_id in selected:
                            completed.add(old_case_id)
            needed = {case_id for case_id in selected if case_id not in completed}
            for case_id in tuple(needed):
                source_id = self.profile_set.cases[case_id].get("sourceCase")
                if source_id is not None:
                    needed.add(source_id)  # same-attempt lineage; never reuse an old attempt's source
            selected_for_attempt = [case_id for case_id in selected if case_id in needed]
            _require(selected_for_attempt, "resume run has no unfinished cases")
        else:
            selected_for_attempt = selected
        attempt_id = str(uuid.uuid4())
        attempt_root = run_root / "attempts" / attempt_id
        _require(not (run_root / "attempts").is_symlink() and not attempt_root.exists() and not attempt_root.is_symlink(),
                 "attempt output path is unsafe or already exists", kind="failed")
        attempt_root.mkdir(parents=True)
        attempt = {"schemaVersion": 1, "attemptID": attempt_id, "startedAt": _utc_now(),
                   "state": "running", "selectedCaseIDs": selected_for_attempt, "preflight": preflight, "cases": [],
                   "lineage": [{"dependent": item, "source": self.profile_set.cases[item]["sourceCase"],
                                "policy": "same-attempt-rerun"} for item in selected_for_attempt
                               if "sourceCase" in self.profile_set.cases[item]]}
        _atomic_json(attempt_root / "attempt.json", attempt)
        run_record["attempts"].append({"attemptID": attempt_id, "startedAt": attempt["startedAt"]})
        _atomic_json(run_root / "run.json", run_record)
        budget_mib = preflight["budget"]["admissionBudgetMiB"]
        interrupted = False
        for index, case_id in enumerate(selected_for_attempt):
            case = self.profile_set.cases[case_id]
            print(f"开始 [{index + 1}/{len(selected_for_attempt)}] {case_id}", file=sys.stderr, flush=True)
            case_root = attempt_root / "cases" / f"{index + 1:03d}-{case_id}"
            _require(not case_root.exists() and not case_root.is_symlink(), "case output already exists", kind="failed")
            case_root.mkdir(parents=True)
            source_case = case.get("sourceCase")
            inspection = None
            if source_case is not None and source_case not in successful_sources:
                result = self._case_record(case, "blocked_dependency", "source case did not complete successfully")
            else:
                try:
                    source = successful_sources.get(source_case) if source_case else None
                    if source is not None:
                        source = self._materialize_source(run_root, source, case)
                    inspection = self._inspect_case(case, case_root, budget_mib, source)
                    if not inspection["withinBudget"]:
                        result = self._case_record(case, "blocked_budget", "inspection exceeds admission budget")
                        result["inspection"] = inspection
                    else:
                        result = self._execute_case(case, case_root, budget_mib, inspection, source)
                except KeyboardInterrupt:
                    result = self._case_record(case, "interrupted", "user interrupted the batch")
                    interrupted = True
                except KitError as error:
                    status = "blocked" if error.kind == "blocked" else "failed"
                    result = self._case_record(case, status, str(error))
                    if inspection is not None: result["inspection"] = inspection
                    process_path = case_root / "execution-process" / "process.json"
                    if process_path.is_file() and not process_path.is_symlink():
                        _, process_value = _read_json(process_path, "case process")
                        result["publicProcess"] = _public_process_dict(process_value)
                    inspection_process_path = case_root / "inspection-process" / "process.json"
                    if inspection_process_path.is_file() and not inspection_process_path.is_symlink():
                        _, inspection_process = _read_json(inspection_process_path, "inspection process")
                        result["inspectionProcess"] = _public_process_dict(inspection_process)
            _atomic_json(case_root / "case.json", result)
            attempt["cases"].append({"caseID": case_id, "path": str((case_root / "case.json").relative_to(attempt_root)),
                                     "status": result["status"]})
            _atomic_json(attempt_root / "attempt.json", attempt)
            if result["status"] == "passed" and case["capability"] == "audio":
                source_info = result.get("sourceForDependents")
                if source_info:
                    successful_sources[case_id] = source_info
            print(f"结束 {case_id}: {result['status']}", file=sys.stderr, flush=True)
            if interrupted:
                break
        attempt["state"] = "interrupted" if interrupted else "finished"
        attempt["finishedAt"] = _utc_now()
        _atomic_json(attempt_root / "attempt.json", attempt)
        summary = self.summarize(run_id)
        return {"runID": run_id, "attemptID": attempt_id, "summary": summary}

    def _materialize_source(self, run_root: Path, source: dict[str, Any], case: dict[str, Any]) -> dict[str, Any]:
        _require(isinstance(source, dict) and set(source) == {"path", "sha256", "frames"}, "source evidence is invalid")
        path = _relative_path(run_root, source["path"], "same-attempt audio source", kind="file")
        _require(isinstance(source["sha256"], str) and HEX64.fullmatch(source["sha256"])
                 and _sha256_file(path) == source["sha256"], "source digest changed")
        _require(_is_int(source["frames"]) and source["frames"] > 0, "source frame count is invalid")
        parameters = case["parameters"]
        if parameters["audioOperation"] == "inpaint":
            _require(parameters["audioEditEndFrame"] <= source["frames"], "audio edit bounds exceed source frames")
        return {"path": str(path), "sha256": source["sha256"], "frames": source["frames"]}

    @staticmethod
    def _case_record(case: dict[str, Any], status: str, message: str | None = None) -> dict[str, Any]:
        result = {"schemaVersion": 1, "caseID": case["id"], "title": case["title"],
                  "capability": case["capability"], "expected": case["expected"], "status": status,
                  "qualityAssessment": "pending", "finishedAt": _utc_now()}
        if message:
            result["message"] = message
        return result

    def _execute_case(self, case: dict[str, Any], case_root: Path, budget_mib: int,
                      inspection: dict[str, Any], source: dict[str, Any] | None) -> dict[str, Any]:
        report = case_root / "cli-report.json"
        artifacts = case_root / "artifacts"
        if case["capability"] in ("image", "audio"):
            artifacts.mkdir()
        command = self._command(case, report, artifacts, budget_mib, inspect=False, source=source)
        system_before = self._system_observation()
        process = self._run_process(command, case_root / "execution-process", float(case["timeoutSeconds"]),
                                    float(case["cancelAfterSeconds"]) if "cancelAfterSeconds" in case else None)
        result = self._case_record(case, "failed")
        result["inspection"] = inspection
        result["process"] = dataclasses.asdict(process)
        result["publicProcess"] = _public_process(process)
        result["systemBefore"] = system_before
        result["systemAfter"] = self._system_observation()
        if process.timed_out or process.forced_stop:
            result["message"] = "case timed out"
            return result
        if process.stdout_limited or process.stderr_limited:
            result["message"] = "case output exceeded the configured limit"
            return result
        _require(report.exists() and report.is_file() and not report.is_symlink(),
                 f"CLI report is missing or unsafe for {case['id']}", kind="failed")
        _, payload = _read_json(report, f"CLI report for {case['id']}", MAX_STREAM_BYTES)
        _require(isinstance(payload, dict) and _is_int(payload.get("schemaVersion")) and payload.get("schemaVersion") == 1
                 and payload.get("tool") == "d-infer", f"invalid CLI report for {case['id']}")
        _require(_is_int(payload.get("exitCode")) and payload.get("exitCode") == process.return_code,
                 f"CLI exit/report mismatch for {case['id']}")
        _require(not payload.get("failure") and not payload.get("artifactCleanupError"),
                 f"CLI reported a failure/cleanup error for {case['id']}")
        options = payload.get("options")
        model = self.catalog[case["model"]]
        _require(isinstance(options, dict) and options.get("capability") == case["capability"]
                 and options.get("model") == str(model.directory) and options.get("revision") == model.revision
                 and _is_int(options.get("repeatCount")) and options.get("repeatCount") == case["repeatCount"],
                 f"CLI options differ from the request for {case['id']}")
        _validate_actual_options(options, case, model, self.root, budget_mib, source)
        runs = payload.get("runs")
        _require(isinstance(runs, list) and len(runs) == case["repeatCount"], f"CLI run count mismatch for {case['id']}")
        expected_outcome = case["expected"]
        _require(all(isinstance(run, dict) and run.get("outcome") == expected_outcome for run in runs),
                 f"CLI outcome differs from expected for {case['id']}")
        expected_exit = 0 if expected_outcome == "completed" else 130
        _require(process.return_code == expected_exit, f"CLI exit code differs from expected for {case['id']}")
        mlx_peaks = []
        run_evidence = []
        seen_run_ids: set[str] = set()
        for iteration, run in enumerate(runs, 1):
            _require(isinstance(run, dict) and isinstance(run.get("request"), dict),
                     f"CLI run/request type is invalid for {case['id']}")
            _require(not any(run.get(key) for key in ("failure", "errorMessage", "outputError", "artifactCleanupError")),
                     f"CLI run reported an error for {case['id']}")
            # The audio event stream throws Swift.CancellationError when the runtime
            # drains a requested cancellation. Preserve that diagnostic; it is not
            # a failed inference. Unknown stream errors still reject the case.
            stream_error = run.get("streamError")
            if stream_error:
                _require(case["capability"] == "audio" and expected_outcome == "cancelled"
                         and process.cancellation_requested and not process.forced_stop
                         and payload.get("terminationSignal") == 2
                         and run.get("result") is None and run.get("artifacts") == []
                         and isinstance(stream_error, str)
                         and stream_error.endswith("(Swift.CancellationError error 1.)")
                         and all(_is_number(run.get(key)) and run[key] >= 0 for key in
                                 ("cancellationRequestedSeconds", "cancellationLatencySeconds")),
                         f"CLI run reported an unexpected stream error for {case['id']}")
            _require(_is_int(run.get("iteration")) and run["iteration"] == iteration
                     and isinstance(run.get("runID"), str) and run["runID"] not in seen_run_ids,
                     f"CLI run identity/iteration is invalid for {case['id']}")
            seen_run_ids.add(run["runID"])
            _require(_is_number(run.get("elapsedSeconds")) and float(run["elapsedSeconds"]) >= 0,
                     f"CLI elapsedSeconds is invalid for {case['id']}")
            _require(run.get("request", {}).get("id") == run.get("runID"), f"CLI request/run identity mismatch for {case['id']}")
            _require(run.get("request", {}).get("model", {}).get("revision") == model.revision,
                     f"CLI request revision mismatch for {case['id']}")
            _validate_request_payload(run["request"], case, model, self.root, source)
            if expected_outcome == "completed":
                _require(isinstance(run.get("result"), dict)
                         and run["result"].get("artifacts", []) == run.get("artifacts", []),
                         f"CLI result artifacts differ for {case['id']}")
            lifecycle = run.get("lifecycle")
            _require(isinstance(lifecycle, list), f"CLI lifecycle is invalid for {case['id']}")
            if case["capability"] == "audio":
                _require(lifecycle == [], f"audio must not fabricate Swift MLX lifecycle for {case['id']}")
            phases = [event.get("phase") for event in lifecycle if isinstance(event, dict)]
            if lifecycle:
                _require("drained" in phases and phases[-1] == "released",
                         f"CLI lifecycle lacks drain/release for {case['id']}")
            previous_uptime = -1.0
            for event in lifecycle:
                _require(isinstance(event, dict) and event.get("runID") == run["runID"]
                         and _is_number(event.get("uptimeSeconds")) and float(event["uptimeSeconds"]) >= previous_uptime,
                         f"CLI lifecycle identity/time is invalid for {case['id']}")
                previous_uptime = float(event["uptimeSeconds"])
                memory = event.get("memory")
                _require(isinstance(memory, dict) and all(_is_int(memory.get(key)) and memory[key] >= 0
                         for key in ("activeBytes", "cacheBytes", "peakBytes"))
                         and memory["peakBytes"] >= memory["activeBytes"], f"CLI lifecycle memory is invalid for {case['id']}")
                peak = memory["peakBytes"]
                if _is_int(peak) and peak >= 0:
                    mlx_peaks.append(peak)
            run_evidence.append({key: run.get(key) for key in ("iteration", "runID", "startedAt", "elapsedSeconds",
                                 "firstChunkSeconds", "firstProgressSeconds", "firstArtifactSeconds",
                                 "cancellationRequestedSeconds", "cancellationLatencySeconds", "streamError", "progress", "lifecycle")})
            run_evidence[-1]["metadata"] = run.get("result", {}).get("metadata", {}) if isinstance(run.get("result"), dict) else {}
            run_evidence[-1]["computeObserved"] = bool(lifecycle)
        execution_stdout = case_root / "execution-process" / "private" / "stdout.log"
        public: list[dict[str, Any]] = []
        if case["capability"] == "text":
            raw = execution_stdout.read_bytes()
            try:
                stdout_text = raw.decode("utf-8")
            except UnicodeDecodeError as error:
                raise KitError(f"text stdout is not UTF-8 for {case['id']}") from error
            texts = []
            for run in runs:
                _require(isinstance(run.get("text"), str), f"text result missing for {case['id']}")
                texts.append(run["text"])
                result_object = run.get("result")
                if expected_outcome == "completed":
                    _require(isinstance(result_object, dict), f"text result object missing for {case['id']}")
                    metadata = result_object.get("metadata")
                    _require(isinstance(metadata, dict), f"text metadata missing for {case['id']}")
                    for key in ("promptTokens", "generationTokens"):
                        _require(isinstance(metadata.get(key), str) and metadata[key].isascii() and metadata[key].isdigit(),
                                 f"text {key} is invalid for {case['id']}")
                    for key in ("promptSeconds", "generationSeconds"):
                        _require(isinstance(metadata.get(key), str) and _finite_decimal(metadata[key]),
                                 f"text {key} is invalid for {case['id']}")
                    _require(isinstance(metadata.get("randomSeed"), str) and metadata["randomSeed"].isascii()
                             and metadata["randomSeed"].isdigit(), f"text randomSeed is invalid for {case['id']}")
            # Formal CLI writes one LF after each terminal text run (including cancellation).
            # Keep exact framing: strip()/rstrip() would hide corrupted or extra output.
            _require(stdout_text == "".join(text + "\n" for text in texts),
                     f"text stdout/report mismatch for {case['id']}")
            text_path = case_root / "text.txt"
            _require(not text_path.exists() and not text_path.is_symlink(), "text output already exists", kind="failed")
            with text_path.open("xb") as handle: handle.write(raw)
            public.append({"type": "text/plain", "path": "text.txt", "absoluteValidatedPath": str(text_path), "bytes": len(raw),
                           "sha256": hashlib.sha256(raw).hexdigest()})
        else:
            lines = [line for line in execution_stdout.read_text(encoding="utf-8").splitlines() if line]
            expected_artifacts = [artifact for run in runs for artifact in run.get("artifacts", [])]
            if expected_outcome == "completed":
                _require(all(len(run.get("artifacts", [])) == 1 for run in runs),
                         f"completed media run must publish exactly one artifact for {case['id']}")
            _require(len(lines) == len(expected_artifacts), f"artifact stdout count mismatch for {case['id']}")
            artifact_runs = [(run["runID"], artifact) for run in runs for artifact in run.get("artifacts", [])]
            audio_provider_records = []
            for line, (artifact_run_id, reference) in zip(lines, artifact_runs):
                try:
                    emitted = json.loads(line)
                except json.JSONDecodeError as error:
                    raise KitError(f"artifact stdout is invalid JSON for {case['id']}") from error
                _require(emitted.get("type") == "artifact" and emitted.get("runID") == artifact_run_id
                         and emitted.get("artifact") == reference, f"artifact stdout/report mismatch for {case['id']}")
                if case["capability"] == "image":
                    public.append(_validate_png_reference(reference, artifacts, case["parameters"]["width"],
                                                          case["parameters"]["height"]))
                else:
                    validated = _validate_wav_reference(reference, artifacts, case["parameters"]["durationSeconds"],
                                                        source, case["parameters"])
                    public.append(validated)
                    if expected_outcome == "completed":
                        matching_run = next(item for item in runs if item["runID"] == artifact_run_id)
                        audio_provider_records.append(_validate_audio_provider(
                            matching_run["result"].get("metadata"), validated, case, model, artifact_run_id,
                            artifacts, options["prompt"], source))
        result["status"] = "passed"
        result.pop("message", None)
        result["artifacts"] = public
        result["actualOptions"] = options
        result["backend"] = payload.get("backend")
        _require(isinstance(result["backend"], dict) and isinstance(result["backend"].get("id"), str),
                 f"backend descriptor missing for {case['id']}")
        result["runs"] = run_evidence
        if case["capability"] == "audio":
            if expected_outcome == "cancelled":
                _require(process.cancellation_requested and not process.forced_stop
                         and all(run.get("result") is None and run.get("lifecycle") == [] for run in runs),
                         f"audio cancellation evidence is invalid for {case['id']}")
                result["memoryMeasurement"] = {"source": "unavailable", "reason": "cancelled-before-provider-result"}
            else:
                result["audioProviderRecords"] = audio_provider_records
                result["memoryMeasurement"] = {"source": "provider", "records": len(audio_provider_records)}
        result["measurements"] = {"mlxPeakBytes": max(mlx_peaks) if mlx_peaks else "unknown",
                                  "processRSS": {"samples": process.rss_samples_kib,
                                                 "children": process.child_rss,
                                                 "aggregation": "not-summed"}}
        if case["capability"] == "audio" and public:
            first = public[0]
            run_root = case_root.parents[3]
            result["sourceForDependents"] = {"path": str(Path(first["absoluteValidatedPath"]).relative_to(run_root)), "sha256": first["sha256"],
                                             "frames": first["frames"]}
        run_root = case_root.parents[3]
        for artifact in result["artifacts"]:
            absolute = artifact.get("absoluteValidatedPath")
            if absolute:
                artifact["path"] = str(Path(absolute).relative_to(run_root))
        return result

    def summarize(self, run_id: str) -> dict[str, Any]:
        _identifier(run_id, "run ID")
        run_root = _relative_path(self.root / "Results", run_id, "run", kind="directory")
        _, run = _read_json(run_root / "run.json", "run.json")
        _require(isinstance(run, dict) and _is_int(run.get("schemaVersion")) and run.get("schemaVersion") == 1
                 and run.get("runID") == run_id,
                 "invalid run.json")
        _require(run.get("kitID") == self.config.raw["kitID"] and run.get("sourceSHA") == self.config.raw["sourceSHA"]
                 and run.get("profileDigest") == self.profile_set.digest, "run does not match the current kit/profile source")
        profile_id = run.get("profileID")
        _require(profile_id in self.profile_set.profiles, "run names an unknown profile")
        selected_ids = run.get("selectedCaseIDs")
        _require(isinstance(selected_ids, list) and selected_ids and len(selected_ids) == len(set(selected_ids))
                 and all(item in self.profile_set.profiles[profile_id]["caseIDs"] for item in selected_ids),
                 "run selection is empty, duplicate, or unknown")
        _require(selected_ids == [item for item in self.profile_set.profiles[profile_id]["caseIDs"] if item in selected_ids],
                 "run selection order differs from the profile")
        _require(isinstance(run.get("attempts"), list), "run attempts must be an array")
        statuses: dict[str, int] = {}
        attempts = []
        latest_by_case: dict[str, str] = {}
        seen_attempts: set[str] = set()
        for attempt_ref in run.get("attempts", []):
            _require(isinstance(attempt_ref, dict), "attempt reference must be an object")
            attempt_id = attempt_ref.get("attemptID")
            _identifier(attempt_id, "attempt ID")
            _require(attempt_id not in seen_attempts, "duplicate attempt ID")
            seen_attempts.add(attempt_id)
            attempt_root = _relative_path(run_root / "attempts", attempt_id, "attempt", kind="directory")
            _, attempt = _read_json(attempt_root / "attempt.json", "attempt.json")
            _require(isinstance(attempt, dict) and _is_int(attempt.get("schemaVersion"))
                     and attempt.get("schemaVersion") == 1 and attempt.get("attemptID") == attempt_id
                     and attempt.get("state") in ("running", "finished", "interrupted"), "invalid attempt record")
            attempt_selected = attempt.get("selectedCaseIDs")
            _require(isinstance(attempt_selected, list) and attempt_selected and len(attempt_selected) == len(set(attempt_selected))
                     and all(item in selected_ids for item in attempt_selected), "attempt selection is invalid")
            _require(isinstance(attempt.get("cases"), list), "attempt cases must be an array")
            cases = []
            observed: set[str] = set()
            for reference in attempt.get("cases", []):
                _require(isinstance(reference, dict) and reference.get("caseID") in attempt_selected
                         and reference.get("caseID") not in observed, "duplicate or unknown attempt case")
                case_path = _relative_path(attempt_root, reference.get("path"), "case result", kind="file")
                _, case_result = _read_json(case_path, "case result")
                _require(isinstance(case_result, dict) and _is_int(case_result.get("schemaVersion"))
                         and case_result.get("schemaVersion") == 1 and case_result.get("caseID") == reference.get("caseID"),
                         "case result identity mismatch")
                clean = _public_case(case_result, self.root, run_root)
                _require(clean.get("status") in ("passed", "blocked", "blocked_budget", "blocked_dependency",
                                                  "failed", "cancelled", "interrupted"), "unknown case status")
                cases.append(clean)
                observed.add(clean["caseID"])
                statuses[clean["status"]] = statuses.get(clean["status"], 0) + 1
                latest_by_case[clean["caseID"]] = clean["status"]
            for case_id in attempt_selected:
                if case_id not in observed:
                    missing_status = "interrupted" if attempt.get("state") != "finished" else "failed"
                    cases.append({"caseID": case_id, "status": missing_status, "qualityAssessment": "pending",
                                  "message": "case evidence is missing"})
                    statuses[missing_status] = statuses.get(missing_status, 0) + 1
                    latest_by_case[case_id] = missing_status
            attempts.append({"attemptID": attempt_id, "state": attempt.get("state", "interrupted"),
                             "preflight": _public_case(attempt.get("preflight", {}), self.root, run_root),
                             "cases": cases})
        overall = "complete" if all(latest_by_case.get(item) == "passed" for item in selected_ids) else "incomplete"
        summary = {"schemaVersion": 1, "runID": run_id, "kitID": run.get("kitID"),
                   "sourceSHA": run.get("sourceSHA"), "profileID": profile_id,
                   "profileTitle": self.profile_set.profiles[profile_id]["title"],
                   "selectedCaseIDs": run.get("selectedCaseIDs"), "overall": overall,
                   "qualityAssessment": "pending", "statusCounts": statuses, "attempts": attempts,
                   "generatedAt": _utc_now()}
        _atomic_json(run_root / "summary.json", summary)
        html_text = _summary_html(summary)
        _atomic_bytes(run_root / "summary.html", html_text.encode("utf-8"))
        zip_path = run_root / "summary.zip"
        temporary = run_root / f".summary.{uuid.uuid4().hex}.zip"
        try:
            with zipfile.ZipFile(temporary, "x", compression=zipfile.ZIP_DEFLATED) as archive:
                archive.write(run_root / "summary.json", "summary.json")
                archive.write(run_root / "summary.html", "summary.html")
                exported: set[str] = set()
                for attempt in summary["attempts"]:
                    for case in attempt["cases"]:
                        for artifact in case.get("artifacts", []):
                            relative_raw = artifact.get("path")
                            path = _relative_path(run_root, relative_raw, "recorded public artifact", kind="file")
                            _require("private" not in Path(relative_raw).parts and relative_raw not in exported,
                                     "private or duplicate artifact cannot be exported")
                            _require(_is_int(artifact.get("bytes")) and path.stat().st_size == artifact["bytes"]
                                     and isinstance(artifact.get("sha256"), str) and HEX64.fullmatch(artifact["sha256"])
                                     and _sha256_file(path) == artifact["sha256"], "recorded artifact changed before export")
                            exported.add(relative_raw)
                            archive.write(path, relative_raw)
            os.replace(temporary, zip_path)
        finally:
            with contextlib.suppress(FileNotFoundError):
                temporary.unlink()
        _atomic_bytes(run_root / "summary.zip.sha256", (_sha256_file(zip_path) + "  summary.zip\n").encode("ascii"))
        return summary


def _same_number(actual: Any, expected: Any) -> bool:
    return _is_number(actual) and _is_number(expected) and float(actual) == float(expected)


def _finite_decimal(value: str) -> bool:
    try: return math.isfinite(float(value)) and float(value) >= 0
    except ValueError: return False


def _validate_actual_options(options: dict[str, Any], case: dict[str, Any], model: CatalogModel,
                             kit_root: Path, budget_mib: int, source: dict[str, Any] | None = None) -> None:
    prompt = _relative_path(kit_root, case["promptFile"], f"case {case['id']} prompt", kind="file").read_text(encoding="utf-8")
    _require(options.get("prompt") == prompt, f"CLI prompt differs from frozen input for {case['id']}")
    _require(_is_int(options.get("memoryBudgetMiB")) and options["memoryBudgetMiB"] == max(1, budget_mib),
             f"CLI memory budget differs for {case['id']}")
    parameters = case["parameters"]
    fields = {"text": ("maxTokens", "temperature", "topP", "maxPromptTokens", "maxOutputTokens", "cacheLimitMiB"),
              "image": ("imageProfile", "width", "height", "steps", "guidance", "seed"),
              "audio": ("audioOperation", "durationSeconds", "audioStrength", "audioEditStartFrame", "audioEditEndFrame",
                        "steps", "guidance", "seed")
              }[case["capability"]]
    for field in fields:
        expected = parameters.get(field)
        actual = options.get(field)
        if field == "seed":
            _require(_is_int(actual) and actual >= 0 and actual == int(expected), f"CLI seed differs for {case['id']}")
        elif expected is None:
            _require(actual is None, f"CLI {field} unexpectedly set for {case['id']}")
        elif _is_number(expected):
            _require(_same_number(actual, expected), f"CLI {field} differs for {case['id']}")
        else:
            _require(actual == expected, f"CLI {field} differs for {case['id']}")
    if case["capability"] == "audio":
        _require(options.get("audioProfile") == model.audio_profile, f"CLI audioProfile differs for {case['id']}")
        _require(_same_number(options.get("timeoutSeconds"), case["timeoutSeconds"]), f"CLI audio timeout differs for {case['id']}")
        if source is None:
            _require(options.get("audioSource") is None and options.get("audioSourceSHA256") is None
                     and options.get("audioSourceFrames") is None, f"CLI has unexpected audio source for {case['id']}")
        else:
            _require(options.get("audioSource") == source["path"] and options.get("audioSourceSHA256") == source["sha256"]
                     and _is_int(options.get("audioSourceFrames")) and options["audioSourceFrames"] == source["frames"],
                     f"CLI audio source options differ for {case['id']}")
    if case["capability"] == "image":
        _require(_is_int(options.get("imageMemoryLimitMiB"))
                 and options["imageMemoryLimitMiB"] == max(1, budget_mib), f"CLI image memory limit differs for {case['id']}")


def _find_mapping_with_key(value: Any, key: str) -> dict[str, Any] | None:
    if isinstance(value, dict):
        if key in value: return value
        for child in value.values():
            found = _find_mapping_with_key(child, key)
            if found is not None: return found
    elif isinstance(value, list):
        for child in value:
            found = _find_mapping_with_key(child, key)
            if found is not None: return found
    return None


def _validate_request_payload(request: dict[str, Any], case: dict[str, Any], model: CatalogModel,
                              root: Path, source: dict[str, Any] | None) -> None:
    model_url = request.get("model", {}).get("directory")
    parsed = urllib.parse.urlparse(model_url) if isinstance(model_url, str) else None
    _require(parsed is not None and parsed.scheme == "file"
             and Path(urllib.parse.unquote(parsed.path)).resolve(strict=False) == model.directory.resolve(strict=False),
             f"CLI request model differs for {case['id']}")
    payload = _find_mapping_with_key(request.get("input"), "prompt")
    _require(payload is not None, f"CLI request input missing for {case['id']}")
    prompt = _relative_path(root, case["promptFile"], f"case {case['id']} prompt", kind="file").read_text(encoding="utf-8")
    _require(payload.get("prompt") == prompt, f"CLI request prompt differs for {case['id']}")
    p = case["parameters"]
    if case["capability"] == "text":
        expected = {"maxTokens": p["maxTokens"], "temperature": p["temperature"], "topP": p["topP"]}
    elif case["capability"] == "image":
        expected = {"width": p["width"], "height": p["height"], "steps": p["steps"],
                    "guidanceScale": p["guidance"], "seed": int(p["seed"])}
    else:
        expected = {"durationSeconds": p["durationSeconds"], "steps": p["steps"],
                    "guidanceScale": p["guidance"], "seed": int(p["seed"]),
                    "strength": p["audioStrength"], "operation": p["audioOperation"]}
    for key, wanted in expected.items():
        actual = payload.get(key)
        if key == "seed": _require(_is_int(actual) and actual == wanted, f"CLI request seed differs for {case['id']}")
        elif _is_number(wanted): _require(_same_number(actual, wanted), f"CLI request {key} differs for {case['id']}")
        else: _require(actual == wanted, f"CLI request {key} differs for {case['id']}")
    if case["capability"] == "audio":
        if source is None: _require(payload.get("source") is None, f"CLI request has an unexpected source for {case['id']}")
        else:
            observed_source = payload.get("source")
            _require(isinstance(observed_source, dict) and observed_source.get("sha256") == source["sha256"]
                     and _is_int(observed_source.get("frameCount")) and observed_source["frameCount"] == source["frames"],
                     f"CLI request source differs for {case['id']}")
            parsed_source = urllib.parse.urlparse(observed_source.get("url", ""))
            _require(parsed_source.scheme == "file" and Path(urllib.parse.unquote(parsed_source.path)).resolve(strict=False)
                     == Path(source["path"]).resolve(strict=False), f"CLI request source path differs for {case['id']}")
        region = payload.get("editRegion")
        if p["audioOperation"] == "inpaint":
            _require(isinstance(region, dict) and _is_int(region.get("startFrame")) and _is_int(region.get("endFrame"))
                     and region["startFrame"] == p["audioEditStartFrame"] and region["endFrame"] == p["audioEditEndFrame"],
                     f"CLI request edit region differs for {case['id']}")
        else:
            _require(region is None, f"CLI request has unexpected edit region for {case['id']}")


def _validate_audio_provider(cli_metadata: Any, artifact: dict[str, Any], case: dict[str, Any],
                             model: CatalogModel, run_id: str, artifact_root: Path, frozen_prompt: str,
                             source: dict[str, Any] | None) -> dict[str, Any]:
    _require(isinstance(cli_metadata, dict) and cli_metadata.get("modelRevision") == model.revision
             and cli_metadata.get("profile") == model.audio_profile, f"audio CLI metadata is invalid for {case['id']}")
    record_raw = cli_metadata.get("recordPath")
    _require(isinstance(record_raw, str), f"audio provider record path is missing for {case['id']}")
    record_path = Path(record_raw)
    _require(record_path.is_absolute() and record_path.exists() and record_path.is_file() and not record_path.is_symlink(),
             f"audio provider record is missing or unsafe for {case['id']}")
    try:
        relative = record_path.relative_to(artifact_root)
    except ValueError as error:
        raise KitError(f"audio provider record escapes artifacts for {case['id']}") from error
    cursor = artifact_root
    for part in relative.parts:
        cursor /= part
        _require(not cursor.is_symlink(), f"audio provider record crosses a symlink for {case['id']}")
    _, provider = _read_json(record_path, f"audio provider record for {case['id']}", MAX_JSON_BYTES)
    _require(isinstance(provider, dict) and _is_int(provider.get("schemaVersion")) and provider["schemaVersion"] == 1
             and provider.get("type") == "result" and isinstance(provider.get("runID"), str)
             and provider["runID"].lower() == run_id.lower(), f"audio provider identity is invalid for {case['id']}")
    published_path = Path(artifact["absoluteValidatedPath"]).resolve(strict=True)
    provider_artifact = provider.get("artifact")
    _require(isinstance(provider_artifact, dict) and isinstance(provider_artifact.get("path"), str)
             and Path(provider_artifact["path"]).resolve(strict=True) == published_path
             and provider_artifact.get("sha256") == artifact["sha256"]
             and _is_int(provider_artifact.get("byteCount")) and provider_artifact["byteCount"] == artifact["bytes"]
             and _is_int(provider_artifact.get("frameCount")) and provider_artifact["frameCount"] == artifact["frames"]
             and provider_artifact.get("sampleRate") == 44100 and provider_artifact.get("channels") == 2
             and provider_artifact.get("encoding") == "float32", f"audio provider artifact differs for {case['id']}")
    metadata = provider.get("metadata")
    _require(isinstance(metadata, dict) and metadata.get("profile") == model.audio_profile
             and metadata.get("modelRevision") == model.revision, f"audio provider metadata differs for {case['id']}")
    request = metadata.get("request"); parameters = case["parameters"]
    _require(isinstance(request, dict) and _is_int(request.get("schemaVersion")) and request["schemaVersion"] == 1
             and isinstance(request.get("runID"), str) and request["runID"].lower() == run_id.lower()
             and request.get("prompt") == frozen_prompt,
             f"audio provider request identity is invalid for {case['id']}")
    expected = {"durationSeconds": parameters["durationSeconds"], "guidanceScale": parameters["guidance"],
                "operation": parameters["audioOperation"], "seed": int(parameters["seed"]),
                "steps": parameters["steps"], "strength": parameters["audioStrength"]}
    for key, wanted in expected.items():
        actual = request.get(key)
        if key in ("seed", "steps"): _require(_is_int(actual) and actual == wanted, f"audio provider {key} differs")
        elif _is_number(wanted): _require(_same_number(actual, wanted), f"audio provider {key} differs")
        else: _require(actual == wanted, f"audio provider {key} differs")
    provider_source = request.get("source")
    if source is None:
        _require(provider_source is None, f"audio provider has unexpected source for {case['id']}")
    else:
        _require(isinstance(provider_source, dict) and provider_source.get("sha256") == source["sha256"]
                 and _is_int(provider_source.get("frameCount")) and provider_source["frameCount"] == source["frames"]
                 and provider_source.get("sampleRate") == 44100 and provider_source.get("channels") == 2,
                 f"audio provider source differs for {case['id']}")
    region = request.get("editRegion")
    if parameters["audioOperation"] == "inpaint":
        _require(isinstance(region, dict) and region.get("startFrame") == parameters["audioEditStartFrame"]
                 and region.get("endFrame") == parameters["audioEditEndFrame"],
                 f"audio provider edit region differs for {case['id']}")
    else:
        _require(region is None, f"audio provider has unexpected edit region for {case['id']}")
    timings = metadata.get("timingsSeconds"); allocations = metadata.get("mlxAllocations"); precision = metadata.get("precision")
    _require(isinstance(timings, dict) and all(isinstance(key, str) and _is_number(value) and value >= 0
             for key, value in timings.items()), f"audio provider timings are invalid for {case['id']}")
    _require(isinstance(precision, dict) and all(isinstance(key, str) and isinstance(value, str)
             for key, value in precision.items()), f"audio provider precision is invalid for {case['id']}")
    _require(isinstance(allocations, dict), f"audio provider allocations are invalid for {case['id']}")
    for key in ("activeBytes", "cacheBytes", "peakBytes", "observedActiveLowerBoundBytes"):
        _require(_is_int(allocations.get(key)) and allocations[key] >= 0, f"audio provider allocation {key} is invalid")
    post = allocations.get("postCleanup")
    _require(isinstance(post, dict) and all(_is_int(post.get(key)) and post[key] >= 0
             for key in ("activeBytes", "cacheBytes", "peakBytes", "observedActiveLowerBoundBytes")),
             f"audio provider post-cleanup observation is invalid for {case['id']}")
    return {"record": str(relative), "runID": provider["runID"], "profile": metadata["profile"],
            "modelRevision": metadata["modelRevision"], "vendorRevision": metadata.get("vendorRevision"),
            "source": provider_source,
            "precision": precision, "timingsSeconds": timings, "mlxAllocations": allocations,
            "measurementSource": "provider"}


def _public_process_dict(value: Mapping[str, Any]) -> dict[str, Any]:
    samples = [{"elapsedSeconds": item.get("elapsedSeconds"), "rssKiB": item.get("rssKiB")}
               for item in value.get("rss_samples_kib", []) if isinstance(item, dict)]
    return {"returnCode": value.get("return_code"), "elapsedSeconds": value.get("elapsed_seconds"),
            "stdoutBytes": value.get("stdout_bytes"), "stderrBytes": value.get("stderr_bytes"),
            "stdoutLimited": value.get("stdout_limited"), "stderrLimited": value.get("stderr_limited"),
            "timedOut": value.get("timed_out"), "cancellationRequested": value.get("cancellation_requested"),
            "forcedStop": value.get("forced_stop"), "rssSampleIntervalSeconds": PROCESS_POLL_SECONDS,
            "rssSamples": samples, "rssSamplesTruncated": value.get("rss_samples_truncated", False),
            "childRSS": value.get("child_rss", "unknown"), "rssAggregation": "not-summed"}


def _public_process(value: ProcessResult) -> dict[str, Any]:
    return _public_process_dict(dataclasses.asdict(value))


def _sysctl(key: str) -> str | None:
    tool = Path("/usr/sbin/sysctl")
    if not tool.is_file(): return None
    try:
        result = subprocess.run([str(tool), "-n", key], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                timeout=1, check=False, env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"})
        value = result.stdout.decode("utf-8", errors="strict").strip()
        return value if result.returncode == 0 and value else None
    except (OSError, UnicodeDecodeError, subprocess.TimeoutExpired):
        return None


def _rss_kib(pid: int) -> int | None:
    ps = Path("/bin/ps")
    if not ps.exists():
        return None
    try:
        result = subprocess.run([str(ps), "-o", "rss=", "-p", str(pid)], check=False,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=1,
                                env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"})
        raw = result.stdout.strip()
        return int(raw) if result.returncode == 0 and raw else None
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None


def _artifact_path(reference: Any, root: Path, media_type: str) -> Path:
    _ordinary_directory(root, "artifact root")
    _require(isinstance(reference, dict) and reference.get("mediaType") == media_type, "artifact media type is invalid")
    url = reference.get("url")
    _require(isinstance(url, str), "artifact URL is missing")
    parsed = urllib.parse.urlparse(url)
    _require(parsed.scheme == "file" and parsed.netloc in ("", "localhost"), "artifact must use a local file URL")
    path = Path(urllib.parse.unquote(parsed.path))
    _require(path.is_absolute() and path.exists() and path.is_file() and not path.is_symlink(), "artifact is not a regular file")
    try:
        relative = path.relative_to(root)
        cursor = root
        for part in relative.parts:
            cursor /= part
            _require(not cursor.is_symlink(), "artifact path crosses a symbolic link")
        path.resolve(strict=True).relative_to(root.resolve(strict=True))
    except ValueError as error:
        raise KitError("artifact escapes its case directory") from error
    return path


def _validate_png_reference(reference: Any, root: Path, expected_width: int, expected_height: int) -> dict[str, Any]:
    path = _artifact_path(reference, root, "image/png")
    _require(path.stat().st_size <= expected_width * expected_height * 8 + 16 * MIB, "PNG exceeds its bounded size")
    raw = path.read_bytes()
    _require(raw.startswith(b"\x89PNG\r\n\x1a\n"), "PNG signature is invalid")
    offset = 8; width = height = None; idat = bytearray(); ended = False
    bit_depth = color_type = interlace = None; chunk_index = 0; saw_idat = False; idat_ended = False
    while offset + 12 <= len(raw):
        length = struct.unpack(">I", raw[offset:offset + 4])[0]
        _require(length <= len(raw) - offset - 12, "PNG chunk length is invalid")
        chunk_type = raw[offset + 4:offset + 8]
        data = raw[offset + 8:offset + 8 + length]
        expected_crc = struct.unpack(">I", raw[offset + 8 + length:offset + 12 + length])[0]
        _require(zlib.crc32(chunk_type + data) & 0xFFFFFFFF == expected_crc, "PNG CRC is invalid")
        if chunk_type == b"IHDR":
            _require(length == 13 and width is None and chunk_index == 0, "PNG IHDR is invalid")
            width, height, bit_depth, color_type, compression, filtering, interlace = struct.unpack(">IIBBBBB", data)
            _require(compression == 0 and filtering == 0 and interlace == 0, "unsupported PNG encoding")
        elif chunk_type == b"IDAT":
            _require(not idat_ended, "PNG IDAT chunks must be contiguous")
            saw_idat = True
            idat.extend(data)
        elif chunk_type == b"IEND":
            _require(length == 0 and saw_idat, "PNG IEND is invalid"); ended = True; offset += 12; break
        else:
            if saw_idat: idat_ended = True
            _require(not (65 <= chunk_type[0] <= 90),
                     f"unsupported PNG critical chunk: {chunk_type!r}")
        offset += 12 + length
        chunk_index += 1
    _require(ended and offset == len(raw), "PNG is truncated or has trailing bytes")
    _require((width, height) == (expected_width, expected_height), "PNG dimensions differ from the request")
    channels = {0: 1, 2: 3, 4: 2, 6: 4}.get(color_type)
    _require(channels is not None and bit_depth in (8, 16), "unsupported PNG pixel format")
    row_bytes = math.ceil(expected_width * channels * bit_depth / 8)
    decoded_limit = expected_height * (row_bytes + 1)
    try:
        decoder = zlib.decompressobj()
        pixels = decoder.decompress(bytes(idat), decoded_limit + 1)
    except zlib.error as error:
        raise KitError(f"PNG pixels cannot be decoded: {error}") from error
    _require(decoder.eof and not decoder.unused_data and len(pixels) == decoded_limit, "PNG decoded pixel length is invalid")
    bpp = max(1, math.ceil(channels * bit_depth / 8)); previous = bytearray(row_bytes)
    for row in range(expected_height):
        start = row * (row_bytes + 1); filter_type = pixels[start]; encoded = pixels[start + 1:start + 1 + row_bytes]
        _require(filter_type <= 4, "PNG filter is invalid")
        decoded = bytearray(row_bytes)
        for index, byte in enumerate(encoded):
            left = decoded[index - bpp] if index >= bpp else 0
            up = previous[index]; upper_left = previous[index - bpp] if index >= bpp else 0
            if filter_type == 0: predictor = 0
            elif filter_type == 1: predictor = left
            elif filter_type == 2: predictor = up
            elif filter_type == 3: predictor = (left + up) // 2
            else:
                p = left + up - upper_left; pa, pb, pc = abs(p-left), abs(p-up), abs(p-upper_left)
                predictor = left if pa <= pb and pa <= pc else (up if pb <= pc else upper_left)
            decoded[index] = (byte + predictor) & 255
        previous = decoded
    return {"type": "image/png", "path": str(path.relative_to(root)), "absoluteValidatedPath": str(path),
            "bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest(), "width": width, "height": height}


def _wav_info(path: Path) -> dict[str, Any]:
    size_total = path.stat().st_size
    _require(size_total <= 512 * MIB, "WAV exceeds the bounded artifact limit")
    with path.open("rb") as handle:
        header = handle.read(12)
        _require(len(header) == 12 and header[:4] == b"RIFF" and header[8:12] == b"WAVE", "WAV RIFF header is invalid")
        _require(struct.unpack("<I", header[4:8])[0] + 8 == size_total, "WAV RIFF size is invalid")
        offset = 12; fmt = None; data_offset = data_size = None; seen: set[bytes] = set()
        while offset < size_total:
            _require(offset + 8 <= size_total, "WAV has a trailing malformed chunk")
            handle.seek(offset); chunk_header = handle.read(8); kind, size = chunk_header[:4], struct.unpack("<I", chunk_header[4:])[0]
            start, end = offset + 8, offset + 8 + size
            _require(end <= size_total, "WAV chunk is truncated")
            if kind in (b"fmt ", b"data"):
                _require(kind not in seen, "WAV contains duplicate fmt/data chunks"); seen.add(kind)
            if kind == b"fmt ":
                handle.seek(start); fmt = handle.read(size)
            elif kind == b"data": data_offset, data_size = start, size
            offset = end + (size & 1)
        _require(offset == size_total and fmt is not None and len(fmt) >= 16 and data_offset is not None,
                 "WAV fmt/data chunks are missing or malformed")
    tag, channels, rate, byte_rate, alignment, bits = struct.unpack("<HHIIHH", fmt[:16])
    _require((tag, channels, rate, byte_rate, alignment, bits) == (3, 2, 44100, 352800, 8, 32),
             "WAV must be 44100 Hz stereo float32")
    assert data_size is not None
    _require(data_size % 8 == 0, "WAV data is not frame aligned")
    with path.open("rb") as handle:
        handle.seek(data_offset); remaining = data_size
        while remaining:
            block = handle.read(min(1024 * 1024, remaining)); remaining -= len(block)
            _require(block and len(block) % 4 == 0 and all(math.isfinite(value[0]) for value in struct.iter_unpack("<f", block)),
                     "WAV contains non-finite or truncated samples")
    return {"bytes": size_total, "frames": data_size // 8, "dataOffset": data_offset,
            "dataBytes": data_size, "sha256": _sha256_file(path)}


def _compare_ranges(first: Path, first_offset: int, second: Path, second_offset: int, byte_count: int) -> bool:
    with first.open("rb") as left, second.open("rb") as right:
        left.seek(first_offset); right.seek(second_offset); remaining = byte_count
        while remaining:
            amount = min(MIB, remaining)
            if left.read(amount) != right.read(amount): return False
            remaining -= amount
    return True


def _expected_audio_frames(duration: Any) -> int:
    return int(math.floor(float(duration) * 44100 / 2 + 0.5)) * 2


def _validate_wav_reference(reference: Any, root: Path, duration: Any,
                            source: dict[str, Any] | None, parameters: dict[str, Any]) -> dict[str, Any]:
    path = _artifact_path(reference, root, "audio/wav")
    info = _wav_info(path); frames = info["frames"]
    if source is None:
        _require(frames == _expected_audio_frames(duration), "WAV frame count differs from the request")
    else:
        _require(frames == source["frames"], "edited WAV frame count differs from its source")
        if parameters["audioOperation"] == "inpaint":
            source_path = Path(source["path"]); source_info = _wav_info(source_path)
            _require(source_info["frames"] == frames, "inpaint source frame count changed")
            start, end = parameters["audioEditStartFrame"], parameters["audioEditEndFrame"]
            _require(_compare_ranges(path, info["dataOffset"], source_path, source_info["dataOffset"], start * 8)
                     and _compare_ranges(path, info["dataOffset"] + end * 8, source_path,
                                         source_info["dataOffset"] + end * 8, (frames - end) * 8),
                     "inpaint changed PCM outside its edit interval")
    return {"type": "audio/wav", "path": str(path.relative_to(root)), "absoluteValidatedPath": str(path),
            "bytes": info["bytes"], "sha256": info["sha256"], "frames": frames,
            "sampleRate": 44100, "channels": 2, "format": "float32"}


def _public_case(value: Any, kit_root: Path, run_root: Path) -> dict[str, Any]:
    _require(isinstance(value, dict), "case result must be an object")
    excluded = {"process", "sourceForDependents", "absoluteValidatedPath"}
    def clean(item: Any) -> Any:
        if isinstance(item, dict):
            return {key: clean(part) for key, part in item.items() if key not in excluded}
        if isinstance(item, list): return [clean(part) for part in item]
        if isinstance(item, str):
            return item.replace(str(run_root), "$RUN").replace(str(kit_root), "$KIT").replace(str(Path.home()), "$HOME")
        return item
    return clean(value)


def _summary_html(summary: dict[str, Any]) -> str:
    rows = []
    for attempt in summary["attempts"]:
        for case in attempt["cases"]:
            rows.append("<tr><td>{}</td><td>{}</td><td>{}</td></tr>".format(
                html.escape(str(attempt["attemptID"])), html.escape(str(case["caseID"])), html.escape(str(case["status"]))))
    return ("<!doctype html><meta charset=\"utf-8\"><title>D Test Kit Summary</title>"
            f"<h1>D Test Kit: {html.escape(str(summary['runID']))}</h1>"
            f"<p>Profile: {html.escape(str(summary['profileTitle']))}</p>"
            f"<p>Overall: {html.escape(str(summary['overall']))}; quality: pending</p>"
            "<table><thead><tr><th>Attempt</th><th>Case</th><th>Status</th></tr></thead><tbody>"
            + "".join(rows) + "</tbody></table>\n")


def _parse_cases(raw: str | None) -> list[str] | None:
    if raw is None: return None
    values = raw.split(",")
    _require(all(values), "--cases must be a comma-separated nonempty list")
    return values


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="D portable offline test-kit runner",
        epilog="Exit 0 means the requested runner command completed; inspect summary.overall and each case status for generation success. Exit 1 is blocked/runtime/output failure, 2 invalid input, 130 user interruption.")
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name in ("preflight", "menu"):
        command = subparsers.add_parser(name)
        command.add_argument("--kit", type=Path, default=Path(__file__).resolve().parent)
    run = subparsers.add_parser("run")
    run.add_argument("--kit", type=Path, default=Path(__file__).resolve().parent)
    run.add_argument("--profile", required=True)
    run.add_argument("--cases")
    run.add_argument("--resume")
    summarize = subparsers.add_parser("summarize")
    summarize.add_argument("--kit", type=Path, default=Path(__file__).resolve().parent)
    summarize.add_argument("--run", required=True)
    return parser


def _menu(runner: KitRunner) -> dict[str, Any] | None:
    preflight = runner.preflight()
    print(f"预检：{preflight['status']}；可用预算 {preflight['budget']['admissionBudgetMiB']} MiB")
    profiles = list(runner.profile_set.profiles.values())
    for index, profile_entry in enumerate(profiles, 1):
        print(f"{index}. {profile_entry['title']} ({profile_entry['id']})")
    raw = input("选择配置（q 退出）：").strip()
    if raw.lower() == "q": return None
    _require(raw.isdigit() and 1 <= int(raw) <= len(profiles), "无效选择")
    print("请确认其他 GPU 任务已停止。本次仅运行所选固定配置。")
    _require(input("输入 RUN 开始：").strip() == "RUN", "用户取消")
    return runner.run(profiles[int(raw) - 1]["id"])


def main(arguments: Sequence[str] | None = None) -> int:
    try:
        args = _parser().parse_args(arguments)
        runner = KitRunner(args.kit)
        if args.command == "preflight": result = runner.preflight()
        elif args.command == "run": result = runner.run(args.profile, _parse_cases(args.cases), args.resume)
        elif args.command == "summarize": result = runner.summarize(args.run)
        else: result = _menu(runner)
        if result is not None:
            print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
        return 0
    except KitError as error:
        print(json.dumps({"schemaVersion": 1, "status": error.kind, "error": str(error)}, ensure_ascii=False), file=sys.stderr)
        return 2 if error.kind == "invalid" else 1
    except KeyboardInterrupt:
        print("已停止；当前用例已请求清理，后续用例未启动。", file=sys.stderr)
        return 130
    except OSError as error:
        print(json.dumps({"schemaVersion": 1, "status": "failed", "error": f"filesystem/process error: {error}"},
                         ensure_ascii=False), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
