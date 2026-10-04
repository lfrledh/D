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
import unittest


REPOSITORY = Path(__file__).resolve().parents[2]
PREPARE = REPOSITORY / "scripts/prepare-development-resources.py"
EMBED = REPOSITORY / "scripts/embed-development-resources.py"
ENGINE_NAMES = (
    "AudioEngine.dengine",
    "MRT2MusicEngine.dengine",
    "VideoEngine.dengine",
    "PitchEngine.dengine",
)
CONTRACTS = {
    "AudioEngine.dengine": (
        "d-audio-engine", "provider/d_audio_backend.py", "vendor",
        ("python/bin/python3", "provider/d_audio_backend.py", "provider/d_audio_access.py",
         "provider/d_audio_contract.py", "model-manifests/sm-music.json", "provider/d_audio_sa3.py"),
    ),
    "MRT2MusicEngine.dengine": (
        "d-mrt2-music-engine", "provider/d_audio_mrt2_backend.py", "vendor",
        ("python/bin/python3", "provider/d_audio_mrt2_backend.py", "provider/d_audio_access.py",
         "provider/d_audio_contract.py", "model-manifests/mrt2-small.json",
         "provider/d_audio_mrt2_contract.py", "provider/d_mrt2_export.py"),
    ),
    "VideoEngine.dengine": (
        "d-video-engine", "provider/d_video_run.py", "Vendor",
        ("python/bin/python3", "provider/d_video_run.py", "provider/d_video_model.py",
         "provider/d_video_prepare.py", "provider/d_audio_access.py", "model-manifests/wan21.json",
         "tokenizer/special_tokens_map.json", "tokenizer/spiece.model", "tokenizer/tokenizer.json",
         "tokenizer/tokenizer_config.json", "Vendor/wan21/__init__.py", "Vendor/wan21/PROVENANCE.json",
         "Vendor/wan21/LICENSE-MIT.txt", "Vendor/wan21/LICENSE-WAN-APACHE-2.0.txt"),
    ),
    "PitchEngine.dengine": (
        "d-pitch-engine", "provider/d_pitch_analysis_backend.py",
        "python/lib/python3.12/site-packages/swift_f0",
        ("python/bin/python3", "provider/d_pitch_analysis_backend.py", "provider/d_audio_access.py",
         "model-manifests/swift-f0.json", "python/lib/python3.12/site-packages/swift_f0/core.py",
         "python/lib/python3.12/site-packages/swift_f0/model.onnx"),
    ),
}

CONTRACTS["ExternalVideoEngine.dengine"] = (
    "d-external-video-engine", "provider/app_video_driver.py", "native",
    ("python/bin/python3", "provider/app_video_driver.py", "provider/d_audio_access.py",
     "model-manifests/h3-fl2va-bf16.json", "native/h3", "native/h3_shaders.metal",
     "native/ffmpeg", "native/ffprobe", "provider/Resources/h3-fl2va-bf16.json",
     "provider/Resources/ltx23-bf16.json", "provider/Resources/ltx23-q8-test.json"),
)

CONTRACTS["ACEMusicEngine.dengine"] = (
    "d-ace-music-engine", "provider/d_audio_ace_backend.py", "vendor",
    ("python/bin/python3", "provider/d_audio_ace_backend.py", "provider/d_audio_access.py",
     "provider/d_audio_ace_contract.py", "provider/d_audio_contract.py", "provider/d_audio_mrt2_contract.py",
     "provider/d_ace_offline_runtime.py", "model-manifests/ace-xl-sft.json", "vendor/acestep/handler.py", "vendor/LICENSE"),
)


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def manifest_files(root: Path) -> list[dict[str, object]]:
    result: list[dict[str, object]] = []
    for current, directories, files in os.walk(root, followlinks=False):
        current_path = Path(current)
        directories[:] = [name for name in directories if not (current_path / name).is_symlink()]
        for name in files:
            path = current_path / name
            relative = path.relative_to(root).as_posix()
            if relative == "engine.json" or path.is_symlink():
                continue
            info = path.stat()
            result.append({
                "path": relative,
                "sizeBytes": info.st_size,
                "sha256": digest(path),
                "executable": bool(info.st_mode & 0o111),
            })
    return sorted(result, key=lambda item: str(item["path"]))


