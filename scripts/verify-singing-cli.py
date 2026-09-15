#!/usr/bin/env python3
"""Offline full-process checks for CLI1. No inference, downloads, or input mutation."""
import argparse
import copy
import hashlib
import json
import math
import os
from pathlib import Path
import signal
import stat
import subprocess
import time

LIMIT = 2 * 1024 * 1024


def absolute(value):
    p = Path(value)
    if not p.is_absolute() or ".." in p.parts or "\0" in value:
        raise argparse.ArgumentTypeError("must be an absolute local path without traversal")
    return p


def nofollow(path, missing_leaf=False):
    current = Path(path.anchor)
    for i, part in enumerate(path.parts[1:]):
        current /= part
        try:
            value = current.lstat()
        except FileNotFoundError:
            if missing_leaf and i == len(path.parts) - 2:
                return
            raise
        if stat.S_ISLNK(value.st_mode):
            raise ValueError("symbolic links are not allowed: " + str(current))
        if i < len(path.parts) - 2 and not stat.S_ISDIR(value.st_mode):
            raise ValueError("non-directory parent: " + str(current))


def inside(child, root):
    return child == root or root in child.parents


def digest(path):
    nofollow(path)
    before = path.stat()
    if not stat.S_ISREG(before.st_mode):
        raise ValueError("not a regular input: " + str(path))
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(chunk)
    after = path.stat()
    identity = lambda s: (s.st_dev, s.st_ino, s.st_mode, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
    if identity(before) != identity(after):
        raise ValueError("input changed while checked: " + str(path))
    return {"identity": identity(after), "sha256": h.hexdigest()}


def pairs(items):
    result = {}
    for key, value in items:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def strict(raw):
    def invalid_constant(value):
        raise ValueError("nonfinite JSON number " + value)
    return json.loads(raw, object_pairs_hook=pairs, parse_constant=invalid_constant)


def run(command, timeout, directory):
    started = time.monotonic()
    child = None
    result = {"command": command}
    env = dict(os.environ, TMPDIR=str(directory), PYTHONDONTWRITEBYTECODE="1",
               PYTHONNOUSERSITE="1", XDG_CACHE_HOME=str(directory))
    env.pop("PYTHONPATH", None)
    try:
        child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 cwd=directory, env=env, start_new_session=True)
        result["pid"] = child.pid
        try:
            out, err = child.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            result["timeout"] = timeout
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                out, err = child.communicate(timeout=2)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                out, err = child.communicate(timeout=5)
        result.update(exit=child.returncode, stdout=out.decode("utf-8", "replace"),
                      stderr=err.decode("utf-8", "replace"))
    except (OSError, subprocess.SubprocessError) as error:
        result["error"] = str(error)
    finally:
        if child is not None and child.poll() is None:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait(timeout=5)
        if child is not None:
            for pipe in (child.stdout, child.stderr):
                if pipe is not None:
                    pipe.close()
        result["reaped"] = child is not None and child.returncode is not None
        result["seconds"] = time.monotonic() - started
    return result


