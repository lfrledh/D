#!/usr/bin/env python3
"""Verify the complete pinned Flux2 source tree and three reversible patches offline."""

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
    if not isinstance(value, str) or not value or "\\" in value:
        raise ValueError("Invalid snapshot path")
    if any(part in ("", ".", "..", ".git") for part in value.split("/")):
        raise ValueError(f"Unsafe snapshot path: {value!r}")
    path = PurePosixPath(value)
    if path.is_absolute() or str(path) != value:
        raise ValueError(f"Invalid snapshot path: {value!r}")
    return path


def regular_bytes(path):
    for candidate in [path, *path.parents]:
        if candidate.is_symlink():
            raise ValueError(f"Symlink is not a source file: {candidate}")
    if not stat.S_ISREG(path.lstat().st_mode):
        raise ValueError(f"Expected regular file: {path}")
    return path.read_bytes()


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def git_hash(kind, data):
    return hashlib.sha1(f"{kind} {len(data)}\0".encode() + data).hexdigest()


def parse_patch(data):
    """Read the generated unified format, rejecting unparsed or ambiguous content."""
    lines = data.decode("utf-8").splitlines(keepends=True)
    result = {}
    index = 0
    while index < len(lines):
        header = re.fullmatch(r"diff --git a/(.+) b/(.+)\n", lines[index])
        if not header or header[1] != header[2]:
            raise ValueError("Unsupported patch file header")
        path = str(relative_path(header[1]))
        if path in result:
            raise ValueError("Duplicate patched path")
        if lines[index + 1:index + 3] != [f"--- a/{path}\n", f"+++ b/{path}\n"]:
            raise ValueError("Patch file labels do not match")
        index += 3
        hunks = []
        while index < len(lines) and not lines[index].startswith("diff --git "):
            header = re.fullmatch(r"@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@[^\n]*\n", lines[index])
            if not header:
                raise ValueError("Invalid patch hunk")
            old_start, old_count = int(header[1]), int(header[2] or 1)
            new_start, new_count = int(header[3]), int(header[4] or 1)
            index += 1
            old_lines, new_lines = [], []
            while index < len(lines) and not lines[index].startswith(("@@ ", "diff --git ")):
                line = lines[index]
                if line[0] not in " +-":
                    raise ValueError("Unsupported patch body")
                if line[0] in " -":
                    old_lines.append(line[1:])
                if line[0] in " +":
                    new_lines.append(line[1:])
                index += 1
            if len(old_lines) != old_count or len(new_lines) != new_count:
                raise ValueError("Patch hunk count mismatch")
            hunks.append((old_start, old_count, new_start, new_count, old_lines, new_lines))
        if not hunks:
            raise ValueError("Patch has no hunks")
        result[path] = hunks
    if not result:
        raise ValueError("Patch has no files")
    return result


def reverse_patch(data, hunks):
    lines = data.decode("utf-8").splitlines(keepends=True)
    restored = []
    cursor = 0
    for old_start, old_count, new_start, new_count, old_lines, new_lines in hunks:
        position = new_start - 1 if new_count else new_start
        old_position = old_start - 1 if old_count else old_start
        if position < cursor or lines[position:position + new_count] != new_lines:
            raise ValueError("Patch does not match patched source exactly")
        restored.extend(lines[cursor:position])
        if len(restored) != old_position:
            raise ValueError("Patch old/new offsets do not match")
        restored.extend(old_lines)
        cursor = position + new_count
    restored.extend(lines[cursor:])
    return "".join(restored).encode("utf-8")


def tree_hash(entries):
    tree = {}
    for entry in entries:
        parts = entry["path"].split("/")
        directory = tree
        for part in parts[:-1]:
            directory = directory.setdefault(part, {})
        if parts[-1] in directory:
            raise ValueError("Duplicate Git tree entry")
        directory[parts[-1]] = (entry["gitMode"], entry["upstreamGitBlob"])

    def encode(directory):
        payload = bytearray()
        for name, value in sorted(directory.items(), key=lambda pair: (pair[0] + ("/" if isinstance(pair[1], dict) else "")).encode()):
            mode, oid = ("40000", encode(value)) if isinstance(value, dict) else value
            payload.extend(f"{mode} {name}\0".encode() + bytes.fromhex(oid))
        return git_hash("tree", bytes(payload))

    return encode(tree)


