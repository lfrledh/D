import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "summarize-ui-results.py"
spec = importlib.util.spec_from_file_location("summarize_ui_results", SCRIPT)
summary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(summary)


IDS = ["DUITests/testOne()", "DUITests/testTwo()"]


def dump(path, value):
    path.write_text(json.dumps(value), encoding="utf-8")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def plan():
    return {"schema_version": 1, "plan_id": "small", "plan_revision": 1, "target": "DUITests",
            "expected_test_ids": IDS, "source": {"path": "DUITests/DUITests.swift", "git_commit": "a", "sha256": "b"}}


def export(cases, container="Passed"):
    nodes = [{"nodeType": "Test Case", "name": ident.split("/")[1], "nodeIdentifier": ident, "result": result}
             for ident, result in cases]
    return {"devices": [{"deviceId": "device"}], "testPlanConfigurations": [{"configurationId": "config"}],
            "testNodes": [{"nodeType": "Test Plan", "name": "plan", "result": container, "children": [
                {"nodeType": "UI test bundle", "name": "DUITests", "children": nodes}]}]}


class SummarizeUIResultsTests(unittest.TestCase):
    def setUp(self):
        base = Path(os.environ["D_UI_RESULTS_TMP"])
        base.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=str(base))
        self.dir = Path(self.temp.name)
        self.plan_path = self.dir / "plan.json"
        self.plan_hash = dump(self.plan_path, plan())

    def tearDown(self):
        self.temp.cleanup()

    def attempt(self, payload=None, tests=None):
        tests_path = self.dir / "tests data.json"
        tests_hash = dump(tests_path, tests if tests is not None else export([(x, "Passed") for x in IDS]))
        value = {"schema_version": 1, "run_id": "run", "attempt_id": "one", "plan_id": "small", "plan_revision": 1,
                 "plan_sha256": self.plan_hash, "execution_state": "completed",
                 "evidence": {"format": "xcresulttool.test-results.tests", "schema_version": "0.1.0",
                              "tests_path": tests_path.name, "tests_sha256": tests_hash,
                              "source_xcresult": "/declared/original.xcresult"}}
        if payload:
            value.update(payload)
        attempt_path = self.dir / "attempt file.json"; dump(attempt_path, value)
        return attempt_path

    def run_cli(self, attempt, report="report output.json"):
        path = self.dir / report
        completed = subprocess.run([sys.executable, "-B", str(SCRIPT), "--plan", str(self.plan_path), "--attempt", str(attempt), "--report", str(path)],
                                   text=True, capture_output=True, check=False, timeout=5)
        return completed, path

    def test_all_passed_cli_is_silent_and_passes(self):
        completed, path = self.run_cli(self.attempt())
        self.assertEqual(completed.returncode, 0); self.assertEqual(completed.stdout, "")
        report = json.loads(path.read_text()); self.assertEqual(report["acceptance"], "PASS")
        self.assertEqual(report["counts"]["PASSED"], 2)

    def test_fixture_is_incomplete_against_frozen_plan(self):
        fixture = ROOT / "scripts/tests/fixtures/ui-results/observed-two-passed.json"
        frozen = ROOT / "scripts/plans/ui-acceptance-v1.json"
        frozen_hash = hashlib.sha256(frozen.read_bytes()).hexdigest()
        attempt = {"schema_version": 1, "run_id": "historical", "attempt_id": "six", "plan_id": "D-UI-complete", "plan_revision": 1,
                   "plan_sha256": frozen_hash, "execution_state": "completed", "evidence": {"format": "xcresulttool.test-results.tests", "schema_version": "0.1.0", "tests_path": str(fixture), "tests_sha256": hashlib.sha256(fixture.read_bytes()).hexdigest(), "source_xcresult": "/declared/old.xcresult"}}
        attempt_path = self.dir / "fixture attempt.json"; dump(attempt_path, attempt)
        result, code = summary.summarize(frozen, attempt_path)
        self.assertEqual(code, 1); self.assertEqual(result["acceptance"], "INCOMPLETE")
        self.assertEqual(result["counts"]["PASSED"], 2); self.assertEqual(result["counts"]["MISSING"], 6)

    def test_failed_expected_failure_unknown_and_skip_classify(self):
        for result_name, expected in [("Failed", "FAIL"), ("Expected Failure", "FAIL"), ("unknown", "UNKNOWN"), ("Skipped", "INCOMPLETE")]:
            with self.subTest(result_name=result_name):
                report, code = summary.summarize(self.plan_path, self.attempt(tests=export([(IDS[0], result_name), (IDS[1], "Passed")])) )
                self.assertEqual(code, 1); self.assertEqual(report["acceptance"], expected)

    def test_missing_empty_and_noncompleted_states(self):
        report, code = summary.summarize(self.plan_path, self.attempt(tests=export([])))
        self.assertEqual((code, report["counts"]["MISSING"]), (1, 2))
        for state, status, acceptance in [("not_started", "NOT_STARTED", "INCOMPLETE"), ("tool_error", "UNKNOWN", "UNKNOWN")]:
            with self.subTest(state=state):
                attempt = self.attempt({"execution_state": state, "reason": "upstream status", "evidence": None})
                report, code = summary.summarize(self.plan_path, attempt)
                self.assertEqual((code, report["tests"][0]["status"], report["acceptance"]), (1, status, acceptance))

    def test_complementary_attempts_do_not_merge_and_container_failure_fails(self):
        first, _ = summary.summarize(self.plan_path, self.attempt(tests=export([(IDS[0], "Passed")])))
        second, _ = summary.summarize(self.plan_path, self.attempt(tests=export([(IDS[1], "Passed")])))
        self.assertEqual((first["acceptance"], second["acceptance"]), ("INCOMPLETE", "INCOMPLETE"))
        report, code = summary.summarize(self.plan_path, self.attempt(tests=export([(IDS[0], "Passed"), (IDS[1], "Passed")], "Failed")))
        self.assertEqual((code, report["acceptance"]), (1, "FAIL"))

    def test_plan_and_export_hash_identity_are_enforced(self):
        bad = self.attempt({"plan_sha256": "0" * 64})
        with self.assertRaises(summary.InputError): summary.summarize(self.plan_path, bad)

    def test_cli_error_retains_known_plan_rows_and_attempt_provenance(self):
        attempt = self.attempt(tests=export([(IDS[0], "Passed"), (IDS[0], "Passed")]))
        completed, path = self.run_cli(attempt)
        report = json.loads(path.read_text())
        self.assertEqual((completed.returncode, report["tool_status"], report["acceptance"]), (2, "ERROR", "UNKNOWN"))
        self.assertEqual(report["plan"]["plan_id"], "small")
        self.assertEqual([item["status"] for item in report["tests"]], ["UNKNOWN", "UNKNOWN"])
        self.assertEqual(report["counts"]["UNKNOWN"], 2)
        self.assertEqual(report["evidence"]["attempt_sha256"], hashlib.sha256(attempt.read_bytes()).hexdigest())
        self.assertEqual(report["evidence"]["source_xcresult_provenance"], "caller_declared_unverified")

    def test_cli_rejects_bool_float_versions_and_nonstring_result(self):
        cases = [
            {"schema_version": True}, {"schema_version": 1.0}, {"plan_revision": True},
        ]
        for change in cases:
            with self.subTest(change=change):
                completed, path = self.run_cli(self.attempt(change), "bad-" + str(len(change)) + "-" + str(id(change)) + ".json")
                report = json.loads(path.read_text())
                self.assertEqual((completed.returncode, report["tool_status"], report["counts"]["UNKNOWN"]), (2, "ERROR", 2))
        completed, path = self.run_cli(self.attempt(tests=export([(IDS[0], []), (IDS[1], "Passed")])), "result-list.json")
        report = json.loads(path.read_text())
        self.assertEqual((completed.returncode, report["tool_status"], report["counts"]["UNKNOWN"]), (2, "ERROR", 2))
        bad = self.attempt({"evidence": {"format": "xcresulttool.test-results.tests", "schema_version": "0.1.0", "tests_path": "tests data.json", "tests_sha256": "0" * 64, "source_xcresult": "/declared/original.xcresult"}})
        with self.assertRaises(summary.InputError): summary.summarize(self.plan_path, bad)

    def test_cli_rejects_boolean_plan_schema_version(self):
        invalid_plan = self.dir / "boolean plan.json"
        value = plan(); value["schema_version"] = True; dump(invalid_plan, value)
        report_path = self.dir / "invalid-plan-report.json"
        completed = subprocess.run([sys.executable, "-B", str(SCRIPT), "--plan", str(invalid_plan), "--attempt", str(self.attempt()), "--report", str(report_path)],
                                   text=True, capture_output=True, check=False, timeout=5)
        report = json.loads(report_path.read_text())
        self.assertEqual((completed.returncode, report["tool_status"], report["tests"]), (2, "ERROR", None))

    def test_duplicate_unknown_and_malformed_structures_are_errors(self):
        for body in [export([(IDS[0], "Passed"), (IDS[0], "Passed")]), export([("DUITests/other()", "Passed")]), {"devices": [], "testPlanConfigurations": [], "testNodes": []}]:
            with self.subTest(body=body):
                with self.assertRaises(summary.InputError): summary.summarize(self.plan_path, self.attempt(tests=body))
        raw = self.dir / "bad.json"; raw.write_text('{"a": 1, "a": 2}', encoding="utf-8")
        with self.assertRaises(summary.InputError): summary.read_json(raw)
        raw.write_text('{"number": NaN}', encoding="utf-8")
        with self.assertRaises(summary.InputError): summary.read_json(raw)

    def test_bad_children_retry_and_passed_failure_message_are_errors(self):
        bad = export([(IDS[0], "Passed")]); bad["testNodes"][0]["children"] = {}
        with self.assertRaises(summary.InputError): summary.summarize(self.plan_path, self.attempt(tests=bad))
        retry = export([(IDS[0], "Passed")]); retry["testNodes"][0]["children"][0]["children"].append({"nodeType": "Repetition", "name": "retry"})
        with self.assertRaises(summary.InputError): summary.summarize(self.plan_path, self.attempt(tests=retry))
        contradictory = export([(IDS[0], "Passed")]); contradictory["testNodes"][0]["children"][0]["children"][0]["children"] = [{"nodeType": "Failure Message", "name": "failure"}]
        with self.assertRaises(summary.InputError): summary.summarize(self.plan_path, self.attempt(tests=contradictory))
        multiple = export([]); multiple["devices"].append({"deviceId": "second"})
        with self.assertRaises(summary.InputError): summary.summarize(self.plan_path, self.attempt(tests=multiple))

    def test_cli_protects_existing_missing_parent_symlink_and_xcresult_output(self):
        attempt = self.attempt(); existing = self.dir / "exists.json"; existing.write_text("keep")
        for name in ("exists.json", "missing/report.json"):
            completed, _ = self.run_cli(attempt, name); self.assertEqual(completed.returncode, 2)
        link = self.dir / "link.json"; link.symlink_to(existing)
        completed, _ = self.run_cli(attempt, "link.json"); self.assertEqual(completed.returncode, 2)
        bundle = self.dir / "source.xcresult"; bundle.mkdir()
        completed, _ = self.run_cli(attempt, "source.xcresult/report.json"); self.assertEqual(completed.returncode, 2)
        completed, path = self.run_cli(attempt, "报告.json")
        self.assertEqual(completed.returncode, 0); self.assertTrue(path.exists())


if __name__ == "__main__":
    unittest.main()
