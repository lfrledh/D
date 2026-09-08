#!/usr/bin/env python3
"""Summarize one explicitly selected UI-test attempt, without invoking Xcode."""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import sys


STATUSES = ("PASSED", "FAILED", "SKIPPED", "EXPECTED_FAILURE", "UNKNOWN", "MISSING", "NOT_STARTED")
RESULT_TO_STATUS = {"Passed": "PASSED", "Failed": "FAILED", "Skipped": "SKIPPED",
                    "Expected Failure": "EXPECTED_FAILURE", "unknown": "UNKNOWN"}
CONTAINERS = {"Test Plan", "UI test bundle", "Test Suite"}
ANNOTATIONS = {"Failure Message", "Runtime Warning", "Source Code Reference", "Attachment",
               "Expression", "Test Value"}


class InputError(Exception):
    pass


def no_constant(value):
    raise ValueError("non-standard JSON constant: " + value)


def no_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate object key: " + str(key))
        result[key] = value
    return result


def read_json(path, provenance=None, path_key=None, hash_key=None):
    if provenance is not None:
        provenance[path_key] = str(path)
    try:
        raw = path.read_bytes()
        if provenance is not None:
            provenance[hash_key] = sha(raw)
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=no_duplicates,
                           parse_constant=no_constant)
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as error:
        raise InputError("cannot read valid JSON " + str(path) + ": " + str(error))
    return raw, value


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def nonempty_string(value, label):
    if not isinstance(value, str) or not value:
        raise InputError(label + " must be a non-empty string")
    return value


def positive_int(value, label):
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise InputError(label + " must be a positive integer")
    return value


def exact_integer(value, label, expected=None):
    if isinstance(value, bool) or not isinstance(value, int) or (expected is not None and value != expected):
        suffix = " must be " + str(expected) if expected is not None else " must be an integer"
        raise InputError(label + suffix)
    return value


def load_plan(path, provenance=None):
    raw, plan = read_json(path, provenance, "path", "sha256")
    if not isinstance(plan, dict):
        raise InputError("plan must be an object")
    exact_integer(plan.get("schema_version"), "plan schema_version", 1)
    plan_id = nonempty_string(plan.get("plan_id"), "plan_id")
    revision = positive_int(plan.get("plan_revision"), "plan_revision")
    if plan.get("target") != "DUITests":
        raise InputError("plan target must be DUITests")
    ids = plan.get("expected_test_ids")
    if not isinstance(ids, list) or not ids or any(not isinstance(x, str) or not x for x in ids) or len(set(ids)) != len(ids):
        raise InputError("expected_test_ids must be a non-empty unique string list")
    source = plan.get("source")
    if not isinstance(source, dict):
        raise InputError("plan source must be an object")
    for key in ("path", "git_commit", "sha256"):
        nonempty_string(source.get(key), "source." + key)
    return raw, plan, ids, plan_id, revision


def resolved_existing(path, label):
    try:
        return path.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise InputError(label + " cannot be resolved: " + str(error))


