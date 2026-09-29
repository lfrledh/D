"""Run one trusted local video engine and drain its owned process group.

The fixed upstream engines used here do not create detached sessions. A child
that deliberately leaves its process group is outside this ownership boundary.
The caller owns model validation, signal-to-Event handling, and output publish.
"""

import math
import os
import selectors
import signal
import subprocess
import threading
import time


_LOG_LIMIT = 16 * 1024 * 1024
_READ_SIZE = 64 * 1024
_POLL_INTERVAL = 0.05


def _validate(argv, cwd, environment, log_directory, timeout_seconds,
              grace_seconds, cancel_event):
    if not isinstance(argv, list) or not argv or any(
        not isinstance(arg, str) or "\x00" in arg for arg in argv
    ):
        raise ValueError("argv must be a nonempty list of NUL-free strings")
    if not os.path.isabs(argv[0]) or not os.path.isfile(argv[0]) or not os.access(argv[0], os.X_OK):
        raise ValueError("argv[0] must be an absolute executable file")
    for label, path in (("cwd", cwd), ("log_directory", log_directory)):
        if not isinstance(path, str) or "\x00" in path or not os.path.isabs(path) or not os.path.isdir(path):
            raise ValueError(f"{label} must be an absolute existing directory")
    if not isinstance(environment, dict) or any(
        not isinstance(key, str) or not key or "=" in key or "\x00" in key
        or not isinstance(value, str) or "\x00" in value
        for key, value in environment.items()
    ):
        raise ValueError("environment must be an explicit NUL-free string dictionary")
    for label, value in (("timeout_seconds", timeout_seconds), ("grace_seconds", grace_seconds)):
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise ValueError(f"{label} must be finite and positive")
        try:
            valid = math.isfinite(value) and value > 0
        except (OverflowError, ValueError):
            valid = False
        if not valid:
            raise ValueError(f"{label} must be finite and positive")
    if not isinstance(cancel_event, threading.Event):
        raise ValueError("cancel_event must be a threading.Event")


def _group_alive(pgid):
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    return True


def _signal_group(pgid, sig):
    try:
        os.killpg(pgid, sig)
    except ProcessLookupError:
        pass


class ProcessCleanupError(RuntimeError):
    """The owned group or its output pipes could not be confirmed drained."""


def _drain_after_error(process, grace_seconds):
    """Stop the whole owned group and discard both pipes until EOF."""
    with selectors.DefaultSelector() as reader:
        for pipe in (process.stdout, process.stderr):
            if pipe is not None and not pipe.closed:
                os.set_blocking(pipe.fileno(), False)
                reader.register(pipe, selectors.EVENT_READ)

        process.poll()  # Reap an exited parent before probing its group.
        if _group_alive(process.pid):
            _signal_group(process.pid, signal.SIGTERM)
        term_at = time.monotonic()
        killed_at = None
        while True:
            exit_code = process.poll()
            group_alive = _group_alive(process.pid)
            if exit_code is not None and not group_alive and not reader.get_map():
                process.wait()
                return

            now = time.monotonic()
            if killed_at is None and now - term_at >= grace_seconds:
                if group_alive:
                    _signal_group(process.pid, signal.SIGKILL)
                killed_at = now
            elif killed_at is not None and now - killed_at >= 5:
                raise ProcessCleanupError(
                    "owned process group or pipes did not drain after SIGKILL"
                )

            for key, _ in reader.select(_POLL_INTERVAL):
                pipe = key.fileobj
                try:
                    chunk = os.read(pipe.fileno(), _READ_SIZE)
                except BlockingIOError:
                    continue
                if not chunk:
                    reader.unregister(pipe)
                    pipe.close()


def _write_limited(fd, data, written):
    remaining = max(0, _LOG_LIMIT - written)
    saved = min(len(data), remaining)
    offset = 0
    while offset < saved:
        count = os.write(fd, data[offset:saved])
        if count == 0:
            raise OSError("log write made no progress")
        offset += count
    return written + saved, saved < len(data)


