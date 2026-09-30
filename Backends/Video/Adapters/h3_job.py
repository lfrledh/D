"""Offline H3 FL2VA private candidate runner; never publishes a project asset.

The host owns heavy-execution and installed-model leases until this call has
drained every child. Its engine/source identity and deployment are host duties.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import signal
import stat
import sys
import tempfile
import threading

from h3_admission import admit_h3_fl2va
from h3_plan import build_plan, UPSTREAM_REVISION, _FIELDS
from ltx_job import verify_candidate
from owned_video_process import run_owned


SHADER_SHA256 = "95d665ecad0a19b6864708272b4e0a30d41ea445ecc8a74b8f75dd6de323ddd3"


def _freeze_request(request):
    # H3 v1 is a flat value contract. Copy once before admission can spend
    # minutes hashing weights; no caller-owned mutable value may survive.
    if type(request) is not dict:
        raise ValueError("request must have exactly the H3 v1 fields")
    frozen = request.copy()
    if set(frozen) != _FIELDS:
        raise ValueError("request must have exactly the H3 v1 fields")
    strings = {"profile", "prompt", "negative_prompt"}
    integers = _FIELDS - strings - {"stream_weights"}
    if (any(type(frozen[key]) is not str for key in strings) or
            any(type(frozen[key]) is not int for key in integers) or
            type(frozen["stream_weights"]) is not bool):
        raise ValueError("H3 v1 request requires immutable exact-type scalar fields")
    return frozen


def _physical_file(path: Path, label: str, executable=False):
    if not path.is_absolute() or not stat.S_ISREG(path.lstat().st_mode):
        raise ValueError(f"{label} must be an absolute physical regular file")
    if executable and not os.access(path, os.X_OK):
        raise ValueError(f"{label} must be executable")


def _digest(path: Path, *, cancelled):
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
    with os.fdopen(os.open(path, flags), "rb") as source:
        before = os.fstat(source.fileno())
        if not stat.S_ISREG(before.st_mode):
            raise ValueError("Expected a physical regular file: " + str(path))
        digest = hashlib.sha256()
        for chunk in iter(lambda: source.read(4 * 1024 * 1024), b""):
            if cancelled():
                raise InterruptedError("Cancelled while hashing local executable or shader")
            digest.update(chunk)
        after = os.fstat(source.fileno())
        if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
                after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns):
            raise ValueError("Local executable or shader changed during hashing")
        if cancelled():
            raise InterruptedError("Cancelled while hashing local executable or shader")
        return digest.hexdigest()


def _copy_shader(source: Path, target: Path, *, cancelled):
    # Rehash the actual bytes copied; a changed source can never be launched.
    with os.fdopen(os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), "rb") as inp:
        if not stat.S_ISREG(os.fstat(inp.fileno()).st_mode):
            raise ValueError("Shader is not a regular file")
        digest = hashlib.sha256()
        with target.open("xb") as out:
            while True:
                if cancelled():
                    raise InterruptedError("Cancelled while copying H3 shader")
                chunk = inp.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
                out.write(chunk)
        if digest.hexdigest() != SHADER_SHA256:
            raise ValueError("Pinned H3 shader changed before the private copy completed")


def _save(path: Path, value):
    # All writes stay in a newly created private run. Atomic replacement keeps
    # the previous diagnostic record if a later save itself fails.
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent,
                                     prefix=".result-", delete=False) as file:
        temporary = Path(file.name)
        try:
            json.dump(value, file, ensure_ascii=False, allow_nan=False, indent=2)
            file.write("\n")
            file.flush()
            os.fsync(file.fileno())
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
    os.replace(temporary, path)


def _separate_run(run: Path, protected: list[Path]):
    if not run.is_absolute() or not run.name or os.path.lexists(run):
        raise ValueError("Task directory must be a new absolute path")
    if not run.parent.is_dir() or run.parent.is_symlink():
        raise ValueError("Task directory needs an existing physical parent")
    actual = run.resolve(strict=False)
    for root in protected:
        physical = root.resolve(strict=True)
        if actual == physical or physical in actual.parents or actual in physical.parents:
            raise ValueError("Task directory overlaps model, engine, shader or tool directory")


def execute(request, *, engine, shader, model, run_directory, ffmpeg, ffprobe,
            timeout_seconds, cancel_event):
    frozen_request = _freeze_request(request)
    engine, shader, model, run_directory, ffmpeg, ffprobe = map(
        Path, (engine, shader, model, run_directory, ffmpeg, ffprobe))
    if not isinstance(cancel_event, threading.Event):
        raise ValueError("cancel_event must be a threading.Event")
    if type(timeout_seconds) not in (int, float) or not math.isfinite(timeout_seconds) or timeout_seconds <= 0:
        raise ValueError("timeout_seconds must be finite and positive")
    for label, path in (("engine", engine), ("shader", shader),
                        ("ffmpeg", ffmpeg), ("ffprobe", ffprobe)):
        _physical_file(path, label, executable=label != "shader")
    if ffmpeg.parent != ffprobe.parent:
        raise ValueError("FFmpeg and FFprobe must share the explicit tool directory")
    if not model.is_absolute() or not stat.S_ISDIR(model.lstat().st_mode):
        raise ValueError("Model must be an absolute physical directory")
    _separate_run(run_directory, [model, engine.parent, shader.parent, ffmpeg.parent])
    if cancel_event.is_set():
        raise InterruptedError("Cancelled before H3 admission")
    admission = admit_h3_fl2va(model, cancelled=cancel_event.is_set)
    engine_sha256 = _digest(engine, cancelled=cancel_event.is_set)
    if _digest(shader, cancelled=cancel_event.is_set) != SHADER_SHA256:
        raise ValueError("H3 shader does not match the pinned upstream bytes")
    if cancel_event.is_set():
        raise InterruptedError("Cancelled before private run creation")

    run_directory.mkdir(mode=0o700, exist_ok=False)
    record = {
        "schema": "d.h3.private-candidate.v1", "request": None,
        "admission": admission,
        "engine_source_expected": f"antirez/h3.c@{UPSTREAM_REVISION}",
        "engine_source_verified": False,
        "engine_sha256": engine_sha256, "shader_sha256": SHADER_SHA256,
        "engine_process": None, "published": False, "media_verified": False,
        "diagnostic_logs": {name: str(run_directory / name) for name in
                            ("engine-log", "probe-log", "decode-log")},
    }
    result_path = run_directory / "result.json"
    try:
        for name in ("cache", "tmp", "engine-log", "probe-log", "decode-log"):
            (run_directory / name).mkdir(mode=0o700)
        _copy_shader(shader, run_directory / "h3_shaders.metal", cancelled=cancel_event.is_set)
        output = run_directory / "candidate.mp4"
        plan = build_plan(frozen_request, engine=str(engine), model=str(model), output=str(output))
        record["request"] = plan["provenance"]["request"]
        record["plan"] = plan
        environment = {
            "PATH": f"{ffmpeg.parent}:/usr/bin:/bin",
            "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
            "TMPDIR": str(run_directory / "tmp"),
            "XDG_CACHE_HOME": str(run_directory / "cache"),
            **plan["environment"], "H3_FFMPEG": str(ffmpeg),
            "H3_FFPROBE": str(ffprobe), "H3_PROFILE": "1",
            "H3_NAX": "0", "H3_CPU_SAMPLER": "1",
        }
        record["environment"] = environment.copy()
        _save(result_path, record)

        def run(argv, label, timeout):
            return run_owned(argv, cwd=str(run_directory), environment=environment,
                             log_directory=str(run_directory / label), timeout_seconds=timeout,
                             grace_seconds=5, cancel_event=cancel_event)

        process = run(plan["argv"], "engine-log", timeout_seconds)
        record["engine_process"] = process
        if output.is_file() and not output.is_symlink():
            record["candidate_file"] = output.name
        _save(result_path, record)
        if process["status"] != "success":
            return record
        verified = verify_candidate(output, record["request"], ffmpeg=ffmpeg,
                                    ffprobe=ffprobe, run=run, cancel_event=cancel_event)
        # Retain measured facts and subprocess diagnostics if H3's stricter
        # audio condition rejects an otherwise decodable MP4.
        record.update({key: value for key, value in verified.items() if key != "media_verified"})
        media = verified["media"]
        if media["audio_codec"] != "aac" or media["audio_sample_rate"] != 32000 or media["audio_channels"] != 2:
            raise ValueError("H3 candidate must contain AAC 32000 Hz stereo audio")
        if cancel_event.is_set():
            raise InterruptedError("Cancelled after H3 media validation")
        record["media_verified"] = True
        _save(result_path, record)
        if cancel_event.is_set():
            raise InterruptedError("Cancelled while recording H3 candidate")
        return record
    except Exception as error:
        record["media_verified"] = False
        record["error"] = {"type": type(error).__name__, "message": str(error)}
        try:
            _save(result_path, record)
        except Exception as save_error:
            raise RuntimeError(
                f"{type(error).__name__}: {error}; H3 result save also failed: {save_error}"
            ) from save_error
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("request", "engine", "shader", "model", "run-directory", "ffmpeg", "ffprobe"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--timeout", type=float, default=1800)
    args = parser.parse_args()
    event = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda signum, frame: event.set())
    with Path(args.request).open("rb") as file:
        raw = file.read(1024 * 1024 + 1)
    if len(raw) > 1024 * 1024:
        raise ValueError("Request exceeds 1 MiB")
    result = execute(json.loads(raw), engine=args.engine, shader=args.shader,
                     model=args.model, run_directory=args.run_directory,
                     ffmpeg=args.ffmpeg, ffprobe=args.ffprobe,
                     timeout_seconds=args.timeout, cancel_event=event)
    if event.is_set():
        result["media_verified"] = False
        result["error"] = {"type": "InterruptedError", "message": "Cancelled before H3 CLI result"}
        _save(Path(args.run_directory) / "result.json", result)
        raise InterruptedError("Cancelled before H3 CLI result")
    success = result["media_verified"] and result["engine_process"]["status"] == "success"
    print(json.dumps({"status": result["engine_process"]["status"],
                      "media_verified": result["media_verified"], "published": False}), flush=True)
    return 0 if success else 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(type(error).__name__ + ": " + str(error), file=sys.stderr, flush=True)
        sys.exit(2)
