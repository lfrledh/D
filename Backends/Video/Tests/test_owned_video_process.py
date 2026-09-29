"""CPU-only process ownership checks. Set VIDEO_PROCESS_TEST_TMPDIR explicitly."""

import hashlib
import errno
import os
from pathlib import Path
import signal
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Adapters"))
import owned_video_process as process_module  # noqa: E402
from owned_video_process import run_owned  # noqa: E402


class OwnedVideoProcessTests(unittest.TestCase):
    def setUp(self):
        task_tmp = os.environ["VIDEO_PROCESS_TEST_TMPDIR"]
        self.assertTrue(os.path.isabs(task_tmp) and os.path.isdir(task_tmp))
        self.temp = tempfile.TemporaryDirectory(prefix="视频 空格 ", dir=task_tmp)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.groups = []
        self.addCleanup(self._reap_test_groups)

    def _reap_test_groups(self):
        for path in self.groups:
            if path.exists():
                try:
                    os.killpg(int(path.read_text().split()[0]), signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def _run(self, script, *, log_name="logs", timeout=5, grace=0.15,
             event=None, extra=(), overrides=None):
        log_dir = self.root / log_name
        log_dir.mkdir(exist_ok=True)
        options = dict(
            argv=[sys.executable, "-c", script, *map(str, extra)],
            cwd=str(self.root), environment={"PYTHONDONTWRITEBYTECODE": "1"},
            log_directory=str(log_dir), timeout_seconds=timeout,
            grace_seconds=grace, cancel_event=event or threading.Event(),
        )
        if overrides:
            options.update(overrides)
        return run_owned(**options)

    def test_exit_zero_with_stderr_and_unicode_space_directory(self):
        result = self._run(
            "import os,sys; print(os.getcwd()); print('diagnostic', file=sys.stderr)"
        )
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["exit_code"], 0)
        self.assertIn(str(self.root).encode(), Path(result["stdout_log"]).read_bytes())
        self.assertEqual(Path(result["stderr_log"]).read_bytes(), b"diagnostic\n")
        self.assertFalse(result["stdout_truncated"])
        self.assertFalse(result["stderr_truncated"])

    def test_nonzero_exit_is_failed(self):
        result = self._run("import sys; sys.exit(7)")
        self.assertEqual((result["status"], result["exit_code"]), ("failed", 7))

    def test_both_pipes_are_drained_and_logs_are_capped(self):
        script = (
            "import os\n"
            "for _ in range(300):\n"
            " os.write(1, b'a'*65536)\n"
            " os.write(2, b'b'*65536)\n"
        )
        result = self._run(script, timeout=15)
        self.assertEqual(result["status"], "success")
        self.assertTrue(result["stdout_truncated"])
        self.assertTrue(result["stderr_truncated"])
        self.assertEqual(Path(result["stdout_log"]).stat().st_size, 16 * 1024 * 1024)
        self.assertEqual(Path(result["stderr_log"]).stat().st_size, 16 * 1024 * 1024)

    def test_timeout_reaps_child(self):
        pidfile = self.root / "group.pid"
        self.groups.append(pidfile)
        script = "import os,sys,time; open(sys.argv[1], 'w').write(str(os.getpid())); time.sleep(60)"
        result = self._run(script, timeout=0.3, extra=(pidfile,))
        self.assertEqual(result["status"], "timed_out")
        self.assertTrue(pidfile.exists())
        with self.assertRaises(ProcessLookupError):
            os.killpg(int(pidfile.read_text()), 0)

    def test_event_cancels_owned_group(self):
        event = threading.Event()
        timer = threading.Timer(0.25, event.set)
        timer.start()
        try:
            result = self._run("import time; time.sleep(60)", event=event)
        finally:
            timer.join(timeout=2)
        self.assertEqual(result["status"], "cancelled")
        self.assertTrue(result["started"])

    def test_pre_cancel_does_not_start_child_or_create_logs(self):
        marker = self.root / "must-not-start"
        event = threading.Event()
        event.set()
        script = "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('started')"
        result = self._run(script, event=event, extra=(marker,))
        self.assertEqual(result, {
            "status": "cancelled",
            "started": False,
            "exit_code": None,
            "stdout_log": None,
            "stderr_log": None,
            "stdout_truncated": False,
            "stderr_truncated": False,
            "elapsed_seconds": 0.0,
        })
        self.assertFalse(marker.exists())
        self.assertEqual(list((self.root / "logs").iterdir()), [])

    def test_cancel_after_second_log_open_keeps_empty_logs_without_start(self):
        marker = self.root / "must-not-start-after-logs"
        event = threading.Event()
        real_open = os.open
        opened = []

        def open_and_cancel(path, flags, mode=0o777):
            fd = real_open(path, flags, mode)
            if str(path).endswith(("stdout.log", "stderr.log")):
                opened.append(str(path))
            if str(path).endswith("stderr.log"):
                event.set()
            return fd

        script = "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('started')"
        with mock.patch.object(process_module.os, "open", side_effect=open_and_cancel):
            result = self._run(script, event=event, extra=(marker,))
        self.assertTrue(event.is_set())
        self.assertEqual(len(opened), 2)
        self.assertEqual(result["status"], "cancelled")
        self.assertFalse(result["started"])
        self.assertIsNone(result["exit_code"])
        self.assertFalse(result["stdout_truncated"])
        self.assertFalse(result["stderr_truncated"])
        self.assertEqual(result["stdout_log"], str(self.root / "logs" / "stdout.log"))
        self.assertEqual(result["stderr_log"], str(self.root / "logs" / "stderr.log"))
        self.assertEqual(Path(result["stdout_log"]).read_bytes(), b"")
        self.assertEqual(Path(result["stderr_log"]).read_bytes(), b"")
        self.assertFalse(marker.exists())

    def test_event_observed_at_child_exit_is_cancelled(self):
        event = threading.Event()
        real_group_alive = process_module._group_alive

        def observe_exit(pgid):
            alive = real_group_alive(pgid)
            if not alive:
                event.set()
            return alive

        with mock.patch.object(process_module, "_group_alive", side_effect=observe_exit):
            result = self._run("pass", event=event)
        self.assertTrue(event.is_set())
        self.assertTrue(result["started"])
        self.assertEqual(result["status"], "cancelled")
        self.assertEqual(result["exit_code"], 0)

    def test_ignored_term_in_parent_and_child_gets_kill(self):
        pidfile = self.root / "group.pids"
        self.groups.append(pidfile)
        script = (
            "import os,signal,subprocess,sys,time\n"
            "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "child='import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)'\n"
            "p=subprocess.Popen([sys.executable, '-c', child])\n"
            "open(sys.argv[1], 'w').write(f'{os.getpid()} {p.pid}')\n"
            "time.sleep(60)\n"
        )
        result = self._run(script, timeout=0.4, grace=0.15, extra=(pidfile,))
        self.assertEqual(result["status"], "timed_out")
        parent, child = map(int, pidfile.read_text().split())
        with self.assertRaises(ProcessLookupError):
            os.killpg(parent, 0)
        with self.assertRaises(ProcessLookupError):
            os.kill(child, 0)

    def test_parent_exits_but_descendant_is_reaped_and_not_success(self):
        pidfile = self.root / "early-parent.pids"
        self.groups.append(pidfile)
        script = (
            "import os,subprocess,sys\n"
            "p=subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])\n"
            "open(sys.argv[1], 'w').write(f'{os.getpid()} {p.pid}')\n"
        )
        result = self._run(script, timeout=3, grace=0.1, extra=(pidfile,))
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["exit_code"], 0)
        parent, child = map(int, pidfile.read_text().split())
        with self.assertRaises(ProcessLookupError):
            os.killpg(parent, 0)
        with self.assertRaises(ProcessLookupError):
            os.kill(child, 0)

    def test_parent_exits_with_silent_descendant_still_fails(self):
        pidfile = self.root / "silent-descendant.pids"
        self.groups.append(pidfile)
        script = (
            "import os,subprocess,sys\n"
            "p=subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'], "
            "stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)\n"
            "open(sys.argv[1], 'w').write(f'{os.getpid()} {p.pid}')\n"
        )
        result = self._run(script, timeout=3, grace=0.1, extra=(pidfile,))
        self.assertEqual(result["status"], "failed")
        parent, child = map(int, pidfile.read_text().split())
        with self.assertRaises(ProcessLookupError):
            os.killpg(parent, 0)
        with self.assertRaises(ProcessLookupError):
            os.kill(child, 0)

    def test_log_write_failure_reaps_owned_group_and_raises(self):
        pidfile = self.root / "write-failure.pids"
        ready = self.root / "descendant-ready"
        burst_done = self.root / "stderr-drained"
        self.groups.append(pidfile)
        child_script = (
            "import os,signal,sys,time; "
            "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
            "open(sys.argv[1], 'w').write('ready'); time.sleep(0.1); "
            "[os.write(2, b'e'*65536) for _ in range(8)]; "
            "open(sys.argv[2], 'w').write('drained'); time.sleep(60)"
        )
        script = (
            "import os,signal,subprocess,sys,time\n"
            f"child={child_script!r}\n"
            "p=subprocess.Popen([sys.executable, '-c', child, sys.argv[2], sys.argv[3]])\n"
            "while not os.path.exists(sys.argv[2]): time.sleep(0.005)\n"
            "open(sys.argv[1], 'w').write(f'{os.getpid()} {p.pid}')\n"
            "os.write(1, b'output')\n"
        )
        real_open = os.open
        opened_log_fds = []

        def track_log_open(path, flags, mode=0o777):
            fd = real_open(path, flags, mode)
            if str(path).endswith(("stdout.log", "stderr.log")):
                opened_log_fds.append(fd)
            return fd

        with mock.patch.object(process_module.os, "open", side_effect=track_log_open):
            with mock.patch.object(process_module, "_write_limited", side_effect=OSError("disk full")):
                with self.assertRaisesRegex(OSError, "disk full"):
                    self._run(script, timeout=2, grace=0.5, extra=(pidfile, ready, burst_done))
        self.assertEqual(burst_done.read_text(), "drained")
        self.assertEqual(len(opened_log_fds), 2)
        for fd in opened_log_fds:
            with self.assertRaises(OSError) as caught:
                os.fstat(fd)
            self.assertEqual(caught.exception.errno, errno.EBADF)
        parent, child = map(int, pidfile.read_text().split())
        with self.assertRaises(ProcessLookupError):
            os.killpg(parent, 0)
        with self.assertRaises(ProcessLookupError):
            os.kill(child, 0)

    def test_cleanup_exception_still_closes_both_log_fds(self):
        pidfile = self.root / "cleanup-error.pid"
        self.groups.append(pidfile)
        script = (
            "import os,sys,time; "
            "open(sys.argv[1], 'w').write(str(os.getpid())); "
            "os.write(1, b'output'); time.sleep(60)"
        )
        real_open = os.open
        real_drain = process_module._drain_after_error
        opened_log_fds = []

        def track_log_open(path, flags, mode=0o777):
            fd = real_open(path, flags, mode)
            if str(path).endswith(("stdout.log", "stderr.log")):
                opened_log_fds.append(fd)
            return fd

        def fail_after_complete_drain(process, grace):
            real_drain(process, grace)
            raise process_module.ProcessCleanupError("simulated cleanup report failure")

        with mock.patch.object(process_module.os, "open", side_effect=track_log_open):
            with mock.patch.object(process_module, "_write_limited", side_effect=OSError("disk full")):
                with mock.patch.object(process_module, "_drain_after_error", side_effect=fail_after_complete_drain):
                    with self.assertRaises(process_module.ProcessCleanupError) as caught:
                        self._run(script, extra=(pidfile,))
        self.assertIsInstance(caught.exception.original_error, OSError)
        self.assertIn("disk full", str(caught.exception.original_error))
        self.assertEqual(len(opened_log_fds), 2)
        for fd in opened_log_fds:
            with self.assertRaises(OSError) as closed:
                os.fstat(fd)
            self.assertEqual(closed.exception.errno, errno.EBADF)
        with self.assertRaises(ProcessLookupError):
            os.killpg(int(pidfile.read_text()), 0)

    def test_existing_logs_and_symlinks_remain_unchanged(self):
        for name in ("stdout.log", "stderr.log"):
            with self.subTest(name=name):
                log_dir = self.root / f"existing-{name}"
                log_dir.mkdir()
                protected = log_dir / name
                protected.write_bytes(b"personal content")
                before = hashlib.sha256(protected.read_bytes()).hexdigest()
                with self.assertRaises(FileExistsError):
                    self._run("print('not run')", log_name=log_dir.name)
                self.assertEqual(hashlib.sha256(protected.read_bytes()).hexdigest(), before)
                self.assertFalse((log_dir / ("stderr.log" if name == "stdout.log" else "stdout.log")).exists())
        log_dir = self.root / "symlink"
        log_dir.mkdir()
        target = self.root / "protected.txt"
        target.write_bytes(b"sentinel")
        (log_dir / "stderr.log").symlink_to(target)
        with self.assertRaises(FileExistsError):
            self._run("print('not run')", log_name=log_dir.name)
        self.assertEqual(target.read_bytes(), b"sentinel")
        self.assertTrue((log_dir / "stderr.log").is_symlink())
        self.assertFalse((log_dir / "stdout.log").exists())

    def test_invalid_configuration_does_not_create_logs(self):
        cases = (
            {"argv": []},
            {"argv": ["python", "-c", "pass"]},
            {"argv": [sys.executable, "bad\x00arg"]},
            {"environment": {"BAD=KEY": "value"}},
            {"environment": {"KEY": "bad\x00value"}},
            {"environment": None},
            {"cwd": "relative"},
            {"log_directory": "relative"},
            {"timeout_seconds": True},
            {"timeout_seconds": float("nan")},
            {"grace_seconds": float("inf")},
            {"cancel_event": None},
        )
        for index, overrides in enumerate(cases):
            with self.subTest(index=index):
                log_dir = self.root / f"invalid-{index}"
                with self.assertRaises(ValueError):
                    self._run("pass", log_name=log_dir.name, overrides=overrides)
                self.assertEqual(list(log_dir.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