def validate_attempt(attempt, attempt_path, plan_id, revision, plan_hash):
    if not isinstance(attempt, dict):
        raise InputError("attempt must be an object")
    exact_integer(attempt.get("schema_version"), "attempt schema_version", 1)
    run_id = nonempty_string(attempt.get("run_id"), "run_id")
    attempt_id = nonempty_string(attempt.get("attempt_id"), "attempt_id")
    exact_integer(attempt.get("plan_revision"), "attempt plan_revision")
    if attempt.get("plan_id") != plan_id or attempt.get("plan_revision") != revision or attempt.get("plan_sha256") != plan_hash:
        raise InputError("attempt plan identity does not match the supplied plan bytes")
    state = attempt.get("execution_state")
    if state not in ("completed", "not_started", "tool_error"):
        raise InputError("invalid execution_state")
    evidence = attempt.get("evidence")
    if state != "completed":
        if evidence is not None or not isinstance(attempt.get("reason"), str) or not attempt["reason"]:
            raise InputError("non-completed attempt requires non-empty reason and null evidence")
        return run_id, attempt_id, state, None, None
    if not isinstance(evidence, dict) or evidence.get("format") != "xcresulttool.test-results.tests" or evidence.get("schema_version") != "0.1.0":
        raise InputError("completed attempt has unsupported evidence format/version")
    tests_path = nonempty_string(evidence.get("tests_path"), "evidence.tests_path")
    tests_hash = nonempty_string(evidence.get("tests_sha256"), "evidence.tests_sha256")
    source = nonempty_string(evidence.get("source_xcresult"), "evidence.source_xcresult")
    if not Path(source).is_absolute() or not source.endswith(".xcresult"):
        raise InputError("source_xcresult must be an absolute .xcresult path")
    candidate = Path(tests_path)
    if not candidate.is_absolute():
        candidate = attempt_path.parent / candidate
    return run_id, attempt_id, state, resolved_existing(candidate, "tests_path"), evidence


def walk_nodes(nodes, expected, cases, container_results, in_bundle=False, in_case=False, passed_case=False, pointer="/testNodes"):
    if not isinstance(nodes, list):
        raise InputError("children/testNodes must be a list")
    for index, node in enumerate(nodes):
        node_pointer = pointer + "/" + str(index)
        if not isinstance(node, dict):
            raise InputError("test node must be an object")
        kind = nonempty_string(node.get("nodeType"), "nodeType")
        nonempty_string(node.get("name"), "node name")
        children = node.get("children", [])
        if not isinstance(children, list):
            raise InputError("node children must be a list")
        result = node.get("result")
        if "result" in node and (not isinstance(result, str) or result not in RESULT_TO_STATUS):
            raise InputError("invalid node result")
        if kind == "Test Case":
            if not in_bundle or in_case:
                raise InputError("Test Case must occur in a DUITests UI test bundle and cannot nest")
            if result is None:
                raise InputError("Test Case result is required")
            ident = nonempty_string(node.get("nodeIdentifier"), "Test Case nodeIdentifier")
            if ident not in expected:
                raise InputError("unknown test ID: " + ident)
            if ident in cases:
                raise InputError("duplicate test ID: " + ident)
            cases[ident] = (RESULT_TO_STATUS[result], node_pointer)
            walk_nodes(children, expected, cases, container_results, in_bundle, True, result == "Passed", node_pointer + "/children")
        elif kind in CONTAINERS:
            if in_case:
                raise InputError("Test Case cannot contain a test container")
            if kind == "UI test bundle" and node["name"] != "DUITests":
                raise InputError("UI test bundle must be named DUITests")
            if result is not None:
                container_results.append(result)
            walk_nodes(children, expected, cases, container_results,
                       in_bundle or (kind == "UI test bundle" and node["name"] == "DUITests"), False, False, node_pointer + "/children")
        elif kind in ANNOTATIONS and in_case:
            if passed_case and kind == "Failure Message":
                raise InputError("Passed test contains Failure Message")
            walk_nodes(children, expected, cases, container_results, in_bundle, True, passed_case, node_pointer + "/children")
        else:
            raise InputError("unsupported nodeType: " + kind)


def parse_tests(tests, expected):
    if not isinstance(tests, dict):
        raise InputError("tests export must be an object")
    for key in ("devices", "testPlanConfigurations", "testNodes"):
        if not isinstance(tests.get(key), list):
            raise InputError("tests export missing array " + key)
    if len(tests["devices"]) != 1 or len(tests["testPlanConfigurations"]) != 1:
        raise InputError("multiple devices/configurations are unsupported")
    device, config = tests["devices"][0], tests["testPlanConfigurations"][0]
    if not isinstance(device, dict) or not isinstance(config, dict):
        raise InputError("device/configuration must be objects")
    nonempty_string(device.get("deviceId"), "deviceId")
    nonempty_string(config.get("configurationId"), "configurationId")
    # Repetition and Test Case Run are deliberately rejected by node validation.
    cases, containers = {}, []
    walk_nodes(tests["testNodes"], set(expected), cases, containers)
    return cases, containers


