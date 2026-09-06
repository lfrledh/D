#!/usr/bin/env python3
"""Download pinned Hugging Face data files, or verify them offline.

Python 3.9+, standard library only. No Hugging Face login or remote code execution.
Example: python3 download_model.py --manifest model-manifest.json \
    --destination /path/to/model [--verify-only]

Four connections maximum; 16 MiB exact HTTP ranges; resumable segment files.
Interrupted downloads retain their segments under .d-model-download. A completed
file is published only after its full SHA-256 matches the manifest. Verification
does not create directories, state, or network requests. Use one downloader per
destination at a time. Unknown files are never removed or replaced.
"""

import argparse
import concurrent.futures
import email.utils
import hashlib
import http.client
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

BLOCK = 1024 * 1024
SEGMENT = 16 * 1024 * 1024
STATE = ".d-model-download"


def report(event, **fields):
    print(json.dumps({"event": event, **fields}, sort_keys=True), flush=True)


def safe_path(path):
    """Reject symlinks, including dangling links and links in existing ancestors."""
    path = Path(os.path.abspath(path))
    for candidate in [*reversed(path.parents), path]:
        try:
            mode = candidate.lstat().st_mode
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(mode):
            raise ValueError(f"Refusing symlink: {candidate}")
    return path


def regular_open(path, mode):
    path = safe_path(path)
    if path.exists() and not stat.S_ISREG(path.lstat().st_mode):
        raise ValueError(f"Refusing non-regular file: {path}")
    flags = {"rb": os.O_RDONLY, "ab": os.O_WRONLY | os.O_CREAT | os.O_APPEND,
             "wb": os.O_WRONLY | os.O_CREAT | os.O_TRUNC}[mode]
    # O_NONBLOCK prevents an unexpected FIFO from blocking before fstat rejects it.
    descriptor = os.open(path, flags | getattr(os, "O_NOFOLLOW", 0)
                         | getattr(os, "O_NONBLOCK", 0), 0o644)
    if not stat.S_ISREG(os.fstat(descriptor).st_mode):
        os.close(descriptor)
        raise ValueError(f"Refusing non-regular file: {path}")
    return os.fdopen(descriptor, mode)


def read_manifest(path):
    with regular_open(path, "rb") as file:
        manifest = json.load(file)
    if set(manifest) != {"schemaVersion", "repository", "revision", "files"}:
        raise ValueError("Unexpected manifest fields")
    if type(manifest["schemaVersion"]) is not int or manifest["schemaVersion"] != 1:
        raise ValueError("Unsupported manifest version")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*",
                        manifest["repository"]):
        raise ValueError("Invalid repository")
    if not re.fullmatch(r"[0-9a-f]{40}", manifest["revision"]):
        raise ValueError("Revision must be a full immutable commit SHA")
    if not isinstance(manifest["files"], list) or not manifest["files"]:
        raise ValueError("Manifest must contain files")
    paths = set()
    for entry in manifest["files"]:
        if set(entry) != {"path", "size", "sha256"}:
            raise ValueError("Unexpected file entry fields")
        name = entry["path"]
        if not isinstance(name, str) or not name or "\\" in name:
            raise ValueError("Invalid relative file path")
        parts = name.split("/")
        if any(p in ("", ".", "..", STATE) for p in parts):
            raise ValueError("Unsafe or reserved file path")
        if any(ord(c) < 32 or ord(c) == 127 for c in name):
            raise ValueError("Control character in file path")
        if PurePosixPath(name).is_absolute() or name in paths:
            raise ValueError("Absolute or duplicate file path")
        if type(entry["size"]) is not int or entry["size"] <= 0:
            raise ValueError("File size must be a positive integer")
        if not re.fullmatch(r"[0-9a-f]{64}", entry["sha256"]):
            raise ValueError("Invalid SHA-256")
        paths.add(name)
    if any(str(parent) in paths for name in paths for parent in PurePosixPath(name).parents):
        raise ValueError("File paths collide with directories")
    return manifest


