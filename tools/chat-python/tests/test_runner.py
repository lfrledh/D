"""Fixed WASI boundary probes for F28-CAPI-1; these are not CPython tests."""
import ctypes
import os
from pathlib import Path
import select
import signal
import subprocess
import tempfile
import time
import unittest


RUN = Path(os.environ["F28_RUNNER"])
LIB = ctypes.CDLL(os.environ["F28_WASMTIME_LIB"])
TMP = Path(os.environ["F28_TMP"])


class ByteVec(ctypes.Structure):
    _fields_ = [("size", ctypes.c_size_t), ("data", ctypes.c_void_p)]


LIB.wasmtime_wat2wasm.argtypes = [ctypes.c_char_p, ctypes.c_size_t,
                                 ctypes.POINTER(ByteVec)]
LIB.wasmtime_wat2wasm.restype = ctypes.c_void_p
LIB.wasm_byte_vec_delete.argtypes = [ctypes.POINTER(ByteVec)]
LIB.wasmtime_error_delete.argtypes = [ctypes.c_void_p]


def wasm(wat):
    source = wat.encode()
    result = ByteVec()
    err = LIB.wasmtime_wat2wasm(source, len(source), ctypes.byref(result))
    if err:
        LIB.wasmtime_error_delete(err)
        raise AssertionError("fixed WAT did not compile")
    try:
        return ctypes.string_at(result.data, result.size)
    finally:
        LIB.wasm_byte_vec_delete(ctypes.byref(result))


def module(body, imports=""):
    return wasm(f'(module {imports} (memory (export "memory") 1) {body})')


WRITE = '''(import "wasi_snapshot_preview1" "fd_write"
    (func $write (param i32 i32 i32 i32) (result i32)))'''
EXIT = '''(import "wasi_snapshot_preview1" "proc_exit"
    (func $exit (param i32)))'''
OPEN = '''(import "wasi_snapshot_preview1" "path_open"
    (func $open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))'''


