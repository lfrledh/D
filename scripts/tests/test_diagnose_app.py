import importlib.util
import json
import math
import os
import sys
import plistlib
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).parents[1] / "diagnose-app.py"
SPEC = importlib.util.spec_from_file_location("diagnose_app", SCRIPT)
diagnose_app = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(diagnose_app)


class DiagnoseAppTests(unittest.TestCase):
    def make_app(self, root, executable="D"):
        app = root / "测试 app;$(bad).app"
        binary = app / "Contents/MacOS" / executable
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b"binary")
        with (app / "Contents/Info.plist").open("wb") as out:
            plistlib.dump({"CFBundleExecutable": executable, "CFBundleIdentifier": "first-test.D"}, out)
        return app

    def runner(self, mode="good"):
        def run(argv, **kwargs):
            if mode == "timeout":
                raise subprocess.TimeoutExpired(argv, 0.01)
            if mode == "missing":
                raise FileNotFoundError("codesign")
            if "--verify" in argv:
                if mode == "verify_timeout":
                    raise subprocess.TimeoutExpired(argv, 0.01)
                return subprocess.CompletedProcess(argv, 1 if mode == "verify_fail" else 0, "", "warning")
            if "--entitlements" in argv:
                if mode == "entitlements_timeout":
                    raise subprocess.TimeoutExpired(argv, 0.01)
                if mode == "bad_entitlements": return subprocess.CompletedProcess(argv, 0, "not plist", "")
                if mode == "array_entitlements": return subprocess.CompletedProcess(argv, 0, plistlib.dumps(["not", "dict"]).decode(), "")
                ent = {"com.apple.security.app-sandbox": True, "com.apple.security.files.user-selected.read-write": True, "com.apple.security.files.bookmarks.app-scope": True, "com.apple.security.network.client": True}
                if mode == "get_task_allow": ent["com.apple.security.get-task-allow"] = True
                if mode == "get_task_allow_false": ent["com.apple.security.get-task-allow"] = False
                if mode == "missing_entitlement": ent.pop("com.apple.security.network.client")
                if mode == "invalid_entitlement": ent["com.apple.security.app-sandbox"] = "yes"
                if mode == "false_entitlement": ent["com.apple.security.app-sandbox"] = False
                if mode == "invalid_library_validation": ent["com.apple.security.cs.disable-library-validation"] = "yes"
                if mode == "data_debug": ent["com.apple.security.get-task-allow"] = b"data"
                return subprocess.CompletedProcess(argv, 0, plistlib.dumps(ent).decode(), "normal note")
            if mode == "unsigned": return subprocess.CompletedProcess(argv, 1, "", "code object is not signed at all")
            if mode == "certificate":
                return subprocess.CompletedProcess(argv, 0, "", "Identifier=first-test.D\nAuthority=Apple Development: Example\nnormal note")
            if mode == "display_error":
                return subprocess.CompletedProcess(argv, 1, "", "display failed")
            return subprocess.CompletedProcess(argv, 0, "", "Identifier=first-test.D\nSignature=adhoc\nnormal note")
        return run

    def test_valid_adhoc_is_pass_and_preserves_argv(self):
        with tempfile.TemporaryDirectory() as raw:
            app = self.make_app(Path(raw))
            report, code = diagnose_app.diagnose(app, runner=self.runner())
        self.assertEqual(code, 0)
        self.assertEqual(report["overall"]["status"], "PASS")
        self.assertEqual(report["checks"]["signature"]["evidence"]["classification"], "ad-hoc")
        self.assertEqual(report["commands"][0]["argv"][-1], str(app.resolve()))

    def test_invalid_structures_are_tool_errors(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            for path in (root / "missing.app", root / "file.app"):
                if path.name == "file.app": path.write_text("x")
                report, code = diagnose_app.diagnose(path, runner=self.runner())
                self.assertEqual(code, 2)
                self.assertTrue(report["tool_errors"])
            incomplete = root / "incomplete.app"; incomplete.mkdir()
            report, code = diagnose_app.diagnose(incomplete, runner=self.runner())
            self.assertEqual(code, 2)
            app = self.make_app(root)
            with (app / "Contents/Info.plist").open("wb") as out:
                plistlib.dump({"CFBundleExecutable": "../escape"}, out)
            report, code = diagnose_app.diagnose(app, runner=self.runner())
            self.assertEqual(code, 2)

    def test_signed_failures_and_unknowns(self):
        with tempfile.TemporaryDirectory() as raw:
            app = self.make_app(Path(raw))
            for mode, expected in (("unsigned", 1), ("verify_fail", 1), ("missing_entitlement", 1), ("bad_entitlements", 2), ("array_entitlements", 2), ("invalid_entitlement", 2), ("verify_timeout", 2), ("entitlements_timeout", 2), ("missing", 2), ("timeout", 2)):
                report, code = diagnose_app.diagnose(app, timeout=.01, runner=self.runner(mode))
                self.assertEqual(code, expected, mode)
                if mode == "bad_entitlements": self.assertEqual(report["checks"]["entitlements"]["status"], "UNKNOWN")

    def test_report_must_be_new_and_outside_app(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw); app = self.make_app(root)
            report, _ = diagnose_app.diagnose(app, runner=self.runner())
            existing = root / "exists.json"; existing.write_text("keep")
            with self.assertRaises(ValueError): diagnose_app.write_report(existing, report)
            with self.assertRaises(ValueError): diagnose_app.write_report(app / "inside.json", report)

    def test_get_task_allow_is_observed_but_not_a_failure(self):
        with tempfile.TemporaryDirectory() as raw:
            app = self.make_app(Path(raw))
            report, code = diagnose_app.diagnose(app, runner=self.runner("get_task_allow"))
            self.assertEqual(code, 0)
            self.assertEqual(report["checks"]["entitlements"]["evidence"]["com.apple.security.get-task-allow"]["state"], "true")
            report, code = diagnose_app.diagnose(app, runner=self.runner("get_task_allow_false"))
            self.assertEqual(code, 0)
            self.assertEqual(report["checks"]["entitlements"]["evidence"]["com.apple.security.get-task-allow"]["state"], "false")
            report, code = diagnose_app.diagnose(app, runner=self.runner())
            self.assertEqual(code, 0)
            self.assertEqual(report["checks"]["entitlements"]["evidence"]["com.apple.security.get-task-allow"]["state"], "missing")

    def test_bundle_identifier_and_entitlement_type_rules(self):
        with tempfile.TemporaryDirectory() as raw:
            app = self.make_app(Path(raw))
            certificate_report, certificate_code = diagnose_app.diagnose(app, runner=self.runner("certificate"))
            self.assertEqual(certificate_code, 0)
            self.assertEqual(certificate_report["checks"]["signature"]["evidence"]["classification"], "certificate-backed")
            (app / "Contents/MacOS/D").unlink()
            missing_report, missing_code = diagnose_app.diagnose(app, runner=self.runner())
            self.assertEqual(missing_code, 2)
            self.assertIn("missing", missing_report["checks"]["artifact"]["reason"])
            (app / "Contents/MacOS/D").write_bytes(b"binary")
            with (app / "Contents/Info.plist").open("wb") as out:
                plistlib.dump({"CFBundleExecutable": "D", "CFBundleIdentifier": "wrong.bundle"}, out)
            report, code = diagnose_app.diagnose(app, runner=self.runner())
            self.assertEqual(code, 1)
            self.assertEqual(report["rules"]["expected_bundle_identifier"]["status"], "FAIL")
            for mode, expected in (("false_entitlement", 1), ("invalid_library_validation", 2), ("data_debug", 2), ("display_error", 2)):
                with (app / "Contents/Info.plist").open("wb") as out:
                    plistlib.dump({"CFBundleExecutable": "D", "CFBundleIdentifier": "first-test.D"}, out)
                report, code = diagnose_app.diagnose(app, runner=self.runner(mode))
                self.assertEqual(code, expected, mode)
                json.dumps(report)
                if mode == "display_error":
                    self.assertTrue(any("codesign_display" in error for error in report["tool_errors"]))

    def test_corrupt_plist_symlink_and_timeout_report_are_complete(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw); app = self.make_app(root)
            (app / "Contents/Info.plist").write_bytes(b"<?xml version='1.0'?><plist><dict><key>broken")
            report, code = diagnose_app.diagnose(app, runner=self.runner())
            self.assertEqual(code, 2); self.assertIn("overall", report); json.dumps(report)
            app = self.make_app(root / "non-dict")
            with (app / "Contents/Info.plist").open("wb") as output:
                plistlib.dump(["not", "a dictionary"], output)
            report, code = diagnose_app.diagnose(app, runner=self.runner())
            self.assertEqual(code, 2)
            app = self.make_app(root / "again")
            outside = root / "outside"; outside.write_bytes(b"fixture")
            (app / "Contents/MacOS/D").unlink(); (app / "Contents/MacOS/D").symlink_to(outside)
            report, code = diagnose_app.diagnose(app, runner=self.runner())
            self.assertEqual(code, 2); self.assertIn("outside the bundle", report["checks"]["artifact"]["reason"])
            def bytes_timeout(argv, **kwargs):
                raise subprocess.TimeoutExpired(argv, .01, output=b"stdout", stderr=b"stderr")
            report, code = diagnose_app.diagnose(self.make_app(root / "timeout"), runner=bytes_timeout)
            self.assertEqual(code, 2); json.dumps(report)

    def test_report_policy_and_finite_timeout(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw); app = self.make_app(root); report, code = diagnose_app.diagnose(app, runner=self.runner())
            target = root / "report.json"; diagnose_app.write_report(target, report)
            self.assertEqual(json.loads(target.read_text())["overall"]["status"], "PASS")
            original = target.read_bytes()
            with self.assertRaises(ValueError): diagnose_app.write_report(target, report)
            self.assertEqual(target.read_bytes(), original)
            for value in (0, -1, math.inf, math.nan):
                failed, exit_code = diagnose_app.diagnose(app, timeout=value, runner=self.runner())
                self.assertEqual(exit_code, 2); self.assertIn("overall", failed)

    def test_actual_cpu_timeout_is_reaped(self):
        evidence = diagnose_app.run_command(
            [sys.executable, "-c", "import os,time; print(os.getpid(), flush=True); time.sleep(5)"],
            timeout=.5,
        )
        self.assertTrue(evidence["timed_out"])
        self.assertIsNone(evidence["returncode"])
        child_pid = int(evidence["stdout"].strip())
        with self.assertRaises(ProcessLookupError):
            os.kill(child_pid, 0)

    def test_macos_symlink_and_nonfinite_plist_values_are_safe(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            app = self.make_app(root)
            outside = root / "outside-macos"
            outside.mkdir()
            return_file = app / "Contents/return-file"
            return_file.write_bytes(b"controlled fixture")
            (outside / "D").symlink_to(return_file)
            (app / "Contents/MacOS/D").unlink()
            (app / "Contents/MacOS").rmdir()
            (app / "Contents/MacOS").symlink_to(outside, target_is_directory=True)
            report, code = diagnose_app.diagnose(app, runner=self.runner())
            self.assertEqual(code, 2)
            self.assertEqual(report["commands"], [])
            self.assertIn("outside the bundle", report["checks"]["artifact"]["evidence"])
            app = self.make_app(root / "finite")
            with (app / "Contents/Info.plist").open("wb") as output:
                plistlib.dump({"CFBundleExecutable": "D", "CFBundleIdentifier": "first-test.D", "CFBundleVersion": float("nan")}, output)
            report, code = diagnose_app.diagnose(app, runner=self.runner())
            self.assertEqual(code, 0)
            json.dumps(report, allow_nan=False)
            self.assertEqual(report["checks"]["artifact"]["evidence"]["CFBundleVersion"]["type"], "float")


if __name__ == "__main__":
    unittest.main()
