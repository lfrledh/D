from __future__ import annotations

import argparse
from contextlib import ExitStack, redirect_stderr
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


PACKAGING = Path(__file__).resolve().parents[1]
if str(PACKAGING) not in sys.path:
    sys.path.insert(0, str(PACKAGING))

import package_audio_app  # noqa: E402
import package_pitch_app  # noqa: E402
import prepare_engine  # noqa: E402
import prepare_pitch_engine  # noqa: E402


APP_IDENTIFIER = "dev.d-workstation.pitch-packaging-fixture"
TEAM_IDENTIFIER = "FIXTURETEAM"
IDENTITY = "A" * 40
SIMULATED_MODEL = b"controlled SwiftF0 model fixture; never executed"
SIMULATED_LICENSE = (
    "Copyright (c) Controlled Fixture Authors\n\n"
    "Permission is hereby granted to use, copy, modify, and distribute this "
    "controlled test material. This file models installed attribution material.\n"
)
APPROVED_MODEL = Path(
    "/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-HUM-PITCH-01/"
    "run-20260914T152228Z/venv/lib/python3.12/site-packages/swift_f0/model.onnx"
)


class PitchPackagingTests(unittest.TestCase):
    def setUp(self) -> None:
        explicit_root = os.environ.get("D_PITCH_PACKAGING_TEST_TMP") or os.environ.get("TMPDIR")
        self.temporary = tempfile.TemporaryDirectory(dir=explicit_root)
        self.root = Path(self.temporary.name)
        self.model_digest = hashlib.sha256(SIMULATED_MODEL).hexdigest()
        self.constants = mock.patch.multiple(
            prepare_pitch_engine,
            MODEL_SHA256=self.model_digest,
            MODEL_SIZE_BYTES=len(SIMULATED_MODEL),
        )
        self.constants.start()
        self.addCleanup(self.constants.stop)
        self.addCleanup(self.temporary.cleanup)

    def _python_root(self) -> Path:
        root = self.root / "python-root"
        (root / "bin").mkdir(parents=True)
        (root / "bin/python3.12").write_text("fixture interpreter\n", encoding="utf-8")
        (root / "lib/python3.12/encodings").mkdir(parents=True)
        (root / "lib/python3.12/LICENSE.txt").write_text("Python fixture license\n", encoding="utf-8")
        (root / "lib/python3.12/encodings/__init__.py").write_text("", encoding="utf-8")
        # This must never be copied as part of the standard library.
        (root / "lib/python3.12/site-packages/cache_package").mkdir(parents=True)
        (root / "lib/python3.12/site-packages/cache_package/__init__.py").write_text("", encoding="utf-8")
        return root

    def _site_packages(self) -> Path:
        site = self.root / "site-packages"
        site.mkdir()
        for name in prepare_pitch_engine.PACKAGE_DIRECTORIES:
            package = site / name
            package.mkdir()
            (package / "__init__.py").write_text("", encoding="utf-8")
        (site / "swift_f0/model.onnx").write_bytes(SIMULATED_MODEL)
        (site / "swift_f0/core.py").write_text("# controlled resolver-required fixture\n", encoding="utf-8")
        (site / "numpy.libs").mkdir()
        (site / "numpy.libs/libfixture.dylib").write_bytes(b"not a Mach-O")
        (site / "google/protobuf").mkdir(parents=True)
        (site / "google/protobuf/__init__.py").write_text("", encoding="utf-8")
        (site / "google/_upb").mkdir()
        (site / "google/_upb/__init__.py").write_text("", encoding="utf-8")
        (site / "google/unrelated").mkdir()
        (site / "google/unrelated/__init__.py").write_text("", encoding="utf-8")
        (site / "unapproved_package").mkdir()
        for name, version in prepare_pitch_engine.DISTRIBUTIONS.items():
            directory = site / f"{name.replace('-', '_')}-{version}.dist-info"
            directory.mkdir()
            (directory / "METADATA").write_text(
                f"Name: {name}\nVersion: {version}\nLicense: fixture-license\n",
                encoding="utf-8",
            )
            (directory / "licenses").mkdir()
            (directory / "licenses/LICENSE.txt").write_text(SIMULATED_LICENSE, encoding="utf-8")
            for record in prepare_pitch_engine.INSTALLATION_RECORDS:
                (directory / record).write_text("private installation data\n", encoding="utf-8")
        return site

    def _provider(self) -> Path:
        provider = self.root / "provider"
        provider.mkdir()
        for name in prepare_pitch_engine.PROVIDERS:
            (provider / name).write_text("# controlled provider fixture\n", encoding="utf-8")
        (provider / "must_not_be_copied.py").write_text("", encoding="utf-8")
        return provider

    def _prepare_args(self, output: Path, *, ack: bool = True) -> argparse.Namespace:
        return argparse.Namespace(
            python_root=str(self._python_root()),
            site_packages=str(self._site_packages()),
            provider_directory=str(self._provider()),
            output=str(output),
            internal_evaluation_ack=ack,
        )

    def _make_engine(self, name: str = "PitchFixture.dengine") -> Path:
        engine = self.root / name
        (engine / "python/bin").mkdir(parents=True)
        (engine / "python/bin/python3").write_text("fixture interpreter\n", encoding="utf-8")
        (engine / "provider").mkdir()
        for provider in prepare_pitch_engine.PROVIDERS:
            (engine / "provider" / provider).write_text("# fixture\n", encoding="utf-8")
        model = engine / "python/lib/python3.12/site-packages/swift_f0/model.onnx"
        model.parent.mkdir(parents=True)
        model.write_bytes(SIMULATED_MODEL)
        (model.parent / "core.py").write_text("# controlled resolver-required fixture\n", encoding="utf-8")
        (engine / "model-manifests").mkdir()
        (engine / "model-manifests/swift-f0.json").write_text(
            json.dumps(prepare_pitch_engine._model_declaration(), sort_keys=True) + "\n",
            encoding="utf-8",
        )
        self._refresh_engine_manifest(engine)
        return engine

    def _refresh_engine_manifest(self, engine: Path) -> None:
        manifest = prepare_pitch_engine._manifest(engine)
        (engine / "engine.json").write_text(json.dumps(manifest, sort_keys=True) + "\n", encoding="utf-8")

    def _make_app(self, name: str = "D-Fixture.app") -> Path:
        app = self.root / name
        (app / "Contents/Resources").mkdir(parents=True)
        (app / "Contents/MacOS").mkdir()
        (app / "Contents/MacOS/D-Fixture").write_text("fixture executable\n", encoding="utf-8")
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": APP_IDENTIFIER,
            "CFBundleExecutable": "D-Fixture",
        }))
        return app

    def _snapshot_tree(self, root: Path) -> tuple[tuple[str, str, str], ...]:
        result: list[tuple[str, str, str]] = []
        for current, directories, names in os.walk(root, followlinks=False):
            current_path = Path(current)
            for name in sorted(directories + names):
                path = current_path / name
                relative = path.relative_to(root).as_posix()
                if path.is_symlink():
                    result.append((relative, "symlink", os.readlink(path)))
                elif path.is_dir():
                    result.append((relative, "directory", ""))
                else:
                    result.append((relative, "file", hashlib.sha256(path.read_bytes()).hexdigest()))
        return tuple(result)

    def _package_args(
        self,
        app: Path,
        engine: Path,
        output: Path,
        report: Path,
        *,
        ack: bool = True,
    ) -> argparse.Namespace:
        return argparse.Namespace(
            app=str(app),
            engine=str(engine),
            identity=IDENTITY,
            output=str(output),
            report=str(report),
            internal_evaluation_ack=ack,
        )

    def _signing_fakes(self) -> ExitStack:
        stack = ExitStack()
        completed = subprocess.CompletedProcess(["fixture-codesign"], 0, "", "")
        stack.enter_context(mock.patch.object(package_audio_app, "_command", return_value=completed))
        stack.enter_context(mock.patch.object(
            package_audio_app,
            "_signature_metadata",
            return_value=(APP_IDENTIFIER, TEAM_IDENTIFIER),
        ))
        stack.enter_context(mock.patch.object(
            package_audio_app,
            "_entitlements",
            return_value=({"com.apple.security.app-sandbox": True}, b"fixture"),
        ))
        return stack

    def test_prepare_controlled_simulation_copies_only_fixed_components(self) -> None:
        output = self.root / "PitchEngine.dengine"
        prepare_pitch_engine.prepare(self._prepare_args(output))

        manifest = json.loads((output / "engine.json").read_text(encoding="utf-8"))
        declaration = json.loads((output / "model-manifests/swift-f0.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["kind"], "d-pitch-engine")
        self.assertEqual(declaration["distribution"], "internal-evaluation-only")
        self.assertEqual(declaration["weightLicense"], "unknown")
        self.assertEqual(declaration["provider"], "CPUExecutionProvider")
        self.assertFalse((output / "provider/must_not_be_copied.py").exists())
        self.assertFalse((output / "python/lib/python3.12/site-packages/unapproved_package").exists())
        self.assertFalse((output / "python/lib/python3.12/site-packages/google/unrelated").exists())
        self.assertFalse((output / "python/lib/python3.12/site-packages/cache_package").exists())
        self.assertTrue(
            (output / "python/lib/python3.12/site-packages/protobuf-7.36.1.dist-info/licenses/LICENSE.txt").is_file()
        )
        for current, _directories, names in os.walk(output):
            self.assertTrue(prepare_pitch_engine.INSTALLATION_RECORDS.isdisjoint(names), current)

    def test_prepare_refuses_missing_ack_without_output(self) -> None:
        output = self.root / "PitchEngine.dengine"
        with self.assertRaisesRegex(prepare_engine.PackagingError, "internal-evaluation-ack"):
            prepare_pitch_engine.prepare(self._prepare_args(output, ack=False))
        self.assertFalse(output.exists())

    def test_prepare_refuses_wrong_fixed_distribution_version(self) -> None:
        output = self.root / "PitchEngine.dengine"
        args = self._prepare_args(output)
        metadata = Path(args.site_packages) / "numpy-2.4.3.dist-info/METADATA"
        metadata.write_text("Name: numpy\nVersion: 0.0\nLicense: fixture\n", encoding="utf-8")
        with self.assertRaisesRegex(prepare_engine.PackagingError, "identity mismatch"):
            prepare_pitch_engine.prepare(args)
        self.assertFalse(output.exists())

    def test_prepare_refuses_missing_distribution_license(self) -> None:
        output = self.root / "PitchEngine.dengine"
        args = self._prepare_args(output)
        licenses = Path(args.site_packages) / "coloredlogs-15.0.1.dist-info/licenses"
        shutil.rmtree(licenses)
        # The METADATA License header deliberately remains: it is not enough.
        with self.assertRaisesRegex(prepare_engine.PackagingError, "actual LICENSE"):
            prepare_pitch_engine.prepare(args)
        self.assertFalse(output.exists())

    def test_approved_environment_source_validation_exposes_missing_flatbuffers_license(self) -> None:
        site = APPROVED_MODEL.parents[1]
        if not site.is_dir():
            self.skipTest("Lead-approved read-only site-packages is unavailable")
        with self.assertRaisesRegex(prepare_engine.PackagingError, "flatbuffers"):
            prepare_pitch_engine._selected_site_entries(site)

    def test_prepare_refuses_model_digest_mismatch(self) -> None:
        output = self.root / "PitchEngine.dengine"
        args = self._prepare_args(output)
        model = Path(args.site_packages) / "swift_f0/model.onnx"
        model.write_bytes(b"same-size-invalid-model".ljust(len(SIMULATED_MODEL), b"x"))
        with self.assertRaisesRegex(prepare_engine.PackagingError, "approved internal-evaluation artifact"):
            prepare_pitch_engine.prepare(args)
        self.assertFalse(output.exists())

    def test_approved_model_reference_has_frozen_digest_without_execution(self) -> None:
        if not APPROVED_MODEL.is_file():
            self.skipTest("Lead-approved read-only ONNX reference is unavailable")
        digest = hashlib.sha256()
        with APPROVED_MODEL.open("rb") as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(block)
        self.assertEqual(APPROVED_MODEL.stat().st_size, 399_114)
        self.assertEqual(
            digest.hexdigest(),
            "fa91bb45512b90339cf4b00a599ba8fe3a253c46419fcfe6b46df77a8a8336a5",
        )

    def test_package_controlled_signing_simulation_preserves_input(self) -> None:
        app = self._make_app()
        engine = self._make_engine()
        output = self.root / "D-Pitch.app"
        report = self.root / "package-report.json"
        original_info = (app / "Contents/Info.plist").read_bytes()
        with self._signing_fakes():
            result = package_pitch_app.package(self._package_args(app, engine, output, report))

        recorded = json.loads(report.read_text(encoding="utf-8"))
        self.assertEqual(result["status"], "packaged")
        self.assertEqual(recorded["packageKind"], "d-pitch-app-internal-evaluation")
        self.assertEqual(recorded["modelExecution"], "not-run")
        self.assertEqual(recorded["runtimeVerification"], "not-run")
        self.assertTrue((output / "Contents/Resources/PitchEngine.dengine").is_dir())
        self.assertEqual((app / "Contents/Info.plist").read_bytes(), original_info)
        self.assertFalse((app / "Contents/Resources/PitchEngine.dengine").exists())

    def test_package_refuses_missing_ack_and_writes_bounded_failure_report(self) -> None:
        app = self._make_app()
        engine = self._make_engine()
        output = self.root / "D-Pitch.app"
        report = self.root / "failure.json"
        with self.assertRaisesRegex(prepare_engine.PackagingError, "internal-evaluation-ack"):
            package_pitch_app.package(self._package_args(app, engine, output, report, ack=False))
        recorded = json.loads(report.read_text(encoding="utf-8"))
        self.assertEqual(recorded["status"], "failed")
        self.assertEqual(recorded["failedStage"], "validate-internal-evaluation-ack")
        self.assertEqual(recorded["producedFiles"], [])
        self.assertFalse(output.exists())

    def test_package_refuses_changed_model_license(self) -> None:
        app = self._make_app()
        engine = self._make_engine()
        declaration_path = engine / "model-manifests/swift-f0.json"
        declaration = json.loads(declaration_path.read_text(encoding="utf-8"))
        declaration["weightLicense"] = "invented"
        declaration_path.write_text(json.dumps(declaration) + "\n", encoding="utf-8")
        self._refresh_engine_manifest(engine)
        output = self.root / "D-Pitch.app"
        report = self.root / "failure.json"
        with self.assertRaisesRegex(prepare_engine.PackagingError, "fixed internal-evaluation profile"):
            package_pitch_app.package(self._package_args(app, engine, output, report))
        self.assertFalse(output.exists())

    def test_package_refuses_missing_resolver_required_core(self) -> None:
        app = self._make_app()
        engine = self._make_engine()
        (engine / "python/lib/python3.12/site-packages/swift_f0/core.py").unlink()
        self._refresh_engine_manifest(engine)
        output = self.root / "D-Pitch.app"
        report = self.root / "failure.json"
        with self.assertRaisesRegex(prepare_engine.PackagingError, "swift_f0/core.py"):
            package_pitch_app.package(self._package_args(app, engine, output, report))
        self.assertFalse(output.exists())

    def test_packager_limits_match_bundled_audio_engine_resolver(self) -> None:
        self.assertEqual(package_pitch_app.MAXIMUM_FILES, 10_000)
        self.assertEqual(package_pitch_app.MAXIMUM_FILE_BYTES, 512 * 1024 * 1024)
        self.assertEqual(package_pitch_app.MAXIMUM_AGGREGATE_BYTES, 1024 * 1024 * 1024)

    def test_package_refuses_file_and_aggregate_sizes_beyond_resolver(self) -> None:
        for index, boundary in enumerate(("file", "aggregate")):
            with self.subTest(boundary=boundary):
                app = self._make_app(f"D-Limit-{index}.app")
                engine = self._make_engine(f"PitchLimit-{index}.dengine")
                manifest_path = engine / "engine.json"
                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
                if boundary == "file":
                    manifest["files"][0]["sizeBytes"] = package_pitch_app.MAXIMUM_FILE_BYTES + 1
                    expected = "invalid type, value, digest, or path"
                else:
                    for entry in manifest["files"]:
                        entry["sizeBytes"] = 200 * 1024 * 1024
                    expected = "aggregate limit"
                manifest_path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")
                output = self.root / f"D-Limit-{index}-Output.app"
                report = self.root / f"limit-{index}.json"
                with self.assertRaisesRegex(prepare_engine.PackagingError, expected):
                    package_pitch_app.package(self._package_args(app, engine, output, report))
                self.assertFalse(output.exists())

    def test_package_refuses_engine_digest_mismatch(self) -> None:
        app = self._make_app()
        engine = self._make_engine()
        (engine / "provider/d_audio_access.py").write_text("changed after manifest\n", encoding="utf-8")
        output = self.root / "D-Pitch.app"
        report = self.root / "failure.json"
        with self.assertRaisesRegex(prepare_engine.PackagingError, "pre-sign verification"):
            package_pitch_app.package(self._package_args(app, engine, output, report))
        self.assertFalse(output.exists())

    def test_package_refuses_manifest_over_finite_file_limit(self) -> None:
        app = self._make_app()
        engine = self._make_engine()
        output = self.root / "D-Pitch.app"
        report = self.root / "failure.json"
        # Locally lower the production bound so this controlled fixture reaches
        # the count rejection without first exceeding the independent 4 MiB cap.
        with mock.patch.object(package_pitch_app, "MAXIMUM_FILES", 1):
            with self.assertRaisesRegex(prepare_engine.PackagingError, "finite limit"):
                package_pitch_app.package(self._package_args(app, engine, output, report))
        self.assertFalse(output.exists())

    def test_package_refuses_path_overlap(self) -> None:
        app = self._make_app()
        engine = self._make_engine()
        output = app / "Nested.app"
        report = self.root / "failure.json"
        with self.assertRaisesRegex(prepare_engine.PackagingError, "app/output.*failure report disabled"):
            package_pitch_app.package(self._package_args(app, engine, output, report))
        self.assertFalse(output.exists())

    def test_unsafe_report_inside_inputs_is_never_written_even_for_early_errors(self) -> None:
        for index, (target_name, failure_kind) in enumerate((
            ("app", "bad-ack"),
            ("engine", "bad-ack"),
            ("app", "bad-input"),
            ("engine", "bad-input"),
        )):
            with self.subTest(target=target_name, failure=failure_kind):
                app = self._make_app(f"D-Protected-{index}.app")
                engine = self._make_engine(f"PitchProtected-{index}.dengine")
                if failure_kind == "bad-input" and target_name == "app":
                    (app / "Contents/Info.plist").unlink()
                if failure_kind == "bad-input" and target_name == "engine":
                    (engine / "engine.json").unlink()
                protected = app if target_name == "app" else engine
                report = protected / "failure.json"
                output = self.root / f"D-Protected-Output-{index}.app"
                app_before = self._snapshot_tree(app)
                engine_before = self._snapshot_tree(engine)
                args = self._package_args(
                    app,
                    engine,
                    output,
                    report,
                    ack=failure_kind != "bad-ack",
                )
                with self.assertRaisesRegex(prepare_engine.PackagingError, "failure report disabled"):
                    package_pitch_app.package(args)
                self.assertEqual(self._snapshot_tree(app), app_before)
                self.assertEqual(self._snapshot_tree(engine), engine_before)
                self.assertFalse(report.exists())
                self.assertFalse(output.exists())

    def test_cli_routes_unsafe_report_failure_to_stderr_only(self) -> None:
        app = self._make_app()
        engine = self._make_engine()
        report = app / "Contents/Resources/failure.json"
        output = self.root / "D-Pitch.app"
        stderr = io.StringIO()
        with redirect_stderr(stderr):
            status = package_pitch_app.main([
                "--app", str(app),
                "--engine", str(engine),
                "--identity", IDENTITY,
                "--output", str(output),
                "--report", str(report),
                "--internal-evaluation-ack",
            ])
        self.assertEqual(status, 2)
        self.assertIn("failure report disabled", stderr.getvalue())
        self.assertFalse(report.exists())
        self.assertFalse(output.exists())

    def test_report_inside_symlinked_app_target_is_never_written(self) -> None:
        app = self._make_app()
        alias = self.root / "D-Alias.app"
        alias.symlink_to(app, target_is_directory=True)
        engine = self._make_engine()
        report = app / "Contents/Resources/failure.json"
        output = self.root / "D-Pitch.app"
        app_before = self._snapshot_tree(app)
        with self.assertRaisesRegex(prepare_engine.PackagingError, "failure report disabled"):
            package_pitch_app.package(self._package_args(alias, engine, output, report, ack=False))
        self.assertEqual(self._snapshot_tree(app), app_before)
        self.assertFalse(report.exists())
        self.assertFalse(output.exists())

    def test_package_never_overwrites_existing_output(self) -> None:
        app = self._make_app()
        engine = self._make_engine()
        output = self.root / "D-Pitch.app"
        output.mkdir()
        marker = output / "user-data"
        marker.write_text("preserve", encoding="utf-8")
        report = self.root / "failure.json"
        with self.assertRaisesRegex(prepare_engine.PackagingError, "already exists"):
            package_pitch_app.package(self._package_args(app, engine, output, report))
        self.assertEqual(marker.read_text(encoding="utf-8"), "preserve")
        self.assertEqual(json.loads(report.read_text(encoding="utf-8"))["status"], "failed")

    def test_package_never_overwrites_existing_report(self) -> None:
        app = self._make_app()
        engine = self._make_engine()
        output = self.root / "D-Pitch.app"
        report = self.root / "existing-report.json"
        report.write_text("preserve-report", encoding="utf-8")
        with self.assertRaisesRegex(prepare_engine.PackagingError, "already exists"):
            package_pitch_app.package(self._package_args(app, engine, output, report))
        self.assertFalse(output.exists())
        self.assertEqual(report.read_text(encoding="utf-8"), "preserve-report")

    def test_package_refuses_engine_symlink_without_touching_target(self) -> None:
        app = self._make_app()
        engine = self._make_engine()
        target = self.root / "user-original.py"
        target.write_text("preserve\n", encoding="utf-8")
        provider = engine / "provider/d_audio_access.py"
        provider.unlink()
        provider.symlink_to(target)
        output = self.root / "D-Pitch.app"
        report = self.root / "failure.json"
        with self.assertRaisesRegex(prepare_engine.PackagingError, "contains symlink"):
            package_pitch_app.package(self._package_args(app, engine, output, report))
        self.assertEqual(target.read_text(encoding="utf-8"), "preserve\n")
        self.assertFalse(output.exists())

    def test_package_reports_command_failure_and_timeout_without_output(self) -> None:
        for index, detail in enumerate(("command exited 9", "command timed out after 30s")):
            with self.subTest(detail=detail):
                app = self._make_app(f"D-Fixture-{index}.app")
                engine = self._make_engine(f"PitchFixture-{index}.dengine")
                output = self.root / f"D-Pitch-{index}.app"
                report = self.root / f"failure-{index}.json"
                with mock.patch.object(package_audio_app, "_command", side_effect=prepare_engine.PackagingError(detail)):
                    with self.assertRaisesRegex(prepare_engine.PackagingError, detail):
                        package_pitch_app.package(self._package_args(app, engine, output, report))
                recorded = json.loads(report.read_text(encoding="utf-8"))
                self.assertEqual(recorded["failedStage"], "verify-input-signature")
                self.assertEqual(recorded["producedFiles"], [])
                self.assertFalse(output.exists())

    def test_report_failure_after_publication_retains_output_and_original(self) -> None:
        app = self._make_app()
        engine = self._make_engine()
        output = self.root / "D-Pitch.app"
        report = self.root / "unwritable-report.json"
        original_info = (app / "Contents/Info.plist").read_bytes()
        with self._signing_fakes(), mock.patch.object(
            package_pitch_app,
            "_write_report_exclusive",
            side_effect=OSError("controlled report refusal"),
        ):
            with self.assertRaisesRegex(prepare_engine.PackagingError, "output retained"):
                package_pitch_app.package(self._package_args(app, engine, output, report))
        self.assertTrue(output.is_dir())
        self.assertFalse(report.exists())
        self.assertEqual((app / "Contents/Info.plist").read_bytes(), original_info)


if __name__ == "__main__":
    unittest.main()
