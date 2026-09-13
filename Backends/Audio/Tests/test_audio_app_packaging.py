"""CPU-only fixtures for the signed dual-audio-engine application packager."""

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
PACKAGING = ROOT / "Backends/Audio/Packaging"
TARGET = PACKAGING / "package_audio_app.py"
TASK_TMP = Path(os.environ["D_TEST_TEMP_DIR"])
IDENTITY = "A" * 40
MACH_O = b"\xcf\xfa\xed\xfe" + b"fixture-native"

sys.path.insert(0, str(PACKAGING))
SPEC = importlib.util.spec_from_file_location("package_audio_app", TARGET)
assert SPEC is not None and SPEC.loader is not None
package_audio_app = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(package_audio_app)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class SigningFixture:
    def __init__(self, entitlements: dict[str, object] | None = None) -> None:
        self.entitlements = entitlements or {
            "com.apple.security.app-sandbox": True,
            "com.apple.security.get-task-allow": True,
            "com.apple.security.files.user-selected.read-write": True,
        }
        self.calls: list[list[str]] = []
        self.failure: str | None = None
        self.final_identifier = "com.example.D"
        self.final_team = "TEAMFIXTURE"
        self.final_entitlements: dict[str, object] | None = None
        self.signed_entitlements: dict[str, object] | None = None
        self.publish_collision: Path | None = None

    def __call__(self, argv: list[str], timeout: int = 30) -> subprocess.CompletedProcess[str]:
        del timeout
        self.calls.append(list(argv))
        target = Path(argv[-1])
        is_output_app = target.name.endswith(".app") and ".d-audio-app-" in str(target)
        if self.failure == "timeout" and "--force" in argv:
            raise package_audio_app.PackagingError("command timed out after 30s: /usr/bin/codesign")
        if self.failure == "sign" and "--force" in argv:
            return subprocess.CompletedProcess(argv, 9, "", "fixture sign failure")
        if "--verify" in argv:
            if self.failure == "input-verify" and not is_output_app and "--deep" not in argv:
                return subprocess.CompletedProcess(argv, 1, "", "fixture invalid signature")
            if self.failure == "final-verify" and is_output_app and "--deep" in argv:
                return subprocess.CompletedProcess(argv, 1, "", "fixture final verification failed")
            if is_output_app and "--deep" in argv and self.publish_collision is not None:
                self.publish_collision.mkdir()
                (self.publish_collision / "sentinel").write_text("keep", encoding="utf-8")
            return subprocess.CompletedProcess(argv, 0, "", "fixture warning on stderr")
        if "--verbose=4" in argv:
            if self.failure == "missing-identity" and not is_output_app:
                text = "TeamIdentifier=TEAMFIXTURE\n"
            elif self.failure == "missing-team" and not is_output_app:
                text = "Identifier=com.example.D\nTeamIdentifier=not set\n"
            else:
                identifier = self.final_identifier if is_output_app else target.name
                if target.name.endswith(".app"):
                    identifier = self.final_identifier if is_output_app else "com.example.D"
                team = self.final_team if is_output_app else "TEAMFIXTURE"
                text = f"Identifier={identifier}\nTeamIdentifier={team}\n"
            return subprocess.CompletedProcess(argv, 0, "", text)
        if "--entitlements" in argv and "-d" in argv:
            value = self.final_entitlements if is_output_app and self.final_entitlements is not None else self.entitlements
            text = plistlib.dumps(value, fmt=plistlib.FMT_XML).decode("utf-8")
            return subprocess.CompletedProcess(argv, 0, text, "fixture diagnostic")
        if "--force" in argv:
            if target.is_file():
                target.write_bytes(target.read_bytes() + b"-SIGNED")
            elif "--entitlements" in argv:
                entitlement_path = Path(argv[argv.index("--entitlements") + 1])
                self.signed_entitlements = plistlib.loads(entitlement_path.read_bytes())
            return subprocess.CompletedProcess(argv, 0, "", "fixture signing diagnostic")
        raise AssertionError(f"unexpected command: {argv}")


