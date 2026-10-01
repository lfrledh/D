"""Private App video provider. Swift owns the process group and task lifetime.

This module never publishes an asset, downloads a model, or starts a session.
Only the parent-issued task directory may receive outputs and diagnostics.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager, redirect_stdout
import hashlib
import json
import math
import os
from pathlib import Path
import re
import selectors
import stat
import struct
import subprocess
import sys
import tempfile
import time
import uuid


MANIFEST_NAME = "D-VIDEO-PACK.json"
RESULT_SCHEMA = "d.external-video.app-result.v1"
H3 = "minimax-h3-fl2va-bf16-full-v1"
LTX_FULL = "ltx-2.3-dev-bf16-full-v1"
LTX_TEST = "ltx-2.3-dev-q8-gemma3-q4-test-v1"
LTX_25 = "ltx-2.5-dev-bf16-full-v1"
REVISIONS = {
    H3: ("42ed227ee7df40d41602854ae760620d6eb651fe", None),
    LTX_FULL: ("cfc837526e56abf8657823a0ae192eec3a40177d", "b8b9b412cb795bd6115fdce8c9a0ef0d1664db3a"),
    LTX_TEST: ("6671a7572a530862d1d60ce393b5d93491e3f76b", "86cc6a8dedbc456dd0e4af01a9d09f396f77e558"),
    LTX_25: ("e378b7e1b50fcb1795fce74219b40bb0b1ede1e2", None),
}
WIRE_FIELDS = frozenset(("schema_version", "profile", "prompt", "negative_prompt", "width",
                         "height", "frames", "steps", "fps", "seed", "stream_weights",
                         "cfg_scale", "stg_scale"))
FRAME_FIELDS = frozenset(("file", "width", "height", "byte_count", "content_sha256"))
FRAME_LIMIT = 64 * 1024 * 1024
MAX_LOG = 4 * 1024 * 1024


def _lexical(path: str | Path, label: str) -> Path:
    """Validate a path without touching protected file system metadata."""
    value = str(path)
    if (not value or "\0" in value or not os.path.isabs(value) or
            os.path.normpath(value) != value or str(Path(value)) != value or value == "/"):
        raise ValueError(f"{label} must be a normalized absolute path")
    return Path(value)


def _physical(path: str | Path, label: str, *, kind: str, executable: bool = False) -> Path:
    """Reject aliases and special leaves, including symlinked ancestors."""
    result = _lexical(path, label)
    current = Path("/")
    for component in result.parts[1:]:
        current /= component
        mode = current.lstat().st_mode
        if stat.S_ISLNK(mode):
            raise ValueError(f"{label} contains a symlink")
    mode = result.lstat().st_mode
    if not (stat.S_ISDIR(mode) if kind == "directory" else stat.S_ISREG(mode)):
        raise ValueError(f"{label} must be a physical {kind}")
    if executable and not os.access(result, os.X_OK):
        raise ValueError(f"{label} must be executable")
    return result


def _separate(run: Path, protected: list[Path]) -> None:
    for path in protected:
        if run == path or run in path.parents or path in run.parents:
            raise ValueError("Task directory overlaps a model, tool, provider, or runtime")


def _identity(info: os.stat_result) -> tuple[int, ...]:
    return (info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def _read_snapshot(path: Path, limit: int) -> tuple[bytes, tuple[int, ...], str]:
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), "rb") as file:
        before = os.fstat(file.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_size > limit:
            raise ValueError(f"{path.name} is not a bounded regular file")
        raw = file.read(limit + 1)
        after = os.fstat(file.fileno())
    if len(raw) > limit or len(raw) != before.st_size or _identity(before) != _identity(after):
        raise ValueError(f"{path.name} changed while reading")
    if _identity(path.lstat()) != _identity(after):
        raise ValueError(f"{path.name} changed during inspection")
    return raw, _identity(after), hashlib.sha256(raw).hexdigest()


def _unchanged(path: Path, snapshot: tuple[bytes, tuple[int, ...], str], limit: int) -> None:
    if _read_snapshot(path, limit)[1:] != snapshot[1:]:
        raise ValueError(f"{path.name} changed during execution")


def _unique(pairs: list[tuple[str, object]]) -> dict:
    value = {}
    for key, child in pairs:
        if key in value:
            raise ValueError("duplicate JSON key")
        value[key] = child
    return value


def _reject_constant(value: str) -> None:
    raise ValueError(f"non-finite JSON constant: {value}")


def _json(raw: bytes) -> object:
    return json.loads(raw.decode("utf-8", "strict"), object_pairs_hook=_unique,
                      parse_constant=_reject_constant)


def _exact(value: object, keys: set[str] | frozenset[str], label: str) -> dict:
    if type(value) is not dict or set(value) != keys:
        raise ValueError(f"{label} fields differ from the fixed schema")
    return value


def _integer(value: object, label: str, low: int, high: int) -> int:
    if type(value) is not int or not low <= value <= high:
        raise ValueError(f"{label} must be an integer in [{low}, {high}]")
    return value


def _number(value: object, label: str) -> int | float:
    if type(value) not in (int, float):
        raise ValueError(f"{label} must be finite numeric")
    try:
        finite = math.isfinite(value)
    except (OverflowError, ValueError):
        finite = False
    if not finite:
        raise ValueError(f"{label} must be finite numeric")
    return value


def _wire(raw: bytes) -> dict:
    root = _exact(_json(raw), {"schema_version", "run_id", "manifest_sha256", "request"}, "wire")
    _integer(root["schema_version"], "wire schema_version", 1, 1)
    run_id = root["run_id"]
    if type(run_id) is not str or str(uuid.UUID(run_id)) != run_id:
        raise ValueError("run_id must be a canonical lowercase UUID")
    digest = root["manifest_sha256"]
    if type(digest) is not str or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
        raise ValueError("manifest_sha256 must be lowercase SHA-256")
    request = root["request"]
    if type(request) is not dict or not WIRE_FIELDS <= set(request) or not set(request) <= WIRE_FIELDS | {"first_frame", "last_frame"}:
        raise ValueError("request fields differ from the fixed schema")
    _integer(request["schema_version"], "request schema_version", 1, 1)
    profile = request["profile"]
    if type(profile) is not str or profile not in REVISIONS:
        raise ValueError("Unsupported video profile")
    for field in ("prompt", "negative_prompt"):
        if type(request[field]) is not str or "\0" in request[field]:
            raise ValueError(f"{field} must be a string without NUL")
    if not request["prompt"]:
        raise ValueError("prompt must be nonempty")
    for field in ("width", "height", "frames", "steps"):
        _integer(request[field], field, 1, 2**31 - 1)
    _integer(request["seed"], "seed", 0, 2**64 - 1)
    for field in ("fps", "cfg_scale", "stg_scale"):
        _number(request[field], field)
    if request["fps"] <= 0 or type(request["stream_weights"]) is not bool:
        raise ValueError("fps must be positive and stream_weights boolean")
    for role in ("first", "last"):
        field = role + "_frame"
        if field in request:
            frame = _exact(request[field], FRAME_FIELDS, field)
            if frame["file"] != role + "-frame.png":
                raise ValueError(f"{field} must name its private role file")
            _integer(frame["width"], field + " width", 1, 2**31 - 1)
            _integer(frame["height"], field + " height", 1, 2**31 - 1)
            _integer(frame["byte_count"], field + " byte_count", 1, FRAME_LIMIT)
            if type(frame["content_sha256"]) is not str or re.fullmatch(r"[0-9a-f]{64}", frame["content_sha256"]) is None:
                raise ValueError(f"{field} must have a lowercase SHA-256")
    if profile != H3 and "last_frame" in request:
        raise ValueError("LTX does not support last-frame conditioning")
    # Rebuild immediately. No caller-owned mutable JSON values survive validation.
    return {"schema_version": 1, "run_id": run_id, "manifest_sha256": digest,
            "request": {key: request[key] for key in request}}


def _frame_snapshots(request: dict, run: Path) -> dict[str, tuple[Path, tuple[bytes, tuple[int, ...], str]]]:
    frames = {}
    file_ids = set()
    for role in ("first", "last"):
        field = role + "_frame"
        if field not in request:
            continue
        expected = request[field]
        path = _physical(run / expected["file"], field, kind="file")
        named = path.lstat()
        file_id = (named.st_dev, named.st_ino)
        if named.st_nlink != 1 or file_id in file_ids:
            raise ValueError(f"{field} must be an independent private file")
        file_ids.add(file_id)
        raw, identity, digest = _read_snapshot(path, FRAME_LIMIT)
        # PNG signature and IHDR are enough here to reject a mismatched wire;
        # Swift has already fully decoded the frozen source before launch.
        if (len(raw) < 33 or raw[:8] != b"\x89PNG\r\n\x1a\n" or
                raw[8:16] != b"\x00\x00\x00\rIHDR" or
                struct.unpack(">II", raw[16:24]) != (expected["width"], expected["height"]) or
                len(raw) != expected["byte_count"] or digest != expected["content_sha256"]):
            raise ValueError(f"{field} bytes or PNG geometry differ from frozen wire")
        frames[role] = (path, (raw, identity, digest))
    return frames


def _unchanged_frames(frames: dict) -> None:
    for path, snapshot in frames.values():
        if path.lstat().st_nlink != 1:
            raise ValueError(f"{path.name} lost independent-file status")
        _unchanged(path, snapshot, FRAME_LIMIT)


def _manifest(raw: bytes, profile: str) -> dict:
    model_revision, text_revision = REVISIONS[profile]
    keys = {"schemaVersion", "profile", "modelRevision"}
    if text_revision is not None:
        keys.add("textEncoderRevision")
    value = _exact(_json(raw), keys, "pack manifest")
    if (type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1 or
            type(value["profile"]) is not str or value["profile"] != profile or
            type(value["modelRevision"]) is not str or value["modelRevision"] != model_revision or
            (text_revision is not None and (type(value["textEncoderRevision"]) is not str or
                                            value["textEncoderRevision"] != text_revision))):
        raise ValueError("Pack manifest identity differs from selected profile")
    return value


@contextmanager
def _file_access(args, run: Path, pack: Path):
    if bool(args.access_manifest) != bool(args.access_run_id):
        raise ValueError("access-manifest and access-run-id must be paired")
    if args.access_manifest is None:
        yield
        return
    access = _lexical(args.access_manifest, "access manifest")
    if type(args.access_run_id) is not str or str(uuid.UUID(args.access_run_id)) != args.access_run_id:
        raise ValueError("Access run ID must be a canonical UUID")
    # Deployment puts the helper beside this provider; repository tests use the
    # reviewed audio helper at its existing location.
    if not (Path(__file__).parent / "d_audio_access.py").is_file():
        sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Audio" / "Python"))
    from d_audio_access import acquire_file_access, AudioAccessError
    try:
        with acquire_file_access(access, run_id=args.access_run_id, allowed_paths=[pack, run]):
            yield
    except AudioAccessError as error:
        raise ValueError("Video file access failed: " + str(error)) from error


def _assert_free(run: Path) -> None:
    for name in ("candidate.mp4", "result.json", "h3_shaders.metal"):
        if os.path.lexists(run / name):
            raise ValueError(f"Private output already exists: {name}")


def _write_result(path: Path, value: dict) -> None:
    with path.open("x", encoding="utf-8") as file:
        json.dump(value, file, ensure_ascii=False, allow_nan=False, sort_keys=True)
        file.write("\n")
        file.flush()
        os.fsync(file.fileno())


class _LTXLog:
    """Keep bounded, live diagnostics for the in-process LTX pipeline."""
    def __init__(self, output, log):
        self.output, self.log, self.size = output, log, 0

    def write(self, text):
        encoded = text.encode("utf-8", errors="replace")
        retained = encoded[:max(0, MAX_LOG - self.size)]
        self.log.write(retained)
        self.size += len(retained)
        self.output.write(text)
        return len(text)

    def flush(self):
        self.log.flush()
        self.output.flush()

    def isatty(self):
        return False


def _run_child(argv: list[str], label: str, timeout: float, run_dir: Path, environment: dict | None = None) -> dict:
    """Drain bounded logs while inheriting the Swift-owned process group."""
    stdout_path, stderr_path = (run_dir / f"{label}.stdout", run_dir / f"{label}.stderr")
    if os.path.lexists(stdout_path) or os.path.lexists(stderr_path):
        raise ValueError("Diagnostic log already exists")
    first_log = stdout_path.open("xb")
    try:
        second_log = stderr_path.open("xb")
    except BaseException:
        first_log.close()
        raise
    logs = [first_log, second_log]
    process = None
    selector = selectors.DefaultSelector()
    sizes = [0, 0]
    truncated = [False, False]
    timed_out = False
    try:
        process = subprocess.Popen(argv, cwd=run_dir, env=environment, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, stdin=subprocess.DEVNULL, close_fds=True)
        for index, pipe in enumerate((process.stdout, process.stderr)):
            os.set_blocking(pipe.fileno(), False)
            selector.register(pipe, selectors.EVENT_READ, index)
        deadline = time.monotonic() + timeout
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                timed_out = True
                break
            for key, _ in selector.select(min(remaining, 0.25)):
                chunk = os.read(key.fileobj.fileno(), 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    key.fileobj.close()
                    continue
                index = key.data
                available = max(0, MAX_LOG - sizes[index])
                logs[index].write(chunk[:available])
                sizes[index] += min(len(chunk), available)
                truncated[index] |= len(chunk) > available
        if timed_out and process.poll() is None:
            process.terminate()  # Direct helper only. Swift owns the group.
        try:
            code = process.wait(timeout=5 if timed_out else max(0.1, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            timed_out = True
            process.kill()  # Direct helper only.
            code = process.wait(timeout=5)
        return {"status": "timeout" if timed_out else "success" if code == 0 else "failure",
                "exit_code": code, "stdout_log": str(stdout_path), "stderr_log": str(stderr_path),
                "stdout_truncated": truncated[0], "stderr_truncated": truncated[1]}
    finally:
        selector.close()
        for pipe in (getattr(process, "stdout", None), getattr(process, "stderr", None)):
            if pipe is not None:
                pipe.close()
        if process is not None and process.poll() is None:
            process.kill()
            process.wait()
        for file in logs:
            file.close()


def _h3_request(request: dict) -> dict:
    if request["cfg_scale"] != 1 or request["stg_scale"] != 0:
        raise ValueError("H3 requires cfg_scale=1 and stg_scale=0")
    if request["fps"] != 24:
        raise ValueError("H3 requires exactly 24 fps")
    return {key: request[key] for key in ("schema_version", "profile", "prompt", "negative_prompt",
                                           "width", "height", "frames", "steps", "seed", "stream_weights")} | {"fps": 24}


def _verify_media(output: Path, request: dict, *, ffmpeg: Path, ffprobe: Path, run: Path, profile: str) -> dict:
    from ltx_job import verify_candidate
    import threading
    def child(argv, label, timeout):
        return _run_child(argv, label, min(timeout, 180), run)
    verified = verify_candidate(output, request, ffmpeg=ffmpeg, ffprobe=ffprobe,
                                run=child, cancel_event=threading.Event())
    media = verified["media"]
    expected_rate = 32000 if profile == H3 else 48000
    if media["audio_codec"] != "aac" or media["audio_sample_rate"] != expected_rate or media["audio_channels"] != 2:
        raise ValueError(f"Candidate must contain AAC {expected_rate} Hz stereo audio")
    return verified


def _execute(request: dict, *, pack: Path, run: Path, ffmpeg: Path, ffprobe: Path,
             h3_engine: Path | None, h3_shader: Path | None, frames: dict,
             engine_timeout_seconds: float) -> tuple[dict, dict]:
    profile = request["profile"]
    output = run / "candidate.mp4"
    _assert_free(run)
    model = _physical(pack / "model", "model", kind="directory")
    if profile == H3:
        if h3_engine is None or h3_shader is None:
            raise ValueError("H3 requires a fixed engine and shader")
        from h3_admission import admit_h3_fl2va
        from h3_plan import build_plan, UPSTREAM_REVISION
        from h3_job import _digest, _copy_shader, SHADER_SHA256
        import threading
        mapped = _h3_request(request)
        plan = build_plan(mapped, engine=str(h3_engine), model=str(model), output=str(output),
                          first_frame=str(frames["first"][0]) if "first" in frames else None,
                          last_frame=str(frames["last"][0]) if "last" in frames else None)
        admission = admit_h3_fl2va(model)
        engine_digest = _digest(h3_engine, cancelled=lambda: False)
        if _digest(h3_shader, cancelled=lambda: False) != SHADER_SHA256:
            raise ValueError("H3 shader differs from pinned bytes")
        _copy_shader(h3_shader, run / "h3_shaders.metal", cancelled=lambda: False)
        environment = os.environ.copy()
        for key in list(environment):
            if key.startswith("H3_"):
                del environment[key]
        environment.update(H3_DIT_F32_FINAL="1", H3_FFMPEG=str(ffmpeg), H3_FFPROBE=str(ffprobe),
                           H3_PROFILE="1", H3_NAX="0", H3_CPU_SAMPLER="1")
        _unchanged_frames(frames)
        process = _run_child(plan["argv"], "engine", engine_timeout_seconds, run, environment)
        source = {"expected_engine_source": f"antirez/h3.c@{UPSTREAM_REVISION}",
                  "engine_sha256": engine_digest, "shader_sha256": SHADER_SHA256,
                  "engine_source_cryptographically_verified": False}
        if process["status"] != "success":
            raise ValueError(f"H3 engine failed: {process['status']}, exit {process['exit_code']}")
        return admission, source
    if h3_engine is not None or h3_shader is not None:
        raise ValueError("H3 engine arguments are invalid for LTX")
    from ltx_admission import admit_ltx23, admit_ltx25
    from ltx_plan import build_plan
    from ltx_job import _confirm_tokenizer_patch
    text_encoder = (_physical(pack / "text_encoder", "text encoder", kind="directory")
                    if profile != LTX_25 else None)
    admission = (admit_ltx25(profile, model=model) if profile == LTX_25 else
                 admit_ltx23(profile, model=model, text_encoder=text_encoder))
    plan_request = {key: value for key, value in request.items() if key in WIRE_FIELDS}
    plan = build_plan(plan_request, engine=sys.executable, model=model, text_encoder=text_encoder, output=output,
                      first_frame=str(frames["first"][0]) if "first" in frames else None)
    upstream = _confirm_tokenizer_patch(Path(sys.executable),
        streaming_gemma4=profile == LTX_25 and plan_request["stream_weights"])
    previous = sys.argv
    try:
        _unchanged_frames(frames)
        sys.argv = plan["argv"]
        from ltx_pipelines_mlx.cli import main as ltx_main
        # No extra child or sandbox boundary: LTX stays in this owned provider.
        # Exclusive creation preserves any earlier diagnostic; marker flushes
        # are visible before completion without unbounded output files.
        with (run / "engine.stdout").open("xb") as log:
            with redirect_stdout(_LTXLog(sys.stdout, log)):
                try:
                    code = ltx_main()
                except SystemExit as error:
                    code = error.code
        if code not in (None, 0):
            raise ValueError(f"LTX engine failed: {code}")
    finally:
        sys.argv = previous
    return admission, {"upstream_patch_commit": upstream,
        "upstream_source_expected": plan["provenance"]["upstream_commit_from_task"],
        "weight_loading": plan["provenance"]["weight_loading"]}


def run(args) -> int:
    """One already-owned App task. All acquired access stays live through children."""
    try:
        engine_timeout = args.engine_timeout_seconds
        if type(engine_timeout) not in (int, float) or not math.isfinite(engine_timeout) or engine_timeout <= 0:
            raise ValueError("engine timeout must be finite and positive")
        request_path = _lexical(args.request, "request")
        if request_path.name != "request.json":
            raise ValueError("request must be the private task request.json")
        run_dir = _lexical(request_path.parent, "task directory")
        pack = _lexical(args.pack, "pack")
        ffmpeg = _lexical(args.ffmpeg, "ffmpeg")
        ffprobe = _lexical(args.ffprobe, "ffprobe")
        h3_engine = _lexical(args.h3_engine, "H3 engine") if args.h3_engine else None
        h3_shader = _lexical(args.h3_shader, "H3 shader") if args.h3_shader else None
        if bool(h3_engine) != bool(h3_shader):
            raise ValueError("H3 engine and shader must be paired")
        if ffmpeg.parent != ffprobe.parent:
            raise ValueError("FFmpeg tools must share a fixed directory")
        executable = _lexical(sys.executable, "Python executable")
        provider = _lexical(Path(__file__).absolute().parent, "video provider")
        prefix = _lexical(sys.prefix, "Python prefix")
        base_prefix = _lexical(sys.base_prefix, "Python base prefix")
        protected = [pack, ffmpeg.parent, ffprobe.parent, provider,
                     executable.parent.parent, prefix, base_prefix]
        if h3_engine:
            protected += [h3_engine.parent, h3_shader.parent]
        # No target metadata is inspected before the two bookmarks are acquired.
        _separate(run_dir, protected)
    except Exception as error:
        print(f"Video App driver rejected input: {type(error).__name__}: {str(error)[:2048]}",
              file=sys.stderr, flush=True)
        return 2
    record = {"schema": RESULT_SCHEMA, "media_verified": False, "published": False}
    try:
        with _file_access(args, run_dir, pack):
            safe_to_write = False
            try:
                request_path = _physical(request_path, "request", kind="file")
                run_dir = _physical(run_dir, "task directory", kind="directory")
                pack = _physical(pack, "pack", kind="directory")
                ffmpeg = _physical(ffmpeg, "ffmpeg", kind="file", executable=True)
                ffprobe = _physical(ffprobe, "ffprobe", kind="file", executable=True)
                if h3_engine:
                    h3_engine = _physical(h3_engine, "H3 engine", kind="file", executable=True)
                    h3_shader = _physical(h3_shader, "H3 shader", kind="file")
                # The running interpreter may be a symlink into a base install.
                # Protect both the venv spelling and resolved base, without
                # adding either runtime path to the model-access grant.
                runtime = _physical(executable.resolve(strict=True), "Python runtime", kind="file", executable=True)
                physical_protected = protected + [runtime.parent.parent,
                    prefix.resolve(strict=True), base_prefix.resolve(strict=True),
                    provider.resolve(strict=True)]
                _separate(run_dir, physical_protected)
                safe_to_write = True
                scratch = _physical(run_dir / "tmp", "TMPDIR", kind="directory")
                _physical(run_dir / "cache", "cache", kind="directory")
                if os.environ.get("TMPDIR") != str(scratch):
                    raise ValueError("TMPDIR must equal the private task tmp directory")
                if (os.environ.get("HF_HUB_OFFLINE") != "1" or
                        os.environ.get("TRANSFORMERS_OFFLINE") != "1" or
                        os.environ.get("LTX2_GEMMA_MAX_LENGTH") != "1024"):
                    raise ValueError("Swift-supplied offline environment and tokenizer limit are required")
                tempfile.tempdir = str(scratch)
                request_snapshot = _read_snapshot(request_path, 1024 * 1024)
                wire = _wire(request_snapshot[0])
                if args.access_run_id and args.access_run_id != wire["run_id"]:
                    raise ValueError("Access run ID differs from request run_id")
                manifest_path = _physical(pack / MANIFEST_NAME, "pack manifest", kind="file")
                manifest_snapshot = _read_snapshot(manifest_path, 16 * 1024)
                request = wire["request"]
                _manifest(manifest_snapshot[0], request["profile"])
                if wire["manifest_sha256"] != manifest_snapshot[2]:
                    raise ValueError("Pack manifest hash differs from frozen wire")
                record.update(run_id=wire["run_id"], request_sha256=request_snapshot[2],
                              manifest_sha256=manifest_snapshot[2], profile=request["profile"],
                              source_request=request.copy())
                frames = _frame_snapshots(request, run_dir)
                if frames:
                    record["frame_conditions"] = {
                        role + "_frame_sha256": snapshot[1][2] for role, snapshot in frames.items()
                    }
                _assert_free(run_dir)
                previous_cwd = Path.cwd()
                os.chdir(run_dir)
                try:
                    try:
                        admission, source = _execute(request, pack=pack, run=run_dir, ffmpeg=ffmpeg,
                                                     ffprobe=ffprobe, h3_engine=h3_engine, h3_shader=h3_shader,
                                                     frames=frames, engine_timeout_seconds=engine_timeout)
                        record.update(admission=admission, source=source)
                        verified = _verify_media(run_dir / "candidate.mp4", request, ffmpeg=ffmpeg,
                                                 ffprobe=ffprobe, run=run_dir, profile=request["profile"])
                    finally:
                        _unchanged_frames(frames)
                        _unchanged(request_path, request_snapshot, 1024 * 1024)
                        _unchanged(manifest_path, manifest_snapshot, 16 * 1024)
                    record.update(candidate_file="candidate.mp4", sha256=verified["sha256"],
                                  media=verified["media"], media_verified=True)
                    _write_result(run_dir / "result.json", record)
                    return 0
                finally:
                    os.chdir(previous_cwd)
            except Exception as error:
                # The report is part of the same capability lifetime as the
                # engine and probes. Unsafe or unknown output roots get no write.
                failure = {key: record[key] for key in ("schema", "run_id", "request_sha256",
                    "manifest_sha256", "profile", "source_request") if key in record}
                failure.update(media_verified=False, published=False,
                    error={"type": type(error).__name__, "message": str(error)[:2048]})
                if safe_to_write and not os.path.lexists(run_dir / "result.json"):
                    _write_result(run_dir / "result.json", failure)
                print(f"Video App driver failed: {type(error).__name__}: {str(error)[:2048]}",
                      file=sys.stderr, flush=True)
                return 2
    except Exception as error:
        # Includes access acquisition/cleanup failures. The scope is unavailable;
        # never attempt a result write after leaving it.
        print(f"Video App driver rejected access: {type(error).__name__}: {str(error)[:2048]}",
              file=sys.stderr, flush=True)
        return 2


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("request", "pack", "ffmpeg", "ffprobe"):
        parser.add_argument("--" + name, required=True)
    for name in ("h3-engine", "h3-shader", "access-manifest", "access-run-id"):
        parser.add_argument("--" + name)
    # The Swift parent remains the owner of the end-to-end deadline and process
    # group. Avoid imposing a second, shorter fixed deadline on the H3 child.
    parser.add_argument("--engine-timeout-seconds", type=float, default=7200)
    args = parser.parse_args(argv)
    try:
        return run(args)
    except Exception as error:
        print(f"Video App driver rejected input: {type(error).__name__}: {str(error)[:2048]}", file=sys.stderr, flush=True)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