def inspection_valid(path):
    if not path.is_file() or path.stat().st_size > LIMIT:
        return False
    d = strict(path.read_bytes())
    o = d.get("options", {})
    i = d.get("inspection", {})
    estimate = i.get("estimate", {})
    return (type(d.get("schemaVersion")) is int and d["schemaVersion"] == 1
            and d.get("tool") == "d-infer" and type(d.get("exitCode")) is int
            and d["exitCode"] == 0 and not d.get("failure") and d.get("runs") == []
            and o.get("capability") == "singing"
            and not set(o).intersection({"seed", "prompt", "steps", "guidance"})
            and type(i.get("withinBudget")) is bool
            and type(estimate.get("peakBytes")) is int and estimate["peakBytes"] > 0)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("cli", "request", "model", "python", "script", "vendor", "profile", "vocoder", "output"):
        parser.add_argument("--" + name, required=True, type=absolute)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--timeout", type=float, default=30)
    a = parser.parse_args()
    try:
        if not math.isfinite(a.timeout) or a.timeout <= 0:
            raise ValueError("timeout must be finite and positive")
        paths = [a.cli, a.request, a.model, a.python, a.script, a.vendor, a.profile, a.vocoder]
        for path in paths:
            nofollow(path)
        nofollow(a.output, missing_leaf=True)
        roots = [a.cli, a.request, a.model, a.python.parent, a.script.parent,
                 a.vendor, a.profile, a.vocoder]
        if os.path.lexists(a.output) or any(inside(a.output, x) or inside(x, a.output) for x in roots):
            raise ValueError("output must be fresh and disjoint from all supplied inputs")
        if not a.output.parent.is_dir() or not a.cli.is_file() or not a.request.is_file():
            raise ValueError("existing ordinary output parent and regular CLI/request required")
        if a.request.stat().st_size > LIMIT:
            raise ValueError("request exceeds 2 MiB")
        original = a.request.read_bytes()
        value = strict(original)
        if set(value) != {"schemaVersion", "runID", "profileID", "phrase", "pronunciations",
                          "vowelIndices", "qualification"}:
            raise ValueError("supply one valid complete SING1 request")
        # Negative cases require a real explicit rest in the positive fixture.
        rest_index = next(i for i, n in enumerate(value["phrase"]["notes"]) if n["midiPitch"] is None)
        protected = {p: digest(p) for p in (a.cli, a.request, a.python, a.script, a.profile)}
    except (OSError, ValueError, KeyError, TypeError, StopIteration) as error:
        parser.error(str(error))
    a.output.mkdir(mode=0o700)
    results = []
    try:
        request = a.output / "request.json"
        request.write_bytes(original)
        protected[request] = digest(request)
        artifacts = a.output / "artifacts"
        artifacts.mkdir(mode=0o700)
        temporary = a.output / "tmp"
        temporary.mkdir(mode=0o700)
        options = {"--capability": "singing", "--model": str(a.model), "--revision": a.revision,
                   "--singing-request": str(request), "--singing-python": str(a.python),
                   "--singing-script": str(a.script), "--singing-vendor": str(a.vendor),
                   "--singing-profile": str(a.profile), "--singing-vocoder": str(a.vocoder),
                   "--artifacts": str(artifacts), "--memory-budget-mib": "8192"}

        def check(name, expected, *, replacements=None, extra=(), custom=None,
                  inspect=False, report_target=None, sentinels=(), reason=None):
            report = report_target or a.output / (name + ".json")
            if custom is None:
                current = dict(options)
                current.update({k: str(v) for k, v in (replacements or {}).items()})
                command = [str(a.cli)] + [v for item in current.items() for v in item]
                command += ["--inspect"]
            else:
                command = [str(a.cli)] + list(custom)
            command += list(extra) + ["--report", str(report)]
            saved = {p: digest(p) for p in sentinels}
            actual = run(command, a.timeout, temporary)
            protection = all(digest(p) == d for p, d in protected.items())
            protection = protection and all(digest(p) == d for p, d in saved.items())
            valid = inspection_valid(report) if inspect and report.exists() else False
            # A parser case must not pass merely due to a duplicate option or missing setup.
            diagnostic = actual.get("stderr", "")
            reason_ok = reason is None or reason.lower() in diagnostic.lower()
            passed = (actual.get("exit") == expected and actual.get("reaped") is True
                      and "timeout" not in actual and "error" not in actual
                      and protection and not list(artifacts.iterdir())
                      and (not inspect or valid) and reason_ok)
            results.append(dict(name=name, expectedExit=expected, actual=actual,
                                inspectionRequired=inspect, inspectionValid=valid,
                                protectedUnchanged=protection, expectedReason=reason,
                                reasonMatched=reason_ok, passed=passed))
            return passed

        if not check("valid-inspect", 0, inspect=True):
            raise ValueError("positive actual CLI inspection failed; negative matrix not meaningful")
        check("valid-timeout", 0, extra=("--timeout-seconds", "1"), inspect=True)
        for name, extra in (("empty-prompt", ("--prompt", "")), ("repeat", ("--repeat", "2")),
                            ("timeout-nan", ("--timeout-seconds", "nan")), ("seed", ("--seed", "1")),
                            ("duplicate", ("--singing-profile", str(a.profile))),
                            ("unknown-option", ("--unknown-option", "x"))):
            check(name, 2, extra=extra)

        def altered(name, obj, *, raw=None, reason=None):
            p = a.output / (name + "-request.json")
            p.write_bytes(raw if raw is not None else json.dumps(obj, ensure_ascii=False).encode())
            check(name, 2, replacements={"--singing-request": p}, sentinels=(p,), reason=reason)

        for owner in (None, "phrase", "pronunciations"):
            for label, spelling in (("bool", "true"), ("float", "1.0"), ("exponent", "1e0")):
                mutated = copy.deepcopy(value)
                target = mutated if owner is None else mutated[owner]
                target["schemaVersion"] = "__D_NUMBER_FIXTURE__"
                raw = json.dumps(mutated, ensure_ascii=False).replace(
                    '"__D_NUMBER_FIXTURE__"', spelling).encode()
                altered((owner or "root") + "-schema-" + label, None, raw=raw, reason="integer")
        mutated = copy.deepcopy(value)
        mutated["phrase"]["revision"] = True
        altered("phrase-revision-bool", mutated, reason="integer")
        mutated = copy.deepcopy(value)
        del mutated["phrase"]["notes"][rest_index]["midiPitch"]
        altered("missing-rest-null", mutated, reason="singing note")
        mutated = copy.deepcopy(value)
        mutated["qualification"]["confirmedApplicable"] = False
        altered("qualification-false", mutated, reason="use declaration")
        mutated = copy.deepcopy(value)
        mutated["unknown"] = 0
        altered("unknown-json-field", mutated, reason="singing request")
        altered("trailing-json", None, raw=original + b" {}", reason="JSON")
        altered("empty-json", None, raw=b"", reason="JSON")
        check("wrong-outer-revision", 1, replacements={"--revision": "unverified-revision"})

        for key in ("--singing-request", "--singing-python", "--singing-script",
                    "--singing-vendor", "--singing-profile", "--singing-vocoder"):
            check("text-rejects-" + key[2:], 2,
                  custom=("--capability", "text", "--model", str(a.model), "--prompt", "x",
                          key, options[key]), reason=key)
        # All dangerous destinations below are disposable fixtures, never original materials.
        for flag in ("--singing-script", "--singing-python"):
            directory = a.output / (flag[2:] + "-fixture")
            directory.mkdir()
            entry = directory / "entry"
            helper = directory / "keep"
            entry.write_text("controlled unused entry")
            helper.write_text("controlled original helper")
            check(flag[2:] + "-parent-report", 2, replacements={flag: entry},
                  extra=("--unknown-option", "x"), report_target=helper, sentinels=(entry, helper))
        bank = a.output / "bank-fixture"
        bank.mkdir()
        sentinel = bank / "config.json"
        sentinel.write_text("controlled original bank")
        check("incomplete-bank-report", 2,
              custom=("--capability", "singing", "--model", str(bank)),
              report_target=sentinel, sentinels=(sentinel,))
        check("report-is-request", 2, report_target=request, sentinels=(request,))
        check("report-in-artifacts", 2, report_target=artifacts / "report.json")
        passed = all(x["passed"] for x in results)
        summary = {"schemaVersion": 1, "passed": passed, "cases": results,
                   "scope": "offline actual CLI parsing/admission, no model inference",
                   "originalInputsUnchanged": all(digest(p) == d for p, d in protected.items())}
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        summary = {"schemaVersion": 1, "passed": False, "cases": results, "error": str(error)}
    with (a.output / "results.json").open("x", encoding="utf-8") as handle:
        json.dump(summary, handle, ensure_ascii=False, indent=2)
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

