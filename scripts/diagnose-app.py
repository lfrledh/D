#!/usr/bin/env python3
"""Read-only diagnostics for an explicitly selected macOS application bundle."""

import argparse
import base64
import datetime as datetime
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import subprocess
import sys


SCHEMA_VERSION = 1
CODESIGN = "/usr/bin/codesign"
EXPECTED_BUNDLE_IDENTIFIER = "first-test.D"
REQUIRED_ENTITLEMENTS = (
    "com.apple.security.app-sandbox",
    "com.apple.security.files.user-selected.read-write",
    "com.apple.security.files.bookmarks.app-scope",
    "com.apple.security.network.client",
)
DEBUG_ENTITLEMENT = "com.apple.security.get-task-allow"
LIBRARY_VALIDATION = "com.apple.security.cs.disable-library-validation"


def json_safe(value):
    """Convert plist and subprocess values to standard-JSON values without guessing."""
    if value is None or isinstance(value, (str, int, bool)):
        return value
    if isinstance(value, float):
        if math.isfinite(value):
            return value
        return {"type": "float", "value": "NaN" if math.isnan(value) else "Infinity" if value > 0 else "-Infinity"}
    if isinstance(value, bytes):
        return {"type": "bytes", "base64": base64.b64encode(value).decode("ascii")}
    if isinstance(value, dict):
        return {str(key): json_safe(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [json_safe(item) for item in value]
    return {"type": type(value).__name__, "repr": repr(value)}


def result(status, reason, evidence=None):
    value = {"status": status, "reason": reason}
    if evidence is not None:
        value["evidence"] = json_safe(evidence)
    return value


def utc_timestamp():
    value = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
    return value.isoformat().replace("+00:00", "Z")


def is_within(path, root):
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def output_text(value):
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return "" if value is None else str(value)


def run_command(argv, timeout=10, runner=subprocess.run):
    """Run a finite argv-only process; subprocess.run kills and reaps timeouts."""
    evidence = {
        "argv": list(argv),
        "returncode": None,
        "stdout": "",
        "stderr": "",
        "timed_out": False,
        "unavailable": False,
        "exception": None,
    }
    try:
        completed = runner(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
            check=False,
        )
        evidence["returncode"] = completed.returncode
        evidence["stdout"] = output_text(completed.stdout)
        evidence["stderr"] = output_text(completed.stderr)
    except subprocess.TimeoutExpired as error:
        evidence["timed_out"] = True
        evidence["stdout"] = output_text(error.stdout)
        evidence["stderr"] = output_text(error.stderr)
        evidence["exception"] = f"TimeoutExpired: {error}"
    except FileNotFoundError as error:
        evidence["unavailable"] = True
        evidence["exception"] = f"FileNotFoundError: {error}"
    except Exception as error:
        evidence["exception"] = f"{type(error).__name__}: {error}"
    return evidence


def parse_entitlements(output):
    start = output.find("<?xml")
    if start < 0:
        start = output.find("<plist")
    if start < 0:
        raise ValueError("codesign output did not contain an entitlement plist")
    entitlements = plistlib.loads(output[start:].encode("utf-8"))
    if not isinstance(entitlements, dict):
        raise ValueError("entitlements plist is not a dictionary")
    return entitlements


def boolean_entitlement(entitlements, key):
    if key not in entitlements:
        return {"state": "missing"}
    value = entitlements[key]
    if value is True:
        return {"state": "true", "value": True}
    if value is False:
        return {"state": "false", "value": False}
    return {"state": "invalid", "value": json_safe(value)}


def is_safe_executable_name(value):
    return (
        isinstance(value, str)
        and value not in ("", ".", "..")
        and "/" not in value
        and "\\" not in value
        and "\0" not in value
    )


def new_report(app):
    return {
        "schema_version": SCHEMA_VERSION,
        "checked_at": utc_timestamp(),
        "input_path": str(app),
        "resolved_path": None,
        "report_complete": False,
        "checks": {},
        "rules": {},
        "tool_errors": [],
        "commands": [],
        "overall": result("UNKNOWN", "diagnosis did not complete"),
        "not_checked": [
            "certificate chain trust",
            "notarization/Gatekeeper",
            "actual sandbox file operations",
            "ongoing TCC effectiveness",
            "bookmark restoration across builds",
            "GUI",
            "D-C01a full-stage acceptance",
        ],
    }


def finalize(report, exit_code=None):
    applicable = [rule for rule in report["rules"].values() if rule["status"] != "NOT_APPLICABLE"]
    unknown = bool(report["tool_errors"]) or any(rule["status"] == "UNKNOWN" for rule in applicable)
    failed = any(rule["status"] == "FAIL" for rule in applicable)
    if exit_code is None:
        exit_code = 2 if unknown else 1 if failed else 0
    report["report_complete"] = exit_code != 2
    status = "UNKNOWN" if exit_code == 2 else "FAIL" if exit_code == 1 else "PASS"
    report["overall"] = result(status, "required rules evaluated")
    return report, exit_code


def structural_failure(report, reason, evidence=None):
    report["checks"]["artifact"] = result("FAIL", reason, evidence)
    report["tool_errors"].append(f"artifact: {reason}")
    return finalize(report, 2)


def resolve_inside(path, bundle, label):
    resolved = path.resolve(strict=True)
    if not is_within(resolved, bundle):
        raise ValueError(f"{label} resolves outside the bundle")
    return resolved


def diagnose(app, timeout=10, runner=subprocess.run):
    report = new_report(app)
    if isinstance(timeout, bool) or not isinstance(timeout, (int, float)) or not math.isfinite(timeout) or timeout <= 0:
        report["tool_errors"].append("timeout: must be a finite positive number")
        return finalize(report, 2)
    try:
        bundle = Path(app).resolve(strict=True)
    except Exception as error:
        return structural_failure(report, "input path cannot be resolved", f"{type(error).__name__}: {error}")
    report["resolved_path"] = str(bundle)
    if not bundle.is_dir():
        return structural_failure(report, "app path is not a directory")
    try:
        contents = resolve_inside(bundle / "Contents", bundle, "Contents directory")
        if not contents.is_dir() or not os.access(contents, os.R_OK | os.X_OK):
            return structural_failure(report, "Contents directory is missing or unreadable")
        plist_path = resolve_inside(contents / "Info.plist", bundle, "Info.plist")
        with plist_path.open("rb") as source:
            info = plistlib.load(source)
        if not isinstance(info, dict):
            return structural_failure(report, "Info.plist is not a dictionary")
        macos_directory = resolve_inside(contents / "MacOS", bundle, "Contents/MacOS directory")
        if not macos_directory.is_dir():
            return structural_failure(report, "Contents/MacOS directory is missing")
    except Exception as error:
        return structural_failure(report, "bundle metadata is missing, unreadable, or invalid", f"{type(error).__name__}: {error}")
    executable = info.get("CFBundleExecutable")
    if not is_safe_executable_name(executable):
        return structural_failure(report, "CFBundleExecutable is not a safe single filename")
    try:
        executable_path = resolve_inside(macos_directory / executable, bundle, "bundle executable")
        if not executable_path.is_file():
            return structural_failure(report, "bundle executable is missing")
        report["checks"]["artifact"] = result(
            "PASS",
            "bundle structure is readable",
            {
                "info_plist_sha256": sha256(plist_path),
                "executable_sha256": sha256(executable_path),
                "CFBundleExecutable": executable,
                "CFBundleShortVersionString": info.get("CFBundleShortVersionString", "missing"),
                "CFBundleVersion": info.get("CFBundleVersion", "missing"),
                "CFBundleIdentifier": info.get("CFBundleIdentifier", "missing"),
            },
        )
    except ValueError as error:
        return structural_failure(report, str(error), f"{type(error).__name__}: {error}")
    except FileNotFoundError as error:
        return structural_failure(report, "bundle executable is missing", f"{type(error).__name__}: {error}")
    except Exception as error:
        return structural_failure(report, "bundle executable cannot be read", f"{type(error).__name__}: {error}")

    bundle_identifier = info.get("CFBundleIdentifier")
    report["rules"]["expected_bundle_identifier"] = result(
        "PASS" if bundle_identifier == EXPECTED_BUNDLE_IDENTIFIER else "FAIL",
        "Info bundle identifier must be first-test.D",
        bundle_identifier,
    )

    def record_command(name, argv, nonzero_is_error=False):
        evidence = run_command(argv, timeout, runner)
        report["commands"].append({"name": name, **evidence})
        if evidence["exception"]:
            report["tool_errors"].append(f"{name}: {evidence['exception']}")
        elif nonzero_is_error and evidence["returncode"] != 0:
            report["tool_errors"].append(f"{name}: exited {evidence['returncode']}")
        return evidence

    display = record_command("codesign_display", [CODESIGN, "-dvv", str(bundle)])
    display_text = display["stdout"] + "\n" + display["stderr"]
    unsigned = display["returncode"] not in (None, 0) and "not signed at all" in display_text.lower()
    if unsigned:
        report["checks"]["signature"] = result("FAIL", "codesign reports unsigned", {"classification": "unsigned"})
        report["rules"]["signature_present"] = result("FAIL", "application is unsigned")
        report["rules"]["integrity"] = result("NOT_APPLICABLE", "application is unsigned")
        report["rules"]["entitlements"] = result("NOT_APPLICABLE", "application is unsigned")
        return finalize(report)
    if display["returncode"] != 0 or display["exception"]:
        if display["returncode"] != 0 and not display["exception"]:
            report["tool_errors"].append(f"codesign_display: exited {display['returncode']}")
        report["checks"]["signature"] = result("UNKNOWN", "codesign display did not complete")
        report["rules"]["signature_present"] = result("UNKNOWN", "signature evidence unavailable")
        return finalize(report)

    identifier = next((line.split("=", 1)[1] for line in display_text.splitlines() if line.startswith("Identifier=")), None)
    signature_line = next((line for line in display_text.splitlines() if line.startswith("Signature=")), "")
    classification = "ad-hoc" if "adhoc" in signature_line.lower() else "certificate-backed" if "Authority=" in display_text else "unknown"
    report["checks"]["signature"] = result("PASS", "codesign display completed", {"identifier": identifier, "classification": classification})
    report["rules"]["signature_present"] = result("PASS", "signature exists")
    if identifier is None or not isinstance(bundle_identifier, str):
        consistency = "UNKNOWN"
    else:
        consistency = "PASS" if identifier == bundle_identifier else "FAIL"
    report["rules"]["identifier_consistency"] = result(consistency, "bundle and signature identifiers compared", {"bundle": bundle_identifier, "signature": identifier})

    verify = record_command("codesign_verify", [CODESIGN, "--verify", "--strict", str(bundle)])
    verify_status = "PASS" if verify["returncode"] == 0 else "UNKNOWN" if verify["exception"] else "FAIL"
    report["rules"]["integrity"] = result(verify_status, "codesign strict verification")

    entitlement_command = record_command("codesign_entitlements", [CODESIGN, "-d", "--entitlements", ":-", str(bundle)], nonzero_is_error=True)
    try:
        if entitlement_command["returncode"] != 0 or entitlement_command["exception"]:
            raise ValueError("codesign entitlement command did not complete")
        entitlements = parse_entitlements(entitlement_command["stdout"])
        evidence = {key: boolean_entitlement(entitlements, key) for key in REQUIRED_ENTITLEMENTS + (DEBUG_ENTITLEMENT,)}
        for key, value in entitlements.items():
            if key.startswith("com.apple.security.temporary-exception.") or key == LIBRARY_VALIDATION:
                evidence[key] = {"state": "present", "value": json_safe(value)}
        invalid = [key for key in REQUIRED_ENTITLEMENTS + (DEBUG_ENTITLEMENT,) if evidence[key]["state"] == "invalid"]
        library_validation = entitlements.get(LIBRARY_VALIDATION)
        if library_validation is not None and not isinstance(library_validation, bool):
            invalid.append(LIBRARY_VALIDATION)
        if invalid:
            raise ValueError("selected entitlement values are not boolean: " + ", ".join(invalid))
        report["checks"]["entitlements"] = result("PASS", "entitlement plist parsed", evidence)
        required_pass = all(evidence[key]["state"] == "true" for key in REQUIRED_ENTITLEMENTS)
        report["rules"]["entitlements"] = result("PASS" if required_pass else "FAIL", "required entitlement values evaluated")
        unsafe = [
            (key, value)
            for key, value in entitlements.items()
            if (key.startswith("com.apple.security.temporary-exception.") and value not in (None, "", [], {}, False))
            or (key == LIBRARY_VALIDATION and value is True)
        ]
        report["rules"]["unsafe_entitlements"] = result("FAIL" if unsafe else "PASS", "temporary exceptions and library validation evaluated", unsafe)
    except Exception as error:
        report["checks"]["entitlements"] = result("UNKNOWN", "entitlements cannot be reliably parsed", f"{type(error).__name__}: {error}")
        report["rules"]["entitlements"] = result("UNKNOWN", "required entitlement evidence unavailable")
        report["tool_errors"].append(f"entitlements: {type(error).__name__}: {error}")
    return finalize(report)


def write_report(path, report):
    target = Path(path)
    bundle_path = report.get("resolved_path")
    if target.exists() or (bundle_path and is_within(target.resolve(strict=False), Path(bundle_path))):
        raise ValueError("report path exists or is inside the app bundle")
    with target.open("x", encoding="utf-8") as output:
        json.dump(report, output, indent=2, ensure_ascii=False, allow_nan=False)
        output.write("\n")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True)
    parser.add_argument("--report")
    parser.add_argument("--timeout", type=float, default=10, help=argparse.SUPPRESS)
    arguments = parser.parse_args(argv)
    report, exit_code = diagnose(arguments.app, arguments.timeout)
    if arguments.report:
        try:
            write_report(arguments.report, report)
        except Exception as error:
            report["tool_errors"].append(f"report: {type(error).__name__}: {error}")
            report, exit_code = finalize(report, 2)
    print(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False))
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
