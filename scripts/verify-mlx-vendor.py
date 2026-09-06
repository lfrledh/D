#!/usr/bin/env python3
"""Verify D's MLX source snapshot and patch metadata without network access or writes."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys


ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / "Vendor"


def relative_path(value):
    if not isinstance(value, str):
        raise ValueError("Snapshot paths must be strings.")
    path = PurePosixPath(value)
    if not value or path.is_absolute() or ".." in path.parts or str(path) != value:
        raise ValueError(f"Invalid snapshot path: {value!r}")
    return path


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def regular_bytes(path):
    if not stat.S_ISREG(path.lstat().st_mode):
        raise ValueError(f"Expected a regular file: {path}")
    return path.read_bytes()


def verify(snapshot):
    provenance = json.loads(regular_bytes(VENDOR / "mlx-swift.provenance.json"))
    if provenance.get("schemaVersion") != 1 or provenance.get("packageIdentity") != "mlx-swift":
        raise ValueError("Unsupported MLX provenance schema or package identity.")
    snapshot_metadata = provenance["snapshot"]
    manifest_path = VENDOR / relative_path(snapshot_metadata["manifest"])
    manifest_data = regular_bytes(manifest_path)
    if sha256(manifest_data) != snapshot_metadata["manifestSHA256"]:
        raise ValueError("MLX file manifest hash mismatch.")
    manifest = json.loads(manifest_data)
    if manifest.get("schemaVersion") != 1 or manifest.get("algorithm") != "sha256":
        raise ValueError("Unsupported MLX file manifest schema.")
    patch = provenance["patch"]
    if sha256(regular_bytes(VENDOR / relative_path(patch["file"]))) != patch["sha256"]:
        raise ValueError("MLX ownership patch hash mismatch.")

    expected = {}
    directories = set()
    for entry in manifest["files"]:
        path = relative_path(entry["path"])
        if str(path) in expected:
            raise ValueError(f"Duplicate source path: {path}")
        if entry.get("gitMode") not in ("100644", "100755"):
            raise ValueError(f"Unsupported source file type/mode: {path}")
        for field in ("sha256", "upstreamSHA256"):
            if not re.fullmatch(r"[0-9a-f]{64}", entry[field]):
                raise ValueError(f"Invalid {field}: {path}")
        for field in ("size", "upstreamSize"):
            if type(entry[field]) is not int or entry[field] < 0:
                raise ValueError(f"Invalid {field}: {path}")
        expected[str(path)] = entry
        directories.update(str(parent) for parent in path.parents if str(parent) != ".")

    if len(expected) != snapshot_metadata["fileCount"]:
        raise ValueError("Source count differs from provenance.")
    if sum(entry["size"] for entry in expected.values()) != snapshot_metadata["patchedBytes"]:
        raise ValueError("Patched source byte count differs from provenance.")
    if sum(entry["upstreamSize"] for entry in expected.values()) != snapshot_metadata["upstreamBytes"]:
        raise ValueError("Upstream source byte count differs from provenance.")
    changed = {path for path, entry in expected.items() if entry["sha256"] != entry["upstreamSHA256"]}
    declared_changes = patch["modifiedFiles"]
    if changed != {entry["path"] for entry in declared_changes}:
        raise ValueError("Declared patch scope differs from the complete source manifest.")
    for change in declared_changes:
        if any(expected[change["path"]][key] != value for key, value in change.items()):
            raise ValueError(f"Patch before/after metadata mismatch: {change['path']}")

    if not snapshot.is_dir():
        raise ValueError(f"MLX snapshot directory does not exist: {snapshot}")
    errors = []
    seen = set()
    ignored = []
    pending = [snapshot]
    while pending:
        directory = pending.pop()
        with os.scandir(directory) as children:
            for child in children:
                path = Path(child.path)
                relative = path.relative_to(snapshot).as_posix()
                # SwiftPM/Xcode create these outside the upstream source inventory. Do not
                # descend into their dependency caches or follow their local symlinks.
                if directory == snapshot and child.name in (".build", ".swiftpm"):
                    ignored.append(relative)
                    continue
                metadata = child.stat(follow_symlinks=False)
                if child.name == ".DS_Store" and stat.S_ISREG(metadata.st_mode):
                    ignored.append(relative)
                    continue
                if stat.S_ISDIR(metadata.st_mode):
                    if relative not in directories:
                        errors.append(f"Unexpected source directory: {relative}")
                    else:
                        pending.append(path)
                    continue
                if not stat.S_ISREG(metadata.st_mode):
                    errors.append(f"Non-regular source entry: {relative}")
                    continue
                entry = expected.get(relative)
                if entry is None:
                    errors.append(f"Unexpected source file: {relative}")
                    continue
                seen.add(relative)
                if metadata.st_size != entry["size"]:
                    errors.append(f"Source size mismatch: {relative}")
                    continue
                if bool(metadata.st_mode & 0o111) != (entry["gitMode"] == "100755"):
                    errors.append(f"Source executable mode mismatch: {relative}")
                digest = hashlib.sha256()
                with path.open("rb") as source:
                    for block in iter(lambda: source.read(1024 * 1024), b""):
                        digest.update(block)
                if digest.hexdigest() != entry["sha256"]:
                    errors.append(f"Source hash mismatch: {relative}")
    errors.extend(f"Missing source file: {path}" for path in sorted(set(expected) - seen))
    if errors:
        excerpt = "\n".join(errors[:25])
        if len(errors) > 25:
            excerpt += f"\n... and {len(errors) - 25} more verification errors."
        raise ValueError(excerpt)
    print(f"Verified MLX vendor: {len(expected)} source files, {snapshot_metadata['patchedBytes']:,} bytes, "
          f"{len(changed)} patched files; {len(ignored)} local artifacts ignored.", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vendor", type=Path, default=VENDOR / "mlx-swift",
                        help="Snapshot directory to compare with D's committed manifest (default: Vendor/mlx-swift).")
    args = parser.parse_args()
    try:
        verify(args.vendor.expanduser().resolve())
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"MLX vendor verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