class Runner(unittest.TestCase):
    def setUp(self):
        self.space = tempfile.TemporaryDirectory(dir=TMP)
        self.addCleanup(self.space.cleanup)
        self.base = Path(self.space.name)
        self.runtime = self.base / "runtime"
        self.inputs = self.base / "inputs"
        self.runtime.mkdir()
        self.inputs.mkdir()
        (self.inputs / "program.py").write_text("print('not executed by fixture')\n")

    def install(self, contents):
        (self.runtime / "python.wasm").write_bytes(contents)

    def run_guest(self, *extra, env=None, timeout=8):
        cmd = [str(RUN), "--runtime", str(self.runtime),
               "--inputs", str(self.inputs), *extra]
        return subprocess.run(cmd, capture_output=True, timeout=timeout, env=env)

    def run_with_closed_output(self, fd):
        read_fd, write_fd = os.pipe()
        os.close(read_fd)
        proc = None
        try:
            proc = subprocess.Popen(
                [str(RUN), "--runtime", str(self.runtime),
                 "--inputs", str(self.inputs)],
                stdout=write_fd if fd == 1 else subprocess.PIPE,
                stderr=write_fd if fd == 2 else subprocess.PIPE)
            os.close(write_fd)
            write_fd = -1
            stdout, stderr = proc.communicate(timeout=8)
            return proc.returncode, stdout, stderr
        finally:
            if write_fd >= 0:
                os.close(write_fd)
            if proc is not None and proc.poll() is None:
                proc.kill()
                proc.wait(timeout=5)

    def test_success_stdout_stderr_and_cli(self):
        self.install(module('''
          (data (i32.const 0) "ok\\0aerr\\0a")
          (func (export "_start")
            (i32.store (i32.const 32) (i32.const 0))
            (i32.store (i32.const 36) (i32.const 3))
            (drop (call $write (i32.const 1) (i32.const 32) (i32.const 1) (i32.const 44)))
            (i32.store (i32.const 32) (i32.const 3))
            (i32.store (i32.const 36) (i32.const 4))
            (drop (call $write (i32.const 2) (i32.const 32) (i32.const 1) (i32.const 44))))
        ''', WRITE))
        result = self.run_guest()
        self.assertEqual((result.returncode, result.stdout, result.stderr),
                         (0, b"ok\n", b"err\n"))
        regular_output = self.base / "stdout.txt"
        with regular_output.open("wb") as destination:
            result = subprocess.run(
                [str(RUN), "--runtime", str(self.runtime),
                 "--inputs", str(self.inputs)],
                stdout=destination, stderr=subprocess.PIPE, timeout=8)
        self.assertEqual((result.returncode, regular_output.read_bytes(),
                          result.stderr), (0, b"ok\n", b"err\n"))
        for args in [("--fuel", "0"), ("--fuel", "5000000001"),
                     ("--timeout-ms", "30001"), ("--memory-mib", "15"),
                     ("--bad", "1"), ("--runtime", str(self.runtime)),
                     ("--inputs", str(self.runtime)), ("--fuel", "1", "--fuel", "1")]:
            self.assertEqual(self.run_guest(*args).returncode, 2, args)

    def test_bad_module_and_symlink_input(self):
        self.install(b"bad wasm")
        self.assertEqual(self.run_guest().returncode, 2)
        self.install(module('(func (export "_start"))'))
        (self.inputs / "link").symlink_to(self.base / "outside")
        self.assertEqual(self.run_guest().returncode, 2)

    def test_no_inherited_environment(self):
        imports = '''(import "wasi_snapshot_preview1" "environ_sizes_get"
            (func $sizes (param i32 i32) (result i32)))'''
        self.install(module('''(func (export "_start")
            (drop (call $sizes (i32.const 0) (i32.const 4)))
            (if (i32.ne (i32.load (i32.const 0)) (i32.const 2))
                (then unreachable)))''', imports))
        env = dict(os.environ, F28_SECRET_SENTINEL="private host value")
        self.assertEqual(self.run_guest(env=env).returncode, 0)

    def test_no_parent_or_host_path_and_readonly_mounts(self):
        # Inputs is the second preopen, at fd 4. Both absolute and parent paths fail.
        (self.runtime / "guard").write_text("intact")
        self.install(module('''
          (data (i32.const 0) "../outside/secret")
          (data (i32.const 40) "/etc/passwd")
          (data (i32.const 80) "program.py")
          (data (i32.const 100) "guard")
          (func (export "_start")
            (if (i32.eqz (call $open (i32.const 4) (i32.const 0)
                (i32.const 0) (i32.const 17) (i32.const 0)
                (i64.const 2) (i64.const 0) (i32.const 0) (i32.const 160)))
                (then unreachable))
            (if (i32.eqz (call $open (i32.const 4) (i32.const 0)
                (i32.const 40) (i32.const 11) (i32.const 0)
                (i64.const 2) (i64.const 0) (i32.const 0) (i32.const 160)))
                (then unreachable))
            (if (i32.eqz (call $open (i32.const 4) (i32.const 0)
                (i32.const 80) (i32.const 10) (i32.const 1)
                (i64.const 64) (i64.const 0) (i32.const 0) (i32.const 160)))
                (then unreachable))
            (if (i32.eqz (call $open (i32.const 3) (i32.const 0)
                (i32.const 100) (i32.const 5) (i32.const 0)
                (i64.const 64) (i64.const 0) (i32.const 0) (i32.const 160)))
                (then unreachable)))
        ''', OPEN))
        (self.base / "outside").mkdir()
        (self.base / "outside" / "secret").write_text("private")
        self.assertEqual(self.run_guest().returncode, 0)
        self.assertEqual((self.base / "outside" / "secret").read_text(), "private")
        self.assertEqual((self.runtime / "guard").read_text(), "intact")

    def test_nonzero_guest_exit(self):
        self.install(module('''(func (export "_start")
            (call $exit (i32.const 9)))''', EXIT))
        self.assertEqual(self.run_guest().returncode, 3)

    def test_no_socket_import(self):
        self.install(wasm('''(module
            (import "wasi_snapshot_preview1" "sock_open"
                (func $sock (param i32) (result i32)))
            (func (export "_start")))'''))
        self.assertNotEqual(self.run_guest().returncode, 0)

    def test_fuel_memory_and_timeout(self):
        self.install(module('''(func (export "_start") (loop $again (br $again)))'''))
        self.assertEqual(self.run_guest("--fuel", "1000").returncode, 4)
        self.assertEqual(self.run_guest("--timeout-ms", "25", timeout=4).returncode, 5)
        self.install(module('''(func (export "_start")
          (if (i32.eq (memory.grow (i32.const 512)) (i32.const -1))
            (then unreachable)))'''))
        self.assertNotEqual(self.run_guest("--memory-mib", "16").returncode, 0)

    def test_output_overflow_even_when_guest_catches_io(self):
        self.install(module('''
          (data (i32.const 0) "x")
          (func (export "_start") (local $n i32)
            (i32.store (i32.const 32) (i32.const 0))
            (i32.store (i32.const 36) (i32.const 65536))
            (loop $again
              (drop (call $write (i32.const 1) (i32.const 32)
                                  (i32.const 1) (i32.const 44)))
              (local.set $n (i32.add (local.get $n) (i32.const 1)))
              (br_if $again (i32.lt_u (local.get $n) (i32.const 17)))))
        ''', WRITE))
        result = self.run_guest(timeout=5)
        self.assertEqual(result.returncode, 4)
        self.assertLessEqual(len(result.stdout) + len(result.stderr), 1048600)

    def test_closed_stdout_reports_io_error_after_full_wait(self):
        self.install(module('''
          (data (i32.const 0) "out")
          (func (export "_start")
            (i32.store (i32.const 32) (i32.const 0))
            (i32.store (i32.const 36) (i32.const 3))
            (drop (call $write (i32.const 1) (i32.const 32)
                               (i32.const 1) (i32.const 44))))
        ''', WRITE))
        status, _, stderr = self.run_with_closed_output(1)
        self.assertEqual((status, stderr), (2, b"runner setup error\n"))

    def test_closed_stderr_preserves_io_and_guest_status_after_full_wait(self):
        self.install(module('''
          (data (i32.const 0) "err")
          (func (export "_start")
            (i32.store (i32.const 32) (i32.const 0))
            (i32.store (i32.const 36) (i32.const 3))
            (drop (call $write (i32.const 2) (i32.const 32)
                               (i32.const 1) (i32.const 44))))
        ''', WRITE))
        status, stdout, _ = self.run_with_closed_output(2)
        self.assertEqual((status, stdout), (2, b""))
        self.install(module('''(func (export "_start")
            (call $exit (i32.const 9)))''', EXIT))
        status, stdout, _ = self.run_with_closed_output(2)
        self.assertEqual((status, stdout), (3, b""))

    def test_sigterm_unwinds_and_next_call(self):
        self.install(module('''
          (data (i32.const 0) "ready")
          (func (export "_start")
            (i32.store (i32.const 32) (i32.const 0))
            (i32.store (i32.const 36) (i32.const 5))
            (drop (call $write (i32.const 1) (i32.const 32)
                               (i32.const 1) (i32.const 44)))
            (loop $again (br $again)))''', WRITE))
        proc = subprocess.Popen([str(RUN), "--runtime", str(self.runtime),
                                 "--inputs", str(self.inputs)],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.assertTrue(select.select([proc.stdout], [], [], 5)[0])
            self.assertEqual(proc.stdout.read(5), b"ready")
            self.assertIsNone(proc.poll())
            proc.send_signal(signal.SIGTERM)
            proc.communicate(timeout=5)
            self.assertEqual(proc.returncode, 6)
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=5)
        self.install(module('(func (export "_start"))'))
        self.assertEqual(self.run_guest().returncode, 0)

    def test_sigterm_with_blocked_stdout_unwinds(self):
        # One callback writes exactly the allowed output budget. The parent
        # waits for full process exit before it drains the stdout pipe.
        self.install(wasm('''(module
          (import "wasi_snapshot_preview1" "fd_write"
            (func $write (param i32 i32 i32 i32) (result i32)))
          (memory (export "memory") 17)
          (func (export "_start")
            (i32.store (i32.const 0) (i32.const 64))
            (i32.store (i32.const 4) (i32.const 1048576))
            (drop (call $write (i32.const 1) (i32.const 0)
                               (i32.const 1) (i32.const 8)))))'''))
        proc = subprocess.Popen([str(RUN), "--runtime", str(self.runtime),
                                 "--inputs", str(self.inputs)],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.assertTrue(select.select([proc.stdout], [], [], 5)[0])
            time.sleep(0.05)
            self.assertIsNone(proc.poll(), "guest exited before cancellation")
            proc.send_signal(signal.SIGTERM)
            proc.wait(timeout=5)
            stdout, _ = proc.communicate(timeout=2)
            self.assertEqual(proc.returncode, 6)
            self.assertGreater(len(stdout), 0)
            self.assertLessEqual(len(stdout), 1048576)
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
