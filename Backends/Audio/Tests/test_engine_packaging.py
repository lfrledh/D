"""CPU-only process fixtures for prepare_engine.py; never imports the target."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import tokenize
import unittest


ROOT = Path(__file__).resolve().parents[3]
TARGET = ROOT / "Backends/Audio/Packaging/prepare_engine.py"
TASK_TMP = Path(os.environ["D_TEST_TEMP_DIR"])


def digest_tree(root: Path) -> dict[str, str]:
    return {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(root.rglob("*")) if path.is_file()}


class EnginePackagingTests(unittest.TestCase):
    def setUp(self) -> None:
        if not TASK_TMP.is_dir():
            self.fail("D_TEST_TEMP_DIR must name an existing directory")
        self.temp = tempfile.TemporaryDirectory(dir=TASK_TMP)
        self.base = Path(self.temp.name)
        self.python_root = self.base / "Python Root"
        self.site = self.base / "venv/lib/python3.12/site-packages"
        self.provider = self.base / "provider"
        self.vendor = self.base / "vendor"
        self.models = self.base / "models"
        (self.python_root / "bin").mkdir(parents=True)
        executable = self.python_root / "bin/python3.12"
        executable.write_text("fixture interpreter", encoding="utf-8")
        executable.chmod(0o755)
        (self.python_root / "bin/python3").symlink_to("python3.12")
        (self.python_root / "lib/python3.12/site-packages").mkdir(parents=True)
        (self.python_root / "lib/python3.12/LICENSE.txt").write_text("PSF", encoding="utf-8")
        (self.python_root / "lib/python3.12/os.py").write_text("stdlib", encoding="utf-8")
        (self.python_root / "lib/python3.12/encodings").mkdir()
        (self.python_root / "lib/python3.12/encodings/__init__.py").write_text("encoding", encoding="utf-8")
        self.site.mkdir(parents=True)
        for package in ("mlx", "numpy", "sentencepiece"):
            (self.site / package).mkdir()
            (self.site / package / "component.txt").write_text(package, encoding="utf-8")
            (self.site / f"{package}-1.0.dist-info").mkdir()
            (self.site / f"{package}-1.0.dist-info/LICENSE").write_text("license", encoding="utf-8")
        (self.site / "mlx_metal-1.0.dist-info").mkdir()
        (self.site / "mlx_metal-1.0.dist-info/LICENSE").write_text("license", encoding="utf-8")
        (self.site / "numpy.libs").mkdir()
        (self.site / "numpy.libs/data").write_text("native", encoding="utf-8")
        (self.site / "pip").mkdir()
        (self.site / "setuptools-1.dist-info").mkdir()
        self.provider.mkdir()
        (self.provider / "d_audio_backend.py").write_text("# backend", encoding="utf-8")
        (self.provider / "d_audio_contract.py").write_text("# contract", encoding="utf-8")
        (self.provider / "d_audio_sa3.py").write_text("# sa3", encoding="utf-8")
        self.vendor.mkdir()
        (self.vendor / "LICENSE").write_text("vendor", encoding="utf-8")
        self.models.mkdir()
        (self.models / "音楽 manifest.json").write_text("{}", encoding="utf-8")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def command(self, output: Path) -> list[str]:
        return [sys.executable, "-B", str(TARGET), "--python-root", str(self.python_root), "--site-packages", str(self.site), "--provider-directory", str(self.provider), "--vendor-directory", str(self.vendor), "--model-manifests", str(self.models), "--output", str(output)]

    def run_cli(self, output: Path) -> subprocess.CompletedProcess[str]:
        environment = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
        return subprocess.run(self.command(output), text=True, capture_output=True, env=environment, check=False, timeout=15)

    def test_syntax_without_import(self) -> None:
        with tokenize.open(TARGET) as handle:
            source = handle.read()
        compile(source, str(TARGET), "exec", dont_inherit=True)

    def test_normal_layout_manifest_unicode_and_determinism(self) -> None:
        source_roots = (self.python_root, self.site, self.provider, self.vendor, self.models)
        before = [digest_tree(root) for root in source_roots]
        first = self.base / "out one"
        result = self.run_cli(first)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("unverified", result.stdout)
        self.assertTrue((first / "python/bin/python3").is_file())
        self.assertFalse((first / "python/lib/python3.12/site-packages/pip").exists())
        self.assertFalse((first / "python/lib/python3.12/site-packages/mlx_metal").exists())
        self.assertTrue((first / "python/lib/python3.12/LICENSE.txt").is_file())
        manifest = json.loads((first / "engine.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["pythonExecutable"], "python/bin/python3")
        paths = [item["path"] for item in manifest["files"]]
        self.assertEqual(paths, sorted(paths))
        self.assertNotIn("engine.json", paths)
        self.assertIn("model-manifests/音楽 manifest.json", paths)
        second = self.base / "out two"
        self.assertEqual(self.run_cli(second).returncode, 0)
        self.assertEqual((first / "engine.json").read_bytes(), (second / "engine.json").read_bytes())
        self.assertEqual(before, [digest_tree(root) for root in source_roots])

    def test_stdout_readonly_returns_two_after_publication(self) -> None:
        output = self.base / "readonly-stdout"
        readonly = self.base / "stdout.txt"
        readonly.write_text("", encoding="utf-8")
        descriptor = os.open(readonly, os.O_RDONLY)
        process = subprocess.Popen(self.command(output), stdout=descriptor, stderr=subprocess.PIPE, text=True,
                                   env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"))
        try:
            _stdout, stderr = process.communicate(timeout=15)
            self.assertEqual(process.returncode, 2, stderr)
            self.assertTrue(output.is_dir())
        finally:
            os.close(descriptor)
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=15)

    def test_stderr_readonly_failure_returns_two(self) -> None:
        output = self.base / "existing-output"
        output.mkdir()
        readonly = self.base / "stderr.txt"
        readonly.write_text("", encoding="utf-8")
        descriptor = os.open(readonly, os.O_RDONLY)
        process = subprocess.Popen(self.command(output), stdout=subprocess.PIPE, stderr=descriptor, text=True,
                                   env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"))
        try:
            stdout, _stderr = process.communicate(timeout=15)
            self.assertEqual(process.returncode, 2, stdout)
            self.assertTrue(output.is_dir())
        finally:
            os.close(descriptor)
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=15)

    def assert_rejected(self, output: Path) -> None:
        result = self.run_cli(output)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertFalse(os.path.lexists(output))

    def test_missing_interpreter_is_refused(self) -> None:
        (self.python_root / "bin/python3.12").unlink()
        self.assert_rejected(self.base / "bad-interpreter")

    def test_unknown_site_component_is_refused(self) -> None:
        (self.site / "plugin").mkdir()
        self.assert_rejected(self.base / "bad-component")

    def test_symlink_is_refused(self) -> None:
        (self.vendor / "link").symlink_to(self.vendor / "LICENSE")
        self.assert_rejected(self.base / "bad-symlink")

    def test_special_file_is_refused(self) -> None:
        os.mkfifo(self.vendor / "pipe")
        self.assert_rejected(self.base / "bad-special")

    def test_symlink_ancestor_is_refused(self) -> None:
        linked_parent = self.base / "linked-parent"
        linked_parent.symlink_to(self.base, target_is_directory=True)
        output = linked_parent / "output"
        self.assert_rejected(output)

    def test_stdlib_symlink_ancestor_is_refused(self) -> None:
        original = self.python_root / "lib"
        actual = self.base / "actual-lib"
        shutil.move(original, actual)
        original.symlink_to("../actual-lib", target_is_directory=True)
        self.assert_rejected(self.base / "bad-stdlib-ancestor")

    def test_required_package_file_is_refused(self) -> None:
        shutil.rmtree(self.site / "mlx")
        (self.site / "mlx").write_text("not a package directory", encoding="utf-8")
        self.assert_rejected(self.base / "bad-package-file")

    def test_output_overlap_existing_and_dangling_are_refused(self) -> None:
        overlap = self.python_root / "inside"
        result = self.run_cli(overlap)
        self.assertEqual(result.returncode, 2)
        exists = self.base / "exists"
        exists.mkdir()
        self.assertEqual(self.run_cli(exists).returncode, 2)
        dangling = self.base / "dangling"
        dangling.symlink_to(self.base / "missing")
        self.assertEqual(self.run_cli(dangling).returncode, 2)

    def test_copy_failure_and_publication_race_do_not_overwrite(self) -> None:
        output = self.base / "copy-failure"
        os.chmod(self.base, 0o555)
        try:
            result = self.run_cli(output)
        finally:
            os.chmod(self.base, 0o755)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertFalse(os.path.lexists(output))
        # Wait for the tool-owned staging directory: output did not exist during validation.
        (self.vendor / "large.bin").write_bytes(b"x" * (16 * 1024 * 1024))
        race = self.base / "race"
        process = subprocess.Popen(self.command(race), text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"))
        try:
            for _ in range(200):
                if any(item.name.startswith(".d-audio-engine-") for item in self.base.iterdir()):
                    break
                if process.poll() is not None:
                    self.fail("packaging completed before publication-race fixture could intervene")
                time.sleep(0.005)
            else:
                self.fail("tool-owned staging directory was not observed")
            race.mkdir()
            sentinel = race / "sentinel"
            sentinel.write_text("keep", encoding="utf-8")
            stdout, stderr = process.communicate(timeout=15)
            self.assertEqual(process.returncode, 2, stderr + stdout)
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep")
        finally:
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=15)

    def test_actual_copy_failure_cleans_staging_and_preserves_input(self) -> None:
        # Real CLI fixture: a task-owned source file becomes unreadable only for copying.
        protected = self.vendor / "LICENSE"
        before = digest_tree(self.vendor)
        original_mode = stat.S_IMODE(protected.stat().st_mode)
        protected.chmod(0)
        output = self.base / "actual-copy-failure"
        try:
            result = self.run_cli(output)
        finally:
            protected.chmod(original_mode)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertFalse(os.path.lexists(output))
        self.assertEqual(before, digest_tree(self.vendor))
        self.assertFalse(any(item.name.startswith(".d-audio-engine-") for item in self.base.iterdir()))


if __name__ == "__main__":
    unittest.main()