class AudioAppPackagingTests(unittest.TestCase):
    def setUp(self) -> None:
        if not TASK_TMP.is_dir():
            self.fail("D_TEST_TEMP_DIR must name the existing task-owned temporary directory")
        self.temporary = tempfile.TemporaryDirectory(dir=TASK_TMP)
        self.base = Path(self.temporary.name)
        self.app = self.base / "普通 D 输入.app"
        resources = self.app / "Contents/Resources"
        resources.mkdir(parents=True)
        info = {"CFBundleIdentifier": "com.example.D", "CFBundleName": "D"}
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        executable = self.app / "Contents/MacOS/D"
        executable.parent.mkdir()
        executable.write_bytes(MACH_O)
        executable.chmod(0o755)
        nested = self.app / "Contents/Frameworks/Preserved.framework"
        nested.mkdir(parents=True)
        (nested / "signature-sentinel").write_bytes(b"existing nested signature")
        (self.app / "Contents/Frameworks/Current.framework").symlink_to("Preserved.framework")

        self.python = self.base / "Python 3.12 根"
        (self.python / "bin").mkdir(parents=True)
        interpreter = self.python / "bin/python3.12"
        interpreter.write_bytes(MACH_O)
        interpreter.chmod(0o755)
        stdlib = self.python / "lib/python3.12"
        (stdlib / "encodings").mkdir(parents=True)
        (stdlib / "LICENSE.txt").write_text("PSF fixture", encoding="utf-8")
        (stdlib / "encodings/__init__.py").write_text("# fixture", encoding="utf-8")

        self.sa3_site = self.base / "SA3 site packages"
        self.sa3_site.mkdir()
        for name in ("mlx", "numpy", "sentencepiece"):
            (self.sa3_site / name).mkdir()
            (self.sa3_site / name / "__init__.py").write_text("# fixture", encoding="utf-8")
        for name in ("mlx", "mlx_metal", "numpy", "sentencepiece"):
            metadata = self.sa3_site / f"{name}-1.0.dist-info"
            metadata.mkdir()
            (metadata / "LICENSE").write_text("fixture", encoding="utf-8")

        self.mrt2_site = self.base / "MRT2 site packages 🎹"
        self.mrt2_site.mkdir()
        versions = {
            "mlx": "0.31.1", "mlx_metal": "0.31.1", "numpy": "2.3.5",
            "sentencepiece": "0.2.2", "ai_edge_litert": "2.2.0",
        }
        for name, version in versions.items():
            metadata = self.mrt2_site / f"{name}-{version}.dist-info"
            metadata.mkdir()
            (metadata / "METADATA").write_text(f"Name: {name}\nVersion: {version}\n", encoding="utf-8")
            (metadata / "LICENSE").write_text("fixture", encoding="utf-8")
            if name != "mlx_metal":
                (self.mrt2_site / name).mkdir()
                (self.mrt2_site / name / "__init__.py").write_text("# fixture", encoding="utf-8")

        self.output = self.base / "封装 输出 🎵.app"
        self.signing = SigningFixture()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def arguments(self, **changes: object) -> argparse.Namespace:
        values = dict(
            app=str(self.app),
            python_root=str(self.python),
            sa3_site_packages=str(self.sa3_site),
            mrt2_site_packages=str(self.mrt2_site),
            identity=IDENTITY,
            output=str(self.output),
        )
        values.update(changes)
        return argparse.Namespace(**values)

    def package(self, **changes: object) -> dict[str, object]:
        with mock.patch.object(package_audio_app, "_run_command", side_effect=self.signing):
            return package_audio_app.package(self.arguments(**changes))

    def assert_controlled_failure(self, expected: str | None = None, **changes: object) -> str:
        with mock.patch.object(package_audio_app, "_run_command", side_effect=self.signing):
            with self.assertRaises(package_audio_app.PackagingError) as caught:
                package_audio_app.package(self.arguments(**changes))
        text = str(caught.exception)
        if expected is not None:
            self.assertIn(expected, text)
        self.assertFalse(os.path.lexists(Path(str(changes.get("output", self.output)))))
        return text

    def test_syntax_without_import_or_bytecode(self) -> None:
        with tokenize.open(TARGET) as handle:
            compile(handle.read(), str(TARGET), "exec", dont_inherit=True)

    def test_normal_dual_engine_manifest_unicode_entitlements_and_nested_preservation(self) -> None:
        nested_before = digest(self.app / "Contents/Frameworks/Preserved.framework/signature-sentinel")
        report = self.package()
        self.assertEqual(report["status"], "packaged")
        self.assertEqual(report["runtimeVerification"], "not-run")
        self.assertGreaterEqual(report["signedNativeFiles"], 2)
        self.assertTrue((self.output / "Contents/Frameworks/Current.framework").is_symlink())
        self.assertEqual(nested_before, digest(self.output / "Contents/Frameworks/Preserved.framework/signature-sentinel"))
        for name, kind in (("AudioEngine.dengine", "d-audio-engine"), ("MRT2MusicEngine.dengine", "d-mrt2-music-engine")):
            engine = self.output / "Contents/Resources" / name
            manifest = json.loads((engine / "engine.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["kind"], kind)
            for item in manifest["files"]:
                path = engine / item["path"]
                self.assertEqual(path.stat().st_size, item["sizeBytes"])
                self.assertEqual(digest(path), item["sha256"])
        native = self.output / "Contents/Resources/AudioEngine.dengine/python/bin/python3"
        self.assertTrue(native.read_bytes().endswith(b"-SIGNED"))
        provider = self.output / "Contents/Resources/AudioEngine.dengine/provider/d_audio_contract.py"
        self.assertEqual(provider.read_bytes(), (ROOT / "Backends/Audio/Python/d_audio_contract.py").read_bytes())
        app_signs = [call for call in self.signing.calls if "--force" in call and call[-1].endswith(".app")]
        self.assertEqual(len(app_signs), 1)
        self.assertNotIn("--deep", app_signs[0])
        self.assertIn("--timestamp=none", app_signs[0])
        self.assertIn("runtime", app_signs[0])
        self.assertEqual(self.signing.signed_entitlements, self.signing.entitlements)
        self.assertTrue(self.signing.signed_entitlements["com.apple.security.get-task-allow"])

    def test_stderr_text_is_not_failure_and_main_reports_json(self) -> None:
        stdout = io.StringIO()
        stderr = io.StringIO()
        argv = [
            "--app", str(self.app), "--python-root", str(self.python),
            "--sa3-site-packages", str(self.sa3_site),
            "--mrt2-site-packages", str(self.mrt2_site),
            "--identity", IDENTITY, "--output", str(self.output),
        ]
        with mock.patch.object(package_audio_app, "_run_command", side_effect=self.signing), \
             mock.patch.object(sys, "stdout", stdout), mock.patch.object(sys, "stderr", stderr):
            status = package_audio_app.main(argv)
        self.assertEqual(status, 0, stderr.getvalue())
        self.assertEqual(json.loads(stdout.getvalue())["status"], "packaged")

    def test_missing_relative_malformed_and_bad_identity_inputs(self) -> None:
        missing = self.base / "missing.app"
        cases = (
            ("missing", dict(app=str(missing))),
            ("absolute", dict(app="relative.app")),
            ("40-character", dict(identity="adhoc")),
            ("absolute .app", dict(output=str(self.base / "not-an-app"))),
        )
        for expected, changes in cases:
            with self.subTest(expected=expected):
                self.assert_controlled_failure(expected, **changes)
        (self.app / "Contents/Info.plist").write_bytes(b"not a plist")
        self.assert_controlled_failure("malformed")

    def test_existing_output_overlap_and_symlink_paths_are_refused(self) -> None:
        self.output.mkdir()
        sentinel = self.output / "sentinel"
        sentinel.write_text("keep", encoding="utf-8")
        with mock.patch.object(package_audio_app, "_run_command", side_effect=self.signing):
            with self.assertRaises(package_audio_app.PackagingError):
                package_audio_app.package(self.arguments())
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep")
        shutil.rmtree(self.output)
        inside = self.app / "Contents/overlap.app"
        self.assert_controlled_failure("overlaps", output=str(inside))
        escaped = self.base / "outside"
        escaped.write_text("outside", encoding="utf-8")
        link = self.app / "Contents/Resources/escape"
        link.symlink_to(os.path.relpath(escaped, link.parent))
        self.assert_controlled_failure("escapes")

    def test_input_with_either_engine_is_refused(self) -> None:
        for name in package_audio_app.ENGINE_DIRECTORIES:
            with self.subTest(engine=name):
                engine = self.app / "Contents/Resources" / name
                engine.mkdir()
                self.assert_controlled_failure("already contains")
                engine.rmdir()

    def test_input_signature_identifier_team_and_sandbox_failures(self) -> None:
        for failure, expected in (("input-verify", "verify input"), ("missing-identity", "identifier"), ("missing-team", "TeamIdentifier")):
            with self.subTest(failure=failure):
                self.signing.failure = failure
                self.assert_controlled_failure(expected)
                self.signing.failure = None
        for entitlements in ({}, {"com.apple.security.app-sandbox": False}):
            with self.subTest(entitlements=entitlements):
                self.signing.entitlements = entitlements
                self.assert_controlled_failure("app-sandbox=true")

    def test_final_identifier_team_entitlements_and_verification_are_checked(self) -> None:
        cases = ("identifier", "team", "entitlements", "verify")
        for case in cases:
            with self.subTest(case=case):
                if case == "identifier":
                    self.signing.final_identifier = "com.example.changed"
                elif case == "team":
                    self.signing.final_team = "OTHERTEAM"
                elif case == "entitlements":
                    self.signing.final_entitlements = {"com.apple.security.app-sandbox": True}
                else:
                    self.signing.failure = "final-verify"
                self.assert_controlled_failure()
                self.signing = SigningFixture()

    def test_prepare_failures_preserve_input_and_do_not_publish(self) -> None:
        source_info = digest(self.app / "Contents/Info.plist")
        shutil.rmtree(self.sa3_site / "mlx")
        self.assert_controlled_failure("prepare AudioEngine")
        self.assertEqual(source_info, digest(self.app / "Contents/Info.plist"))
        (self.sa3_site / "mlx").mkdir()
        (self.sa3_site / "mlx/__init__.py").write_text("# fixture", encoding="utf-8")
        (self.mrt2_site / "mlx-0.31.1.dist-info/METADATA").write_text("Name: mlx\nVersion: 9\n", encoding="utf-8")
        self.assert_controlled_failure("prepare MRT2MusicEngine")
        self.assertEqual(source_info, digest(self.app / "Contents/Info.plist"))

    def test_sign_failure_and_timeout_do_not_publish(self) -> None:
        for failure, expected in (("sign", "command exited 9"), ("timeout", "timed out")):
            with self.subTest(failure=failure):
                self.signing.failure = failure
                self.assert_controlled_failure(expected)
                self.signing.failure = None

    def test_publication_collision_preserves_existing_destination(self) -> None:
        self.signing.publish_collision = self.output
        with mock.patch.object(package_audio_app, "_run_command", side_effect=self.signing):
            with self.assertRaises(package_audio_app.PackagingError) as caught:
                package_audio_app.package(self.arguments())
        self.assertIn("output appeared during publication", str(caught.exception))
        self.assertEqual((self.output / "sentinel").read_text(encoding="utf-8"), "keep")

    def test_real_cli_invalid_input_returns_two(self) -> None:
        command = [
            sys.executable, "-B", str(TARGET),
            "--app", "relative.app", "--python-root", str(self.python),
            "--sa3-site-packages", str(self.sa3_site),
            "--mrt2-site-packages", str(self.mrt2_site),
            "--identity", IDENTITY, "--output", str(self.output),
        ]
        result = subprocess.run(
            command,
            env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"),
            text=True,
            capture_output=True,
            timeout=20,
            check=False,
        )
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("app must be", result.stderr)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