def counts_for(tests):
    return {status: sum(1 for item in tests if item["status"] == status) for status in STATUSES}


def make_report(plan, plan_path, plan_hash, run_id, attempt_id, state, attempt_path, tests_path=None, tests_hash=None, evidence=None, attempt_hash=None):
    return {"schema_version": 1, "tool_status": "OK", "acceptance": "UNKNOWN", "run_id": run_id,
            "attempt_id": attempt_id, "execution_state": state,
            "plan": {"plan_id": plan.get("plan_id") if isinstance(plan, dict) else None,
                     "plan_revision": plan.get("plan_revision") if isinstance(plan, dict) else None,
                     "sha256": plan_hash, "path": str(plan_path) if plan_path else None},
            "tests": None, "counts": None, "issues": [],
            "evidence": {"attempt_path": str(attempt_path) if attempt_path else None, "attempt_sha256": attempt_hash,
                         "tests_path": str(tests_path) if tests_path else None, "tests_sha256": tests_hash,
                         "source_xcresult": evidence.get("source_xcresult") if evidence else None,
                         "source_xcresult_provenance": "caller_declared_unverified" if evidence and evidence.get("source_xcresult") is not None else None,
                         "format": evidence.get("format") if evidence else None,
                         "schema_version": evidence.get("schema_version") if evidence else None}}


def summarize(plan_path, attempt_path, report=None):
    # Update one report as bytes are read, so an error preserves the evidence
    # already obtained without re-reading inputs or retaining partial test results.
    if report is None:
        report = make_report(None, None, None, None, None, None, None)
    plan_path = resolved_existing(plan_path, "plan")
    plan_raw, plan, expected, plan_id, revision = load_plan(plan_path, report["plan"])
    plan_hash = sha(plan_raw)
    report["plan"].update(plan_id=plan_id, plan_revision=revision)
    report["tests"] = [{"test_id": ident, "status": "UNKNOWN", "reason": None,
                        "evidence_pointer": None} for ident in expected]
    attempt_path = resolved_existing(attempt_path, "attempt")
    attempt_raw, attempt = read_json(attempt_path, report["evidence"], "attempt_path", "attempt_sha256")
    known_attempt_fields(report, attempt, attempt_path, sha(attempt_raw))
    run_id, attempt_id, state, tests_path, evidence = validate_attempt(attempt, attempt_path, plan_id, revision, plan_hash)
    if state == "not_started":
        report["tests"] = [{"test_id": ident, "status": "NOT_STARTED", "reason": attempt["reason"], "evidence_pointer": None} for ident in expected]
        report["counts"] = counts_for(report["tests"]); report["acceptance"] = "INCOMPLETE"; return report, 1
    if state == "tool_error":
        report["tests"] = [{"test_id": ident, "status": "UNKNOWN", "reason": attempt["reason"], "evidence_pointer": None} for ident in expected]
        report["counts"] = counts_for(report["tests"]); report["acceptance"] = "UNKNOWN"; return report, 1
    tests_raw, tests_json = read_json(tests_path, report["evidence"], "tests_path", "tests_sha256")
    if evidence["tests_sha256"] != sha(tests_raw):
        raise InputError("tests_sha256 does not match tests bytes")
    report["evidence"]["tests_sha256"] = sha(tests_raw)
    cases, containers = parse_tests(tests_json, expected)
    report["tests"] = [{"test_id": ident, "status": cases.get(ident, ("MISSING", None))[0],
                        "reason": None if ident in cases else "not observed in this attempt",
                        "evidence_pointer": cases.get(ident, (None, None))[1]} for ident in expected]
    report["counts"] = counts_for(report["tests"])
    observed = set(item["status"] for item in report["tests"])
    if "FAILED" in observed or "EXPECTED_FAILURE" in observed or "Expected Failure" in containers or "Failed" in containers:
        report["acceptance"] = "FAIL"
    elif "UNKNOWN" in observed or "unknown" in containers:
        report["acceptance"] = "UNKNOWN"
    elif "SKIPPED" in observed or "EXPECTED_FAILURE" in observed or "MISSING" in observed or "Skipped" in containers:
        report["acceptance"] = "INCOMPLETE"
    else:
        report["acceptance"] = "PASS"
    return report, 0 if report["acceptance"] == "PASS" else 1


