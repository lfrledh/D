#!/usr/bin/env python3
"""Read-only diagnostics for an explicitly selected macOS .app bundle."""

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys


SCHEMA_VERSION = 1
CODESIGN = "/usr/bin/codesign"
REQUIRED_ENTITLEMENTS = (
    "com.apple.security.app-sandbox",
    "com.apple.security.files.user-selected.read-write",
    "com.apple.security.files.bookmarks.app-scope",
    "com.apple.security.network.client",
)
OBSERVED_ENTITLEMENTS = REQUIRED_ENTITLEMENTS + ("com.apple.security.get-task-allow",)


def now():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def status(name, reason, evidence=None):
    item = {"status": name, "reason": reason}
    if evidence is not None:
        item["evidence"] = evidence
    return item


def command_evidence(argv, timeout=10, runner=subprocess.run):
    result = {"argv": list(argv), "returncode": None, "stdout": "", "stderr": "",
              "timed_out": False, "unavailable": False, "exception": None}
    try:
        completed = runner(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, text=True, encoding="utf-8", errors="replace",
                           timeout=timeout, check=False)
        result.update(returncode=completed.returncode, stdout=completed.stdout, stderr=completed.stderr)
    except subprocess.TimeoutExpired as error:
        result.update(timed_out=True, stdout=(error.stdout or ""), stderr=(error.stderr or ""),
                      exception=f"TimeoutExpired: {error}")
    except FileNotFoundError as error:
        result.update(unavailable=True, exception=f"FileNotFoundError: {error}")
    except Exception as error:
        result["exception"] = f"{type(error).__name__}: {error}"
    return result


def plist_from_codesign(output):
    start = output.find("<?xml")
    if start < 0:
        start = output.find("<plist")
    if start < 0:
        raise ValueError("codesign output did not contain an entitlement plist")
    return plistlib.loads(output[start:].encode("utf-8"))


def entitlement_value(value):
    if value is True:
        return {"state": "true", "value": True}
    if value is False:
        return {"state": "false", "value": False}
    return {"state": "invalid", "value": value}


def safe_executable_name(value):
    return isinstance(value, str) and value not in ("", ".", "..") and "/" not in value and "\\" not in value and "\x00" not in value


