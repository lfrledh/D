"""Read-only verification for pinned local video adapter resources.

No downloader, model import, inference, permission prompt or writable cache. The
caller supplies a trusted, reviewed inventory, not an inventory embedded in an
untrusted model directory. A matching hash proves file identity, not numerical
parity, licence eligibility or that the model fits the current machine.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import struct


class ResourceError(ValueError):
    pass


def _unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ResourceError(f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def _name(value):
    if not isinstance(value, str) or not value or "\\" in value or "\0" in value:
        raise ResourceError("Invalid resource path")
    p = PurePosixPath(value)
    if p.is_absolute() or any(x in (".", "..", "") for x in value.split("/")):
        raise ResourceError("Resource path must stay inside the explicit model root")
    return p.parts


def _open_regular(root_fd, name):
    parts = _name(name)
    parent = os.dup(root_fd)
    try:
        for part in parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
            os.close(parent)
            parent = child
        fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            os.close(fd)
            raise ResourceError(f"Not a regular resource: {name}")
        return os.fdopen(fd, "rb")
    finally:
        os.close(parent)


def inspect_safetensors(file, *, allow_quantized=False):
    """Bounded header inspection; never maps tensor data or creates MLX arrays."""
    file.seek(0)
    raw = file.read(8)
    if len(raw) != 8:
        raise ResourceError("Truncated safetensors header length")
    length = struct.unpack("<Q", raw)[0]
    total = os.fstat(file.fileno()).st_size
    if not 2 <= length <= 64 * 1024 * 1024 or length + 8 > total:
        raise ResourceError("Invalid or over-budget safetensors header")
    header = json.loads(file.read(length), object_pairs_hook=_unique)
    if not isinstance(header, dict):
        raise ResourceError("Safetensors header must be an object")
    sizes = {"BF16": 2, "F16": 2, "F32": 4, "F64": 8,
             "I8": 1, "U8": 1, "I16": 2, "U16": 2, "I32": 4,
             "U32": 4, "I64": 8, "U64": 8, "BOOL": 1}
    dtypes, regions, count = {}, [], 0
    for name, tensor in header.items():
        if name == "__metadata__":
            if not isinstance(tensor, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in tensor.items()):
                raise ResourceError("Invalid safetensors metadata")
            continue
        if not isinstance(tensor, dict) or set(tensor) != {"dtype", "shape", "data_offsets"}:
            raise ResourceError("Malformed tensor entry")
        dtype, shape, offsets = tensor["dtype"], tensor["shape"], tensor["data_offsets"]
        if not isinstance(dtype, str) or dtype not in sizes or not isinstance(shape, list) or len(shape) > 16:
            raise ResourceError("Invalid tensor dtype/shape")
        if any(type(n) is not int or not 0 <= n <= 2**63 - 1 for n in shape):
            raise ResourceError("Invalid tensor dimension")
        if not isinstance(offsets, list) or len(offsets) != 2 or any(type(n) is not int for n in offsets):
            raise ResourceError("Invalid tensor offsets")
        start, end = offsets
        elements = 1
        for n in shape:
            elements *= n
        if not 0 <= start <= end <= total - length - 8 or end - start != elements * sizes[dtype]:
            raise ResourceError("Tensor range does not match its shape/dtype/file")
        if not allow_quantized and (dtype not in {"BF16", "F16", "F32", "F64"}
                                    or name.endswith((".scales", ".qweight", ".qzeros"))):
            raise ResourceError("Full precision profile contains packed/non-floating or quantized tensors")
        if end > start:
            regions.append((start, end))
        dtypes[dtype] = dtypes.get(dtype, 0) + 1
        count += 1
    if not count:
        raise ResourceError("No tensors")
    previous = 0
    for start, end in sorted(regions):
        if start != previous:
            raise ResourceError("Overlapping or non-contiguous tensor ranges")
        previous = end
    if previous != total - length - 8:
        raise ResourceError("Unaccounted tensor payload")
    return {"tensors": count, "dtypes": dtypes}


def verify_inventory(root, inventory):
    """Hash every required file through no-follow descriptors; preserve originals."""
    root = Path(root)
    if not root.is_absolute():
        raise ResourceError("Model root must be absolute")
    if type(inventory.get("schema_version")) is not int or inventory["schema_version"] != 1:
        raise ResourceError("Unsupported inventory schema")
    if not isinstance(inventory.get("profile"), str) or not inventory["profile"]:
        raise ResourceError("Missing inventory profile")
    entries = inventory.get("files")
    if not isinstance(entries, list) or not entries or len(entries) > 10000:
        raise ResourceError("Invalid inventory files")
    names = set()
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {"name", "size", "sha256", "tensor_policy"}:
            raise ResourceError("Invalid file inventory entry")
        _name(entry["name"])
        if entry["name"] in names or type(entry["size"]) is not int or entry["size"] <= 0:
            raise ResourceError("Duplicate resource or invalid size")
        names.add(entry["name"])
        if not isinstance(entry["sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", entry["sha256"]):
            raise ResourceError("Invalid SHA256")
        if entry["tensor_policy"] not in {"not_tensor", "floating_only", "quantized_explicit"}:
            raise ResourceError("Unknown tensor policy")
    root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    verified = []
    try:
        for entry in entries:
            with _open_regular(root_fd, entry["name"]) as file:
                before = os.fstat(file.fileno())
                if before.st_size != entry["size"]:
                    raise ResourceError(f"Size mismatch: {entry['name']}")
                digest = hashlib.sha256()
                for chunk in iter(lambda: file.read(4 * 1024 * 1024), b""):
                    digest.update(chunk)
                if digest.hexdigest() != entry["sha256"]:
                    raise ResourceError(f"Hash mismatch: {entry['name']}")
                tensors = None
                if entry["tensor_policy"] != "not_tensor":
                    tensors = inspect_safetensors(file, allow_quantized=entry["tensor_policy"] == "quantized_explicit")
                after = os.fstat(file.fileno())
                if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns):
                    raise ResourceError("Resource changed during verification")
                verified.append({"name": entry["name"], "sha256": digest.hexdigest(), "tensor_header": tensors})
    finally:
        os.close(root_fd)
    return {"schema_version": 1, "profile": inventory["profile"], "verified_files": verified,
            "scope": "listed-file-identity-and-header-only", "inference_verified": False}