def run_owned(argv, *, cwd, environment, log_directory, timeout_seconds,
              grace_seconds, cancel_event) -> dict:
    """Run a local executable with bounded logs, cancellation, and group drain.

    A normal parent exit with inherited descendants is a failed run. This
    function does not validate models or declare produced media usable.
    """
    _validate(argv, cwd, environment, log_directory, timeout_seconds,
              grace_seconds, cancel_event)
    if cancel_event.is_set():
        return {
            "status": "cancelled",
            "started": False,
            "exit_code": None,
            "stdout_log": None,
            "stderr_log": None,
            "stdout_truncated": False,
            "stderr_truncated": False,
            "elapsed_seconds": 0.0,
        }
    stdout_path = os.path.join(log_directory, "stdout.log")
    stderr_path = os.path.join(log_directory, "stderr.log")
    for path in (stdout_path, stderr_path):
        if os.path.lexists(path):
            raise FileExistsError(f"log path already exists: {path}")

    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    stdout_fd = os.open(stdout_path, flags, 0o600)
    try:
        stderr_fd = os.open(stderr_path, flags, 0o600)
    except BaseException:
        os.close(stdout_fd)
        raise

    process = None
    selector = None
    start = time.monotonic()
    written = {"stdout": 0, "stderr": 0}
    truncated = {"stdout": False, "stderr": False}
    reason = None
    term_at = None
    killed_at = None
    primary_error = None
    cleanup_error = None
    close_errors = []
    result = None
    try:
        # Freeze mutable caller inputs before the child is created.
        argv = argv.copy()
        environment = environment.copy()
        if cancel_event.is_set():
            result = {
                "status": "cancelled",
                "started": False,
                "exit_code": None,
                "stdout_log": stdout_path,
                "stderr_log": stderr_path,
                "stdout_truncated": False,
                "stderr_truncated": False,
                "elapsed_seconds": time.monotonic() - start,
            }
        else:
            process = subprocess.Popen(
                argv, shell=False, start_new_session=True, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=cwd,
                env=environment,
            )
            selector = selectors.DefaultSelector()
            for name, pipe in (("stdout", process.stdout), ("stderr", process.stderr)):
                os.set_blocking(pipe.fileno(), False)
                selector.register(pipe, selectors.EVENT_READ, name)

            while True:
                now = time.monotonic()
                exit_code = process.poll()
                group_alive = _group_alive(process.pid)
                if cancel_event.is_set():
                    reason = "cancelled"
                elif reason is None:
                    if exit_code is not None and group_alive:
                        reason = "failed"
                    elif exit_code is None and now - start >= timeout_seconds:
                        reason = "timed_out"

                if reason is not None:
                    if term_at is None:
                        _signal_group(process.pid, signal.SIGTERM)
                        term_at = now
                    elif killed_at is None and now - term_at >= grace_seconds:
                        _signal_group(process.pid, signal.SIGKILL)
                        killed_at = now
                    elif killed_at is not None and now - killed_at >= 5:
                        if group_alive or selector.get_map() or exit_code is None:
                            raise RuntimeError("owned process group or pipes did not drain after SIGKILL")

                if exit_code is not None and not group_alive and not selector.get_map():
                    break

                for key, _ in selector.select(_POLL_INTERVAL):
                    pipe = key.fileobj
                    try:
                        chunk = os.read(pipe.fileno(), _READ_SIZE)
                    except BlockingIOError:
                        continue
                    if not chunk:
                        selector.unregister(pipe)
                        pipe.close()
                        continue
                    name = key.data
                    fd = stdout_fd if name == "stdout" else stderr_fd
                    written[name], overflow = _write_limited(fd, chunk, written[name])
                    truncated[name] |= overflow

            exit_code = process.wait()
            status = "cancelled" if cancel_event.is_set() else reason or (
                "success" if exit_code == 0 else "failed"
            )
            result = {
                "status": status,
                "started": True,
                "exit_code": exit_code,
                "stdout_log": stdout_path,
                "stderr_log": stderr_path,
                "stdout_truncated": truncated["stdout"],
                "stderr_truncated": truncated["stderr"],
                "elapsed_seconds": time.monotonic() - start,
            }
    except BaseException as exc:
        primary_error = exc
        if process is not None:
            try:
                _drain_after_error(process, grace_seconds)
            except BaseException as cleanup_exc:
                cleanup_error = cleanup_exc
    finally:
        if selector is not None:
            try:
                selector.close()
            except BaseException as exc:
                close_errors.append(exc)
        if process is not None:
            for pipe in (process.stdout, process.stderr):
                if pipe is not None:
                    try:
                        pipe.close()
                    except BaseException as exc:
                        close_errors.append(exc)
        for fd in (stdout_fd, stderr_fd):
            try:
                os.close(fd)
            except BaseException as exc:
                close_errors.append(exc)

    if cleanup_error is not None or close_errors:
        failure = ProcessCleanupError("owned process cleanup or FD closure failed")
        failure.original_error = primary_error
        raise failure from (cleanup_error or close_errors[0])
    if primary_error is not None:
        raise primary_error.with_traceback(primary_error.__traceback__)
    return result