def inspect_destination(destination, manifest):
    safe_path(destination)
    allowed = {entry["path"] for entry in manifest["files"]}
    directories_allowed = {str(parent) for name in allowed for parent in PurePosixPath(name).parents}
    states = {state_key(entry): entry for entry in manifest["files"]}
    if not destination.exists():
        return
    if not destination.is_dir():
        raise ValueError("Destination is not a directory")
    for root, directories, files in os.walk(destination, followlinks=False):
        for name in directories + files:
            path = Path(root) / name
            safe_path(path)
            if not path.is_dir() and not stat.S_ISREG(path.lstat().st_mode):
                raise ValueError(f"Refusing non-regular destination entry: {path}")
            relative = path.relative_to(destination).as_posix()
            parts = relative.split("/")
            if parts[0] == STATE:
                if len(parts) == 1 and path.is_dir():
                    continue
                if len(parts) == 2 and parts[1] in states and path.is_dir():
                    continue
                if len(parts) == 3 and parts[1] in states and path.is_file():
                    entry = states[parts[1]]
                    match = re.fullmatch(r"(\d+)-(\d+)\.(part|range)", parts[2])
                    if parts[2] == "assembled.part" and path.stat().st_size <= entry["size"]:
                        continue
                    if match:
                        begin, end = int(match[1]), int(match[2])
                        if (begin % SEGMENT == 0 and 0 <= begin < entry["size"]
                                and end == min(begin + SEGMENT, entry["size"]) - 1
                                and path.stat().st_size <= end - begin + 1):
                            continue
                raise ValueError(f"Unrecognized download state: {relative}")
            if path.is_dir() and relative in directories_allowed:
                continue
            if path.is_file() and relative in allowed:
                continue
            raise ValueError(f"Unlisted destination entry: {relative}")


def state_key(entry):
    return hashlib.sha256((entry["path"] + ":" + entry["sha256"]).encode()).hexdigest()


def verify_file(path, entry):
    digest = hashlib.sha256()
    with regular_open(path, "rb") as file:
        before = os.fstat(file.fileno())
        if before.st_size != entry["size"]:
            raise ValueError(f"Size mismatch: {entry['path']}")
        count = 0
        while data := file.read(BLOCK):
            count += len(data)
            digest.update(data)
        after = os.fstat(file.fileno())
    if (count != entry["size"] or before.st_size != after.st_size
            or before.st_mtime_ns != after.st_mtime_ns or digest.hexdigest() != entry["sha256"]):
        raise ValueError(f"SHA-256 mismatch or file changed: {entry['path']}")
    return count


def content_range(response, begin, end, size):
    match = re.fullmatch(r"bytes (\d+)-(\d+)/(\d+)", response.headers.get("Content-Range", ""))
    if response.status != 206 or not match or tuple(map(int, match.groups())) != (begin, end, size):
        raise ValueError("Server did not return the exact requested 206 Content-Range")
    if response.headers.get("Content-Encoding", "identity").lower() != "identity":
        raise ValueError("Unexpected content encoding")
    length = response.headers.get("Content-Length")
    if length is not None and (not length.isdigit() or int(length) != end - begin + 1):
        raise ValueError("Unexpected Content-Length")
    if urllib.parse.urlsplit(response.url).scheme != "https":
        raise ValueError("Refusing non-HTTPS response")


class HTTPSRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file, code, message, headers, url):
        if urllib.parse.urlsplit(url).scheme != "https":
            raise ValueError("Refusing non-HTTPS redirect")
        return super().redirect_request(request, file, code, message, headers, url)


