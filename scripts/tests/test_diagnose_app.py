import importlib.util
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
                return subprocess.CompletedProcess(argv, 1 if mode == "verify_fail" else 0, "", "warning")
            if "--entitlements" in argv:
                if mode == "bad_entitlements": return subprocess.CompletedProcess(argv, 0, "not plist", "")
                ent = {"com.apple.security.app-sandbox": True, "com.apple.security.files.user-selected.read-write": True, "com.apple.security.files.bookmarks.app-scope": True, "com.apple.security.network.client": True}
                if mode == "get_task_allow": ent["com.apple.security.get-task-allow"] = True
                if mode == "missing_entitlement": ent.pop("com.apple.security.network.client")
                if mode == "invalid_entitlement": ent["com.apple.security.app-sandbox"] = "yes"
                return subprocess.CompletedProcess(argv, 0, plistlib.dumps(ent).decode(), "normal note")
            if mode == "unsigned": return subprocess.CompletedProcess(argv, 1, "", "code object is not signed at all")
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
            for mode, expected in (("unsigned", 1), ("verify_fail", 1), ("missing_entitlement", 1), ("bad_entitlements", 2), ("invalid_entitlement", 2), ("missing", 2), ("timeout", 2)):
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


if __name__ == "__main__":
    unittest.main()