def diagnose(app, timeout=10, runner=subprocess.run):
    report = {"schema_version": SCHEMA_VERSION, "checked_at": now(), "input_path": str(app),
              "resolved_path": None, "report_complete": False, "checks": {}, "rules": {},
              "tool_errors": [], "commands": [], "not_checked": [
                  "certificate chain trust", "notarization/Gatekeeper", "actual sandbox file operations",
                  "ongoing TCC effectiveness", "bookmark restoration across builds", "GUI", "D-C01a full-stage acceptance"]}
    path = Path(app)
    try:
        resolved = path.resolve(strict=True)
        report["resolved_path"] = str(resolved)
    except (OSError, RuntimeError) as error:
        report["checks"]["artifact"] = status("UNKNOWN", "input path cannot be resolved", str(error))
        report["tool_errors"].append(f"path: {type(error).__name__}: {error}")
        return report, 2
    if not resolved.is_dir():
        report["checks"]["artifact"] = status("FAIL", "app path is not a directory")
        report["tool_errors"].append("artifact: app path is not a directory")
        return report, 2
    contents = resolved / "Contents"
    if not contents.is_dir() or not os.access(contents, os.R_OK | os.X_OK):
        report["checks"]["artifact"] = status("FAIL", "Contents directory is missing or unreadable")
        report["tool_errors"].append("artifact: Contents directory is missing or unreadable")
        return report, 2
    plist_path = contents / "Info.plist"
    try:
        with plist_path.open("rb") as source:
            info = plistlib.load(source)
        if not isinstance(info, dict):
            raise ValueError("Info.plist is not a dictionary")
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        report["checks"]["artifact"] = status("FAIL", "Info.plist is missing, unreadable, or invalid", str(error))
        report["tool_errors"].append(f"artifact: {type(error).__name__}: {error}")
        return report, 2
    executable = info.get("CFBundleExecutable")
    if not safe_executable_name(executable):
        report["checks"]["artifact"] = status("FAIL", "CFBundleExecutable is not a safe single filename")
        report["tool_errors"].append("artifact: unsafe CFBundleExecutable")
        return report, 2
    executable_path = contents / "MacOS" / executable
    if not executable_path.is_file():
        report["checks"]["artifact"] = status("FAIL", "bundle executable is missing", str(executable_path))
        report["tool_errors"].append("artifact: bundle executable is missing")
        return report, 2
    try:
        report["checks"]["artifact"] = status("PASS", "bundle structure is readable", {
            "info_plist_sha256": sha256(plist_path), "executable_sha256": sha256(executable_path),
            "CFBundleExecutable": executable,
            "CFBundleShortVersionString": info.get("CFBundleShortVersionString", "missing"),
            "CFBundleVersion": info.get("CFBundleVersion", "missing"),
            "CFBundleIdentifier": info.get("CFBundleIdentifier", "missing")})
    except OSError as error:
        report["checks"]["artifact"] = status("UNKNOWN", "bundle hashes cannot be read", str(error))
        report["tool_errors"].append(f"artifact: {type(error).__name__}: {error}")
        return report, 2

    def run(label, args):
        evidence = command_evidence(args, timeout, runner)
        report["commands"].append({"name": label, **evidence})
        if evidence["timed_out"] or evidence["unavailable"] or evidence["exception"]:
            report["tool_errors"].append(f"{label}: {evidence['exception']}")
        return evidence

    display = run("codesign_display", [CODESIGN, "-dvv", str(resolved)])
    text = display["stdout"] + "\n" + display["stderr"]
    unsigned = display["returncode"] is not None and display["returncode"] != 0 and "not signed at all" in text.lower()
    if unsigned:
        report["checks"]["signature"] = status("FAIL", "codesign reports unsigned", {"classification": "unsigned"})
        report["rules"]["signature_present"] = status("FAIL", "application is unsigned")
        report["rules"]["integrity"] = status("NOT_APPLICABLE", "application is unsigned")
        report["rules"]["entitlements"] = status("NOT_APPLICABLE", "application is unsigned")
    elif display["returncode"] != 0 or display["exception"]:
        report["checks"]["signature"] = status("UNKNOWN", "codesign display did not complete")
        report["rules"]["signature_present"] = status("UNKNOWN", "signature evidence unavailable")
    else:
        identifier = next((line.split("=", 1)[1] for line in text.splitlines() if line.startswith("Identifier=")), None)
        signature_line = next((line for line in text.splitlines() if line.startswith("Signature=")), "")
        classification = "ad-hoc" if "adhoc" in signature_line.lower() else "certificate-backed" if "Authority=" in text else "unknown"
        report["checks"]["signature"] = status("PASS", "codesign display completed", {"identifier": identifier, "classification": classification})
        report["rules"]["signature_present"] = status("PASS", "signature exists")
        bundle_id = info.get("CFBundleIdentifier")
        if isinstance(bundle_id, str) and identifier is not None:
            report["rules"]["identifier_consistency"] = status("PASS" if bundle_id == identifier else "FAIL", "bundle and signature identifiers compared", {"bundle": bundle_id, "signature": identifier})
        else:
            report["rules"]["identifier_consistency"] = status("UNKNOWN", "bundle or signature identifier unavailable")
        verify = run("codesign_verify", [CODESIGN, "--verify", "--strict", str(resolved)])
        report["rules"]["integrity"] = status("PASS" if verify["returncode"] == 0 else "UNKNOWN" if verify["exception"] else "FAIL", "codesign strict verification" if verify["returncode"] is not None else "codesign verify unavailable")
        ent = run("codesign_entitlements", [CODESIGN, "-d", "--entitlements", ":-", str(resolved)])
        try:
            if ent["returncode"] != 0 or ent["exception"]:
                raise ValueError("codesign entitlement command did not complete")
            entitlements = plist_from_codesign(ent["stdout"])
            if not isinstance(entitlements, dict):
                raise ValueError("entitlements plist is not a dictionary")
            values = {key: entitlement_value(entitlements[key]) if key in entitlements else {"state": "missing"} for key in OBSERVED_ENTITLEMENTS}
            for key, value in entitlements.items():
                if key.startswith("com.apple.security.temporary-exception.") or key == "com.apple.security.cs.disable-library-validation":
                    values[key] = {"state": "present", "value": value}
            report["checks"]["entitlements"] = status("PASS", "entitlement plist parsed", values)
            invalid_required = [key for key in REQUIRED_ENTITLEMENTS if values[key]["state"] == "invalid"]
            if invalid_required:
                raise ValueError("required entitlement values are not boolean: " + ", ".join(invalid_required))
            required_ok = all(values[key]["state"] == "true" for key in REQUIRED_ENTITLEMENTS)
            report["rules"]["entitlements"] = status("PASS" if required_ok else "FAIL", "required entitlement values evaluated")
            prohibited = [(key, value) for key, value in values.items() if (key.startswith("com.apple.security.temporary-exception.") and value.get("value") not in (None, "", [], {}, False)) or (key == "com.apple.security.cs.disable-library-validation" and value.get("value") is True)]
            report["rules"]["unsafe_entitlements"] = status("FAIL" if prohibited else "PASS", "temporary exceptions and library validation evaluated", prohibited)
        except (ValueError, plistlib.InvalidFileException, TypeError) as error:
            report["checks"]["entitlements"] = status("UNKNOWN", "entitlements cannot be reliably parsed", str(error))
            report["rules"]["entitlements"] = status("UNKNOWN", "required entitlement evidence unavailable")
            report["tool_errors"].append(f"entitlements: {type(error).__name__}: {error}")

    required = [value for value in report["rules"].values() if value["status"] not in ("NOT_APPLICABLE",)]
    has_unknown = bool(report["tool_errors"]) or any(item["status"] == "UNKNOWN" for item in required)
    has_fail = any(item["status"] == "FAIL" for item in required)
    report["report_complete"] = not has_unknown
    report["overall"] = status("UNKNOWN" if has_unknown else "FAIL" if has_fail else "PASS", "required rules evaluated")
    return report, 2 if has_unknown else 1 if has_fail else 0


def write_report(path, report):
    destination = Path(path)
    app_path = report.get("resolved_path")
    inside_app = app_path is not None and destination.resolve(strict=False).is_relative_to(Path(app_path))
    if destination.exists() or inside_app:
        raise ValueError("report path exists or is inside the app bundle")
    with destination.open("x", encoding="utf-8") as output:
        json.dump(report, output, indent=2, ensure_ascii=False)
        output.write("\n")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, help="explicit app bundle path")
    parser.add_argument("--report", help="new JSON report path outside the app bundle")
    parser.add_argument("--timeout", type=float, default=10, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    report, code = diagnose(args.app, args.timeout)
    if args.report:
        try:
            write_report(args.report, report)
        except (OSError, ValueError) as error:
            report["tool_errors"].append(f"report: {type(error).__name__}: {error}")
            report["report_complete"] = False
            report["overall"] = status("UNKNOWN", "report could not be written")
            code = 2
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return code


if __name__ == "__main__":
    sys.exit(main())
