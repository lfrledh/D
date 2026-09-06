#!/usr/bin/env python3
"""Download or verify D's pinned text validation fixture using only the standard library."""

import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request


PROJECT_ROOT = Path(__file__).resolve().parent.parent
MANIFEST_PATH = PROJECT_ROOT / "fixtures" / "text-model.json"
CHUNK_BYTES = 1024 * 1024
PROVENANCE_NAME = ".provenance.json"
LOCK_NAME = ".download.lock"


def status(message):
    print(message, file=sys.stderr, flush=True)


def load_manifest():
    raw = MANIFEST_PATH.read_bytes()
    manifest = json.loads(raw)
    if manifest.get("schemaVersion") != 1:
        raise ValueError("Unsupported fixture manifest version.")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", manifest["repository"]):
        raise ValueError("Invalid fixture repository.")
    if not re.fullmatch(r"[0-9a-f]{40}", manifest["revision"]):
        raise ValueError("Fixture revision must be a full commit SHA.")
    names = set()
    for entry in manifest["files"]:
        name = entry["name"]
        if not re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9_.-]*", name) or name in names:
            raise ValueError("Fixture filenames must be unique, plain filenames.")
        names.add(name)
        if type(entry["size"]) is not int or entry["size"] <= 0:
            raise ValueError(f"Invalid size for {name}.")
        length = {"sha256": 64, "git-blob-sha1": 40}.get(entry["algorithm"])
        if length is None or not re.fullmatch(r"[0-9a-f]{%d}" % length, entry["checksum"]):
            raise ValueError(f"Invalid checksum for {name}.")
    if not names:
        raise ValueError("Fixture manifest contains no files.")
    directory_name = manifest["directoryName"]
    if not re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9_.-]*", directory_name):
        raise ValueError("Invalid fixture directory name.")
    return manifest, hashlib.sha256(raw).hexdigest()


def verify_file(path, entry):
    """Git blob IDs hash the object header as well as the file's contents."""
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode):
        raise ValueError(f"{entry['name']}: expected a regular file, not a symlink.")
    if metadata.st_size != entry["size"]:
        raise ValueError(f"{entry['name']}: size {metadata.st_size}, expected {entry['size']}.")
    if entry["algorithm"] == "git-blob-sha1":
        digest = hashlib.sha1()
        digest.update(f"blob {entry['size']}\0".encode("ascii"))
    else:
        digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(CHUNK_BYTES), b""):
            digest.update(block)
    if digest.hexdigest() != entry["checksum"]:
        raise ValueError(f"{entry['name']}: checksum mismatch.")


def verify_directory_entries(destination, manifest):
    """MLX discovers weights recursively, so unlisted files can change this fixture."""
    names = {entry["name"] for entry in manifest["files"]}
    allowed = names | {PROVENANCE_NAME, LOCK_NAME}
    temporary_bases = "|".join(re.escape(name) for name in sorted(names | {"provenance"}))
    known_partial = re.compile(r"\.(?:" + temporary_bases + r")\.[A-Za-z0-9_-]{8}\.partial")
    ignored_partials = []
    for path in destination.iterdir():
        if not stat.S_ISREG(path.lstat().st_mode):
            raise ValueError(f"Unexpected fixture entry {path.name!r}: directories, symlinks, and special files are not allowed.")
        if path.name in allowed:
            continue
        if known_partial.fullmatch(path.name):
            # A killed download may leave a non-loadable temporary file. Preserve it;
            # accepting arbitrary *.partial names or directories would widen this exception.
            ignored_partials.append(path.name)
            continue
        raise ValueError(f"Unlisted fixture entry {path.name!r}. Move it outside the fixture directory; no files were deleted.")
    if ignored_partials:
        status("Preserving incomplete downloader temporary files: " + ", ".join(sorted(ignored_partials)))


def download_file(destination, manifest, entry):
    name = entry["name"]
    url = (
        "https://huggingface.co/" + manifest["repository"] + "/resolve/"
        + manifest["revision"] + "/" + urllib.parse.quote(name, safe="")
    )
    request = urllib.request.Request(url, headers={
        "User-Agent": "D-validation-fixture/1",
        "Accept-Encoding": "identity",
    })
    for attempt in range(1, 4):
        temporary_path = None
        try:
            status(f"Downloading {name} ({entry['size']:,} bytes), attempt {attempt}/3")
            fd, temporary_name = tempfile.mkstemp(prefix=f".{name}.", suffix=".partial", dir=destination)
            temporary_path = Path(temporary_name)
            with os.fdopen(fd, "wb") as output:
                with urllib.request.urlopen(request, timeout=60) as response:
                    received = 0
                    reported_at = time.monotonic()
                    while True:
                        block = response.read(CHUNK_BYTES)
                        if not block:
                            break
                        received += len(block)
                        if received > entry["size"]:
                            raise ValueError(f"{name}: server returned more bytes than the fixture permits.")
                        output.write(block)
                        if time.monotonic() - reported_at >= 5:
                            status(f"  {name}: {received:,}/{entry['size']:,} bytes")
                            reported_at = time.monotonic()
                output.flush()
                os.fsync(output.fileno())
            verify_file(temporary_path, entry)
            os.replace(temporary_path, destination / name)
            status(f"Verified {name}")
            return
        except (OSError, ValueError, urllib.error.URLError) as error:
            status(f"  {name}: attempt {attempt} failed: {error}")
            if attempt == 3:
                raise RuntimeError(f"Could not download and verify {name}.") from error
            time.sleep(attempt)
        finally:
            if temporary_path is not None:
                temporary_path.unlink(missing_ok=True)


