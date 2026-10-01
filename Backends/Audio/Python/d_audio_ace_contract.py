"""Pure-stdlib, strict ACE 1.5 XL SFT launch/request/resource contract."""

from __future__ import annotations

import hashlib
import json
import math
import os
import stat
from dataclasses import dataclass
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
SOURCE_PATCHES = (
    ("acestep/core/generation/handler/init_service_loader.py",
     "22b41692bcb73fead4c831d16eaef3dda56cc995577f2353d763445dae7362e1"),
    ("acestep/core/generation/handler/init_service_loader_components.py",
     "621fc7d24ee847835de2eb66f35451120cb92310cf5e112e4edbdf955535d6de"),
)
MAX_REQUEST_BYTES = 3 * 1024 * 1024
MAX_MANIFEST_BYTES = 2 * 1024 * 1024
SHA = re.compile(r"[0-9a-f]{64}\Z")
INT64_LIMIT = 2**63
XL_ROOT = "checkpoints/acestep-v15-xl-sft/"
XL_SHARDS = {f"model-{number:05d}-of-00004.safetensors" for number in range(1, 5)}
REQUIRED_MODEL_FILES = {
    XL_ROOT + name for name in (
        "config.json", "configuration_acestep_v15.py", "modeling_acestep_v15_xl_base.py",
        "apg_guidance.py", "silence_latent.pt", "model.safetensors.index.json")
} | {XL_ROOT + name for name in XL_SHARDS} | {
    "checkpoints/vae/config.json", "checkpoints/vae/diffusion_pytorch_model.safetensors"} | {
    "checkpoints/Qwen3-Embedding-0.6B/" + name for name in (
        "config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json",
        "special_tokens_map.json", "added_tokens.json", "chat_template.jinja",
        "merges.txt", "vocab.json")
}


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
    frames = duration * 48000
    if not math.isfinite(frames) or not 1 <= round(frames) < INT64_LIMIT or abs(frames - round(frames)) > 1e-6:
        raise ACEContractError("ACE duration is outside the 48 kHz frame grid")
    _integer(request["seed"], 0, 2**32 - 1, "seed")
    params = exact(request["parameters"], {"kind", "ace"}, label="ACE parameters")
    if params["kind"] != "aceStep15":
        raise ACEContractError("ACE parameter family is wrong")
    ace = exact(params["ace"], {"executionProfile", "vocal", "steps", "guidanceScale"},
                {"bpm", "keyScale", "timeSignature", "referenceAudio", "editOptions", "loadingStrategy"}, label="ACE condition")
    if ace.get("loadingStrategy", "resident") not in ("resident", "ssdLayered"):
        raise ACEContractError("Unknown ACE loading strategy")
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
        if source["frameCount"] != round(frames):
            raise ACEContractError("ACE edit duration must equal exact source frames")
    region = request.get("editRegion")
    options = ace.get("editOptions")
    op = request["operation"]
    if op == "generate":
        if source is not None or region is not None or options is not None:
            raise ACEContractError("ACE generation cannot accept edit input")
        if abs(duration * 10 - round(duration * 10)) > 1e-6:
            raise ACEContractError("ACE generation requires the 0.1-second grid")
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
                             "sharedRepository", "sharedRevision", "sourceRevision", "files", "sourceFiles"},
                     {"sourcePatches"},
                     label="ACE manifest")
    expected = {"schemaVersion": 1, "profile": PROFILE, "modelRepository": MODEL_REPOSITORY,
                "modelRevision": MODEL_REVISION, "sharedRepository": SHARED_REPOSITORY,
                "sharedRevision": SHARED_REVISION, "sourceRevision": SOURCE_REVISION}
    if any(manifest[key] != item for key, item in expected.items()):
        raise ACEContractError("ACE manifest identifies a different model or source", "configuration")
    patches = manifest.get("sourcePatches")
    if not isinstance(patches, list) or len(patches) != len(SOURCE_PATCHES):
        raise ACEContractError("ACE source patch inventory differs", "configuration")
    for patch, (path, original) in zip(patches, SOURCE_PATCHES):
        exact(patch, {"path", "baseSHA256", "patchedSHA256"}, label="ACE source patch")
        if (patch["path"] != path or patch["baseSHA256"] != original
                or not isinstance(patch["patchedSHA256"], str)
                or not SHA.fullmatch(patch["patchedSHA256"])):
            raise ACEContractError("ACE source patch identity differs", "configuration")
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
    if roles != {"xl", "vae", "embedding"} or not REQUIRED_MODEL_FILES <= paths:
        raise ACEContractError("ACE manifest omits required XL, VAE or embedding resources", "configuration")
    sources = manifest["sourceFiles"]
    if not isinstance(sources, list) or not 5 <= len(sources) <= 4096:
        raise ACEContractError("ACE pinned source inventory is absent", "configuration")
    source_paths: set[str] = set()
    for raw in sources:
        item = exact(raw, {"path", "size", "sha256"}, label="ACE source file")
        path = item["path"]
        if (not isinstance(path, str) or not path or path.startswith("/")
                or any(part in ("", ".", "..") for part in path.split("/"))
                or "\0" in path or path in source_paths
                or type(item["size"]) is not int or item["size"] < 0
                or not isinstance(item["sha256"], str) or not SHA.fullmatch(item["sha256"])):
            raise ACEContractError("invalid ACE source entry", "configuration")
        source_paths.add(path)
    if not {"acestep/handler.py", "acestep/model_downloader.py",
            "acestep/models/xl_sft/modeling_acestep_v15_xl_base.py",
            "acestep/models/xl_sft/configuration_acestep_v15.py",
            "acestep/models/xl_sft/apg_guidance.py"} <= source_paths:
        raise ACEContractError("ACE source inventory omits required official code", "configuration")
    by_path = {item["path"]: item for item in sources}
    if any(patch["path"] not in by_path or by_path[patch["path"]]["sha256"] != patch["patchedSHA256"]
           for patch in patches):
        raise ACEContractError("ACE patched source inventory differs", "configuration")
    return manifest


