"""Pure-stdlib, strict ACE 1.5 XL SFT launch/request/resource contract."""

from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path
import re
import struct
from urllib.parse import unquote, urlsplit
from typing import Any


PROFILE = "ace-step-1.5-xl-sft-mlx-f32-v1"
MODEL_REPOSITORY = "ACE-Step/acestep-v15-xl-sft"
MODEL_REVISION = "d06de46b4622f781cf07f4a013a67d591ca52819"
SHARED_REPOSITORY = "ACE-Step/Ace-Step1.5"
SHARED_REVISION = "19671f406d603126926c1b7e2adc169acbcade22"
SOURCE_REVISION = "ca1e85fe9430179831e6bc6be790c332190a3866"
MAX_REQUEST_BYTES = 3 * 1024 * 1024
MAX_MANIFEST_BYTES = 2 * 1024 * 1024
SHA = re.compile(r"[0-9a-f]{64}\Z")


class ACEContractError(Exception):
    def __init__(self, message: str, kind: str = "invalidRequest") -> None:
        super().__init__(message)
        self.kind = kind


def _unique_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise ACEContractError(f"duplicate JSON key: {key}")
        value[key] = item
    return value


def load_json(path: Path, maximum: int) -> dict[str, Any]:
    try:
        if not path.is_file() or path.stat().st_size > maximum:
            raise ACEContractError("ACE JSON file is absent or too large", "configuration")
        raw = path.read_bytes()
        value = json.loads(raw, object_pairs_hook=_unique_pairs,
                           parse_constant=lambda _: (_ for _ in ()).throw(ACEContractError("nonfinite JSON number")))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ACEContractError(f"cannot read ACE JSON: {exc}", "configuration") from exc
    if not isinstance(value, dict):
        raise ACEContractError("ACE JSON root must be an object")
    return value