def write_provenance(destination, manifest, manifest_digest):
    provenance = {
        "schemaVersion": 1,
        "repository": manifest["repository"],
        "revision": manifest["revision"],
        "source": manifest["source"],
        "manifestSHA256": manifest_digest,
        "verifiedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "totalBytes": sum(entry["size"] for entry in manifest["files"]),
        "files": manifest["files"],
    }
    fd, temporary_name = tempfile.mkstemp(prefix=".provenance.", suffix=".partial", dir=destination)
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            json.dump(provenance, output, indent=2)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary_path, destination / PROVENANCE_NAME)
    finally:
        temporary_path.unlink(missing_ok=True)


def verify_provenance(destination, manifest, manifest_digest):
    path = destination / PROVENANCE_NAME
    if not stat.S_ISREG(path.lstat().st_mode):
        raise ValueError("Fixture provenance must be a regular file.")
    provenance = json.loads(path.read_text(encoding="utf-8"))
    expected = {
        "schemaVersion": 1,
        "repository": manifest["repository"],
        "revision": manifest["revision"],
        "manifestSHA256": manifest_digest,
        "totalBytes": sum(entry["size"] for entry in manifest["files"]),
        "files": manifest["files"],
    }
    if any(provenance.get(key) != value for key, value in expected.items()):
        raise ValueError("Fixture provenance does not match the pinned manifest.")


def main():
    parser = argparse.ArgumentParser(
        description="Download D's pinned Qwen2.5-0.5B-Instruct-4bit validation model; verify every file's size and hash.",
        epilog="Uses Python's standard library only; does not execute model code. Status goes to stderr; stdout contains only the verified absolute directory.",
    )
    parser.add_argument("--destination", type=Path, metavar="PATH",
                        help="Model directory (default: ../D-Development/Models/Qwen2.5-0.5B-Instruct-4bit beside the project).")
    parser.add_argument("--verify-only", action="store_true",
                        help="Verify existing files and provenance without network access or rewriting them (uses a local advisory lock).")
    args = parser.parse_args()
    manifest, manifest_digest = load_manifest()
    destination = (args.destination or PROJECT_ROOT.parent / "D-Development" / "Models" / manifest["directoryName"]).expanduser().resolve()
    if args.verify_only:
        if not destination.is_dir():
            raise ValueError(f"Model directory does not exist: {destination}")
    else:
        # Fixture weights always remain outside the source repository.
        if destination == PROJECT_ROOT or PROJECT_ROOT in destination.parents:
            raise ValueError("Choose a model destination outside the source repository.")
        destination.mkdir(parents=True, exist_ok=True)
    verify_directory_entries(destination, manifest)
    # Do not follow a lock symlink that appeared after the directory check.
    lock_fd = os.open(destination / LOCK_NAME, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(lock_fd, "a+b") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            status("Waiting for another fixture download/verification to finish...")
            fcntl.flock(lock, fcntl.LOCK_EX)
        verify_directory_entries(destination, manifest)
        for entry in manifest["files"]:
            try:
                verify_file(destination / entry["name"], entry)
                status(f"Verified existing {entry['name']}")
            except (OSError, ValueError):
                if args.verify_only:
                    raise
                download_file(destination, manifest, entry)
        if args.verify_only:
            verify_provenance(destination, manifest, manifest_digest)
        else:
            write_provenance(destination, manifest, manifest_digest)
        verify_directory_entries(destination, manifest)
        total_bytes = sum(entry["size"] for entry in manifest["files"])
        status(f"Verified {len(manifest['files'])} files, {total_bytes:,} bytes, revision {manifest['revision']}.")
    print(destination, flush=True)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        status("Interrupted; any incomplete temporary download was removed.")
        sys.exit(130)
    except (OSError, ValueError, KeyError, TypeError, RuntimeError) as error:
        status(f"Error: {error}")
        sys.exit(1)
