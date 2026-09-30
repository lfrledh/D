"""Private App video provider. Swift owns the process group and task lifetime.

This module never publishes an asset, downloads a model, or starts a session.
Only the parent-issued task directory may receive outputs and diagnostics.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import hashlib
import json
import math
import os
from pathlib import Path
import re
import selectors
import stat
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
MAX_LOG = 4 * 1024 * 1024


def _physical(path: str | Path, label: str, *, kind: str, executable: bool = False) -> Path:
    """Reject aliases and special leaves, including symlinked ancestors."""
    value = str(path)
    if (not value or "\0" in value or not os.path.isabs(value) or
            os.path.normpath(value) != value or str(Path(value)) != value or value == "/"):
        raise ValueError(f"{label} must be a normalized absolute path")
    result = Path(value)
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
            raise ValueError("Task directory overlaps a model, engine, or runtime")


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
    request = _exact(root["request"], WIRE_FIELDS, "request")
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
    # Rebuild immediately. No caller-owned mutable JSON values survive validation.
    return {"schema_version": 1, "run_id": run_id, "manifest_sha256": digest,
            "request": {key: request[key] for key in WIRE_FIELDS}}


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
    access = _physical(args.access_manifest, "access manifest", kind="file")
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
             h3_engine: Path | None, h3_shader: Path | None) -> tuple[dict, dict]:
    profile = request["profile"]
    output = run / "candidate.mp4"
    if profile == LTX_25:
        raise ValueError("LTX 2.5 has no accessible verified resource inventory; execution rejected")
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
        plan = build_plan(mapped, engine=str(h3_engine), model=str(model), output=str(output))
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
        process = _run_child(plan["argv"], "engine", 7200, run, environment)
        source = {"expected_engine_source": f"antirez/h3.c@{UPSTREAM_REVISION}",
                  "engine_sha256": engine_digest, "shader_sha256": SHADER_SHA256,
                  "engine_source_cryptographically_verified": False}
        if process["status"] != "success":
            raise ValueError(f"H3 engine failed: {process['status']}, exit {process['exit_code']}")
        return admission, source
    if h3_engine is not None or h3_shader is not None:
        raise ValueError("H3 engine arguments are invalid for LTX")
    from ltx_admission import admit_ltx23
    from ltx_plan import build_plan
    from ltx_job import _confirm_tokenizer_patch
    text_encoder = _physical(pack / "text_encoder", "text encoder", kind="directory")
    plan = build_plan(request, engine=sys.executable, model=model, text_encoder=text_encoder, output=output)
    admission = admit_ltx23(profile, model=model, text_encoder=text_encoder)
    upstream = _confirm_tokenizer_patch(Path(sys.executable))
    previous = sys.argv
    try:
        sys.argv = plan["argv"]
        from ltx_pipelines_mlx.cli import main as ltx_main
        try:
            code = ltx_main()
        except SystemExit as error:
            code = error.code
        if code not in (None, 0):
            raise ValueError(f"LTX engine failed: {code}")
    finally:
        sys.argv = previous
    return admission, {"upstream_patch_commit": upstream, "upstream_source_expected": plan["provenance"]["upstream_commit_from_task"]}


def run(args) -> int:
    """One already-owned App task. All acquired access stays live through children."""
    request_path = _physical(args.request, "request", kind="file")
    if request_path.name != "request.json":
        raise ValueError("request must be the private task request.json")
    run_dir = _physical(request_path.parent, "task directory", kind="directory")
    record = {"schema": RESULT_SCHEMA, "media_verified": False, "published": False}
    safe_to_write = False
    try:
        pack = _physical(args.pack, "pack", kind="directory")
        ffmpeg = _physical(args.ffmpeg, "ffmpeg", kind="file", executable=True)
        ffprobe = _physical(args.ffprobe, "ffprobe", kind="file", executable=True)
        h3_engine = _physical(args.h3_engine, "H3 engine", kind="file", executable=True) if args.h3_engine else None
        h3_shader = _physical(args.h3_shader, "H3 shader", kind="file") if args.h3_shader else None
        if bool(h3_engine) != bool(h3_shader):
            raise ValueError("H3 engine and shader must be paired")
        if ffmpeg.parent != ffprobe.parent:
            raise ValueError("FFmpeg tools must share a fixed directory")
        # sys.executable may itself be an OS-installed symlink; it is the running
        # interpreter, not a caller-supplied path. Protect its resolved install root.
        runtime = _physical(Path(sys.executable).resolve(strict=True), "Python runtime", kind="file", executable=True)
        protected = [pack, runtime.parent.parent, ffmpeg.parent]
        if h3_engine:
            protected += [h3_engine.parent, h3_shader.parent]
        _separate(run_dir, protected)
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
        with _file_access(args, run_dir, pack):
            # Acquisition is before opening the request or any pack file.
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
            _assert_free(run_dir)
            previous_cwd = Path.cwd()
            os.chdir(run_dir)
            try:
                admission, source = _execute(request, pack=pack, run=run_dir, ffmpeg=ffmpeg,
                                             ffprobe=ffprobe, h3_engine=h3_engine, h3_shader=h3_shader)
                record.update(admission=admission, source=source)
                verified = _verify_media(run_dir / "candidate.mp4", request, ffmpeg=ffmpeg,
                                         ffprobe=ffprobe, run=run_dir, profile=request["profile"])
                _unchanged(request_path, request_snapshot, 1024 * 1024)
                _unchanged(manifest_path, manifest_snapshot, 16 * 1024)
                record.update(candidate_file="candidate.mp4", sha256=verified["sha256"],
                              media=verified["media"], media_verified=True)
                _write_result(run_dir / "result.json", record)
                return 0
            finally:
                os.chdir(previous_cwd)
    except (OSError, ValueError, RuntimeError, ImportError, InterruptedError) as error:
        record["media_verified"] = False
        record["error"] = {"type": type(error).__name__, "message": str(error)[:2048]}
        if safe_to_write and not os.path.lexists(run_dir / "result.json"):
            _write_result(run_dir / "result.json", record)
        print(f"Video App driver failed: {type(error).__name__}: {error}", file=sys.stderr, flush=True)
        return 2


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("request", "pack", "ffmpeg", "ffprobe"):
        parser.add_argument("--" + name, required=True)
    for name in ("h3-engine", "h3-shader", "access-manifest", "access-run-id"):
        parser.add_argument("--" + name)
    args = parser.parse_args(argv)
    try:
        return run(args)
    except (OSError, ValueError, RuntimeError) as error:
        print(f"Video App driver rejected input: {type(error).__name__}: {error}", file=sys.stderr, flush=True)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