def verify(snapshot):
    provenance = json.loads(regular_bytes(VENDOR / "flux2-swift.provenance.json"))
    if provenance.get("schemaVersion") != 1 or provenance.get("packageIdentity") != "flux2-swift":
        raise ValueError("Unsupported Flux2 provenance")
    repository = provenance["repository"]
    commit = repository["commitText"].encode()
    if git_hash("commit", commit) != repository["revision"]:
        raise ValueError("Recorded upstream commit does not match its revision")
    if commit.splitlines()[0] != f"tree {repository['tree']}".encode():
        raise ValueError("Upstream commit tree mismatch")
    metadata = provenance["snapshot"]
    manifest_data = regular_bytes(VENDOR / relative_path(metadata["manifest"]))
    if sha256(manifest_data) != metadata["manifestSHA256"]:
        raise ValueError("Source manifest checksum mismatch")
    manifest = json.loads(manifest_data)
    if manifest.get("schemaVersion") != 1 or manifest.get("algorithm") != "sha256":
        raise ValueError("Unsupported source manifest")
    expected = {}
    directories = set()
    for entry in manifest["files"]:
        path = str(relative_path(entry["path"]))
        if path in expected or entry["gitMode"] not in ("100644", "100755"):
            raise ValueError("Duplicate source path or unsupported Git mode")
        for key in ("size", "upstreamSize"):
            if type(entry[key]) is not int or entry[key] < 0:
                raise ValueError("Invalid byte count")
        for key, length in (("sha256", 64), ("upstreamSHA256", 64), ("upstreamGitBlob", 40)):
            if not re.fullmatch(r"[0-9a-f]{" + str(length) + "}", entry[key]):
                raise ValueError(f"Invalid {key}")
        expected[path] = entry
        directories.update(str(parent) for parent in PurePosixPath(path).parents if str(parent) != ".")
    if len(expected) != metadata["fileCount"]:
        raise ValueError("Source count mismatch")
    if sum(entry["size"] for entry in expected.values()) != metadata["patchedBytes"]:
        raise ValueError("Patched source bytes mismatch")
    if sum(entry["upstreamSize"] for entry in expected.values()) != metadata["upstreamBytes"]:
        raise ValueError("Upstream source bytes mismatch")
    if tree_hash(expected.values()) != repository["tree"]:
        raise ValueError("Manifest does not reproduce the complete upstream Git tree")
    changes = {name for name, entry in expected.items() if entry["sha256"] != entry["upstreamSHA256"]}
    hunks = {}
    patch_paths = set()
    for patch in provenance["patches"]:
        patch_path = str(relative_path(patch["file"]))
        if patch_path in patch_paths:
            raise ValueError("Duplicate patch")
        patch_paths.add(patch_path)
        data = regular_bytes(VENDOR / patch_path)
        if sha256(data) != patch["sha256"]:
            raise ValueError(f"Patch checksum mismatch: {patch_path}")
        parsed = parse_patch(data)
        declared = {entry["path"] for entry in patch["modifiedFiles"]}
        if declared != set(parsed) or len(declared) != len(patch["modifiedFiles"]):
            raise ValueError("Patch scope differs from provenance")
        for entry in patch["modifiedFiles"]:
            if entry["path"] not in expected or any(expected[entry["path"]].get(key) != value for key, value in entry.items()):
                raise ValueError("Patch before/after metadata mismatch")
        if hunks.keys() & parsed.keys():
            raise ValueError("Overlapping patches are not supported")
        hunks.update(parsed)
    if changes != hunks.keys():
        raise ValueError("Patched source scope differs from complete manifest")
    if snapshot.is_symlink() or not snapshot.is_dir():
        raise ValueError("Expected an ordinary snapshot directory")
    seen = set()
    ignored = []
    pending = [snapshot]
    while pending:
        directory = pending.pop()
        for child in os.scandir(directory):
            path = Path(child.path)
            relative = path.relative_to(snapshot).as_posix()
            status = child.stat(follow_symlinks=False)
            if directory == snapshot and child.name in (".build", ".swiftpm"):
                ignored.append(relative)
                continue
            if child.name == ".DS_Store" and stat.S_ISREG(status.st_mode):
                ignored.append(relative)
                continue
            if stat.S_ISDIR(status.st_mode):
                if relative not in directories:
                    raise ValueError(f"Unexpected source directory: {relative}")
                pending.append(path)
                continue
            if not stat.S_ISREG(status.st_mode) or relative not in expected:
                raise ValueError(f"Unexpected or non-regular source file: {relative}")
            entry = expected[relative]
            if bool(status.st_mode & 0o111) != (entry["gitMode"] == "100755"):
                raise ValueError(f"Executable mode mismatch: {relative}")
            data = regular_bytes(path)
            if len(data) != entry["size"] or sha256(data) != entry["sha256"]:
                raise ValueError(f"Patched source checksum mismatch: {relative}")
            upstream = reverse_patch(data, hunks[relative]) if relative in hunks else data
            if len(upstream) != entry["upstreamSize"] or sha256(upstream) != entry["upstreamSHA256"]:
                raise ValueError(f"Reversed patch does not reproduce upstream: {relative}")
            if git_hash("blob", upstream) != entry["upstreamGitBlob"]:
                raise ValueError(f"Upstream Git blob mismatch: {relative}")
            seen.add(relative)
    if seen != expected.keys():
        raise ValueError(f"Missing source files: {sorted(expected.keys() - seen)}")
    print(f"Verified Flux2 vendor: {len(seen)} files, {metadata['patchedBytes']:,} bytes; "
          f"{len(patch_paths)} patches/{len(changes)} modified files; "
          f"upstream {repository['revision']}; {len(ignored)} local artifacts ignored.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vendor", type=Path, default=VENDOR / "flux2-swift")
    args = parser.parse_args()
    try:
        verify(Path(os.path.abspath(args.vendor.expanduser())))
    except (OSError, ValueError, KeyError, TypeError, IndexError) as error:
        print(f"Flux2 vendor verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