def retry_delay(error, attempt):
    value = error.headers.get("Retry-After", "") if isinstance(error, urllib.error.HTTPError) else ""
    if value.isdigit():
        seconds = int(value)
    elif value:
        seconds = max(0, email.utils.parsedate_to_datetime(value).timestamp() - time.time())
    else:
        seconds = min(2 ** attempt, 16)
    if seconds > 300:
        raise ValueError("Server requested a long Retry-After; preserve partials and retry later")
    return seconds


def segment_path(directory, start, end, suffix):
    return safe_path(directory / f"{start}-{end}.{suffix}")


def existing_size(path):
    safe_path(path)
    try:
        status = path.lstat()
    except FileNotFoundError:
        return 0
    if not stat.S_ISREG(status.st_mode):
        raise ValueError(f"Refusing non-regular state: {path}")
    return status.st_size


def download_segment(manifest, entry, directory, start, end, cancel_event=None):
    def check_cancelled():
        if cancel_event is not None and cancel_event.is_set():
            raise concurrent.futures.CancelledError("Download interrupted; partials retained")

    check_cancelled()
    required = end - start + 1
    complete = segment_path(directory, start, end, "range")
    partial = segment_path(directory, start, end, "part")
    if complete.exists():
        if existing_size(complete) != required:
            raise ValueError("Completed segment has wrong size; retain it for inspection")
        return 0
    initial = existing_size(partial)
    if initial > required:
        raise ValueError("Partial segment exceeds requested range")
    url = (f"https://huggingface.co/{manifest['repository']}/resolve/{manifest['revision']}/"
           f"{urllib.parse.quote(entry['path'], safe='/')}?download=true")
    opener = urllib.request.build_opener(HTTPSRedirect())
    for attempt in range(1, 6):
        try:
            check_cancelled()
            offset = existing_size(partial)
            if offset < required:
                begin = start + offset
                request = urllib.request.Request(url, headers={
                    "Range": f"bytes={begin}-{end}", "Accept-Encoding": "identity",
                    "User-Agent": "D-Pinned-Model-Fixture/1.0",
                })
                with opener.open(request, timeout=60) as response:
                    content_range(response, begin, end, entry["size"])
                    with regular_open(partial, "ab") as output:
                        if os.fstat(output.fileno()).st_size != offset:
                            raise ValueError("Partial changed during request")
                        received = offset
                        while data := response.read(BLOCK):
                            check_cancelled()
                            received += len(data)
                            if received > required:
                                raise ValueError("Range response contains excess bytes")
                            output.write(data)
                        output.flush()
                        os.fsync(output.fileno())
                        if received != required:
                            raise OSError("Incomplete range response")
            safe_path(complete)
            os.replace(partial, complete)
            return required - initial
        except (OSError, urllib.error.URLError, http.client.HTTPException) as error:
            code = getattr(error, "code", None)
            if attempt == 5 or (code is not None and code not in (408, 429, 500, 502, 503, 504)):
                raise RuntimeError(f"Transfer failed for {entry['path']}, HTTP={code}, type={type(error).__name__}") from None
            delay = retry_delay(error, attempt)
            report("retry", path=entry["path"], start=start, end=end, attempt=attempt,
                   httpStatus=code, errorType=type(error).__name__, delaySeconds=delay)
            if cancel_event is None:
                time.sleep(delay)
            elif cancel_event.wait(delay):
                check_cancelled()


def assemble(destination, entry, directory, ranges):
    target = safe_path(destination / entry["path"])
    temporary = safe_path(directory / "assembled.part")
    with regular_open(temporary, "wb") as output:
        for start, end in ranges:
            with regular_open(segment_path(directory, start, end, "range"), "rb") as source:
                if os.fstat(source.fileno()).st_size != end - start + 1:
                    raise ValueError("Segment size changed before assembly")
                while data := source.read(BLOCK):
                    output.write(data)
        output.flush()
        os.fsync(output.fileno())
    verify_file(temporary, entry)
    safe_path(target.parent).mkdir(parents=True, exist_ok=True)
    safe_path(target)
    if target.exists():
        raise ValueError("Destination file appeared during download; refusing replacement")
    # Hard-link publication is atomic and refuses an existing target; same filesystem.
    os.link(temporary, target, follow_symlinks=False)
    temporary.unlink()
    for start, end in ranges:
        segment_path(directory, start, end, "range").unlink()
    directory.rmdir()