def safe_output_path(value):
    path = Path(value)
    if os.path.lexists(str(path)):
        raise InputError("report path already exists or is a symlink")
    parent = path.parent
    if not parent.is_dir():
        raise InputError("report parent directory does not exist")
    resolved = parent.resolve(strict=True) / path.name
    if any(part.endswith(".xcresult") for part in resolved.parts):
        raise InputError("report may not be written inside an .xcresult directory")
    return resolved


def write_report(path, report):
    data = (json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as output:
        output.write(data)


def known_attempt_fields(report, attempt, attempt_path, attempt_hash):
    report["evidence"]["attempt_path"] = str(attempt_path)
    report["evidence"]["attempt_sha256"] = attempt_hash
    if not isinstance(attempt, dict):
        return
    for key in ("run_id", "attempt_id"):
        if isinstance(attempt.get(key), str) and attempt[key]:
            report[key] = attempt[key]
    if attempt.get("execution_state") in ("completed", "not_started", "tool_error"):
        report["execution_state"] = attempt["execution_state"]
    evidence = attempt.get("evidence")
    if isinstance(evidence, dict):
        for key in ("format", "schema_version", "source_xcresult"):
            if isinstance(evidence.get(key), str) and evidence[key]:
                report["evidence"][key] = evidence[key]
        if isinstance(evidence.get("source_xcresult"), str) and evidence["source_xcresult"]:
            report["evidence"]["source_xcresult_provenance"] = "caller_declared_unverified"


def error_with_known_plan(report, expected, reason):
    report["tool_status"] = "ERROR"
    report["acceptance"] = "UNKNOWN"
    report["issues"].append({"code": "INPUT_ERROR", "reason": reason})
    if expected is not None:
        report["tests"] = [{"test_id": ident, "status": "UNKNOWN", "reason": "attempt/export could not be reliably parsed", "evidence_pointer": None} for ident in expected]
        report["counts"] = counts_for(report["tests"])
    return report


def report_error(message):
    # Do not leave an error message buffered for interpreter-shutdown flushing.
    try:
        os.write(2, (message + "\n").encode("utf-8", errors="backslashreplace"))
    except OSError:
        pass


class CLIParser(argparse.ArgumentParser):
    def error(self, message):
        report_error("argument error: " + message)
        raise SystemExit(2)


def main(argv=None):
    parser = CLIParser()
    parser.add_argument("--plan", required=True); parser.add_argument("--attempt", required=True); parser.add_argument("--report", required=True)
    args = parser.parse_args(argv)
    report_path = None
    report = make_report(None, None, None, None, None, None, None)
    try:
        report_path = safe_output_path(args.report)
        report, code = summarize(Path(args.plan), Path(args.attempt), report)
    except (InputError, OSError) as error:
        expected = [item["test_id"] for item in report["tests"]] if report["tests"] is not None else None
        report = error_with_known_plan(report, expected, str(error))
        code = 2
    if report_path is not None:
        try:
            write_report(report_path, report)
        except OSError as error:
            report_error("cannot write report: " + str(error))
            return 2
    else:
        report_error(report["issues"][0]["reason"])
    return code


if __name__ == "__main__":
    sys.exit(main())