def exact(value: Any, required: set[str], optional: set[str] = frozenset(), *, label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or not required <= value.keys() or not value.keys() <= required | optional:
        raise ACEContractError(f"{label} has missing or unknown fields")
    return value


def _integer(value: Any, low: int, high: int, label: str) -> int:
    if type(value) is not int or not low <= value <= high:
        raise ACEContractError(f"invalid {label}")
    return value


def _float(value: Any, low: float, high: float, label: str) -> float:
    if type(value) not in (int, float) or not math.isfinite(value) or not low <= value <= high:
        raise ACEContractError(f"invalid {label}")
    return float(value)


def _string(value: Any, maximum: int, label: str) -> str:
    if not isinstance(value, str) or "\0" in value or len(value.encode("utf-8")) > maximum:
        raise ACEContractError(f"invalid {label}")
    return value


def _reference(value: Any, label: str) -> dict[str, Any]:
    ref = exact(value, {"url", "sha256", "frameCount", "sampleRate", "channels"}, label=label)
    url = urlsplit(_string(ref["url"], 8192, label + " URL"))
    if url.scheme != "file" or url.netloc not in ("", "localhost") or url.query or url.fragment:
        raise ACEContractError(f"{label} requires a local file URL")
    path = Path(unquote(url.path))
    if not path.is_absolute() or ".." in path.parts:
        raise ACEContractError(f"{label} path is invalid")
    if not isinstance(ref["sha256"], str) or not SHA.fullmatch(ref["sha256"]):
        raise ACEContractError(f"{label} SHA-256 is malformed")
    _integer(ref["frameCount"], 1, 2**62, label + " frames")
    if ref["sampleRate"] != 48000 or ref["channels"] != 2:
        raise ACEContractError(f"{label} requires stereo 48 kHz WAV")
    return ref


def reference_path(ref: dict[str, Any]) -> Path:
    return Path(unquote(urlsplit(ref["url"]).path))


def validate_request(value: dict[str, Any]) -> dict[str, Any]:
    request = exact(value, {"schemaVersion", "runID", "operation", "prompt", "durationSeconds",
                            "seed", "parameters"},
                    {"source", "editRegion", "requestedSource", "requestedReference"}, label="ACE request")
    if request["schemaVersion"] != 1 or not isinstance(request["runID"], str):
        raise ACEContractError("invalid ACE request schema/run ID")
    import uuid
    try:
        if str(uuid.UUID(request["runID"])) != request["runID"]:
            raise ValueError()
    except ValueError as exc:
        raise ACEContractError("invalid canonical ACE run ID") from exc
    if request["operation"] not in ("generate", "variation", "inpaint"):
        raise ACEContractError("unknown ACE operation")
    _string(request["prompt"], 1_048_576, "prompt")
    duration = _float(request["durationSeconds"], 0.1, 600, "duration")
    if abs(duration * 10 - round(duration * 10)) > 1e-6:
        raise ACEContractError("ACE duration is outside the 0.1-second grid")
    _integer(request["seed"], 0, 2**32 - 1, "seed")
    params = exact(request["parameters"], {"kind", "ace"}, label="ACE parameters")
    if params["kind"] != "aceStep15":
        raise ACEContractError("ACE parameter family is wrong")
    ace = exact(params["ace"], {"executionProfile", "vocal", "steps", "guidanceScale"},
                {"bpm", "keyScale", "timeSignature", "referenceAudio", "editOptions"}, label="ACE condition")
    if ace["executionProfile"] != PROFILE:
        raise ACEContractError("ACE execution profile is wrong")
    _integer(ace["steps"], 1, 2**31 - 1, "steps")
    _float(ace["guidanceScale"], 0, float("inf"), "guidance")
    vocal = exact(ace["vocal"], {"kind"}, {"text", "language"}, label="ACE vocal")
    if vocal["kind"] == "instrumental":
        exact(vocal, {"kind"}, label="instrumental vocal")
    elif vocal["kind"] == "lyrics":
        exact(vocal, {"kind", "text", "language"}, label="lyric vocal")
        _string(vocal["text"], 1_048_576, "lyrics")
        if not _string(vocal["language"], 64, "language"):
            raise ACEContractError("language is empty")
    else:
        raise ACEContractError("unknown ACE vocal kind")
    if ace.get("bpm") is not None:
        _integer(ace["bpm"], 1, 2**31 - 1, "BPM")
    if ace.get("keyScale") is not None:
        _string(ace["keyScale"], 128, "key")
    if ace.get("timeSignature") is not None and ace["timeSignature"] not in ("2", "3", "4", "6"):
        raise ACEContractError("unknown ACE meter")
    if ace.get("referenceAudio") is not None:
        _reference(ace["referenceAudio"], "ACE style reference")
    source = request.get("source")
    if source is not None:
        _reference(source, "ACE edit source")
        if source["frameCount"] != round(duration * 48000):
            raise ACEContractError("ACE edit duration must equal exact source frames")
    region = request.get("editRegion")
    options = ace.get("editOptions")
    op = request["operation"]
    if op == "generate":
        if source is not None or region is not None or options is not None:
            raise ACEContractError("ACE generation cannot accept edit input")
    elif op == "variation":
        if source is None or region is not None:
            raise ACEContractError("ACE variation requires only a source")
        cover = exact(options, {"kind", "audioCoverStrength", "noiseStrength"}, label="ACE cover")
        if cover["kind"] != "cover":
            raise ACEContractError("ACE variation requires cover options")
        _float(cover["audioCoverStrength"], 0, 1, "cover strength")
        _float(cover["noiseStrength"], 0, 1, "noise strength")
    else:
        if source is None:
            raise ACEContractError("ACE repaint requires source")
        region = exact(region, {"startFrame", "endFrame"}, label="ACE edit region")
        start = _integer(region["startFrame"], 0, source["frameCount"] - 1, "start frame")
        _integer(region["endFrame"], start + 1, source["frameCount"], "end frame")
        repaint = exact(options, {"kind", "strength"}, label="ACE repaint")
        if repaint["kind"] != "repaint":
            raise ACEContractError("ACE inpaint requires repaint options")
        _float(repaint["strength"], 0, 1, "repaint strength")
    for key in ("requestedSource", "requestedReference"):
        if request.get(key) is not None:
            _string(request[key], 8192, key)
    return request


def validate_manifest(value: dict[str, Any]) -> dict[str, Any]:
    manifest = exact(value, {"schemaVersion", "profile", "modelRepository", "modelRevision",
                             "sharedRepository", "sharedRevision", "sourceRevision", "files"},
                     label="ACE manifest")
    expected = {"schemaVersion": 1, "profile": PROFILE, "modelRepository": MODEL_REPOSITORY,
                "modelRevision": MODEL_REVISION, "sharedRepository": SHARED_REPOSITORY,
                "sharedRevision": SHARED_REVISION, "sourceRevision": SOURCE_REVISION}
    if any(manifest[key] != item for key, item in expected.items()):
        raise ACEContractError("ACE manifest identifies a different model or source", "configuration")
    files = manifest["files"]
    if not isinstance(files, list) or not 1 <= len(files) <= 4096:
        raise ACEContractError("ACE manifest files are absent", "configuration")
    roles: set[str] = set()
    paths: set[str] = set()
    for raw in files:
        item = exact(raw, {"path", "size", "sha256", "role"}, label="ACE manifest file")
        path, role = item["path"], item["role"]
        prefix = {"xl": "checkpoints/acestep-v15-xl-sft/",
                  "vae": "checkpoints/vae/", "embedding": "checkpoints/Qwen3-Embedding-0.6B/"}.get(role)
        if (not isinstance(path, str) or not prefix or not path.startswith(prefix)
                or ".." in Path(path).parts or "//" in path or path.endswith("/")
                or path in paths or type(item["size"]) is not int or item["size"] <= 0
                or not isinstance(item["sha256"], str) or not SHA.fullmatch(item["sha256"])):
            raise ACEContractError("invalid ACE manifest file", "configuration")
        paths.add(path)
        roles.add(role)
    if roles != {"xl", "vae", "embedding"}:
        raise ACEContractError("ACE manifest omits XL, VAE or embedding resources", "configuration")
    return manifest


def verify_manifest_files(manifest: dict[str, Any], root: Path) -> None:
    for item in manifest["files"]:
        path = root / item["path"]
        if path.is_symlink() or not path.is_file() or path.stat().st_size != item["size"]:
            raise ACEContractError(f"ACE resource missing or size changed: {item['path']}", "configuration")
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        if digest.hexdigest() != item["sha256"]:
            raise ACEContractError(f"ACE resource digest changed: {item['path']}", "configuration")


def verify_wav(ref: dict[str, Any]) -> None:
    path = reference_path(ref)
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 512 * 1024 * 1024:
        raise ACEContractError("ACE frozen WAV is absent or oversized")
    raw = path.read_bytes()
    if hashlib.sha256(raw).hexdigest() != ref["sha256"]:
        raise ACEContractError("ACE frozen WAV digest changed")
    if len(raw) < 44 or raw[:4] != b"RIFF" or raw[8:12] != b"WAVE" or struct.unpack_from("<I", raw, 4)[0] + 8 != len(raw):
        raise ACEContractError("ACE frozen WAV container is invalid")
    offset, fmt, frame_bytes = 12, None, None
    while offset < len(raw):
        if offset + 8 > len(raw):
            raise ACEContractError("ACE WAV chunk is truncated")
        tag = raw[offset:offset+4]
        size = struct.unpack_from("<I", raw, offset+4)[0]
        body = offset + 8
        if body + size > len(raw):
            raise ACEContractError("ACE WAV chunk size is invalid")
        if tag == b"fmt ":
            if fmt is not None or size < 16:
                raise ACEContractError("ACE WAV format is duplicated")
            fmt = struct.unpack_from("<HHIIHH", raw, body)
        if tag == b"data":
            if frame_bytes is not None:
                raise ACEContractError("ACE WAV audio data is duplicated")
            frame_bytes = size
        offset = body + size + (size & 1)
    if offset != len(raw) or fmt is None or frame_bytes is None:
        raise ACEContractError("ACE WAV is incomplete")
    code, channels, rate, byte_rate, align, bits = fmt
    if ((code, bits) not in ((3, 32), (1, 16), (1, 24), (1, 32))
            or channels != 2 or rate != 48000 or align != 2 * bits // 8
            or byte_rate != rate * align or frame_bytes % align
            or frame_bytes // align != ref["frameCount"]):
        raise ACEContractError("ACE WAV format or frame count changed")