def run(manifest, destination, verify_only=False, connections=4):
    destination = safe_path(destination)
    inspect_destination(destination, manifest)
    verified = 0
    missing = []
    for entry in manifest["files"]:
        target = safe_path(destination / entry["path"])
        if verify_only or target.exists():
            verified += verify_file(target, entry)
            report("verified", **entry)
        else:
            missing.append(entry)
    total = sum(entry["size"] for entry in manifest["files"])
    if not missing:
        report("complete", files=len(manifest["files"]), verifiedBytes=verified,
               repository=manifest["repository"], revision=manifest["revision"], offline=verify_only)
        return
    safe_path(destination).mkdir(parents=True, exist_ok=True)
    plans = []
    retained = 0
    for entry in missing:
        directory = safe_path(destination / STATE / state_key(entry))
        directory.mkdir(parents=True, exist_ok=True)
        ranges = [(start, min(start + SEGMENT, entry["size"]) - 1)
                  for start in range(0, entry["size"], SEGMENT)]
        for start, end in ranges:
            complete = segment_path(directory, start, end, "range")
            partial = segment_path(directory, start, end, "part")
            retained += existing_size(complete) if complete.exists() else existing_size(partial)
        plans.append({"entry": entry, "directory": directory, "ranges": ranges, "pending": len(ranges)})
    received = 0
    started = last_report = time.monotonic()
    report("started", totalBytes=total, verifiedBytes=verified, retainedBytes=retained, connections=connections)
    cancel_event = threading.Event()
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=connections)
    jobs = {}
    try:
        for index in range(max(len(plan["ranges"]) for plan in plans)):
            for plan in plans:
                if index < len(plan["ranges"]):
                    start, end = plan["ranges"][index]
                    future = pool.submit(download_segment, manifest, plan["entry"], plan["directory"], start, end, cancel_event)
                    jobs[future] = plan
        while jobs:
            done, _ = concurrent.futures.wait(jobs, timeout=15, return_when=concurrent.futures.FIRST_COMPLETED)
            for future in done:
                plan = jobs.pop(future)
                received += future.result()
                plan["pending"] -= 1
                if plan["pending"] == 0:
                    assemble(destination, plan["entry"], plan["directory"], plan["ranges"])
                    verified += plan["entry"]["size"]
                    report("verified", **plan["entry"])
            now = time.monotonic()
            if now - last_report >= 15 or not jobs:
                report("progress", verifiedBytes=verified, totalBytes=total,
                       transferredBytes=received, bytesPerSecond=round(received / (now - started)),
                       pendingSegments=len(jobs))
                last_report = now
    except BaseException:
        cancel_event.set()
        for queued in jobs:
            queued.cancel()
        raise
    finally:
        pool.shutdown(wait=True, cancel_futures=True)
    inspect_destination(destination, manifest)
    report("complete", files=len(manifest["files"]), verifiedBytes=verified,
           repository=manifest["repository"], revision=manifest["revision"], offline=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--verify-only", action="store_true", help="Offline SHA-256 verification; no writes")
    parser.add_argument("--connections", type=int, choices=range(1, 5), default=4)
    args = parser.parse_args()
    try:
        run(read_manifest(args.manifest), args.destination, args.verify_only, args.connections)
        return 0
    except (OSError, ValueError, RuntimeError, KeyError, TypeError) as error:
        report("failed", errorType=type(error).__name__, message=str(error))
        return 1
    except KeyboardInterrupt:
        report("interrupted", message="Partial segments retained for resume")
        return 130


if __name__ == "__main__":
    sys.exit(main())
