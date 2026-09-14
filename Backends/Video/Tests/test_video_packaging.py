"""CPU-only fixtures for the fixed video engine and application packagers."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import tokenize
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[3]
PACKAGING = ROOT / "Backends/Video/Packaging"
TASK_TMP = Path(os.environ["D_TEST_TEMP_DIR"])
IDENTITY = "A" * 40
MACH_O = b"\xcf\xfa\xed\xfe" + b"fixture-native"

sys.path.insert(0, str(PACKAGING))


def load(name: str):
    target = PACKAGING / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name, target)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


prepare_video_engine = load("prepare_video_engine")
package_video_app = load("package_video_app")


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class VideoFixture(unittest.TestCase):
    def setUp(self) -> None:
        if not TASK_TMP.is_dir():
            self.fail("D_TEST_TEMP_DIR must name the existing task-owned temporary directory")
        self.temporary = tempfile.TemporaryDirectory(dir=TASK_TMP)
        self.base = Path(self.temporary.name)
        self.python = self.base / "Python 3.12 根"
        (self.python / "bin").mkdir(parents=True)
        interpreter = self.python / "bin/python3.12"
        interpreter.write_bytes(MACH_O)
        interpreter.chmod(0o755)
        stdlib = self.python / "lib/python3.12"
        (stdlib / "encodings").mkdir(parents=True)
        (stdlib / "LICENSE.txt").write_text("PSF fixture", encoding="utf-8")
        (stdlib / "encodings/__init__.py").write_text("# fixture", encoding="utf-8")

        self.site = self.base / "site packages 📦"
        self.site.mkdir()
        for package in prepare_video_engine.REQUIRED_PACKAGES:
            path = self.site / package
            path.mkdir()
            (path / "__init__.py").write_text("# fixture", encoding="utf-8")
        for name, version in prepare_video_engine.REQUIRED_DISTRIBUTIONS.items():
            stem = name.replace("-", "_")
            metadata = self.site / f"{stem}-{version}.dist-info"
            metadata.mkdir()
            (metadata / "METADATA").write_text(f"Name: {name}\nVersion: {version}\n", encoding="utf-8")
            (metadata / "WHEEL").write_text("Wheel-Version: 1.0\n", encoding="utf-8")
            (metadata / "LICENSE").write_text(f"license for {name}", encoding="utf-8")
            (metadata / "direct_url.json").write_text('{"url":"file:///private/build/path"}', encoding="utf-8")
            (metadata / "RECORD").write_text("private/build/path", encoding="utf-8")
            (metadata / "INSTALLER").write_text("pip", encoding="utf-8")
            (metadata / "REQUESTED").write_text("", encoding="utf-8")
        (self.site / "torch").mkdir()
        (self.site / "torch/__init__.py").write_text("must not be copied", encoding="utf-8")
        (self.site / "transformers").mkdir()

        self.tokenizer = self.base / "tokenizer 输入"
        self.tokenizer.mkdir()
        self.tokenizer_digests: dict[str, str] = {}
        for name in prepare_video_engine.TOKENIZER_DIGESTS:
            path = self.tokenizer / name
            path.write_bytes(("fixture:" + name).encode("utf-8"))
            self.tokenizer_digests[name] = digest(path)

        self.video_root = ROOT / "Backends/Video"
        self.audio_provider = ROOT / "Backends/Audio/Python"
        self.output = self.base / "Video Engine 输出.dengine"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def prepare_arguments(self, **changes: object) -> argparse.Namespace:
        values = dict(
            python_root=str(self.python),
            site_packages=str(self.site),
            video_root=str(self.video_root),
            audio_provider_directory=str(self.audio_provider),
            tokenizer=str(self.tokenizer),
            output=str(self.output),
        )
        values.update(changes)
        return argparse.Namespace(**values)

    def prepare(self, **changes: object) -> None:
        with mock.patch.object(prepare_video_engine, "TOKENIZER_DIGESTS", self.tokenizer_digests):
            prepare_video_engine.prepare(self.prepare_arguments(**changes))


class PrepareVideoEngineTests(VideoFixture):
    def test_official_tokenizers_wheel_without_license_preserves_pinned_source_license(self) -> None:
        (self.site / "tokenizers-0.22.2.dist-info/LICENSE").unlink()
        self.prepare()
        copied = self.output / "python/lib/python3.12/site-packages/tokenizers-0.22.2.dist-info/licenses/D-tokenizers-LICENSE.txt"
        self.assertEqual(digest(copied), prepare_video_engine.TOKENIZERS_LICENSE_SHA256)
        self.assertFalse((self.site / "tokenizers-0.22.2.dist-info/LICENSE").exists())
        with mock.patch.object(prepare_video_engine, "TOKENIZERS_LICENSE", self.base / "missing-license"):
            with self.assertRaisesRegex(prepare_video_engine.PackagingError, "license"):
                self.prepare(output=str(self.base / "missing-license-output"))

    def test_syntax_without_import_or_bytecode(self) -> None:
        for name in ("prepare_video_engine.py", "package_video_app.py"):
            target = PACKAGING / name
            with tokenize.open(target) as handle:
                compile(handle.read(), str(target), "exec", dont_inherit=True)

    def test_fixed_layout_manifest_whitelist_unicode_and_input_preservation(self) -> None:
        runner_before = digest(self.video_root / "Python/d_video_run.py")
        self.prepare()
        manifest = json.loads((self.output / "engine.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["kind"], "d-video-engine")
        self.assertEqual(manifest["pythonABI"], "3.12")
        self.assertEqual(manifest["providerScript"], "provider/d_video_run.py")
        self.assertEqual(manifest["vendorDirectory"], "Vendor")
        self.assertEqual(manifest["modelManifestsDirectory"], "model-manifests")
        paths = [entry["path"] for entry in manifest["files"]]
        self.assertEqual(paths, sorted(paths))
        inventory = [path.relative_to(self.output).as_posix() for path in self.output.rglob("*")]
        self.assertEqual(len(inventory), len({path.casefold() for path in inventory}))
        self.assertNotIn("Python", {path.name for path in self.output.iterdir()})
        for relative in package_video_app.REQUIRED_VIDEO_FILES:
            self.assertIn(relative, paths)
        self.assertFalse((self.output / "python/lib/python3.12/site-packages/torch").exists())
        self.assertFalse((self.output / "python/lib/python3.12/site-packages/transformers").exists())
        self.assertEqual(digest(self.output / "provider/d_video_run.py"), runner_before)
        self.assertEqual(digest(self.video_root / "Python/d_video_run.py"), runner_before)
        for name, version in prepare_video_engine.REQUIRED_DISTRIBUTIONS.items():
            metadata = self.output / "python/lib/python3.12/site-packages" / f"{name.replace('-', '_')}-{version}.dist-info"
            self.assertTrue((metadata / "METADATA").is_file())
            self.assertTrue((metadata / "WHEEL").is_file())
            self.assertTrue((metadata / "LICENSE").is_file())
            for record in prepare_video_engine.INSTALLATION_RECORDS:
                self.assertFalse((metadata / record).exists())
        for entry in manifest["files"]:
            path = self.output / entry["path"]
            self.assertEqual(path.stat().st_size, entry["sizeBytes"])
            self.assertEqual(digest(path), entry["sha256"])

    def test_missing_wrong_version_license_tokenizer_and_legitimate_runner_are_handled(self) -> None:
        cases: list[tuple[str, callable]] = [
            ("package", lambda: shutil.rmtree(self.site / "ftfy")),
            ("version", lambda: (self.site / "numpy-2.4.3.dist-info/METADATA").write_text("Name: numpy\nVersion: 9\n", encoding="utf-8")),
            ("license", lambda: (self.site / "wcwidth-0.8.3.dist-info/LICENSE").unlink()),
            ("tokenizer", lambda: (self.tokenizer / "spiece.model").write_bytes(b"changed")),
        ]
        for index, (expected, mutate) in enumerate(cases):
            with self.subTest(expected=expected):
                self.tearDown()
                self.setUp()
                mutate()
                with self.assertRaisesRegex(prepare_video_engine.PackagingError, expected):
                    self.prepare(output=str(self.base / f"bad-{index}"))
        self.tearDown()
        self.setUp()
        copied_video = self.base / "video-copy"
        shutil.copytree(self.video_root, copied_video)
        runner = copied_video / "Python/d_video_run.py"
        runner.write_bytes(runner.read_bytes() + b"\n# approved caller-explicit integration revision\n")
        changed_output = self.base / "changed-runner"
        self.prepare(video_root=str(copied_video), output=str(changed_output))
        self.assertEqual(digest(changed_output / "provider/d_video_run.py"), digest(runner))
        manifest = json.loads((changed_output / "engine.json").read_text(encoding="utf-8"))
        declaration = next(item for item in manifest["files"] if item["path"] == "provider/d_video_run.py")
        self.assertEqual(declaration["sha256"], digest(runner))

    def test_provider_source_and_copy_replacement_are_refused(self) -> None:
        source = self.base / "explicit-provider.py"
        source.write_text("print('original')\n", encoding="utf-8")
        source.chmod(0o755)
        destination = self.base / "copied-provider.py"
        original_copy = prepare_video_engine._copy_descriptor

        def replace_source(descriptor: int, target: Path, mode: int) -> None:
            original_copy(descriptor, target, mode)
            replacement = self.base / "replacement-provider.py"
            replacement.write_text("print('replacement')\n", encoding="utf-8")
            replacement.chmod(0o755)
            os.replace(replacement, source)

        with mock.patch.object(prepare_video_engine, "_copy_descriptor", side_effect=replace_source):
            with self.assertRaisesRegex(prepare_video_engine.PackagingError, "changed or was replaced"):
                prepare_video_engine._copy_verified_source(source, destination, "provider fixture")
        destination.unlink()
        source.write_text("print('original again')\n", encoding="utf-8")
        source.chmod(0o755)

        def replace_copy(descriptor: int, target: Path, mode: int) -> None:
            original_copy(descriptor, target, mode)
            target.write_text("tampered copy\n", encoding="utf-8")
            target.chmod(mode)

        with mock.patch.object(prepare_video_engine, "_copy_descriptor", side_effect=replace_copy):
            with self.assertRaisesRegex(prepare_video_engine.PackagingError, "copied file differs"):
                prepare_video_engine._copy_verified_source(source, destination, "provider fixture")

    def test_symlink_overlap_existing_and_installation_path_are_refused(self) -> None:
        self.output.mkdir()
        sentinel = self.output / "sentinel"
        sentinel.write_text("keep", encoding="utf-8")
        with self.assertRaisesRegex(prepare_video_engine.PackagingError, "already exists"):
            self.prepare()
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep")
        shutil.rmtree(self.output)
        with self.assertRaisesRegex(prepare_video_engine.PackagingError, "overlaps"):
            self.prepare(output=str(self.tokenizer / "nested"))
        link = self.site / "numpy/link"
        link.symlink_to(self.site / "numpy/__init__.py")
        with self.assertRaisesRegex(prepare_video_engine.PackagingError, "symlink"):
            self.prepare(output=str(self.base / "bad-link"))
        link.unlink()
        (self.site / "numpy/install.py").write_text(str(self.site), encoding="utf-8")
        with self.assertRaisesRegex(prepare_video_engine.PackagingError, "installation input path"):
            self.prepare(output=str(self.base / "bad-absolute"))

    def test_relative_inputs_and_real_cli_failure_are_controlled(self) -> None:
        with self.assertRaisesRegex(prepare_video_engine.PackagingError, "absolute"):
            self.prepare(python_root="relative")
        command = [
            sys.executable, "-B", str(PACKAGING / "prepare_video_engine.py"),
            "--python-root", "relative", "--site-packages", str(self.site),
            "--video-root", str(self.video_root), "--audio-provider-directory", str(self.audio_provider),
            "--tokenizer", str(self.tokenizer), "--output", str(self.output),
        ]
        result = subprocess.run(command, text=True, capture_output=True, timeout=20, check=False,
                                env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"))
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("absolute", result.stderr)
        self.assertFalse(self.output.exists())


class SigningFixture:
    def __init__(self) -> None:
        self.entitlements: dict[str, object] = {
            "com.apple.security.app-sandbox": True,
            "com.apple.security.get-task-allow": True,
            "com.apple.security.files.user-selected.read-write": True,
        }
        self.calls: list[list[str]] = []
        self.failure: str | None = None
        self.final_identifier = "com.example.D"
        self.final_team = "TEAMFIXTURE"
        self.final_entitlements: dict[str, object] | None = None

    def __call__(self, argv: list[str], timeout: int = 30) -> subprocess.CompletedProcess[str]:
        del timeout
        self.calls.append(list(argv))
        target = Path(argv[-1])
        output_app = target.name.endswith(".app") and ".d-video-app-" in str(target)
        if self.failure == "timeout" and "--force" in argv:
            raise package_video_app.PackagingError("command timed out after 30s: /usr/bin/codesign")
        if self.failure == "sign" and "--force" in argv:
            return subprocess.CompletedProcess(argv, 7, "", "fixture sign failure")
        if "--verify" in argv:
            if self.failure == "verify" and output_app and "--deep" in argv:
                return subprocess.CompletedProcess(argv, 5, "", "fixture verification failure")
            return subprocess.CompletedProcess(argv, 0, "", "fixture diagnostic")
        if "--verbose=4" in argv:
            identifier = self.final_identifier if output_app else ("com.example.D" if target.suffix == ".app" else "native")
            team = self.final_team if output_app else "TEAMFIXTURE"
            return subprocess.CompletedProcess(argv, 0, "", f"Identifier={identifier}\nTeamIdentifier={team}\n")
        if "--entitlements" in argv and "-d" in argv:
            value = self.final_entitlements if output_app and self.final_entitlements is not None else self.entitlements
            return subprocess.CompletedProcess(argv, 0, plistlib.dumps(value).decode("utf-8"), "")
        if "--force" in argv:
            if target.is_file():
                target.write_bytes(target.read_bytes() + b"-SIGNED")
            return subprocess.CompletedProcess(argv, 0, "", "")
        raise AssertionError(f"unexpected signing command: {argv}")


class PackageVideoAppTests(VideoFixture):
    def setUp(self) -> None:
        super().setUp()
        self.prepare()
        self.tokenizer_patch = mock.patch.object(
            prepare_video_engine, "TOKENIZER_DIGESTS", self.tokenizer_digests,
        )
        self.tokenizer_patch.start()
        self.app = self.base / "已签名 输入.app"
        resources = self.app / "Contents/Resources"
        resources.mkdir(parents=True)
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.example.D"}))
        executable = self.app / "Contents/MacOS/D"
        executable.parent.mkdir()
        executable.write_bytes(MACH_O)
        executable.chmod(0o755)
        audio = resources / "AudioEngine.dengine"
        audio.mkdir()
        (audio / "engine.json").write_text("audio bytes stay fixed", encoding="utf-8")
        self.audio_digest = digest(audio / "engine.json")
        self.app_output = self.base / "封装 输出.app"
        self.report = self.base / "封装 报告.json"
        self.signing = SigningFixture()

    def tearDown(self) -> None:
        patcher = getattr(self, "tokenizer_patch", None)
        if patcher is not None:
            patcher.stop()
            self.tokenizer_patch = None
        super().tearDown()

    def arguments(self, **changes: object) -> argparse.Namespace:
        values = dict(app=str(self.app), engine=str(self.output), identity=IDENTITY,
                      output=str(self.app_output), report=str(self.report))
        values.update(changes)
        return argparse.Namespace(**values)

    def package(self, **changes: object) -> dict[str, object]:
        with mock.patch.object(package_video_app.package_audio_app, "_run_command", side_effect=self.signing):
            return package_video_app.package(self.arguments(**changes))

    def assert_failure(self, expected: str | None = None, **changes: object) -> str:
        with mock.patch.object(package_video_app.package_audio_app, "_run_command", side_effect=self.signing):
            with self.assertRaises(package_video_app.PackagingError) as caught:
                package_video_app.package(self.arguments(**changes))
        if expected:
            self.assertIn(expected, str(caught.exception))
        return str(caught.exception)

    def test_valid_package_report_audio_preservation_and_manifest_resigning(self) -> None:
        result = self.package()
        self.assertEqual(result["status"], "packaged")
        self.assertEqual(result["preservedAudioEngines"], ["AudioEngine.dengine"])
        self.assertGreaterEqual(result["signedNativeFiles"], 1)
        self.assertEqual(json.loads(self.report.read_text(encoding="utf-8")), result)
        self.assertEqual(self.report.stat().st_mode & 0o777, 0o600)
        resources = self.app_output / "Contents/Resources"
        self.assertEqual(digest(resources / "AudioEngine.dengine/engine.json"), self.audio_digest)
        manifest = package_video_app._validate_video_engine(resources / package_video_app.VIDEO_ENGINE)
        self.assertEqual(manifest["kind"], "d-video-engine")
        interpreter = resources / "VideoEngine.dengine/python/bin/python3"
        self.assertTrue(interpreter.read_bytes().endswith(b"-SIGNED"))
        outer_sign = [call for call in self.signing.calls if "--force" in call and call[-1].endswith(".app")]
        self.assertEqual(len(outer_sign), 1)
        self.assertNotIn("--deep", outer_sign[0])

    def test_caller_explicit_legitimate_runner_version_packages(self) -> None:
        copied_video = self.base / "integration-video-source"
        shutil.copytree(self.video_root, copied_video)
        runner = copied_video / "Python/d_video_run.py"
        runner.write_bytes(runner.read_bytes() + b"\n# approved integration-only CLI revision\n")
        changed_engine = self.base / "integration VideoEngine.dengine"
        self.prepare(video_root=str(copied_video), output=str(changed_engine))
        result = self.package(engine=str(changed_engine))
        self.assertEqual(result["status"], "packaged")
        packaged_runner = self.app_output / "Contents/Resources/VideoEngine.dengine/provider/d_video_run.py"
        self.assertEqual(digest(packaged_runner), digest(runner))

    def test_engine_manifest_type_hash_required_files_and_existing_video_reject(self) -> None:
        manifest_path = self.output / "engine.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["schemaVersion"] = True
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        self.assert_failure("schemaVersion")
        self.assertFalse(self.app_output.exists())
        self.tearDown()
        self.setUp()
        (self.output / "provider/d_video_model.py").write_text("changed", encoding="utf-8")
        self.assert_failure("pre-sign verification")
        self.tearDown()
        self.setUp()
        (self.app / "Contents/Resources/VideoEngine.dengine").mkdir()
        self.assert_failure("already contains")

    def test_strict_file_entry_and_model_schema_types_reject_equal_numeric_values(self) -> None:
        manifest_path = self.output / "engine.json"
        original = manifest_path.read_bytes()
        base = json.loads(original)
        cases = []
        false_entry = next(index for index, item in enumerate(base["files"]) if item["executable"] is False)
        true_entry = next(index for index, item in enumerate(base["files"]) if item["executable"] is True)
        cases.append((false_entry, "executable", 0))
        cases.append((true_entry, "executable", 1))
        cases.append((false_entry, "sizeBytes", float(base["files"][false_entry]["sizeBytes"])))
        for index, key, value in cases:
            with self.subTest(key=key, value=value):
                changed = json.loads(original)
                changed["files"][index][key] = value
                manifest_path.write_text(json.dumps(changed), encoding="utf-8")
                with self.assertRaisesRegex(package_video_app.PackagingError, "invalid types"):
                    package_video_app._validate_video_engine(self.output)
                manifest_path.write_bytes(original)

        declaration = self.base / "wan-schema.json"
        fixed = json.loads((ROOT / "Backends/Video/Models/wan21.json").read_text(encoding="utf-8"))
        for schema in (True, 1.0):
            with self.subTest(schema=schema):
                changed = dict(fixed)
                changed["schemaVersion"] = schema
                declaration.write_text(json.dumps(changed), encoding="utf-8")
                with self.assertRaisesRegex(prepare_video_engine.PackagingError, "fixed Wan2.1 profile"):
                    prepare_video_engine._validate_model_declaration(declaration)

    def test_existing_output_report_overlap_identity_and_sandbox_reject(self) -> None:
        self.app_output.mkdir()
        (self.app_output / "sentinel").write_text("keep", encoding="utf-8")
        self.assert_failure("already exists")
        self.assertEqual((self.app_output / "sentinel").read_text(encoding="utf-8"), "keep")
        shutil.rmtree(self.app_output)
        self.report.write_text("keep", encoding="utf-8")
        self.assert_failure("already exists")
        self.assertEqual(self.report.read_text(encoding="utf-8"), "keep")
        self.report.unlink()
        self.assert_failure("overlaps", report=str(self.app / "report.json"))
        self.assert_failure("40-character", identity="adhoc")
        self.signing.entitlements = {}
        self.assert_failure("app-sandbox=true")

    def test_sign_timeout_identity_team_entitlement_and_verify_failures_do_not_publish(self) -> None:
        for case in ("sign", "timeout", "identifier", "team", "entitlements", "verify"):
            with self.subTest(case=case):
                if case in {"sign", "timeout", "verify"}:
                    self.signing.failure = case
                elif case == "identifier":
                    self.signing.final_identifier = "com.example.changed"
                elif case == "team":
                    self.signing.final_team = "OTHERTEAM"
                else:
                    self.signing.final_entitlements = {"com.apple.security.app-sandbox": True}
                self.assert_failure()
                self.assertFalse(self.app_output.exists())
                self.assertFalse(self.report.exists())
                self.signing = SigningFixture()

    def test_report_failure_after_publication_preserves_output(self) -> None:
        with mock.patch.object(package_video_app.package_audio_app, "_run_command", side_effect=self.signing), \
             mock.patch.object(package_video_app, "_write_report_exclusive",
                               side_effect=package_video_app.PackagingError("fixture report collision")):
            with self.assertRaisesRegex(package_video_app.PackagingError, "packaged App retained"):
                package_video_app.package(self.arguments())
        self.assertTrue(self.app_output.is_dir())
        self.assertFalse(self.report.exists())
        self.assertEqual(digest(self.app_output / "Contents/Resources/AudioEngine.dengine/engine.json"), self.audio_digest)

    def test_main_json_and_real_cli_invalid_input(self) -> None:
        stdout, stderr = io.StringIO(), io.StringIO()
        argv = ["--app", str(self.app), "--engine", str(self.output), "--identity", IDENTITY,
                "--output", str(self.app_output), "--report", str(self.report)]
        with mock.patch.object(package_video_app.package_audio_app, "_run_command", side_effect=self.signing), \
             mock.patch.object(sys, "stdout", stdout), mock.patch.object(sys, "stderr", stderr):
            self.assertEqual(package_video_app.main(argv), 0, stderr.getvalue())
        self.assertEqual(json.loads(stdout.getvalue())["status"], "packaged")

        bad_output = self.base / "bad.app"
        command = [sys.executable, "-B", str(PACKAGING / "package_video_app.py"),
                   "--app", "relative.app", "--engine", str(self.output), "--identity", IDENTITY,
                   "--output", str(bad_output), "--report", str(self.base / "bad.json")]
        result = subprocess.run(command, text=True, capture_output=True, timeout=20, check=False,
                                env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"))
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("absolute", result.stderr)
        self.assertFalse(bad_output.exists())


if __name__ == "__main__":
    unittest.main()