def rewrite_engine_manifest(root: Path, name: str) -> None:
    kind, provider, vendor, _required = CONTRACTS[name]
    manifest = {
        "schemaVersion": 1,
        "kind": kind,
        "pythonABI": "3.12",
        "pythonExecutable": "python/bin/python3",
        "providerScript": provider,
        "vendorDirectory": vendor,
        "modelManifestsDirectory": "model-manifests",
        "files": manifest_files(root),
    }
    (root / "engine.json").write_text(
        json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2) + "\n",
        encoding="utf-8",
    )


def write_engine(parent: Path, name: str) -> Path:
    root = parent / name
    kind, provider, vendor, required = CONTRACTS[name]
    del kind, provider
    for relative in required:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes((name + ":" + relative + "\n").encode("utf-8"))
    (root / vendor).mkdir(parents=True, exist_ok=True)
    (root / "python/bin/python3").chmod(0o755)
    rewrite_engine_manifest(root, name)
    return root


def tree_snapshot(root: Path) -> dict[str, tuple[int, int, str]]:
    result: dict[str, tuple[int, int, str]] = {}
    for current, directories, files in os.walk(root, followlinks=False):
        current_path = Path(current)
        for name in directories + files:
            path = current_path / name
            relative = path.relative_to(root).as_posix()
            info = path.lstat()
            marker = os.readlink(path) if stat.S_ISLNK(info.st_mode) else ""
            result[relative] = (info.st_mode, info.st_mtime_ns, marker)
    return result


class DevelopmentResourceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="d development resources ü "))
        self.addCleanup(lambda: shutil.rmtree(self.root, ignore_errors=True))
        self.inputs = self.root / "prepared engine inputs"
        self.inputs.mkdir()
        self.engines = {name: write_engine(self.inputs, name) for name in ENGINE_NAMES}
        self.config = self.root / "local engines 配置.json"
        self.write_config()

    def write_config(self, engines: dict[str, str] | None = None) -> None:
        values = engines or {name: str(self.engines[name]) for name in ENGINE_NAMES}
        self.config.write_text(
            json.dumps({"schemaVersion": 1, "engines": values}, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )

    def run_cli(self, script: Path, *arguments: object) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["TMPDIR"] = os.environ["TMPDIR"]
        return subprocess.run(
            [sys.executable, str(script), *(str(item) for item in arguments)],
            cwd=REPOSITORY,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def run_cli_with_read_only_stream(
        self,
        script: Path,
        arguments: list[object],
        *,
        stream: str,
        close_stdout: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        descriptor_path = self.root / f"task owned read-only {stream} {len(list(self.root.iterdir()))}.txt"
        descriptor_path.write_text("task-owned descriptor fixture\n", encoding="utf-8")
        environment = os.environ.copy()
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["TMPDIR"] = os.environ["TMPDIR"]

        def close_child_stdout() -> None:
            os.close(1)

        with descriptor_path.open("rb") as read_only:
            options: dict[str, object] = {
                "cwd": REPOSITORY,
                "env": environment,
                "text": True,
                "check": False,
                "timeout": 15,
                "stdout": read_only if stream == "stdout" else subprocess.PIPE,
                "stderr": read_only if stream == "stderr" else subprocess.PIPE,
            }
            if close_stdout:
                options["preexec_fn"] = close_child_stdout
            return subprocess.run(
                [sys.executable, str(script), *(str(item) for item in arguments)],
                **options,
            )

    def prepare(self, output: Path | None = None) -> tuple[Path, subprocess.CompletedProcess[str]]:
        target = output or self.root / "resource set 输出"
        result = self.run_cli(PREPARE, "--config", self.config, "--output", target)
        return target, result

    def assert_failure(self, result: subprocess.CompletedProcess[str]) -> dict[str, object]:
        self.assertEqual(result.returncode, 2, (result.stdout, result.stderr))
        self.assertTrue(result.stderr)
        self.assertNotIn('"status": "prepared"', result.stdout)
        try:
            report = json.loads(result.stderr.splitlines()[-1])
        except json.JSONDecodeError:
            self.fail(f"last stderr line was not diagnostic JSON: {result.stderr}")
        self.assertEqual(report["status"], "failed")
        return report

    def test_prepare_four_engines_and_reuse_without_modification(self) -> None:
        inputs_before = tree_snapshot(self.inputs)
        output, first = self.prepare()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(json.loads(first.stdout)["status"], "prepared")
        self.assertEqual({item.name for item in (output / "Engines").iterdir()}, set(ENGINE_NAMES))
        manifest = json.loads((output / "development-resources.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["schemaVersion"], 1)
        self.assertEqual(set(manifest["engines"]), set(ENGINE_NAMES))
        self.assertEqual(tree_snapshot(self.inputs), inputs_before)
        before = tree_snapshot(output)

        _same, second = self.prepare(output)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(json.loads(second.stdout)["status"], "reused")
        self.assertEqual(tree_snapshot(output), before)

    def test_optional_ace_requires_its_real_import_closure(self) -> None:
        name = "ACEMusicEngine.dengine"
        engine = write_engine(self.inputs, name)
        values = {key: str(value) for key, value in self.engines.items()}
        values[name] = str(engine)
        self.write_config(values)
        _prepared, result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        for missing in ("d_audio_contract.py", "d_audio_mrt2_contract.py"):
            path = engine / "provider" / missing
            original = path.read_bytes()
            path.unlink()
            rewrite_engine_manifest(engine, name)
            _prepared, rejected = self.prepare(self.root / (missing + "-missing"))
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn(missing, rejected.stderr)
            path.write_bytes(original)
            rewrite_engine_manifest(engine, name)

    def test_optional_wasi_python_uses_its_own_contract_and_embeds(self) -> None:
        name = "ChatPython.dengine"
        engine = self.inputs / name
        required = ("runner", "libwasmtime.dylib", "runtime/python.wasm",
                    "runtime/lib/python3.14/encodings/__init__.py", "runtime/lib/python3.14/csv.py",
                    "runtime/lib/python3.14/statistics.py", "runtime/lib/python3.14/d_result.py",
                    "LICENSE-CPython.txt", "LICENSE-Wasmtime.txt", "PROVENANCE.json")
        for relative in required:
            path = engine / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture, not executable Python\n")
        (engine / "runner").chmod(0o755)
        manifest = {"schemaVersion": 1, "kind": "d-chat-python-wasi", "pythonVersion": "3.14.8",
                    "wasmtimeVersion": "49.0.2", "engine": "pulley64", "files": manifest_files(engine)}
        (engine / "engine.json").write_text(json.dumps(manifest))
        self.write_config({**{key: str(value) for key, value in self.engines.items()}, name: str(engine)})
        output, result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        destination = self.root / "app-resources" / "Engines"
        destination.parent.mkdir()
        embedded = self.run_cli(EMBED, "--prepared", output, "--destination", destination)
        self.assertEqual(embedded.returncode, 0, embedded.stderr)
        self.assertEqual((destination / name / "runtime/python.wasm").read_bytes(),
                         (engine / "runtime/python.wasm").read_bytes())
        manifest["engine"] = "native-host-python"
        (engine / "engine.json").write_text(json.dumps(manifest))
        _, rejected = self.prepare(self.root / "invalid-wasi-resources")
        self.assert_failure(rejected)

    def test_optional_external_video_is_explicit_verified_and_reusable(self) -> None:
        name = "ExternalVideoEngine.dengine"
        external = write_engine(self.inputs, name)
        values = {key: str(value) for key, value in self.engines.items()}
        values[name] = str(external)
        self.write_config(values)
        before = tree_snapshot(self.inputs)
        prepared, result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(set(json.loads(result.stdout)["engines"]), set(values))
        destination = self.root / "native resources"
        first = self.run_cli(EMBED, "--prepared", prepared, "--destination", destination)
        self.assertEqual(first.returncode, 0, first.stderr)
        snapshot = tree_snapshot(destination)
        second = self.run_cli(EMBED, "--prepared", prepared, "--destination", destination)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(tree_snapshot(destination), snapshot)
        self.assertEqual(tree_snapshot(self.inputs), before)
        (prepared / "Engines" / name / "native/h3").write_bytes(b"tampered")
        rejected = self.run_cli(EMBED, "--prepared", prepared, "--destination", self.root / "must not exist")
        self.assert_failure(rejected)
        self.assertFalse((self.root / "must not exist").exists())

    def test_reuse_rejects_changed_input_even_when_config_is_unchanged(self) -> None:
        output, first = self.prepare()
        self.assertEqual(first.returncode, 0, first.stderr)
        changed = self.engines["AudioEngine.dengine"] / "provider/d_audio_backend.py"
        changed.write_text("valid but changed input\n", encoding="utf-8")
        rewrite_engine_manifest(self.engines["AudioEngine.dengine"], "AudioEngine.dengine")
        before = tree_snapshot(output)

        _same, second = self.prepare(output)
        report = self.assert_failure(second)
        self.assertIn("changed engine inputs", str(report["error"]))
        self.assertEqual(tree_snapshot(output), before)

    def test_semantically_identical_reformatted_config_reuses_output(self) -> None:
        output, first = self.prepare()
        self.assertEqual(first.returncode, 0, first.stderr)
        before = tree_snapshot(output)
        values = {name: str(self.engines[name]) for name in reversed(ENGINE_NAMES)}
        self.config.write_text(
            json.dumps({"engines": values, "schemaVersion": 1}, ensure_ascii=False, separators=(",", ":")),
            encoding="utf-8",
        )

        _same, second = self.prepare(output)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(json.loads(second.stdout)["status"], "reused")
        self.assertEqual(tree_snapshot(output), before)

    def test_missing_engine_config_is_rejected(self) -> None:
        values = {name: str(path) for name, path in self.engines.items() if name != "PitchEngine.dengine"}
        self.write_config(values)
        output, result = self.prepare()
        self.assert_failure(result)
        self.assertFalse(output.exists())

    def test_bad_manifest_contract_is_rejected(self) -> None:
        manifest_path = self.engines["VideoEngine.dengine"] / "engine.json"
        value = json.loads(manifest_path.read_text(encoding="utf-8"))
        value["kind"] = "d-audio-engine"
        manifest_path.write_text(json.dumps(value), encoding="utf-8")
        output, result = self.prepare()
        report = self.assert_failure(result)
        self.assertIn("kind", str(report["error"]))
        self.assertFalse(output.exists())

    def test_input_manifest_hash_conflict_is_rejected(self) -> None:
        changed = self.engines["AudioEngine.dengine"] / "provider/d_audio_backend.py"
        changed.write_text("changed after manifest\n", encoding="utf-8")
        output, result = self.prepare()
        report = self.assert_failure(result)
        self.assertIn("differing", str(report["error"]))
        self.assertFalse(output.exists())

    def test_output_input_overlap_is_rejected_without_removal(self) -> None:
        marker = self.engines["PitchEngine.dengine"] / "keep.txt"
        marker.write_text("keep", encoding="utf-8")
        rewrite_engine_manifest(self.engines["PitchEngine.dengine"], "PitchEngine.dengine")
        output = self.engines["PitchEngine.dengine"] / "nested output"
        _target, result = self.prepare(output)
        self.assert_failure(result)
        self.assertEqual(marker.read_text(encoding="utf-8"), "keep")

    def test_external_and_absolute_symlinks_are_rejected(self) -> None:
        outside = self.root / "outside.txt"
        outside.write_text("outside", encoding="utf-8")
        link = self.engines["AudioEngine.dengine"] / "provider/escape"
        link.symlink_to(outside)
        output, result = self.prepare()
        report = self.assert_failure(result)
        self.assertIn("relative target", str(report["error"]))
        self.assertFalse(output.exists())

    def test_internal_python_framework_links_and_unicode_paths_are_preserved(self) -> None:
        engine = self.engines["AudioEngine.dengine"]
        framework = engine / "python/Python.framework"
        binary = framework / "Versions/3.12/Python"
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b"framework binary fixture")
        (framework / "Versions/Current").symlink_to("3.12")
        (framework / "Python").symlink_to("Versions/Current/Python")
        unicode_file = engine / "vendor/资料 with space.txt"
        unicode_file.write_text("fixture", encoding="utf-8")
        rewrite_engine_manifest(engine, "AudioEngine.dengine")

        prepared, result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        copied_framework = prepared / "Engines/AudioEngine.dengine/python/Python.framework"
        self.assertTrue((copied_framework / "Versions/Current").is_symlink())
        self.assertEqual(os.readlink(copied_framework / "Versions/Current"), "3.12")
        self.assertTrue((copied_framework / "Python").is_symlink())
        self.assertTrue((prepared / "Engines/AudioEngine.dengine/vendor/资料 with space.txt").is_file())

    def test_embed_and_repeat_do_not_modify_files(self) -> None:
        prepared, result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        resources = self.root / "Build Product.app/Contents/Resources"
        resources.mkdir(parents=True)
        destination = resources / "Engines"
        first = self.run_cli(EMBED, "--prepared", prepared, "--destination", destination)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(json.loads(first.stdout)["status"], "embedded")
        before = tree_snapshot(destination)

        second = self.run_cli(EMBED, "--prepared", prepared, "--destination", destination)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(json.loads(second.stdout)["status"], "reused")
        self.assertEqual(tree_snapshot(destination), before)

    def test_embed_refuses_unknown_destination_entry_before_copy(self) -> None:
        prepared, result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        destination = self.root / "Build/Resources/Engines"
        destination.mkdir(parents=True)
        unknown = destination / "UnknownEngine.dengine"
        unknown.mkdir()
        marker = unknown / "keep.txt"
        marker.write_text("keep", encoding="utf-8")

        embedded = self.run_cli(EMBED, "--prepared", prepared, "--destination", destination)
        report = self.assert_failure(embedded)
        self.assertIn("unknown", str(report["error"]))
        self.assertEqual(marker.read_text(encoding="utf-8"), "keep")
        self.assertEqual({item.name for item in destination.iterdir()}, {"UnknownEngine.dengine"})

    def test_embed_validates_all_prepared_hashes_before_destination_write(self) -> None:
        prepared, result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        corrupted = prepared / "Engines/PitchEngine.dengine/provider/d_pitch_analysis_backend.py"
        corrupted.write_text("corrupt\n", encoding="utf-8")
        destination = self.root / "Build/Resources/Engines"
        destination.parent.mkdir(parents=True)

        embedded = self.run_cli(EMBED, "--prepared", prepared, "--destination", destination)
        report = self.assert_failure(embedded)
        self.assertIn("prepared resource validation failed", str(report["error"]))
        self.assertFalse(destination.exists())

    def test_embed_conflict_does_not_overwrite_existing_engine(self) -> None:
        prepared, result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        destination = self.root / "Build/Resources/Engines"
        destination.parent.mkdir(parents=True)
        first = self.run_cli(EMBED, "--prepared", prepared, "--destination", destination)
        self.assertEqual(first.returncode, 0, first.stderr)
        conflict = destination / "VideoEngine.dengine/provider/d_video_run.py"
        conflict.write_text("local unknown change\n", encoding="utf-8")

        second = self.run_cli(EMBED, "--prepared", prepared, "--destination", destination)
        report = self.assert_failure(second)
        self.assertIn("conflicts", str(report["error"]))
        self.assertEqual(conflict.read_text(encoding="utf-8"), "local unknown change\n")

    def test_existing_unknown_output_is_refused_without_cleanup(self) -> None:
        output = self.root / "resource set 输出"
        output.mkdir()
        marker = output / "keep.txt"
        marker.write_text("keep", encoding="utf-8")
        _target, result = self.prepare(output)
        self.assert_failure(result)
        self.assertEqual(marker.read_text(encoding="utf-8"), "keep")

    def test_closed_stdout_exits_two_after_successful_publication(self) -> None:
        prepare_output = self.root / "closed stdout prepared"
        prepared = self.run_cli_with_read_only_stream(
            PREPARE,
            ["--config", self.config, "--output", prepare_output],
            stream="stdout",
            close_stdout=True,
        )
        self.assertEqual(prepared.returncode, 2, prepared.stderr)
        self.assertTrue((prepare_output / "development-resources.json").is_file())

        reusable, normal = self.prepare(self.root / "closed stdout embed source")
        self.assertEqual(normal.returncode, 0, normal.stderr)
        destination = self.root / "Closed.app/Contents/Resources/Engines"
        destination.parent.mkdir(parents=True)
        embedded = self.run_cli_with_read_only_stream(
            EMBED,
            ["--prepared", reusable, "--destination", destination],
            stream="stdout",
            close_stdout=True,
        )
        self.assertEqual(embedded.returncode, 2, embedded.stderr)
        self.assertEqual({item.name for item in destination.iterdir()}, set(ENGINE_NAMES))

    def test_buffered_stdout_failure_exits_two_after_successful_publication(self) -> None:
        prepare_output = self.root / "buffered stdout prepared"
        prepared = self.run_cli_with_read_only_stream(
            PREPARE,
            ["--config", self.config, "--output", prepare_output],
            stream="stdout",
        )
        self.assertEqual(prepared.returncode, 2, prepared.stderr)
        self.assertTrue((prepare_output / "development-resources.json").is_file())

        reusable, normal = self.prepare(self.root / "buffered stdout embed source")
        self.assertEqual(normal.returncode, 0, normal.stderr)
        destination = self.root / "Buffered.app/Contents/Resources/Engines"
        destination.parent.mkdir(parents=True)
        embedded = self.run_cli_with_read_only_stream(
            EMBED,
            ["--prepared", reusable, "--destination", destination],
            stream="stdout",
        )
        self.assertEqual(embedded.returncode, 2, embedded.stderr)
        self.assertEqual({item.name for item in destination.iterdir()}, set(ENGINE_NAMES))

    def test_unwritable_error_stderr_does_not_mask_exit_two(self) -> None:
        values = {name: str(path) for name, path in self.engines.items() if name != "PitchEngine.dengine"}
        self.write_config(values)
        output = self.root / "stderr failure output"
        result = self.run_cli_with_read_only_stream(
            PREPARE,
            ["--config", self.config, "--output", output],
            stream="stderr",
        )
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertFalse(output.exists())

    def test_config_engine_path_with_nul_is_controlled_exit_two(self) -> None:
        values = {name: str(path) for name, path in self.engines.items()}
        values["AudioEngine.dengine"] = str(self.root / "existing parent" / "x\x00y")
        (self.root / "existing parent").mkdir()
        self.write_config(values)
        output, result = self.prepare()
        report = self.assert_failure(result)
        self.assertIn("NUL", str(report["error"]))
        self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
