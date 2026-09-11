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
TASK_TMP = Path("/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-AUDIO-APP-01/run-20260911T125328Z/pack/tmp")


def digest_tree(root: Path) -> dict[str, str]:
    return {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(root.rglob("*")) if path.is_file()}


class EnginePackagingTests(unittest.TestCase):
    def setUp(self) -> None:
        TASK_TMP.mkdir(parents=True, exist_ok=True)
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
        (self.python_root / "lib/python3.12/site-packages").mkdir(parents=True)
        (self.python_root / "lib/python3.12/LICENSE.txt").write_text("PSF", encoding="utf-8")
        (self.python_root / "lib/python3.12/os.py").write_text("stdlib", encoding="utf-8")
        self.site.mkdir(parents=True)
        for package in ("mlx", "mlx_metal", "numpy", "sentencepiece"):
            (self.site / package).mkdir()
            (self.site / package / "component.txt").write_text(package, encoding="utf-8")
            (self.site / f"{package}-1.0.dist-info").mkdir()
            (self.site / f"{package}-1.0.dist-info/LICENSE").write_text("license", encoding="utf-8")
        (self.site / "numpy.libs").mkdir()
        (self.site / "numpy.libs/data").write_text("native", encoding="utf-8")
        (self.site / "pip").mkdir()
        (self.site / "setuptools-1.dist-info").mkdir()
        self.provider.mkdir()
        (self.provider / "d_audio_backend.py").write_text("# backend", encoding="utf-8")
        (self.provider / "d_audio_contract.py").write_text("# contract", encoding="utf-8")
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
        return subprocess.run(self.command(output), text=True, capture_output=True, env=environment, check=False)

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

    def test_rejections_leave_output_unpublished(self) -> None:
        cases: list[tuple[str, callable]] = [
            ("unknown component", lambda: (self.site / "plugin").mkdir()),
            ("symlink", lambda: (self.vendor / "link").symlink_to(self.vendor / "LICENSE")),
            ("special file", lambda: os.mkfifo(self.vendor / "pipe")),
            ("missing interpreter", lambda: (self.python_root / "bin/python3.12").unlink()),
        ]
        for label, arrange in cases:
            with self.subTest(label):
                arrange()
                output = self.base / ("bad-" + label)
                result = self.run_cli(output)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertFalse(os.path.lexists(output))

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
        # A root-capable fixture host may bypass directory modes; exercise the CLI's existing-output guard too.
        if result.returncode == 0:
            shutil.rmtree(output)
        else:
            self.assertEqual(result.returncode, 2)
        # Wait for the tool-owned staging directory: output did not exist during validation.
        (self.vendor / "large.bin").write_bytes(b"x" * (16 * 1024 * 1024))
        race = self.base / "race"
        process = subprocess.Popen(self.command(race), text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"))
        for _ in range(200):
            if any(item.name.startswith(".d-audio-engine-") for item in self.base.iterdir()):
                break
            if process.poll() is not None:
                self.fail("packaging completed before publication-race fixture could intervene")
            time.sleep(0.005)
        else:
            process.kill()
            self.fail("tool-owned staging directory was not observed")
        race.mkdir()
        sentinel = race / "sentinel"
        sentinel.write_text("keep", encoding="utf-8")
        stdout, stderr = process.communicate(timeout=15)
        self.assertEqual(process.returncode, 2, stderr + stdout)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep")


if __name__ == "__main__":
    unittest.main()