def _open_exact(path: Path, *, directory: bool = False) -> int:
    """Walk from the filesystem root with no symlink following at any component."""
    if not path.is_absolute():
        raise ACEContractError("ACE admitted path is not absolute", "configuration")
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for index, part in enumerate(path.parts[1:]):
            last = index == len(path.parts) - 2
            flags = os.O_RDONLY | os.O_NOFOLLOW
            if not last or directory:
                flags |= os.O_DIRECTORY
            next_fd = os.open(part, flags, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        return fd
    except BaseException:
        os.close(fd)
        raise


def _identity(path: Path) -> tuple[int, int, int, int, int, int]:
    """Open and fstat the exact file or directory without following links."""
    fd = _open_exact(path)
    try:
        value = os.fstat(fd)
        if not (stat.S_ISREG(value.st_mode) or stat.S_ISDIR(value.st_mode)):
            raise ACEContractError("ACE admitted path changed type", "configuration")
        return (value.st_dev, value.st_ino, value.st_mode, value.st_size,
                value.st_mtime_ns, value.st_ctime_ns)
    finally:
        os.close(fd)


def _link_identity(path: Path) -> tuple[int, int, int, int, int, int]:
    fd = _open_exact(path.parent, directory=True)
    try:
        value = os.stat(path.name, dir_fd=fd, follow_symlinks=False)
        if not stat.S_ISLNK(value.st_mode):
            raise ACEContractError("ACE private weight view is no longer a link", "configuration")
        return (value.st_dev, value.st_ino, value.st_mode, value.st_size,
                value.st_mtime_ns, value.st_ctime_ns)
    finally:
        os.close(fd)


@dataclass(frozen=True)
class VerificationRecord:
    manifest_bytes: bytes
    paths: tuple[tuple[Path, tuple[int, int, int, int, int, int]], ...]
    manifest_path: Path
    model_root: Path
    vendor_root: Path
    view_root: Path | None = None

    def check(self, manifest: dict[str, Any], *, manifest_path: Path | None = None,
              model: Path | None = None, vendor: Path | None = None,
              view: Path | None = None) -> None:
        if ((manifest_path is not None and manifest_path != self.manifest_path)
                or (model is not None and model != self.model_root)
                or (vendor is not None and vendor != self.vendor_root)
                or (view is not None and self.view_root is not None and view != self.view_root)):
            raise ACEContractError("ACE verification record belongs to another job location", "configuration")
        try:
            current_manifest = json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode()
        except (TypeError, ValueError) as exc:
            raise ACEContractError("ACE manifest changed after admission", "configuration") from exc
        if current_manifest != self.manifest_bytes:
            raise ACEContractError("ACE manifest changed after admission", "configuration")
        for path, identity in self.paths:
            try:
                observed = (_link_identity(path) if stat.S_ISLNK(identity[2])
                            else _identity(path))
                # Directory contents change when an unrelated sibling is created.
                # Keep the ancestor itself pinned, while files and view links retain
                # their complete metadata snapshot.
                same = ((observed[:2] == identity[:2]
                         and stat.S_IFMT(observed[2]) == stat.S_IFMT(identity[2]))
                        if stat.S_ISDIR(identity[2]) else observed == identity)
                if not same:
                    raise ACEContractError(f"ACE admitted identity changed: {path}", "configuration")
            except OSError as exc:
                raise ACEContractError(f"ACE admitted path changed: {path}", "configuration") from exc
        declared_source = {item["path"] for item in manifest["sourceFiles"]}
        observed_source = set()
        for path in self.vendor_root.rglob("*"):
            if path.is_symlink():
                raise ACEContractError("ACE source tree contains a symbolic link", "configuration")
            if path.is_file():
                observed_source.add(path.relative_to(self.vendor_root).as_posix())
        if observed_source != declared_source:
            raise ACEContractError("ACE source tree differs from pinned inventory", "configuration")

    def with_view(self, view: Path) -> "VerificationRecord":
        original = dict(self.paths)
        paths = set(original)
        for item in (view, *view.rglob("*")):
            path = item
            while path != path.parent:
                paths.add(path)
                path = path.parent
        snapshot = []
        for path in sorted(paths):
            if path in original:
                identity = original[path]
            elif path.is_symlink():
                identity = _link_identity(path)
            else:
                identity = _identity(path)
            snapshot.append((path, identity))
        return VerificationRecord(self.manifest_bytes, tuple(snapshot),
                                  self.manifest_path, self.model_root, self.vendor_root, view)


def capture_verified_record(manifest: dict[str, Any], manifest_path: Path,
                            model: Path, vendor: Path) -> VerificationRecord:
    """Pin identities before complete model and source hashing begins."""
    paths = [manifest_path, model, vendor]
    paths += [model / item["path"] for item in manifest["files"]]
    paths += [vendor / item["path"] for item in manifest["sourceFiles"]]
    expanded: set[Path] = set()
    for path in paths:
        while path != path.parent:
            expanded.add(path)
            path = path.parent
    try:
        snapshot = tuple((path, _identity(path)) for path in sorted(expanded))
    except OSError as exc:
        raise ACEContractError("ACE admitted path cannot be opened safely", "configuration") from exc
    return VerificationRecord(json.dumps(manifest, sort_keys=True,
                              separators=(",", ":")).encode(), snapshot,
                              manifest_path, model, vendor)


def verify_manifest_files(manifest: dict[str, Any], root: Path) -> None:
    index_path = root / XL_ROOT / "model.safetensors.index.json"
    index_entry = next(item for item in manifest["files"] if item["path"] == XL_ROOT + "model.safetensors.index.json")
    if (index_path.is_symlink() or not index_path.is_file()
            or index_entry["size"] > MAX_MANIFEST_BYTES
            or index_path.stat().st_size != index_entry["size"]):
        raise ACEContractError("ACE XL shard index is missing or changed", "configuration")
    if hashlib.sha256(index_path.read_bytes()).hexdigest() != index_entry["sha256"]:
        raise ACEContractError("ACE XL shard index digest changed", "configuration")
    try:
        index = json.loads(index_path.read_text(), object_pairs_hook=_unique_pairs)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ACEContractError("ACE XL shard index is invalid", "configuration") from exc
    weight_map = exact(index, {"metadata", "weight_map"}, label="ACE XL shard index")["weight_map"]
    if not isinstance(weight_map, dict) or not weight_map:
        raise ACEContractError("ACE XL shard map is empty", "configuration")
    names = tuple(weight_map.values())
    if (any(not isinstance(name, str) or Path(name).name != name or "\\" in name
            or not name.endswith(".safetensors") or name in (".", "..") for name in names)
            or not names
            or set(names) != XL_SHARDS
            or {XL_ROOT + name for name in names} != {
                item["path"] for item in manifest["files"]
                if item["role"] == "xl" and item["path"].endswith(".safetensors")
            }):
        raise ACEContractError("ACE XL shard references differ from admitted files", "configuration")
    for item in manifest["files"]:
        path = root / item["path"]
        parent = root
        for part in Path(item["path"]).parts[:-1]:
            parent = parent / part
            if parent.is_symlink():
                raise ACEContractError(f"ACE resource path contains a link: {item['path']}", "configuration")
        if path.is_symlink() or not path.is_file() or path.stat().st_size != item["size"]:
            raise ACEContractError(f"ACE resource missing or size changed: {item['path']}", "configuration")
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        if digest.hexdigest() != item["sha256"]:
            raise ACEContractError(f"ACE resource digest changed: {item['path']}", "configuration")


def verify_source_files(manifest: dict[str, Any], vendor: Path) -> None:
    declared = {item["path"] for item in manifest["sourceFiles"]}
    observed = set()
    for path in vendor.rglob("*"):
        if path.is_symlink():
            raise ACEContractError("ACE source tree contains a symbolic link", "configuration")
        if path.is_file():
            observed.add(path.relative_to(vendor).as_posix())
    if observed != declared:
        raise ACEContractError("ACE source tree differs from pinned inventory", "configuration")
    for item in manifest["sourceFiles"]:
        path = vendor / item["path"]
        if path.is_symlink() or not path.is_file() or path.stat().st_size != item["size"]:
            raise ACEContractError(f"ACE source missing or size changed: {item['path']}", "configuration")
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        if digest.hexdigest() != item["sha256"]:
            raise ACEContractError(f"ACE source digest changed: {item['path']}", "configuration")


def verify_wav(ref: dict[str, Any]) -> None:
    path = reference_path(ref)
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 512 * 1024 * 1024:
        raise ACEContractError("ACE frozen WAV is absent or oversized")
    raw = path.read_bytes()
    if hashlib.sha256(raw).hexdigest() != ref["sha256"]:
        raise ACEContractError("ACE frozen WAV digest changed")
    if len(raw) < 44 or raw[:4] != b"RIFF" or raw[8:12] != b"WAVE" or struct.unpack_from("<I", raw, 4)[0] + 8 != len(raw):
        raise ACEContractError("ACE frozen WAV container is invalid")
    offset, fmt, frame_bytes, sample_start = 12, None, None, None
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
            sample_start = body
        offset = body + size + (size & 1)
    if offset != len(raw) or fmt is None or frame_bytes is None:
        raise ACEContractError("ACE WAV is incomplete")
    code, channels, rate, byte_rate, align, bits = fmt
    if ((code, bits) not in ((3, 32), (1, 16), (1, 24), (1, 32))
            or channels != 2 or rate != 48000 or align != 2 * bits // 8
            or byte_rate != rate * align or frame_bytes % align
            or frame_bytes // align != ref["frameCount"]):
        raise ACEContractError("ACE WAV format or frame count changed")
    if code == 3:
        for position in range(sample_start, sample_start + frame_bytes, 4):
            sample = struct.unpack_from("<f", raw, position)[0]
            if not math.isfinite(sample) or not -1 <= sample <= 1:
                raise ACEContractError("ACE WAV contains a nonfinite or out-of-range sample")
